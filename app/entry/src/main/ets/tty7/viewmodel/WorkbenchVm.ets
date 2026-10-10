/**
 * tty7 工作台 ViewModel(任务 tty7-M1b 建立,M1c 接入 LayoutTree,M2a 多 Tab 独立
 * 布局树+持久化,M2b 多工作区 + SessionSlot 挂接)。
 *
 * 纯状态容器:字段 + 纯方法。红线:除 tty7/store/WorkbenchStore 外不 import 任何 service/PTY/SSH/AI。
 * 四级模型(M2b 齐):Workspace(workspaces/activeWs)→ Tab(tabs/activeTab)→
 * Pane(layout/panes/focusedPane)→ Session(TabState.sessions + bind/unbind)。
 *
 * tabs 投影约定:@Observed(V1)无 getter 追踪,tabs 不能做成计算属性——改为
 * 显式同引用投影:tabs 恒等于 workspaces[activeWs].tabs(切工作区时整体替换
 * this.tabs 引用;写路径不变,syncFromLayout 写 tabs[activeTab] 即经同引用写回
 * 当前工作区,TabBar 等旧消费方零改动)。工作区 activeTab 记忆在 persist 前回写。
 *
 * SessionSlot 挂接:bindSession/unbindSession/sessionOf(当前 tab,pane 必须存在
 * 于树);closePane 联动清理被删 pane 的 slot;slotsRev 计数器驱动 PaneSurface
 * 标题行刷新(V1 方法调用不追踪,表达式读 slotsRev 绑定字段建立依赖)。
 * 持久化:构造恢复(失败→双 pane 基线);sync/会话变更/工作区操作后 saveWorkbench(v2)。
 */
import { LayoutTreeModel, SplitDir } from '../layout/LayoutTree';
import { LayoutOps } from '../layout/LayoutOps';
import { TabState, SessionSlot } from '../model/TabState';
import { WorkspaceState } from '../model/WorkspaceState';
import { restoreWorkbench, saveWorkbench } from '../store/WorkbenchStore';
import { TermHost } from '../term/TermHost';
import { RemoteTermHost } from '../remote/RemoteTermHost';
import { getSharedStore } from '../../store/ConnStore';

/** Sidebar 工作区图标 glyph 池(AppIcons 现有 glyph 集内取;本地常量,不 import UI 模块)。 */
const WS_GLYPHS: string[] = ['◈', '▣', '☸', '⌗', '∿', '▦', '◷'];

@Observed
export class WorkbenchVm {
  /** 工作区数组(activeWs 为下标;至少 1 个)。 */
  workspaces: WorkspaceState[] = []
  activeWs: number = 0
  /** tab 状态数组(=workspaces[activeWs].tabs 同引用投影;activeTab 为下标)。 */
  tabs: TabState[] = []
  activeTab: number = 0
  /** 布局树(=tabs[activeTab].layout 同步引用;一切布局事实的唯一来源)。 */
  layout: LayoutTreeModel = new LayoutTreeModel()
  /** 以下两项由 syncFromLayout 从 layout 同步(派生展示态)。 */
  panes: string[] = []
  focusedPane: string = ''
  /** RightPanel(M1d agent 面板)开关桩。 */
  rightPanelOpen: boolean = false
  /** 右面板当前页签(+tty7-M7a:'agent'|'sftp'|'git';从 RightPanel
   *  组件内 @State 提升为 vm 字段——palette 命令可指定落页)。 */
  rightTab: string = 'agent'
  /** 命令面板开关(M1d):单源状态,AppShell/StatusBar 共用(避免双源)。 */
  paletteOpen: boolean = false
  /** 布局版本号:每次 syncFromLayout +1。PaneGrid 用其奇偶交替 if 分支强制
   * 重建渲染子树(V1 精准更新不重评组件构造参数,树根/槽宽变化否则全部
   * 冻结——M1c 验收实证;M3 前置优化:升级 @ObservedV2/@Trace 精细追踪)。 */
  rev: number = 0
  /** 会话槽版本号:每次 bind/unbind/联动清理 +1。PaneSurface 标题表达式读
   * 此绑定字段(V1 方法调用不追踪,借 slotsRev 建立依赖),sessionTitle 纯查询。 */
  slotsRev: number = 0
  statusText: string = '就绪'
  /** 终端会话版本号(M3a):TermHost 绑定/解绑/EOF 死亡时 +1。PaneSurface
   *  内容区条件渲染表达式读此绑定字段(bound() 静态查询不追踪,借 termTick
   *  建立依赖,同 slotsRev 模式)。 */
  termTick: number = 0
  /** Agent 状态点桩(M1d 接 HMH Provider 真状态)。 */
  agentOnline: boolean = true
  /** Agent 活跃版本号(M5b):桥 emit 含 paneId 的事件时经 agentRevTap ++。
   *  PaneSurface 标题表达式读此绑定字段建立追踪(V1 方法调用不追踪,
   *  activeOnPane 纯查询,同 slotsRev/termTick 模式)。 */
  agentRev: number = 0
  private tabSeq: number = 1
  private paneSeq: number = 0
  private wsSeq: number = 1

