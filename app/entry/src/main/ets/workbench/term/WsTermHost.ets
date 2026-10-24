/**
 * WsTermHost —— WebSocket 终端会话宿主(R4u:多终端+系统环境根治)。
 *
 * 架构:自绘 TermPaneView(显示实证可用)+ 直连系统 ttyd 的 WebSocket
 * (协议实勘自 ttyd 前端 bundle):
 *   - 连接 ws://127.0.0.1:27681/ws;
 *   - open 后首条:JSON {AuthToken:"", columns:C, rows:R};
 *   - 服务端→客户端:二进制帧,首字节指令:'0'=输出(余下为 PTY 原始
 *     字节),'1'=标题,'2'=偏好;
 *   - 客户端→服务端:'0'+文本=输入;'1'+JSON{columns,rows}=尺寸。
 *   ttyd 每个连接独立 spawn /bin/sh(root、完整系统环境——用户实锤
 *   自绘 PTY「识别不到系统程序」根因即环境差异,本通道天然全环境)。
 * 多实例:Map<paneId, Session> 天然多 pane;镜像喂 TtydSession(CLI
 * capture 兼容)。VT 解析复用 TermModel;渲染复用 TermPaneView 注入
 * 模式(M6a 远程同款)——零 ArkWeb 依赖(平台零像素缺陷绕开)。
 */
import webSocket from '@ohos.net.webSocket';
import { BusinessError } from '@ohos.base';
import util from '@ohos.util';
import { TermModel } from '../../components/TermModel';
import { TtydSession } from './TtydSession';
import { hilog } from '@kit.PerformanceAnalysisKit';

const WST_TAG: string = 'oat.wsterm'
const WST_DOMAIN: number = 0x0301
/** ttyd 服务(VM 启动项,root,-W 可写;ADR-0002 同源)。 */
const TTYD_WS_URL: string = 'ws://127.0.0.1:27681/ws'

/** 协议纯函数(单测靶):输入帧编码。 */
export function wsInputFrame(text: string): string {
  return '0' + text
}

/** 协议纯函数(单测靶):resize 帧编码。 */
export function wsResizeFrame(cols: number, rows: number): string {
  return '1{"columns":' + cols.toString() + ',"rows":' + rows.toString() + '}'
}

/** 协议纯函数(单测靶):首条握手 JSON。 */
export function wsHelloFrame(cols: number, rows: number): string {
  return '{"AuthToken":"","columns":' + cols.toString() + ',"rows":' + rows.toString() + '}'
}

/** 协议纯函数(单测靶):服务端帧分流——'0' 输出 / '1' 标题 / 其余丢弃。 */
export function wsParseServerFrame(data: string): string {
  if (data.length < 1) {
    return ''
  }
  const cmd = data.charAt(0)
  if (cmd === '0') {
    return data.substring(1)
  }
  return ''
}

class WsTermSession {
  model: TermModel
  ws: webSocket.WebSocket
  live: boolean = false
  cols: number
  rows: number

  constructor(model: TermModel, cols: number, rows: number) {
    this.model = model
    this.cols = cols
    this.rows = rows
    this.ws = webSocket.createWebSocket()
  }

  /** 客户端帧一律二进制发送(ttyd 前端实勘:textEncoder.encode→
   *  ArrayBuffer;libwebsockets 服务端只按二进制帧处理客户端消息)。 */
  sendBin(text: string): boolean {
    try {
      const enc = new util.TextEncoder()
      const bytes = enc.encodeInto(text)
      this.ws.send(bytes.buffer as ArrayBuffer)
      return true
    } catch (e) {
      hilog.warn(WST_DOMAIN, WST_TAG, 'sendBin fail')
      return false
    }
  }
}

export class WsTermHost {
  private static sessions: Map<string, WsTermSession> = new Map()

  static session(paneId: string): WsTermSession | null {
    const s = WsTermHost.sessions.get(paneId)
    return s === undefined ? null : s
  }

  static model(paneId: string): TermModel | null {
    const s = WsTermHost.session(paneId)
    return s === null ? null : s.model
  }

  static isLive(paneId: string): boolean {
    const s = WsTermHost.session(paneId)
    return s !== null && s.live
  }

