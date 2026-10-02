/**
 * HmhAdapter HMH 引擎适配器（升级 Phase 2 / 任务 3.1~3.6，design 2.2.2.7）。
 *
 * implements AgentProvider；将 hmharness HTTP/SSE 协议映射到统一 AgentEvent：
 *   - createSession：创建会话元数据（不立即连接 SSE）；
 *   - subscribe：注册监听器 + 建立 SSE 长连接（GET /api/events）；
 *   - prompt：POST /api/task {text, mode, fresh, sessionId}；
 *   - cancel：POST /api/interrupt + 关闭 SSE 流 + 会话转 cancelled；
 *   - approve：POST /api/approve {granted: boolean}（approvalReq→need_approval→approve→approvalDone）；
 *   - resumeSession：以 Last-Event-ID 重建 SSE 订阅。
 *
 * HMH 12 种 SSE 事件映射（spec 5.2.1.3）：
 *   hello/busy/state → state_changed；line/delta → message；
 *   tool/toolResult → tool_call；approvalReq → need_approval；
 *   approvalDone → approval_result；final → done；error → error；
 *   injected/queue → state_changed。
 *
 * 审批桥接：HMH approvalReq → 本地 need_approval 事件 → UI 审批卡 →
 *   approve() POST /api/approve {granted} → HMH approvalDone 对账。
 *
 * 服务不可达：连接失败/中断 → 会话标 aborted + engine_state_changed 事件
 *   + AGENT_ENGINE_UNAVAILABLE（AgentAdapter 感知后回落 LocalAssistant）。
 */
import http from '@ohos.net.http';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AgentEvent, AgentEventListener, AgentProvider, AgentSessionConfig,
  AgentSessionHandle, AGENT_ENGINE_UNAVAILABLE, ApprovalDecision,
  ApprovalPolicyKind, ApprovalView, CapabilityLevel, PromptAck, PromptInput,
  ToolCallView, Unsubscribe
} from '../AgentProvider';
import { AgentSessionMeta, AgentSessionStore } from '../AgentSessionStore';
import { HarnessStream, HarnessEventCbs } from '../../service/HarnessClient';
import { AgentSettings, AgentSettingsStore } from '../../service/AgentSettingsStore';
import { PolicyEngine, ToolCallContext } from '../security/PolicyEngine';
import { ApprovalManager } from '../security/ApprovalManager';
import { AuditWriter, AuditRecord } from '../security/AuditWriter';
import { ToolLevelUtils } from '../ToolLevelUtils';

const TAG: string = 'oat.hmh';
const DOMAIN: number = 0x0110;
const HTTP_CONNECT_TIMEOUT_MS: number = 10000;
const HTTP_READ_TIMEOUT_MS: number = 10000;

class HmhSessionState {
  sessionId: string = ''
  baseUrl: string = ''
  stream: HarnessStream | null = null
  lastEventId: number = -1
  turn: number = 0
  cancelled: boolean = false
  title: string = ''
  connected: boolean = false
  approval: ApprovalManager | null = null
  pendingApprovalRequestId: string = ''
}

export class HmhAdapter implements AgentProvider {
  private filesDir: string = ''
  private sessions: Map<string, HmhSessionState> = new Map()
  private listeners: Map<string, AgentEventListener[]> = new Map()

  constructor(filesDir: string) {
    this.filesDir = filesDir
  }

  // ===== 事件分发 =====
  private emit(sessionId: string, e: AgentEvent): void {
    const ls = this.listeners.get(sessionId)
    if (ls !== undefined) {
      for (const l of ls) {
        l(e)
      }
    }
  }

