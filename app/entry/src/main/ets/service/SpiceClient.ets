// SPICE 客户端核心:握手(RSA 票据) + Display 通道(纯 TS)
// 布局:REDQ magic / LinkMess / LinkReply(裸 n,e 公钥) / RSA PKCS1 票据 / mini-header 消息
import socket from '@ohos.net.socket';
import cryptoFramework from '@ohos.security.cryptoFramework';

export class SpiceClient {
  private sock: socket.TCPSocket | null = null
  private buf: number[] = []
  st: string = 'idle'
  width: number = 0
  height: number = 0
  onStatus: ((s: string) => void) | null = null

  async connect(host: string, port: number, password: string): Promise<void> {
    const s = socket.constructTCPSocketInstance()
    s.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message)
      for (let i = 0; i < u8.length; i++) {
        this.buf.push(u8[i])
      }
    })
    await s.connect({ address: { address: host, port: port }, timeout: 10 })
    this.sock = s
    this.st = 'handshake'
    await this.handshake(password)
  }

  private async handshake(password: string): Promise<void> {
    const body: number[] = []
    this.pu32(body, 0)      // connection_id(首连接 0)
    body.push(2)            // channel_type = DISPLAY
    body.push(0)            // channel_id
    this.pu32(body, 1)      // num_common_caps
    this.pu32(body, 0)      // num_channel_caps
    this.pu32(body, 18)     // caps_offset = sizeof(LinkMess)=18
    this.pu32(body, 0x03)   // common caps: protocol_auth_selection + mini_header
    const hdr: number[] = [0x52, 0x45, 0x44, 0x51] // "REDQ"
    this.pu32(hdr, 2)
    this.pu32(hdr, 2)
    this.pu32(hdr, body.length)
    await this.sendRaw(new Uint8Array(hdr.concat(body)))
    const rhdr = await this.readN(16)
    const err = this.u32(rhdr, 4)
    if (err !== 0) {
      throw new Error('SPICE link 失败 code=' + err.toString())
    }
    const size = this.u32(rhdr, 12)
    const rbody = await this.readN(size)
    const pubKey = rbody.slice(4, 4 + 162) // error(4) + pub_key(162)
    // 票据:password\0(64B 对齐) — spice 协议约定 RSA 只加密密码区(AES 走 auth 机制 2)
    const ticket: number[] = []
    for (let i = 0; i < password.length && i < 60; i++) {
      ticket.push(password.charCodeAt(i) & 0xff)
    }
    ticket.push(0)
    const encTicket = await this.rsaEncrypt(pubKey, new Uint8Array(ticket))
    await this.sendRaw(encTicket)
    const res = await this.readN(4)
    const rc = this.u32(res, 0)
    if (rc !== 0) {
      throw new Error('SPICE 认证失败 code=' + rc.toString())
    }
    this.st = 'connected'
    if (this.onStatus !== null) {
      this.onStatus('SPICE 已连接(显示通道)')
    }
    this.readLoop()
  }

  private async readLoop(): Promise<void> {
    try {
      while (this.st === 'connected') {
        const hdr = await this.readN(6)
        const msgType = hdr[0] | hdr[1] << 8
        const size = this.u32(hdr, 2)
        const body = size > 0 ? await this.readN(size) : new Uint8Array(0)
        if (msgType >= 300 && msgType < 400) {
          if (msgType === 301) { // SURFACE_CREATE
            this.width = this.u32(body, 4)
            this.height = this.u32(body, 8)
            if (this.onStatus !== null) {
              this.onStatus('surface ' + this.width.toString() + 'x' + this.height.toString())
            }
          }
        }
      }
    } catch (e) {
      this.st = 'error'
      if (this.onStatus !== null) {
        this.onStatus('断开')
      }
    }
  }

  close(): void {
    if (this.sock !== null) {
      try {
        this.sock.close()
      } catch (e) {
      }
    }
    this.sock = null
    this.st = 'closed'
  }

  // spice 裸公钥(n_len u16BE + n + e_len u16BE + e)→ DER SPKI → RSA PKCS1
  private async rsaEncrypt(pubKey: Uint8Array, plain: Uint8Array): Promise<Uint8Array> {
    const nLen = pubKey[0] << 8 | pubKey[1]
    const n = pubKey.slice(2, 2 + nLen)
    let off = 2 + nLen
    const eLen = pubKey[off] << 8 | pubKey[off + 1]
    off += 2
    const e = pubKey.slice(off, off + eLen)
    const der = SpiceClient.buildRsaDer(n, e)
    const generator = cryptoFramework.createAsyKeyGenerator('RSA1024|PRIMES_2')
    const keyPair = await generator.convertKey({ data: der }, null)
    const cipher = cryptoFramework.createCipher('RSA1024|PKCS1')
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null)
    const out = await cipher.doFinal({ data: plain })
    return out.data
  }

  static buildRsaDer(n: Uint8Array, e: Uint8Array): Uint8Array {
    const intDer = (b: Uint8Array, pad: boolean): number[] => {
      const arr = Array.from(b)
      if (pad || (b[0] & 0x80) !== 0) {
        return [0x02, arr.length + 1, 0x00].concat(arr)
      }
      return [0x02, arr.length].concat(arr)
    }
    const nInt = intDer(n, false)
    const eInt = intDer(e, false)
    const seq = [0x30, nInt.length + eInt.length].concat(nInt, eInt)
    const bitstr = [0x03, seq.length + 1, 0x00].concat(seq)
    const algId = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
    const spki = [0x30, algId.length + bitstr.length].concat(algId, bitstr)
    return new Uint8Array(spki)
  }

  private randBytes(n: number): Uint8Array {
    const out = new Uint8Array(n)
    for (let i = 0; i < n; i++) {
      out[i] = Math.floor(Math.random() * 256)
    }
    return out
  }

  private async sendRaw(b: Uint8Array): Promise<void> {
    const s = this.sock
    if (s !== null) {
      await s.send({ data: b.buffer.slice(b.byteOffset, b.byteOffset + b.length) })
    }
  }

  private async readN(n: number): Promise<Uint8Array> {
    for (let i = 0; i < 400; i++) {
      if (this.buf.length >= n) {
        const out = new Uint8Array(n)
        for (let j = 0; j < n; j++) {
          out[j] = this.buf[j]
        }
        this.buf.splice(0, n)
        return out
      }
      await this.sleep(25)
    }
    throw new Error('超时读取 ' + n.toString() + ' 字节')
  }

  private u32(b: Uint8Array | number[], o: number): number {
    return (b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24) >>> 0
  }

  private pu32(a: number[], v: number): void {
    a.push(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff)
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>(r => setTimeout(r, ms))
  }
}
