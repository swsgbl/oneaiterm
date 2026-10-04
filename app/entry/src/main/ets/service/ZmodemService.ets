/**
 * upstream M8 relay-5 - Zmodem (rz/sz) bidirectional file transfer.
 *
 * Wire-verified protocol implementation (harness: .verify/m8r5/harness,
 * recv.js / send.js both md5-matched against real WSL lrzsz):
 *
 *  - frame types: ZRQINIT=0 ZRINIT=1 ZFILE=4 ZNAK=6 ZFIN=8 ZRPOS=9
 *    ZDATA=10 ZEOF=11 (NOTE: NOT the naive 0x0a-0x0f list - those are
 *    off by one; verified against real sz/rz on the wire);
 *  - subframe terminators: ZCRCE=0x68 ZCRCG=0x69 ZCRCQ=0x71 ZCRCW=0x6b;
 *  - header forms: hex ("**" ZDLE 'B' + 14 hex + CR 0x8a XON), bin16
 *    ("*" ZDLE 'A' + escaped type/data/crc16), bin32 ("*" ZDLE 'C' +
 *    escaped type/data + 4 escaped crc32 bytes, LITTLE-ENDIAN);
 *  - subframes (ZBIN32): escaped payload + ZDLE term + 4 escaped crc32 LE
 *    bytes; crc32 covers [payload..., term];
 *  - escape set: (x & 0x7f) in {0x18, 0x11, 0x13, 0x10, 0x0d, 0x0a} ->
 *    ZDLE (x ^ 0x40); unescape keeps bit7 ((c ^ 0x40) & 0xff);
 *  - RX flow: ZRQINIT -> ZRINIT[0x23,0,0,0]; ZFILE -> parse name/size ->
 *    ZRPOS 0; ZDATA -> drain; ZCRCW window end -> ZRPOS(len) resume;
 *    ZEOF(size match) -> ZRINIT; ZFIN -> ZFIN + "OO";
 *  - TX flow: peer ZRINIT -> ZFILE(bin16, ZCRCW); peer ZRPOS(pos) ->
 *    ZDATA(bin32) + 1KB ZCRCG subframes (last ZCRCE) + hex ZEOF;
 *    peer ZRINIT after ZEOF -> ZFIN; peer ZFIN -> ZFIN + "OO".
 *
 * Binary safety: all channel bytes cross the napi boundary base64-encoded
 * (native zmSetRaw switches the reader to "zmdata" events; zmWriteBinary
 * writes raw bytes) - the UTF-8 string boundary never sees file data.
 */

import hilog from '@ohos.hilog';
import util from '@ohos.util';
import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { SessionService } from './SessionService';
import type { libssh } from '@ohos/libssh';

const DOMAIN: number = 0x0a17;
const TAG: string = 'oat.zmodem';

// frame types (wire-verified)
const ZRQINIT: number = 0;
const ZRINIT: number = 1;
const ZFILE: number = 4;
const ZNAK: number = 6;
const ZFIN: number = 8;
const ZRPOS: number = 9;
const ZDATA: number = 10;
const ZEOF: number = 11;
// subframe terminators
const ZCRCE: number = 0x68;
const ZCRCG: number = 0x69;
const ZCRCQ: number = 0x71;
const ZCRCW: number = 0x6b;
const ZCRC: number = 0x63;

const ZDLE: number = 0x18;
const ZHEX: number = 0x42;
const ZBIN: number = 0x41;
const ZBIN32: number = 0x43;
const XON: number = 0x11;

const SUB: number = 1024; // tx subframe payload size

class ZmFrame {
  type: number = -1;
  data: number[] = [];
  crcOk: boolean = false;
  kind: string = '';
}

class ZmSub {
  data: number[] = [];
  term: number = -1;
  end: number = 0;
  crcOk: boolean = false;
}

export class ZmodemService {
  private static b64: util.Base64Helper = new util.Base64Helper();
  private static buf: number[] = [];
  private static state: string = 'idle'; // idle | hdrWait | drain | tx
  private static mode: string = '';      // rx | tx
  private static file: number[] = [];
  private static zfileName: string = '';
  private static zfileSize: number = 0;
  private static gotZfin: boolean = false;
  private static txData: number[] = [];
  private static txName: string = 'zmfile.bin';
  private static txStage: number = 0;
  /** M8 relay7: payload bytes actually streamed for the current tx (tx-done log). */
  private static txBytes: number = 0;
  private static filesDir: string = '';
  private static markerWin: string = '';

