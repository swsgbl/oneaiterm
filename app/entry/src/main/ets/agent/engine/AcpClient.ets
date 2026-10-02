/**
 * AcpClient ACP v1 引擎适配器（升级 Phase 3 / 任务 4.1~4.5，design 2.2.2.8）。
 *
 * implements AgentProvider；将 ACP v1 JSON-RPC 2.0 协议映射到统一 AgentEvent：
 *   - initialize → createSession 前置握手（版本/能力协商，失败则不建会话）；
 *   - session/new → createSession；
 *   - session/load → resumeSession；
 *   - prompt → prompt；
 *   - update → message/tool_call 事件（流式渐进回显）；
 *   - permission → need_approval 事件（经 ApprovalManager，遵守安全分级档位标注）；
 *   - cancel → cancel。
 *
 * transport：HTTP + SSE（JSON-RPC 2.0 over HTTP），接口化预留 stdio 扩展点。
 * feature flag：featureFlags.acp_v2 默认 false；开启后 v2 分支独立验证。
 *
 * 握手失败：initialize 失败/版本不兼容 → 明确提示不兼容原因、不建立会话、
 *   不影响其他引擎（spec 5.4.3.1）。
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
import { AgentSettings, AgentSettingsStore } from '../../service/AgentSettingsStore';
import { PolicyEngine, ToolCallContext } from '../security/PolicyEngine';
import { ApprovalManager } from '../security/ApprovalManager';
import { AuditWriter, AuditRecord } from '../security/AuditWriter';


const TAG: string = 'oat.acp';
const DOMAIN: number = 0x0110;
const RPC_VERSION: string = '2.0';
const ACP_VERSION_V1: string = '1.0';
const ACP_VERSION_V2: string = '2.0';
const REQUEST_TIMEOUT_MS: number = 30000;
const HTTP_CONNECT_TIMEOUT_MS: number = 15000;
const SSE_READ_TIMEOUT_MS: number = 600000;

/** JSON-RPC 2.0 请求结构。 */
class RpcRequest {
  jsonrpc: string = RPC_VERSION
  id: number = 0
  method: string = ''
  params: Record<string, Object> = {}
}

/** JSON-RPC 2.0 响应结构。 */
class RpcResponse {
  jsonrpc: string = RPC_VERSION
  id: number = 0
  result: Record<string, Object> | null = null
  error: RpcError | null = null
}

/** JSON-RPC 2.0 错误对象。 */
class RpcError {
  code: number = 0
  message: string = ''
  data: Record<string, Object> | null = null
}

/** ACP transport 接口（预留 stdio 扩展点，design 2.1.3.7）。 */
interface AcpTransport {
  send(request: RpcRequest): Promise<RpcResponse>
  subscribe(url: string, listener: (event: string, data: string) => void): void
  close(): void
}

