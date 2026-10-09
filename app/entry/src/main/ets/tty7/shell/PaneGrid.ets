/**
 * tty7 PaneGrid 布局树渲染器(任务 tty7-M1c,ADR-0001 ArkUI 同构壳 M1 第三块)。
 *
 * 消费 vm.layout(LayoutTreeModel)递归渲染:SplitNode('h')→Row / ('v')→Column,
 * 子节点间 4px 视觉宽(12px 命中宽)SplitHandle:onTouch 本地坐标差分调
 * vm.resizeSplit(sp.id, ratio)(clamp 0.1~0.9 由 LayoutOps 内建)。
 * zoom 语义由渲染层实现:layout.zoomedPaneId !== '' 时只画该叶。
 * 空模型(root 叶 paneId='')显示"新建 pane"引导(vm.newPane('h') 即得 single('p1'),
 * 与规格 split('','h','p1') 等价——LayoutOps.split 对空 paneId 是守卫直返)。
 *
 * 热修(M1c 验收实测驱动):递归渲染不能放 @Builder——@Builder 普通参数
 * (node/sp/ratio)不参与响应式追踪,首次构建后整体冻结:close(根 Split→Leaf)
 * 屏面残留旧分屏、resize(ratio 变化)宽度不动,而 VM 状态栏已更新(实证)。
 * 改为独立组件 SplitLayout 递归:@Prop node 树整体按值更新驱动组件重渲,
 * @Builder 仅承载引用自身状态(this.node/@Prop)的槽位表达式;轴向长度由
 * 组件自身 onAreaChange 测(@State,不依赖父级 ForEach 键传递)。
 *
 * 红线遵守:布局计算全部走 LayoutOps,组件内无树变换(仅渲染递归+身份键);
 * ForEach 键含 ratio/身份戳——ratio 或结构变化时槽位重建。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { LayoutNode, PaneLeaf, SplitNode } from '../layout/LayoutTree';
import { PaneSurface } from './PaneSurface';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

/** 分隔条:可拖拽调父 SplitNode.ratio。轴向差分换算,不依赖全局坐标 API。 */
@Component
struct SplitHandle {
  @Prop isH: boolean = true
  @Prop axisLen: number = 0
  @Prop ratio: number = 0.5
  @Prop themeName: string = 'dark'
  onRatio: (r: number) => void = () => {
  }
  @State active: boolean = false
  @State selfAxis: number = 0
  private startPx: number = 0
  private baseRatio: number = 0.5

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  private axis(): number {
    return this.axisLen > 1 ? this.axisLen : this.selfAxis
  }

  build() {
    if (this.isH) {
      // 垂直分隔条(左右分):12px 命中宽,2px 视觉条
      Column() {
        Row()
          .width(2)
          .height('100%')
          .borderRadius(1)
          .backgroundColor(this.active ? this.th().brand : this.th().hairline)
      }
      .width(12)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_SM)
      .backgroundColor(this.active ? this.th().hover : Color.Transparent)
      .onAreaChange((_o: Area, n: Area) => {
        this.selfAxis = Number(n.height)
      })
      .onTouch((e: TouchEvent) => this.handleTouch(e))
    } else {
      // 水平分隔条(上下分)
      Row() {
        Column()
          .height(2)
          .width('100%')
          .borderRadius(1)
          .backgroundColor(this.active ? this.th().brand : this.th().hairline)
      }
      .height(12)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_SM)
      .backgroundColor(this.active ? this.th().hover : Color.Transparent)
      .onAreaChange((_o: Area, n: Area) => {
        this.selfAxis = Number(n.width)
      })
      .onTouch((e: TouchEvent) => this.handleTouch(e))
    }
  }

  private handleTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.active = true
      this.startPx = this.isH ? e.touches[0].x : e.touches[0].y
      this.baseRatio = this.ratio
    } else if (e.type === TouchType.Move && this.active) {
      const cur = this.isH ? e.touches[0].x : e.touches[0].y
      if (this.axis() > 1) {
        this.onRatio(this.baseRatio + (cur - this.startPx) / this.axis())
      }
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.active = false
    }
  }
}

/** 布局树递归渲染组件:@Prop node 按值更新驱动重渲(替代冻结的 @Builder 递归)。 */
@Component
struct SplitLayout {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  @Prop node: LayoutNode = new PaneLeaf()
  /** 容器轴向尺寸(px),供 SplitHandle 差分换算;onAreaChange 自测。 */
  @State axisSize: number = 0

  build() {
    Column() {
      this.renderNode(this.node)
    }
    .width('100%')
    .height('100%')
  }

  /** 递归分派:@Builder 内 if 分支选向;组件重渲(@Prop node 更新)时重新求值。 */
  @Builder
  renderNode(node: LayoutNode) {
    if (node instanceof SplitNode) {
      if ((node as SplitNode).dir === 'h') {
        this.buildH(node as SplitNode)
      } else {
        this.buildV(node as SplitNode)
      }
    } else {
      PaneSurface({
        vm: this.vm,
        themeName: this.themeName,
        paneId: (node as PaneLeaf).paneId,
        onZoom: () => this.vm.zoomToggle()
      })
    }
  }

