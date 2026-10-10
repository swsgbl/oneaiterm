/**
 * tty7 CLI 桥(任务 tty7-M8a):app 内 TCP JSON-RPC server,供 oneaiterm-cli
 * (VM 侧 node 工具)驱动工作台。首发六命令:doctor/workspace.list/tab.list/
 * pane.list/send/capture(agents/events/procs/ports/git/wait 留 M8b)。
 *
 * 架构(任务书定稿):
 * - 传输:@ohos.net.socket TCPSocketServer,仅 listen 127.0.0.1:18971
 *   (红线:绝不绑非环回地址;本机环回无 TLS,M9 评估)。
 * - 握手:每连接首行必须是 token 行(TODO-M9:首发常量 'dev-local';
 *   M9 换 filesDir 下 cli_token 真文件)。校验失败立即 close(秘密红线:
 *   token 值与 send 文本绝不进 hilog,日志只记事件)。
 * - 协议:每行一个 JSON 请求 {id,cmd,args};响应 {id,ok,data|error} 单行
 *   JSON;连接可复用,请求串行处理。
 * - vm 持有:AppShell aboutToAppear 时 setVm(vm);桥静态单 ref,vm 未设时
 *   所有命令优雅降级(doctor 返回 vm:0,其余 error)。
 * - 线程模型:@ohos.net.socket 回调在主线程事件循环交付(SDK 实读),vm
 *   直调安全;handle() 纯同步,无 await、无 UI API。
 *
 * 纯函数(parseRequest/formatResponse/linesToText/handleCmd)与 socket 层
 * 分离——单测只测纯函数,TCP 层 M9 冒烟。
 */
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { TermHost } from '../term/TermHost';
import { RemoteTermHost } from '../remote/RemoteTermHost';
import { LayoutOps } from '../layout/LayoutOps';

const DOMAIN: number = 0x0700;
const TAG: string = 'tty7.bridge';
const BRIDGE_PORT: number = 18971;
/** TODO-M9: 首发常量 token(dev 阶段);M9 换 filesDir 下 cli_token 真文件。 */
const DEV_TOKEN: string = 'dev-local';

/** 桥响应统一形态:{id,ok,data} 或 {id,ok:false,error}。 */
export interface BridgeResponse {
  id: number
  ok: boolean
  data?: string
  error?: string
}

/** 桥请求形态:{id,cmd,args};args 内字段由各命令自取。 */
export interface BridgeRequest {
  id: number
  cmd: string
  args?: Record<string, Object>
}

/** 单行文本转请求。坏 JSON/非对象/缺 id/缺 cmd 时返回 null。 */
export function parseRequest(line: string): BridgeRequest | null {
  let raw: object | null = null
  try {
    raw = JSON.parse(line) as object
  } catch (e) {
    return null
  }
  if (raw === null || typeof raw !== 'object') {
    return null
  }
  const rec = raw as Record<string, Object>
  const id = rec['id']
  const cmd = rec['cmd']
  if (id === undefined || typeof id !== 'number') {
    return null
  }
  if (cmd === undefined || typeof cmd !== 'string' || cmd === '') {
    return null
  }
  const req: BridgeRequest = { id: id, cmd: cmd }
  const args = rec['args']
  if (args !== undefined && args !== null && typeof args === 'object') {
    req.args = args as Record<string, Object>
  }
  return req
}

/** 响应转单行 JSON(序列化异常兜底为内建 error 形态)。 */
export function formatResponse(r: BridgeResponse): string {
  try {
    return JSON.stringify(r)
  } catch (e) {
    return '{"id":' + r.id + ',"ok":false,"error":"format-failed"}'
  }
}

/** capture 行拼接纯函数:取尾 N 行用换行拼接(不追加末尾换行)。 */
export function linesToText(lines: string[], tailN: number): string {
  if (lines.length === 0) {
    return ''
  }
  const n = tailN > 0 ? Math.min(tailN, lines.length) : lines.length
  const start = lines.length - n
  let s = ''
  for (let i = start; i < lines.length; i++) {
    if (s.length > 0) {
      s += '\n'
    }
    s += lines[i]
  }
  return s
}

