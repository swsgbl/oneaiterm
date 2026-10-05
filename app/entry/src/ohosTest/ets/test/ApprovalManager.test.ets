/**
 * ApprovalManager 审批状态机单元测试（M5，ArkTS/hypium）。
 *
 * 纯函数复制 replicates ApprovalManager 中审批判定与超时出口逻辑（dependency-free）。
 * 覆盖：
 *   1. request open 档：直接 approved（不弹卡）
 *   2. request standard 档：非危险自动 approved、危险弹卡
 *   3. request strict 档：全部弹卡
 *   4. resolve：批准/拒绝回传
 *   5. onTimeout：超时出口 timeout_denied
 *   6. dispose：批量超时清理
 *   7. resolve 重复/无效 requestId：幂等忽略
 */
import { describe, it, expect } from '@ohos/hypium';

type ApprovalPolicyKind = 'strict' | 'standard' | 'open'
type ApprovalDecision = 'approved' | 'denied' | 'timeout_denied'
type CapabilityLevel = 'read_only' | 'workspace_write' | 'terminal' | 'remote' | 'destructive'

const APPROVAL_TIMEOUT_MS: number = 300000

class TApprovalView {
  requestId: string = ''
  toolName: string = ''
  argsDigest: string = ''
  level: CapabilityLevel = 'read_only'
  timeoutAt: number = 0
}

class TApprovalState {
  resolvers: Map<string, ApprovalDecision> = new Map()
  timers: Map<string, number> = new Map()
  emittedEvents: string[] = []
  auditRecords: string[] = []
}

function requestDecision(st: TApprovalState, view: TApprovalView, policy: ApprovalPolicyKind): ApprovalDecision | null {
  if (policy === 'open') {
    st.auditRecords.push('approved:' + view.toolName)
    return 'approved'
  }
  if (policy === 'standard' && view.level !== 'destructive' && view.level !== 'remote') {
    st.auditRecords.push('approved:' + view.toolName)
    return 'approved'
  }
  view.timeoutAt = Date.now() + APPROVAL_TIMEOUT_MS
  st.resolvers.set(view.requestId, 'pending' as ApprovalDecision)
  st.emittedEvents.push('need_approval:' + view.requestId)
  return null
}

function resolveDecision(st: TApprovalState, requestId: string, decision: ApprovalDecision): boolean {
  const exists = st.resolvers.get(requestId)
  if (exists === undefined) {
    return false
  }
  st.resolvers.delete(requestId)
  st.timers.delete(requestId)
  st.emittedEvents.push('approval_result:' + requestId + ':' + decision)
  st.auditRecords.push(decision + ':requestId=' + requestId)
  return true
}

function onTimeoutDecision(st: TApprovalState, requestId: string): boolean {
  const exists = st.resolvers.get(requestId)
  if (exists === undefined) {
    return false
  }
  st.resolvers.delete(requestId)
  st.timers.delete(requestId)
  st.emittedEvents.push('approval_result:' + requestId + ':timeout_denied')
  st.auditRecords.push('timeout_denied:requestId=' + requestId)
  return true
}

function disposeAll(st: TApprovalState): number {
  const ids = Array.from(st.resolvers.keys())
  for (const id of ids) {
    onTimeoutDecision(st, id)
  }
  return ids.length
}

function isPending(st: TApprovalState, requestId: string): boolean {
  return st.resolvers.get(requestId) !== undefined
}

