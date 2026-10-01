/**
 * upstream M6 relay3 - AI 智能体内核(ArkTS 原生, hmharness 式多轮 function-calling)。
 *
 * 回路: run(userText) → while(round < 12):
 *   chatWithTools(带 4 工具) → 有 tool_calls → 逐个过审批门(需确认时 emit 审批卡
 *   + Promise 挂起, UI 允许/拒绝回调续跑) → 执行 → role:'tool' 回填 → continue;
 *   无 tool_calls → 最终答复, done。
 *
 * 4 工具(走既有服务):
 *   term_write(cmd)    → SessionService.write(危险判定黑名单正则)
 *   term_read(lastN)   → SessionService.screenText
 *   session_info()     → 会话状态快照
 *   sftp_list(path)    → ssh.sftpList(sessionId)
 *
 * 审计: 每轮 append filesDir/agent-audit.jsonl(ts/round/tool/args/result 摘要)。
 * 上下文预算: term_read lastN≤40 行; 历史消息 >20 轮时截断中间。
 * 全程事件回调驱动 UI(无后台 setInterval);轮次推进靠 Promise 续跑。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { Llm, LlmConfig, LlmMsg, OaiToolCall } from './Llm';
import { LlmConfigStore } from './LlmConfigStore';
import { SessionService } from './SessionService';
import { AgentSettings, AgentSettingsStore, ApprovalMode } from './AgentSettingsStore';

const TAG: string = 'oat.agent';
const DOMAIN: number = 0x0110;
const MAX_ROUNDS: number = 12;
const MAX_HISTORY: number = 20;

/** 内核发往 UI 的事件(AIDock 渲染三类消息 + 审批卡)。 */
export interface KernelEvent {
  kind: string
  // 'user' 用户指令 | 'assistant' 模型文本 | 'tool' 工具卡(name+args+result)
  // | 'need_approval' 审批请求(callId+name+args) | 'approved'/'denied' 审批结果
  // | 'round' 轮次指示 | 'done' 完成 | 'err' 错误
  text: string
  name: string
  args: string
  result: string
  callId: string
  round: number
}

/** 审计 jsonl 单行结构。 */
interface AuditRow {
  ts: number
  round: number
  tool: string
  args: string
  ok: boolean
  approved: boolean
  result: string
}

export class AgentKernel {
  static onEvent: (e: KernelEvent) => void = (e: KernelEvent) => {
  }
  private static busy: boolean = false
  private static round: number = 0
  // 审批挂起: callId → resolver(true=允许 / false=拒绝)
  private static pendingResolve: ((ok: boolean) => void) | null = null
  private static pendingCallId: string = ''

  /** UI 允许按钮回调(续跑挂起的轮次)。 */
  static approve(): void {
    hilog.info(DOMAIN, TAG, 'approve callId=%{public}s', AgentKernel.pendingCallId)
    const r = AgentKernel.pendingResolve
    if (r !== null) {
      AgentKernel.pendingResolve = null
      AgentKernel.pendingCallId = ''
      r(true)
    }
  }

  /** UI 拒绝按钮回调(工具结果=已拒绝, 模型继续)。 */
  static deny(): void {
    hilog.info(DOMAIN, TAG, 'deny callId=%{public}s', AgentKernel.pendingCallId)
    const r = AgentKernel.pendingResolve
    if (r !== null) {
      AgentKernel.pendingResolve = null
      AgentKernel.pendingCallId = ''
      r(false)
    }
  }

