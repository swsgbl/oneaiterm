/**
 * tty7 WorkbenchStore 存档层单元测试(任务 tty7-M2a 建立,M2b 适配 v2 多工作区格式)。
 *
 * 纯序列化/反序列化用例直接验证 serializeWorkspaces/deserializeWorkspaces;Vm 用例不落盘
 * ——单测环境无 ability context,AppStorage 无 'ut.filesDir',WorkbenchVm 构造
 * 走恢复失败降级分支(双 pane 基线),persist() 静默不落盘。
 *
 * 覆盖(原 M2a 套件适配 v2 后语义不变):
 *   1. serialize→deserialize 往返一致(2 工作区:一棵 2x2 树 + 一棵单叶)
 *   2. 损坏 JSON(截断/非 JSON/缺字段/错 dir/children<2)→ null
 *   3. 空 workspaces 数组 → null
 *   4. ratio 越界 clamp 后恢复
 *   5. Vm 层:tab1 分屏后切 tab2 新建 pane,切回 tab1 布局不变(布局独立性)
 *   6. Vm 层:setActiveTab 派生态跟随(statusText 'panes N' 与该 tab 树一致)
 */
import { describe, it, expect } from '@ohos/hypium';
import { serializeWorkspaces, deserializeWorkspaces } from '../../../main/ets/tty7/store/WorkbenchStore';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';
import { TabState } from '../../../main/ets/tty7/model/TabState';
import { WorkspaceState } from '../../../main/ets/tty7/model/WorkspaceState';
import { PaneLeaf, SplitNode } from '../../../main/ets/tty7/layout/LayoutTree';

/** 构造 2x2 树:p1|p2 两列,各列上下再分(p3 挂 p1 下,p4 挂 p2 下)。 */
function tab2x2(): TabState {
  const vm = new WorkbenchVm() // 基线 p1|h|p2(恢复失败降级分支)
  vm.focusPane('p1')
  vm.newPane('v') // p1 上/下 → p3
  vm.focusPane('p2')
  vm.newPane('v') // p2 上/下 → p4
  const t = new TabState()
  t.tabId = 't9'
  t.title = 'vm-2x2'
  t.layout = vm.layout
  return t
}

/** 手工单叶 tab。 */
function tabSingle(): TabState {
  const t = new TabState()
  t.tabId = 't8'
  t.title = 'single'
  const leaf = new PaneLeaf()
  leaf.paneId = 'p7'
  leaf.sizeRatio = 1
  t.layout.root = leaf
  t.layout.focusedPaneId = 'p7'
  return t
}

/** 手工单工作区。 */
function wsOf(wsId: string, tabs: TabState[]): WorkspaceState {
  const ws = new WorkspaceState()
  ws.wsId = wsId
  ws.name = 'ws-' + wsId
  ws.glyph = '◈'
  ws.tabs = tabs
  ws.activeTab = 0
  return ws
}

