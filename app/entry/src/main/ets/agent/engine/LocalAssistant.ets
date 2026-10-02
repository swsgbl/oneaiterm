/**
 * LocalAssistant 本地引擎（升级 Phase 1 / 任务 2.9，design 2.2.2.9）。
 *
 * implements AgentProvider；存量 AgentKernel 的 12 轮 function-calling 回路等价迁入：
 *   - busy 静态单例 → 会话实例（多会话并存，cancelled 标志可中断）；
 *   - 工具注册表数据驱动化（ToolDef 元数据 + schema，替代 toolsJson/handleToolCall
 *     双 switch 硬编码）；
 *   - term_write/term_read/sftp_list/session_info 工具执行继续走 SessionService
 *     （底座行为不变，design 1.2.4）；
 *   - 工具执行前经 PolicyEngine 判定、审批经 ApprovalManager、审计经 AuditWriter，
 *     完整走 request → policy → approval → execute → audit；
 *   - 历史预算截断（>20 条保头尾）与 term_write 屏幕指纹轮询逻辑等价迁移。
 * 回落角色：HMH/ACP 不可达时的默认回落引擎（spec 4.2.1）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AgentEvent, AgentEventListener, AgentProvider, AgentSessionConfig,
  AgentSessionHandle, AGENT_MODEL_NOT_CONFIGURED, AGENT_SESSION_NOT_FOUND,
  ApprovalDecision, ApprovalPolicyKind, ApprovalView, CapabilityLevel,
  PromptAck, PromptInput, ToolCallView, Unsubscribe
} from '../AgentProvider';
import { AgentSessionMeta, AgentSessionStore } from '../AgentSessionStore';
import { PolicyEngine, ToolCallContext } from '../security/PolicyEngine';
import { ApprovalManager } from '../security/ApprovalManager';
import { AuditWriter, AuditRecord } from '../security/AuditWriter';
import { Llm, LlmConfig, LlmMsg, OaiToolCall } from '../../service/Llm';
import { LlmConfigStore } from '../../service/LlmConfigStore';
import { AgentSettings, AgentSettingsStore } from '../../service/AgentSettingsStore';
import { SessionService } from '../../service/SessionService';

const TAG: string = 'oat.local';
const DOMAIN: number = 0x0110;
const MAX_ROUNDS: number = 12;
const MAX_HISTORY: number = 20;
const SCREEN_READ_LENGTH: number = 4000;
const SCREEN_WAIT_MS: number = 8000;
const SFTP_RESULT_MAX_LENGTH: number = 3000;

/** 工具注册表条目（数据驱动，替代硬编码双 switch）。 */
class ToolDef {
  name: string = ''
  description: string = ''
  /** 参数 JSON Schema 子对象（properties）。 */
  properties: Record<string, Object> = {}
  required: string[] = []
}

/** 会话实例状态（替代静态 busy 单例）。 */
class LocalSessionState {
  sessionId: string = ''
  hist: LlmMsg[] = []
  round: number = 0
  busy: boolean = false
  cancelled: boolean = false
  title: string = ''
  approval: ApprovalManager | null = null
}

export class LocalAssistant implements AgentProvider {
  private filesDir: string = ''
  private sessions: Map<string, LocalSessionState> = new Map()
  private listeners: Map<string, AgentEventListener[]> = new Map()
  private tools: ToolDef[] = []

  constructor(filesDir: string) {
    this.filesDir = filesDir
    this.registerTools()
  }

  // ===== 工具注册表（数据驱动） =====
  private registerTools(): void {
    const p1cmd: Record<string, Object> = {}
    p1cmd['type'] = 'string'
    p1cmd['description'] = 'shell 命令文本(不含换行结尾)'
    const p1: Record<string, Object> = {}
    p1['cmd'] = p1cmd

    const p2n: Record<string, Object> = {}
    p2n['type'] = 'number'
    p2n['description'] = '返回最后 N 行'
    const p2: Record<string, Object> = {}
    p2['lastN'] = p2n

    const p4p: Record<string, Object> = {}
    p4p['type'] = 'string'
    p4p['description'] = '远端路径'
    const p4: Record<string, Object> = {}
    p4['path'] = p4p

    const t1 = new ToolDef()
    t1.name = 'term_write'
    t1.description = '在当前终端会话执行一条 shell 命令并等待输出完成。危险命令需用户审批。'
    t1.properties = p1
    t1.required = ['cmd']
    const t2 = new ToolDef()
    t2.name = 'term_read'
    t2.description = '读取终端屏幕最近输出。lastN: 返回最后 N 行(1-40, 默认 24)'
    t2.properties = p2
    const t3 = new ToolDef()
    t3.name = 'session_info'
    t3.description = '获取当前终端会话信息(类型/状态/连接标签)'
    const t4 = new ToolDef()
    t4.name = 'sftp_list'
    t4.description = '列出当前 SSH 会话远端目录内容。path: 远端路径(默认 .)'
    t4.properties = p4
    this.tools = [t1, t2, t3, t4]
  }