  /** 4 工具的 OpenAI tools 参数 JSON(Record 组装避免双重序列化)。 */
  static toolsJson(): string {
    // parameters JSON Schema 子对象(properties 值必须是 schema 对象, 非描述文本)
    const p1: Record<string, Object> = {}
    const p1cmd: Record<string, Object> = {}
    p1cmd['type'] = 'string'
    p1cmd['description'] = 'shell 命令文本(不含换行结尾)'
    p1['cmd'] = p1cmd
    const fn1p: Record<string, Object> = {}
    fn1p['type'] = 'object'
    fn1p['properties'] = p1
    const fn1req: string[] = ['cmd']
    fn1p['required'] = fn1req
    const fn1: Record<string, Object> = {}
    fn1['name'] = 'term_write'
    fn1['description'] = '在当前终端会话执行一条 shell 命令并等待输出完成。危险命令需用户审批。'
    fn1['parameters'] = fn1p

    const p2: Record<string, Object> = {}
    const p2n: Record<string, Object> = {}
    p2n['type'] = 'number'
    p2n['description'] = '返回最后 N 行'
    p2['lastN'] = p2n
    const fn2p: Record<string, Object> = {}
    fn2p['type'] = 'object'
    fn2p['properties'] = p2
    const fn2: Record<string, Object> = {}
    fn2['name'] = 'term_read'
    fn2['description'] = '读取终端屏幕最近输出。lastN: 返回最后 N 行(1-40, 默认 24)'
    fn2['parameters'] = fn2p

    const fn3p: Record<string, Object> = {}
    fn3p['type'] = 'object'
    const fn3: Record<string, Object> = {}
    fn3['name'] = 'session_info'
    fn3['description'] = '获取当前终端会话信息(类型/状态/连接标签)'
    fn3['parameters'] = fn3p

    const p4: Record<string, Object> = {}
    const p4p: Record<string, Object> = {}
    p4p['type'] = 'string'
    p4p['description'] = '远端路径'
    p4['path'] = p4p
    const fn4p: Record<string, Object> = {}
    fn4p['type'] = 'object'
    fn4p['properties'] = p4
    const fn4: Record<string, Object> = {}
    fn4['name'] = 'sftp_list'
    fn4['description'] = '列出当前 SSH 会话远端目录内容。path: 远端路径(默认 .)'
    fn4['parameters'] = fn4p

    const mk = (fn: Record<string, Object>): Record<string, Object> => {
      const s: Record<string, Object> = {}
      s['type'] = 'function'
      s['function'] = fn
      return s
    }
    const arr: Record<string, Object>[] = [mk(fn1), mk(fn2), mk(fn3), mk(fn4)]
    return JSON.stringify(arr)
  }

  /** 危险命令黑名单(rm -rf 必中: rm 后跟空白)。 */
  static riskOf(cmd: string): string {
    const d = /rm\s|mkfs|dd\s|reboot|shutdown|kill|chmod|chown|>\s*\/|curl.*\|\s*sh|wget.*\|\s*sh/
    if (d.test(cmd)) {
      return 'dangerous'
    }
    const r = /^(ls|cat|pwd|whoami|uname|df|free|ps|ip|ifconfig|netstat|uptime|top|head|tail|grep|echo|date|id)\b/
    if (r.test(cmd)) {
      return 'read'
    }
    return 'write'
  }

  /** 审批门: 全部确认→true; 仅危险→risk==='dangerous'; 全自动→false。 */
  static needConfirm(mode: ApprovalMode, risk: string): boolean {
    if (mode === 'confirm_all') {
      return true
    }
    if (mode === 'confirm_dangerous') {
      return risk === 'dangerous'
    }
    return false
  }

  /** 入口: 用户指令 → 多轮回路。 */
  static async run(userText: string): Promise<void> {
    if (AgentKernel.busy) {
      hilog.warn(DOMAIN, TAG, 'busy, ignore new run')
      return
    }
    AgentKernel.busy = true
    AgentKernel.round = 0
    AgentKernel.emit({ kind: 'user', text: userText, name: '', args: '', result: '', callId: '', round: 0 })
    try {
      const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
      const cfg: LlmConfig = LlmConfigStore.read(filesDir)
      if (cfg.apiKey === '') {
        AgentKernel.emit({ kind: 'err', text: '未配置模型(设置→AI 模型)', name: '', args: '', result: '', callId: '', round: 0 })
        return
      }
      const settings = AgentSettingsStore.read(filesDir)
      hilog.info(DOMAIN, TAG, 'run mode=%{public}s rounds<=12', settings.mode)
      const system = '你是一站AI终端的智能体。可用工具: term_write(执行shell命令,危险命令需用户审批)、' +
        'term_read(读终端屏幕)、session_info(会话信息)、sftp_list(列远端目录)。' +
        '完成用户任务时优先用工具,所有命令必须经 term_write 执行;' +
        '执行后用 term_read 查看输出再决定下一步;完成后直接文字答复,不再调用工具。'
      const hist: LlmMsg[] = []
      const userMsg = new LlmMsg()
      userMsg.role = 'user'
      userMsg.text = userText
      hist.push(userMsg)
      let final = ''
      for (let r = 1; r <= MAX_ROUNDS; r++) {
        AgentKernel.round = r
        AgentKernel.emit({ kind: 'round', text: '', name: '', args: '', result: '', callId: '', round: r })
        const res = await Llm.chatWithTools(cfg, AgentKernel.trimHistory(hist), system, AgentKernel.toolsJson())
        hilog.info(DOMAIN, TAG, 'round %{public}d finish=%{public}s calls=%{public}s',
          r, res.finishReason, res.toolCallsJson.substring(0, 120))
        if (res.toolCallsJson === '[]' || res.toolCallsJson === '') {
          final = res.content
          break
        }
        // assistant 轮回填(tool_calls)
        const am = new LlmMsg()
        am.role = 'assistant'
        am.text = res.content
        am.toolCallsJson = res.toolCallsJson
        hist.push(am)
        const calls = JSON.parse(res.toolCallsJson) as OaiToolCall[]
        for (const tc of calls) {
          const outcome = await AgentKernel.handleToolCall(tc, settings.mode, r)
          // role:tool 回填
          const tm = new LlmMsg()
          tm.role = 'tool'
          tm.toolCallId = tc.id
          tm.text = outcome
          hist.push(tm)
        }
      }
      if (final === '') {
        final = '已达最大轮次(12),任务暂停。可继续发送指令续跑。'
      }
      AgentKernel.emit({ kind: 'done', text: final, name: '', args: '', result: '', callId: '', round: AgentKernel.round })
      AgentKernel.audit(0, 'run', userText.substring(0, 200), true, true, final.substring(0, 200))
    } catch (e) {
      const msg = e instanceof Error ? e.message : JSON.stringify(e)
      hilog.error(DOMAIN, TAG, 'run FAIL %{public}s', msg)
      AgentKernel.emit({ kind: 'err', text: '执行失败: ' + msg, name: '', args: '', result: '', callId: '', round: AgentKernel.round })
    } finally {
      AgentKernel.busy = false
    }
  }