  /** 建立 pane 的 WS 终端会话;返回 model(注入 TermPaneView)。 */
  static connect(paneId: string, cols: number, rows: number): TermModel | null {
    let s = WsTermHost.session(paneId)
    if (s !== null) {
      return s.model
    }
    const model = new TermModel(cols, rows)
    s = new WsTermSession(model, cols, rows)
    WsTermHost.sessions.set(paneId, s)
    const sess = s
    sess.ws.on('open', (_err: BusinessError, _v: Object): void => {
      sess.live = true
      // 桥镜像登记(live=true 才可被 CLI capture 读取)
      TtydSession.markLive(paneId, true)
      hilog.info(WST_DOMAIN, WST_TAG, 'ws open pane=%{public}s', paneId)
      try {
        sess.sendBin(wsHelloFrame(sess.cols, sess.rows))
        // 诊断+RD3 环境补全:ttyd 会话的 mount namespace 无 /usr/local/bin
        // (宿主 su 域可见但 ttyd 域不可见,实测 ls 报 No such file),node/npm
        // 只在 /data/local/home/.ohos/node/bin。open 后注入 PATH export,
        // 让每个终端 which node/npm/hdc 直接可用(原回车探测帧并入)。
        setTimeout((): void => {
          try {
            sess.sendBin(wsInputFrame(
              'export PATH=/data/local/home/.ohos/node/bin:/data/local/home/.local/bin:$PATH\r'))
          } catch (e2) {
          }
        }, 800)
      } catch (e) {
        hilog.warn(WST_DOMAIN, WST_TAG, 'hello send fail pane=%{public}s', paneId)
      }
    })
    sess.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer): void => {
      // ttyd 输出为二进制帧:首字节指令+原始字节;TextDecoder 流式解码
      // (UTF-8 跨帧边界由 stream 尾缀缓存兜住)。
      let text = ''
      const isStr = typeof value === 'string'
      if (isStr) {
        text = value as string
      } else {
        try {
          const dec = new util.TextDecoder('utf-8')
          text = dec.decodeWithStream(new Uint8Array(value as ArrayBuffer))
        } catch (e) {
          hilog.warn(WST_DOMAIN, WST_TAG, 'ws decode fail pane=%{public}s', paneId)
          return
        }
      }
      hilog.warn(WST_DOMAIN, WST_TAG, 'ws msg pane=%{public}s str=%{public}s len=%{public}d head=%{public}s',
        paneId, isStr ? 'Y' : 'N', text.length, text.length > 0 ? text.charAt(0) : '-')
      const out = wsParseServerFrame(text)
      if (out === '') {
        return
      }
      sess.model.feed(out)
      TtydSession.feed(paneId, out)
    })
    sess.ws.on('close', (_err: BusinessError, _v: Object): void => {
      sess.live = false
      hilog.info(WST_DOMAIN, WST_TAG, 'ws close pane=%{public}s', paneId)
    })
    // RD3 根修:ttyd 1.7.1(libwebsockets)要求客户端握手携带子协议
    // "tty",否则升级成功但服务端静默不启动会话(零回帧实锤;VM node
    // 探针 A/C 无子协议=零回帧,B 带 tty=输出帧全通)。OHOS webSocket
    // 经 WebSocketRequestOptions.protocol 映射 Sec-WebSocket-Protocol。
    sess.ws.connect(TTYD_WS_URL, { protocol: 'tty' }, (_err: BusinessError, _ok: boolean): void => {
    })
    return model
  }

  static write(paneId: string, text: string): boolean {
    const s = WsTermHost.session(paneId)
    if (s === null || !s.live || text.length === 0) {
      return false
    }
    try {
      s.sendBin(wsInputFrame(text))
      return true
    } catch (e) {
      return false
    }
  }

  static resize(paneId: string, cols: number, rows: number): void {
    const s = WsTermHost.session(paneId)
    if (s === null || !s.live) {
      return
    }
    s.cols = cols
    s.rows = rows
    try {
      s.sendBin(wsResizeFrame(cols, rows))
    } catch (e) {
    }
  }

  static detach(paneId: string): void {
    const s = WsTermHost.session(paneId)
    if (s === null) {
      return
    }
    WsTermHost.sessions.delete(paneId)
    try {
      s.ws.close()
    } catch (e) {
    }
  }

  /** 单测复位。 */
  static reset(): void {
    WsTermHost.sessions.forEach((s: WsTermSession): void => {
      try {
        s.ws.close()
      } catch (e) {
      }
    })
    WsTermHost.sessions = new Map()
  }
}
