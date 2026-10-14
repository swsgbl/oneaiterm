/**
 * tty7-RD-2: CLI 桥的 ttyd 会话镜像/写入通道(ADR-0002 集成棒 2,方案 B)。
 *
 * 实勘定案(VM 27681,证据见 REPORT-RD-2):
 *  - ttyd 多客户端 = 独立 shell 会话(c2 看不到 c1 写入的命令输出);
 *  - 因此桥**不能自连 WS**(那会是另一个 shell,屏上不可见)——方案 A 弃;
 *  - 方案 B:桥复用 **TermWebView 页面自己的 WS**:
 *    · 输出镜像:注入脚本 wrap WebSocket,onmessage('0' 帧)→ proxy 回传 → feed();
 *    · 桥写入:TtydSession.sendText → sender(runJavaScript)→ 页面 __tty7rd.write
 *      → 同一 socket.send('0'+bytes) —— 屏上可见(A1 同会话判据);
 *    · 输入探针:wrap send 拦截 INPUT 帧,行完成时 type() → InputHistory。
 *
 * ring 镜像:per-pane 行数组(cap 2000 行 × 每行 2000 字符截断)+ 残行缓冲;
 * capture = stripAnsi → trimBlankTail(ParityUi 复用)→ 尾 N 行拼接。
 * 红线:秘密不入日志;pane 销毁 detach 全清。
 */
import { trimBlankTail } from '../shell/ParityUi';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** ring 行数上限(任务书:尾部 2000 行)。 */
export const RING_MAX_LINES: number = 2000;
/** 单行字符截断(防超长单行(如 base64/cat 大文件)撑爆内存)。 */
export const RING_LINE_CAP: number = 2000;

/** ANSI 剥离(纯):CSI(ESC[ ... @~)/OSC(ESC] ... BEL|ESC\\)/单字符转义。 */
export function stripAnsi(s: string): string {
  let out = ''
  let i = 0
  while (i < s.length) {
    const c = s.charAt(i)
    if (c === '\x1b') {
      const n = s.charAt(i + 1)
      if (n === '[') {
        // CSI: 参数 0x30-0x3f + 中间 0x20-0x2f + 终结 0x40-0x7e
        let j = i + 2
        while (j < s.length) {
          const cc = s.charCodeAt(j)
          if (cc >= 0x40 && cc <= 0x7e) {
            j++
            break
          }
          j++
        }
        i = j
        continue
      }
      if (n === ']') {
        // OSC: 到 BEL(\x07)或 ST(ESC \)
        let j = i + 2
        while (j < s.length) {
          if (s.charAt(j) === '\x07') {
            j++
            break
          }
          if (s.charAt(j) === '\x1b' && s.charAt(j + 1) === '\\') {
            j += 2
            break
          }
          j++
        }
        i = j
        continue
      }
      // 单字符转义(ESC c 等):跳两字符
      i += 2
      continue
    }
    out += c
    i++
  }
  return out
}

/** 流分行(纯):chunk 按 \r\n/\n/\r 分行;prevPending 为上次残行;返回新行
 *  数组(不含残行)与残行拼接状态。回车/退格等编辑控制符不在此处理
 * (镜像行只做展示/判定,capture 前由调用方 stripAnsi)。 */
export function splitFeedLines(prevPending: string, chunk: string): FeedSplit {
  const r = new FeedSplit()
  let pending = prevPending
  let i = 0
  let segStart = 0
  while (i < chunk.length) {
    const c = chunk.charAt(i)
    if (c === '\n' || c === '\r') {
      r.lines.push(pending + chunk.substring(segStart, i))
      pending = ''
      if (c === '\r' && chunk.charAt(i + 1) === '\n') {
        i++
      }
      i++
      segStart = i
      continue
    }
    i++
  }
  r.pending = pending + chunk.substring(segStart)
  return r
}

/** splitFeedLines 结果形状。 */
export class FeedSplit {
  lines: string[] = []
  pending: string = ''
}

/** 单 pane 会话镜像。 */
class PaneMirror {
  lines: string[] = []
  pending: string = ''
  live: boolean = false
  /** sender 就绪(runJavaScript 通道;null = 组件未挂/页面未加载)。 */
  sender: ((js: string) => void) | null = null
}

export class TtydSession {
  private static panes: Map<string, PaneMirror> = new Map()
  /** 桥写入 tap(完成探测锚点;TermWebView 注册)。 */
  static onWriteTap: ((paneId: string) => void) | null = null

  private static mirrorOf(paneId: string): PaneMirror {
    let m = TtydSession.panes.get(paneId)
    if (m === undefined) {
      m = new PaneMirror()
      TtydSession.panes.set(paneId, m)
    }
    return m
  }

  /** 页面输出镜像入口(注入脚本 proxy push;文本已是 UTF-8 解码后的原始流)。 */
  static feed(paneId: string, text: string): void {
    if (paneId === '' || text.length === 0) {
      return
    }
    hilog.info(0xFF00, 'RDPOC', 'feed pane=%{public}s len=%{public}d', paneId, text.length)
    const m = TtydSession.mirrorOf(paneId)
    const sp = splitFeedLines(m.pending, text)
    m.pending = sp.pending.length > RING_LINE_CAP ? sp.pending.substring(0, RING_LINE_CAP) : sp.pending
    for (const ln of sp.lines) {
      let line = ln.length > RING_LINE_CAP ? ln.substring(0, RING_LINE_CAP) : ln
      m.lines.push(line)
    }
    if (m.lines.length > RING_MAX_LINES) {
      m.lines = m.lines.slice(m.lines.length - RING_MAX_LINES)
    }
  }