  private emitState(sessionId: string, text: string, turn: number): void {
    const e = new AgentEvent()
    e.kind = 'state_changed'
    e.sessionId = sessionId
    e.turn = turn
    e.text = text
    this.emit(sessionId, e)
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

  private emitEngineUnavailable(sessionId: string): void {
    const e = new AgentEvent()
    e.kind = 'engine_state_changed'
    e.sessionId = sessionId
    e.turn = 0
    e.text = 'HMH 服务不可达'
    e.errCode = AGENT_ENGINE_UNAVAILABLE
    this.emit(sessionId, e)
  }

  // ===== 六方法 =====
  async createSession(config: AgentSessionConfig): Promise<AgentSessionHandle> {
    const sid = AgentSessionStore.newId()
    const settings = AgentSettingsStore.read(this.filesDir)
    const baseUrl = settings.engines.hmh.baseUrl
    const st = new HmhSessionState()
    st.sessionId = sid
    st.baseUrl = baseUrl
    st.title = config.title
    this.sessions.set(sid, st)
    const meta = new AgentSessionMeta()
    meta.sessionId = sid
    meta.engine = 'hmh'
    meta.state = 'active'
    meta.createdAt = Date.now()
    meta.updatedAt = Date.now()
    meta.title = config.title
    AgentSessionStore.create(this.filesDir, meta)
    const h = new AgentSessionHandle()
    h.sessionId = sid
    h.engine = 'hmh'
    h.resumed = false
    const e = new AgentEvent()
    e.kind = 'session_started'
    e.sessionId = sid
    this.emit(sid, e)
    hilog.info(DOMAIN, TAG, 'createSession %{public}s base=%{public}s', sid, baseUrl)
    return h
  }

  async resumeSession(sessionId: string): Promise<AgentSessionHandle> {
    const meta = AgentSessionStore.read(this.filesDir, sessionId)
    const h = new AgentSessionHandle()
    h.sessionId = sessionId
    if (meta === null) {
      h.engine = 'hmh'
      h.resumed = false
      return h
    }
    if (meta.engine !== 'hmh') {
      h.engine = meta.engine
      h.resumed = false
      return h
    }
    const settings = AgentSettingsStore.read(this.filesDir)
    const st = new HmhSessionState()
    st.sessionId = sessionId
    st.baseUrl = settings.engines.hmh.baseUrl
    st.title = meta.title
    st.lastEventId = meta.engineRef !== '' ? Number(meta.engineRef) : -1
    if (isNaN(st.lastEventId)) {
      st.lastEventId = -1
    }
    this.sessions.set(sessionId, st)
    st.cancelled = false
    AgentSessionStore.update(this.filesDir, meta)
    h.engine = 'hmh'
    h.resumed = true
    const e = new AgentEvent()
    e.kind = 'session_resumed'
    e.sessionId = sessionId
    this.emit(sessionId, e)
    hilog.info(DOMAIN, TAG, 'resumeSession %{public}s lastId=%{public}d', sessionId, st.lastEventId)
    return h
  }

  async prompt(sessionId: string, input: PromptInput): Promise<PromptAck> {
    const ack = new PromptAck()
    ack.sessionId = sessionId
    const st = this.sessions.get(sessionId)
    if (st === undefined) {
      ack.accepted = false
      ack.errCode = 'AGENT_SESSION_NOT_FOUND'
      return ack
    }
    if (st.cancelled) {
      ack.accepted = false
      return ack
    }
    if (st.baseUrl === '') {
      this.emitEngineUnavailable(sessionId)
      this.abortSession(st)
      ack.accepted = false
      ack.errCode = AGENT_ENGINE_UNAVAILABLE
      return ack
    }
    if (st.title === '') {
      st.title = input.text.substring(0, 40)
      const meta = AgentSessionStore.read(this.filesDir, sessionId)
      if (meta !== null) {
        meta.title = st.title
        AgentSessionStore.update(this.filesDir, meta)
      }
    }
    st.turn++
    ack.accepted = true
    ack.turn = st.turn
    if (st.stream === null || !st.connected) {
      this.connectStream(st)
    }
    if (st.stream !== null) {
      st.stream.send(input.text, 'ask', sessionId, st.turn === 1)
    }
    this.auditPrompt(st, input.text)
    hilog.info(DOMAIN, TAG, 'prompt %{public}s turn=%{public}d', sessionId, st.turn)
    return ack
  }

  async cancel(sessionId: string, reason: string): Promise<void> {
    const st = this.sessions.get(sessionId)
    if (st === undefined) {
      return
    }
    st.cancelled = true
    st.approval?.dispose()
    this.postInterrupt(st)
    this.closeStream(st)
    const meta = AgentSessionStore.read(this.filesDir, sessionId)
    if (meta !== null) {
      meta.state = 'cancelled'
      AgentSessionStore.update(this.filesDir, meta)
    }
    this.emitState(sessionId, '已取消: ' + reason, st.turn)
    hilog.info(DOMAIN, TAG, 'cancel %{public}s reason=%{public}s', sessionId, reason)
  }

  async approve(sessionId: string, requestId: string, decision: ApprovalDecision): Promise<void> {
    const st = this.sessions.get(sessionId)
    if (st === undefined) {
      return
    }
    this.approval(st).resolve(requestId, decision)
    hilog.info(DOMAIN, TAG, 'approve %{public}s granted=%{public}s', sessionId, decision === 'approved' ? 'true' : 'false')
  }

  subscribe(sessionId: string, listener: AgentEventListener): Unsubscribe {
    let ls = this.listeners.get(sessionId)
    if (ls === undefined) {
      ls = []
      this.listeners.set(sessionId, ls)
    }
    ls.push(listener)
    const st = this.sessions.get(sessionId)
    if (st !== undefined && !st.connected) {
      this.connectStream(st)
    }
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

  // ===== SSE 连接与事件映射 =====
  private connectStream(st: HmhSessionState): void {
    if (st.connected || st.stream !== null) {
      return
    }
    const sid = st.sessionId
    const cbs: HarnessEventCbs = {
      onEvent: (name: string, data: string): void => {
        this.onSseEvent(st, name, data)
      },
      onError: (msg: string): void => {
        hilog.error(DOMAIN, TAG, 'SSE error %{public}s: %{public}s', sid, msg)
        st.connected = false
        this.emitEngineUnavailable(sid)
        this.abortSession(st)
      },
      onEnd: (): void => {
        hilog.info(DOMAIN, TAG, 'SSE end %{public}s', sid)
        st.connected = false
      }
    }
    st.stream = new HarnessStream(st.baseUrl)
    st.stream.connect(cbs)
    st.connected = true
    hilog.info(DOMAIN, TAG, 'connectStream %{public}s base=%{public}s', sid, st.baseUrl)
  }

  private closeStream(st: HmhSessionState): void {
    st.connected = false
    if (st.stream !== null) {
      st.stream.close()
      st.stream = null
    }
  }

  private onSseEvent(st: HmhSessionState, name: string, data: string): void {
    const sid = st.sessionId
    let obj: Record<string, Object> = {}
    if (data !== '') {
      try {
        obj = JSON.parse(data) as Record<string, Object>
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'parse SSE data fail name=%{public}s', name)
      }
    }
    const eventSid = typeof obj['sessionId'] === 'string' ? obj['sessionId'] as string : ''
    if (eventSid !== '' && eventSid !== sid) {
      return
    }
    switch (name) {
      case 'hello':
        this.emitState(sid, '已连接', 0)
        break
      case 'busy':
        this.emitState(sid, '处理中', st.turn)
        break
      case 'line':
        this.emitMsg(sid, 'message', typeof obj['text'] === 'string' ? obj['text'] as string : '', st.turn, '')
        break
      case 'delta':
        this.emitMsg(sid, 'message', typeof obj['chunk'] === 'string' ? obj['chunk'] as string : '', st.turn, '')
        break
      case 'tool':
        this.onToolEvent(st, obj)
        break
      case 'toolResult':
        this.onToolResultEvent(st, obj)
        break
      case 'approvalReq':
        this.onApprovalReq(st, obj)
        break
      case 'approvalDone':
        this.onApprovalDone(st, obj)
        break
      case 'final':
        this.onFinalEvent(st, obj)
        break
      case 'error':
        this.emitMsg(sid, 'error', typeof obj['message'] === 'string' ? obj['message'] as string : '未知错误', st.turn, '')
        break
      case 'injected':
        this.emitState(sid, '已注入用户输入', st.turn)
        break
      case 'queue':
      case 'queued':
        this.emitState(sid, '排队中', st.turn)
        break
      case 'state':
        this.emitState(sid, '状态更新', st.turn)
        break
      default:
        hilog.warn(DOMAIN, TAG, 'unknown SSE event %{public}s', name)
        break
    }
  }

  private onToolEvent(st: HmhSessionState, obj: Record<string, Object>): void {
    const name = typeof obj['name'] === 'string' ? obj['name'] as string : ''
    const args = typeof obj['args'] === 'string' ? obj['args'] as string : JSON.stringify(obj['args'] ?? '')
    const argsDigest = AuditWriter.digest(args)
    const level = ToolLevelUtils.level(name)
    this.emitTool(st.sessionId, st.turn, level, name, argsDigest, '', false)
  }

  private onToolResultEvent(st: HmhSessionState, obj: Record<string, Object>): void {
    const name = typeof obj['name'] === 'string' ? obj['name'] as string : ''
    const isError = obj['isError'] === true
    const preview = typeof obj['preview'] === 'string' ? obj['preview'] as string : ''
    const full = typeof obj['full'] === 'string' ? obj['full'] as string : preview
    const level = ToolLevelUtils.level(name)
    this.emitTool(st.sessionId, st.turn, level, name, '', full, isError)
  }

  private onApprovalReq(st: HmhSessionState, obj: Record<string, Object>): void {
    const name = typeof obj['name'] === 'string' ? obj['name'] as string : ''
    const args = typeof obj['args'] === 'string' ? obj['args'] as string : JSON.stringify(obj['args'] ?? '')
    const ctx = new ToolCallContext()
    ctx.toolName = name
    ctx.argsJson = args
    ctx.target = 'remote'
    const policyDecision = PolicyEngine.evaluate(ctx)
    const argsDigest = AuditWriter.digest(args)
    if (policyDecision.kind === 'deny') {
      this.emitTool(st.sessionId, st.turn, policyDecision.level, name, argsDigest, '已拦截: ' + policyDecision.reason, true)
      this.postApprove(st, false)
      return
    }
    const level = ToolLevelUtils.level(name)
    const view = new ApprovalView()
    view.requestId = 'h' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
    view.sessionId = st.sessionId
    view.toolName = name
    view.argsDigest = argsDigest
    view.level = level
    st.pendingApprovalRequestId = view.requestId
    const settings: AgentSettings = AgentSettingsStore.read(this.filesDir)
    const policy: ApprovalPolicyKind = settings.security.approvalPolicy
    this.approval(st).setTurn(st.turn)
    this.approval(st).request(view, policy).then((decision: ApprovalDecision): void => {
      st.pendingApprovalRequestId = ''
      this.postApprove(st, decision === 'approved')
    })
  }

  private onApprovalDone(st: HmhSessionState, obj: Record<string, Object>): void {
    const granted = obj['granted'] === true
    const timeout = obj['timeout'] === true
    const decision: ApprovalDecision = timeout ? 'timeout_denied' : (granted ? 'approved' : 'denied')
    if (st.approval !== null && st.pendingApprovalRequestId !== '') {
      st.approval.resolve(st.pendingApprovalRequestId, decision)
      st.pendingApprovalRequestId = ''
    }
  }

  private onFinalEvent(st: HmhSessionState, obj: Record<string, Object>): void {
    const content = typeof obj['content'] === 'string' ? obj['content'] as string :
      (typeof obj['text'] === 'string' ? obj['text'] as string : '')
    this.emitMsg(st.sessionId, 'done', content, st.turn, '')
    const meta = AgentSessionStore.read(this.filesDir, st.sessionId)
    if (meta !== null) {
      meta.state = 'finished'
      meta.engineRef = st.lastEventId.toString()
      AgentSessionStore.update(this.filesDir, meta)
    }
    this.auditFinal(st, content)
  }

  // ===== HTTP 辅助 =====
  private postApprove(st: HmhSessionState, granted: boolean): void {
    if (st.baseUrl === '') {
      return
    }
    const r = http.createHttp()
    const bodyObj: Record<string, boolean> = {}
    bodyObj['granted'] = granted
    r.request(st.baseUrl.replace(/\/+$/, '') + '/api/approve', {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: JSON.stringify(bodyObj),
      connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
      readTimeout: HTTP_READ_TIMEOUT_MS
    }, (err: Error, resp: http.HttpResponse) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(DOMAIN, TAG, 'approve POST fail %{public}s', JSON.stringify(err).substring(0, 120))
        return
      }
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'approve POST code=%{public}d', resp.responseCode)
        return
      }
      hilog.info(DOMAIN, TAG, 'approve POST ok granted=%{public}s', granted ? 'true' : 'false')
    })
  }

  private postInterrupt(st: HmhSessionState): void {
    if (st.baseUrl === '') {
      return
    }
    const r = http.createHttp()
    r.request(st.baseUrl.replace(/\/+$/, '') + '/api/interrupt', {
      method: http.RequestMethod.POST,
      connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
      readTimeout: HTTP_READ_TIMEOUT_MS
    }, (err: Error, resp: http.HttpResponse) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(DOMAIN, TAG, 'interrupt POST fail %{public}s', JSON.stringify(err).substring(0, 120))
        return
      }
      hilog.info(DOMAIN, TAG, 'interrupt POST code=%{public}d', resp.responseCode)
    })
  }

  // ===== 会话状态管理 =====
  private abortSession(st: HmhSessionState): void {
    this.closeStream(st)
    const meta = AgentSessionStore.read(this.filesDir, st.sessionId)
    if (meta !== null) {
      meta.state = 'aborted'
      AgentSessionStore.update(this.filesDir, meta)
    }
  }

  private approval(st: HmhSessionState): ApprovalManager {
    if (st.approval === null) {
      st.approval = new ApprovalManager(st.sessionId, this.filesDir, (e: AgentEvent): void => {
        this.emit(st.sessionId, e)
      })
    }
    return st.approval
  }

  // ===== 审计 =====
  private auditPrompt(st: HmhSessionState, text: string): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = st.sessionId
    rec.turn = st.turn
    rec.tool = 'prompt'
    rec.level = ''
    rec.argsDigest = AuditWriter.digest(text)
    rec.resultDigest = ''
    rec.approval = ''
    const ok = AuditWriter.append(this.filesDir, rec)
    if (!ok) {
      const e = new AgentEvent()
      e.kind = 'audit_write_failed'
      e.sessionId = st.sessionId
      e.turn = st.turn
      e.text = '审计写入失败'
      this.emit(st.sessionId, e)
    }
  }

  private auditFinal(st: HmhSessionState, content: string): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = st.sessionId
    rec.turn = st.turn
    rec.tool = 'final'
    rec.level = ''
    rec.argsDigest = ''
    rec.resultDigest = AuditWriter.digest(content)
    rec.approval = ''
    const ok = AuditWriter.append(this.filesDir, rec)
    if (!ok) {
      const e = new AgentEvent()
      e.kind = 'audit_write_failed'
      e.sessionId = st.sessionId
      e.turn = st.turn
      e.text = '审计写入失败'
      this.emit(st.sessionId, e)
    }
  }
}