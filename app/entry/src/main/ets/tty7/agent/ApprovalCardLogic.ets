/**
 * tty7 审批卡纯逻辑(任务 tty7-M5b;单测靶,零 UI 依赖)。
 * RightPanel 审批卡与 AgentApproval.test.ets 共用:风险色档/收口判定/checkpoint 文案。
 * 红线:argsDigest 只做展示;决策不在此处(经 HmhEventBridge.decide 走
 * AgentAdapter.approve → ApprovalManager 原通道,卡片只调不造)。
 */
import { AgentEvent } from './AgentEvent';

/** 审批风险色档:destructive/remote→danger,terminal→warn,其余(含空)→brand。 */
export function approvalToneOf(level: string): string {
  if (level === 'destructive' || level === 'remote') {
    return 'danger'
  }
  if (level === 'terminal') {
    return 'warn'
  }
  return 'brand'
}

/**
 * 审批卡是否已收口:事件流里存在同 approvalId(toolId)的 approval_result
 * (v1 映射为 tool_result 且 toolName===''、text∈三决策值)即已决策/过期。
 */
export function approvalSettled(events: AgentEvent[], approvalId: string): boolean {
  if (approvalId === '') {
    return false
  }
  for (const ev of events) {
    if (ev.toolId === approvalId && ev.type === 'tool_result' && ev.toolName === '' &&
      (ev.text === 'approved' || ev.text === 'denied' || ev.text === 'timeout_denied')) {
      return true
    }
  }
  return false
}

/** checkpoint 卡文案:'resumed[ sid]'→会话恢复(sid 取前 8 位前缀);
 *  turn N→检查点。桩卡:HMH resume 机制接入留 M8 CLI 棒。 */
export function checkpointLabel(text: string): string {
  if (text === 'resumed') {
    return '↻ 会话恢复'
  }
  if (text.indexOf('resumed ') === 0) {
    const sid = text.substring('resumed '.length)
    return '↻ 会话恢复 ' + sid.substring(0, 8)
  }
  return '↻ 检查点 ' + text
}
