/**
 * tty7 工作台 ViewModel(任务 tty7-M1b 建立,M1c 扩容接入 LayoutTree,M2a 多 Tab 独立布局树+持久化恢复)。
 *
 * 纯状态容器:字段 + 纯方法。红线:除 tty7/store/WorkbenchStore 外不 import 任何 service/PTY/SSH/AI。
 * M2a 起 tabs 为 TabState[](每 tab 独立布局树):切 tab 布局跟随 setActiveTab 内
 * syncFromLayout(tabs[i].layout);一切布局变换经 syncFromLayout 落到
 * tabs[activeTab].layout 再派生 panes/focusedPane/statusText/rev(整树不可变替换驱动刷新)。
 * 持久化:构造恢复(失败→双 pane 基线);sync/newTab/closeTab/setActiveTab 后 saveWorkbench。
 * 对外签名/字段(tabs/activeTab/panes/focusedPane/statusText/rev/layout)不变——消费方零改动
 * (TabBar 渲染改读 tabs[i].title,属展示字段适配,非签名破坏)。
 */
import { LayoutTreeModel, SplitDir } from '../layout/LayoutTree';
import { LayoutOps } from '../layout/LayoutOps';
import { TabState } from '../model/TabState';
import { restoreWorkbench, saveWorkbench } from '../store/WorkbenchStore';

@Observed
export class WorkbenchVm {
  /** tab 状态数组(activeTab 为下标);每 tab 独立布局树(M2a)。 */
  tabs: TabState[] = []
  activeTab: number = 0
  /** 布局树(=tabs[activeTab].layout 同步引用;一切布局事实的唯一来源)。 */
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
    // 恢复存档;失败(无档/损坏/无 context)→ 双 pane 基线:single('p1') 再 split 出 p2。
    let restored = false
    try {
      const snap = restoreWorkbench()
      if (snap !== null) {
        this.tabs = snap.tabs
        this.activeTab = snap.active
        // tabSeq 从恢复的 tabId 重导(防 closeTab 后 newTab 生成重复 id:
        // 存档可能来自 t1..t3 的会话,tabSeq 若仍为 1 会再造出 t2/t3 撞键)
        let maxTab = 0
        for (const t of this.tabs) {
          if (t.tabId.indexOf('t') === 0) {
            const num = Number(t.tabId.substring(1))
            if (!Number.isNaN(num) && num > maxTab) {
              maxTab = num
            }
          }
        }
        this.tabSeq = maxTab
        this.syncFromLayout(this.tabs[this.activeTab].layout)
        restored = true
      }
    } catch (e) {
      restored = false
    }
    if (!restored) {
      const t = new TabState()
      t.tabId = 't1'
      t.title = 'tty7'
      t.layout = LayoutOps.split(LayoutOps.single('p1'), 'p1', 'h', 'p2')
      this.tabs = [t]
      this.activeTab = 0
      this.syncFromLayout(t.layout)
    }
  }

  /** 树 → 展示态同步(唯一写入口;写入当前 tab 树 + 整体替换驱动刷新 + 落盘)。 */
  private syncFromLayout(m: LayoutTreeModel): void {
    this.rev += 1
    this.layout = m
    if (this.activeTab >= 0 && this.activeTab < this.tabs.length) {
      this.tabs[this.activeTab].layout = m
    }
    this.panes = LayoutOps.panes(m)
    this.focusedPane = m.focusedPaneId
    const focus = m.focusedPaneId !== '' ? m.focusedPaneId : '-'
    this.statusText = 'panes ' + this.panes.length.toString() + ' · focus ' + focus
    this.persist()
  }

  /** 持久化(无 context 环境静默不落盘;失败静默,绝不外抛)。 */
  private persist(): void {
    try {
      saveWorkbench(this.tabs, this.activeTab)
    } catch (e) {
      // 静默:存档失败不阻塞 UI
    }
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

  /** 新建 tab:空模型根叶(切到即见"空白工作区"引导),标题 tty7-N,置为 active。 */
  newTab(): void {
    this.tabSeq += 1
    const t = new TabState()
    t.tabId = 't' + this.tabSeq.toString()
    t.title = 'tty7-' + this.tabSeq.toString()
    this.tabs = this.tabs.concat([t])
    this.activeTab = this.tabs.length - 1
    this.syncFromLayout(t.layout)
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
    this.syncFromLayout(this.tabs[this.activeTab].layout)
    this.statusText = '关闭标签,共 ' + this.tabs.length.toString() + ' 个'
  }

  /** 切 tab:布局跟随(整树替换 + sync 派生)。 */
  setActiveTab(i: number): void {
    if (i >= 0 && i < this.tabs.length && i !== this.activeTab) {
      this.activeTab = i
      this.syncFromLayout(this.tabs[i].layout)
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