  /** 单个 tool_call: 审批门 → 执行 → 返回工具结果文本。 */
  private static async handleToolCall(tc: OaiToolCall, mode: ApprovalMode, round: number): Promise<string> {
    let args: string = ''
    if (tc.name === 'term_write') {
      args = AgentKernel.argString(tc.arguments, 'cmd')
    } else if (tc.name === 'term_read') {
      args = AgentKernel.argString(tc.arguments, 'lastN')
    } else if (tc.name === 'sftp_list') {
      args = AgentKernel.argString(tc.arguments, 'path')
    } else if (tc.name === 'session_info') {
      args = ''
    } else {
      AgentKernel.emit({ kind: 'tool', text: '', name: tc.name, args: tc.arguments, result: '未知工具: ' + tc.name, callId: tc.id, round: round })
      return '未知工具: ' + tc.name
    }
    // 审批门
    if (tc.name === 'term_write') {
      const risk = AgentKernel.riskOf(args)
      if (AgentKernel.needConfirm(mode, risk)) {
        const ok = await AgentKernel.requestApproval(tc.id, tc.name, args, round)
        if (!ok) {
          const denied = '用户拒绝执行该命令。'
          AgentKernel.emit({ kind: 'tool', text: '', name: tc.name, args: args, result: denied, callId: tc.id, round: round })
          AgentKernel.audit(round, tc.name, args, false, false, denied)
          return denied
        }
      }
    }
    // 执行
    let out = ''
    let ok = true
    try {
      if (tc.name === 'term_write') {
        out = await AgentKernel.termWrite(args)
      } else if (tc.name === 'term_read') {
        out = AgentKernel.termRead(tc.arguments)
      } else if (tc.name === 'session_info') {
        out = AgentKernel.sessionInfo()
      } else if (tc.name === 'sftp_list') {
        out = await AgentKernel.sftpList(args)
      }
    } catch (e) {
      ok = false
      out = '工具执行异常: ' + (e instanceof Error ? e.message : JSON.stringify(e))
    }
    AgentKernel.emit({ kind: 'tool', text: '', name: tc.name, args: args, result: out, callId: tc.id, round: round })
    AgentKernel.audit(round, tc.name, args, ok, true, out)
    return out
  }

