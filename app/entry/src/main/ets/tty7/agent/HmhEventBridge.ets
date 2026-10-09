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
 */
import { AgentAdapter } from '../../agent/AgentAdapter';
import {
  AgentEvent as AE, AgentEventListener, AgentSessionConfig, PromptAck, PromptInput,
  AGENT_ENGINE_UNAVAILABLE
} from '../../agent/AgentProvider';
import { AgentSettingsStore } from '../../service/AgentSettingsStore';
import { AgentEvent, AgentEventType } from './AgentEvent';
import { AgentEventBus } from './AgentEventBus';

export class HmhEventBridge {
  private static attached: boolean = false
  private static runSeq: number = 0
  /** 当前活跃订阅退订口(hmh 单流 v1;新任务前先退旧)。 */
  private static unsub: (() => void) | null = null

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
  static async sendTask(text: string): Promise<string> {
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
      const listener: AgentEventListener = (e: AE): void => {
        bus.emit(HmhEventBridge.map(runId, e))
      }
      HmhEventBridge.unsub = adapter.subscribe(h.sessionId, listener)
      const pi = new PromptInput()
      pi.text = t
      const ack: PromptAck = await adapter.prompt(h.sessionId, pi)
      if (!ack.accepted) {
        return 'reject:' + ack.errCode
      }
      return 'ok'
    } catch (e) {
      return 'fail:' + (e instanceof Error ? e.message : String(e))
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
        ev.state = 'waiting'
        break
      }
      case 'approval_result':
        type = 'tool_result'
        ev.text = e.text
        ev.ok = e.text === 'approved'
        ev.toolName = ''
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
        ev.text = 'resumed'
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