export default function approvalManagerTest() {
  describe('approvalManagerStateMachine', () => {
    // ===== request open 档 =====
    it('request_open_policy_auto_approved', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.toolName = 'term_write'
      v.level = 'destructive'
      const d = requestDecision(st, v, 'open')
      expect(d === 'approved').assertTrue()
      expect(st.emittedEvents.length === 0).assertTrue()
    })

    it('request_open_policy_no_pending', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'terminal'
      requestDecision(st, v, 'open')
      expect(!isPending(st, 'r1')).assertTrue()
    })

    // ===== request standard 档 =====
    it('request_standard_read_only_auto_approved', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.toolName = 'term_read'
      v.level = 'read_only'
      const d = requestDecision(st, v, 'standard')
      expect(d === 'approved').assertTrue()
      expect(st.emittedEvents.length === 0).assertTrue()
    })

    it('request_standard_workspace_write_auto_approved', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'workspace_write'
      const d = requestDecision(st, v, 'standard')
      expect(d === 'approved').assertTrue()
    })

    it('request_standard_terminal_auto_approved', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'terminal'
      const d = requestDecision(st, v, 'standard')
      expect(d === 'approved').assertTrue()
    })

    it('request_standard_destructive_needs_approval', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.toolName = 'rm'
      v.level = 'destructive'
      const d = requestDecision(st, v, 'standard')
      expect(d === null).assertTrue()
      expect(isPending(st, 'r1')).assertTrue()
      expect(st.emittedEvents.length === 1).assertTrue()
      expect(st.emittedEvents[0] === 'need_approval:r1').assertTrue()
    })

    it('request_standard_remote_needs_approval', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'remote'
      const d = requestDecision(st, v, 'standard')
      expect(d === null).assertTrue()
      expect(isPending(st, 'r1')).assertTrue()
    })

    // ===== request strict 档 =====
    it('request_strict_read_only_needs_approval', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'read_only'
      const d = requestDecision(st, v, 'strict')
      expect(d === null).assertTrue()
      expect(isPending(st, 'r1')).assertTrue()
    })

    it('request_strict_terminal_needs_approval', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'terminal'
      const d = requestDecision(st, v, 'strict')
      expect(d === null).assertTrue()
    })

    it('request_strict_destructive_needs_approval', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      const d = requestDecision(st, v, 'strict')
      expect(d === null).assertTrue()
    })

    // ===== resolve =====
    it('resolve_approved_clears_pending', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      const ok = resolveDecision(st, 'r1', 'approved')
      expect(ok).assertTrue()
      expect(!isPending(st, 'r1')).assertTrue()
    })

    it('resolve_denied_clears_pending', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      const ok = resolveDecision(st, 'r1', 'denied')
      expect(ok).assertTrue()
      expect(!isPending(st, 'r1')).assertTrue()
    })

    it('resolve_emits_approval_result_event', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      resolveDecision(st, 'r1', 'approved')
      expect(st.emittedEvents.length === 2).assertTrue()
      expect(st.emittedEvents[1] === 'approval_result:r1:approved').assertTrue()
    })

    it('resolve_unknown_request_id_ignored', 0, () => {
      const st = new TApprovalState()
      const ok = resolveDecision(st, 'nonexistent', 'approved')
      expect(!ok).assertTrue()
    })

    it('resolve_double_call_idempotent', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      const ok1 = resolveDecision(st, 'r1', 'approved')
      const ok2 = resolveDecision(st, 'r1', 'approved')
      expect(ok1).assertTrue()
      expect(!ok2).assertTrue()
    })

    // ===== onTimeout =====
    it('on_timeout_resolves_timeout_denied', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      const ok = onTimeoutDecision(st, 'r1')
      expect(ok).assertTrue()
      expect(!isPending(st, 'r1')).assertTrue()
    })

    it('on_timeout_emits_timeout_denied_event', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      onTimeoutDecision(st, 'r1')
      expect(st.emittedEvents.length === 2).assertTrue()
      expect(st.emittedEvents[1] === 'approval_result:r1:timeout_denied').assertTrue()
    })

    it('on_timeout_unknown_request_id_ignored', 0, () => {
      const st = new TApprovalState()
      const ok = onTimeoutDecision(st, 'nonexistent')
      expect(!ok).assertTrue()
    })

    // ===== dispose =====
    it('dispose_clears_all_pending', 0, () => {
      const st = new TApprovalState()
      const v1 = new TApprovalView()
      v1.requestId = 'r1'
      v1.level = 'destructive'
      requestDecision(st, v1, 'strict')
      const v2 = new TApprovalView()
      v2.requestId = 'r2'
      v2.level = 'remote'
      requestDecision(st, v2, 'strict')
      const count = disposeAll(st)
      expect(count === 2).assertTrue()
      expect(!isPending(st, 'r1')).assertTrue()
      expect(!isPending(st, 'r2')).assertTrue()
    })

    it('dispose_no_pending_returns_zero', 0, () => {
      const st = new TApprovalState()
      const count = disposeAll(st)
      expect(count === 0).assertTrue()
    })

    it('dispose_emits_timeout_for_each', 0, () => {
      const st = new TApprovalState()
      const v1 = new TApprovalView()
      v1.requestId = 'r1'
      v1.level = 'destructive'
      requestDecision(st, v1, 'strict')
      const v2 = new TApprovalView()
      v2.requestId = 'r2'
      v2.level = 'remote'
      requestDecision(st, v2, 'strict')
      disposeAll(st)
      expect(st.emittedEvents.length === 4).assertTrue()
      expect(st.emittedEvents[2] === 'approval_result:r1:timeout_denied').assertTrue()
      expect(st.emittedEvents[3] === 'approval_result:r2:timeout_denied').assertTrue()
    })

    // ===== 审计记录 =====
    it('auto_approved_generates_audit', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.toolName = 'term_read'
      v.level = 'read_only'
      requestDecision(st, v, 'standard')
      expect(st.auditRecords.length === 1).assertTrue()
      expect(st.auditRecords[0] === 'approved:term_read').assertTrue()
    })

    it('resolve_generates_audit', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      resolveDecision(st, 'r1', 'denied')
      expect(st.auditRecords.length === 1).assertTrue()
      expect(st.auditRecords[0] === 'denied:requestId=r1').assertTrue()
    })

    it('timeout_generates_audit', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      requestDecision(st, v, 'strict')
      onTimeoutDecision(st, 'r1')
      expect(st.auditRecords.length === 1).assertTrue()
      expect(st.auditRecords[0] === 'timeout_denied:requestId=r1').assertTrue()
    })

    // ===== timeoutAt 设置 =====
    it('pending_request_sets_timeout_at', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'destructive'
      v.timeoutAt = 0
      requestDecision(st, v, 'strict')
      expect(v.timeoutAt > 0).assertTrue()
    })

    it('auto_approved_does_not_set_timeout_at', 0, () => {
      const st = new TApprovalState()
      const v = new TApprovalView()
      v.requestId = 'r1'
      v.level = 'read_only'
      v.timeoutAt = 0
      requestDecision(st, v, 'standard')
      expect(v.timeoutAt === 0).assertTrue()
    })
  })
}