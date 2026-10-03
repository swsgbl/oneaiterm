// MySQL 客户端:wire 协议纯 TS(@ohos.net.socket + cryptoFramework SHA1)
// 子集:handshake v10 / mysql_native_password / COM_QUERY 文本结果集
// hilog tag: oat.mysql(域 0x0112)供 E2E 断言
import socket from '@ohos.net.socket';
import cryptoFramework from '@ohos.security.cryptoFramework';
import hilog from '@ohos.hilog';

const TAG: string = 'oat.mysql';
const DOMAIN: number = 0x0112;

export class MySqlService {
  private static sock: socket.TCPSocket | null = null
  private static pending: number[] = []
  private static seq: number = 0

  static active(): boolean {
    return MySqlService.sock !== null
  }

  static async connect(host: string, port: number, user: string, password: string, db: string): Promise<void> {
    if (MySqlService.sock !== null) {
      await MySqlService.close()
    }
    MySqlService.pending = []
    MySqlService.seq = 0
    hilog.info(DOMAIN, TAG, 'connect begin host=%{public}s port=%{public}d user=%{public}s db=%{public}s',
      host, port, user, db)
    const s = socket.constructTCPSocketInstance()
    s.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message)
      for (let i = 0; i < u8.length; i++) {
        MySqlService.pending.push(u8[i])
      }
    })
    try {
      await s.connect({ address: { address: host, port: port }, timeout: 10 })
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      hilog.error(DOMAIN, TAG, 'tcp connect FAIL %{public}s:%{public}d err=%{public}s', host, port, msg)
      throw new Error('TCP 连接失败: ' + host + ':' + port.toString() + ' ' + msg)
    }
    MySqlService.sock = s
    // ===== 读 server handshake =====
    const hs = await MySqlService.readPacket()
    if (hs.length === 0 || hs[0] === 0xff) {
      throw new Error(MySqlService.parseErr(hs))
    }
    if (hs[0] !== 10) {
      throw new Error('不支持的协议版本 ' + hs[0].toString())
    }
    let p = 1
    while (p < hs.length && hs[p] !== 0) {
      p++ // server version
    }
    p += 1 + 4 // null + thread id
    const salt1 = MySqlService.sliceBytes(hs, p, 8)
    p += 8 + 1 // salt1 + filler
    p += 2 + 1 + 2 // caps lower, charset, status
    const capsUpper = MySqlService.readU16At(hs, p)
    p += 2
    const authLen = hs[p]
    p += 1 + 10 // auth len + reserved
    let salt2Len = Math.max(13, authLen - 8) - 1
    if (salt2Len < 0) {
      salt2Len = 12
    }
    const salt2 = MySqlService.sliceBytes(hs, p, salt2Len)
    hilog.info(DOMAIN, TAG, 'handshake v10 capsUpper=%{public}d authLen=%{public}d', capsUpper, authLen)
    // ===== 客户端认证包 =====
    // 只声明最小能力集,不回声服务器高位能力:
    // LONG_PASSWORD|PROTOCOL_41|SECURE_CONNECTION|PLUGIN_AUTH(+CONNECT_WITH_DB)
    const caps = 0x00000001 | 0x00000200 | 0x00008000 | 0x00080000 | (db !== '' ? 0x00000008 : 0)
    const authResp = await MySqlService.nativePassword(password, MySqlService.concat(salt1, salt2))
    const body: number[] = []
    MySqlService.pushU32(body, caps)
    MySqlService.pushU32(body, 16777216)
    body.push(33) // utf8
    for (let i = 0; i < 23; i++) {
      body.push(0)
    }
    MySqlService.pushCStr(body, user)
    body.push(authResp.length)
    for (let i = 0; i < authResp.length; i++) {
      body.push(authResp[i])
    }
    if (db !== '') {
      MySqlService.pushCStr(body, db)
    }
    MySqlService.pushCStr(body, 'mysql_native_password')
    await MySqlService.writePacket(body)
    // ===== 认证结果循环 =====
    for (;;) {
      const r = await MySqlService.readPacket()
      if (r.length === 0) {
        continue
      }
      if (r[0] === 0x00) {
        hilog.info(DOMAIN, TAG, 'auth OK user=%{public}s db=%{public}s', user, db)
        return // OK
      }
      if (r[0] === 0xff) {
        const em = MySqlService.parseErr(r)
        hilog.error(DOMAIN, TAG, 'auth FAIL %{public}s', em)
        throw new Error(em)
      }
      if (r[0] === 0xfe) {
        // AuthSwitchRequest: plugin name CStr + new salt(定长读入常带尾部 NUL,剥掉再算 scramble)
        let q = 1
        let plugin = ''
        while (q < r.length && r[q] !== 0) {
          plugin += String.fromCharCode(r[q])
          q++
        }
        q++
        let newSalt = MySqlService.sliceBytes(r, q, r.length - q)
        let end = newSalt.length - 1
        while (end >= 0 && newSalt[end] === 0) {
          end--
        }
        newSalt = newSalt.slice(0, end + 1)
        hilog.info(DOMAIN, TAG, 'authswitch plugin=%{public}s saltLen=%{public}d', plugin, newSalt.length)
        const resp2 = await MySqlService.nativePassword(password, newSalt)
        const b2: number[] = []
        for (let i = 0; i < resp2.length; i++) {
          b2.push(resp2[i])
        }
        await MySqlService.writePacket(b2)
        continue
      }
      if (r[0] === 0x01) {
        continue // AuthMoreData
      }
    }
  }

  /** COM_QUERY,渲染文本结果集 */
  static async query(sql: string): Promise<string> {
    if (MySqlService.sock === null) {
      throw new Error('未连接')
    }
    hilog.info(DOMAIN, TAG, 'query sql=%{public}s', sql)
    MySqlService.seq = 0 // 每条新命令序号从 0 起
    const body: number[] = [0x03]
    for (let i = 0; i < sql.length; i++) {
      body.push(sql.charCodeAt(i) & 0xff)
    }
    await MySqlService.writePacket(body)
    const first = await MySqlService.readPacket()
    if (first.length === 0) {
      return ''
    }
    if (first[0] === 0xff) {
      throw new Error(MySqlService.parseErr(first))
    }
    if (first[0] === 0x00) {
      // OK packet: affected rows
      let q = 1
      const ar = MySqlService.lenenc(first, q)
      q = ar.next
      const li = MySqlService.lenenc(first, q)
      return 'OK,受影响行数 ' + ar.value.toString() + (li.value > 0 ? ',last id ' + li.value.toString() : '')
    }
    // 列数
    const cn = MySqlService.lenenc(first, 0)
    const nCols = cn.value
    const lines: string[] = []
    // 列定义(取第5个 lenenc 字段名)
    for (let c = 0; c < nCols; c++) {
      const def = await MySqlService.readPacket()
      let q = 0
      for (let f = 0; f < 5; f++) {
        const l = MySqlService.lenenc(def, q)
        if (f === 4) {
          lines.push(MySqlService.bytesText(MySqlService.sliceBytes(def, l.next, l.value)))
        }
        q = l.next + l.value
      }
    }
    // 消费列定义后的 EOF 包(不消费则后续行全乱 → 空结果)
    const eof1 = await MySqlService.readPacket()
    if (eof1.length > 0 && eof1[0] === 0xff) {
      throw new Error(MySqlService.parseErr(eof1))
    }
    lines.push('')
    // 行(直到 EOF 0xfe / ERR 0xff)
    let nRows = 0
    for (;;) {
      const row = await MySqlService.readPacket()
      if (row.length === 0) {
        continue
      }
      if (row[0] === 0xff) {
        throw new Error(MySqlService.parseErr(row))
      }
      if (row[0] === 0xfe && row.length < 9) {
        hilog.info(DOMAIN, TAG, 'result cols=%{public}d rows=%{public}d', nCols, nRows)
        return lines.join('\n')
      }
      const vals: string[] = []
      let q = 0
      while (q < row.length) {
        if (row[q] === 0xfb) {
          vals.push('NULL')
          q++
        } else {
          const l = MySqlService.lenenc(row, q)
          vals.push(MySqlService.bytesText(MySqlService.sliceBytes(row, l.next, l.value)))
          q = l.next + l.value
        }
      }
      lines.push(vals.join(' | '))
      nRows++
    }
  }

  static async close(): Promise<void> {
    const s = MySqlService.sock
    MySqlService.sock = null
    if (s !== null) {
      try {
        s.close()
      } catch (e) {
      }
    }
    hilog.info(DOMAIN, TAG, 'closed')
  }

  // ===== 帧:3字节长度+1字节序号 =====
  private static async readPacket(): Promise<number[]> {
    for (let i = 0; i < 200; i++) {
      if (MySqlService.pending.length >= 4) {
        const len = MySqlService.pending[0] | MySqlService.pending[1] << 8 | MySqlService.pending[2] << 16
        if (MySqlService.pending.length >= 4 + len) {
          // 响应帧序号 = 收到的服务器帧序号 + 1(原实现自增导致 off-by-one)
          MySqlService.seq = (MySqlService.pending[3] + 1) & 0xff
          MySqlService.pending.splice(0, 4)
          return MySqlService.pending.splice(0, len)
        }
      }
      await MySqlService.sleep(30)
    }
    throw new Error('超时等待服务器响应')
  }

  private static async writePacket(body: number[]): Promise<void> {
    const s = MySqlService.sock
    if (s === null) {
      throw new Error('未连接')
    }
    const len = body.length
    const frame = new Uint8Array(4 + len)
    frame[0] = len & 0xff
    frame[1] = (len >> 8) & 0xff
    frame[2] = (len >> 16) & 0xff
    frame[3] = MySqlService.seq & 0xff
    MySqlService.seq++
    for (let i = 0; i < len; i++) {
      frame[4 + i] = body[i] & 0xff
    }
    MySqlService.pending = []
    await s.send({ data: frame.buffer })
  }

  private static async nativePassword(pw: string, salt: Uint8Array): Promise<Uint8Array> {
    // SHA1(pw) XOR SHA1(salt + SHA1(SHA1(pw)))
    if (pw === '') {
      return new Uint8Array(0)
    }
    const s1 = await MySqlService.sha1(MySqlService.strBytes(pw))
    const s2 = await MySqlService.sha1(s1)
    const salted = MySqlService.concat(salt, s2)
    const s3 = await MySqlService.sha1(salted)
    const out = new Uint8Array(s1.length)
    for (let i = 0; i < s1.length; i++) {
      out[i] = s1[i] ^ s3[i]
    }
    return out
  }

  private static async sha1(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA1')
    const blob: cryptoFramework.DataBlob = { data: data }
    await md.update(blob)
    const out = await md.digest()
    return out.data
  }

  private static lenenc(b: number[], off: number): LenOut {
    const r = new LenOut()
    const v = b[off]
    if (v < 0xfb) {
      r.value = v
      r.next = off + 1
    } else if (v === 0xfc) {
      r.value = b[off + 1] | b[off + 2] << 8
      r.next = off + 3
    } else {
      r.value = b[off + 1] | b[off + 2] << 8 | b[off + 3] << 16
      r.next = off + 4
    }
    return r
  }

  private static readU16At(b: number[], off: number): number {
    return b[off] | b[off + 1] << 8
  }

  private static pushU32(a: number[], v: number): void {
    a.push(v & 0xff)
    a.push((v >> 8) & 0xff)
    a.push((v >> 16) & 0xff)
    a.push((v >> 24) & 0xff)
  }

  private static pushCStr(a: number[], s: string): void {
    for (let i = 0; i < s.length; i++) {
      a.push(s.charCodeAt(i) & 0xff)
    }
    a.push(0)
  }

  private static sliceBytes(b: number[], off: number, len: number): Uint8Array {
    const out = new Uint8Array(len)
    for (let i = 0; i < len; i++) {
      out[i] = b[off + i]
    }
    return out
  }

  private static bytesText(b: Uint8Array): string {
    let s = ''
    for (let i = 0; i < b.length; i++) {
      s += String.fromCharCode(b[i])
    }
    return s
  }

  private static strBytes(s: string): Uint8Array {
    const out = new Uint8Array(s.length)
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff
    }
    return out
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length)
    out.set(a, 0)
    out.set(b, a.length)
    return out
  }

  private static parseErr(p: number[]): string {
    if (p.length >= 3 && p[0] === 0xff) {
      const code = p[1] | p[2] << 8
      let msg = ''
      let start = 3
      if (p.length > 9 && p[3] === 35) {
        start = 9 // #sqlstate
      }
      for (let i = start; i < p.length; i++) {
        msg += String.fromCharCode(p[i])
      }
      return 'ERROR ' + code.toString() + ': ' + msg
    }
    return '未知错误'
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>(resolve => setTimeout(resolve, ms))
  }
}

class LenOut {
  value: number = 0
  next: number = 0
}
