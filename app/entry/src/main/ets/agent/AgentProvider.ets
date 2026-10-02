/**
 * AgentProvider 六方法统一接口 + AgentEvent 统一事件（升级 Phase 1 / 任务 2.3）。
 *
 * UI 唯一 AI 入口契约（design 2.2.2.1/2.2.2.2）：
 *   HmhAdapter / AcpClient / LocalAssistant 三个引擎均 implements AgentProvider；
 *   引擎间互不感知，回落编排由 AgentAdapter 负责。
 * 异常映射码：AGENT_SESSION_NOT_FOUND / AGENT_ENGINE_MISMATCH /
 *   AGENT_ENGINE_UNAVAILABLE / AGENT_MODEL_NOT_CONFIGURED。
 */

/** 安全分级五档（spec 4.3.1 read-only→workspace-write→terminal→remote→destructive）。 */
export type CapabilityLevel = 'read_only' | 'workspace_write' | 'terminal' | 'remote' | 'destructive'

/** 审批决策三出口（批准 / 拒绝 / 超时拒绝）。 */
export type ApprovalDecision = 'approved' | 'denied' | 'timeout_denied'

/** 审批策略三档（strict 每次审批 / standard 仅危险审批 / open 风险自担）。 */
export type ApprovalPolicyKind = 'strict' | 'standard' | 'open'

/** 引擎类型（会话恢复时不得错配，spec 6.1.2）。 */
export type AgentEngineType = 'hmh' | 'acp' | 'local'

/** AgentSession 四态（spec 6.1.3，每次流转持久化）。 */
export type AgentSessionState = 'active' | 'cancelled' | 'finished' | 'aborted'

/**
 * 统一事件类型。HMH SSE / ACP 通知 / 本地单轮结果统一映射至此；
 * UI 层不做任何引擎协议解析（spec 5.2.1.3）。
 * ui_action 为 A2UI 预留（仅 schema validation/policy，不渲染原生 UI，spec 5.5.1.6）。
 */
export type AgentEventKind =
  'session_started' | 'session_resumed' | 'message' | 'tool_call' | 'need_approval'
  | 'approval_result' | 'turn' | 'done' | 'error' | 'state_changed'
  | 'engine_state_changed' | 'ui_action' | 'audit_write_failed'

/** 异常映射码。 */
export const AGENT_SESSION_NOT_FOUND: string = 'AGENT_SESSION_NOT_FOUND'
export const AGENT_ENGINE_MISMATCH: string = 'AGENT_ENGINE_MISMATCH'
export const AGENT_ENGINE_UNAVAILABLE: string = 'AGENT_ENGINE_UNAVAILABLE'
export const AGENT_MODEL_NOT_CONFIGURED: string = 'AGENT_MODEL_NOT_CONFIGURED'

/** 审批超时时长：与 HMH 服务端 5 分钟超时对齐（spec 5.3.3.2 / 任务 3.3）。 */
export const APPROVAL_TIMEOUT_MS: number = 300000

/** 工具调用回显视图（tool_call 事件载荷）。 */
export class ToolCallView {
  name: string = ''
  /** 脱敏后的参数摘要（审批卡/回显共用，不出凭据）。 */
  argsDigest: string = ''
  result: string = ''
  isError: boolean = false
}

/** 审批请求视图（need_approval / approval_result 事件载荷）。 */
export class ApprovalView {
  requestId: string = ''
  sessionId: string = ''
  toolName: string = ''
  /** 脱敏后的参数摘要。 */
  argsDigest: string = ''
  /** 档位徽标数据源。 */
  level: CapabilityLevel = 'read_only'
  /** 超时时刻（epoch ms），倒计时用。 */
  timeoutAt: number = 0
}

/** 统一事件结构（显式字段类，禁字符串 Map 传结构化数据，design 2.2.1）。 */
export class AgentEvent {
  kind: AgentEventKind = 'message'
  sessionId: string = ''
  /** 轮次（1 起；会话级事件为 0）。 */
  turn: number = 0
  /** 工具/审批事件携带档位；其余为 ''。 */
  level: CapabilityLevel | '' = ''
  /** message/done: 模型文本（流式增量或全量）；error: 可读错误。 */
  text: string = ''
  tool: ToolCallView | null = null
  approval: ApprovalView | null = null
  /** error 时的异常映射码。 */
  errCode: string = ''
}

export type AgentEventListener = (e: AgentEvent) => void
export type Unsubscribe = () => void

/** createSession 入参。 */
export class AgentSessionConfig {
  engine: AgentEngineType = 'local'
  title: string = ''
}

/** createSession/resumeSession 出参（会话句柄）。 */
export class AgentSessionHandle {
  sessionId: string = ''
  engine: AgentEngineType = 'local'
  resumed: boolean = false
}

/** prompt 入参。 */
export class PromptInput {
  text: string = ''
}

/** prompt 受理确认（结果经 subscribe 事件流异步回报）。 */
export class PromptAck {
  sessionId: string = ''
  turn: number = 0
  accepted: boolean = true
  errCode: string = ''
}

/** 六方法统一接口（稳定契约）。 */
export interface AgentProvider {
  /** 创建会话：返回唯一会话句柄（元数据同步写入 AgentSessionStore）。 */
  createSession(config: AgentSessionConfig): Promise<AgentSessionHandle>
  /** 恢复会话：按 sessionId 恢复上下文（引擎类型必须匹配，不得错配）。 */
  resumeSession(sessionId: string): Promise<AgentSessionHandle>
  /** 提交一轮输入：返回受理确认，结果经 subscribe 事件流异步回报。 */
  prompt(sessionId: string, input: PromptInput): Promise<PromptAck>
  /** 取消会话：终止当前轮次与流式接收，会话转 cancelled。 */
  cancel(sessionId: string, reason: string): Promise<void>
  /** 审批决策：对挂起的审批请求回传批准/拒绝。 */
  approve(sessionId: string, requestId: string, decision: ApprovalDecision): Promise<void>
  /** 订阅会话事件流：返回取消订阅函数。须在 prompt 之前调用。 */
  subscribe(sessionId: string, listener: AgentEventListener): Unsubscribe
}