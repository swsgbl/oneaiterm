/**
 * tty7 Pane 布局树纯数据变换（任务 tty7-M1a）。
 *
 * 全部纯静态函数、全部返回新树（不可变风格；内部深拷贝，绝不改入参）。
 * 无 UI、无业务 service 依赖——M1c ArkUI 组件与 M2 session 重挂只消费本 API。
 *
 * 语义要点：
 * - split：目标叶被 SplitNode[dir]{old, new} 原位替换，ratio 0.5；父层不做重排。
 * - close：叶删除后父 SplitNode 仅剩一子则该子上提替换父（可逐级连锁）；
 *   全树只剩该叶则返回 single('') 空模型；focused/zoomed 落在被删叶时，
 *   focus 移到按几何矩形中心距离最近的剩余叶，zoom 清除。
 * - neighbor：按几何矩形判定。'h' = 水平轴向邻居（左或右，取最近且垂直投影
 *   有重叠者），'v' = 垂直轴向邻居（上或下）。无邻居返回 ''。
 *   矩形细分约定：'h' 分割左右并排（首子占宽 ratio），'v' 上下堆叠（首子占高 ratio）；
 *   N>2 子时首子占 ratio、其余均分 (1-ratio)/(N-1)（本版本操作集只产生二叉）。
 * - panes：先序遍历叶；空模型（根叶 paneId=''）返回 []（文档化决策：
 *   空占位叶不对外暴露，M1c 消费方拿不到幽灵 pane）。
 * - SplitNode.id 由本文件在 split 时确定性生成（'sp' + 现存最大序号+1），
 *   供 resize(model, splitNodeId, ratio) 寻址。
 */
import { LayoutTreeModel, LayoutNode, PaneLeaf, SplitNode, SplitDir } from './LayoutTree';

/** 面积矩形（x/y/w/h 均为 0..1 归一坐标），neighbor/close 焦点迁移的几何依据。 */
class Rect {
  x: number = 0
  y: number = 0
  w: number = 1
  h: number = 1
}

/** close 的递归结果载体（ArkTS 不鼓励匿名对象字面量，用显式类）。 */
class RemoveState {
  removed: boolean = false
  focusFallback: string = ''
}

export class LayoutOps {

  /** 单叶模型。single('') 即空模型（focused/zoomed 均为 ''）。 */
  static single(paneId: string): LayoutTreeModel {
    const m = new LayoutTreeModel()
    const leaf = new PaneLeaf()
    leaf.paneId = paneId
    leaf.sizeRatio = 1
    m.root = leaf
    m.focusedPaneId = paneId
    m.zoomedPaneId = ''
    return m
  }

  /** 目标叶原位变 SplitNode[dir]{old, new}，ratio 0.5。找不到目标叶返回原模型的拷贝。 */
  static split(model: LayoutTreeModel, paneId: string, dir: SplitDir, newPaneId: string): LayoutTreeModel {
    const m = LayoutOps.cloneModel(model)
    const target = LayoutOps.findLeaf(m.root, paneId)
    if (target === null || paneId === '' || newPaneId === '' ||
      LayoutOps.findLeaf(m.root, newPaneId) !== null) {
      return m
    }
    const sp = new SplitNode()
    sp.id = LayoutOps.nextSplitId(m.root)
    sp.dir = dir
    sp.ratio = 0.5
    const fresh = new PaneLeaf()
    fresh.paneId = newPaneId
    fresh.sizeRatio = 0.5
    target.sizeRatio = 0.5
    sp.children.push(target)
    sp.children.push(fresh)
    m.root = LayoutOps.replaceNode(m.root, target, sp)
    return m
  }

