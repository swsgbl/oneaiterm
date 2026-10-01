// VNC 客户端:RFB 协议纯 TS(@ohos.net.socket)
// 子集:RFB 3.8 握手 / VNC 认证(DES challenge-response)/ ClientInit / ServerInit
//       SetEncodings(只请求 RAW=0)/ FramebufferUpdateRequest(增量) / 指针+键盘事件
// 渲染层:回调交付 RGB(A) 像素缓冲,由 VncTab 转 PixelMap 显示
import socket from '@ohos.net.socket';

export class VncService {
  private static sock: socket.TCPSocket | null = null
  private static pending: number[] = []
  private static ver: string = 'RFB 003.008\n'
  static width: number = 0
  static height: number = 0
  static onFrame: ((x: number, y: number, w: number, h: number, rgba: Uint8Array) => void) | null = null
  static onStatus: ((s: string) => void) | null = null
  private static running: boolean = false

  static active(): boolean {
    return VncService.sock !== null
  }

  static async connect(host: string, port: number, password: string): Promise<void> {
    if (VncService.sock !== null) {
      await VncService.close()
    }
    const s = socket.constructTCPSocketInstance()
    s.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message)
      for (let i = 0; i < u8.length; i++) {
        VncService.pending.push(u8[i])
      }
    })
    await s.connect({ address: { address: host, port: port }, timeout: 10 })
    VncService.sock = s
    VncService.pending = []
    // ===== RFB 握手 =====
    const sv = await VncService.readBytes(12) // "RFB 003.008\n"
    const svStr = VncService.text(sv)
    if (!svStr.startsWith('RFB')) {
      throw new Error('非 RFB 服务: ' + svStr.trim())
    }
    const minor = parseInt(svStr.substring(6, 9)) || 8
    VncService.write(VncService.bytes('RFB 003.' + (minor >= 7 ? '008' : '003') + '\n'))
    // 安全类型列表
    if (minor >= 7) {
      const n = (await VncService.readBytes(1))[0]
      const types = await VncService.readBytes(n)
      let chosen = 0 // 无认证
      for (const t of types) {
        if (t === 2) {
          chosen = 2
        } // VNC 认证
        if (t === 1) {
          chosen = 1
        }
      }
      if (chosen === 0) {
        throw new Error('服务器要求不支持的认证类型')
      }
      VncService.write(new Uint8Array([chosen]))
    }
    if (minor >= 7) {
      const sec = (await VncService.readBytes(4))
      const code = VncService.u32(sec)
      if (code !== 0) {
        const len = VncService.u32(await VncService.readBytes(4))
        const msg = VncService.text(await VncService.readBytes(len))
        throw new Error('认证失败: ' + msg)
      }
    } else {
      const sec = VncService.u32(await VncService.readBytes(4))
      if (sec === 2) {
        const challenge = await VncService.readBytes(16)
        VncService.write(VncService.desChallenge(password, challenge))
        const res = VncService.u32(await VncService.readBytes(4))
        if (res !== 0) {
          throw new Error('认证失败(code ' + res.toString() + ')')
        }
      }
    }
    // ClientInit(shared=1) / ServerInit
    VncService.write(new Uint8Array([1]))
    const w = VncService.u16(await VncService.readBytes(2))
    const h = VncService.u16(await VncService.readBytes(2))
    VncService.width = w
    VncService.height = h
    const nameLen = VncService.u32(await VncService.readBytes(4))
    const name = VncService.text(await VncService.readBytes(nameLen))
    if (VncService.onStatus !== null) {
      VncService.onStatus('已连接 ' + name + ' ' + w.toString() + 'x' + h.toString())
    }
    // SetEncodings: 只 RAW
    const enc = new Uint8Array(12)
    enc[0] = 2
    VncService.putU16(enc, 1, 1)
    VncService.putU16(enc, 3, 1)
    VncService.putU32(enc, 4, 0) // RAW
    VncService.putU32(enc, 8, 0xffffff21) // DesktopSize 伪编码(通知 resize)
    VncService.write(enc)
    VncService.running = true
    // 请求全帧 + 进入读循环
    VncService.requestUpdate(0, 0, w, h, false)
    VncService.readLoop()
  }

  /** 增量帧请求 */
  static requestUpdate(x: number, y: number, w: number, h: number, incr: boolean): void {
    const m = new Uint8Array(10)
    m[0] = 3
    m[1] = incr ? 1 : 0
    VncService.putU16(m, 2, x)
    VncService.putU16(m, 4, y)
    VncService.putU16(m, 6, w)
    VncService.putU16(m, 8, h)
    VncService.write(m)
  }

  static pointerEvent(mask: number, x: number, y: number): void {
    const m = new Uint8Array(6)
    m[0] = 5
    m[1] = mask
    VncService.putU16(m, 2, x)
    VncService.putU16(m, 4, y)
    VncService.write(m)
  }

  static keyEvent(down: boolean, keysym: number): void {
    const m = new Uint8Array(8)
    m[0] = 4
    m[1] = down ? 1 : 0
    VncService.putU32(m, 4, keysym)
    VncService.write(m)
  }

  static async close(): Promise<void> {
    VncService.running = false
    const s = VncService.sock
    VncService.sock = null
    if (s !== null) {
      try {
        s.close()
      } catch (e) {
      }
    }
  }

  // ===== 服务器消息循环 =====
  private static async readLoop(): Promise<void> {
    try {
      while (VncService.running && VncService.sock !== null) {
        const t = (await VncService.readBytes(1))[0]
        if (t === 0) {
          // FramebufferUpdate
          await VncService.readBytes(1) // padding
          const nRect = VncService.u16(await VncService.readBytes(2))
          for (let r = 0; r < nRect; r++) {
            const rx = VncService.u16(await VncService.readBytes(2))
            const ry = VncService.u16(await VncService.readBytes(2))
            const rw = VncService.u16(await VncService.readBytes(2))
            const rh = VncService.u16(await VncService.readBytes(2))
            const encType = VncService.u32(await VncService.readBytes(4))
            if (encType === 0) {
              // RAW: rw*rh*4 字节 BGRA(通常 32bpp)→ RGBA
              const raw = await VncService.readBytes(rw * rh * 4)
              const rgba = new Uint8Array(rw * rh * 4)
              for (let i = 0; i < rw * rh; i++) {
                rgba[i * 4] = raw[i * 4 + 2]
                rgba[i * 4 + 1] = raw[i * 4 + 1]
                rgba[i * 4 + 2] = raw[i * 4]
                rgba[i * 4 + 3] = 255
              }
              if (VncService.onFrame !== null) {
                VncService.onFrame(rx, ry, rw, rh, rgba)
              }
            } else if (encType === -239) {
              // DesktopSize 伪矩形:重请求全帧
              VncService.requestUpdate(0, 0, VncService.width, VncService.height, false)
            } else {
              // 未请求的编码:跳过该矩形数据(不应发生,只请求了 RAW)
              VncService.requestUpdate(0, 0, VncService.width, VncService.height, false)
              break
            }
          }
          // 增量续帧
          VncService.requestUpdate(0, 0, VncService.width, VncService.height, true)
        } else if (t === 1) {
          // SetColourMapEntries:忽略
          await VncService.readBytes(5)
          const n = VncService.u16(await VncService.readBytes(2))
          await VncService.readBytes(n * 6)
        } else if (t === 2) {
          // Bell:忽略
        } else if (t === 3) {
          // ServerCutText
          await VncService.readBytes(3)
          const len = VncService.u32(await VncService.readBytes(4)) & 0x7fffffff
          await VncService.readBytes(len)
        }
      }
    } catch (e) {
      if (VncService.onStatus !== null && VncService.running) {
        VncService.onStatus('连接断开: ' + e.toString().substring(0, 200))
      }
      VncService.running = false
    }
  }

  // ===== DES challenge(VNC 认证)=====
  private static desChallenge(password: string, challenge: Uint8Array): Uint8Array {
    // VNC DES:密钥取密码前 8 字节逐位反转,ECB 加密 challenge(16 字节=2 块)
    // 纯 TS DES 实现(精简,仅加密路径)
    const keyBytes = new Uint8Array(8)
    for (let i = 0; i < 8; i++) {
      let c = i < password.length ? password.charCodeAt(i) & 0xff : 0
      let rk = 0
      for (let b = 0; b < 8; b++) {
        rk = (rk << 1) | ((c >> b) & 1)
      }
      keyBytes[i] = rk
    }
    const pc1 = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
      62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    const shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    const k = new Uint8Array(56)
    for (let i = 0; i < 56; i++) {
      k[i] = (keyBytes[pc1[i] / 8 | 0] >> (7 - pc1[i] % 8)) & 1
    }
    const subKeys: number[][] = []
    let off = 0
    for (let r = 0; r < 16; r++) {
      off += shifts[r]
      const sk: number[] = new Array(48).fill(0)
      for (let i = 0; i < 48; i++) {
        const idx = (i < 28 ? i : i - 28) + off
        sk[i] = k[idx % 28 + (i < 28 ? 0 : 28)]
      }
      subKeys.push(sk)
    }
    const ip = [57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
      56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6]
    const ep = [31, 0, 1, 2, 3, 4, 3, 4, 5, 6, 7, 8, 7, 8, 9, 10, 11, 12, 11, 12, 13, 14, 15, 16, 15, 16, 17, 18, 19, 20, 19, 20, 21, 22, 23, 24, 23, 24, 25, 26, 27, 28, 27, 28, 29, 30, 31, 0]
    const pbox = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24]
    const sbox = [
      [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
      [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
      [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
      [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
      [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
      [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]
    ]
    const fp = [39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24]
    const out = new Uint8Array(16)
    for (let blk = 0; blk < 2; blk++) {
      const bits: number[] = new Array(64).fill(0)
      for (let i = 0; i < 64; i++) {
        bits[i] = (challenge[blk * 8 + (ip[i] / 8 | 0)] >> (7 - ip[i] % 8)) & 1
      }
      let l = bits.slice(0, 32)
      let r = bits.slice(32)
      for (let rd = 0; rd < 16; rd++) {
        const er: number[] = new Array(48).fill(0)
        for (let i = 0; i < 48; i++) {
          er[i] = r[ep[i]]
        }
        const x: number[] = new Array(48).fill(0)
        for (let i = 0; i < 48; i++) {
          x[i] = er[i] ^ subKeys[rd][i]
        }
        const f: number[] = new Array(32).fill(0)
        for (let i = 0; i < 8; i++) {
          const row = x[i * 6] * 2 + x[i * 6 + 5]
          const col = x[i * 6 + 1] * 8 + x[i * 6 + 2] * 4 + x[i * 6 + 3] * 2 + x[i * 6 + 4]
          const v = sbox[i][row * 16 + col]
          for (let b = 0; b < 4; b++) {
            f[i * 4 + b] = (v >> (3 - b)) & 1
          }
        }
        const pf: number[] = new Array(32).fill(0)
        for (let i = 0; i < 32; i++) {
          pf[i] = f[pbox[i]]
        }
        const nl = r.slice()
        for (let i = 0; i < 32; i++) {
          r[i] = l[i] ^ pf[i]
        }
        l = nl
      }
      const pre = l.concat(r)
      for (let i = 0; i < 64; i++) {
        const bit = pre[fp[i]]
        if (bit) {
          out[blk * 8 + (i / 8 | 0)] |= 1 << (7 - i % 8)
        }
      }
    }
    return out
  }

  // ===== 基础 IO =====
  private static async readBytes(n: number): Promise<Uint8Array> {
    for (let i = 0; i < 400; i++) {
      if (VncService.pending.length >= n) {
        const out = new Uint8Array(n)
        for (let j = 0; j < n; j++) {
          out[j] = VncService.pending[j]
        }
        VncService.pending.splice(0, n)
        return out
      }
      await VncService.sleep(25)
    }
    throw new Error('超时读取(' + n.toString() + ' 字节)')
  }

  private static write(data: Uint8Array): void {
    const s = VncService.sock
    if (s !== null) {
      s.send({ data: data.buffer }).catch(() => {
      })
    }
  }

  private static u16(b: Uint8Array): number {
    return b[0] << 8 | b[1]
  }

  private static u32(b: Uint8Array): number {
    return ((b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) >>> 0)
  }

  private static putU16(b: Uint8Array, o: number, v: number): void {
    b[o] = (v >> 8) & 0xff
    b[o + 1] = v & 0xff
  }

  private static putU32(b: Uint8Array, o: number, v: number): void {
    b[o] = (v >>> 24) & 0xff
    b[o + 1] = (v >>> 16) & 0xff
    b[o + 2] = (v >>> 8) & 0xff
    b[o + 3] = v & 0xff
  }

  private static text(b: Uint8Array): string {
    let s = ''
    for (let i = 0; i < b.length; i++) {
      if (b[i] !== 0) {
        s += String.fromCharCode(b[i])
      }
    }
    return s
  }

  private static bytes(s: string): Uint8Array {
    const out = new Uint8Array(s.length)
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff
    }
    return out
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>(resolve => setTimeout(resolve, ms))
  }
}