  /** 残行冲刷(capture 时点把 pending 落成可见尾行,提示符常驻残行)。 */
  private static flushPending(m: PaneMirror): void {
    if (m.pending.length > 0) {
      const line = m.pending.length > RING_LINE_CAP ? m.pending.substring(0, RING_LINE_CAP) : m.pending
      m.lines.push(line)
      m.pending = ''
      if (m.lines.length > RING_MAX_LINES) {
        m.lines = m.lines.slice(m.lines.length - RING_MAX_LINES)
      }
    }
  }

  /** 会话活性标记(注入握手 hello=true / WS close=false)。 */
  static markLive(paneId: string, on: boolean): void {
    const m = TtydSession.mirrorOf(paneId)
    m.live = on
  }

  /** web 会话是否活跃(页面 WS 已建;桥路由判定源)。 */
  static isLive(paneId: string): boolean {
    const m = TtydSession.panes.get(paneId)
    return m !== undefined && m.live
  }

  /** 任一 live pane(引擎 term_write 无 pane 上下文时的取用判定)。 */
  static anyLivePane(): string {
    let best = ''
    let bestLen = -1
    TtydSession.panes.forEach((m: PaneMirror, k: string) => {
      if (m.live && m.lines.length > bestLen) {
        best = k
        bestLen = m.lines.length
      }
    })
    return best
  }

  /** 注册 sender(TermWebView onControllerAttached 注入;null 清除)。 */
  static setSender(paneId: string, sender: ((js: string) => void) | null): void {
    TtydSession.mirrorOf(paneId).sender = sender
  }

  /** 桥/引擎写入:经页面 __tty7rd.write(b64) → 同一 socket 发 INPUT 帧。
   *  b64 承载避免引号/换行的 JS 注入地狱(util Base64)。返回 false = 通道
   *  未就绪(页面未加载/组件未挂)。 */
  static sendText(paneId: string, text: string): boolean {
    const m = TtydSession.panes.get(paneId)
    if (m === undefined || !m.live || m.sender === null || text.length === 0) {
      return false
    }
    const b64 = TtydSession.b64Of(text)
    if (b64 === '') {
      return false
    }
    try {
      m.sender('window.__tty7rd && window.__tty7rd.write("' + b64 + '")')
      const tap = TtydSession.onWriteTap
      if (tap !== null) {
        tap(paneId)
      }
      return true
    } catch (e) {
      return false
    }
  }

  /** UTF-8 → base64(util;异常回 '' 由调用方当通道失败处理)。 */
  private static b64Of(text: string): string {
    try {
      const u8: Uint8Array = new Uint8Array(text.length)
      let n = 0
      for (let i = 0; i < text.length; i++) {
        const cp = text.charCodeAt(i)
        if (cp < 0x80) {
          u8[n++] = cp
        } else if (cp < 0x800) {
          u8[n++] = 0xc0 | (cp >> 6)
          u8[n++] = 0x80 | (cp & 0x3f)
        } else {
          u8[n++] = 0xe0 | (cp >> 12)
          u8[n++] = 0x80 | ((cp >> 6) & 0x3f)
          u8[n++] = 0x80 | (cp & 0x3f)
        }
      }
      return TtydSession.b64Encode(u8.subarray(0, n))
    } catch (e) {
      return ''
    }
  }

  /** 纯 base64(单测靶;标准字母表,无填充省略——页面侧已按需补)。 */
  static b64Encode(bytes: Uint8Array): string {
    const T = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let out = ''
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i]
      const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0
      const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0
      out += T.charAt(b0 >> 2)
      out += T.charAt(((b0 & 3) << 4) | (b1 >> 4))
      out += i + 1 < bytes.length ? T.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '='
      out += i + 2 < bytes.length ? T.charAt(b2 & 63) : '='
    }
    return out
  }

  /** 捕获(桥 capture / 完成探测共用):残行冲刷 → stripAnsi → trimBlankTail
   *  → 尾 N 行 \n 拼接。无镜像/空 → ''(桥侧转 not bound,同 paneCapture)。 */
  static capture(paneId: string, tailN: number): string {
    const m = TtydSession.panes.get(paneId)
    if (m === undefined) {
      return ''
    }
    TtydSession.flushPending(m)
    if (m.lines.length === 0) {
      return ''
    }
    const stripped: string[] = []
    for (const ln of m.lines) {
      stripped.push(stripAnsi(ln).replace(/\s+$/, ''))
    }
    const src = trimBlankTail(stripped)
    if (src.length === 0) {
      return ''
    }
    const n = tailN > 0 ? Math.min(tailN, src.length) : src.length
    let out = ''
    for (let i = src.length - n; i < src.length; i++) {
      if (out.length > 0) {
        out += '\n'
      }
      out += src[i]
    }
    return out
  }

  /** 镜像行数(单测/诊断)。 */
  static lineCount(paneId: string): number {
    const m = TtydSession.panes.get(paneId)
    return m === undefined ? 0 : m.lines.length
  }

  /** pane 销毁全清(TermWebView aboutToDisappear)。 */
  static detach(paneId: string): void {
    TtydSession.panes.delete(paneId)
  }

  /** 全清(单测复位)。 */
  static reset(): void {
    TtydSession.panes = new Map()
    TtydSession.onWriteTap = null
  }
}
