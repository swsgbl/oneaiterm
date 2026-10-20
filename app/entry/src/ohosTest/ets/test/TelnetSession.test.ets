/**
 * LEG-2 Telnet 会话单测(ArkTS/hypium)。
 * 靶: SessionSlot.kind='telnet' 路由(bindTelnetSession 档案过滤/幂等语义的
 * 纯查询面) + AgentPanelLogic 引擎/prompt 守卫在 telnet 上下文的组合。
 * 说明: WorkbenchVm/Socket 为设备态(PTY/网络),单测只覆盖纯逻辑;
 *  socket 链路(旁路投递/事件路由)由 VM 自测(真机)覆盖。
 */
import { describe, it, expect } from '@ohos/hypium';
import { engineOfKey, promptGuard, wantPromptValid } from '../../../main/ets/workbench/agent/AgentPanelLogic';
import { SessionSlot, slotKindValid } from '../../../main/ets/workbench/model/TabState';

export default function telnetSessionTest() {
  describe('TelnetSession', () => {
    it('slot_kind_supports_telnet', 0, () => {
      // kind 白名单扩 'telnet'(+LEG-2);旧 kind 零回归
      expect(slotKindValid('telnet')).assertTrue()
      expect(slotKindValid('ssh')).assertTrue()
      expect(slotKindValid('local')).assertTrue()
      expect(slotKindValid('')).assertFalse()
      expect(slotKindValid('rdp')).assertFalse()
    })

    it('telnet_slot_title_and_connKey', 0, () => {
      const s = new SessionSlot()
      s.kind = 'telnet'
      s.connKey = 'tel-1'
      s.title = 'telnet 墙内跳板'
      expect(s.kind).assertEqual('telnet')
      expect(s.connKey).assertEqual('tel-1')
      expect(s.title).assertEqual('telnet 墙内跳板')
    })

    it('prompt_guard_blocks_empty_in_telnet_context', 0, () => {
      expect(promptGuard('  telnet 会话里问 AI  ')).assertEqual('telnet 会话里问 AI')
      expect(promptGuard('\n\t ')).assertEqual('')
    })

    it('engine_gate_keeps_default_hmh', 0, () => {
      expect(engineOfKey('local')).assertEqual('local')
      expect(engineOfKey('')).assertEqual('hmh')
      expect(wantPromptValid('hi')).assertTrue()
    })
  })
}
