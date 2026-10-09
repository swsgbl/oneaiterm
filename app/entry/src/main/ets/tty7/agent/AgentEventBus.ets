/**
 * tty7 AgentEvent 发布/订阅总线(任务 tty7-M5a;01 文档 AgentEvent v1)。
 * 单例;emit 同步分发(seq 单调自增 + ts 填充),订阅者异常 try 隔离互不影响;
 * recent(n) 环形 200 条回放(RightPanel 挂载时取历史)。
 * 红线:纯 ArkTS 无 UI 依赖;只广播不做审批决策(approval_required 原样转发,
 * 决策仍在 agent/security 原路径);易失层——事件不进 preferences/存档。
 */
import { AgentEvent } from './AgentEvent';

const RING_MAX: number = 200;

class BusSub {
  id: number = 0
  fn: (ev: AgentEvent) => void = (_ev: AgentEvent): void => {
  }
}

export class AgentEventBus {
  private static sInst: AgentEventBus | null = null
  private seq: number = 0
  private subSeq: number = 0
  private subs: BusSub[] = []
  private ring: AgentEvent[] = []

  static instance(): AgentEventBus {
    if (AgentEventBus.sInst === null) {
      AgentEventBus.sInst = new AgentEventBus()
    }
    return AgentEventBus.sInst
  }

  /** 订阅;返回订阅 id(unsubscribe 用)。 */
  subscribe(fn: (ev: AgentEvent) => void): number {
    this.subSeq += 1
    const s = new BusSub()
    s.id = this.subSeq
    s.fn = fn
    this.subs = this.subs.concat([s])
    return s.id
  }

  /** 退订(未订阅 id no-op)。 */
  unsubscribe(id: number): void {
    const kept: BusSub[] = []
    for (const s of this.subs) {
      if (s.id !== id) {
        kept.push(s)
      }
    }
    this.subs = kept
  }

  /** 发布:seq 自增 + ts 填充;同步分发,订阅者异常隔离;环形 200 截断。 */
  emit(ev: AgentEvent): void {
    this.seq += 1
    ev.seq = this.seq
    ev.ts = Date.now()
    this.ring = this.ring.concat([ev])
    if (this.ring.length > RING_MAX) {
      this.ring = this.ring.slice(this.ring.length - RING_MAX)
    }
    const snapshot = this.subs
    for (const s of snapshot) {
      try {
        s.fn(ev)
      } catch (e) {
        // 订阅者异常隔离:不杀总线、不影响其他订阅者
      }
    }
  }

  /** 回放最近 n 条(挂载时取历史;n<=0 空)。 */
  recent(n: number): AgentEvent[] {
    if (n <= 0) {
      return []
    }
    const start = Math.max(0, this.ring.length - n)
    return this.ring.slice(start)
  }

  /** 清空回放缓冲(订阅者不动;测试隔离用)。 */
  clear(): void {
    this.ring = []
  }
}