  /**
   * 删除叶。父仅剩一子则上提替换（连锁）；全树只剩该叶返回 single('')。
   * focused/zoomed 在被删叶上时：focus 迁到几何最近剩余叶，zoom 清除。
   */
  static close(model: LayoutTreeModel, paneId: string): LayoutTreeModel {
    if (LayoutOps.findLeaf(model.root, paneId) === null) {
      return LayoutOps.cloneModel(model)
    }
    const fallback = LayoutOps.nearestOtherPane(model, paneId)
    const m = LayoutOps.cloneModel(model)
    const st = new RemoveState()
    const nextRoot: LayoutNode | null = LayoutOps.removeRec(m.root, paneId, st)
    if (nextRoot === null) {
      return LayoutOps.single('')
    }
    m.root = nextRoot
    if (st.removed) {
      LayoutOps.normalizeLeaves(m.root)
      // 折叠到单根叶时 ratio 归一为 1(normalizeLeaves 只处理 SplitNode,
      // 根叶场景无人管——单测 close_to_single_leaf_ratio_normalized 实证)
      if (m.root instanceof PaneLeaf) {
        (m.root as PaneLeaf).sizeRatio = 1
      }
      if (m.focusedPaneId === paneId) {
        m.focusedPaneId = fallback
      }
      if (m.zoomedPaneId === paneId) {
        m.zoomedPaneId = ''
      }
    }
    return m
  }

  /** 焦点切换（pane 必须存在，否则原样返回拷贝）。 */
  static focus(model: LayoutTreeModel, paneId: string): LayoutTreeModel {
    const m = LayoutOps.cloneModel(model)
    if (LayoutOps.findLeaf(m.root, paneId) !== null) {
      m.focusedPaneId = paneId
    }
    return m
  }

  /** zoom 切换：再点同叶取消；pane 必须存在。 */
  static zoom(model: LayoutTreeModel, paneId: string): LayoutTreeModel {
    const m = LayoutOps.cloneModel(model)
    if (LayoutOps.findLeaf(m.root, paneId) === null) {
      return m
    }
    m.zoomedPaneId = (m.zoomedPaneId === paneId) ? '' : paneId
    return m
  }

  /** 调整指定分割节点 ratio，clamp 0.1~0.9；未知 id 原样返回拷贝。 */
  static resize(model: LayoutTreeModel, splitNodeId: string, ratio: number): LayoutTreeModel {
    const m = LayoutOps.cloneModel(model)
    const clamped = Math.min(0.9, Math.max(0.1, ratio))
    const sp = LayoutOps.findSplit(m.root, splitNodeId)
    if (sp !== null) {
      sp.ratio = clamped
    }
    return m
  }

  /** 先序遍历叶（空占位叶 '' 不暴露）。 */
  static panes(model: LayoutTreeModel): string[] {
    const out: string[] = []
    LayoutOps.collectLeaves(model.root, out)
    return out
  }

  /** 几何最近邻：'h'=左右邻居、'v'=上下邻居；无邻居 ''。 */
  static neighbor(model: LayoutTreeModel, paneId: string, dir: SplitDir): string {
    const rects = new Map<string, Rect>()
    LayoutOps.assignRects(model.root, LayoutOps.unitRect(), rects)
    const target = rects.get(paneId)
    if (target === undefined) {
      return ''
    }
    const ids = LayoutOps.panes(model)
    let best = ''
    let bestGap = Number.MAX_VALUE
    let bestOverlap = -1
    for (const id of ids) {
      if (id === paneId) {
        continue
      }
      const r = rects.get(id)
      if (r === undefined) {
        continue
      }
      let gap = -1
      let overlap = 0
      if (dir === 'h') {
        const vOverlap = Math.min(target.y + target.h, r.y + r.h) - Math.max(target.y, r.y)
        if (vOverlap > 1e-9) {
          if (r.x >= target.x + target.w - 1e-9) {
            gap = r.x - (target.x + target.w)
          } else if (r.x + r.w <= target.x + 1e-9) {
            gap = target.x - (r.x + r.w)
          }
          overlap = vOverlap
        }
      } else {
        const hOverlap = Math.min(target.x + target.w, r.x + r.w) - Math.max(target.x, r.x)
        if (hOverlap > 1e-9) {
          if (r.y >= target.y + target.h - 1e-9) {
            gap = r.y - (target.y + target.h)
          } else if (r.y + r.h <= target.y + 1e-9) {
            gap = target.y - (r.y + r.h)
          }
          overlap = hOverlap
        }
      }
      if (gap >= -1e-9 && gap < Number.MAX_VALUE) {
        const g = Math.max(0, gap)
        if (best === '' || g < bestGap - 1e-9 || (Math.abs(g - bestGap) <= 1e-9 && overlap > bestOverlap)) {
          best = id
          bestGap = g
          bestOverlap = overlap
        }
      }
    }
    return best
  }

