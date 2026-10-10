/**
 * tty7 单测:审批卡 + pane 绑定逻辑(任务 tty7-M5b)。
 * 覆盖:
 *   1. map 恒 paneId=''(M5a 占位);bridge.dispatch 统一覆写 paneId 后入 bus
 *   2. activeOnPane:run_started(p1)+未 final → true;final 后 → false
 *   3. 审批卡:approvalToneOf 风险色映射 + approvalSettled 同 id 置灰判定
 *      (approval_required/approval_result 均携带 requestId→toolId)
 *   4. agentRev 递增(pane 事件经 setAgentRevTap 回调触发;面板级事件不触发)
 *   5. checkpointLabel 会话恢复文案
 */
import { describe, it, expect } from '@ohos/hypium';
import { AgentEventBus } from '../../../main/ets/tty7/agent/AgentEventBus';
import { AgentEvent } from '../../../main/ets/tty7/agent/AgentEvent';
import { HmhEventBridge } from '../../../main/ets/tty7/agent/HmhEventBridge';
import { approvalToneOf, approvalSettled, checkpointLabel } from '../../../main/ets/tty7/agent/ApprovalCardLogic';
import {
  AgentEvent as AE, ApprovalView
} from '../../../main/ets/agent/AgentProvider';

export default function agentApprovalTest() {
  describe('tty7AgentApproval', () => {
    it('map_keeps_pane_placeholder_and_dispatch_overrides', 0, () => {
      // map 恒 paneId=''(M5a 占位);pane 归属由 dispatch 统一覆写
      const ss = new AE()
      ss.kind = 'session_started'
      const m = HmhEventBridge.map('r1', ss)
      expect(m.paneId).assertEqual('')
      // dispatch:map→paneId 覆写→emit;bus 最近事件 paneId=p1
      const bus = AgentEventBus.instance()
      bus.clear()
      HmhEventBridge.dispatch('r9', 'p1', ss)
      const r = bus.recent(1)
      expect(r.length).assertEqual(1)
      expect(r[0].runId).assertEqual('r9')
      expect(r[0].paneId).assertEqual('p1')
      expect(r[0].type).assertEqual('run_started')
      // pane='' 面板级事件:paneId 保持 ''
      const msg = new AE()
      msg.kind = 'message'
      msg.text = 'x'
      HmhEventBridge.dispatch('r9', '', msg)
      const r2 = bus.recent(1)
      expect(r2[0].paneId).assertEqual('')
      expect(r2[0].type).assertEqual('delta')
    })

    it('activeOnPane_run_started_then_final', 0, () => {
      const bus = AgentEventBus.instance()
      bus.clear()
      // 无事件 → false
      expect(HmhEventBridge.activeOnPane('p1')).assertFalse()
      // run_started(p1) 未 final → true;他 pane → false
      const ss = new AE()
      ss.kind = 'session_started'
      HmhEventBridge.dispatch('r1', 'p1', ss)
      expect(HmhEventBridge.activeOnPane('p1')).assertTrue()
      expect(HmhEventBridge.activeOnPane('p2')).assertFalse()
      // final 后 → false
      const fin = new AE()
      fin.kind = 'done'
      fin.text = 'ok'
      HmhEventBridge.dispatch('r1', 'p1', fin)
      expect(HmhEventBridge.activeOnPane('p1')).assertFalse()
      // 新 run 再起(p1 活跃) → true
      const ss2 = new AE()
      ss2.kind = 'session_started'
      HmhEventBridge.dispatch('r2', 'p1', ss2)
      expect(HmhEventBridge.activeOnPane('p1')).assertTrue()
    })

    it('approval_card_tone_and_settled_matching', 0, () => {
      // 风险色档:destructive/remote→danger,terminal→warn,低档/空→brand
      expect(approvalToneOf('destructive')).assertEqual('danger')
      expect(approvalToneOf('remote')).assertEqual('danger')
      expect(approvalToneOf('terminal')).assertEqual('warn')
      expect(approvalToneOf('workspace_write')).assertEqual('brand')
      expect(approvalToneOf('read_only')).assertEqual('brand')
      expect(approvalToneOf('')).assertEqual('brand')
      // approval_required 映射携带 requestId(toolId)
      const ap = new AE()
      ap.kind = 'need_approval'
      const av = new ApprovalView()
      av.toolName = 'run_command'
      av.argsDigest = 'rm -rf /tmp/x'
      av.level = 'remote'
      av.requestId = 'req-7'
      ap.approval = av
      ap.level = 'remote'
      const card = HmhEventBridge.map('r1', ap)
      expect(card.type).assertEqual('approval_required')
      expect(card.toolId).assertEqual('req-7')
      expect(card.riskLevel).assertEqual('remote')
      // 同 id approval_result(映射 tool_result)→ 置灰判定 true
      const ar = new AE()
      ar.kind = 'approval_result'
      ar.text = 'denied'
      const rv = new ApprovalView()
      rv.requestId = 'req-7'
      ar.approval = rv
      const res = HmhEventBridge.map('r1', ar)
      expect(res.type).assertEqual('tool_result')
      expect(res.toolId).assertEqual('req-7')
      const stream: AgentEvent[] = [card, res]
      expect(approvalSettled(stream, 'req-7')).assertTrue()
      // 无对应 result → 未收口(卡片可点);空 id 恒 false
      expect(approvalSettled(stream, 'req-8')).assertFalse()
      expect(approvalSettled(stream, '')).assertFalse()
    })

    it('agent_rev_tap_fires_on_pane_events', 0, () => {
      const bus = AgentEventBus.instance()
      bus.clear()
      let rev = 0
      HmhEventBridge.setAgentRevTap((): void => {
        rev += 1
      })
      // 面板级事件('')不触发
      const msg = new AE()
      msg.kind = 'message'
      HmhEventBridge.dispatch('r1', '', msg)
      expect(rev).assertEqual(0)
      // pane 事件触发
      HmhEventBridge.dispatch('r1', 'p1', msg)
      expect(rev).assertEqual(1)
      const ss = new AE()
      ss.kind = 'session_started'
      HmhEventBridge.dispatch('r1', 'p1', ss)
      expect(rev).assertEqual(2)
      // 清 tap 后不再触发
      HmhEventBridge.setAgentRevTap(null)
      HmhEventBridge.dispatch('r1', 'p1', msg)
      expect(rev).assertEqual(2)
    })

    it('checkpoint_label_resumed_and_turn', 0, () => {
      expect(checkpointLabel('resumed')).assertEqual('↻ 会话恢复')
      expect(checkpointLabel('resumed sess-abcdefgh-9999')).assertEqual('↻ 会话恢复 sess-abc')
      expect(checkpointLabel('turn 3')).assertEqual('↻ 检查点 turn 3')
      // bridge 映射:session_resumed 携带 sessionId 前缀
      const sr = new AE()
      sr.kind = 'session_resumed'
      sr.sessionId = 'sess-zzzzzzzz'
      const ck = HmhEventBridge.map('r1', sr)
      expect(ck.type).assertEqual('session_checkpoint')
      expect(checkpointLabel(ck.text)).assertEqual('↻ 会话恢复 sess-zzz')
    })
  })
}
