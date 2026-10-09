/**
 * tty7 WorkbenchVm 布局集成单元测试（任务 tty7-M1c，ArkTS/hypium）。
 *
 * Vm 是 @Observed 状态容器，其布局方法全部是 LayoutOps 纯变换的薄封装，
 * 可在无 UI 环境直接实例化验证（沿用 LayoutTree.test 的真实 import 范式）。
 *
 * 覆盖（对应 M1c 验收点）：
 *   1. 初始基线：双 pane（p1|p2 左右分），panes/focusedPane/statusText 同步
 *   2. newPane('h'/'v')：对焦点叶 split，新 id=p{最大+1}
 *   3. closePane：父折叠 + 焦点迁移；全关 → 空模型；空模型上 newPane 重建 p1
 *   4. focusPane：切换与非法 id 拒绝
 *   5. zoomToggle：焦点叶 zoom/取消
 *   6. resizeSplit：clamp 0.1~0.9 + 派生态同步
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';
import { PaneLeaf, SplitNode } from '../../../main/ets/tty7/layout/LayoutTree';

/** 构造 2x2：p1|p2 两列，各列上下再分。 */
function vm2x2(): WorkbenchVm {
  const vm = new WorkbenchVm() // 基线 p1|h|p2
  vm.focusPane('p1')
  vm.newPane('v') // p1 上/下 → p3
  vm.focusPane('p2')
  vm.newPane('v') // p2 上/下 → p4
  return vm
}

export default function workbenchVmTest() {
  describe('tty7WorkbenchVm', () => {
    // ===== 1. 初始基线 =====
    it('initial_baseline_two_panes', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.panes.join(',')).assertEqual('p1,p2')
      expect(vm.focusedPane).assertEqual('p1')
      expect(vm.layout.zoomedPaneId).assertEqual('')
      expect(vm.statusText).assertEqual('panes 2 · focus p1')
      const sp = vm.layout.root as SplitNode
      expect(sp.dir).assertEqual('h')
      expect(sp.children.length).assertEqual(2)
    })

    // ===== 2. newPane =====
    it('newpane_splits_focused_leaf_with_next_id', 0, () => {
      const vm = new WorkbenchVm()
      vm.newPane('v')
      expect(vm.panes.join(',')).assertEqual('p1,p3,p2')
      expect(vm.focusedPane).assertEqual('p1')
      expect(vm.statusText).assertEqual('panes 3 · focus p1')
      // 新叶 p3 落在焦点叶 p1 的下位
      const left = (vm.layout.root as SplitNode).children[0] as SplitNode
      expect(left.dir).assertEqual('v')
      expect(((left.children[1]) as PaneLeaf).paneId).assertEqual('p3')
      // 再分:焦点仍在 p1,新 id 递增 p4
      vm.newPane('h')
      expect(vm.panes.join(',')).assertEqual('p1,p4,p3,p2')
    })

    it('newpane_on_empty_layout_rebuilds_p1', 0, () => {
      const vm = new WorkbenchVm()
      vm.closePane('p1')
      vm.closePane('p2')
      expect(vm.panes.join(',')).assertEqual('')
      expect(vm.statusText).assertEqual('panes 0 · focus -')
      vm.newPane('h')
      expect(vm.panes.join(',')).assertEqual('p1')
      expect(vm.focusedPane).assertEqual('p1')
    })

    // ===== 3. closePane =====
    it('closepane_collapses_parent_and_moves_focus', 0, () => {
      const vm = new WorkbenchVm()
      vm.focusPane('p2')
      vm.closePane('p2')
      // p2 被删后整树折叠为单叶 p1,焦点迁回 p1
      expect(vm.panes.join(',')).assertEqual('p1')
      expect(vm.layout.root instanceof PaneLeaf).assertTrue()
      expect(vm.focusedPane).assertEqual('p1')
      expect(vm.statusText).assertEqual('panes 1 · focus p1')
    })

    it('closepane_zoomed_clears_zoom', 0, () => {
      const vm = new WorkbenchVm()
      vm.focusPane('p2')
      vm.zoomToggle()
      expect(vm.layout.zoomedPaneId).assertEqual('p2')
      vm.closePane('p2')
      expect(vm.layout.zoomedPaneId).assertEqual('')
    })

    // ===== 4. focusPane =====
    it('focuspane_switches_and_rejects_unknown', 0, () => {
      const vm = new WorkbenchVm()
      vm.focusPane('p2')
      expect(vm.focusedPane).assertEqual('p2')
      vm.focusPane('Z')
      expect(vm.focusedPane).assertEqual('p2')
    })

    // ===== 5. zoomToggle =====
    it('zoomtoggle_on_focused_pane', 0, () => {
      const vm = new WorkbenchVm()
      vm.zoomToggle()
      expect(vm.layout.zoomedPaneId).assertEqual('p1')
      vm.zoomToggle()
      expect(vm.layout.zoomedPaneId).assertEqual('')
    })

    // ===== 6. resizeSplit =====
    it('resizesplit_clamps_and_syncs_derived_state', 0, () => {
      const vm = new WorkbenchVm()
      const spId = (vm.layout.root as SplitNode).id
      vm.resizeSplit(spId, 1.5)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.9)
      vm.resizeSplit(spId, 0)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.1)
      vm.resizeSplit(spId, 0.4)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.4)
      expect(vm.panes.join(',')).assertEqual('p1,p2')
    })
  })
}
