/**
 * tty7 工作台 ViewModel 桩(任务 tty7-M1b,ADR-0001 ArkUI 同构壳 M1 第二块)。
 *
 * 纯状态容器:字段 + 纯方法。红线:不 import 任何 service/PTY/SSH/AI/store——
 * shell 组件只消费本 Vm;M1c PaneGrid 接 LayoutTree、M1d RightPanel 接 agent 面板时
 * 由宿主层负责桥接,本文件继续保持零业务依赖。
 *
 * @Observed 只跟踪第一层属性,方法内一律"整体重赋值"(concat/slice),
 * 不做 push/splice 原地修改,保证 @ObjectLink 消费方可靠重渲染。
 */
@Observed
export class WorkbenchVm {
  /** tab 标题数组(activeTab 为下标)。 */
  tabs: string[] = ['tty7']
  activeTab: number = 0
  /** M1c 前固定两个 pane 占位 id(p1/p2),M1c 起由 LayoutOps.panes() 供数。 */
  panes: string[] = ['p1', 'p2']
  focusedPane: string = 'p1'
  /** RightPanel(M1d agent 面板)开关桩。 */
  rightPanelOpen: boolean = false
  statusText: string = '就绪'
  /** Agent 状态点桩(M1d 接 HMH Provider 真状态)。 */
  agentOnline: boolean = true
  private tabSeq: number = 1

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

  /** 焦点 pane 切换(pane 必须存在,纯桩无副作用)。 */
  focusPane(id: string): void {
    if (this.panes.indexOf(id) >= 0 && id !== this.focusedPane) {
      this.focusedPane = id
      this.statusText = '焦点 ' + id
    }
  }

  /** RightPanel 开关(桩)。 */
  toggleRightPanel(): void {
    this.rightPanelOpen = !this.rightPanelOpen
    this.statusText = this.rightPanelOpen ? 'Agent 面板开' : 'Agent 面板关'
  }

  /** 状态栏文案直写(Sidebar 桩动作回写)。 */
  setStatus(text: string): void {
    this.statusText = text
  }
}