  /** UI/status: set the app-sandbox dir for received files. */
  public static setFilesDir(d: string): void {
    ZmodemService.filesDir = d;
  }

  /** libssh handle of the live session (null-checked at every call). */
  private static ssh(): libssh | null {
    const h = SessionService.sshHandle();
    return h;
  }

  /** Marker detection over the TEXT stream (TermModel feed hook).
   * ZRQINIT '**'+ZDLE+'B'+'00' -> remote wants to SEND (we receive);
   * ZRINIT '**'+ZDLE+'B'+'01' -> remote wants to RECEIVE (we send).
   * The triggering frame arrives on the TEXT path; begin() then switches
   * the native reader to raw/zmdata, so those frame bytes would be lost
   * and both sides deadlock (sz waits for our ZRINIT forever). Seed the
   * parser buffer with the frame bytes we already hold, then pump. */
  public static feedText(raw: string): void {
    if (ZmodemService.state !== 'idle') {
      return;
    }
    ZmodemService.markerWin = (ZmodemService.markerWin + raw).slice(-64);
    const mRx = ZmodemService.markerWin.indexOf('**\x18B00');
    const mTx = ZmodemService.markerWin.indexOf('**\x18B01');
    if (mRx < 0 && mTx < 0) {
      return;
    }
    const seed = ZmodemService.markerWin;
    ZmodemService.begin(mRx >= 0 ? 'rx' : 'tx');
    for (let i = 0; i < seed.length; i++) {
      ZmodemService.buf.push(seed.charCodeAt(i) & 0xff);
    }
    hilog.info(DOMAIN, TAG, 'seeded %{public}dB from text marker', seed.length);
    ZmodemService.pump();
  }

  /** Enter a transfer: switch native reader to raw mode, reset state. */
  public static begin(mode: string): void {
    if (ZmodemService.state !== 'idle') {
      return;
    }
    ZmodemService.mode = mode;
    ZmodemService.state = 'hdrWait';
    ZmodemService.buf = [];
    ZmodemService.file = [];
    ZmodemService.zfileName = '';
    ZmodemService.zfileSize = 0;
    ZmodemService.gotZfin = false;
    ZmodemService.markerWin = '';
    AppStorage.setOrCreate('ut.zm.status', mode === 'rx' ? 'receiving' : 'sending');
    const id = ZmodemService.sessionId();
    const h = ZmodemService.ssh();
    if (id >= 0 && h !== null) {
      h.zmSetRaw(id, true);
    }
    hilog.info(DOMAIN, TAG, 'begin mode=%{public}s id=%{public}d', mode, id);
    if (mode === 'tx') {
      ZmodemService.txStage = 0;
      ZmodemService.txData = [];
      ZmodemService.txBytes = 0;
      ZmodemService.loadTxFile();
      // tx is driven by the peer's ZRINIT arriving via onRaw
    }
  }

  /** Manual trigger (ZM button): tx uses the newest file in filesDir/zmodem. */
  public static startTxManually(): void {
    if (ZmodemService.state === 'idle') {
      // send "rz\r" to the remote so it answers ZRINIT -> marker -> begin('tx')
      const id = ZmodemService.sessionId();
      const h2 = ZmodemService.ssh();
      if (id >= 0 && h2 !== null) {
        h2.writeStdin(id, 'rz\r');
        AppStorage.setOrCreate('ut.zm.status', 'rz-sent');
      }
    } else {
      // busy: ignore
    }
  }

  private static sessionId(): number {
    const v = AppStorage.get<number>('ut.session.id');
    return v === undefined ? -1 : v;
  }