/** HTTP + SSE transport 默认实现。 */
class HttpSseTransport implements AcpTransport {
  private baseUrl: string = ''
  private sseReq: http.HttpRequest | null = null
  private sseBuffer: string = ''
  private sseListener: ((event: string, data: string) => void) | null = null
  private closed: boolean = false

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/+$/, '')
  }

  async send(request: RpcRequest): Promise<RpcResponse> {
    return new Promise<RpcResponse>((resolve) => {
      const r = http.createHttp()
      const body = JSON.stringify(request)
      r.request(this.baseUrl, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS
      }, (err: Error, resp: http.HttpResponse) => {
        if (err !== undefined && err !== null && err.message !== '') {
          hilog.error(DOMAIN, TAG, 'rpc send fail %{public}s', err instanceof Error ? err.message : String(err))
          const er = new RpcResponse()
          er.error = new RpcError()
          er.error.code = -1
          er.error.message = '传输失败: ' + (err instanceof Error ? err.message : String(err)).substring(0, 80)
          resolve(er)
          return
        }
        if (resp.responseCode !== 200) {
          hilog.error(DOMAIN, TAG, 'rpc send code=%{public}d', resp.responseCode)
          const er = new RpcResponse()
          er.error = new RpcError()
          er.error.code = resp.responseCode
          er.error.message = 'HTTP ' + resp.responseCode
          resolve(er)
          return
        }
        try {
          const raw = resp.result as string
          const obj = JSON.parse(raw) as Record<string, Object>
          const rp = new RpcResponse()
          rp.jsonrpc = typeof obj['jsonrpc'] === 'string' ? obj['jsonrpc'] as string : RPC_VERSION
          rp.id = typeof obj['id'] === 'number' ? obj['id'] as number : 0
          if (obj['result'] !== undefined && obj['result'] !== null) {
            rp.result = obj['result'] as Record<string, Object>
          }
          if (obj['error'] !== undefined && obj['error'] !== null) {
            const eObj = obj['error'] as Record<string, Object>
            const e = new RpcError()
            e.code = typeof eObj['code'] === 'number' ? eObj['code'] as number : 0
            e.message = typeof eObj['message'] === 'string' ? eObj['message'] as string : ''
            rp.error = e
          }
          resolve(rp)
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'rpc parse fail %{public}s', (e instanceof Error ? e.message : String(e)).substring(0, 80))
          const er = new RpcResponse()
          er.error = new RpcError()
          er.error.code = -1
          er.error.message = '响应解析失败'
          resolve(er)
        }
      })
    })
  }

  subscribe(url: string, listener: (event: string, data: string) => void): void {
    this.sseListener = listener
    this.closed = false
    this.sseReq = http.createHttp()
    this.sseReq.on('dataReceive', (buf: ArrayBuffer) => {
      this.onSseBytes(buf)
    })
    this.sseReq.on('dataEnd', () => {
      this.flushSse()
    })
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'text/event-stream' },
      connectTimeout: HTTP_CONNECT_TIMEOUT_MS,
      readTimeout: SSE_READ_TIMEOUT_MS
    }
    this.sseReq.requestInStream(url, opts, (err: Error, code: number) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(DOMAIN, TAG, 'sse connect fail %{public}s', err instanceof Error ? err.message : String(err))
        return
      }
      if (code !== 200) {
        hilog.error(DOMAIN, TAG, 'sse connect code=%{public}d', code)
        return
      }
      hilog.info(DOMAIN, TAG, 'sse connected %{public}s', url)
    })
  }

  private onSseBytes(buf: ArrayBuffer): void {
    const u8 = new Uint8Array(buf)
    let decoded = ''
    let i = 0
    while (i < u8.length) {
      const b = u8[i]
      if (b < 0x80) {
        decoded += String.fromCharCode(b)
        i++
      } else if (b < 0xC0) {
        i++
      } else if (b < 0xE0) {
        if (i + 1 < u8.length) {
          decoded += String.fromCharCode(((b & 0x1F) << 6) | (u8[i + 1] & 0x3F))
          i += 2
        } else {
          i++
        }
      } else if (b < 0xF0) {
        if (i + 2 < u8.length) {
          decoded += String.fromCharCode(((b & 0x0F) << 12) | ((u8[i + 1] & 0x3F) << 6) | (u8[i + 2] & 0x3F))
          i += 3
        } else {
          i++
        }
      } else {
        if (i + 3 < u8.length) {
          const cp = ((b & 0x07) << 18) | ((u8[i + 1] & 0x3F) << 12) | ((u8[i + 2] & 0x3F) << 6) | (u8[i + 3] & 0x3F)
          const adj = cp - 0x10000
          decoded += String.fromCharCode(0xD800 + (adj >> 10))
          decoded += String.fromCharCode(0xDC00 + (adj & 0x3FF))
          i += 4
        } else {
          i++
        }
      }
    }
    this.sseBuffer += decoded
    let nl = this.sseBuffer.indexOf('\n')
    while (nl >= 0) {
      const line = this.sseBuffer.substring(0, nl).replace(/\r$/, '')
      this.sseBuffer = this.sseBuffer.substring(nl + 1)
      this.onSseLine(line)
      nl = this.sseBuffer.indexOf('\n')
    }
  }

  private curEvent: string = ''
  private curData: string = ''

  private onSseLine(line: string): void {
    if (line === '') {
      this.flushSse()
      return
    }
    if (line.startsWith('event:')) {
      this.curEvent = line.substring(6).trim()
    } else if (line.startsWith('data:')) {
      const d = line.substring(5)
      this.curData = this.curData === '' ? d : this.curData + '\n' + d
    }
  }

  private flushSse(): void {
    if (this.curEvent === '' && this.curData === '') {
      return
    }
    if (this.sseListener !== null) {
      this.sseListener(this.curEvent, this.curData)
    }
    this.curEvent = ''
    this.curData = ''
  }

  close(): void {
    this.closed = true
    this.sseListener = null
    if (this.sseReq !== null) {
      try {
        this.sseReq.destroy()
      } catch (e) {
      }
      this.sseReq = null
    }
  }
}

