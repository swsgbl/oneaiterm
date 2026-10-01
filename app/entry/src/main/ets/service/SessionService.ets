/**
 * upstream M2 relay-4 - terminal session service (ArkTS side).
 *
 * Owns the single native session (M2 scope: one terminal at a time) and the
 * global event dispatcher. The native event callback is a process-wide
 * singleton threadsafe function (terminal_napi.cpp InitGlobalTsfn: the
 * callback passed to the FIRST sessionOpenWithPassword wins for the whole
 * process), so this service always passes the same static dispatcher and
 * fans events out by session id.
 *
 * relay-4: the view contract is one method accept(raw: string) so the page
 * can plug either the legacy line-stream view or the ANSI TermModel bridge;
 * stats() exposes chunks/bytes/lines plus a write->first-data latency probe
 * used by the performance acceptance (hilog-timestamped, no estimates).
 *
 * UI state is published through AppStorage keys:
 *   ut.term.status  idle|connecting|connected|disconnected|error
 *   ut.term.title   header text
 *   ut.term.reason  last error text (verbatim libssh message on auth fail)
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import type { TermModel } from '../components/TermModel';
import { libssh } from '@ohos/libssh';
import { ConnRec } from '../store/ConnStore';
import { IdentityStore, MaterializedCreds } from '../store/IdentityStore';

/** Local mirror of the native event shape (HAR Index only re-exports libssh). */
interface TermEvent {
  type: string;
  id: number;
  chunk?: string;
  reason?: string;
  message?: string;
  authMethod?: string;
}

const TAG: string = 'oat.session';
const DOMAIN: number = 0x0110;

/** Anything that can receive decoded ssh output bytes. */
export interface TermView {
  accept(raw: string): void;
  /** AI Agent 桥:暴露底层 TermModel(无则 null)。 */
  modelOf(): TermModel | null;
}

/** Snapshot of throughput counters (all values measured, never estimated). */
export class TermStats {
  chunks: number = 0;
  bytes: number = 0;
  lines: number = 0;
  lastCmdMs: number = -1;
}

/**
 * Single-terminal session service. All state is static: M2 keeps at most one
 * live session; the UI talks to it through AppStorage + the attached view.
 */
export class SessionService {
  private static ssh: libssh | null = null;
  private static sessionId: number = -1;
  private static dataChunks: number = 0;
  private static dataBytes: number = 0;
  private static dataLines: number = 0;
  private static view: TermView | null = null;
  private static label: string = '';
  private static writeMs: number = -1; // perf marker: last write timestamp
  private static firstDataMs: number = -1; // perf marker: first data after it
  /** M3: auth method actually used by the last connect ("publickey"/"password"). */
  private static lastAuth: string = '';
  /** M3 relay-2: shared identity store for materializing identity connections. */
  private static identities: IdentityStore | null = null;

  /** Register the process-wide identity store (called by ConnList on load). */
  public static setIdentities(ids: IdentityStore | null): void {
    SessionService.identities = ids;
  }

  /** TerminalPage registers its view on appear, clears it on disappear. */
  public static attachView(v: TermView | null): void {
    SessionService.view = v;
  }

