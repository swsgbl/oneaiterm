/**
 * tty7 单测:AgentEventBus + HmhEventBridge.map(任务 tty7-M5a)。
 * 覆盖:
 *   1. emit/subscribe 收到 + seq 单调
 *   2. unsubscribe 后不再收
 *   3. 订阅者抛异常不影响其他订阅者
 *   4. recent 环形 200 截断
 *   5. HmhEventBridge.map 引擎事件→v1 映射(done→final/need_approval→
 *      approval_required/tool_result/UNAVAILABLE→error/取消→idle)
 */
import { describe, it, expect } from '@ohos/hypium';
import { AgentEventBus } from '../../../main/ets/tty7/agent/AgentEventBus';
import { AgentEvent } from '../../../main/ets/tty7/agent/AgentEvent';
import { HmhEventBridge } from '../../../main/ets/tty7/agent/HmhEventBridge';
import {
  AgentEvent as AE, ToolCallView, ApprovalView, AGENT_ENGINE_UNAVAILABLE
} from '../../../main/ets/agent/AgentProvider';

/** 按类型构造最小事件(type 字面量直赋,避免字符串 as 联合类型)。 */
function mkDelta(): AgentEvent {
  const e = new AgentEvent()
  e.type = 'delta'
  e.text = 'x'
  return e
}

export default function agentEventBusTest() {
  describe('tty7AgentEventBus', () => {
    it('emit_subscribes_and_seq_increases', 0, () => {
      const bus = AgentEventBus.instance()
      const seen: AgentEvent[] = []
      const id = bus.subscribe((ev: AgentEvent): void => {
        seen.push(ev)
      })
      bus.emit(mkDelta())
      bus.emit(mkDelta())
      bus.unsubscribe(id)
      expect(seen.length).assertEqual(2)
      expect(seen[0].ts > 0).assertTrue()
      expect(seen[1].seq > seen[0].seq).assertTrue()
    })

    it('unsubscribe_stops_delivery', 0, () => {
      const bus = AgentEventBus.instance()
      let n = 0
      const id = bus.subscribe((): void => {
        n += 1
      })
      bus.emit(mkDelta())
      bus.unsubscribe(id)
      bus.emit(mkDelta())
      expect(n).assertEqual(1)
    })

    it('subscriber_throw_does_not_kill_others', 0, () => {
      const bus = AgentEventBus.instance()
      let got = 0
      const idBad = bus.subscribe((ev: AgentEvent): void => {
        if (ev.seq > 0) {
          throw new Error('boom')
        }
      })
      const idOk = bus.subscribe((): void => {
        got += 1
      })
      bus.emit(mkDelta())
      bus.unsubscribe(idBad)
      bus.unsubscribe(idOk)
      expect(got).assertEqual(1)
    })

    it('recent_ring_truncates_at_200', 0, () => {
      const bus = AgentEventBus.instance()
      bus.clear()
      for (let i = 0; i < 230; i++) {
        bus.emit(mkDelta())
      }
      const r = bus.recent(1000)
      expect(r.length).assertEqual(200)
      expect(bus.recent(50).length).assertEqual(50)
      // seq 跨用例连续:断言环内首尾相对差(230 emit 后保留最后 200 条)
      expect(r[0].seq).assertEqual(r[199].seq - 199)
      expect(r[0].seq > 30).assertTrue() // 前 30 条确实被砍头(起始 seq>=1)
      bus.clear()
      expect(bus.recent(100).length).assertEqual(0)
    })

    it('bridge_maps_engine_events_to_v1', 0, () => {
      // done → final
      const ae = new AE()
      ae.kind = 'done'
      ae.text = 'M5A-OK'
      const fin = HmhEventBridge.map('r1', ae)
      expect(fin.type).assertEqual('final')
      expect(fin.ok).assertTrue()
      expect(fin.text).assertEqual('M5A-OK')
      expect(fin.agentId).assertEqual('hmh')
      // tool_call 无 result → v1 tool_call;有 result → tool_result
      const t0 = new AE()
      t0.kind = 'tool_call'
      const tv = new ToolCallView()
      tv.name = 'run_command'
      tv.argsDigest = 'd1'
      t0.tool = tv
      t0.level = 'terminal'
      const c0 = HmhEventBridge.map('r1', t0)
      expect(c0.type).assertEqual('tool_call')
      expect(c0.toolName).assertEqual('run_command')
      expect(c0.riskLevel).assertEqual('terminal')
      tv.result = 'ok-out'
      const c1 = HmhEventBridge.map('r1', t0)
      expect(c1.type).assertEqual('tool_result')
      expect(c1.ok).assertTrue()
      tv.isError = true
      const c2 = HmhEventBridge.map('r1', t0)
      expect(c2.ok).assertFalse()
      // need_approval → approval_required(waiting)
      const ap = new AE()
      ap.kind = 'need_approval'
      const av = new ApprovalView()
      av.toolName = 'sftp'
      av.argsDigest = 'd2'
      ap.approval = av
      ap.level = 'remote'
      const a0 = HmhEventBridge.map('r1', ap)
      expect(a0.type).assertEqual('approval_required')
      expect(a0.state).assertEqual('waiting')
      expect(a0.riskLevel).assertEqual('remote')
      // engine UNAVAILABLE → error 态
      const un = new AE()
      un.kind = 'engine_state_changed'
      un.text = 'HMH 服务不可达'
      un.errCode = AGENT_ENGINE_UNAVAILABLE
      const u0 = HmhEventBridge.map('r1', un)
      expect(u0.type).assertEqual('state_changed')
      expect(u0.state).assertEqual('error')
      // state_changed 取消文案 → idle
      const sc = new AE()
      sc.kind = 'state_changed'
      sc.text = '已取消: 手动'
      const s0 = HmhEventBridge.map('r1', sc)
      expect(s0.state).assertEqual('idle')
      // message → delta(message)
      const m0AE = new AE()
      m0AE.kind = 'message'
      m0AE.text = 'hi'
      const d0 = HmhEventBridge.map('r1', m0AE)
      expect(d0.type).assertEqual('delta')
      expect(d0.kind).assertEqual('message')
      // run_started / checkpoint
      const ss = new AE()
      ss.kind = 'session_started'
      const r0 = HmhEventBridge.map('r1', ss)
      expect(r0.type).assertEqual('run_started')
      expect(r0.state).assertEqual('working')
      const sr = new AE()
      sr.kind = 'session_resumed'
      expect(HmhEventBridge.map('r1', sr).type).assertEqual('session_checkpoint')
    })
  })
}