  /** OpenAI tools 参数 JSON（Record 组装避免双重序列化，等价存量 toolsJson）。 */
  private toolsJson(): string {
    const mk = (t: ToolDef): Record<string, Object> => {
      const fnp: Record<string, Object> = {}
      fnp['type'] = 'object'
      fnp['properties'] = t.properties
      if (t.required.length > 0) {
        fnp['required'] = t.required
      }
      const fn: Record<string, Object> = {}
      fn['name'] = t.name
      fn['description'] = t.description
      fn['parameters'] = fnp
      const s: Record<string, Object> = {}
      s['type'] = 'function'
      s['function'] = fn
      return s
    }
    const arr: Record<string, Object>[] = []
    for (const t of this.tools) {
      arr.push(mk(t))
    }
    return JSON.stringify(arr)
  }

  // ===== 事件 =====
  private emit(sessionId: string, e: AgentEvent): void {
    const ls = this.listeners.get(sessionId)
    if (ls !== undefined) {
      for (const l of ls) {
        l(e)
      }
    }
  }

  private emitMsg(sessionId: string, kind: 'message' | 'done' | 'error', text: string, turn: number, errCode: string): void {
    const e = new AgentEvent()
    e.kind = kind
    e.sessionId = sessionId
    e.turn = turn
    e.text = text
    e.errCode = errCode
    this.emit(sessionId, e)
  }

  private emitTurn(sessionId: string, turn: number): void {
    const e = new AgentEvent()
    e.kind = 'turn'
    e.sessionId = sessionId
    e.turn = turn
    this.emit(sessionId, e)
  }

  private emitTool(sessionId: string, turn: number, level: CapabilityLevel | '', name: string, argsDigest: string, result: string, isError: boolean): void {
    const e = new AgentEvent()
    e.kind = 'tool_call'
    e.sessionId = sessionId
    e.turn = turn
    e.level = level
    const tv = new ToolCallView()
    tv.name = name
    tv.argsDigest = argsDigest
    tv.result = result
    tv.isError = isError
    e.tool = tv
    this.emit(sessionId, e)
  }

  // ===== 六方法 =====
  async createSession(config: AgentSessionConfig): Promise<AgentSessionHandle> {
    const sid = AgentSessionStore.newId()
    const st = new LocalSessionState()
    st.sessionId = sid
    st.title = config.title
    this.sessions.set(sid, st)
    const meta = new AgentSessionMeta()
    meta.sessionId = sid
    meta.engine = 'local'
    meta.state = 'active'
    meta.createdAt = Date.now()
    meta.updatedAt = Date.now()
    meta.title = config.title
    AgentSessionStore.create(this.filesDir, meta)
    const h = new AgentSessionHandle()
    h.sessionId = sid
    h.engine = 'local'
    h.resumed = false
    const e = new AgentEvent()
    e.kind = 'session_started'
    e.sessionId = sid
    this.emit(sid, e)
    return h
  }

  async resumeSession(sessionId: string): Promise<AgentSessionHandle> {
    const meta = AgentSessionStore.read(this.filesDir, sessionId)
    const h = new AgentSessionHandle()
    h.sessionId = sessionId
    if (meta === null) {
      h.engine = 'local'
      h.resumed = false
      return h
    }
    if (meta.engine !== 'local') {
      // 引擎类型错配：由 AgentAdapter 层拒绝；此处返回原引擎标注
      h.engine = meta.engine
      h.resumed = false
      return h
    }
    let st = this.sessions.get(sessionId)
    if (st === undefined) {
      st = new LocalSessionState()
      st.sessionId = sessionId
      st.title = meta.title
      // 从持久化 historyDigest 重建历史
      if (meta.historyDigest !== '') {
        try {
          st.hist = JSON.parse(meta.historyDigest) as LlmMsg[]
        } catch (e) {
          st.hist = []
        }
      }
      this.sessions.set(sessionId, st)
    }
    st.cancelled = false
    AgentSessionStore.update(this.filesDir, meta)
    h.engine = 'local'
    h.resumed = true
    const e = new AgentEvent()
    e.kind = 'session_resumed'
    e.sessionId = sessionId
    this.emit(sessionId, e)
    return h
  }