  /** 挂起等待 UI 审批(Promise 不落地不推进)。 */
  private static requestApproval(callId: string, name: string, args: string, round: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      AgentKernel.pendingResolve = resolve
      AgentKernel.pendingCallId = callId
      AgentKernel.emit({ kind: 'need_approval', text: '', name: name, args: args, result: '', callId: callId, round: round })
      hilog.info(DOMAIN, TAG, 'need_approval callId=%{public}s cmd=%{public}s', callId, args)
    })
  }

  /** term_write: 写入命令 → 屏幕指纹轮询等输出稳定 → 返回增量输出。 */
  private static async termWrite(cmd: string): Promise<string> {
    if (!SessionService.hasSession()) {
      return '无活动终端会话'
    }
    const before = SessionService.screenText(4000)
    const n = SessionService.write(cmd + '\n')
    if (n < 0) {
      return '命令写入失败'
    }
    // 屏幕指纹对比轮询(上限 8s): 文本稳定 1.2s 或命中提示符即收
    return await AgentKernel.waitScreen(before, 8000)
  }

  /** 轮询屏幕文本直到稳定(与 before 不同且连续两次采样一致)。 */
  private static async waitScreen(before: string, maxMs: number): Promise<string> {
    const t0 = Date.now()
    let last = ''
    let stable = 0
    while (Date.now() - t0 < maxMs) {
      await AgentKernel.sleep(400)
      const cur = SessionService.screenText(4000)
      if (cur !== before && cur === last) {
        stable++
        if (stable >= 2) {
          return cur
        }
      } else {
        stable = 0
      }
      last = cur
      // 提示符回落启发: 新行以 $/#/❯ 结尾且长度>4 → 已回到 shell
      const lines = cur.split('\n')
      const lastLine = lines.length > 0 ? lines[lines.length - 2] : ''
      if (cur !== before && lastLine !== '' && /[$#❯]\s*$/.test(lastLine)) {
        return cur
      }
    }
    return last
  }

  /** term_read: 屏幕末 lastN 行(≤40)。 */
  private static termRead(argsJson: string): string {
    let n = 24
    try {
      const o = JSON.parse(argsJson) as Record<string, Object>
      const v = o['lastN']
      if (typeof v === 'number') {
        n = v as number
      }
    } catch (e) {
    }
    if (n < 1) {
      n = 1
    }
    if (n > 40) {
      n = 40
    }
    return SessionService.screenText(4000).split('\n').slice(-n).join('\n')
  }

  /** session_info: 会话状态快照。 */
  private static sessionInfo(): string {
    const status = AppStorage.get<string>('ut.term.status') ?? 'unknown'
    const title = AppStorage.get<string>('ut.term.title') ?? ''
    return JSON.stringify({ status: status, title: title, hasSession: SessionService.hasSession(), sessionId: SessionService.getSessionId() })
  }

  /** sftp_list: 列远端目录(复用活动 SSH 会话)。 */
  private static async sftpList(path: string): Promise<string> {
    const ssh = SessionService.sshHandle()
    const sid = SessionService.getSessionId()
    if (ssh === null || sid < 0) {
      return '无活动 SSH 会话'
    }
    const json = await ssh.sftpList(sid, path === '' ? '.' : path)
    return json.substring(0, 3000)
  }

  /** 历史预算: >MAX_HISTORY 条消息截断中间(保头尾)。 */
  private static trimHistory(hist: LlmMsg[]): LlmMsg[] {
    if (hist.length <= MAX_HISTORY) {
      return hist
    }
    const head = hist.slice(0, 2)
    const tail = hist.slice(hist.length - (MAX_HISTORY - 2))
    return head.concat(tail)
    // 注: 中间被截断,模型可能看不到早期上下文;预算换 token 安全。
  }

  private static argString(argsJson: string, key: string): string {
    try {
      const o = JSON.parse(argsJson) as Record<string, Object>
      const v = o[key]
      if (typeof v === 'string') {
        return v
      }
      if (typeof v === 'number') {
        return (v as number).toString()
      }
    } catch (e) {
    }
    return ''
  }

  /** 审计: append 一行 jsonl(filesDir/agent-audit.jsonl)。 */
  private static audit(round: number, tool: string, args: string, ok: boolean, approved: boolean, result: string): void {
    try {
      const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
      if (filesDir === '') {
        return
      }
      const row: AuditRow = {
        ts: Date.now(), round: round, tool: tool, args: args,
        ok: ok, approved: approved, result: result.substring(0, 300)
      }
      const p = filesDir + '/agent-audit.jsonl'
      let f: fs.File | null = null
      try {
        f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
        fs.writeSync(f.fd, JSON.stringify(row) + '\n')
        fs.closeSync(f)
      } catch (e) {
        if (f !== null) {
          try {
            fs.closeSync(f)
          } catch (e2) {
          }
        }
        hilog.warn(DOMAIN, TAG, 'audit append fail %{public}s', JSON.stringify(e))
      }
    } catch (e) {
    }
  }

  private static emit(e: KernelEvent): void {
    AgentKernel.onEvent(e)
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>(resolve => setTimeout(resolve, ms))
  }
}
