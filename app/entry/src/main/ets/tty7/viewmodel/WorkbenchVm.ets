/**
 * tty7 工作台 ViewModel(任务 tty7-M1b 建立,M1c 扩容接入 LayoutTree)。
 *
 * 纯状态容器:字段 + 纯方法。红线:不 import 任何 service/PTY/SSH/AI/store。
 * M1c 起 layout 为真布局树:一切变换经 LayoutOps 纯函数产出新树后整体替换
 * (@Observed 只跟踪第一层,嵌套对象不可变替换驱动 @ObjectLink 消费方刷新);
 * panes/focusedPane/statusText 均由 syncFromLayout 从树同步,禁止双源手写。
 */
import { LayoutTreeModel, SplitDir } from '../layout/LayoutTree';
import { LayoutOps } from '../layout/LayoutOps';

@Observed
export class WorkbenchVm {
  /** tab 标题数组(activeTab 为下标);本期一个 tab 对应一棵布局树。 */
  tabs: string[] = ['tty7']
  activeTab: number = 0
  /** 布局树(M1c):一切布局事实的唯一来源。 */
  layout: LayoutTreeModel = new LayoutTreeModel()
  /** 以下两项由 syncFromLayout 从 layout 同步(派生展示态)。 */
  panes: string[] = []
  focusedPane: string = ''
  /** RightPanel(M1d agent 面板)开关桩。 */
  rightPanelOpen: boolean = false
  /** 命令面板开关(M1d):单源状态,AppShell/StatusBar 共用(避免双源)。 */
  paletteOpen: boolean = false
  /** 布局版本号:每次 syncFromLayout +1。PaneGrid 用其奇偶交替 if 分支强制
   * 重建渲染子树(V1 精准更新不重评组件构造参数,树根/槽宽变化否则全部
   * 冻结——M1c 验收实证;M3 前置优化:升级 @ObservedV2/@Trace 精细追踪)。 */
  rev: number = 0
  statusText: string = '就绪'
  /** Agent 状态点桩(M1d 接 HMH Provider 真状态)。 */
  agentOnline: boolean = true
  private tabSeq: number = 1
  private paneSeq: number = 0

  constructor() {
    // 双 pane 基线:single('p1') 再 split 出 p2(左右分)。
    this.syncFromLayout(LayoutOps.split(LayoutOps.single('p1'), 'p1', 'h', 'p2'))
  }

  /** 树 → 展示态同步(唯一写入口;整体替换驱动刷新)。 */
  private syncFromLayout(m: LayoutTreeModel): void {
    this.rev += 1
    this.layout = m
    this.panes = LayoutOps.panes(m)
    this.focusedPane = m.focusedPaneId
    const focus = m.focusedPaneId !== '' ? m.focusedPaneId : '-'
    this.statusText = 'panes ' + this.panes.length.toString() + ' · focus ' + focus
  }

  /** 新建 pane:空布局→single(首 pane);否则对焦点叶 split,新 id=p{现存最大序号+1}。 */
  newPane(dir: SplitDir): void {
    const ids = LayoutOps.panes(this.layout)
    let max = 0
    for (const id of ids) {
      if (id.indexOf('p') === 0) {
        const num = Number(id.substring(1))
        if (!Number.isNaN(num) && num > max) {
          max = num
        }
      }
    }
    this.paneSeq = max + 1
    const fresh = 'p' + this.paneSeq.toString()
    if (ids.length === 0) {
      this.syncFromLayout(LayoutOps.single(fresh))
      return
    }
    let host = this.layout.focusedPaneId
    if (host === '') {
      host = ids[0]
    }
    this.syncFromLayout(LayoutOps.split(this.layout, host, dir, fresh))
  }

  /** 关闭 pane(close 内建焦点迁移与父层折叠)。 */
  closePane(id: string): void {
    this.syncFromLayout(LayoutOps.close(this.layout, id))
  }

  /** 焦点叶 zoom 切换(zoom 语义由 PaneGrid 渲染层实现)。 */
  zoomToggle(): void {
    if (this.layout.focusedPaneId === '') {
      return
    }
    this.syncFromLayout(LayoutOps.zoom(this.layout, this.layout.focusedPaneId))
  }

  /** 分隔条拖拽落点(供 PaneGrid 回调;clamp 由 LayoutOps 内建)。 */
  resizeSplit(splitNodeId: string, ratio: number): void {
    this.syncFromLayout(LayoutOps.resize(this.layout, splitNodeId, ratio))
  }

  /** 新建 tab:标题 tty7-N,置为 active。 */
  newTab(): void {
    this.tabSeq += 1
    this.tabs = this.tabs.concat(['tty7-' + this.tabSeq.toString()])
    this.activeTab = this.tabs.length - 1
    this.statusText = '新标签 tty7-' + this.tabSeq.toString()
  }

  /** 关 tab(至少保留 1 个);active 落在被删位时右移收缩,在左侧时左移。 */
  closeTab(i: number): void {
    if (i < 0 || i >= this.tabs.length || this.tabs.length <= 1) {
      return
    }
    this.tabs = this.tabs.slice(0, i).concat(this.tabs.slice(i + 1))
    if (this.activeTab >= this.tabs.length) {
      this.activeTab = this.tabs.length - 1
    } else if (i < this.activeTab) {
      this.activeTab -= 1
    }
    this.statusText = '关闭标签,共 ' + this.tabs.length.toString() + ' 个'
  }

  setActiveTab(i: number): void {
    if (i >= 0 && i < this.tabs.length && i !== this.activeTab) {
      this.activeTab = i
    }
  }

  /** 焦点 pane 切换(pane 必须存在;经 LayoutOps.focus 保持单源)。 */
  focusPane(id: string): void {
    if (this.panes.indexOf(id) >= 0 && id !== this.focusedPane) {
      this.syncFromLayout(LayoutOps.focus(this.layout, id))
    }
  }

  /** RightPanel 开关(桩)。 */
  toggleRightPanel(): void {
    this.rightPanelOpen = !this.rightPanelOpen
    this.statusText = this.rightPanelOpen ? 'Agent 面板开' : 'Agent 面板关'
  }

  /** 命令面板开关翻转(M1d;syncFromLayout 不动它——非布局派生态)。 */
  togglePalette(): void {
    this.paletteOpen = !this.paletteOpen
  }

  /** 状态栏文案直写(Sidebar 桩动作回写)。 */
  setStatus(text: string): void {
    this.statusText = text
  }
}
