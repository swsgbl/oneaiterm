/**
 * tty7 HMH 事件桥(任务 tty7-M5a)。
 *
 * 零改动 agent/:HmhAdapter 事件流本就经 AgentAdapter.subscribe(sessionId,
 * listener) 公开可订阅(与 AIDock 同通道),桥在**自己的调用点**做包装映射——
 * agent/ 目录一行不改,不触碰审批决策(ApprovalManager 原路径照常,桥只把
 * need_approval 转发为 approval_required 广播)。
 *
 * 映射(agent AgentEvent → tty7 AgentEvent v1,以 HmhAdapter 实际字段为准):
 *   session_started→run_started(working) / message→delta(message) /
 *   tool_call(result='')→tool_call,tool_call(result≠'')→tool_result /
 *   need_approval→approval_required / approval_result→tool_result /
 *   done→final(ok)+state_changed(idle 收口) / error→state_changed(error)+
 *   attention / state_changed→state_changed(取消→idle,其余 working) /
 *   engine_state_changed(UNAVAILABLE)→state_changed(error) /
 *   session_resumed→session_checkpoint;turn/audit_write_failed→attention。
 * paneId 暂 ''(M5b pane 绑定);agentId='hmh';runId 桥侧任务号。
 *
 * M5b:
 *   - sendTask 增可选参 paneId(默认 '');dispatch 统一分发口(map→paneId
 *     覆写→emit;pane 事件触发 agentRevTap);activeOnPane 纯查询 bus
 *     (run_started.paneId 命中且未 final 即活跃——PaneSurface '✦' 标记源);
 *   - approval_required/approval_result 事件携带 requestId→v1 toolId
 *     (审批卡匹配/置灰对账;ApprovalView 原负载只读挂接,不复制凭据);
 *   - decide():决策走 AgentAdapter.approve→ApprovalManager 原通道
 *     (只调不造;决策不进 bus,approval_result 回流照常广播)。
 */
import { AgentAdapter } from '../../agent/AgentAdapter';
import {
  AgentEvent as AE, AgentEventListener, AgentSessionConfig, PromptAck, PromptInput,
  ApprovalDecision, AGENT_ENGINE_UNAVAILABLE
} from '../../agent/AgentProvider';
import { AgentSettingsStore } from '../../service/AgentSettingsStore';
import { AgentEvent, AgentEventType } from './AgentEvent';
import { AgentEventBus } from './AgentEventBus';

/** activeOnPane 回看深度(覆盖一个 run 的全部事件;bus 环形 200)。 */
const RING_SCAN: number = 200;

export class HmhEventBridge {
  private static attached: boolean = false
  private static runSeq: number = 0
  /** 当前活跃订阅退订口(hmh 单流 v1;新任务前先退旧)。 */
  private static unsub: (() => void) | null = null
  /** pane 活跃标记回调(emit 含 paneId 的事件后触发;Vm 注册驱动 agentRev)。 */
  private static agentRevTap: (() => void) | null = null
  /** runId→sessionId 映射(decide 决策通道寻址用;runId 桥侧任务号)。 */
  private static sessionOf: Map<string, string> = new Map()

  /** 挂载(幂等)。v1 无常驻流——真实接线发生在 sendTask 的 subscribe,此处仅置位。 */
  static attach(): void {
    HmhEventBridge.attached = true
  }

  /** 卸载:断开当前流并置位(不销毁总线)。 */
  static detach(): void {
    HmhEventBridge.closeStream()
    HmhEventBridge.attached = false
  }

  static isAttached(): boolean {
    return HmhEventBridge.attached
  }

  /** 注册 pane 活跃标记回调(AppShell aboutToAppear 绑 vm.agentRev++;null 清除)。 */
  static setAgentRevTap(fn: (() => void) | null): void {
    HmhEventBridge.agentRevTap = fn
  }

  /** pane 是否有活跃 run:bus 里最近 run_started.paneId 命中且其后无 final。
   *  纯查询(PaneSurface 标题表达式借 vm.agentRev 建立追踪后调用,同 slotsRev)。 */
  static activeOnPane(paneId: string): boolean {
    if (paneId === '') {
      return false
    }
    const ring = AgentEventBus.instance().recent(RING_SCAN)
    // 回看本 pane 的 run:最近的 run_started(paneId 命中)之后若无 final 收口
    // 即活跃。final(任意)在 run_started 之前出现 → 该 run 已收口。
    let started = false
    for (let i = ring.length - 1; i >= 0; i--) {
      const ev = ring[i]
      if (ev.type === 'final' && ev.paneId === paneId) {
        return false // 本 pane 最近 run 已收口
      }
      if (ev.type === 'run_started' && ev.paneId === paneId) {
        started = true
        break
      }
    }
    return started
  }

  private static closeStream(): void {
    const u = HmhEventBridge.unsub
    HmhEventBridge.unsub = null
    if (u !== null) {
      u()
    }
  }

