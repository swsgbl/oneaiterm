/**
 * ApprovalManager 审批状态机（升级 Phase 1 / 任务 2.8，design 2.1.3.1/2.2.2.4）。
 *
 * 固定流程 request → policy → approval → execute → audit（任何步骤不可跳过）：
 *   - request()：收 require_approval 决策后按 approvalPolicy 三档判定——
 *       open：直接批准（风险自担，不弹卡）；standard：仅 destructive/remote 档弹卡
 *       （terminal 档自动放行，等价存量 confirm_dangerous）；strict：全部弹卡。
 *   - 弹卡时即时发 need_approval 事件（审批卡呈现不延迟到执行之后）+ 启动超时计时；
 *   - resolve()：处理批准/拒绝；超时按 timeout_denied 处理并终止对应工具调用；
 *   - 三种出口均产生 ApprovalRecord 审计（含档位/决策/时间戳）；
 *   - 决策与实际执行结果严格一致（spec 6.2.2）。
 */
import {
  AgentEvent, ApprovalDecision, ApprovalPolicyKind, ApprovalView,
  APPROVAL_TIMEOUT_MS, CapabilityLevel
} from '../AgentProvider';
import { AuditWriter, AuditRecord } from './AuditWriter';

const TAG: string = 'oat.approval';
const DOMAIN: number = 0x0110;

export class ApprovalManager {
  private sessionId: string = ''
  private filesDir: string = ''
  private turn: number = 0
  private emit: (e: AgentEvent) => void = (e: AgentEvent) => {
  }
  /** 挂起审批：requestId → resolver。 */
  private resolvers: Map<string, (d: ApprovalDecision) => void> = new Map()
  /** 挂起审批：requestId → 超时 timer id。 */
  private timers: Map<string, number> = new Map()

  constructor(sessionId: string, filesDir: string, emit: (e: AgentEvent) => void) {
    this.sessionId = sessionId
    this.filesDir = filesDir
    this.emit = emit
  }

  /** 轮次同步（审计记录关联轮次）。 */
  setTurn(turn: number): void {
    this.turn = turn
  }

  /**
   * 审批请求入口（Promise 挂起，不落地不推进）。
   * view.argsDigest 必须已脱敏（调用方经 AuditWriter.digest）。
   */
  request(view: ApprovalView, policy: ApprovalPolicyKind): Promise<ApprovalDecision> {
    // open 档：风险自担，直接放行（禁止默认，需用户显式选择）
    if (policy === 'open') {
      this.audit(view, 'approved')
      return Promise.resolve('approved')
    }
    // standard 档：仅危险（destructive/remote）弹卡；terminal 自动放行（等价存量 confirm_dangerous）
    if (policy === 'standard' && view.level !== 'destructive' && view.level !== 'remote') {
      this.audit(view, 'approved')
      return Promise.resolve('approved')
    }
    // strict 档（或 standard 的危险档）：弹审批卡
    return new Promise<ApprovalDecision>((resolve) => {
      view.timeoutAt = Date.now() + APPROVAL_TIMEOUT_MS
      this.resolvers.set(view.requestId, resolve)
      const e = new AgentEvent()
      e.kind = 'need_approval'
      e.sessionId = this.sessionId
      e.turn = this.turn
      e.level = view.level
      e.approval = view
      this.emit(e)
      const t = setTimeout((): void => {
        this.onTimeout(view.requestId)
      }, APPROVAL_TIMEOUT_MS)
      this.timers.set(view.requestId, t)
    })
  }

  /** UI 决策回传：批准/拒绝（仅对挂起的 requestId 有效）。 */
  resolve(requestId: string, decision: ApprovalDecision): void {
    const r = this.resolvers.get(requestId)
    if (r === undefined) {
      return
    }
    this.resolvers.delete(requestId)
    const t = this.timers.get(requestId)
    if (t !== undefined) {
      clearTimeout(t)
      this.timers.delete(requestId)
    }
    // approval_result 事件（决策回显）
    const e = new AgentEvent()
    e.kind = 'approval_result'
    e.sessionId = this.sessionId
    e.turn = this.turn
    const v = new ApprovalView()
    v.requestId = requestId
    v.timeoutAt = 0
    e.approval = v
    e.text = decision
    this.emit(e)
    this.auditByRequest(requestId, decision)
    r(decision)
  }

  /** 超时出口：timeout_denied 并终止对应工具调用。 */
  private onTimeout(requestId: string): void {
    const r = this.resolvers.get(requestId)
    if (r === undefined) {
      return
    }
    this.resolvers.delete(requestId)
    this.timers.delete(requestId)
    const e = new AgentEvent()
    e.kind = 'approval_result'
    e.sessionId = this.sessionId
    e.turn = this.turn
    e.text = 'timeout_denied'
    const v = new ApprovalView()
    v.requestId = requestId
    v.timeoutAt = 0
    e.approval = v
    this.emit(e)
    this.auditByRequest(requestId, 'timeout_denied')
    r('timeout_denied')
  }

  /** 审计（决策出口：resolve/timeout）。 */
  private auditByRequest(requestId: string, decision: ApprovalDecision): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = this.sessionId
    rec.turn = this.turn
    rec.tool = 'approval'
    rec.level = ''
    rec.argsDigest = 'requestId=' + requestId
    rec.resultDigest = decision === 'timeout_denied' ? '超时拒绝' : decision
    rec.approval = decision
    this.write(rec)
  }

  /** 审计（自动放行出口：open/standard 非危险）。 */
  private audit(view: ApprovalView, decision: ApprovalDecision): void {
    const rec = new AuditRecord()
    rec.ts = Date.now()
    rec.sessionId = this.sessionId
    rec.turn = this.turn
    rec.tool = view.toolName
    rec.level = view.level as CapabilityLevel | ''
    rec.argsDigest = view.argsDigest
    rec.resultDigest = 'auto-approved(' + view.level + ')'
    rec.approval = decision
    this.write(rec)
  }

  /** 写审计；失败发 audit_write_failed 事件（不静默丢弃）。 */
  private write(rec: AuditRecord): void {
    const ok = AuditWriter.append(this.filesDir, rec)
    if (!ok) {
      const e = new AgentEvent()
      e.kind = 'audit_write_failed'
      e.sessionId = this.sessionId
      e.turn = this.turn
      e.text = '审计写入失败'
      this.emit(e)
    }
  }

  /** 会话销毁时清理挂起审批（未决策按 timeout_denied 结束）。 */
  dispose(): void {
    const ids = Array.from(this.resolvers.keys())
    for (const id of ids) {
      this.onTimeout(id)
    }
  }
}