/** 当前 vm 快照(doctor 用);vm 未设时返回降级形态(不抛)。 */
export function doctorSnapshot(): Record<string, Object> {
  const vm = CommandBridge.getVm()
  const out: Record<string, Object> = {}
  out['app'] = 'oneaiterm'
  out['bridge'] = CommandBridge.isRunning() ? 1 : 0
  out['port'] = BRIDGE_PORT
  if (vm === null) {
    out['vm'] = 0
    return out
  }
  out['vm'] = 1
  out['wsCount'] = vm.workspaces.length
  out['tabCount'] = vm.tabs.length
  out['paneCount'] = vm.panes.length
  out['termLocal'] = TermHost.bound()
  out['termRemote'] = RemoteTermHost.bound()
  return out
}

/**
 * 命令分发(vm 未设时全命令 'vm-not-set' 降级)。data 为 JSON 字符串
 * (send 成功时为 'ok';capture 为纯文本)。
 */
export function handleCmd(req: BridgeRequest): BridgeResponse {
  const vm = CommandBridge.getVm()
  if (vm === null) {
    return { id: req.id, ok: false, error: 'vm-not-set' }
  }
  try {
    switch (req.cmd) {
      case 'doctor':
        return { id: req.id, ok: true, data: JSON.stringify(doctorSnapshot()) }
      case 'workspace.list': {
        const arr: object[] = []
        for (const ws of vm.workspaces) {
          const rec: Record<string, Object> = {}
          rec['wsId'] = ws.wsId
          rec['name'] = ws.name
          rec['glyph'] = ws.glyph
          rec['tabs'] = ws.tabs.length
          rec['active'] = ws.activeTab
          arr.push(rec)
        }
        return { id: req.id, ok: true, data: JSON.stringify(arr) }
      }
      case 'tab.list': {
        const arr: object[] = []
        for (const t of vm.tabs) {
          const rec: Record<string, Object> = {}
          rec['tabId'] = t.tabId
          rec['title'] = t.title
          rec['panes'] = LayoutOps.panes(t.layout).length
          arr.push(rec)
        }
        return { id: req.id, ok: true, data: JSON.stringify(arr) }
      }
      case 'pane.list': {
        const arr: object[] = []
        for (const p of vm.panes) {
          const rec: Record<string, Object> = {}
          rec['paneId'] = p
          rec['focused'] = p === vm.focusedPane
          const slot = vm.sessionOf(p)
          rec['slotKind'] = slot !== null ? slot.kind : ''
          rec['title'] = slot !== null ? slot.title : ''
          arr.push(rec)
        }
        return { id: req.id, ok: true, data: JSON.stringify(arr) }
      }
      case 'send': {
        const paneId = strArg(req, 'paneId')
        const text = strArg(req, 'text')
        if (paneId === '' || text === '') {
          return { id: req.id, ok: false, error: 'send requires paneId and text' }
        }
        const host = routeToHost(paneId)
        if (host === null) {
          return { id: req.id, ok: false, error: 'pane not bound: ' + paneId }
        }
        host.write(text)
        return { id: req.id, ok: true, data: 'ok' }
      }
      case 'capture': {
        const paneId = strArg(req, 'paneId')
        const lines = intArg(req, 'lines', 40)
        if (paneId === '') {
          return { id: req.id, ok: false, error: 'capture requires paneId' }
        }
        const text = vm.paneCapture(paneId, lines)
        if (text === '') {
          return { id: req.id, ok: false, error: 'pane not bound: ' + paneId }
        }
        return { id: req.id, ok: true, data: text }
      }
      default:
        return { id: req.id, ok: false, error: 'unknown cmd: ' + req.cmd }
    }
  } catch (e) {
    return { id: req.id, ok: false, error: 'cmd error: ' + (e instanceof Error ? e.message : String(e)) }
  }
}

/** args 取 string 字段(缺失或类型错时返回空串)。 */
function strArg(req: BridgeRequest, key: string): string {
  if (req.args === undefined) {
    return ''
  }
  const v = req.args[key]
  if (v === undefined || typeof v !== 'string') {
    return ''
  }
  return v
}

/** args 取 number 字段(缺失或类型错时返回 def)。 */
function intArg(req: BridgeRequest, key: string, def: number): number {
  if (req.args === undefined) {
    return def
  }
  const v = req.args[key]
  if (v === undefined || typeof v !== 'number') {
    return def
  }
  return v
}

/** 可写宿主(write 闭包;interface 需独立声明,ArkTS 不支持内联对象字面量类型)。 */
interface HostSink {
  write: (t: string) => void
}