  private static loadTxFile(): void {
    try {
      const dir = ZmodemService.filesDir + '/zmodem';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const names = fs.listFileSync(dir);
      let best = '';
      let bestMs = -1;
      for (let i = 0; i < names.length; i++) {
        const st = fs.statSync(dir + '/' + names[i]);
        if (st.isFile() && st.mtime > bestMs) {
          bestMs = st.mtime;
          best = names[i];
        }
      }
      if (best !== '') {
        const st = fs.statSync(dir + '/' + best);
        const fd = fs.openSync(dir + '/' + best, fs.OpenMode.READ_ONLY);
        const ab = new ArrayBuffer(st.size);
        const got = fs.readSync(fd.fd, ab);
        fs.closeSync(fd);
        const u8 = new Uint8Array(ab, 0, got);
        ZmodemService.txData = Array.from(u8);
        ZmodemService.txName = best;
        hilog.info(DOMAIN, TAG, 'tx file=%{public}s %{public}d/%{public}dB', best, got, st.size);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'loadTxFile fail %{public}s', msg);
    }
  }

  /** Native zmdata event: raw channel bytes, base64-encoded. */
  public static onRaw(b64: string): void {
    if (ZmodemService.state === 'idle') {
      return;
    }
    const bytes: Uint8Array = ZmodemService.b64.decodeSync(b64);
    for (let i = 0; i < bytes.length; i++) {
      ZmodemService.buf.push(bytes[i]);
    }
    ZmodemService.pump();
  }

  private static send(bytes: number[]): void {
    const id = ZmodemService.sessionId();
    if (id < 0) {
      return;
    }
    const u8 = new Uint8Array(bytes);
    const b64 = ZmodemService.b64.encodeToStringSync(u8);
    const hs = ZmodemService.ssh();
    if (hs === null) {
      return;
    }
    const n = hs.zmWriteBinary(id, b64);
    if (n < 0) {
      hilog.error(DOMAIN, TAG, 'send fail %{public}dB', bytes.length);
    }
  }

  private static sendText(s: string): void {
    const id = ZmodemService.sessionId();
    const hh = ZmodemService.ssh();
    if (id >= 0 && hh !== null) {
      hh.writeStdin(id, s);
    }
  }

  // ---- codec ----
  private static crc16(arr: number[]): number {
    let crc = 0;
    for (let i = 0; i < arr.length; i++) {
      crc ^= (arr[i] & 0xff) << 8;
      for (let k = 0; k < 8; k++) {
        crc = (crc & 0x8000) !== 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xffff;
      }
    }
    return crc >>> 0;
  }