/** ACP 会话状态。 */
class AcpSessionState {
  sessionId: string = ''
  agentUrl: string = ''
  agentName: string = ''
  transport: HttpSseTransport | null = null
  acpSessionId: string = ''
  turn: number = 0
  cancelled: boolean = false
  initialized: boolean = false
  pendingPermissionId: string = ''
  rpcIdCounter: number = 0
  v2Enabled: boolean = false
  title: string = ''
  approval: ApprovalManager | null = null
}

export class AcpClient implements AgentProvider {
  private filesDir: string = ''
  private sessions: Map<string, AcpSessionState> = new Map()
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

  private emitMsg(sessionId: string, kind: 'message' | 'done' | 'error', text: string, turn: number, errCode: string): void {
    const e = new AgentEvent()
    e.kind = kind
    e.sessionId = sessionId
    e.turn = turn
    e.text = text
    e.errCode = errCode
    this.emit(sessionId, e)
  }

  private emitState(sessionId: string, text: string, turn: number): void {
    const e = new AgentEvent()
    e.kind = 'state_changed'
    e.sessionId = sessionId
    e.turn = turn
    e.text = text
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

  // ===== JSON-RPC 辅助 =====
  private nextRpcId(st: AcpSessionState): number {
    st.rpcIdCounter++
    return st.rpcIdCounter
  }

  private buildRequest(id: number, method: string, params: Record<string, Object>): RpcRequest {
    const req = new RpcRequest()
    req.jsonrpc = RPC_VERSION
    req.id = id
    req.method = method
    req.params = params
    return req
  }

  // ===== 六方法 =====
  async createSession(config: AgentSessionConfig): Promise<AgentSessionHandle> {
    const sid = AgentSessionStore.newId()
    const settings = AgentSettingsStore.read(this.filesDir)
    const acpAgents = settings.engines.acp
    if (acpAgents.length === 0) {
      const h = new AgentSessionHandle()
      h.sessionId = sid
      h.engine = 'acp'
      h.resumed = false
      this.emitMsg(sid, 'error', '未配置 ACP Agent（设置→AI→ACP Agents）', 0, AGENT_ENGINE_UNAVAILABLE)
      return h
    }
    const agent = acpAgents[0]
    const st = new AcpSessionState()
    st.sessionId = sid
    st.agentUrl = agent.url
    st.agentName = agent.name
    st.v2Enabled = settings.featureFlags.acp_v2
    this.sessions.set(sid, st)
    const meta = new AgentSessionMeta()
    meta.sessionId = sid
    meta.engine = 'acp'
    meta.state = 'active'
    meta.createdAt = Date.now()
    meta.updatedAt = Date.now()
    meta.title = config.title
    AgentSessionStore.create(this.filesDir, meta)
    st.transport = new HttpSseTransport(st.agentUrl)
    const initOk = await this.initialize(st)
    if (!initOk) {
      this.emitMsg(sid, 'error', 'ACP 握手失败：版本不兼容或服务不可达', 0, AGENT_ENGINE_UNAVAILABLE)
      const m = AgentSessionStore.read(this.filesDir, sid)
      if (m !== null) {
        m.state = 'aborted'
        AgentSessionStore.update(this.filesDir, m)
      }
      const h = new AgentSessionHandle()
      h.sessionId = sid
      h.engine = 'acp'
      h.resumed = false
      return h
    }
    const sessionOk = await this.sessionNew(st)
    if (!sessionOk) {
      this.emitMsg(sid, 'error', 'ACP session/new 失败', 0, AGENT_ENGINE_UNAVAILABLE)
      const m = AgentSessionStore.read(this.filesDir, sid)
      if (m !== null) {
        m.state = 'aborted'
        AgentSessionStore.update(this.filesDir, m)
      }
      const h = new AgentSessionHandle()
      h.sessionId = sid
      h.engine = 'acp'
      h.resumed = false
      return h
    }
    const e = new AgentEvent()
    e.kind = 'session_started'
    e.sessionId = sid
    this.emit(sid, e)
    const h = new AgentSessionHandle()
    h.sessionId = sid
    h.engine = 'acp'
    h.resumed = false
    hilog.info(DOMAIN, TAG, 'createSession %{public}s agent=%{public}s', sid, st.agentName)
    return h
  }

  async resumeSession(sessionId: string): Promise<AgentSessionHandle> {
    const meta = AgentSessionStore.read(this.filesDir, sessionId)
    const h = new AgentSessionHandle()
    h.sessionId = sessionId
    if (meta === null) {
      h.engine = 'acp'
      h.resumed = false
      return h
    }
    if (meta.engine !== 'acp') {
      h.engine = meta.engine
      h.resumed = false
      return h
    }
    const settings = AgentSettingsStore.read(this.filesDir)
    const acpAgents = settings.engines.acp
    if (acpAgents.length === 0) {
      h.engine = 'acp'
      h.resumed = false
      return h
    }
    const agent = acpAgents[0]
    const st = new AcpSessionState()
    st.sessionId = sessionId
    st.agentUrl = agent.url
    st.agentName = agent.name
    st.v2Enabled = settings.featureFlags.acp_v2
    st.acpSessionId = meta.engineRef
    st.transport = new HttpSseTransport(st.agentUrl)
    this.sessions.set(sessionId, st)
    st.cancelled = false
    const initOk = await this.initialize(st)
    if (!initOk) {
      this.emitMsg(sessionId, 'error', 'ACP 握手失败', 0, AGENT_ENGINE_UNAVAILABLE)
      return h
    }
    const loadOk = await this.sessionLoad(st)
    if (!loadOk) {
      this.emitMsg(sessionId, 'error', 'ACP session/load 失败', 0, AGENT_ENGINE_UNAVAILABLE)
      return h
    }
    AgentSessionStore.update(this.filesDir, meta)
    h.engine = 'acp'
    h.resumed = true
    const e = new AgentEvent()
    e.kind = 'session_resumed'
    e.sessionId = sessionId
    this.emit(sessionId, e)
    hilog.info(DOMAIN, TAG, 'resumeSession %{public}s acpSid=%{public}s', sessionId, st.acpSessionId)
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
    if (st.cancelled || !st.initialized) {
      ack.accepted = false
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
    const params: Record<string, Object> = {}
    params['sessionId'] = st.acpSessionId
    params['text'] = input.text
    const req = this.buildRequest(this.nextRpcId(st), 'prompt', params)
    if (st.transport !== null) {
      const resp = await st.transport.send(req)
      if (resp.error !== null) {
        this.emitMsg(sessionId, 'error', 'prompt 失败: ' + resp.error.message, st.turn, '')
        ack.accepted = false
        return ack
      }
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
    const params: Record<string, Object> = {}
    params['sessionId'] = st.acpSessionId
    params['reason'] = reason
    const req = this.buildRequest(this.nextRpcId(st), 'cancel', params)
    if (st.transport !== null) {
      await st.transport.send(req)
      st.transport.close()
    }
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
    if (st !== undefined && st.transport !== null) {
      const sseUrl = st.agentUrl.replace(/\/+$/, '') + '/events?sessionId=' + st.acpSessionId
      st.transport.subscribe(sseUrl, (event: string, data: string): void => {
        this.onSseEvent(st, event, data)
      })
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

  // ===== ACP v1 方法实现 =====
  private async initialize(st: AcpSessionState): Promise<boolean> {
    const params: Record<string, Object> = {}
    params['version'] = st.v2Enabled ? ACP_VERSION_V2 : ACP_VERSION_V1
    params['client'] = 'OneAITerm'
    const req = this.buildRequest(this.nextRpcId(st), 'initialize', params)
    if (st.transport === null) {
      return false
    }
    const resp = await st.transport.send(req)
    if (resp.error !== null) {
      hilog.error(DOMAIN, TAG, 'initialize fail %{public}s', resp.error.message)
      return false
    }
    if (resp.result !== null) {
      const serverVersion = typeof resp.result['version'] === 'string' ? resp.result['version'] as string : ''
      if (serverVersion !== ACP_VERSION_V1 && serverVersion !== ACP_VERSION_V2) {
        hilog.error(DOMAIN, TAG, 'version mismatch server=%{public}s', serverVersion)
        return false
      }
      if (serverVersion === ACP_VERSION_V2 && !st.v2Enabled) {
        hilog.warn(DOMAIN, TAG, 'server v2 but client v1 only')
        return false
      }
    }
    st.initialized = true
    hilog.info(DOMAIN, TAG, 'initialize ok v=%{public}s', st.v2Enabled ? ACP_VERSION_V2 : ACP_VERSION_V1)
    return true
  }

  private async sessionNew(st: AcpSessionState): Promise<boolean> {
    const params: Record<string, Object> = {}
    params['title'] = st.sessionId
    const req = this.buildRequest(this.nextRpcId(st), 'session/new', params)
    if (st.transport === null) {
      return false
    }
    const resp = await st.transport.send(req)
    if (resp.error !== null) {
      hilog.error(DOMAIN, TAG, 'session/new fail %{public}s', resp.error.message)
      return false
    }
    if (resp.result !== null) {
      const sid = typeof resp.result['sessionId'] === 'string' ? resp.result['sessionId'] as string : ''
      st.acpSessionId = sid
      const meta = AgentSessionStore.read(this.filesDir, st.sessionId)
      if (meta !== null) {
        meta.engineRef = sid
        AgentSessionStore.update(this.filesDir, meta)
      }
    }
    hilog.info(DOMAIN, TAG, 'session/new ok acpSid=%{public}s', st.acpSessionId)
    return true
  }

  private async sessionLoad(st: AcpSessionState): Promise<boolean> {
    const params: Record<string, Object> = {}
    params['sessionId'] = st.acpSessionId
    const req = this.buildRequest(this.nextRpcId(st), 'session/load', params)
    if (st.transport === null) {
      return false
    }
    const resp = await st.transport.send(req)
    if (resp.error !== null) {
      hilog.error(DOMAIN, TAG, 'session/load fail %{public}s', resp.error.message)
      return false
    }
    st.initialized = true
    hilog.info(DOMAIN, TAG, 'session/load ok acpSid=%{public}s', st.acpSessionId)
    return true
  }

  // ===== SSE 事件处理 =====
  private onSseEvent(st: AcpSessionState, event: string, data: string): void {
    const sid = st.sessionId
    let obj: Record<string, Object> = {}
    if (data !== '') {
      try {
        obj = JSON.parse(data) as Record<string, Object>
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'parse SSE data fail event=%{public}s', event)
      }
    }
    switch (event) {
      case 'update':
        this.onUpdateEvent(st, obj)
        break
      case 'permission':
        this.onPermissionEvent(st, obj)
        break
      case 'error':
        this.emitMsg(sid, 'error', typeof obj['message'] === 'string' ? obj['message'] as string : 'ACP 错误', st.turn, '')
        break
      case 'done':
        this.onDoneEvent(st, obj)
        break
      case 'state':
        this.emitState(sid, '状态更新', st.turn)
        break
      default:
        hilog.warn(DOMAIN, TAG, 'unknown ACP event %{public}s', event)
        break
    }
  }

  private onUpdateEvent(st: AcpSessionState, obj: Record<string, Object>): void {
    const kind = typeof obj['kind'] === 'string' ? obj['kind'] as string : ''
    if (kind === 'message' || kind === 'delta') {
      const text = typeof obj['text'] === 'string' ? obj['text'] as string :
        (typeof obj['content'] === 'string' ? obj['content'] as string : '')
      this.emitMsg(st.sessionId, 'message', text, st.turn, '')
    } else if (kind === 'tool_call' || kind === 'tool') {
      const name = typeof obj['name'] === 'string' ? obj['name'] as string : ''
      const args = typeof obj['args'] === 'string' ? obj['args'] as string : JSON.stringify(obj['args'] ?? '')
      const ctx = new ToolCallContext()
      ctx.toolName = name
      ctx.argsJson = args
      ctx.target = 'remote'
      const policyDecision = PolicyEngine.evaluate(ctx)
      const argsDigest = AuditWriter.digest(args)
      if (policyDecision.kind === 'deny') {
        this.emitTool(st.sessionId, st.turn, policyDecision.level, name, argsDigest, '安全拦截: ' + policyDecision.reason, true)
      } else {
        this.emitTool(st.sessionId, st.turn, policyDecision.level, name, argsDigest, '', false)
      }
    } else if (kind === 'tool_result' || kind === 'toolResult') {
      const name = typeof obj['name'] === 'string' ? obj['name'] as string : ''
      const isError = obj['isError'] === true
      const result = typeof obj['result'] === 'string' ? obj['result'] as string :
        (typeof obj['output'] === 'string' ? obj['output'] as string : '')
      const ctx = new ToolCallContext()
      ctx.toolName = name
      ctx.argsJson = ''
      ctx.target = 'remote'
      const policyDecision = PolicyEngine.evaluate(ctx)
      this.emitTool(st.sessionId, st.turn, policyDecision.level, name, '', result, isError)
    } else {
      const text = typeof obj['text'] === 'string' ? obj['text'] as string : ''
      if (text !== '') {
        this.emitMsg(st.sessionId, 'message', text, st.turn, '')
      }
    }
  }

  private onPermissionEvent(st: AcpSessionState, obj: Record<string, Object>): void {
    const requestId = typeof obj['requestId'] === 'string' ? obj['requestId'] as string :
      'p' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
    const toolName = typeof obj['tool'] === 'string' ? obj['tool'] as string :
      (typeof obj['name'] === 'string' ? obj['name'] as string : '')
    const args = typeof obj['args'] === 'string' ? obj['args'] as string : JSON.stringify(obj['args'] ?? '')
    const ctx = new ToolCallContext()
    ctx.toolName = toolName
    ctx.argsJson = args
    ctx.target = 'remote'
    const policyDecision = PolicyEngine.evaluate(ctx)
    const argsDigest = AuditWriter.digest(args)
    if (policyDecision.kind === 'deny') {
      this.emitTool(st.sessionId, st.turn, policyDecision.level, toolName, argsDigest, '已拦截: ' + policyDecision.reason, true)
      this.sendPermission(st, requestId, false)
      return
    }
    st.pendingPermissionId = requestId
    const view = new ApprovalView()
    view.requestId = requestId
    view.sessionId = st.sessionId
    view.toolName = toolName
    view.argsDigest = argsDigest
    view.level = policyDecision.level
    const settings: AgentSettings = AgentSettingsStore.read(this.filesDir)
    const policy: ApprovalPolicyKind = settings.security.approvalPolicy
    this.approval(st).setTurn(st.turn)
    this.approval(st).request(view, policy).then((decision: ApprovalDecision): void => {
      st.pendingPermissionId = ''
      this.sendPermission(st, requestId, decision === 'approved')
    })
  }

  private async sendPermission(st: AcpSessionState, requestId: string, granted: boolean): Promise<void> {
    const params: Record<string, Object> = {}
    params['sessionId'] = st.acpSessionId
    params['requestId'] = requestId
    params['granted'] = granted
    const req = this.buildRequest(this.nextRpcId(st), 'permission', params)
    if (st.transport !== null) {
      await st.transport.send(req)
    }
  }

  private onDoneEvent(st: AcpSessionState, obj: Record<string, Object>): void {
    const content = typeof obj['content'] === 'string' ? obj['content'] as string :
      (typeof obj['text'] === 'string' ? obj['text'] as string : '')
    this.emitMsg(st.sessionId, 'done', content, st.turn, '')
    const meta = AgentSessionStore.read(this.filesDir, st.sessionId)
    if (meta !== null) {
      meta.state = 'finished'
      AgentSessionStore.update(this.filesDir, meta)
    }
    this.auditFinal(st, content)
  }

  private approval(st: AcpSessionState): ApprovalManager {
    if (st.approval === null) {
      st.approval = new ApprovalManager(st.sessionId, this.filesDir, (e: AgentEvent): void => {
        this.emit(st.sessionId, e)
      })
    }
    return st.approval
  }

  // ===== 审计 =====
  private auditPrompt(st: AcpSessionState, text: string): void {
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

  private auditFinal(st: AcpSessionState, content: string): void {
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