  /** Global dispatcher - MUST be the callback of the first open (see header). */
  private static onEvent(ev: TermEvent): void {
    if (ev.type === 'auth') {
      // M3: native reports which auth method succeeded (id is -1 here)
      SessionService.lastAuth = (ev.authMethod === undefined || ev.authMethod === null) ? '' : ev.authMethod;
      hilog.info(DOMAIN, TAG, 'auth method=%{public}s', SessionService.lastAuth);
      return;
    }
    if (ev.id !== SessionService.sessionId) {
      hilog.warn(DOMAIN, TAG, 'stale event type=%{public}s id=%{public}d cur=%{public}d',
        ev.type, ev.id, SessionService.sessionId);
      return;
    }
    if (ev.type === 'data') {
      let chunk = ev.chunk;
      if (chunk === undefined || chunk === null) {
        chunk = '';
      }
      SessionService.dataChunks++;
      SessionService.dataBytes += chunk.length;
      SessionService.dataLines += countLf(chunk);
      if (SessionService.writeMs >= 0 && SessionService.firstDataMs < 0) {
        SessionService.firstDataMs = nowMs();
      }
      const v = SessionService.view;
      if (v !== null) {
        v.accept(chunk);
      }
      if (SessionService.dataChunks % 50 === 1) {
        hilog.info(DOMAIN, TAG, 'data chunks=%{public}d bytes=%{public}d lines=%{public}d',
          SessionService.dataChunks, SessionService.dataBytes, SessionService.dataLines);
      }
      return;
    }
    if (ev.type === 'closed') {
      let reason = ev.reason;
      if (reason === undefined || reason === null) {
        reason = '';
      }
      const cur = AppStorage.get<string>('ut.term.status');
      if (cur !== 'error') {
        AppStorage.setOrCreate('ut.term.status', 'disconnected');
      }
      hilog.info(DOMAIN, TAG, 'closed id=%{public}d reason=%{public}s chunks=%{public}d bytes=%{public}d',
        ev.id, reason, SessionService.dataChunks, SessionService.dataBytes);
      return;
    }
    if (ev.type === 'error') {
      let msg = ev.message;
      if (msg === undefined || msg === null) {
        msg = 'unknown session error';
      }
      AppStorage.setOrCreate('ut.term.status', 'error');
      AppStorage.setOrCreate('ut.term.reason', msg);
      hilog.error(DOMAIN, TAG, 'error id=%{public}d msg=%{public}s', ev.id, msg);
    }
  }

  /**
   * Open the session. authType=password goes through the native terminal
   * channel with password auth; authType=keyText passes the PEM text +
   * passphrase (config.Password doubles as the passphrase, upstream
   * parseAuthKeySigner semantics) and prefers publickey with password
   * fallback; authType=key reads the key file at keyPath (sandbox path) the
   * same way. On failure the AppStorage status becomes 'error' and the
   * reason holds the verbatim libssh error string.
   */
  /** M3-3a: active connection's backspaceKey mode ('del'|'bs'|'vt220'). */
  private static backspaceKey: string = 'del';

