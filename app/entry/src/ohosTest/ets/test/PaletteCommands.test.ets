/**
 * tty7 命令面板注册表单元测试（任务 tty7-M1d，ArkTS/hypium）。
 *
 * PaletteCommands 为纯函数注册表，WorkbenchVm 为 @Observed 纯状态容器，
 * 均可无 UI 直接验证（沿用 WorkbenchVm.test 的真实 import 范式）。
 *
 * 覆盖（对应 M1d 验收点）：
 *   1. 注册表非空且 key 唯一
 *   2. split.h / split.v：panes 3 且树含对应方向 SplitNode
 *   3. pane.close 空守卫：空模型 run 无异常且 panes 不变（rev 亦不变）
 *   4. vm.togglePalette 翻转
 *   5. panel.agent → toggleRightPanel 翻转
 *   6. theme.toggle 切换 AppStorage（测试后切回 dark）
 */
import { describe, it, expect } from '@ohos/hypium';
import { paletteCmds, PaletteCmd } from '../../../main/ets/tty7/shell/PaletteCommands';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';
import { SplitNode } from '../../../main/ets/tty7/layout/LayoutTree';

/** 按 key 取命令（找不到返回 null，由调用方断言）。 */
function cmdByKey(key: string): PaletteCmd | null {
  const cmds = paletteCmds()
  for (const c of cmds) {
    if (c.key === key) {
      return c
    }
  }
  return null
}

export default function paletteCommandsTest() {
  describe('tty7PaletteCommands', () => {
    // ===== 1. 注册表完整性 =====
    it('registry_nonempty_with_unique_keys', 0, () => {
      const cmds = paletteCmds()
      expect(cmds.length > 0).assertTrue()
      const seen = new Set<string>()
      for (const c of cmds) {
        expect(seen.has(c.key)).assertFalse()
        seen.add(c.key)
        expect(c.label.length > 0).assertTrue()
      }
    })

    // ===== 2. split.h / split.v =====
    it('split_h_yields_three_panes_and_h_split_node', 0, () => {
      const vm = new WorkbenchVm() // 基线 p1|h|p2,焦点 p1
      const cmd = cmdByKey('split.h')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.panes.join(',')).assertEqual('p1,p3,p2')
      const left = (vm.layout.root as SplitNode).children[0]
      expect(left instanceof SplitNode).assertTrue()
      expect((left as SplitNode).dir).assertEqual('h')
    })

    it('split_v_yields_three_panes_and_v_split_node', 0, () => {
      const vm = new WorkbenchVm()
      const cmd = cmdByKey('split.v')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.panes.join(',')).assertEqual('p1,p3,p2')
      const left = (vm.layout.root as SplitNode).children[0]
      expect(left instanceof SplitNode).assertTrue()
      expect((left as SplitNode).dir).assertEqual('v')
    })

    // ===== 3. pane.close 空守卫 =====
    it('close_cmd_guards_empty_model', 0, () => {
      const vm = new WorkbenchVm()
      vm.closePane('p1')
      vm.closePane('p2')
      expect(vm.panes.length).assertEqual(0)
      expect(vm.focusedPane).assertEqual('')
      const revBefore = vm.rev
      const cmd = cmdByKey('pane.close')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm) // 守卫:focusedPane==='' 不执行,无异常
      expect(vm.panes.length).assertEqual(0)
      expect(vm.rev).assertEqual(revBefore) // 未触发 syncFromLayout
    })

    // ===== 4. vm.togglePalette 翻转 =====
    it('toggle_palette_flips_state', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.paletteOpen).assertFalse()
      vm.togglePalette()
      expect(vm.paletteOpen).assertTrue()
      vm.togglePalette()
      expect(vm.paletteOpen).assertFalse()
    })

    // ===== 5. panel.agent → toggleRightPanel 翻转 =====
    it('agent_panel_cmd_toggles_right_panel', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.rightPanelOpen).assertFalse()
      const cmd = cmdByKey('panel.agent')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.rightPanelOpen).assertTrue()
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.rightPanelOpen).assertFalse()
    })

    // ===== 5b. panel.git (+tty7-M7a): 开抽屉 + 落 Git 页 =====
    it('git_panel_cmd_opens_drawer_on_git_tab', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.rightTab).assertEqual('agent')
      const cmd = cmdByKey('panel.git')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.rightPanelOpen).assertTrue()
      expect(vm.rightTab).assertEqual('git')
      // 已开时再点:面板保持开,页签仍 git(不翻关)
      ;(cmd as PaletteCmd).run(vm)
      expect(vm.rightPanelOpen).assertTrue()
      expect(vm.rightTab).assertEqual('git')
    })

    // ===== 6. theme.toggle 切换 AppStorage =====
    it('theme_cmd_toggles_appstorage_theme', 0, () => {
      AppStorage.setOrCreate('ut.theme', 'dark')
      const cmd = cmdByKey('theme.toggle')
      expect(cmd !== null).assertTrue()
      ;(cmd as PaletteCmd).run(vm0())
      expect(AppStorage.get<string>('ut.theme')).assertEqual('light')
      ;(cmd as PaletteCmd).run(vm0())
      expect(AppStorage.get<string>('ut.theme')).assertEqual('dark')
      // 复位:不影响后续套件的 AppStorage 初值
      AppStorage.setOrCreate('ut.theme', 'dark')
    })
  })
}

/** theme 命令的 run 不读 vm,给个最小实例即可。 */
function vm0(): WorkbenchVm {
  return new WorkbenchVm()
}