  /** 批量替换 pane id（M2 session 重挂）。focused/zoomed 同步改写。幂等：旧 id 不存在则无操作。 */
  static replacePanes(model: LayoutTreeModel, map: Map<string, string>): LayoutTreeModel {
    const m = LayoutOps.cloneModel(model)
    LayoutOps.remapLeaf(m.root, map)
    const nf = map.get(m.focusedPaneId)
    if (nf !== undefined) {
      m.focusedPaneId = nf
    }
    const nz = map.get(m.zoomedPaneId)
    if (nz !== undefined) {
      m.zoomedPaneId = nz
    }
    return m
  }

  // ===================== 内部工具（均为纯函数） =====================

  private static unitRect(): Rect {
    return new Rect()
  }

  private static cloneModel(model: LayoutTreeModel): LayoutTreeModel {
    const m = new LayoutTreeModel()
    m.root = LayoutOps.cloneNode(model.root)
    m.focusedPaneId = model.focusedPaneId
    m.zoomedPaneId = model.zoomedPaneId
    return m
  }

  private static cloneNode(node: LayoutNode): LayoutNode {
    if (node instanceof SplitNode) {
      const sp = new SplitNode()
      sp.id = node.id
      sp.dir = node.dir
      sp.ratio = node.ratio
      for (const c of node.children) {
        sp.children.push(LayoutOps.cloneNode(c))
      }
      return sp
    }
    const leaf = node as PaneLeaf
    const cp = new PaneLeaf()
    cp.paneId = leaf.paneId
    cp.sizeRatio = leaf.sizeRatio
    return cp
  }

  private static findLeaf(node: LayoutNode, paneId: string): PaneLeaf | null {
    if (node instanceof SplitNode) {
      for (const c of node.children) {
        const hit = LayoutOps.findLeaf(c, paneId)
        if (hit !== null) {
          return hit
        }
      }
      return null
    }
    const leaf = node as PaneLeaf
    return leaf.paneId === paneId ? leaf : null
  }

  private static findSplit(node: LayoutNode, id: string): SplitNode | null {
    if (node instanceof SplitNode) {
      if (node.id === id) {
        return node
      }
      for (const c of node.children) {
        const hit = LayoutOps.findSplit(c, id)
        if (hit !== null) {
          return hit
        }
      }
    }
    return null
  }

  /** 原位把 old 节点替换为 fresh（按引用同一性定位）。 */
  private static replaceNode(node: LayoutNode, old: LayoutNode, fresh: LayoutNode): LayoutNode {
    if (node === old) {
      return fresh
    }
    if (node instanceof SplitNode) {
      const kept: LayoutNode[] = []
      for (const c of node.children) {
        kept.push(LayoutOps.replaceNode(c, old, fresh))
      }
      node.children = kept
    }
    return node
  }

  /** 递归删叶：父仅剩一子则上提；返回 null 表示整树已空。 */
  private static removeRec(node: LayoutNode, paneId: string, st: RemoveState): LayoutNode | null {
    if (!(node instanceof SplitNode)) {
      const leaf = node as PaneLeaf
      if (leaf.paneId === paneId) {
        st.removed = true
        return null
      }
      return node
    }
    const sp = node as SplitNode
    const kept: LayoutNode[] = []
    for (const c of sp.children) {
      const r = LayoutOps.removeRec(c, paneId, st)
      if (r !== null) {
        kept.push(r)
      }
    }
    if (kept.length === 0) {
      return null
    }
    if (kept.length === 1) {
      return kept[0]
    }
    sp.children = kept
    return sp
  }