  async prompt(sessionId: string, input: PromptInput): Promise<PromptAck> {
    const ack = new PromptAck()
    ack.sessionId = sessionId
    const st = this.sessions.get(sessionId)
    if (st === undefined) {
      ack.accepted = false
      ack.errCode = AGENT_SESSION_NOT_FOUND
      return ack
    }
    if (st.busy) {
      ack.accepted = false
      return ack
    }
    // 会话标题：首条 prompt 摘要
    if (st.title === '') {
      st.title = input.text.substring(0, 40)
      const meta = AgentSessionStore.read(this.filesDir, sessionId)
      if (meta !== null) {
        meta.title = st.title
        AgentSessionStore.update(this.filesDir, meta)
      }
    }
    ack.accepted = true
    ack.turn = 0
    // 异步回路（结果经事件流回报）
    this.runSession(st, input.text).then((): void => {
      hilog.info(DOMAIN, TAG, 'session done %{public}s', sessionId)
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'session FAIL %{public}s', e instanceof Error ? e.message : String(e))
    })
    return ack
  }

  async cancel(sessionId: string, reason: string): Promise<void> {
    const st = this.sessions.get(sessionId)
    if (st === undefined) {
      return
    }
    st.cancelled = true
    const meta = AgentSessionStore.read(this.filesDir, sessionId)
    if (meta !== null) {
      meta.state = 'cancelled'
      AgentSessionStore.update(this.filesDir, meta)
    }
    hilog.info(DOMAIN, TAG, 'cancel %{public}s reason=%{public}s', sessionId, reason)
  }

  async approve(sessionId: string, requestId: string, decision: ApprovalDecision): Promise<void> {
    const st = this.sessions.get(sessionId)
    if (st === undefined || st.approval === null) {
      return
    }
    st.approval.resolve(requestId, decision)
  }

  subscribe(sessionId: string, listener: AgentEventListener): Unsubscribe {
    let ls = this.listeners.get(sessionId)
    if (ls === undefined) {
      ls = []
      this.listeners.set(sessionId, ls)
    }
    ls.push(listener)
    return (): void => {
      const cur = this.listeners.get(sessionId)
      if (cur === undefined) {
        return
      }
      const idx = cur.indexOf(listener)
      if (idx >= 0) {
        cur.splice(idx, 1)
      }
    }
  }

  // ===== 12 轮回路（等价迁移 AgentKernel.run） =====
  private async runSession(st: LocalSessionState, userText: string): Promise<void> {
    const sid = st.sessionId
    st.busy = true
    st.cancelled = false
    st.round = 0
    const userMsg = new LlmMsg()
    userMsg.role = 'user'
    userMsg.text = userText
    st.hist.push(userMsg)
    try {
      const cfg: LlmConfig = LlmConfigStore.read(this.filesDir)
      const settings: AgentSettings = AgentSettingsStore.read(this.filesDir)
      if (settings.engines.local.model !== '') {
        cfg.model = settings.engines.local.model
      }
      if (cfg.apiKey === '') {
        this.emitMsg(sid, 'error', '未配置模型(设置→AI 模型)', 0, AGENT_MODEL_NOT_CONFIGURED)
        this.finishSession(st, 'aborted')
        return
      }
      const policy = settings.security.approvalPolicy
      hilog.info(DOMAIN, TAG, 'run policy=%{public}s rounds<=12', policy)
      const system = '你是一站AI终端的智能体。可用工具: term_write(执行shell命令,危险命令需用户审批)、' +
        'term_read(读终端屏幕)、session_info(会话信息)、sftp_list(列远端目录)。' +
        '完成用户任务时优先用工具,所有命令必须经 term_write 执行;' +
        '执行后用 term_read 查看输出再决定下一步;完成后直接文字答复,不再调用工具。'
      let final = ''
      for (let r = 1; r <= MAX_ROUNDS; r++) {
        if (st.cancelled) {
          break
        }
        st.round = r
        if (st.approval !== null) {
          st.approval.setTurn(r)
        }
        this.emitTurn(sid, r)
        const res = await Llm.chatWithTools(cfg, this.trimHistory(st.hist), system, this.toolsJson())
        hilog.info(DOMAIN, TAG, 'round %{public}d finish=%{public}s calls=%{public}s',
          r, res.finishReason, res.toolCallsJson.substring(0, 120))
        if (res.toolCallsJson === '[]' || res.toolCallsJson === '') {
          final = res.content
          break
        }
        const am = new LlmMsg()
        am.role = 'assistant'
        am.text = res.content
        am.toolCallsJson = res.toolCallsJson
        st.hist.push(am)
        const calls = JSON.parse(res.toolCallsJson) as OaiToolCall[]
        for (const tc of calls) {
          if (st.cancelled) {
            break
          }
          const outcome = await this.handleToolCall(st, tc, policy, r)
          const tm = new LlmMsg()
          tm.role = 'tool'
          tm.toolCallId = tc.id
          tm.text = outcome
          st.hist.push(tm)
        }
      }
      if (final === '') {
        final = st.cancelled ? '任务已取消。' : '已达最大轮次(12),任务暂停。可继续发送指令续跑。'
      }
      this.emitMsg(sid, 'done', final, st.round, '')
      this.auditRun(st, userText, final)
      this.finishSession(st, st.cancelled ? 'cancelled' : 'finished')
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      hilog.error(DOMAIN, TAG, 'run FAIL %{public}s', msg)
      this.emitMsg(sid, 'error', '执行失败: ' + msg, st.round, '')
      this.finishSession(st, 'aborted')
    } finally {
      st.busy = false
    }
  }

  /** 单个 tool_call：request → policy → approval → execute → audit（任何步骤不可跳过）。 */
  private async handleToolCall(st: LocalSessionState, tc: OaiToolCall, policy: ApprovalPolicyKind, round: number): Promise<string> {
    const sid = st.sessionId
    const known = tc.name === 'term_write' || tc.name === 'term_read' || tc.name === 'session_info' || tc.name === 'sftp_list'
    if (!known) {
      this.emitTool(sid, round, 'read_only', tc.name, AuditWriter.digest(tc.arguments), '未知工具: ' + tc.name, true)
      return '未知工具: ' + tc.name
    }
    // policy 判定（五档 + 注入拦截）
    const ctx = new ToolCallContext()
    ctx.toolName = tc.name
    ctx.argsJson = tc.arguments
    ctx.target = tc.name === 'term_write' ? this.sessionTarget() : 'local'
    const decision = PolicyEngine.evaluate(ctx)
    const argsDigest = AuditWriter.digest(tc.arguments)
    if (decision.kind === 'deny') {
      this.emitTool(sid, round, decision.level, tc.name, argsDigest, '已拦截: ' + decision.reason, true)
      this.auditTool(st, round, tc.name, decision.level, tc.arguments, '已拦截: ' + decision.reason, '', false)
      return '已拦截(' + decision.reason + ')。'
    }
    // approval 环节
    if (decision.kind === 'require_approval') {
      const view = new ApprovalView()
      view.requestId = 'a' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
      view.sessionId = sid
      view.toolName = tc.name
      view.argsDigest = argsDigest
      view.level = decision.level
      const d: ApprovalDecision = await this.approval(st).request(view, policy)
      if (d !== 'approved') {
        const out = d === 'timeout_denied' ? '审批超时,已拒绝执行。' : '用户拒绝执行该命令。'
        this.emitTool(sid, round, decision.level, tc.name, argsDigest, out, true)
        this.auditTool(st, round, tc.name, decision.level, tc.arguments, out, d, false)
        return out
      }
    }
    // execute 环节
    let out = ''
    let ok = true
    try {
      out = await this.execTool(st, tc)
    } catch (e) {
      ok = false
      out = '工具执行异常: ' + (e instanceof Error ? e.message : String(e))
    }
    const approvalRec: ApprovalDecision | '' = decision.kind === 'allow' ? '' : 'approved'
    this.emitTool(sid, round, decision.level, tc.name, argsDigest, out, !ok)
    this.auditTool(st, round, tc.name, decision.level, tc.arguments, out, approvalRec, ok)
    return out
  }

  // ===== 工具执行（继续走 SessionService，底座行为不变） =====
  private sessionTarget(): 'local' | 'remote' {
    return SessionService.sshHandle() !== null ? 'remote' : 'local'
  }

  /** term_write: 写入命令 → 屏幕指纹轮询等输出稳定 → 返回增量输出（等价迁移）。 */
  private async termWrite(cmd: string): Promise<string> {
    if (!SessionService.hasSession()) {
      return '无活动终端会话'
    }
    const before = SessionService.screenText(SCREEN_READ_LENGTH)
    const n = SessionService.write(cmd + '\n')
    if (n < 0) {
      return '命令写入失败'
    }
    return await this.waitScreen(before, SCREEN_WAIT_MS)
  }

  /** 轮询屏幕文本直到稳定（等价迁移）。 */
  private async waitScreen(before: string, maxMs: number): Promise<string> {
    const t0 = Date.now()
    let last = ''
    let stable = 0
    while (Date.now() - t0 < maxMs) {
      await this.sleep(400)
      const cur = SessionService.screenText(SCREEN_READ_LENGTH)
      if (cur !== before && cur === last) {
        stable++
        if (stable >= 2) {
          return cur
        }
      } else {
        stable = 0
      }
      last = cur
      const lines = cur.split('\n')
      const lastLine = lines.length > 0 ? lines[lines.length - 2] : ''
      if (cur !== before && lastLine !== '' && /[$#❯]\s*$/.test(lastLine)) {
        return cur
      }
    }
    return last
  }

  /** term_read: 屏幕末 lastN 行（≤40，等价迁移）。 */
  private termRead(argsJson: string): string {
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
    return SessionService.screenText(SCREEN_READ_LENGTH).split('\n').slice(-n).join('\n')
  }

  /** session_info: 会话状态快照（等价迁移）。 */
  private sessionInfo(): string {
    const status = AppStorage.get<string>('ut.term.status') ?? 'unknown'
    const title = AppStorage.get<string>('ut.term.title') ?? ''
    return JSON.stringify({ status: status, title: title, hasSession: SessionService.hasSession(), sessionId: SessionService.getSessionId() })
  }

  /** sftp_list: 列远端目录（复用活动 SSH 会话，等价迁移）。 */
  private async sftpList(path: string): Promise<string> {
    const ssh = SessionService.sshHandle()
    const sid = SessionService.getSessionId()
    if (ssh === null || sid < 0) {
      return '无活动 SSH 会话'
    }
    const json = await ssh.sftpList(sid, path === '' ? '.' : path)
    return json.substring(0, SFTP_RESULT_MAX_LENGTH)
  }

  private async execTool(st: LocalSessionState, tc: OaiToolCall): Promise<string> {
    if (tc.name === 'term_write') {
      return await this.termWrite(PolicyEngine.argString(tc.arguments, 'cmd'))
    }
    if (tc.name === 'term_read') {
      return this.termRead(tc.arguments)
    }
    if (tc.name === 'session_info') {
      return this.sessionInfo()
    }
    if (tc.name === 'sftp_list') {
      return await this.sftpList(PolicyEngine.argString(tc.arguments, 'path'))
    }
    return '未知工具: ' + tc.name
  }

  // ===== 辅助 =====
  /** 历史预算: >MAX_HISTORY 条消息截断中间（保头尾，等价迁移）。 */
  private trimHistory(hist: LlmMsg[]): LlmMsg[] {
    if (hist.length <= MAX_HISTORY) {
      return hist
    }
    const head = hist.slice(0, 2)
    const tail = hist.slice(hist.length - (MAX_HISTORY - 2))
    return head.concat(tail)
  }

  private approval(st: LocalSessionState): ApprovalManager {
    if (st.approval === null) {
      st.approval = new ApprovalManager(st.sessionId, this.filesDir, (e: AgentEvent): void => {
        this.emit(st.sessionId, e)
      })
    }
    return st.approval
  }

  private auditTool(st: LocalSessionState, round: number, tool: string, level: CapabilityLevel | '',
    args: string, result: string, approvalRec: ApprovalDecision | '', ok: boolean): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = st.sessionId
    rec.turn = round
    rec.tool = tool
    rec.level = level
    rec.argsDigest = args
    rec.resultDigest = result
    rec.approval = approvalRec
    const wOk = AuditWriter.append(this.filesDir, rec)
    if (!wOk) {
      this.emit(st.sessionId, this.auditFailEvent(st.sessionId, round))
    }
  }

  private auditRun(st: LocalSessionState, userText: string, final: string): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = st.sessionId
    rec.turn = 0
    rec.tool = 'run'
    rec.level = ''
    rec.argsDigest = userText
    rec.resultDigest = final
    rec.approval = ''
    const wOk = AuditWriter.append(this.filesDir, rec)
    if (!wOk) {
      this.emit(st.sessionId, this.auditFailEvent(st.sessionId, 0))
    }
  }

  private auditFailEvent(sessionId: string, turn: number): AgentEvent {
    const e = new AgentEvent()
    e.kind = 'audit_write_failed'
    e.sessionId = sessionId
    e.turn = turn
    e.text = '审计写入失败'
    return e
  }

  private finishSession(st: LocalSessionState, state: 'active' | 'cancelled' | 'finished' | 'aborted'): void {
    const meta = AgentSessionStore.read(this.filesDir, st.sessionId)
    if (meta !== null) {
      meta.state = state
      meta.historyDigest = JSON.stringify(st.hist)
      AgentSessionStore.update(this.filesDir, meta)
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void) => setTimeout(resolve, ms))
  }
}