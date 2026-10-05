/**
 * AgentSession 状态机校验单元测试（升级 Phase 1 / 任务 2.2，ArkTS/hypium）。
 *
 * 纯函数复制 replicates AgentSessionStore.read() 的字段校验逻辑 +
 * AgentAdapter.resumeSession 的引擎错配拒绝逻辑（dependency-free）。
 * 覆盖：state 四态合法/非法、engine 三类合法/非法、引擎错配拒绝（spec 6.1.2/6.1.3）。
 */
import { describe, it, expect } from '@ohos/hypium';

type SessionState = 'active' | 'cancelled' | 'finished' | 'aborted'
type EngineType = 'hmh' | 'acp' | 'local'

/** replicates AgentSessionStore.read() 状态校验分支。 */
function parseState(raw: string): SessionState | null {
  if (raw === 'active' || raw === 'cancelled' || raw === 'finished' || raw === 'aborted') {
    return raw as SessionState
  }
  return null
}

/** replicates AgentSessionStore.read() 引擎校验分支。 */
function parseEngine(raw: string): EngineType | null {
  if (raw === 'hmh' || raw === 'acp' || raw === 'local') {
    return raw as EngineType
  }
  return null
}

/** replicates AgentAdapter.resumeSession 引擎错配拒绝（本地引擎恢复前置）。 */
function resumeAllowed(metaEngine: string, targetEngine: string): boolean {
  if (metaEngine !== targetEngine) {
    return false
  }
  return true
}

/** replicates AgentSession 状态机流转合法性。 */
function transitionAllowed(from: SessionState, action: 'prompt' | 'cancel' | 'done' | 'abort' | 'resume'): boolean {
  if (from === 'active') {
    return action === 'cancel' || action === 'done' || action === 'abort' || action === 'prompt'
  }
  if (from === 'aborted') {
    return action === 'resume'
  }
  return false
}

export default function agentSessionStateTest() {
  describe('agentSessionStateMachine', () => {
    it('state_four_valid_values_accepted', 0, () => {
      expect(parseState('active') !== null).assertTrue();
      expect(parseState('cancelled') !== null).assertTrue();
      expect(parseState('finished') !== null).assertTrue();
      expect(parseState('aborted') !== null).assertTrue();
    });

    it('state_invalid_value_rejected', 0, () => {
      expect(parseState('running') === null).assertTrue();
      expect(parseState('') === null).assertTrue();
      expect(parseState('Active') === null).assertTrue();
    });

    it('engine_three_valid_values_accepted', 0, () => {
      expect(parseEngine('hmh') !== null).assertTrue();
      expect(parseEngine('acp') !== null).assertTrue();
      expect(parseEngine('local') !== null).assertTrue();
    });

    it('engine_invalid_value_rejected', 0, () => {
      expect(parseEngine('openai') === null).assertTrue();
      expect(parseEngine('') === null).assertTrue();
    });

    it('engine_mismatch_rejects_resume', 0, () => {
      expect(resumeAllowed('hmh', 'local') === false).assertTrue();
      expect(resumeAllowed('acp', 'local') === false).assertTrue();
    });

    it('engine_match_allows_resume', 0, () => {
      expect(resumeAllowed('local', 'local')).assertTrue();
      expect(resumeAllowed('hmh', 'hmh')).assertTrue();
    });

    it('active_session_transitions', 0, () => {
      expect(transitionAllowed('active', 'prompt')).assertTrue();
      expect(transitionAllowed('active', 'cancel')).assertTrue();
      expect(transitionAllowed('active', 'done')).assertTrue();
      expect(transitionAllowed('active', 'abort')).assertTrue();
    });

    it('aborted_session_only_resume', 0, () => {
      expect(transitionAllowed('aborted', 'resume')).assertTrue();
      expect(transitionAllowed('aborted', 'cancel') === false).assertTrue();
      expect(transitionAllowed('aborted', 'done') === false).assertTrue();
    });

    it('terminal_states_no_transition', 0, () => {
      expect(transitionAllowed('cancelled', 'resume') === false).assertTrue();
      expect(transitionAllowed('finished', 'prompt') === false).assertTrue();
    });
  });
}