  public static async connect(conn: ConnRec, cols: number, rows: number): Promise<number> {
    // M3 relay-2: materialize identity references (upstream MaterializeIdentity):
    // override user + inject credentials from the referenced identity.
    const mat = SessionService.identities;
    if (conn.authType === 'identity') {
      if (mat === null) {
        throw new Error('身份库未初始化,无法解析 identity 连接');
      }
      const resolved = mat.materialize(conn.authType, conn.identityId);
      if (resolved === null) {
        throw new Error('身份缺失: ' + conn.identityId + ' 不存在,请改绑身份');
      }
      conn = materializeConn(conn, resolved);
      hilog.info(DOMAIN, TAG, 'identity materialized id=%{public}s -> auth=%{public}s user=%{public}s',
        conn.identityId, conn.authType, conn.user);
    }
    SessionService.ssh = new libssh();
    SessionService.backspaceKey = conn.backspaceKey;
    SessionService.sessionId = -1;
    SessionService.dataChunks = 0;
    SessionService.dataBytes = 0;
    SessionService.dataLines = 0;
    SessionService.writeMs = -1;
    SessionService.firstDataMs = -1;
    SessionService.lastAuth = '';
    SessionService.label = conn.name + ' ' + conn.user + '@' + conn.host + ':' + conn.port.toString();
    AppStorage.setOrCreate('ut.term.status', 'connecting');
    AppStorage.setOrCreate('ut.term.reason', '');
    hilog.info(DOMAIN, TAG, 'connect %{public}s cols=%{public}d rows=%{public}d auth=%{public}s pwlen=%{public}d keylen=%{public}d',
      SessionService.label, cols, rows, conn.authType, conn.password.length, conn.keyContent.length);
    try {
      const cb = (ev: TermEvent): void => {
        SessionService.onEvent(ev);
      };
      let id: number;
      if (conn.authType === 'keyText' || conn.authType === 'key') {
        let pem: string = '';
        if (conn.authType === 'keyText') {
          pem = conn.keyContent;
        } else {
          pem = readKeyFile(conn.keyPath);
          if (pem === '') {
            throw new Error('read key file failed: ' + conn.keyPath);
          }
        }
        id = await SessionService.ssh.sessionOpenWithKey(
          conn.host, conn.port, conn.user, conn.password, pem, conn.password, cols, rows, cb,
          conn.encoding, conn.keepaliveSec);
      } else if (conn.authType === 'password') {
        id = await SessionService.ssh.sessionOpenWithPassword(
          conn.host, conn.port, conn.user, conn.password, cols, rows, cb,
          conn.encoding, conn.keepaliveSec);
      } else {
        throw new Error('authType=' + conn.authType + ' not supported yet');
      }
      SessionService.sessionId = id;
      AppStorage.setOrCreate('ut.term.status', 'connected');
      hilog.info(DOMAIN, TAG, 'connect ok id=%{public}d auth=%{public}s %{public}s',
        id, SessionService.lastAuth, SessionService.label);
      return id;
    } catch (e) {
      SessionService.sessionId = -1;
      const msg = (e instanceof Error) ? e.message : JSON.stringify(e);
      AppStorage.setOrCreate('ut.term.status', 'error');
      AppStorage.setOrCreate('ut.term.reason', msg);
      hilog.error(DOMAIN, TAG, 'connect FAIL %{public}s err=%{public}s', SessionService.label, msg);
      const re = e instanceof Error ? e : new Error(JSON.stringify(e));
      throw re;
    }
  }

  /**
   * Write text to the remote stdin. Returns bytes written, -1 on failure.
   * Marks the perf probe window (write -> first data chunk).
   */
  public static write(text: string): number {
    if (SessionService.ssh === null || SessionService.sessionId < 0) {
      hilog.warn(DOMAIN, TAG, 'write ignored: no session');
      return -1;
    }
    const wire = SessionService.applyBackspaceKey(text);
    const n = SessionService.ssh.writeStdin(SessionService.sessionId, wire);
    if (n >= 0) {
      SessionService.writeMs = nowMs();
      SessionService.firstDataMs = -1;
    }
    hilog.info(DOMAIN, TAG, 'write bytes=%{public}d asked=%{public}d', n, text.length);
    return n;
  }

