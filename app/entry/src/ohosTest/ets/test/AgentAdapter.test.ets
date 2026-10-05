/**
 * AgentAdapter 回落编排单元测试（M5，ArkTS/hypium）。
 *
 * 纯函数复制 replicates AgentAdapter 中回落编排的可测试逻辑（dependency-free）。
 * 覆盖：
 *   1. targetEngine：引擎不存在→null、HMH 不可用→null、正常→引擎
 *   2. engineStatus：未接入/ unavailable / ready
 *   3. createSession 回落：非本地引擎不可用→fallbackLocal
 *   4. resumeSession 回落：HMH 不可达→回落 local
 *   5. prompt 错误码：SESSION_NOT_FOUND / ENGINE_UNAVAILABLE / ENGINE_MISMATCH
 *   6. subscribe 包装：error+AGENT_ENGINE_UNAVAILABLE→hmhAvailable=false
 */
import { describe, it, expect } from '@ohos/hypium';

type AgentEngineType = 'hmh' | 'acp' | 'local'

const AGENT_SESSION_NOT_FOUND: string = 'AGENT_SESSION_NOT_FOUND'
const AGENT_ENGINE_MISMATCH: string = 'AGENT_ENGINE_MISMATCH'
const AGENT_ENGINE_UNAVAILABLE: string = 'AGENT_ENGINE_UNAVAILABLE'

class TEngineState {
  hmhAvailable: boolean = true
  engines: Map<AgentEngineType, boolean> = new Map()
  fallbackNote: string = ''
}

function targetEngine(st: TEngineState, engine: AgentEngineType): boolean {
  const exists = st.engines.get(engine)
  if (exists === undefined) {
    return false
  }
  if (engine === 'hmh' && !st.hmhAvailable) {
    return false
  }
  return true
}

function engineStatus(st: TEngineState, type: AgentEngineType): string {
  const exists = st.engines.get(type)
  if (exists === undefined) {
    return type === 'local' ? 'ready' : '未接入'
  }
  if (type === 'hmh' && !st.hmhAvailable) {
    return 'unavailable'
  }
  return 'ready'
}

function createSessionFallback(st: TEngineState, engine: AgentEngineType): string {
  if (engine === 'local') {
    return 'local'
  }
  const available = targetEngine(st, engine)
  if (!available) {
    st.fallbackNote = '当前引擎: 本地辅助（' + engine + ' 引擎不可用）'
    return 'local_fallback'
  }
  st.fallbackNote = ''
  return engine
}

function resumeSessionFallback(st: TEngineState, metaEngine: AgentEngineType): string {
  if (metaEngine === 'hmh' && !st.hmhAvailable) {
    st.fallbackNote = '当前引擎: 本地辅助（HMH 不可达）'
    return 'local_fallback'
  }
  const exists = st.engines.get(metaEngine)
  if (exists === undefined) {
    return 'ENGINE_MISMATCH'
  }
  return metaEngine
}

function promptErrCode(st: TEngineState, metaEngine: AgentEngineType, sessionExists: boolean): string {
  if (!sessionExists) {
    return AGENT_SESSION_NOT_FOUND
  }
  if (metaEngine === 'hmh' && !st.hmhAvailable) {
    return AGENT_ENGINE_UNAVAILABLE
  }
  const exists = st.engines.get(metaEngine)
  if (exists === undefined) {
    return AGENT_ENGINE_MISMATCH
  }
  return ''
}

function subscribeWrapper(st: TEngineState, engineType: AgentEngineType, eventKind: string, errCode: string): void {
  if (eventKind === 'error' && errCode === AGENT_ENGINE_UNAVAILABLE && engineType === 'hmh') {
    st.hmhAvailable = false
    st.fallbackNote = '当前引擎: 本地辅助（HMH 不可达）'
  }
}

