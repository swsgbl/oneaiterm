/**
 * tty7 LayoutTree/LayoutOps 单元测试（任务 tty7-M1a，ArkTS/hypium）。
 *
 * 与既有套件的“纯函数复制”范式不同：LayoutTree 是本任务新增的零依赖纯数据模块，
 * 因此直接相对路径 import 真实实现（测真实 API 而非复制品）。
 *
 * 覆盖（对应任务验收点）：
 *   1. single → split h → split v 嵌套构造 2x2 后 panes 先序正确
 *   2. close 中间叶 → 父折叠；（另一用例）收敛单叶 → sizeRatio 归一为 1
 *   3. close 最后一个叶 → 空模型不崩溃
 *   4. focus/zoom 切换与取消（再点同叶取消）
 *   5. resize clamp 0.1~0.9
 *   6. neighbor 2x2 四向正确 + 边界返回 ''
 *   7. replacePanes 幂等（二次应用无操作）+ focused/zoomed 同步改写
 *   8. 不可变风格：所有 op 不改入参
 */
import { describe, it, expect } from '@ohos/hypium';
import { LayoutOps } from '../../../main/ets/tty7/layout/LayoutOps';
import { LayoutTreeModel, PaneLeaf, SplitNode } from '../../../main/ets/tty7/layout/LayoutTree';

/** 构造 2x2：A|B 两列，各列上下再分（A→C 上/下、B→D 上/下）。panes 先序 = A,C,B,D。 */
function build2x2(): LayoutTreeModel {
  let m = LayoutOps.single('A')
  m = LayoutOps.split(m, 'A', 'h', 'B')
  m = LayoutOps.split(m, 'A', 'v', 'C')
  m = LayoutOps.split(m, 'B', 'v', 'D')
  return m
}