  /**
   * 面板发送任务:hmh 引擎一条龙(createSession→subscribe→prompt),
   * 事件经 map 进总线。结果:'ok'|'no_engine'(未配置,不假成功)|'reject:码'|
   * 'fail:原因'。任务文本原样透传(不加包装)。
   */
  static async sendTask(text: string, paneId: string = ''): Promise<string> {
    const t = text.trim()
    if (t === '') {
      return 'empty'
    }
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const settings = AgentSettingsStore.read(filesDir)
    if (settings.engines.hmh.baseUrl === '') {
      return 'no_engine'
    }
    HmhEventBridge.attach()
    const bus = AgentEventBus.instance()
    HmhEventBridge.runSeq += 1
    const runId = 'r' + HmhEventBridge.runSeq.toString()
    const adapter = AgentAdapter.instance()
    const cfg = new AgentSessionConfig()
    cfg.engine = 'hmh'
    cfg.title = t.substring(0, 40)
    try {
      const h = await adapter.createSession(cfg)
      HmhEventBridge.closeStream()
      HmhEventBridge.sessionOf.set(runId, h.sessionId)
      const listener: AgentEventListener = (e: AE): void => {
        HmhEventBridge.dispatch(runId, paneId, e)
      }
      HmhEventBridge.unsub = adapter.subscribe(h.sessionId, listener)
      const pi = new PromptInput()
      pi.text = t
      const ack: PromptAck = await adapter.prompt(h.sessionId, pi)
      if (!ack.accepted) {
        return 'reject:' + ack.errCode
      }
      // pane 活跃锚点:引擎 session_started 在 subscribe 前 emit(桥收不到),
      // 提交受理后补发 run_started(paneId) 使 activeOnPane 有源(final 收口)
      if (paneId !== '') {
        const anchor = new AgentEvent()
        anchor.runId = runId
        anchor.agentId = 'hmh'
        anchor.paneId = paneId
        anchor.type = 'run_started'
        anchor.state = 'working'
        AgentEventBus.instance().emit(anchor)
        const tap0 = HmhEventBridge.agentRevTap
        if (tap0 !== null) {
          tap0()
        }
      }
      return 'ok'
    } catch (e) {
      return 'fail:' + (e instanceof Error ? e.message : String(e))
    }
  }

  /** 统一分发口:map→paneId 覆写→emit;pane 事件(pneId≠'')触发 agentRevTap。 */
  static dispatch(runId: string, paneId: string, e: AE): void {
    const ev = HmhEventBridge.map(runId, e)
    ev.paneId = paneId
    AgentEventBus.instance().emit(ev)
    if (ev.paneId !== '') {
      const tap = HmhEventBridge.agentRevTap
      if (tap !== null) {
        tap()
      }
    }
  }

  /** 审批决策:走 AgentAdapter.approve→ApprovalManager 原通道(只调不造;
   *  决策不进 bus,approval_result 回流照常广播)。未知 runId→false 不 fail-open。 */
  static async decide(runId: string, requestId: string, decision: string): Promise<boolean> {
    const sid = HmhEventBridge.sessionOf.get(runId)
    if (sid === undefined) {
      return false
    }
    try {
      await AgentAdapter.instance().approve(sid, requestId, decision as ApprovalDecision)
      return true
    } catch (e) {
      return false
    }
  }

  /**
   * 纯映射(单测靶;不碰 IO)。
   * agent AgentEvent(引擎统一事件)→ tty7 AgentEvent v1。
   */
  static map(runId: string, e: AE): AgentEvent {
    const ev = new AgentEvent()
    ev.runId = runId
    ev.agentId = 'hmh'
    ev.paneId = ''
    let type: AgentEventType = 'attention'
    switch (e.kind) {
      case 'session_started':
        type = 'run_started'
        ev.state = 'working'
        break
      case 'state_changed':
        type = 'state_changed'
        ev.state = e.text.indexOf('已取消') >= 0 ? 'idle' : 'working'
        ev.text = e.text
        break
      case 'engine_state_changed':
        type = 'state_changed'
        ev.state = e.errCode === AGENT_ENGINE_UNAVAILABLE ? 'error' : 'working'
        ev.text = e.text
        break
      case 'message':
        type = 'delta'
        ev.kind = 'message'
        ev.text = e.text
        break
      case 'tool_call': {
        const tv = e.tool
        const hasResult = tv !== null && tv.result !== ''
        type = hasResult ? 'tool_result' : 'tool_call'
        ev.toolName = tv !== null ? tv.name : ''
        ev.argsDigest = tv !== null ? tv.argsDigest : ''
        ev.riskLevel = e.level !== '' ? e.level : ''
        ev.ok = tv === null ? true : !tv.isError
        ev.text = tv !== null ? tv.result : ''
        break
      }
      case 'need_approval': {
        type = 'approval_required'
        const av = e.approval
        ev.toolName = av !== null ? av.toolName : ''
        ev.argsDigest = av !== null ? av.argsDigest : ''
        ev.riskLevel = e.level !== '' ? e.level : ''
        ev.toolId = av !== null ? av.requestId : '' // 审批卡匹配/置灰对账
        ev.state = 'waiting'
        break
      }
      case 'approval_result':
        type = 'tool_result'
        ev.text = e.text
        ev.ok = e.text === 'approved'
        ev.toolName = ''
        ev.toolId = e.approval !== null ? e.approval.requestId : ''
        break
      case 'done':
        type = 'final'
        ev.ok = true
        ev.text = e.text
        break
      case 'error':
        type = 'attention'
        ev.ok = false
        ev.text = e.text
        break
      case 'turn':
        type = 'session_checkpoint'
        ev.text = 'turn ' + e.turn.toString()
        break
      case 'session_resumed':
        type = 'session_checkpoint'
        ev.text = e.sessionId !== '' ? 'resumed ' + e.sessionId : 'resumed'
        break
      case 'audit_write_failed':
        type = 'attention'
        ev.ok = false
        ev.text = '审计写入失败'
        break
      case 'ui_action':
      default:
        type = 'attention'
        ev.text = e.text
        break
    }
    ev.type = type
    return ev
  }

  /** final 后置 idle 收口点(RightPanel 状态点回 success)。 */
  static emitIdle(runId: string): void {
    const ev = new AgentEvent()
    ev.runId = runId
    ev.agentId = 'hmh'
    ev.type = 'state_changed'
    ev.state = 'idle'
    AgentEventBus.instance().emit(ev)
  }
}