  /** 左右分:首子宽 ratio%,中间子均分,末子 layoutWeight(1) 吃剩余空间。 */
  @Builder
  buildH(sp: SplitNode) {
    Row() {
      ForEach(this.idxArr(sp.children.length), (i: number) => {
        if (i > 0) {
          SplitHandle({
            isH: true,
            axisLen: this.axisSize,
            ratio: sp.ratio,
            themeName: this.themeName,
            onRatio: (r: number) => this.vm.resizeSplit(sp.id, r)
          })
        }
        if (i === sp.children.length - 1) {
          Column() {
            SplitLayout({ vm: this.vm, themeName: this.themeName, node: sp.children[i] })
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          Column() {
            SplitLayout({ vm: this.vm, themeName: this.themeName, node: sp.children[i] })
          }
          .width(this.pct(i === 0 ? sp.ratio : (1 - sp.ratio) / (sp.children.length - 1)))
          .height('100%')
        }
      }, (i: number) => this.slotKey(sp, i))
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_o: Area, n: Area) => {
      this.axisSize = Number(n.width)
    })
  }

  /** 上下分:与 buildH 镜像(宽高对调)。 */
  @Builder
  buildV(sp: SplitNode) {
    Column() {
      ForEach(this.idxArr(sp.children.length), (i: number) => {
        if (i > 0) {
          SplitHandle({
            isH: false,
            axisLen: this.axisSize,
            ratio: sp.ratio,
            themeName: this.themeName,
            onRatio: (r: number) => this.vm.resizeSplit(sp.id, r)
          })
        }
        if (i === sp.children.length - 1) {
          Row() {
            SplitLayout({ vm: this.vm, themeName: this.themeName, node: sp.children[i] })
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Row() {
            SplitLayout({ vm: this.vm, themeName: this.themeName, node: sp.children[i] })
          }
          .height(this.pct(i === 0 ? sp.ratio : (1 - sp.ratio) / (sp.children.length - 1)))
          .width('100%')
        }
      }, (i: number) => this.slotKey(sp, i))
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_o: Area, n: Area) => {
      this.axisSize = Number(n.height)
    })
  }

  private idxArr(n: number): number[] {
    const a: number[] = []
    for (let i = 0; i < n; i++) {
      a.push(i)
    }
    return a
  }

  private pct(r: number): string {
    return (r * 100).toFixed(2) + '%'
  }

  /** ForEach 键:槽位+ratio+子身份戳——驱动拖拽/结构变化的槽位重建。 */
  private slotKey(sp: SplitNode, i: number): string {
    const c = sp.children[i]
    const stamp = c instanceof SplitNode ? (c as SplitNode).id : (c as PaneLeaf).paneId
    return i.toString() + '#' + sp.ratio.toFixed(4) + '#' + sp.children.length.toString() + '#' + stamp
  }
}

@Component
export struct PaneGrid {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Column() {
      if (this.vm.layout.zoomedPaneId !== '') {
        // zoom:只画该叶(渲染层实现 zoom 语义)
        PaneSurface({
          vm: this.vm,
          themeName: this.themeName,
          paneId: this.vm.layout.zoomedPaneId,
          onZoom: () => this.vm.zoomToggle()
        })
          .layoutWeight(1)
          .width('100%')
      } else if (this.isEmptyRoot()) {
        // 空模型引导:点击即得首个 pane p1
        Column({ space: DesignTokens.SPACE_MD }) {
          Text('空白工作区')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
          Text('新建 pane')
            .fontSize(DesignTokens.FONT_HEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().onBrand)
            .padding({
              left: DesignTokens.SPACE_LG,
              right: DesignTokens.SPACE_LG,
              top: DesignTokens.SPACE_SM,
              bottom: DesignTokens.SPACE_SM
            })
            .backgroundColor(this.th().brand)
            .borderRadius(DesignTokens.RADIUS_MD)
            .accessibilityText('新建 pane')
            .onClick(() => this.vm.newPane('h'))
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
      } else if (this.vm.rev % 2 === 0) {
        // rev 奇偶双分支:syncFromLayout 每次 rev+1 → 本表达式(V1 绑定)重评
        // → 分支交替切换 → SplitLayout 销毁重建、以新树为 @Prop 初值——
        // 这是 V1 下唯一实证可靠的"树变更必重渲"通道(组件构造参数不绑定
        // 状态,@Builder 参数/ForEach 键在精准更新下均不重评,M1c 实测)。
        SplitLayout({ vm: this.vm, themeName: this.themeName, node: this.vm.layout.root })
          .layoutWeight(1)
          .width('100%')
      } else {
        SplitLayout({ vm: this.vm, themeName: this.themeName, node: this.vm.layout.root })
          .layoutWeight(1)
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(DesignTokens.SPACE_XS)
    .backgroundColor(this.th().surface)
  }

  private isEmptyRoot(): boolean {
    const r = this.vm.layout.root
    return !(r instanceof SplitNode) && (r as PaneLeaf).paneId === ''
  }
}