export default function layoutTreeTest() {
  describe('tty7LayoutTree', () => {
    // ===== 1. 构造与 panes 先序 =====
    it('single_split_nested_2x2_panes_preorder', 0, () => {
      const m0 = LayoutOps.single('A')
      expect(LayoutOps.panes(m0).join(',')).assertEqual('A')
      const m = build2x2()
      expect(LayoutOps.panes(m).join(',')).assertEqual('A,C,B,D')
      // 根为 h 分割，两列各为 v 分割
      const root = m.root
      expect(root instanceof SplitNode).assertTrue()
      const sp = root as SplitNode
      expect(sp.dir).assertEqual('h')
      expect(sp.ratio).assertEqual(0.5)
      expect(sp.children.length).assertEqual(2)
      expect(sp.children[0] instanceof SplitNode).assertTrue()
      expect((sp.children[0] as SplitNode).dir).assertEqual('v')
      expect((sp.children[1] as SplitNode).dir).assertEqual('v')
      // split 语义：新叶在后位
      expect((sp.children[0] as SplitNode).children[0] instanceof PaneLeaf).assertTrue()
      expect(((sp.children[0] as SplitNode).children[0] as PaneLeaf).paneId).assertEqual('A')
    })

    it('split_keeps_old_pane_and_sets_ratio_half', 0, () => {
      let m = LayoutOps.single('A')
      m = LayoutOps.split(m, 'A', 'h', 'B')
      const sp = m.root as SplitNode
      expect(((sp.children[0] as PaneLeaf).paneId)).assertEqual('A')
      expect(((sp.children[1] as PaneLeaf).paneId)).assertEqual('B')
      expect((sp.children[0] as PaneLeaf).sizeRatio).assertEqual(0.5)
      expect((sp.children[1] as PaneLeaf).sizeRatio).assertEqual(0.5)
    })

    it('split_unknown_pane_is_noop', 0, () => {
      const m0 = LayoutOps.single('A')
      const m1 = LayoutOps.split(m0, 'Z', 'h', 'B')
      expect(LayoutOps.panes(m1).join(',')).assertEqual('A')
      expect(m1.root instanceof PaneLeaf).assertTrue()
    })

    // ===== 2. close：父折叠 / sizeRatio 归一 =====
    it('close_middle_leaf_parent_collapses', 0, () => {
      const m2 = build2x2()
      const m = LayoutOps.close(m2, 'C')
      expect(LayoutOps.panes(m).join(',')).assertEqual('A,B,D')
      // v{A,C} 折叠：根 h 的第一子直接是叶 A
      const sp = m.root as SplitNode
      expect(sp.children[0] instanceof PaneLeaf).assertTrue()
      expect((sp.children[0] as PaneLeaf).paneId).assertEqual('A')
      expect(sp.children.length).assertEqual(2)
    })

    it('close_to_single_leaf_ratio_normalized', 0, () => {
      let m = LayoutOps.single('A')
      m = LayoutOps.split(m, 'A', 'h', 'B')
      const m1 = LayoutOps.close(m, 'B')
      expect(LayoutOps.panes(m1).join(',')).assertEqual('A')
      expect(m1.root instanceof PaneLeaf).assertTrue()
      expect((m1.root as PaneLeaf).sizeRatio).assertEqual(1)
      expect(m1.focusedPaneId).assertEqual('A')
    })

    it('close_focus_on_deleted_moves_to_nearest', 0, () => {
      // h{A, v{B,C}}，focus C，删 C → v 折叠为 B，focus 迁到几何最近叶 B
      let m = LayoutOps.single('A')
      m = LayoutOps.split(m, 'A', 'h', 'B')
      m = LayoutOps.split(m, 'B', 'v', 'C')
      m = LayoutOps.focus(m, 'C')
      const m1 = LayoutOps.close(m, 'C')
      expect(LayoutOps.panes(m1).join(',')).assertEqual('A,B')
      expect(m1.focusedPaneId).assertEqual('B')
    })

    it('close_zoomed_pane_clears_zoom', 0, () => {
      const m2 = build2x2()
      const z = LayoutOps.zoom(m2, 'D')
      expect(z.zoomedPaneId).assertEqual('D')
      const m1 = LayoutOps.close(z, 'D')
      expect(m1.zoomedPaneId).assertEqual('')
    })

    // ===== 3. close 最后一个叶：空模型不崩溃 =====
    it('close_last_leaf_yields_empty_model', 0, () => {
      const m0 = LayoutOps.single('A')
      const m1 = LayoutOps.close(m0, 'A')
      expect(LayoutOps.panes(m1).join(',')).assertEqual('')
      expect(m1.root instanceof PaneLeaf).assertTrue()
      expect((m1.root as PaneLeaf).paneId).assertEqual('')
      expect(m1.focusedPaneId).assertEqual('')
      expect(m1.zoomedPaneId).assertEqual('')
      // 空模型上继续操作不崩溃
      const m2 = LayoutOps.close(m1, '')
      expect(LayoutOps.panes(m2).join(',')).assertEqual('')
      const m3 = LayoutOps.zoom(m1, 'X')
      expect(m3.zoomedPaneId).assertEqual('')
    })

    // ===== 4. focus / zoom 切换与取消 =====
    it('focus_and_zoom_toggle', 0, () => {
      const m2 = build2x2()
      const f = LayoutOps.focus(m2, 'B')
      expect(f.focusedPaneId).assertEqual('B')
      const f2 = LayoutOps.focus(f, 'D')
      expect(f2.focusedPaneId).assertEqual('D')
      // focus 不改 zoom
      expect(f2.zoomedPaneId).assertEqual('')
      // zoom 切换
      const z1 = LayoutOps.zoom(f2, 'A')
      expect(z1.zoomedPaneId).assertEqual('A')
      const z2 = LayoutOps.zoom(z1, 'D')
      expect(z2.zoomedPaneId).assertEqual('D')
      // 再点同叶取消
      const z3 = LayoutOps.zoom(z2, 'D')
      expect(z3.zoomedPaneId).assertEqual('')
      // 未知 pane：无操作
      const z4 = LayoutOps.zoom(z3, 'Z')
      expect(z4.zoomedPaneId).assertEqual('')
      const f3 = LayoutOps.focus(f2, 'Z')
      expect(f3.focusedPaneId).assertEqual('D')
    })

    // ===== 5. resize clamp =====
    it('resize_clamps_between_01_and_09', 0, () => {
      let m = LayoutOps.single('A')
      m = LayoutOps.split(m, 'A', 'h', 'B')
      const spId = (m.root as SplitNode).id
      const up = LayoutOps.resize(m, spId, 0.95)
      expect((up.root as SplitNode).ratio).assertEqual(0.9)
      const down = LayoutOps.resize(m, spId, 0.05)
      expect((down.root as SplitNode).ratio).assertEqual(0.1)
      const mid = LayoutOps.resize(m, spId, 0.3)
      expect((mid.root as SplitNode).ratio).assertEqual(0.3)
      // 未知 split id：无操作
      const noop = LayoutOps.resize(m, 'sp999', 0.7)
      expect((noop.root as SplitNode).ratio).assertEqual(0.5)
    })

    // ===== 6. neighbor 四向 + 边界 =====
    it('neighbor_2x2_all_directions', 0, () => {
      const m = build2x2()
      // 左列 A(上)/C(下)，右列 B(上)/D(下)
      expect(LayoutOps.neighbor(m, 'A', 'h')).assertEqual('B')
      expect(LayoutOps.neighbor(m, 'B', 'h')).assertEqual('A')
      expect(LayoutOps.neighbor(m, 'C', 'h')).assertEqual('D')
      expect(LayoutOps.neighbor(m, 'D', 'h')).assertEqual('C')
      expect(LayoutOps.neighbor(m, 'A', 'v')).assertEqual('C')
      expect(LayoutOps.neighbor(m, 'C', 'v')).assertEqual('A')
      expect(LayoutOps.neighbor(m, 'B', 'v')).assertEqual('D')
      expect(LayoutOps.neighbor(m, 'D', 'v')).assertEqual('B')
    })

    it('neighbor_boundary_returns_empty', 0, () => {
      // 两叶水平布局：垂直方向无邻居
      let m = LayoutOps.single('A')
      m = LayoutOps.split(m, 'A', 'h', 'B')
      expect(LayoutOps.neighbor(m, 'A', 'v')).assertEqual('')
      expect(LayoutOps.neighbor(m, 'B', 'v')).assertEqual('')
      // 单叶：四向皆空
      const s = LayoutOps.single('A')
      expect(LayoutOps.neighbor(s, 'A', 'h')).assertEqual('')
      expect(LayoutOps.neighbor(s, 'A', 'v')).assertEqual('')
      // 空模型：不崩溃返回空
      const e = LayoutOps.single('')
      expect(LayoutOps.neighbor(e, '', 'h')).assertEqual('')
    })

    // ===== 7. replacePanes 幂等 =====
    it('replace_panes_idempotent', 0, () => {
      const m2 = build2x2()
      const f = LayoutOps.focus(m2, 'C')
      const z = LayoutOps.zoom(f, 'C')
      const map = new Map<string, string>()
      map.set('A', 'W')
      map.set('C', 'X')
      const once = LayoutOps.replacePanes(z, map)
      expect(LayoutOps.panes(once).join(',')).assertEqual('W,X,B,D')
      expect(once.focusedPaneId).assertEqual('X')
      expect(once.zoomedPaneId).assertEqual('X')
      // 二次应用同一映射：旧 id 已不存在 → 无操作（幂等）
      const twice = LayoutOps.replacePanes(once, map)
      expect(LayoutOps.panes(twice).join(',')).assertEqual('W,X,B,D')
      expect(twice.focusedPaneId).assertEqual('X')
      expect(twice.zoomedPaneId).assertEqual('X')
    })

    // ===== 8. 不可变风格：入参不被修改 =====
    it('ops_never_mutate_input_model', 0, () => {
      const m2 = build2x2()
      const before = LayoutOps.panes(m2).join(',')
      LayoutOps.split(m2, 'A', 'h', 'E')
      LayoutOps.close(m2, 'A')
      LayoutOps.focus(m2, 'B')
      LayoutOps.zoom(m2, 'B')
      const spId = (m2.root as SplitNode).id
      LayoutOps.resize(m2, spId, 0.9)
      const map = new Map<string, string>()
      map.set('A', 'W')
      LayoutOps.replacePanes(m2, map)
      expect(LayoutOps.panes(m2).join(',')).assertEqual(before)
      expect((m2.root as SplitNode).ratio).assertEqual(0.5)
      expect(m2.focusedPaneId).assertEqual('A')
      expect(m2.zoomedPaneId).assertEqual('')
    })
  })
}
