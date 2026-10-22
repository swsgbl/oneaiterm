/**
 * R4g 屏幕软键盘单测(ArkTS/hypium)。
 * 靶: skSeqOf(控制键序列)/skLetterRows/skDigitRow/skSymbolEdges(键表完整性)
 *     + WorkbenchVm.sendToFocusedPane 路由(无焦点拒/本地桥通/无会话拒)。
 */
import { describe, it, expect } from '@ohos/hypium';
import { skSeqOf, skLetterRows, skDigitRow, skSymbolEdges } from '../../../main/ets/workbench/shell/SoftKeyboard';
import { WorkbenchVm } from '../../../main/ets/workbench/viewmodel/WorkbenchVm';
import { TtydSession } from '../../../main/ets/workbench/term/TtydSession';

export default function softKeyboardTest() {
  describe('SoftKeyboard', () => {
    it('control_specs_map_to_sequences', 0, () => {
      expect(skSeqOf('⌫')).assertEqual('\x7f')
      expect(skSeqOf('Enter')).assertEqual('\r')
      expect(skSeqOf('Tab')).assertEqual('\t')
      expect(skSeqOf('Esc')).assertEqual('\x1b')
      expect(skSeqOf('←')).assertEqual('\x1b[D')
      expect(skSeqOf('→')).assertEqual('\x1b[C')
      expect(skSeqOf('↑')).assertEqual('\x1b[A')
      expect(skSeqOf('↓')).assertEqual('\x1b[B')
      expect(skSeqOf('Ctrl-C')).assertEqual('\x03')
      expect(skSeqOf('Ctrl-D')).assertEqual('\x04')
      expect(skSeqOf('Ctrl-L')).assertEqual('\x0c')
      expect(skSeqOf('␣')).assertEqual(' ')
    })

    it('printable_labels_pass_through', 0, () => {
      expect(skSeqOf('a')).assertEqual('a')
      expect(skSeqOf('Z')).assertEqual('Z')
      expect(skSeqOf('1')).assertEqual('1')
      expect(skSeqOf('-')).assertEqual('-')
      expect(skSeqOf('|')).assertEqual('|')
    })

    it('letter_rows_cover_26_letters_no_dup', 0, () => {
      const rows = skLetterRows()
      expect(rows.length).assertEqual(3)
      const seen: string[] = []
      for (const row of rows) {
        for (const k of row) {
          expect(k.length).assertEqual(1)
          expect(seen.indexOf(k) < 0).assertTrue()
          expect(k >= 'a' && k <= 'z').assertTrue()
          seen.push(k)
        }
      }
      expect(seen.length).assertEqual(26)
    })

    it('digit_and_symbol_tables_nonempty', 0, () => {
      const d = skDigitRow()
      expect(d.length >= 10).assertTrue()
      expect(d[0]).assertEqual('1')
      const e = skSymbolEdges()
      expect(e.length).assertEqual(3)
      for (const row of e) {
        expect(row.length > 0).assertTrue()
      }
    })

    it('vm_route_no_focus_or_empty_rejected', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.sendToFocusedPane('')).assertFalse() // 空文本
      // 关空全部 pane → 无焦点
      const panes = vm.panes.slice()
      for (const p of panes) {
        vm.closePane(p)
      }
      expect(vm.panes.length).assertEqual(0)
      expect(vm.sendToFocusedPane('d')).assertFalse()
    })

    it('vm_route_local_web_via_bridge', 0, () => {
      const vm = new WorkbenchVm()
      vm.focusPane('p1')
      // 桥活语义:markLive + 假 sender 捕获注入脚本
      let captured = ''
      TtydSession.markLive('p1', true)
      TtydSession.setSender('p1', (js: string): void => {
        captured = js
      })
      expect(vm.bindLocalSessionFor('p1')).assertTrue()
      expect(vm.sessionKindOf('p1')).assertEqual('local')
      expect(vm.sendToFocusedPane('d')).assertTrue()
      expect(captured.indexOf('__oatrd.write(') >= 0).assertTrue()
      TtydSession.detach('p1')
    })
  })
}