export default function agentAdapterTest() {
  describe('agentAdapterFallback', () => {
    // ===== targetEngine =====
    it('target_engine_unregistered_returns_null', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(!targetEngine(st, 'hmh')).assertTrue()
      expect(!targetEngine(st, 'acp')).assertTrue()
    })

    it('target_engine_hmh_unavailable_returns_null', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = false
      expect(!targetEngine(st, 'hmh')).assertTrue()
    })

    it('target_engine_hmh_available_returns_engine', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      expect(targetEngine(st, 'hmh')).assertTrue()
    })

    it('target_engine_local_always_available', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(targetEngine(st, 'local')).assertTrue()
    })

    it('target_engine_acp_available', 0, () => {
      const st = new TEngineState()
      st.engines.set('acp', true)
      expect(targetEngine(st, 'acp')).assertTrue()
    })

    // ===== engineStatus =====
    it('engine_status_unregistered_non_local', 0, () => {
      const st = new TEngineState()
      expect(engineStatus(st, 'hmh') === '未接入').assertTrue()
      expect(engineStatus(st, 'acp') === '未接入').assertTrue()
    })

    it('engine_status_unregistered_local_is_ready', 0, () => {
      const st = new TEngineState()
      expect(engineStatus(st, 'local') === 'ready').assertTrue()
    })

    it('engine_status_hmh_unavailable', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = false
      expect(engineStatus(st, 'hmh') === 'unavailable').assertTrue()
    })

    it('engine_status_hmh_ready', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      expect(engineStatus(st, 'hmh') === 'ready').assertTrue()
    })

    // ===== createSession 回落 =====
    it('create_session_local_uses_local', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(createSessionFallback(st, 'local') === 'local').assertTrue()
      expect(st.fallbackNote === '').assertTrue()
    })

    it('create_session_hmh_available_uses_hmh', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.engines.set('local', true)
      st.hmhAvailable = true
      expect(createSessionFallback(st, 'hmh') === 'hmh').assertTrue()
      expect(st.fallbackNote === '').assertTrue()
    })

    it('create_session_hmh_unavailable_falls_back', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.engines.set('local', true)
      st.hmhAvailable = false
      expect(createSessionFallback(st, 'hmh') === 'local_fallback').assertTrue()
      expect(st.fallbackNote !== '').assertTrue()
    })

    it('create_session_acp_unregistered_falls_back', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(createSessionFallback(st, 'acp') === 'local_fallback').assertTrue()
      expect(st.fallbackNote !== '').assertTrue()
    })

    // ===== resumeSession 回落 =====
    it('resume_session_hmh_unavailable_falls_back', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.engines.set('local', true)
      st.hmhAvailable = false
      expect(resumeSessionFallback(st, 'hmh') === 'local_fallback').assertTrue()
      expect(st.fallbackNote !== '').assertTrue()
    })

    it('resume_session_engine_mismatch', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(resumeSessionFallback(st, 'acp') === 'ENGINE_MISMATCH').assertTrue()
    })

    it('resume_session_hmh_available_no_fallback', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      expect(resumeSessionFallback(st, 'hmh') === 'hmh').assertTrue()
    })

    it('resume_session_local_no_fallback', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(resumeSessionFallback(st, 'local') === 'local').assertTrue()
    })

    // ===== prompt 错误码 =====
    it('prompt_session_not_found', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(promptErrCode(st, 'local', false) === AGENT_SESSION_NOT_FOUND).assertTrue()
    })

    it('prompt_hmh_unavailable', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = false
      expect(promptErrCode(st, 'hmh', true) === AGENT_ENGINE_UNAVAILABLE).assertTrue()
    })

    it('prompt_engine_mismatch', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(promptErrCode(st, 'acp', true) === AGENT_ENGINE_MISMATCH).assertTrue()
    })

    it('prompt_normal_no_error', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      expect(promptErrCode(st, 'local', true) === '').assertTrue()
    })

    // ===== subscribe 包装：感知引擎不可达 =====
    it('subscribe_error_unavailable_sets_hmh_false', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      subscribeWrapper(st, 'hmh', 'error', AGENT_ENGINE_UNAVAILABLE)
      expect(!st.hmhAvailable).assertTrue()
      expect(st.fallbackNote !== '').assertTrue()
    })

    it('subscribe_non_error_event_no_change', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      subscribeWrapper(st, 'hmh', 'message', '')
      expect(st.hmhAvailable).assertTrue()
    })

    it('subscribe_error_other_code_no_change', 0, () => {
      const st = new TEngineState()
      st.engines.set('hmh', true)
      st.hmhAvailable = true
      subscribeWrapper(st, 'hmh', 'error', 'SOME_OTHER_ERROR')
      expect(st.hmhAvailable).assertTrue()
    })

    it('subscribe_error_unavailable_local_no_change', 0, () => {
      const st = new TEngineState()
      st.engines.set('local', true)
      st.hmhAvailable = true
      subscribeWrapper(st, 'local', 'error', AGENT_ENGINE_UNAVAILABLE)
      expect(st.hmhAvailable).assertTrue()
    })
  })
}