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
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { TermHost } from '../term/TermHost';
import { RemoteTermHost } from '../remote/RemoteTermHost';
import { LayoutOps } from '../layout/LayoutOps';
import { AgentEventBus } from '../agent/AgentEventBus';
import { AgentEvent } from '../agent/AgentEvent';
import { GitService, GitBranchInfo, GitFileEntry, GitCommit } from '../git/GitService';
import { LayoutNode, SplitNode, SplitDir, PaneLeaf } from '../layout/LayoutTree';
import { SessionSlot } from '../model/TabState';

const DOMAIN: number = 0x0700;
const TAG: string = 'tty7.bridge';
const BRIDGE_PORT: number = 18971;
const TOKEN_FILE: string = '/cli_token';

/**
 * 双 UUID 拼 hex(任务 tty7-M9,纯函数,单测共靶):两次 generateRandomUUID
 * 各去 '-' 得 32 hex,拼接成 64 hex = 32 字节熵(单 UUID 仅 16 字节熵,
 * 不达标)。任一输入空/形态错 → ''(拒绝,不降熵)。
 */
export function joinUuidHex(a: string, b: string): string {
  const x = a.replace(/-/g, '');
  const y = b.replace(/-/g, '');
  if (x.length !== 32 || y.length !== 32) {
    return '';
  }
  if (!/^[0-9a-f]{32}$/.test(x) || !/^[0-9a-f]{32}$/.test(y)) {
    return '';
  }
  return x + y;
}

/**
 * token 恒时比较(任务 tty7-M9,纯函数,单测共靶):逐字节异或累积,
 * 不早退(长度不等也扫完短串+差值,总时恒;长度本身是公开信息)。
 * 空 token 永远 false(未生成态拒绝一切)。
 */
export function tokenTimeEqual(a: string, b: string): boolean {
  if (a === '' || b === '') {
    return false;
  }
  const n = a.length > b.length ? a.length : b.length;
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < n; i++) {
    const ca = i < a.length ? a.charCodeAt(i) : 0;
    const cb = i < b.length ? b.charCodeAt(i) : 0;
    diff |= ca ^ cb;
  }
  return diff === 0;
}

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

/**
 * CLI \r 转义(任务 tty7-M8b,纯函数,单测共靶):--text 值里的字面
 * 两字符序列 '\r'/'\n'/'\t'(反斜杠+r/n/t)转成真控制符 0x0d/0x0a/0x09
 * ——单引号 shell 传参友好(真控制符难从 VM shell 键入)。CLI 端原样传,
 * 转义统一在桥侧做。其余反斜杠序列不动(字面量)。
 */
export function escapeText(t: string): string {
  let out = ''
  for (let i = 0; i < t.length; i++) {
    const c = t.charAt(i)
    if (c === '\\' && i + 1 < t.length) {
      const n = t.charAt(i + 1)
      if (n === 'r') {
        out += '\r'
        i++
        continue
      }
      if (n === 'n') {
        out += '\n'
        i++
        continue
      }
      if (n === 't') {
        out += '\t'
        i++
        continue
      }
    }
    out += c
  }
  return out
}

/** wait 参数校验结果(纯数据;ArkTS 不收匿名对象字面量类型,独立类)。 */
export class WaitParams {
  ok: boolean = false
  timeout: number = 0
  interval: number = 0
}

/**
 * wait 参数校验/钳制(纯函数,单测共靶):match 非空;timeoutMs 缺省
 * 10000 上限 60000(≤0 回默认);intervalMs 缺省 300 下限 100(≤0 回默认)。
 */
export function waitParams(match: string, timeoutMs: number, intervalMs: number): WaitParams {
  const w = new WaitParams()
  if (match === '') {
    return w
  }
  let to = timeoutMs
  if (to <= 0) {
    to = 10000
  }
  if (to > 60000) {
    to = 60000
  }
  let iv = intervalMs
  if (iv <= 0) {
    iv = 300
  }
  if (iv < 100) {
    iv = 100
  }
  w.ok = true
  w.timeout = to
  w.interval = iv
  return w
}

/**
 * events → agents 摘要聚合(纯函数,单测共靶):按 agentId 分组,每组
 * 取最近事件的 state/type + 事件计数(agents 命令数据源;内部按 seq
 * 排序后聚合,时间序输入不影响结果)。
 */