/** pane 路由到宿主:先本地后远程(bound 命中且 term 存在);未命中返回 null。 */
function routeToHost(paneId: string): HostSink | null {
  if (TermHost.bound() === paneId && TermHost.term() !== null) {
    const sink: HostSink = {
      write: (t: string): void => {
        TermHost.write(t)
      }
    }
    return sink
  }
  if (RemoteTermHost.bound() === paneId && RemoteTermHost.term() !== null) {
    const sink: HostSink = {
      write: (t: string): void => {
        RemoteTermHost.write(t)
      }
    }
    return sink
  }
  return null
}

/** ArrayBuffer 转 utf-8 文本(分块安全:逐字节拼,多字节字符不跨块时正确)。 */
function decodeChunk(buf: ArrayBuffer): string {
  const u8 = new Uint8Array(buf)
  let s = ''
  for (let i = 0; i < u8.length; i++) {
    s += String.fromCharCode(u8[i])
  }
  return s
}

/**
 * 命令桥单例:app 内 TCP server(仅 127.0.0.1)。生命周期由 AppShell 持有
 * (aboutToAppear setVm+start;aboutToDisappear 仅 setVm(null),连接与
 * server 保留,doctor 降级不崩)。
 */
export class CommandBridge {
  private static server: socket.TCPSocketServer | null = null
  private static running: boolean = false
  private static vm: WorkbenchVm | null = null

  /** vm 注册(ArkTS 事件循环内调用;传 null 即注销,命令降级)。 */
  static setVm(vm: WorkbenchVm | null): void {
    CommandBridge.vm = vm
  }

  static getVm(): WorkbenchVm | null {
    return CommandBridge.vm
  }

  static isRunning(): boolean {
    return CommandBridge.running
  }

  /** 起服(幂等;仅 127.0.0.1;listen 失败仅记日志不抛,不留半开)。 */
  static start(port: number): boolean {
    if (CommandBridge.running) {
      return true
    }
    try {
      const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance()
      srv.listen({ address: '127.0.0.1', port: port } as socket.NetAddress)
        .then((): void => {
          CommandBridge.server = srv
          CommandBridge.running = true
          CommandBridge.wire(srv)
          hilog.info(DOMAIN, TAG, 'bridge up port=%{public}d', port)
        })
        .catch((): void => {
          // listen 失败:server 未置,后续 start 可重试(不留半开)
          hilog.warn(DOMAIN, TAG, 'bridge listen failed port=%{public}d', port)
        })
      return true
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bridge start threw')
      return false
    }
  }

  /** 挂 connect 处理(新连接:token 握手 + 行缓冲命令循环)。 */
  private static wire(srv: socket.TCPSocketServer): void {
    srv.on('connect', (conn: socket.TCPSocketConnection): void => {
      let authed = false
      let buf = ''
      const push = (text: string): void => {
        conn.send({ data: text } as socket.TCPSendOptions).catch((): void => {
          // 对端先关:忽略
        })
      }
      conn.on('message', (info: socket.SocketMessageInfo): void => {
        buf += decodeChunk(info.message)
        let nl = buf.indexOf('\n')
        while (nl >= 0) {
          const line = buf.slice(0, nl).replace(/\r$/, '')
          buf = buf.slice(nl + 1)
          if (!authed) {
            // 首行 token(TODO-M9 常量);失败即断,绝不回显
            if (line === DEV_TOKEN) {
              authed = true
            } else {
              hilog.warn(DOMAIN, TAG, 'bridge auth rejected')
              conn.close()
              return
            }
          } else {
            const trimmed = line.trim()
            if (trimmed === '') {
              continue
            }
            const req = parseRequest(trimmed)
            let resp: BridgeResponse
            if (req === null) {
              resp = { id: -1, ok: false, error: 'bad request' }
            } else {
              resp = handleCmd(req)
            }
            push(formatResponse(resp) + '\n')
          }
          nl = buf.indexOf('\n')
        }
      })
      conn.on('close', (): void => {
        hilog.info(DOMAIN, TAG, 'bridge conn closed')
      })
      conn.on('error', (): void => {
        hilog.warn(DOMAIN, TAG, 'bridge conn error')
      })
    })
  }

  /** 停服;未跑时安全 no-op。 */
  static stop(): void {
    const srv: socket.TCPSocketServer | null = CommandBridge.server
    CommandBridge.server = null
    CommandBridge.running = false
    if (srv !== null) {
      try {
        srv.close()
      } catch (e) {
        // 关闭异常不反杀状态
      }
    }
  }
}