export default function workbenchStoreTest() {
  describe('tty7WorkbenchStore', () => {
    // ===== 1. 往返一致 =====
    it('roundtrip_two_workspaces_2x2_and_single', 0, () => {
      const json = serializeWorkspaces([wsOf('w1', [tab2x2()]), wsOf('w2', [tabSingle()])], 1)
      const back = deserializeWorkspaces(json)
      expect(back !== null).assertTrue()
      const wss = back as WorkspaceState[]
      expect(wss.length).assertEqual(2)
      expect(wss[0].wsId).assertEqual('w1')
      expect(wss[1].wsId).assertEqual('w2')
      expect(wss[0].tabs.length).assertEqual(1)
      // ws0 tab0: 2x2 结构
      const root0 = wss[0].tabs[0].layout.root as SplitNode
      expect(root0 instanceof SplitNode).assertTrue()
      expect(root0.dir).assertEqual('h')
      expect(root0.children.length).assertEqual(2)
      const col0 = root0.children[0] as SplitNode
      const col1 = root0.children[1] as SplitNode
      expect(col0 instanceof SplitNode && col0.dir === 'v').assertTrue()
      expect(col1 instanceof SplitNode && col1.dir === 'v').assertTrue()
      expect((col0.children[0] as PaneLeaf).paneId).assertEqual('p1')
      expect((col0.children[1] as PaneLeaf).paneId).assertEqual('p3')
      expect((col1.children[0] as PaneLeaf).paneId).assertEqual('p2')
      expect((col1.children[1] as PaneLeaf).paneId).assertEqual('p4')
      // ws1 tab0: 单叶
      expect(wss[1].tabs[0].layout.root instanceof PaneLeaf).assertTrue()
      expect((wss[1].tabs[0].layout.root as PaneLeaf).paneId).assertEqual('p7')
      // 元数据
      expect(wss[0].tabs[0].tabId).assertEqual('t9')
      expect(wss[0].tabs[0].title).assertEqual('vm-2x2')
      expect(wss[1].tabs[0].tabId).assertEqual('t8')
    })

    // ===== 2. 损坏 JSON → null =====
    it('corrupt_json_returns_null', 0, () => {
      const good = serializeWorkspaces([wsOf('w1', [tab2x2()])], 0)
      // 截断
      expect(deserializeWorkspaces(good.substring(0, good.length - 5))).assertNull()
      // 非 JSON
      expect(deserializeWorkspaces('not-json-at-all')).assertNull()
      // 缺 workspaces 字段(合法 JSON)
      expect(deserializeWorkspaces('{"v":2,"activeWs":0}')).assertNull()
      // 错 dir(x)
      const badDir = good.replace('"dir":"h"', '"dir":"x"')
      expect(deserializeWorkspaces(badDir)).assertNull()
      // children<2(手写最小坏档:单子分割节点)
      const badChildren = '{"v":2,"activeWs":0,"workspaces":[{"wsId":"w1","name":"x","glyph":"◈","activeTab":0,"tabs":[{"tabId":"t1","title":"x","layout":{"root":{"t":"s","id":"sp1","dir":"h","ratio":0.5,"ch":[{"t":"l","id":"p1"}]},"focused":"p1","zoomed":""},"sessions":[]}]}]}'
      expect(deserializeWorkspaces(badChildren)).assertNull()
    })

    // ===== 3. 空 workspaces 数组 → null =====
    it('empty_workspaces_returns_null', 0, () => {
      expect(deserializeWorkspaces('{"v":2,"activeWs":0,"workspaces":[]}')).assertNull()
    })

    // ===== 4. ratio 越界 clamp =====
    it('ratio_clamped_on_restore', 0, () => {
      const over = '{"v":2,"activeWs":0,"workspaces":[{"wsId":"w1","name":"x","glyph":"◈","activeTab":0,"tabs":[{"tabId":"t1","title":"x","layout":{"root":{"t":"s","id":"sp1","dir":"h","ratio":1.7,"ch":[{"t":"l","id":"p1"},{"t":"l","id":"p2"}]},"focused":"p1","zoomed":""},"sessions":[]}]}]}'
      const backOver = deserializeWorkspaces(over)
      expect(backOver !== null).assertTrue()
      expect((backOver as WorkspaceState[])[0].tabs[0].layout.root instanceof SplitNode).assertTrue()
      expect(((backOver as WorkspaceState[])[0].tabs[0].layout.root as SplitNode).ratio).assertEqual(0.9)
      const under = over.replace('"ratio":1.7', '"ratio":0.01')
      const backUnder = deserializeWorkspaces(under)
      expect(backUnder !== null).assertTrue()
      expect(((backUnder as WorkspaceState[])[0].tabs[0].layout.root as SplitNode).ratio).assertEqual(0.1)
    })

    // ===== 5. Vm 层:布局独立性 =====
    it('vm_tab_layouts_are_independent', 0, () => {
      const vm = new WorkbenchVm() // 基线 p1|h|p2,activeTab=0
      vm.newTab() // tab2(空模型根叶)
      expect(vm.tabs.length).assertEqual(2)
      expect(vm.activeTab).assertEqual(1)
      expect(vm.panes.join(',')).assertEqual('') // 空模型无 pane
      vm.newPane('v') // tab2 首 pane p1(上下分无兄弟→single)
      expect(vm.panes.join(',')).assertEqual('p1')
      vm.setActiveTab(0) // 切回 tab1
      // tab1 布局原样:p1|h|p2,不受 tab2 的 p1 影响
      expect(vm.panes.join(',')).assertEqual('p1,p2')
      const root = vm.layout.root as SplitNode
      expect(root.dir).assertEqual('h')
      expect((root.children[0] as PaneLeaf).paneId).assertEqual('p1')
      expect((root.children[1] as PaneLeaf).paneId).assertEqual('p2')
    })

    // ===== 6. Vm 层:派生态跟随 =====
    it('vm_setactivetab_derived_state_follows', 0, () => {
      const vm = new WorkbenchVm() // tab1: p1|h|p2
      vm.newTab() // tab2
      vm.newPane('h') // tab2: single p1
      vm.setActiveTab(0)
      expect(vm.activeTab).assertEqual(0)
      expect(vm.statusText).assertEqual('panes 2 · focus p1')
      expect(vm.focusedPane).assertEqual('p1')
      vm.setActiveTab(1)
      expect(vm.activeTab).assertEqual(1)
      expect(vm.statusText).assertEqual('panes 1 · focus p1')
      expect(vm.panes.join(',')).assertEqual('p1')
      vm.setActiveTab(0)
      expect(vm.statusText).assertEqual('panes 2 · focus p1')
    })
  })
}