  /** 全叶兄弟组 sizeRatio 归一（sum=1，按原比例缩放）。 */
  private static normalizeLeaves(node: LayoutNode): void {
    if (!(node instanceof SplitNode)) {
      return
    }
    const sp = node as SplitNode
    let allLeaf = true
    for (const c of sp.children) {
      if (c instanceof SplitNode) {
        allLeaf = false
        break
      }
    }
    if (allLeaf) {
      let sum = 0
      for (const c of sp.children) {
        sum += (c as PaneLeaf).sizeRatio
      }
      if (sum > 1e-9) {
        for (const c of sp.children) {
          (c as PaneLeaf).sizeRatio = (c as PaneLeaf).sizeRatio / sum
        }
      }
    }
    for (const c of sp.children) {
      LayoutOps.normalizeLeaves(c)
    }
  }

  private static collectLeaves(node: LayoutNode, out: string[]): void {
    if (node instanceof SplitNode) {
      for (const c of node.children) {
        LayoutOps.collectLeaves(c, out)
      }
      return
    }
    const leaf = node as PaneLeaf
    if (leaf.paneId !== '') {
      out.push(leaf.paneId)
    }
  }

  /** 按分割语义递归分配矩形（'h' 左右并排、'v' 上下堆叠）。 */
  private static assignRects(node: LayoutNode, rect: Rect, out: Map<string, Rect>): void {
    if (!(node instanceof SplitNode)) {
      const leaf = node as PaneLeaf
      const r = new Rect()
      r.x = rect.x
      r.y = rect.y
      r.w = rect.w
      r.h = rect.h
      out.set(leaf.paneId, r)
      return
    }
    const sp = node as SplitNode
    const n = sp.children.length
    if (n === 0) {
      return
    }
    const rest = n > 1 ? (1 - sp.ratio) / (n - 1) : 0
    let offset = 0
    for (let i = 0; i < n; i++) {
      const w = i === 0 ? sp.ratio : rest
      const child = new Rect()
      if (sp.dir === 'h') {
        child.x = rect.x + rect.w * offset
        child.y = rect.y
        child.w = rect.w * w
        child.h = rect.h
      } else {
        child.x = rect.x
        child.y = rect.y + rect.h * offset
        child.w = rect.w
        child.h = rect.h * w
      }
      LayoutOps.assignRects(sp.children[i], child, out)
      offset += w
    }
  }

  /** 被删叶的 focus 迁移目标：几何中心最近的其它叶。 */
  private static nearestOtherPane(model: LayoutTreeModel, paneId: string): string {
    const rects = new Map<string, Rect>()
    LayoutOps.assignRects(model.root, LayoutOps.unitRect(), rects)
    const target = rects.get(paneId)
    if (target === undefined) {
      return ''
    }
    const tx = target.x + target.w / 2
    const ty = target.y + target.h / 2
    let best = ''
    let bestDist = Number.MAX_VALUE
    for (const id of LayoutOps.panes(model)) {
      if (id === paneId) {
        continue
      }
      const r = rects.get(id)
      if (r === undefined) {
        continue
      }
      const dx = r.x + r.w / 2 - tx
      const dy = r.y + r.h / 2 - ty
      const d = dx * dx + dy * dy
      if (best === '' || d < bestDist) {
        best = id
        bestDist = d
      }
    }
    return best
  }

  private static remapLeaf(node: LayoutNode, map: Map<string, string>): void {
    if (node instanceof SplitNode) {
      for (const c of node.children) {
        LayoutOps.remapLeaf(c, map)
      }
      return
    }
    const leaf = node as PaneLeaf
    const nv = map.get(leaf.paneId)
    if (nv !== undefined) {
      leaf.paneId = nv
    }
  }

  /** 确定性生成分割节点 id：'sp' + 现存最大数字后缀 + 1。 */
  private static nextSplitId(root: LayoutNode): string {
    let max = 0
    const stack: LayoutNode[] = [root]
    while (stack.length > 0) {
      const node = stack.pop() as LayoutNode
      if (node instanceof SplitNode) {
        const sp = node as SplitNode
        if (sp.id.indexOf('sp') === 0) {
          const num = Number(sp.id.substring(2))
          if (!Number.isNaN(num) && num > max) {
            max = num
          }
        }
        for (const c of sp.children) {
          stack.push(c)
        }
      }
    }
    return 'sp' + (max + 1)
  }
}