export function agentsSummary(events: AgentEvent[]): object[] {
  const arr = events.slice().sort((a: AgentEvent, b: AgentEvent): number => {
    return a.seq - b.seq
  })
  const order: string[] = []
  const counts: Record<string, number> = {}
  const last: Record<string, AgentEvent> = {}
  for (const ev of arr) {
    const key = ev.agentId !== '' ? ev.agentId : '-'
    if (counts[key] === undefined) {
      counts[key] = 0
      order.push(key)
    }
    counts[key] = counts[key] + 1
    last[key] = ev
  }
  const out: object[] = []
  for (const k of order) {
    const ev = last[k]
    const rec: Record<string, Object> = {}
    rec['agentId'] = k
    rec['events'] = counts[k]
    let st = ''
    if (ev.type === 'state_changed') {
      st = ev.state
    } else if (ev.type === 'final') {
      st = ev.ok ? 'done' : 'error'
    }
    rec['state'] = st
    rec['lastType'] = ev.type
    rec['ts'] = ev.ts
    out.push(rec)
  }
  return out
}

/**
 * git 子命令白名单(纯函数,单测共靶):'status'|'log' 放行,其余 false
 * (桥侧 git 只读红线:写操作不经 CLI)。
 */
export function gitSubOk(sub: string): boolean {
  return sub === 'status' || sub === 'log'
}

/** 命名键 → 转义字节表(任务 tty7-PA:send --keys)。 */
const KEY_BYTES: Record<string, string> = {
  'enter': '\r',
  'escape': '\x1b',
  'tab': '\t',
  'up': '\x1b[A',
  'down': '\x1b[B',
  'right': '\x1b[C',
  'left': '\x1b[D',
  'home': '\x1b[H',
  'end': '\x1b[F',
  'backspace': '\x7f',
  'delete': '\x1b[3~',
  'space': ' ',
  'pgup': '\x1b[5~',
  'pgdn': '\x1b[6~'
}

/** 键名串 → 字节串(纯函数,单测共靶):逗号分隔键名(大小写不敏感,
 *  容空白);命名键查表;C-x 和弦=char&0x1f(C-a..C-z → \x01..\x1a,
 *  C-@..C-_ 按码表,C-c 与 C-C 同字节=Ctrl 不分大小写);任一键名
 *  未知 → ''(整串拒绝,绝不半发)。空串 → ''。 */
export function keysToBytes(names: string): string {
  if (names === '') {
    return ''
  }
  let out = ''
  const parts = names.split(',')
  for (const raw of parts) {
    const k = raw.trim().toLowerCase()
    if (k === '') {
      return ''
    }
    const hit = KEY_BYTES[k]
    if (hit !== undefined) {
      out += hit
      continue
    }
    if (k.length >= 3 && k.charAt(0) === 'c' && k.charAt(1) === '-') {
      const code = k.charCodeAt(2)
      if (code >= 64 && code <= 95) {
        out += String.fromCharCode(code & 0x1f)
        continue
      }
      if (code >= 97 && code <= 122) {
        out += String.fromCharCode(code - 96)
        continue
      }
    }
    return ''
  }
  return out
}

/** 布局节点 → 递归 JSON 记录(纯函数,单测共靶,任务 tty7-PA:ws.tree):
 *  SplitNode → {type:'split',dir,ratio,children:[...]};PaneLeaf →
 *  {type:'pane',paneId,slotKind,title}(slot 元数据经 slotOf 回调查询,
 *  未绑定 slotKind/title 为 '')。 */
export function treeToJson(node: LayoutNode, slotOf: (paneId: string) => SessionSlot | null): Record<string, Object> {
  if (node instanceof SplitNode) {
    const sp = node as SplitNode
    const rec: Record<string, Object> = {}
    rec['type'] = 'split'
    rec['dir'] = sp.dir
    rec['ratio'] = sp.ratio
    const ch: object[] = []
    for (const c of sp.children) {
      ch.push(treeToJson(c, slotOf))
    }
    rec['children'] = ch
    return rec
  }
  const leaf = node as PaneLeaf
  const rec: Record<string, Object> = {}
  rec['type'] = 'pane'
  rec['paneId'] = leaf.paneId
  const s = slotOf(leaf.paneId)
  rec['slotKind'] = s !== null ? s.kind : ''
  rec['title'] = s !== null ? s.title : ''
  return rec
}

/** pane.split dir 归一(纯函数,单测共靶):'' → 'h'(缺省);'h'/'v' 原样;
 *  其余 ''(白名单外拒)。 */