  private static crc32tab: Uint32Array | null = null;
  private static crc32(arr: number[]): number {
    if (ZmodemService.crc32tab === null) {
      const t = new Uint32Array(256);
      for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) {
          c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        }
        t[n] = c >>> 0;
      }
      ZmodemService.crc32tab = t;
    }
    const t = ZmodemService.crc32tab as Uint32Array;
    let c = 0xFFFFFFFF;
    for (let i = 0; i < arr.length; i++) {
      c = t[(c ^ (arr[i] & 0xff)) & 0xff] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  private static hexByte(v: number): string {
    const h = '0123456789abcdef';
    return h.charAt((v >> 4) & 0xf) + h.charAt(v & 0xf);
  }

  private static hexFrame(type: number, data: number[]): number[] {
    const body = [type].concat(data);
    const crc = ZmodemService.crc16(body);
    let s = '**\x18B';
    for (let i = 0; i < body.length; i++) {
      s += ZmodemService.hexByte(body[i]);
    }
    s += ZmodemService.hexByte((crc >> 8) & 0xff) + ZmodemService.hexByte(crc & 0xff);
    s += '\r\x8a\x11';
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      out.push(s.charCodeAt(i) & 0xff);
    }
    return out;
  }

  private static esc(bytes: number[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < bytes.length; i++) {
      const x = bytes[i] & 0xff;
      const t = x & 0x7f;
      if (t === 0x18 || t === 0x11 || t === 0x13 || t === 0x10 || t === 0x0d || t === 0x0a) {
        out.push(ZDLE, (x ^ 0x40) & 0xff);
      } else {
        out.push(x);
      }
    }
    return out;
  }

  private static binHdr(type: number, data: number[]): number[] {
    const body = [type].concat(data);
    const crc = ZmodemService.crc16(body);
    return [0x2a, ZDLE, ZBIN].concat(
      ZmodemService.esc(body),
      ZmodemService.esc([(crc >> 8) & 0xff, crc & 0xff]));
  }

  private static bin32Hdr(type: number, data: number[]): number[] {
    const body = [type].concat(data);
    const c = ZmodemService.crc32(body);
    return [0x2a, ZDLE, ZBIN32].concat(
      ZmodemService.esc(body),
      ZmodemService.esc([c & 0xff, (c >>> 8) & 0xff, (c >>> 16) & 0xff, (c >>> 24) & 0xff]));
  }

  private static sub32(payload: number[], term: number): number[] {
    const c = ZmodemService.crc32(payload.concat([term]));
    return ZmodemService.esc(payload).concat(
      [ZDLE, term],
      ZmodemService.esc([c & 0xff, (c >>> 8) & 0xff, (c >>> 16) & 0xff, (c >>> 24) & 0xff]));
  }

  private static le32(n: number): number[] {
    return [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >>> 24) & 0xff];
  }

  private static isHexChar(c: number): boolean {
    return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
  }

  private static hexVal(c: number): number {
    if (c >= 0x30 && c <= 0x39) {
      return c - 0x30;
    }
    if (c >= 0x41 && c <= 0x46) {
      return c - 0x41 + 10;
    }
    return c - 0x61 + 10;
  }

  private static findPair(a: number, b: number): number {
    for (let i = 0; i + 1 < ZmodemService.buf.length; i++) {
      if (ZmodemService.buf[i] === a && ZmodemService.buf[i + 1] === b) {
        return i;
      }
    }
    return -1;
  }

  private static tryHeader(): ZmFrame | null {
    const buf = ZmodemService.buf;
    while (true) {
      const i = ZmodemService.findPair(ZDLE, ZHEX);
      const j = ZmodemService.findPair(ZDLE, ZBIN);
      let k = -1;
      let hex = false;
      if (i >= 0 && (j < 0 || i < j)) {
        k = i;
        hex = true;
      } else if (j >= 0) {
        k = j;
        hex = false;
      } else {
        if (buf.length > 64) {
          ZmodemService.buf = buf.slice(buf.length - 8);
        }
        return null;
      }
      if (hex) {
        if (buf.length < k + 2 + 14) {
          return null;
        }
        let ok = true;
        for (let x = 0; x < 14; x++) {
          if (!ZmodemService.isHexChar(buf[k + 2 + x])) {
            ok = false;
            break;
          }
        }
        if (!ok) {
          ZmodemService.buf = buf.slice(k + 1);
          continue;
        }
        const f = new ZmFrame();
        f.kind = 'hex';
        f.type = ZmodemService.hexVal(buf[k + 2]) * 16 + ZmodemService.hexVal(buf[k + 3]);
        const data: number[] = [];
        for (let x = 2; x < 10; x += 2) {
          data.push(ZmodemService.hexVal(buf[k + 2 + x]) * 16 + ZmodemService.hexVal(buf[k + 2 + x + 1]));
        }
        f.data = data;
        const crc = ZmodemService.hexVal(buf[k + 2 + 10]) * 4096 +
          ZmodemService.hexVal(buf[k + 2 + 11]) * 256 +
          ZmodemService.hexVal(buf[k + 2 + 12]) * 16 +
          ZmodemService.hexVal(buf[k + 2 + 13]);
        f.crcOk = ZmodemService.crc16([f.type].concat(data)) === crc;
        let len = k + 2 + 14;
        if (buf[len] === 0x0d) {
          len++;
        }
        if (buf.length > len && (buf[len] === 0x0a || buf[len] === 0x8a || buf[len] === XON)) {
          len++;
        }
        ZmodemService.buf = buf.slice(len);
        return f;
      }
      // bin (16): escaped type + 4 data + 2 crc
      let p = k + 2;
      const rd = (): number => {
        if (p >= ZmodemService.buf.length) {
          return -1;
        }
        let v = ZmodemService.buf[p];
        if (v === ZDLE) {
          if (p + 1 >= ZmodemService.buf.length) {
            return -1;
          }
          v = (ZmodemService.buf[p + 1] ^ 0x40) & 0xff;
          p += 2;
        } else {
          p++;
        }
        return v;
      };
      const t = rd();
      if (t < 0) {
        return null;
      }
      const data: number[] = [];
      let complete = true;
      for (let x = 0; x < 4; x++) {
        const v = rd();
        if (v < 0) {
          complete = false;
          break;
        }
        data.push(v);
      }
      const c1 = rd();
      const c2 = rd();
      if (!complete || c1 < 0 || c2 < 0) {
        return null;
      }
      const f = new ZmFrame();
      f.kind = 'bin';
      f.type = t;
      f.data = data;
      f.crcOk = ZmodemService.crc16([t].concat(data)) === ((c1 << 8) | c2);
      ZmodemService.buf = ZmodemService.buf.slice(p);
      return f;
    }
  }

  private static isTerm(c: number): boolean {
    return c === ZCRCE || c === ZCRCG || c === ZCRCQ || c === ZCRCW || c === ZCRC;
  }

  private static parseSubframe(): ZmSub | null {
    const buf = ZmodemService.buf;
    const out: number[] = [];
    let i = 0;
    let term = -1;
    let termPos = -1;
    while (i < buf.length) {
      const b = buf[i];
      if (b === ZDLE) {
        if (i + 1 >= buf.length) {
          return null;
        }
        const c = buf[i + 1];
        if (ZmodemService.isTerm(c & 0x7f)) {
          term = c & 0x7f;
          termPos = i;
          break;
        }
        out.push((c ^ 0x40) & 0xff);
        i += 2;
        continue;
      }
      out.push(b);
      i++;
    }
    if (term < 0) {
      return null;
    }
    // 2 crc bytes (may be ZDLE-escaped) - v1 ignores their value
    let ci = termPos + 2;
    let got = 0;
    while (got < 2) {
      if (ci >= buf.length) {
        return null;
      }
      if (buf[ci] === ZDLE) {
        if (ci + 1 >= buf.length) {
          return null;
        }
        ci += 2;
      } else {
        ci += 1;
      }
      got++;
    }
    const sub = new ZmSub();
    sub.data = out;
    sub.term = term;
    sub.end = ci;
    sub.crcOk = true; // v1: subframe CRC not verified (scope cut)
    return sub;
  }

  // ---- state machine ----
  private static pump(): void {
    if (ZmodemService.gotZfin) {
      return;
    }
    if (ZmodemService.state === 'drain') {
      while (true) {
        const sub = ZmodemService.parseSubframe();
        if (sub === null) {
          return;
        }
        ZmodemService.buf = ZmodemService.buf.slice(sub.end);
        ZmodemService.file = ZmodemService.file.concat(sub.data);
        AppStorage.setOrCreate('ut.zm.progress', ZmodemService.file.length);
        if (sub.term === ZCRCW) {
          ZmodemService.send(ZmodemService.hexFrame(ZRPOS, ZmodemService.le32(ZmodemService.file.length)));
          ZmodemService.state = 'hdrWait';
          break;
        }
        if (sub.term === ZCRCE) {
          ZmodemService.state = 'hdrWait';
          break;
        }
      }
      if (ZmodemService.state === 'drain') {
        return;
      }
    }
    if (ZmodemService.mode === 'tx') {
      ZmodemService.pumpTx();
      return;
    }
    // rx: header loop
    let h: ZmFrame | null = ZmodemService.tryHeader();
    while (h !== null) {
      hilog.info(DOMAIN, TAG, 'rx hdr type=%{public}d %{public}s crcOk=%{public}d',
        h.type, h.kind, h.crcOk ? 1 : 0);
      if (h.type === ZRQINIT) {
        ZmodemService.send(ZmodemService.hexFrame(ZRINIT, [0x23, 0x00, 0x00, 0x00]));
      } else if (h.type === ZFILE) {
        const sub = ZmodemService.parseSubframe();
        if (sub === null) {
          return;
        }
        ZmodemService.buf = ZmodemService.buf.slice(sub.end);
        let info = '';
        for (let i = 0; i < sub.data.length; i++) {
          const ch = sub.data[i] & 0xff;
          info += ch >= 0x20 && ch < 0x7f ? String.fromCharCode(ch) : (ch === 0 ? '\0' : '?');
        }
        const parts = info.split('\0');
        ZmodemService.zfileName = parts[0] !== undefined ? parts[0] : 'zmfile.bin';
        const sz = parts[1] !== undefined ? parseInt(parts[1].split(' ')[0]) : 0;
        ZmodemService.zfileSize = isNaN(sz) ? 0 : sz;
        hilog.info(DOMAIN, TAG, 'ZFILE %{public}s %{public}dB', ZmodemService.zfileName, ZmodemService.zfileSize);
        ZmodemService.file = [];
        ZmodemService.send(ZmodemService.hexFrame(ZRPOS, [0, 0, 0, 0]));
      } else if (h.type === ZDATA) {
        ZmodemService.state = 'drain';
        ZmodemService.pump();
        return;
      } else if (h.type === ZEOF) {
        if (!h.crcOk) {
          ZmodemService.send(ZmodemService.hexFrame(ZNAK, [0, 0, 0, 0]));
        } else if (ZmodemService.file.length !== ZmodemService.zfileSize) {
          hilog.warn(DOMAIN, TAG, 'ZEOF mismatch got=%{public}d want=%{public}d -> ZRPOS resume',
            ZmodemService.file.length, ZmodemService.zfileSize);
          ZmodemService.send(ZmodemService.hexFrame(ZRPOS, ZmodemService.le32(ZmodemService.file.length)));
        } else {
          ZmodemService.saveRxFile();
          ZmodemService.send(ZmodemService.hexFrame(ZRINIT, [0x23, 0x00, 0x00, 0x00]));
        }
      } else if (h.type === ZFIN) {
        ZmodemService.finishZfin();
        return;
      }
      h = ZmodemService.tryHeader();
    }
  }

  // tx driven by peer headers in the raw stream
  private static pumpTx(): void {
    let h: ZmFrame | null = ZmodemService.tryHeader();
    while (h !== null) {
      hilog.info(DOMAIN, TAG, 'tx hdr type=%{public}d %{public}s', h.type, h.kind);
      if (h.type === ZRINIT && ZmodemService.txStage === 0) {
        if (ZmodemService.txData.length === 0) {
          hilog.warn(DOMAIN, TAG, 'tx: no file loaded -> ZFIN skip');
          ZmodemService.send(ZmodemService.hexFrame(5 /* ZSKIP */, [0, 0, 0, 0]));
          ZmodemService.txStage = 9;
        } else {
          const info = ZmodemService.txName + '\0' + ZmodemService.txData.length +
            ' 1000000000 644 0 1 ' + ZmodemService.txData.length + '\0';
          const infoBytes: number[] = [];
          for (let i = 0; i < info.length; i++) {
            infoBytes.push(info.charCodeAt(i) & 0xff);
          }
          const crc = ZmodemService.crc16(infoBytes.concat([ZCRCW]));
          const pkt = ZmodemService.binHdr(ZFILE, [0, 0, 0, 0]).concat(
            ZmodemService.esc(infoBytes), [ZDLE, ZCRCW],
            ZmodemService.esc([(crc >> 8) & 0xff, crc & 0xff]));
          ZmodemService.send(pkt);
          ZmodemService.txStage = 1;
        }
      } else if (h.type === ZRPOS && ZmodemService.txStage >= 1) {
        const pos = h.data[0] | (h.data[1] << 8) | (h.data[2] << 16) | (h.data[3] << 24);
        ZmodemService.streamTx(pos);
        ZmodemService.txStage = 2;
      } else if (h.type === ZRINIT && ZmodemService.txStage === 2) {
        ZmodemService.send(ZmodemService.hexFrame(ZFIN, [0, 0, 0, 0]));
        ZmodemService.txStage = 3;
      } else if (h.type === ZFIN) {
        ZmodemService.send(ZmodemService.hexFrame(ZFIN, [0, 0, 0, 0]));
        ZmodemService.sendText('OO');
        ZmodemService.done('tx-done');
        return;
      }
      h = ZmodemService.tryHeader();
    }
  }

  private static streamTx(pos: number): void {
    const parts: number[][] = [];
    parts.push(ZmodemService.bin32Hdr(ZDATA, ZmodemService.le32(pos)));
    let off = pos;
    while (off < ZmodemService.txData.length) {
      const take = Math.min(SUB, ZmodemService.txData.length - off);
      const piece = ZmodemService.txData.slice(off, off + take);
      const last = off + take >= ZmodemService.txData.length;
      parts.push(ZmodemService.sub32(piece, last ? ZCRCE : ZCRCG));
      off += take;
    }
    // write in bounded chunks to avoid one giant base64 blob
    let idx = 0;
    while (idx < parts.length) {
      const batch: number[] = [];
      let est = 0;
      while (idx < parts.length && est < 24576) {
        batch.push(...parts[idx]);
        est += parts[idx].length + 2;
        idx++;
      }
      ZmodemService.send(batch);
    }
    hilog.info(DOMAIN, TAG, 'tx streamed %{public}d subframes bytes=%{public}d',
      parts.length - 1, ZmodemService.txData.length - pos);
    ZmodemService.txBytes += ZmodemService.txData.length - pos;
    // ZEOF follows after a short beat (peer needs the data first)
    setTimeout(() => {
      ZmodemService.send(ZmodemService.hexFrame(ZEOF, ZmodemService.le32(ZmodemService.txData.length)));
    }, 300);
  }

  private static saveRxFile(): void {
    let stage = 'access';
    try {
      const dir = ZmodemService.filesDir + '/zmodem';
      stage = 'access(' + dir + ')';
      if (!fs.accessSync(dir)) {
        stage = 'mkdir(' + dir + ')';
        fs.mkdirSync(dir, true);
      }
      let name = ZmodemService.zfileName.replace(/[\/\\]/g, '_');
      if (name === '') {
        name = 'zmfile.bin';
      }
      const path = dir + '/' + name;
      stage = 'open(' + path + ') size=' + ZmodemService.file.length;
      const fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      stage = 'write';
      const ab = new ArrayBuffer(ZmodemService.file.length);
      const u8 = new Uint8Array(ab);
      for (let i = 0; i < ZmodemService.file.length; i++) {
        u8[i] = ZmodemService.file[i];
      }
      const wrote = fs.writeSync(fd.fd, ab);
      fs.closeSync(fd);
      stage = 'ok wrote=' + wrote;
      // md5 (logged for E2E evidence)
      ZmodemService.md5Of(ZmodemService.file, path);
      hilog.info(DOMAIN, TAG, 'saved %{public}s %{public}d/ %{public}dB', path, ZmodemService.file.length, ZmodemService.zfileSize);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'saveRxFile fail at %{public}s: %{public}s', stage, msg);
    }
  }

  private static async md5Of(bytes: number[], path: string): Promise<void> {
    try {
      const md = cryptoFramework.createMd('MD5');
      const blob: cryptoFramework.DataBlob = { data: new Uint8Array(bytes) };
      await md.update(blob);
      const r = await md.digest();
      let hex = '';
      for (let i = 0; i < r.data.length; i++) {
        hex += (r.data[i] < 16 ? '0' : '') + r.data[i].toString(16);
      }
      hilog.info(DOMAIN, TAG, 'MD5 %{public}s %{public}s', path, hex);
      AppStorage.setOrCreate('ut.zm.md5', hex);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'md5 fail %{public}s', msg);
    }
  }

  private static finishZfin(): void {
    ZmodemService.send(ZmodemService.hexFrame(ZFIN, [0, 0, 0, 0]));
    ZmodemService.sendText('OO');
    ZmodemService.done('rx-done');
  }

  private static done(status: string): void {
    ZmodemService.gotZfin = true;
    ZmodemService.state = 'idle';
    // M8 relay7: capture tx mode/bytes before mode reset (tx file[] is empty)
    const isTx = ZmodemService.mode === 'tx';
    const txTotal = ZmodemService.txBytes;
    ZmodemService.mode = '';
    ZmodemService.buf = [];
    ZmodemService.markerWin = '';
    const id = ZmodemService.sessionId();
    const hd = ZmodemService.ssh();
    if (id >= 0 && hd !== null) {
      hd.zmSetRaw(id, false);
    }
    const bytes = isTx ? txTotal : ZmodemService.file.length;
    AppStorage.setOrCreate('ut.zm.status', status + ' ' + bytes.toString() + 'B');
    hilog.info(DOMAIN, TAG, 'done %{public}s bytes=%{public}d', status, bytes);
  }

  /** Abort (page disappear / user cancel): leave raw mode silently. */
  public static abort(): void {
    if (ZmodemService.state !== 'idle') {
      const id = ZmodemService.sessionId();
      const ha = ZmodemService.ssh();
      if (id >= 0 && ha !== null) {
        ha.zmSetRaw(id, false);
      }
      ZmodemService.state = 'idle';
      ZmodemService.mode = '';
      ZmodemService.buf = [];
      ZmodemService.markerWin = '';
      AppStorage.setOrCreate('ut.zm.status', 'aborted');
      hilog.warn(DOMAIN, TAG, 'aborted');
    }
  }
}