  constructor() {
    // 恢复存档(v2 直读/v1 降级);失败(无档/损坏/无 context)→ 双 pane 基线:
    // 单工作区单 tab,single('p1') 再 split 出 p2。
    let restored = false
    try {
      const snap = restoreWorkbench()
      if (snap !== null) {
        this.workspaces = snap.workspaces
        this.activeWs = snap.activeWs
        // wsSeq/tabSeq 从恢复的 id 重导(防 close 后 new 生成重复 id 撞 ForEach 键)
        let maxWs = 0
        let maxTab = 0
        for (const ws of this.workspaces) {
          if (ws.wsId.indexOf('w') === 0) {
            const wn = Number(ws.wsId.substring(1))
            if (!Number.isNaN(wn) && wn > maxWs) {
              maxWs = wn
            }
          }
          for (const t of ws.tabs) {
            if (t.tabId.indexOf('t') === 0) {
              const num = Number(t.tabId.substring(1))
              if (!Number.isNaN(num) && num > maxTab) {
                maxTab = num
              }
            }
          }
        }
        this.wsSeq = maxWs
        this.tabSeq = maxTab
        const ws = this.workspaces[this.activeWs]
        this.tabs = ws.tabs
        this.activeTab = ws.activeTab >= 0 && ws.activeTab < ws.tabs.length ? ws.activeTab : 0
        ws.activeTab = this.activeTab
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
      const ws = new WorkspaceState()
      ws.wsId = 'w1'
      ws.name = 'workspace'
      ws.glyph = WS_GLYPHS[0]
      ws.tabs = [t]
      ws.activeTab = 0
      this.workspaces = [ws]
      this.activeWs = 0
      this.tabs = ws.tabs
      this.activeTab = 0
      this.syncFromLayout(t.layout)
    }
    // M3a:PTY EOF(sh exit)时通知 UI(model 保留供回看,termTick 驱动重评)
    TermHost.onDead = (): void => {
      this.termTick += 1
      this.statusText = '会话已结束'
    }
    // M6a:远程 SSH 会话死亡(connect 失败/断线/主动关)——清 slot 防幽灵,
    // termTick 驱动 PaneSurface 条件重评(statusText 由 refreshStatus 统一组装)
    RemoteTermHost.onDead = (): void => {
      const b = RemoteTermHost.bound()
      const why = this.remoteErrorBrief() // stop() 前取(死后保留诊断)
      RemoteTermHost.stop()
      if (b !== '') {
        this.unbindSession(b)
      }
      this.termTick += 1
      // M6b:失败/断线反馈(带原因前 60 字;无错回退通用文案)
      this.statusText = why !== '' ? 'ssh 失败:' + why : 'ssh 已断开'
    }
    // M6b:连接建立反馈(statusText;'ssh 已连接';onDead 同站点会覆写,
    // 文案不叠加)。错误原因经 RemoteTermHost.lastError 查询,不在此展开。
    RemoteTermHost.onOpen = (): void => {
      this.statusText = 'ssh 已连接'
    }
  }

  /** 布局树 → 展示态同步(唯一写入口;写入当前 tab 树 + 整体替换驱动刷新 + 落盘)。 */
  private syncFromLayout(m: LayoutTreeModel): void {
    this.rev += 1
    this.layout = m
    if (this.activeTab >= 0 && this.activeTab < this.tabs.length) {
      this.tabs[this.activeTab].layout = m
    }
    this.panes = LayoutOps.panes(m)
    this.focusedPane = m.focusedPaneId
    this.refreshStatus()
    this.persist()
  }

  /** 状态栏文案派生:panes N · focus X · sess M(仅 M>0 时追加)。 */
  private refreshStatus(): void {
    const focus = this.focusedPane !== '' ? this.focusedPane : '-'
    let s = 'panes ' + this.panes.length.toString() + ' · focus ' + focus
    const n = this.sessionCount()
    if (n > 0) {
      s += ' · sess ' + n.toString()
    }
    this.statusText = s
  }

  /** 持久化(无 context 环境静默不落盘;失败静默,绝不外抛)。
   *  落盘前回写当前工作区的 activeTab 记忆。 */
  private persist(): void {
    try {
      if (this.activeWs >= 0 && this.activeWs < this.workspaces.length) {
        this.workspaces[this.activeWs].activeTab = this.activeTab
      }
      saveWorkbench(this.workspaces, this.activeWs)
    } catch (e) {
      // 静默:存档失败不阻塞 UI
    }
  }

  // ===================== 工作区(M2b) =====================

  /** 新建工作区:空工作区(单 tab 空模型)入栈并切换。 */
  newWorkspace(): void {
    this.wsSeq += 1
    const ws = new WorkspaceState()
    ws.wsId = 'w' + this.wsSeq.toString()
    ws.name = 'workspace-' + this.wsSeq.toString()
    ws.glyph = WS_GLYPHS[(this.wsSeq - 1) % WS_GLYPHS.length]
    this.tabSeq += 1
    const t = new TabState()
    t.tabId = 't' + this.tabSeq.toString()
    t.title = 'tty7-' + this.tabSeq.toString()
    ws.tabs = [t]
    ws.activeTab = 0
    this.workspaces = this.workspaces.concat([ws])
    this.activeWs = this.workspaces.length - 1
    this.tabs = ws.tabs
    this.activeTab = 0
    this.syncFromLayout(t.layout)
    this.statusText = '新工作区 ' + ws.name
  }

  /** 切工作区:activeWs=i、tabs 引用整体替换、activeTab 取工作区记忆值、sync + persist。 */
  switchWorkspace(i: number): void {
    if (i < 0 || i >= this.workspaces.length || i === this.activeWs) {
      return
    }
    this.activeWs = i
    const ws = this.workspaces[i]
    this.tabs = ws.tabs
    this.activeTab = ws.activeTab >= 0 && ws.activeTab < ws.tabs.length ? ws.activeTab : 0
    this.syncFromLayout(this.tabs[this.activeTab].layout)
    this.statusText = '工作区 ' + ws.name
  }

  /** 关工作区(至少保留 1 个);active 落在被删位时右移收缩,在左侧时左移。 */
  closeWorkspace(i: number): void {
    if (i < 0 || i >= this.workspaces.length || this.workspaces.length <= 1) {
      return
    }
    this.workspaces = this.workspaces.slice(0, i).concat(this.workspaces.slice(i + 1))
    if (this.activeWs >= this.workspaces.length) {
      this.activeWs = this.workspaces.length - 1
    } else if (i < this.activeWs) {
      this.activeWs -= 1
    }
    const ws = this.workspaces[this.activeWs]
    this.tabs = ws.tabs
    this.activeTab = ws.activeTab >= 0 && ws.activeTab < ws.tabs.length ? ws.activeTab : 0
    this.syncFromLayout(this.tabs[this.activeTab].layout)
    this.statusText = '关闭工作区,共 ' + this.workspaces.length.toString() + ' 个'
    this.reapTermIfGone() // M3a:工作区收缩后绑定 pane 不在当前树 → 回收
  }

  // ===================== SessionSlot 挂接(M2b) =====================

  /** pane↔会话绑定(当前 tab;pane 必须存在于树;同 paneId 重复绑定=覆盖)。 */
  bindSession(paneId: string, kind: string, connKey: string, title: string): boolean {
    if (this.panes.indexOf(paneId) < 0) {
      return false
    }
    const cur = this.curTabOrNull()
    if (cur === null) {
      return false
    }
    let slot: SessionSlot | null = null
    for (const s of cur.sessions) {
      if (s.paneId === paneId) {
        slot = s
        break
      }
    }
    if (slot === null) {
      slot = new SessionSlot()
      slot.paneId = paneId
      cur.sessions = cur.sessions.concat([slot])
    }
    slot.kind = kind
    slot.connKey = connKey
    slot.title = title
    this.slotsRev += 1
    this.refreshStatus()
    this.persist()
    return true
  }

  /** 解除绑定(未绑定 no-op)。 */
  unbindSession(paneId: string): void {
    const cur = this.curTabOrNull()
    if (cur === null) {
      return
    }
    let found = false
    const kept: SessionSlot[] = []
    for (const s of cur.sessions) {
      if (s.paneId === paneId) {
        found = true
      } else {
        kept.push(s)
      }
    }
    if (found) {
      cur.sessions = kept
      this.slotsRev += 1
      this.refreshStatus()
      this.persist()
    }
  }

  /** 查询 pane 的会话槽(当前 tab;未绑定 null)。 */
  sessionOf(paneId: string): SessionSlot | null {
    const cur = this.curTabOrNull()
    if (cur === null) {
      return null
    }
    for (const s of cur.sessions) {
      if (s.paneId === paneId) {
        return s
      }
    }
    return null
  }

  /** 当前 tab 绑定数(状态栏 sess N 派生源)。 */
  sessionCount(): number {
    const cur = this.curTabOrNull()
    return cur === null ? 0 : cur.sessions.length
  }

  /** pane 标题(绑定时 slot.title 非空优先,否则 kind;未绑定回 paneId)。
   *  纯查询:PaneSurface 标题表达式读 vm.slotsRev 建立追踪后调此方法。 */
  sessionTitle(paneId: string): string {
    const s = this.sessionOf(paneId)
    if (s === null) {
      return paneId
    }
    return s.title !== '' ? s.title : s.kind
  }

  /** 当前 tab(无有效 tab 时 null)。 */
  private curTabOrNull(): TabState | null {
    if (this.activeTab >= 0 && this.activeTab < this.tabs.length) {
      return this.tabs[this.activeTab]
    }
    return null
  }

  /** 联动清理:剔除 sessions 中 paneId 已不在当前树的槽(closePane 后调)。 */
  private pruneSessions(): void {
    const cur = this.curTabOrNull()
    if (cur === null) {
      return
    }
    let changed = false
    const kept: SessionSlot[] = []
    for (const s of cur.sessions) {
      if (this.panes.indexOf(s.paneId) >= 0) {
        kept.push(s)
      } else {
        changed = true
      }
    }
    if (changed) {
      cur.sessions = kept
      this.slotsRev += 1
      this.refreshStatus()
    }
  }

  /** SSH 连接选择浮层开关(M6a;>1 条 ssh profile 时 palette 打开)。 */
  sshPickerOpen: boolean = false

  // ===================== 远程终端会话(M6a,单会话) =====================

  /** 焦点 pane 挂 SSH 远程会话。返回 true 仅代表已发起(connect 异步补判,
   *  失败经 RemoteTermHost.onDead 异步清 slot);store 未就绪/无记录 → false。 */
  bindSshSession(connKey: string): boolean {
    const paneId = this.focusedPane
    if (paneId === '') {
      return false
    }
    if (RemoteTermHost.bound() === paneId) {
      this.focusPane(paneId)
      return true // 幂等(同 bindLocalSession 语义)
    }
    // 单会话互斥:远程已绑他 pane → 先解绑;本地在跑 → 让位(provider 兜底)
    if (RemoteTermHost.bound() !== '') {
      this.unbindSession(RemoteTermHost.bound())
      RemoteTermHost.stop()
    }
    if (TermHost.bound() !== '') {
      this.unbindTerm()
    }
    if (!RemoteTermHost.start(connKey, 80, 24)) {
      return false
    }
    RemoteTermHost.bind(paneId)
    this.bindSession(paneId, 'ssh', connKey, 'ssh ' + this.sshConnName(connKey))
    this.termTick += 1
    // M6b:发起反馈('连接中';成败由 onOpen/onDead 异步覆写——成功
    // 'ssh 已连接',失败带原因前 60 字)。此处覆写 refreshStatus 文案可接受:
    // 布局/会话计数经后续 sync 重组,连接反馈为瞬时态。
    this.statusText = 'ssh 连接中…'
    return true
  }

  /** 连接名查询(store 内存态;查不到回 connKey)。只读,不 load()。 */
  private sshConnName(connKey: string): string {
    const store = getSharedStore()
    if (store === null) {
      return connKey
    }
    for (const c of store.connections) {
      if (c.id === connKey) {
        return c.name !== '' ? c.name : connKey
      }
    }
    return connKey
  }

  /** 结束远程会话(stop 内部关句柄;slot 清 + termTick)。 */
  unbindRemote(): void {
    const wasBound = RemoteTermHost.bound()
    RemoteTermHost.stop()
    if (wasBound !== '') {
      this.unbindSession(wasBound)
    }
    this.termTick += 1
  }

  /** 最近一次远程错误摘要(M6b:live-ssh 反馈;前 60 字,无错回 '')。
   *  纯查询 RemoteTermHost.lastError,不重连不碰句柄。 */
  remoteErrorBrief(): string {
    const e = RemoteTermHost.lastError
    return e.length > 60 ? e.substring(0, 60) : e
  }

  // ===================== 本地终端会话(M3a,单会话) =====================

  /** 焦点 pane 起本地 shell。规则(任务书):已绑定本 pane → 聚焦即可(幂等);
   *  已绑定他 pane → 先解绑旧 pane 再绑新;PTY 启动失败 → false 不动状态。 */
  bindLocalSession(): boolean {
    const paneId = this.focusedPane
    if (paneId === '') {
      return false
    }
    if (TermHost.bound() === paneId) {
      this.focusPane(paneId)
      return true
    }
    if (TermHost.bound() !== '') {
      this.unbindSession(TermHost.bound())
    }
    if (!TermHost.start(80, 24)) {
      return false
    }
    TermHost.bind(paneId)
    this.bindSession(paneId, 'local', '', 'local shell')
    this.termTick += 1
    // statusText 由 bindSession→refreshStatus 统一组装(panes · focus · sess N),
    // 此处不覆写——保留布局与焦点信息(验收判据:状态栏含 sess 1)
    return true
  }

  /** 结束本地会话:PTY 关 + 绑定 pane 的 slot 清 + termTick 驱动水印回归。
   *  M6a:同时结束远程会话(session.end 语义=全停,双宿主幂等)。 */
  unbindTerm(): void {
    const wasBound = TermHost.bound()
    TermHost.stop()
    if (wasBound !== '') {
      this.unbindSession(wasBound) // 内部 refreshStatus:sess 计数归零
    }
    this.unbindRemote()
  }

  /** 绑定 pane 已不在当前树 → 回收 PTY/远程会话 + 清 slot(布局收缩后统一
   *  调用;M6a 起双宿主各查各的 bound)。 */
  private reapTermIfGone(): void {
    const b = TermHost.bound()
    if (b !== '' && this.panes.indexOf(b) < 0) {
      TermHost.stop()
      this.unbindSession(b)
      this.termTick += 1
    }
    const rb = RemoteTermHost.bound()
    if (rb !== '' && this.panes.indexOf(rb) < 0) {
      RemoteTermHost.stop()
      this.unbindSession(rb)
      this.termTick += 1
    }
  }

  // ===================== 布局(M1c) =====================

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

  /** 关闭 pane(close 内建焦点迁移与父层折叠;联动清理被删 pane 的会话槽)。 */
  closePane(id: string): void {
    this.syncFromLayout(LayoutOps.close(this.layout, id))
    this.pruneSessions()
    this.reapTermIfGone() // M3a:被删 pane 持有 PTY → 回收
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

  // ===================== Tab(M2a) =====================

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
    this.reapTermIfGone() // M3a:新 active 树无绑定 pane → 回收 PTY
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

  // ===================== 面板/杂项(M1d) =====================

  /** RightPanel 开关(桩)。 */
  toggleRightPanel(): void {
    this.rightPanelOpen = !this.rightPanelOpen
    this.statusText = this.rightPanelOpen ? 'Agent 面板开' : 'Agent 面板关'
  }

  /** 右面板页签切换(+tty7-M7a:RightPanel pill 点击与 palette 命令
   *  共用;值经 drawerTabOf 白名单归一)。 */
  setRightTab(tab: string): void {
    this.rightTab = tab
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