export function splitDirOf(raw: string): string {
  if (raw === '') {
    return 'h'
  }
  if (raw === 'h' || raw === 'v') {
    return raw
  }
  return ''
}

/** tab.* 命令的 index 解析(纯函数,单测共靶):iRaw>=0 用显式值,否则
 *  activeTab;越界(含 tabCount=0)→ -1。 */
export function indexArg(iRaw: number, activeTab: number, tabCount: number): number {
  const i = iRaw >= 0 ? iRaw : activeTab
  if (i < 0 || i >= tabCount) {
    return -1
  }
  return i
}

/** tab.rename 的 title 校验(纯函数,单测共靶):空串拒。 */
export function renameOk(title: string): boolean {
  return title !== ''
}

/** status 命令快照(任务 tty7-PA):桥/vm/工作台/双宿主/uptime;vm 未设
 *  时降级 {bridge,port,vm:0}(不抛)。 */
export function statusSnapshot(): Record<string, Object> {
  const vm = CommandBridge.getVm()
  const out: Record<string, Object> = {}
  out['bridge'] = CommandBridge.isRunning() ? 1 : 0
  out['port'] = BRIDGE_PORT
  if (vm === null) {
    out['vm'] = 0
    return out
  }
  out['vm'] = 1
  out['workspaces'] = vm.workspaces.length
  out['activeWs'] = vm.activeWs
  out['activeTabs'] = vm.tabs.length
  out['panes'] = vm.panes.length
  out['termLocal'] = TermHost.bound()
  out['termRemote'] = RemoteTermHost.bound()
  out['uptimeMs'] = CommandBridge.uptimeMs()
  return out
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
      case 'ws.new': {
        const wsId = vm.newWorkspaceNamed(strArg(req, 'name'))
        const ws = vm.workspaces[vm.activeWs]
        const rec: Record<string, Object> = {}
        rec['wsId'] = ws.wsId
        rec['name'] = ws.name
        return { id: req.id, ok: true, data: JSON.stringify(rec) }
      }
      case 'ws.close': {
        if (vm.workspaces.length <= 1) {
          return { id: req.id, ok: false, error: 'last workspace: refuse close' }
        }
        const closedWs = vm.workspaces[vm.activeWs].wsId
        vm.closeWorkspace(vm.activeWs)
        const rec2: Record<string, Object> = {}
        rec2['closed'] = closedWs
        return { id: req.id, ok: true, data: JSON.stringify(rec2) }
      }
      case 'ws.tree': {
        const wsT = vm.workspaces[vm.activeWs]
        const outT: Record<string, Object> = {}
        outT['id'] = wsT.wsId
        outT['name'] = wsT.name
        outT['activeTab'] = vm.activeTab
        const tabsArr: object[] = []
        for (const t of wsT.tabs) {
          const tr: Record<string, Object> = {}
          tr['tabId'] = t.tabId
          tr['title'] = t.title
          const lay: Record<string, Object> = {}
          lay['focusedPaneId'] = t.layout.focusedPaneId
          lay['root'] = treeToJson(t.layout.root, (pid: string): SessionSlot | null => {
            for (const s of t.sessions) {
              if (s.paneId === pid) {
                return s
              }
            }
            return null
          })
          tr['layout'] = lay
          tabsArr.push(tr)
        }
        outT['tabs'] = tabsArr
        return { id: req.id, ok: true, data: JSON.stringify(outT) }
      }
      case 'tab.new': {
        vm.newTab()
        const tn = vm.tabs[vm.activeTab]
        const rec3: Record<string, Object> = {}
        rec3['tabId'] = tn.tabId
        rec3['title'] = tn.title
        return { id: req.id, ok: true, data: JSON.stringify(rec3) }
      }
      case 'tab.close': {
        const i = indexArg(intArg(req, 'index', -1), vm.activeTab, vm.tabs.length)
        if (i < 0 || vm.tabs.length <= 1) {
          return { id: req.id, ok: false, error: 'tab.close refused (index out of range / last-tab guard)' }
        }
        const closedTab = vm.tabs[i].title
        vm.closeTab(i)
        const rec4: Record<string, Object> = {}
        rec4['closed'] = closedTab
        return { id: req.id, ok: true, data: JSON.stringify(rec4) }
      }
      case 'tab.rename': {
        const title = strArg(req, 'title')
        if (!renameOk(title)) {
          return { id: req.id, ok: false, error: 'tab.rename requires title' }
        }
        const i2 = indexArg(intArg(req, 'index', -1), vm.activeTab, vm.tabs.length)
        if (i2 < 0 || !vm.renameTab(i2, title)) {
          return { id: req.id, ok: false, error: 'tab.rename index out of range' }
        }
        const rec5: Record<string, Object> = {}
        rec5['tabId'] = vm.tabs[i2].tabId
        rec5['title'] = title
        return { id: req.id, ok: true, data: JSON.stringify(rec5) }
      }
      case 'pane.split': {
        const d = splitDirOf(strArg(req, 'dir'))
        if (d === '') {
          return { id: req.id, ok: false, error: 'pane.split dir must be h|v' }
        }
        const rec6: Record<string, Object> = {}
        rec6['paneId'] = vm.newPaneId(d as SplitDir)
        return { id: req.id, ok: true, data: JSON.stringify(rec6) }
      }
      case 'pane.close': {
        let pid = strArg(req, 'paneId')
        if (pid === '') {
          pid = vm.focusedPane
        }
        if (pid === '' || vm.panes.indexOf(pid) < 0) {
          return { id: req.id, ok: false, error: 'pane.close: pane not found: ' + pid }
        }
        vm.closePane(pid)
        const rec7: Record<string, Object> = {}
        rec7['closed'] = pid
        return { id: req.id, ok: true, data: JSON.stringify(rec7) }
      }
      case 'status':
        return { id: req.id, ok: true, data: JSON.stringify(statusSnapshot()) }
      case 'send': {
        const paneId = strArg(req, 'paneId')
        const text = strArg(req, 'text')
        const keysRaw = strArg(req, 'keys')
        if (paneId === '' || (text === '' && keysRaw === '')) {
          return { id: req.id, ok: false, error: 'send requires paneId and text or keys' }
        }
        let bytes = ''
        if (keysRaw !== '') {
          bytes = keysToBytes(keysRaw)
          if (bytes === '') {
            return { id: req.id, ok: false, error: 'send unknown key in: ' + keysRaw }
          }
        }
        const host = routeToHost(paneId)
        if (host === null) {
          return { id: req.id, ok: false, error: 'pane not bound: ' + paneId }
        }
        if (text !== '') {
          host.write(escapeText(text))
        }
        if (bytes !== '') {
          host.write(bytes)
        }
        return { id: req.id, ok: true, data: 'ok' }
      }
      case 'agents': {
        // bus 环形 200 条聚合;空 → [](M8b)
        const arr2 = agentsSummary(AgentEventBus.instance().recent(200))
        return { id: req.id, ok: true, data: JSON.stringify(arr2) }
      }
      case 'events': {
        // recent(n 默认 20;1..200 钳制)→ [{seq,ts,type,agentId,paneId,text 截 120}]
        const nRaw = intArg(req, 'n', 20)
        const n = nRaw > 0 ? Math.min(nRaw, 200) : 20
        const evs = AgentEventBus.instance().recent(n)
        const arr3: object[] = []
        for (const ev of evs) {
          const rec: Record<string, Object> = {}
          rec['seq'] = ev.seq
          rec['ts'] = ev.ts
          rec['type'] = ev.type
          rec['agentId'] = ev.agentId
          rec['paneId'] = ev.paneId
          rec['text'] = ev.text.length > 120 ? ev.text.substring(0, 120) : ev.text
          arr3.push(rec)
        }
        return { id: req.id, ok: true, data: JSON.stringify(arr3) }
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

/**
 * wait 命令(任务 tty7-M8b):桥内 setTimeout 链轮询——每 intervalMs 调
 * vm.paneCapture(paneId,80) 命中 match 子串即 ok 'matched';超时 error
 * 'timeout'。链式 setTimeout 不阻塞 UI 线程(回调轻:一次 capture)。
 * pane 未绑立即 error(首探 capture 空串判定)。返回 null = 已异步接管
 * (响应稍后经 push 发);非 null = 立即同步响应(参数错/pane 未绑)。
 */
function handleWait(req: BridgeRequest, push: (t: string) => void): BridgeResponse | null {
  // 热修(M8b 真机实证):setTimeout 回调跨上下文调 conn.send 触发 native
  // 崩溃(app 进程死,18971 随之 ECONNREFUSED)——wait 轮询移到 CLI 客户端
  // 侧(capture 循环),桥侧只做参数校验并同步指引。
  const paneId = strArg(req, 'paneId')
  const match = strArg(req, 'match')
  const pr = waitParams(match, intArg(req, 'timeoutMs', 0), intArg(req, 'intervalMs', 0))
  if (paneId === '' || !pr.ok) {
    return { id: req.id, ok: false, error: 'wait requires paneId and match' }
  }
  return { id: req.id, ok: false, error: 'wait is client-side: poll capture from CLI' }
}

/**
 * git 命令(任务 tty7-M8b):sub 白名单 status/log → GitService 异步回调
 * (响应在回调里经 push 发);runner 未受理(无远程会话/通道忙)→
 * error 'remote not connected'。git 只读红线:写操作子命令一律白名单外。
 */
function handleGit(req: BridgeRequest, push: (t: string) => void): void {
  // 热修(M8b 真机实证):GitService 回调经 setTimeout 链跨上下文调 conn.send
  // 与 wait 同因崩桥——git 快捷改为同步降级指引,编排走 CLI 侧
  // send('git status')+wait+capture 组合(tools/README.md 有示例)。
  const sub = strArg(req, 'sub')
  if (sub !== 'status' && sub !== 'log') {
    push(formatResponse({ id: req.id, ok: false, error: 'git sub must be status|log' }) + '\n')
    return
  }
  push(formatResponse({ id: req.id, ok: false, error: 'git: use cli-side send+wait+capture combo' }) + '\n')
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
  private static tok: string = ''
  private static startMs: number = 0

  /**
   * 真 token(M9):filesDir/cli_token 读/生成/写(双 UUID 64 hex);
   * 文件读写失败降级内存 token(app 本次生命周期内一致)。token 绝不
   * 进 hilog/不回显全量(tokenPrefix 只显前 4 字)。
   */
  static token(): string {
    if (CommandBridge.tok !== '') {
      return CommandBridge.tok
    }
    let fromFile = ''
    try {
      const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
      if (filesDir !== '') {
        const p = filesDir + TOKEN_FILE
        try {
          const t = fs.readTextSync(p).trim()
          if (t !== '' && t.length <= 128) {
            fromFile = t
          }
        } catch (e) {
          // 无文件:首次冷启,走生成
        }
        if (fromFile === '') {
          const gen = joinUuidHex(util.generateRandomUUID(false), util.generateRandomUUID(false))
          if (gen !== '') {
            const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
            fs.writeSync(f.fd, gen)
            fs.closeSync(f)
            fromFile = gen
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bridge token io failed')
    }
    if (fromFile === '') {
      // 降级:内存 token(本次进程生命周期一致;下次冷启重生成)
      fromFile = joinUuidHex(util.generateRandomUUID(false), util.generateRandomUUID(false))
    }
    CommandBridge.tok = fromFile
    return fromFile
  }

  /** token 前 4 字(palette 状态展示;肩窥安全,不回显全量)。 */
  static tokenPrefix(): string {
    const t = CommandBridge.token()
    return t !== '' ? t.substring(0, 4) : ''
  }

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

  /** 桥运行时长 ms(未起服 0;任务 tty7-PA:status.uptimeMs)。 */
  static uptimeMs(): number {
    return CommandBridge.startMs > 0 ? Date.now() - CommandBridge.startMs : 0
  }

  /** 起服(幂等;仅 127.0.0.1;listen 失败仅记日志不抛,不留半开)。 */
  static start(port: number): boolean {
    if (CommandBridge.running) {
      return true
    }
    // M9:冷启即生成/加载 token(判据:filesDir/cli_token 落盘)
    CommandBridge.token()
    try {
      const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance()
      srv.listen({ address: '127.0.0.1', port: port } as socket.NetAddress)
        .then((): void => {
          CommandBridge.server = srv
          CommandBridge.running = true
          CommandBridge.startMs = Date.now()
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
            // 首行 token(filesDir/cli_token 真文件,M9);失败即断,绝不回显
            if (tokenTimeEqual(line, CommandBridge.token())) {
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
            if (req === null) {
              push(formatResponse({ id: -1, ok: false, error: 'bad request' }) + '\n')
              continue
            }
            // M8b 异步命令分流:wait(轮询)/git(远程回调)响应异步发,
            // 同连接后续请求并发处理(CLI 按响应 id 匹配)。
            if (req.cmd === 'wait') {
              const pr = handleWait(req, push)
              if (pr !== null) {
                push(formatResponse(pr) + '\n')
              }
              continue
            }
            if (req.cmd === 'git') {
              handleGit(req, push)
              continue
            }
            push(formatResponse(handleCmd(req)) + '\n')
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