  /**
   * M3-3a: apply the per-host backspaceKey mapping, mirroring upstream
   * frontend/src/utils/backspaceKey.ts: the OS keyboard delivers 0x7F (DEL);
   * hosts configured 'bs' receive 0x08, 'vt220' receives ESC[3~.
   */
  private static applyBackspaceKey(text: string): string {
    if (SessionService.backspaceKey === 'del' || text.indexOf('\x7f') < 0) {
      return text;
    }
    let out = '';
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === '\x7f') {
        out += (SessionService.backspaceKey === 'bs') ? '\x08' : '\x1b[3~';
      } else {
        out += ch;
      }
    }
    return out;
  }

  /** Resize the remote pty. Returns 0 on success. */
  public static resize(cols: number, rows: number): number {
    if (SessionService.ssh === null || SessionService.sessionId < 0) {
      return -1;
    }
    const rc = SessionService.ssh.resizePty(SessionService.sessionId, cols, rows);
    hilog.info(DOMAIN, TAG, 'resize %{public}dx%{public}d rc=%{public}d', cols, rows, rc);
    return rc;
  }

  /** Measured counters for the status bar / acceptance report. */
  public static stats(): TermStats {
    const st = new TermStats();
    st.chunks = SessionService.dataChunks;
    st.bytes = SessionService.dataBytes;
    st.lines = SessionService.dataLines;
    if (SessionService.writeMs >= 0 && SessionService.firstDataMs >= 0) {
      st.lastCmdMs = SessionService.firstDataMs - SessionService.writeMs;
    }
    return st;
  }

  /** M3: which auth method the last successful connect used. */
  public static authMethod(): string {
    return SessionService.lastAuth;
  }

  /** M3 relay-3b: live ssh libssh handle (for SFTP on the same session). */
  public static sshHandle(): libssh | null {
    return SessionService.ssh;
  }

  /** Telnet/RawTCP 外部数据注入口:直通终端视图(TelnetService 用)。 */
  public static feedExternal(chunk: string): void {
    const v = SessionService.view;
    if (v !== null) {
      v.accept(chunk);
    }
  }

  /** AI Agent 用:是否有活动 SSH 会话。 */
  public static hasSession(): boolean {
    return SessionService.ssh !== null && SessionService.sessionId >= 0;
  }

  /** AI Agent 用:终端屏幕文本(供模型阅读)。 */
  public static screenText(maxLen: number): string {
    const v = SessionService.view;
    if (v === null) {
      return '';
    }
    const m = v.modelOf();
    if (m === null) {
      return '';
    }
    let out = '';
    const start = Math.max(0, m.lines.length - m.rows);
      for (let i = start; i < m.lines.length; i++) {
      const ln = m.lines[i];
      let s = '';
      for (let c = 0; c < ln.cells.length; c++) {
        s += ln.cells[c].char;
      }
      out += s.replace(/\s+$/, '');
      out += '\n';
    }
    if (out.length > maxLen) {
      out = out.substring(out.length - maxLen);
    }
    return out;
  }

  /** M3 relay-3b: current native session id (-1 when closed). */
  public static getSessionId(): number {
    return SessionService.sessionId;
  }

  /** Close the session and free native resources (local close). */
  public static close(): void {
    const id = SessionService.sessionId;
    SessionService.sessionId = -1;
    if (SessionService.ssh !== null && id >= 0) {
      hilog.info(DOMAIN, TAG, 'close id=%{public}d', id);
      SessionService.ssh.closeSession(id);
    }
    AppStorage.setOrCreate('ut.term.status', 'disconnected');
    hilog.info(DOMAIN, TAG, 'closed locally chunks=%{public}d bytes=%{public}d',
      SessionService.dataChunks, SessionService.dataBytes);
  }
}

function countLf(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) === 10) {
      n++;
    }
  }
  return n;
}

/** M3 relay-2: apply resolved identity credentials onto a copy of the conn. */
function materializeConn(conn: ConnRec, r: MaterializedCreds): ConnRec {
  const out = new ConnRec();
  out.id = conn.id;
  out.name = conn.name;
  out.remark = conn.remark;
  out.type = conn.type;
  out.host = conn.host;
  out.port = conn.port;
  out.user = r.user;
  out.authType = r.authType;
  out.identityId = conn.identityId;
  out.password = r.password;
  out.keyPath = r.keyPath;
  out.keyContent = r.keyContent;
  out.groupId = conn.groupId;
  out.encoding = conn.encoding;
  out.backspaceKey = conn.backspaceKey;
  out.initialCols = conn.initialCols;
  out.initialRows = conn.initialRows;
  out.postLoginScript = conn.postLoginScript;
  out.logOnConnect = conn.logOnConnect;
  out.tunnelSSHConnId = conn.tunnelSSHConnId;
  out.proxyId = conn.proxyId;
  return out;
}

/** Read a PEM private key file from the app sandbox (authType=key). Empty on failure. */
function readKeyFile(path: string): string {
  try {
    return fileIo.readTextSync(path, { encoding: 'utf-8' });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'readKeyFile fail %{public}s err=%{public}s', path, JSON.stringify(e));
    return '';
  }
}

function nowMs(): number {
  return Date.now();
}
