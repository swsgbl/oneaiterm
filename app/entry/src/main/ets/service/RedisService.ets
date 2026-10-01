// Redis 客户端:RESP 协议(@ohos.net.socket 纯 TS 实现,无 C++ 依赖)
// 官方 DatabaseTab→Redis 子集:命令执行 + 简单响应解析
import socket from '@ohos.net.socket';

export class RedisService {
  private static sock: socket.TCPSocket | null = null
  private static buf: string = ''

  static active(): boolean {
    return RedisService.sock !== null
  }

  static async connect(host: string, port: number): Promise<void> {
    if (RedisService.sock !== null) {
      await RedisService.close()
    }
    const s = socket.constructTCPSocketInstance()
    s.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message)
      let chunk = ''
      for (let i = 0; i < u8.length; i++) {
        chunk += String.fromCharCode(u8[i])
      }
      RedisService.buf += chunk
    })
    await s.connect({ address: { address: host, port: port }, timeout: 10 }) // r6k 回退实证值
    RedisService.sock = s
  }

  static async close(): Promise<void> {
    const s = RedisService.sock
    RedisService.sock = null
    if (s !== null) {
      try {
        s.close()
      } catch (e) {
      }
    }
  }

  /** 执行一条命令(PING/GET/SET/INFO...),返回 RESP 解析文本 */
  static async exec(cmd: string): Promise<string> {
    const s = RedisService.sock
    if (s === null) {
      throw new Error('未连接')
    }
    // 编码:RESP 数组 *N\r\n$len\r\narg\r\n...
    const parts = cmd.trim().split(/\s+/)
    let wire = '*' + parts.length.toString() + '\r\n'
    for (const p of parts) {
      wire += '$' + p.length.toString() + '\r\n' + p + '\r\n'
    }
    const enc = new Uint8Array(wire.length)
    for (let i = 0; i < wire.length; i++) {
      enc[i] = wire.charCodeAt(i) & 0xff
    }
    RedisService.buf = ''
    await s.send({ data: enc.buffer })
    // 等响应(轮询 buf,最多 3s;r6l 回退 r6h 形态)
    for (let i = 0; i < 30; i++) {
      await RedisService.sleep(100)
      if (RedisService.tryParse() !== null) {
        const r = RedisService.tryParse()
        if (r !== null) {
          return r
        }
      }
    }
    throw new Error('超时(响应: ' + RedisService.buf.substring(0, 200) + ')')
  }

  private static tryParse(): string | null {
    const b = RedisService.buf
    if (b.length === 0) {
      return null
    }
    const t = b[0]
    const nl = b.indexOf('\r\n')
    if (nl < 0) {
      return null
    }
    const head = b.substring(1, nl)
    if (t === '+' || t === '-' || t === ':') {
      return (t === '-' ? '(error) ' : '') + head
    }
    if (t === '$') {
      const len = parseInt(head)
      if (isNaN(len)) {
        return null
      }
      if (len < 0) {
        return '(nil)'
      }
      if (b.length < nl + 2 + len + 2) {
        return null // 未收全
      }
      return b.substring(nl + 2, nl + 2 + len)
    }
    if (t === '*') {
      const n = parseInt(head)
      if (isNaN(n)) {
        return null
      }
      if (n < 0) {
        return '(nil)'
      }
      // 逐项解析(简化:递归消费 buf)
      let rest = b.substring(nl + 2)
      const lines: string[] = []
      for (let i = 0; i < n; i++) {
        if (rest.length === 0) {
          return null
        }
        const t2 = rest[0]
        const nl2 = rest.indexOf('\r\n')
        if (nl2 < 0) {
          return null
        }
        const h2 = rest.substring(1, nl2)
        if (t2 === ':' || t2 === '+' || t2 === '-') {
          lines.push(h2)
          rest = rest.substring(nl2 + 2)
        } else if (t2 === '$') {
          const l2 = parseInt(h2)
          if (isNaN(l2) || rest.length < nl2 + 2 + l2 + 2) {
            return null
          }
          lines.push(l2 < 0 ? '(nil)' : rest.substring(nl2 + 2, nl2 + 2 + l2))
          rest = rest.substring(nl2 + 2 + l2 + 2)
        } else {
          lines.push(rest.substring(0, nl2))
          rest = rest.substring(nl2 + 2)
        }
      }
      return lines.join('\n')
    }
    return b // 非标准(inline reply)
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>(resolve => setTimeout(resolve, ms))
  }
}
