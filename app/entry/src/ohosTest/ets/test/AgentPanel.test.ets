/**
 * tty7-LEG-2 Agent 面板纯逻辑单测(ArkTS/hypium)。
 * 靶: AgentPanelLogic 导出的 engineOfKey/engineLabel/promptGuard/wantPromptValid。
 */
import { describe, it, expect } from '@ohos/hypium';
import { engineOfKey, engineLabel, promptGuard, wantPromptValid } from '../../../main/ets/tty7/agent/AgentPanelLogic';

export default function agentPanelTest() {
  describe('tty7AgentPanel', () => {
    it('engine_key_whitelist_and_default', 0, () => {
      expect(engineOfKey('local')).assertEqual('local')
      expect(engineOfKey('acp')).assertEqual('acp')
      expect(engineOfKey('hmh')).assertEqual('hmh')
      expect(engineOfKey('')).assertEqual('hmh')
      expect(engineOfKey('bogus')).assertEqual('hmh')
    })

    it('engine_label_mapping', 0, () => {
      expect(engineLabel('local')).assertEqual('本地')
      expect(engineLabel('acp')).assertEqual('ACP')
      expect(engineLabel('hmh')).assertEqual('HMH')
      expect(engineLabel('xx')).assertEqual('HMH') // 非法回默认
    })

    it('prompt_guard_trims_and_blocks_empty', 0, () => {
      expect(promptGuard('  列出目录  ')).assertEqual('列出目录')
      expect(promptGuard('date')).assertEqual('date')
      expect(promptGuard('   ')).assertEqual('')
      expect(promptGuard('')).assertEqual('')
    })

    it('want_prompt_valid_gate', 0, () => {
      expect(wantPromptValid(' run ls ')).assertTrue()
      expect(wantPromptValid('')).assertFalse()
      expect(wantPromptValid('  \t ')).assertFalse()
    })
  })
}
