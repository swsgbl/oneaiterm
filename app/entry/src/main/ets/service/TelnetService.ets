// Telnet / Raw TCP 会话服务(@ohos.net.socket)
// 复用 TermModel 终端渲染:数据 → SessionService 注入视图;输入 → socket send
import socket from '@ohos.net.socket';
import { SessionService } from './SessionService';

export type TelKind = 'telnet' | 'raw';

interface RawSession {
  sock: socket.TCPSocket
  kind: TelKind
  host: string
  port: number
}

export class TelnetService {
  private static cur: RawSession | null = null;

  static active(): boolean {
    return TelnetService.cur !== null
  }

  static async connect(kind: TelKind, host: string, port: number): Promise<void> {
    if (TelnetService.cur !== null) {
      await TelnetService.disconnect()
    }
    const sock = socket.constructTCPSocketInstance()
    const s: RawSession = { sock: sock, kind: kind, host: host, port: port }
    TelnetService.cur = s
    sock.on('message', (info: socket.SocketMessageInfo) => {
      // telnet: 交互协商字节(IAC...)过滤掉,保留可打印负载;raw: 原样
      const raw = info.message
      const u8 = new Uint8Array(raw)
      const data = kind === 'telnet' ? TelnetService.stripIac(raw) : u8
      if (data.byteLength > 0) {
        const text = TelnetService.decode(data)
        if (text !== '') {
          SessionService.feedExternal(text)
        }
      }
    })
    sock.on('close', () => {
      SessionService.feedExternal('\r\n[连接已关闭]\r\n')
      TelnetService.cur = null
    })
    sock.on('error', (err: Error) => {
      SessionService.feedExternal('\r\n[错误] ' + err.message + '\r\n')
    })
    await sock.connect({ address: { address: host, port: port }, timeout: 15 })
    SessionService.feedExternal('[已连接 ' + host + ':' + port.toString() + ']\r\n')
  }

  static write(text: string): void {
    const s = TelnetService.cur
    if (s === null) {
      return
    }
    const buf = TelnetService.encode(text)
    s.sock.send({ data: buf }).catch(() => {
    })
  }

  static async disconnect(): Promise<void> {
    const s = TelnetService.cur
    if (s !== null) {
      TelnetService.cur = null
      try {
        s.sock.close()
      } catch (e) {
      }
    }
  }

  // telnet IAC 命令过滤:IAC(255) CMD [OPT]
  private static stripIac(data: ArrayBuffer): Uint8Array {
    const b = new Uint8Array(data)
    const out = new Uint8Array(b.length)
    let j = 0
    let i = 0
    while (i < b.length) {
      if (b[i] === 255) {
        const cmd = b[i + 1]
        if (cmd === 255) {
          out[j++] = 255
          i += 2
          continue
        }
        if (cmd === 251 || cmd === 252 || cmd === 253 || cmd === 254) {
          i += 3 // WILL/WONT/DO/DONT + option
          continue
        }
        if (cmd === 250) { // SB 子协商 → 找 IAC SE(240)
          i += 2
          while (i + 1 < b.length && !(b[i] === 255 && b[i + 1] === 240)) {
            i++
          }
          i += 2
          continue
        }
        i += 2 // 其它两字节命令
        continue
      }
      out[j++] = b[i]
      i++
    }
    return out.subarray(0, j)
  }

  private static decode(data: Uint8Array): string {
    let s = ''
    for (let i = 0; i < data.length; i++) {
      s += String.fromCharCode(data[i])
    }
    return s
  }

  private static encode(text: string): ArrayBuffer {
    const out = new Uint8Array(text.length)
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xff
    }
    return out.buffer
  }
}
