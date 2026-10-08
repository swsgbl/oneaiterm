/**
 * tty7 Pane 布局树纯数据模型（任务 tty7-M1a，ADR-0001 ArkUI 同构壳 M1 基石）。
 *
 * 设计约定（与规格的对应关系）：
 * - 布局与 UI 彻底分离：本文件只有数据结构，所有布局操作是纯数据变换（LayoutOps.ets），
 *   M1c 的 ArkUI 组件只消费这棵树。
 * - ArkTS 联合类型受限的等价结构：LayoutNode = PaneLeaf | SplitNode 为判别联合，
 *   判别方式 = instanceof 收窄 + isSplit() 辅助方法（访问联合成员前需类型收窄）。
 * - SplitNode 在规格三字段（dir/ratio/children）之外携带最小必要扩展字段 id：
 *   resize(model, splitNodeId, ratio) 需要寻址内部分割节点，无 id 则 API 无法落地。
 * - PaneLeaf.sizeRatio 语义：0 < r <= 1，同层兄弟归一（仅在“直接子节点全为叶”的层
 *   有强约束 sum=1；混合层由渲染端按 children 数均分，见 LayoutOps 注释）。
 */

/** 分割方向：'h' 左右分（水平轴），'v' 上下分（垂直轴）。 */
export type SplitDir = 'h' | 'v'

/** 叶节点：一个 pane 占位。 */
export class PaneLeaf {
  paneId: string = ''
  sizeRatio: number = 1
  isSplit(): boolean {
    return false
  }
}

/** 分割节点：children.length >= 2；二叉时 ratio 为第一子的占比。 */
export class SplitNode {
  id: string = ''
  dir: SplitDir = 'h'
  ratio: number = 0.5
  children: LayoutNode[] = []
  isSplit(): boolean {
    return true
  }
}

/** 树节点联合类型（判别联合，见文件头说明）。 */
export type LayoutNode = PaneLeaf | SplitNode

/** 布局树模型：根 + 焦点 pane + zoom pane（zoomedPaneId === '' 表示无 zoom）。 */
export class LayoutTreeModel {
  root: LayoutNode = new PaneLeaf()
  focusedPaneId: string = ''
  zoomedPaneId: string = ''
}
