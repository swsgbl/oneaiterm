/**
 * WorkbenchVm 布局集成单元测试（任务 M1c，ArkTS/hypium）。
 *
 * Vm 是 @Observed 状态容器，其布局方法全部是 LayoutOps 纯变换的薄封装，
 * 可在无 UI 环境直接实例化验证（沿用 LayoutTree.test 的真实 import 范式）。
 *
 * 覆盖（对应 M1c 验收点）：
 *   1. 初始基线：单 pane（p1）——R4r 默认单屏（用户指令）;多 pane 场景经 vmBase() 自建
 *   2. newPane('h'/'v')：对焦点叶 split，新 id=p{最大+1}
 *   3. closePane：父折叠 + 焦点迁移；全关 → 空模型；空模型上 newPane 重建 p1
 *   4. focusPane：切换与非法 id 拒绝
 *   5. zoomToggle：焦点叶 zoom/取消
 *   6. resizeSplit：clamp 0.1~0.9 + 派生态同步
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkbenchVm, firstLocalSlotPaneId } from '../../../main/ets/workbench/viewmodel/WorkbenchVm';
import { PaneLeaf, SplitNode } from '../../../main/ets/workbench/layout/LayoutTree';
import { SessionSlot } from '../../../main/ets/workbench/model/TabState';

/** 双 pane 基线(R4r 起构造器默认单屏;多 pane 用例经本函数自建 p1|h|p2)。 */
function vmBase(): WorkbenchVm {
  const vm = new WorkbenchVm() // 单叶 p1
  vm.newPane('h') // → p1|h|p2(焦点 p1)
  vm.focusPane('p1')
  return vm
}

/** 构造 2x2：p1|p2 两列，各列上下再分。 */
function vm2x2(): WorkbenchVm {
  const vm = vmBase() // 基线 p1|h|p2
  vm.focusPane('p1')
  vm.newPane('v') // p1 上/下 → p3
  vm.focusPane('p2')
  vm.newPane('v') // p2 上/下 → p4
  return vm
}

export default function workbenchVmTest() {
  describe('workbenchVm', () => {
    // ===== 1. 初始基线 =====
    it('initial_baseline_single_pane', 0, () => {
      // R4r:默认单屏(用户指令「初始就是一个屏」);原双 pane 开发期基线退役
      const vm = new WorkbenchVm()
      expect(vm.panes.join(',')).assertEqual('p1')
      expect(vm.focusedPane).assertEqual('p1')
      expect(vm.layout.zoomedPaneId).assertEqual('')
      expect(vm.statusText).assertEqual('panes 1 · focus p1')
      expect(vm.layout.root instanceof PaneLeaf).assertTrue()
    })

    // ===== 2. newPane =====
    it('newpane_splits_focused_leaf_with_next_id', 0, () => {
      const vm = vmBase()
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
      const vm = vmBase()
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
      const vm = vmBase()
      vm.focusPane('p2')
      vm.closePane('p2')
      // p2 被删后整树折叠为单叶 p1,焦点迁回 p1
      expect(vm.panes.join(',')).assertEqual('p1')
      expect(vm.layout.root instanceof PaneLeaf).assertTrue()
      expect(vm.focusedPane).assertEqual('p1')
      expect(vm.statusText).assertEqual('panes 1 · focus p1')
    })

    it('closepane_zoomed_clears_zoom', 0, () => {
      const vm = vmBase()
      vm.focusPane('p2')
      vm.zoomToggle()
      expect(vm.layout.zoomedPaneId).assertEqual('p2')
      vm.closePane('p2')
      expect(vm.layout.zoomedPaneId).assertEqual('')
    })

    // ===== 4. focusPane =====
    it('focuspane_switches_and_rejects_unknown', 0, () => {
      const vm = vmBase()
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
      const vm = vmBase()
      const spId = (vm.layout.root as SplitNode).id
      vm.resizeSplit(spId, 1.5)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.9)
      vm.resizeSplit(spId, 0)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.1)
      vm.resizeSplit(spId, 0.4)
      expect((vm.layout.root as SplitNode).ratio).assertEqual(0.4)
      expect(vm.panes.join(',')).assertEqual('p1,p2')
    })

    // ===== 7. FR: firstLocalSlotPaneId(恢复复活取槽纯函数) =====
    it('firstlocalslot_empty_when_no_sessions', 0, () => {
      expect(firstLocalSlotPaneId([])).assertEqual('')
    })

    it('firstlocalslot_picks_first_local_skipping_remote', 0, () => {
      const remote = new SessionSlot()
      remote.paneId = 'p1'
      remote.kind = 'ssh'
      const local2 = new SessionSlot()
      local2.paneId = 'p3'
      local2.kind = 'local'
      const local3 = new SessionSlot()
      local3.paneId = 'p4'
      local3.kind = 'local'
      expect(firstLocalSlotPaneId([remote, local2, local3])).assertEqual('p3')
    })

    it('fr_baseline_ctor_stays_pure_no_pty', 0, () => {
      // 构造纯净性:基线构造不启 PTY(会话绑定在 Index UI 层,单测环境不触发)
      const vm = new WorkbenchVm()
      expect(vm.restoredFromArchive).assertFalse()
      expect(vm.shellVisibleTick).assertEqual(0)
      expect(vm.sessionOf('p1')).assertNull()
    })
  })
}
