/**
 * AgentAdapter 引擎路由与全量收口（升级 Phase 1 / 任务 2.10，design 2.1.2/2.2.2.1）。
 *
 * - 引擎注册表（注册/选择/状态查询）；Phase 1 注册 LocalAssistant；
 *   Phase 2/3 注册 HmhAdapter/AcpClient 后即插即用（A2A 预留扩展点）；
 * - 六方法路由到对应引擎；作为 AgentProvider 的唯一实现暴露给 UI；
 * - HMH 不可达回落编排：连接失败/中断 → hmhAvailable=false + 明确提示
 *   （不静默降级，spec 5.2.1.4/5.3.1.4）→ 后续 createSession 自动回落
 *   LocalAssistant 并标注"当前引擎：本地辅助（HMH 不可达）"；
 * - resumeSession 前置校验：会话存在 + 引擎类型匹配（不得错配，spec 6.1.2）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AgentEvent, AgentEventListener, AgentProvider, AgentSessionConfig,
  AgentSessionHandle, AgentEngineType, AGENT_ENGINE_MISMATCH,
  AGENT_ENGINE_UNAVAILABLE, AGENT_SESSION_NOT_FOUND,
  PromptAck, PromptInput, ApprovalDecision, Unsubscribe
} from './AgentProvider';
import { AgentSessionMeta, AgentSessionStore } from './AgentSessionStore';
import { LocalAssistant } from './engine/LocalAssistant';
import { HmhAdapter } from './engine/HmhAdapter';
import { AcpClient } from './engine/AcpClient';
import { HarnessClient } from '../service/HarnessClient';

const TAG: string = 'oat.adapter';
const DOMAIN: number = 0x0110;

export class AgentAdapter implements AgentProvider {
  private static inst: AgentAdapter | null = null
  private engines: Map<AgentEngineType, AgentProvider> = new Map()
  private filesDir: string = ''
  private local: LocalAssistant | null = null
  /** HMH 可用性（连接失败/中断后置 false，回落编排依据）。 */
  private hmhAvailable: boolean = true
  private hmhRegistered: boolean = false
  /** 回落提示（回落时明确标注引擎状态，不静默降级）。 */
  private fallbackNote: string = ''

  private constructor() {
  }

  static instance(): AgentAdapter {
    if (AgentAdapter.inst === null) {
      AgentAdapter.inst = new AgentAdapter()
    }
    return AgentAdapter.inst
  }

  /** 初始化（UI 首次调用时注册本地引擎 + HMH 引擎 + ACP 引擎；幂等）。 */
  private ensureLocal(): LocalAssistant {
    if (this.local === null) {
      const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
      this.filesDir = filesDir
      this.local = new LocalAssistant(filesDir)
      this.engines.set('local', this.local)
      const hmh = new HmhAdapter(filesDir)
      this.engines.set('hmh', hmh)
      this.hmhRegistered = true
      const acp = new AcpClient(filesDir)
      this.engines.set('acp', acp)
    }
    return this.local
  }

  /** 注册引擎（Phase 2/3 引擎接入点；A2A 多 Agent 预留扩展点）。 */
  registerEngine(type: AgentEngineType, provider: AgentProvider): void {
    this.engines.set(type, provider)
    if (type === 'hmh') {
      this.hmhAvailable = true
    }
  }

  /** 引擎状态查询（'ready' | 'unavailable' | '未接入'）。 */
  engineStatus(type: AgentEngineType): string {
    const e = this.engines.get(type)
    if (e === undefined) {
      return type === 'local' ? 'ready' : '未接入'
    }
    if (type === 'hmh' && !this.hmhAvailable) {
      return 'unavailable'
    }
    return 'ready'
  }

  /** HMH 连接测试（复用存量 HarnessClient 底座；设置页经此调用，UI 不直接 import 引擎层）。 */
  async testHmh(url: string): Promise<string> {
    const r = await HarnessClient.test(url)
    return r.detail
  }

  /** 回落提示（UI 标注引擎状态用）。 */
  getFallbackNote(): string {
    return this.fallbackNote
  }

  /** 目标引擎（含回落判定）。 */
  private targetEngine(engine: AgentEngineType): AgentProvider | null {
    const e = this.engines.get(engine)
    if (e === undefined) {
      return null
    }
    if (engine === 'hmh' && !this.hmhAvailable) {
      return null
    }
    return e
  }

  /** HMH 不可达时的回落会话（自动切 local + 明确提示，不静默降级）。 */
  private async fallbackLocal(config: AgentSessionConfig): Promise<AgentSessionHandle> {
    this.fallbackNote = '当前引擎: 本地辅助（HMH 不可达）'
    const la = this.ensureLocal()
    const fc = new AgentSessionConfig()
    fc.engine = 'local'
    fc.title = config.title
    return await la.createSession(fc)
  }

  async createSession(config: AgentSessionConfig): Promise<AgentSessionHandle> {
    if (config.engine === 'local') {
      const la = this.ensureLocal()
      return await la.createSession(config)
    }
    // 非本地引擎：注册且可用则用之；否则回落 local（明确提示）
    const e = this.targetEngine(config.engine)
    if (e === null) {
      hilog.warn(DOMAIN, TAG, 'engine %{public}s unavailable, fallback local', config.engine)
      this.fallbackNote = '当前引擎: 本地辅助（' + config.engine + ' 引擎不可用）'
      return await this.fallbackLocal(config)
    }
    this.fallbackNote = ''
    return await e.createSession(config)
  }

  async resumeSession(sessionId: string): Promise<AgentSessionHandle> {
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const meta = AgentSessionStore.read(filesDir, sessionId)
    if (meta === null) {
      // 会话不存在：明确错误，不静默新建（design 2.1.3.3）
      const err = new Error(AGENT_SESSION_NOT_FOUND)
      throw err
    }
    // 引擎不可用（HMH）：aborted 会话回落 local 重建上下文（明确提示）
    if (meta.engine === 'hmh' && !this.hmhAvailable) {
      hilog.warn(DOMAIN, TAG, 'resume %{public}s: hmh unavailable, fallback local', sessionId)
      this.fallbackNote = '当前引擎: 本地辅助（HMH 不可达）'
      const la = this.ensureLocal()
      const fc = new AgentSessionConfig()
      fc.engine = 'local'
      fc.title = meta.title
      return await la.createSession(fc)
    }
    const e = this.engines.get(meta.engine)
    if (e === undefined) {
      const err = new Error(AGENT_ENGINE_MISMATCH)
      throw err
    }
    return await e.resumeSession(sessionId)
  }

  async prompt(sessionId: string, input: PromptInput): Promise<PromptAck> {
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const meta = AgentSessionStore.read(filesDir, sessionId)
    if (meta === null) {
      const ack = new PromptAck()
      ack.sessionId = sessionId
      ack.accepted = false
      ack.errCode = AGENT_SESSION_NOT_FOUND
      return ack
    }
    // HMH 会话不可用：prompt 层回落（发 state_changed 提示）
    if (meta.engine === 'hmh' && !this.hmhAvailable) {
      const ack = new PromptAck()
      ack.sessionId = sessionId
      ack.accepted = false
      ack.errCode = AGENT_ENGINE_UNAVAILABLE
      return ack
    }
    const e = this.engines.get(meta.engine)
    if (e === undefined) {
      const ack = new PromptAck()
      ack.sessionId = sessionId
      ack.accepted = false
      ack.errCode = AGENT_ENGINE_MISMATCH
      return ack
    }
    return await e.prompt(sessionId, input)
  }

  async cancel(sessionId: string, reason: string): Promise<void> {
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const meta = AgentSessionStore.read(filesDir, sessionId)
    if (meta === null) {
      return
    }
    const e = this.engines.get(meta.engine)
    if (e === undefined) {
      return
    }
    return await e.cancel(sessionId, reason)
  }

  async approve(sessionId: string, requestId: string, decision: ApprovalDecision): Promise<void> {
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const meta = AgentSessionStore.read(filesDir, sessionId)
    if (meta === null) {
      return
    }
    const e = this.engines.get(meta.engine)
    if (e === undefined) {
      return
    }
    return await e.approve(sessionId, requestId, decision)
  }

  subscribe(sessionId: string, listener: AgentEventListener): Unsubscribe {
    const filesDir = AppStorage.get<string>('ut.filesDir') ?? ''
    const meta = AgentSessionStore.read(filesDir, sessionId)
    // 包装 listener：感知引擎不可达（回落编排依据）
    const engineType: AgentEngineType = meta !== null ? meta.engine : 'local'
    const inner: AgentEventListener = (e: AgentEvent): void => {
      if (e.kind === 'error' && e.errCode === AGENT_ENGINE_UNAVAILABLE && engineType === 'hmh') {
        this.hmhAvailable = false
        this.fallbackNote = '当前引擎: 本地辅助（HMH 不可达）'
      }
      listener(e)
    }
    const e = this.engines.get(engineType)
    if (e === undefined) {
      return (): void => {
      }
    }
    return e.subscribe(sessionId, inner)
  }
}