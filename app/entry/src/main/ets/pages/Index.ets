// 一站AI终端(One AI Term)自有外壳 M6 relay2 布局①:
// 命令栏44px(品牌+坞折叠+搜索命令面板+AI/齿轮/分屏)+ TabsList pill 条(28px)
// + 左坞双态(56窄/200宽,宽态嵌 ConnList)+ 底部状态栏24px + 工作台首页(收藏pill+最近卡片)
// 红线: 全部 tab/conn/sftp/DB 组件与逻辑原样复用,只改外壳。
import { ConnectionStore, ConnRec, getSharedStore } from '../store/ConnStore';
import { ConnList } from './ConnList';
import { TerminalPage } from './TerminalPage';
import { SftpPanel } from './SftpPanel';
import { MonitorPanel } from '../components/MonitorPanel';
import { FileSidebar } from '../components/FileSidebar';
import { QuickCommandsPanel, HistoryPanel, PersonalizationPanel, TunnelPanel } from '../components/SidePanels';
import { SettingsTab } from '../components/SettingsTab';
import { RedisTab } from '../components/RedisTab';
import { K8sTab } from '../components/K8sTab';
import { PgTab } from '../components/PgTab';
import { MySqlTab } from '../components/MySqlTab';
import { VncTab } from '../components/VncTab';
import { RdpTab } from '../components/RdpTab';
import { SpiceTab } from '../components/SpiceTab';
import { themeByName, AppTheme } from '../common/AppTheme';
import { AIDock } from '../components/AIDock';
import { WantParams } from '../common/WantParams';
import { ToolsInstaller } from '../service/ToolsInstaller';
import { LocalTerminalService } from '../service/LocalTerminalService';
import { GuideOverlay } from '../components/GuideOverlay';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DesignTokens } from '../common/DesignTokens';
import { LayoutConstants } from '../common/LayoutConstants';
import { AppIcons } from '../common/AppIcons';

interface TabInfo {
  id: number
  name: string
  kind: string // start/terminal/sftp/settings/redis/k8s/pg/mysql/vnc/rdp/spice
  connId: string
}

// 命令面板条目(命令+连接混合,键盘上下/回车,鼠标点击)
interface PaletteItem {
  key: string
  icon: string
  label: string
  hint: string
  run: () => void
}

@Entry
@Component
struct Index {
  @State themeName: string = 'dark'
  @State sidebarVisible: boolean = true
  @State sideView: number = 0 // 0连接 1文件 2监控 3隧道 4快捷 5历史 6个性化
  @State tabs: TabInfo[] = [{ id: 0, name: '开始', kind: 'start', connId: '' }]
  @State activeTab: number = 0
  @State nextTabId: number = 1
  @State showSettingsMenu: boolean = false
  // M6 relay3: 底部 AI 智能体 Dock
  @State aiDockOpen: boolean = false
  @State splitTabId: number = -1 // 分屏右侧固定的标签(-1 关闭)
  @State searchText: string = ''
  // M6 relay2 布局①: 左坞双态(宽200 icon+文字 / 窄56 icon)
  @State dockWide: boolean = true
  // 命令面板(focus 搜索框展开)
  @State paletteFocus: boolean = false
  @State paletteSel: number = 0
  // M6 relay1 P0-6: 全局悬停态(hoverTip 记录当前悬停目标 id,驱动 tooltip + 图标高亮)
  @State hoverTip: string = ''
  @State hoverOn: boolean = false
  // M5 relay6 fix: th 原为 private 普通属性,applyTheme 重赋值不触发重渲染,
  // 主题切换从未真正生效(菜单高亮变、颜色不变)。改 @State 使颜色随主题刷新。
  @State th: AppTheme = themeByName('dark')
  private sideIcons: string[] = [AppIcons.PANEL_CONNECTIONS, AppIcons.PANEL_FILES, AppIcons.PANEL_MONITOR, AppIcons.PANEL_TUNNEL, AppIcons.PANEL_QUICK, AppIcons.PANEL_HISTORY, AppIcons.PANEL_WORKSPACE]
  private sideTips: string[] = ['连接', '文件', '监控', '隧道', '快捷命令', '历史', '工作台']
  private sideViewNames: string[] = ['连接', '文件', '监控', '隧道', '快捷命令', '历史', '工作台']
  // 状态栏: 当前连接名(活跃终端标签)
  @State statusConn: string = ''
  // relay4 C1: 首启引导浮层(filesDir/guide_done 存在则不再弹)
  @State guideShow: boolean = false
  @StorageLink('ut.openSftp') @Watch('onOpenSftp') openSftpSignal: string = ''
  @StorageLink('ut.closeTab') @Watch('onCloseTab') closeTabSignal: string = ''

  aboutToAppear(): void {
    this.applyTheme(this.themeName)
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const marker = ctx.filesDir + '/guide_done'
      let exists = false
      try {
        exists = fileIo.accessSync(marker)
      } catch (e2) {
        exists = false
      }
      if (!exists) {
        this.guideShow = true
      }
    } catch (e) {
      this.guideShow = true // 拿不到路径宁可弹(有跳过钮)
    }
    // M8-relay14 dev channel: --ps agentPrompt/--ps agentEngine
    if (WantParams.getAgentPrompt() !== '') {
      this.aiDockOpen = true
    }
    // --ps termCmd '<cmd>': 自动打开本地终端并注入命令(openLocalTerminal 内写 PTY)。
    // 延迟触发:aboutToAppear 时共享 store 尚未初始化,直接调用会早退(实测)。
    if (WantParams.getTermCmd() !== '') {
      setTimeout(() => {
        this.openLocalTerminal()
      }, 1500)
    }
  }

  onOpenSftp(): void {
    if (this.openSftpSignal !== '') {
      const connId = this.openSftpSignal
      this.openSftpSignal = ''
      this.openSftpTab(connId)
    }
    this.refreshStatusConn()
  }

  onCloseTab(): void {
    if (this.closeTabSignal !== '') {
      const closeId = this.closeTabSignal
      this.closeTabSignal = ''
      const t = this.tabs.find(x => x.connId === closeId)
      if (t !== undefined) {
        this.closeTab(t.id)
      }
    }
    this.refreshStatusConn()
  }

  applyTheme(name: string): void {
    animateTo({
      duration: DesignTokens.DURATION_NORMAL,
      curve: Curve.EaseInOut
    }, () => {
      this.themeName = name
      this.th = themeByName(name)
      AppStorage.setOrCreate('ut.theme', name)
    })
  }

  // relay4 C1: 引导完成/跳过 → 写标记文件,永不再弹
  finishGuide(): void {
    this.guideShow = false
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const f = fileIo.openSync(ctx.filesDir + '/guide_done',
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE)
      fileIo.writeSync(f.fd, 'done')
      fileIo.closeSync(f)
    } catch (e) {
      hilog.error(0x0110, 'oat.index', 'finishGuide write fail: %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  // ===== 命令面板数据源(命令 + 连接混合) =====
  paletteItems(): PaletteItem[] {
    const items: PaletteItem[] = []
    items.push({
      key: 'cmd.newconn', icon: AppIcons.OP_ADD, label: '新建连接', hint: '打开连接面板',
      run: () => { this.sideView = 0; this.sidebarVisible = true }
    })
    items.push({
      key: 'cmd.local', icon: AppIcons.CONN_LOCAL, label: '本地终端', hint: '开一个本地 shell 标签',
      run: () => this.openLocalTerminal()
    })
    items.push({
      key: 'cmd.settings', icon: AppIcons.CMD_SETTINGS, label: '设置', hint: '打开设置标签页',
      run: () => this.openSettingsTab()
    })
    items.push({
      key: 'cmd.theme.dark', icon: '●', label: '主题 · 暗色', hint: '深蓝紫底+琥珀',
      run: () => this.applyTheme('dark')
    })
    items.push({
      key: 'cmd.theme.light', icon: '●', label: '主题 · 浅色', hint: '暖白底+琥珀',
      run: () => this.applyTheme('light')
    })
    items.push({
      key: 'cmd.sftp', icon: AppIcons.TAB_SFTP, label: 'SFTP 文件传输', hint: '打开 SFTP 标签',
      run: () => this.openKindTab('sftp', 'SFTP')
    })
    items.push({
      key: 'cmd.pg', icon: AppIcons.CONN_DB, label: 'PostgreSQL', hint: '打开数据库标签',
      run: () => this.openKindTab('pg', 'PostgreSQL')
    })
    items.push({
      key: 'cmd.redis', icon: AppIcons.CONN_DB, label: 'Redis', hint: '打开数据库标签',
      run: () => this.openKindTab('redis', 'Redis')
    })
    items.push({
      key: 'cmd.mysql', icon: AppIcons.CONN_DB, label: 'MySQL', hint: '打开数据库标签',
      run: () => this.openKindTab('mysql', 'MySQL')
    })
    items.push({
      key: 'cmd.k8s', icon: AppIcons.CONN_K8S, label: 'K8s', hint: '打开集群标签',
      run: () => this.openKindTab('k8s', 'K8s')
    })
    items.push({
      key: 'cmd.vnc', icon: AppIcons.CONN_VNC, label: 'VNC', hint: '远程桌面',
      run: () => this.openKindTab('vnc', 'VNC')
    })
    items.push({
      key: 'cmd.rdp', icon: AppIcons.CONN_RDP, label: 'RDP', hint: '远程桌面',
      run: () => this.openKindTab('rdp', 'RDP')
    })
    items.push({
      key: 'cmd.spice', icon: AppIcons.CONN_SPICE, label: 'SPICE', hint: '远程桌面',
      run: () => this.openKindTab('spice', 'SPICE')
    })
    items.push({
      key: 'cmd.split', icon: AppIcons.CMD_SPLIT, label: '分屏', hint: '当前标签钉到右栏',
      run: () => this.toggleSplit()
    })
    items.push({
      key: 'cmd.tunnel', icon: AppIcons.PANEL_TUNNEL, label: '隧道', hint: '端口转发 -L',
      run: () => { this.sideView = 3; this.sidebarVisible = true }
    })
    // 连接: 按搜索词过滤
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const store = new ConnectionStore(ctx.filesDir)
      const kw = this.searchText.trim().toLowerCase()
      for (const c of store.connections) {
        const name = (c.name !== '' ? c.name : (c.user + '@' + c.host))
        if (kw !== '' && name.toLowerCase().indexOf(kw) < 0) {
          continue
        }
        items.push({
          key: 'conn.' + c.id, icon: this.cardIcon(c), label: name,
          hint: '打开终端连接',
          run: () => this.openConnTab(c.id)
        })
      }
    } catch (e) {
      hilog.error(0x0110, 'oat.index', 'paletteItems store read fail: %{public}s', e instanceof Error ? e.message : String(e));
    }
    return items
  }
  refreshStatusConn(): void {
    const t = this.tabs.find(x => x.id === this.activeTab)
    if (t !== undefined && t.kind === 'terminal') {
      this.statusConn = t.name
      return
    }
    const anyTerm = this.tabs.find(x => x.kind === 'terminal')
    if (anyTerm !== undefined) {
      this.statusConn = anyTerm.name
      return
    }
    this.statusConn = ''
  }

  activeTabKind(): string {
    const t = this.tabs.find(x => x.id === this.activeTab)
    return t !== undefined ? t.kind : 'start'
  }

  activeConnId(): string {
    const t = this.tabs.find(x => x.id === this.activeTab)
    return t !== undefined && (t.kind === 'terminal' || t.kind === 'sftp') ? t.connId : ''
  }

  addStartTab(): void {
    const id = this.nextTabId++
    this.tabs.push({ id: id, name: '开始', kind: 'start', connId: '' })
    this.activeTab = id
  }

  openConnTab(connId: string): void {
    const existing = this.tabs.find(t => t.kind === 'terminal' && t.connId === connId)
    if (existing !== undefined) {
      this.activeTab = existing.id
      return
    }
    let name = '终端'
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const store = new ConnectionStore(ctx.filesDir)
      const c = store.connections.find((x: ConnRec) => x.id === connId)
      if (c !== undefined) {
        name = c.name !== '' ? c.name : (c.user + '@' + c.host)
      }
    } catch (e) {
      hilog.error(0x0110, 'oat.index', 'openConnTab store read fail: %{public}s', e instanceof Error ? e.message : String(e));
    }
    const id = this.nextTabId++
    this.tabs.push({ id: id, name: name, kind: 'terminal', connId: connId })
    this.activeTab = id
  }

  toggleSplit(): void {
    const t = this.tabs.find(x => x.id === this.activeTab)
    if (t === undefined) {
      return
    }
    if (this.splitTabId === t.id) {
      this.splitTabId = -1
      return
    }
    if (t.kind === 'terminal') {
      return
    }
    this.splitTabId = t.id
  }

  splitTab(): TabInfo | null {
    if (this.splitTabId < 0) {
      return null
    }
    return this.tabs.find(x => x.id === this.splitTabId) ?? null
  }

  openKindTab(kind: string, name: string): void {
    const existing = this.tabs.find(t => t.kind === kind)
    if (existing !== undefined) {
      this.activeTab = existing.id
      return
    }
    const id = this.nextTabId++
    this.tabs.push({ id: id, name: name, kind: kind, connId: '' })
    this.activeTab = id
  }

  openSettingsTab(): void {
    this.openKindTab('settings', '设置')
  }

  // M5 relay4 fix(bug1): StartPane Local Terminal 的落点 — 确保 store 有
  // type=local 连接(共享实例,防解密态被磁盘密文覆盖)后开终端标签。
  openLocalTerminal(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    // M8 工具箱: 首开本地终端自动装配(rawfile/tools.zip → files/tools,后台解压
    // 不阻塞开终端;完成前 PATH 已含工具箱目录,下次会话或解压完成即生效)
    ToolsInstaller.ensure(ctx).then((err: string): void => {
      if (err !== '' && err !== 'busy') {
        hilog.warn(0x0110, 'oat.tools', 'auto-provision skip: %{public}s', err)
      }
    })
    const store = getSharedStore()
    if (store === null) {
      return
    }
    let local = store.connections.find((c: ConnRec) => c.type === 'local')
    if (local === undefined) {
      const c = new ConnRec()
      c.id = 'local-term-' + Date.now().toString(36)
      c.name = '本地终端'
      c.type = 'local'
      store.upsertConn(c)
      store.save()
      local = c
    }
    this.openConnTab(local.id)
    // 终端直写开发通道: --ps termCmd '<cmd>' —— 终端已无可见输入行(纯原生直输),
    // 自动化/联调经此注入命令(等 PTY 就绪后写入,最多等 30s)
    const termCmd = WantParams.getTermCmd()
    if (termCmd !== '') {
      hilog.info(0x0110, 'oat.termcmd', 'armed len=%{public}d', termCmd.length)
      let waited = 0
      const timerId = setInterval(() => {
        waited += 1000
        if (waited % 5000 === 0) {
          hilog.info(0x0110, 'oat.termcmd', 'tick w=%{public}d active=%{public}s', waited, LocalTerminalService.active() ? 'y' : 'n')
        }
        if (LocalTerminalService.active() || waited >= 30000) {
          clearInterval(timerId)
          if (LocalTerminalService.active()) {
            hilog.info(0x0110, 'oat.termcmd', 'fire len=%{public}d', termCmd.length)
            LocalTerminalService.write(termCmd + '\r')
          } else {
            hilog.warn(0x0110, 'oat.termcmd', 'giveup after 30s')
          }
        }
      }, 1000)
    }
  }

  openSftpTab(connId: string): void {
    const existing = this.tabs.find(t => t.kind === 'sftp' && t.connId === connId)
    if (existing !== undefined) {
      this.activeTab = existing.id
      return
    }
    const id = this.nextTabId++
    this.tabs.push({ id: id, name: 'SFTP', kind: 'sftp', connId: connId })
    this.activeTab = id
  }

  closeTab(id: number): void {
    if (this.tabs.length <= 1) {
      return
    }
    const idx = this.tabs.findIndex(t => t.id === id)
    this.tabs.splice(idx, 1)
    if (this.activeTab === id) {
      this.activeTab = this.tabs[Math.max(0, idx - 1)].id
    }
  }

  // ===== 命令栏图标钮(悬停高亮+tooltip) =====
  @Builder
  HeaderBtn(icon: string, tip: string, action: () => void) {
    Text(icon)
      .fontSize(DesignTokens.FONT_DISPLAY)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.hoverOn && this.hoverTip === tip ? this.th.brand : this.th.iconStrong)
      .width(30)
      .height(30)
      .textAlign(TextAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .margin({ left: 2, right: 2 })
      .backgroundColor(this.hoverOn && this.hoverTip === tip ? this.th.hover : Color.Transparent)
      .accessibilityText(tip)
      .onClick(() => action())
      .onHover((h: boolean) => {
        this.hoverTip = h ? tip : ''
        this.hoverOn = h
      })
      .bindPopup(this.hoverOn && this.hoverTip === tip, {
        message: tip,
        placementOnTop: true
      })
  }

  // ===== TabsList pill(28px 圆角卡片条,命令栏正下方) =====
  @Builder
  TabItem(t: TabInfo) {
    Row({ space: 5 }) {
      Text(t.kind === 'start' ? AppIcons.TAB_START : (t.kind === 'sftp' ? AppIcons.TAB_SFTP : (t.kind === 'settings' ? AppIcons.TAB_SETTINGS : AppIcons.TAB_TERMINAL)))
        .fontSize(DesignTokens.FONT_HEADING)
        .fontColor(t.id === this.activeTab ? this.th.surface : this.th.inkSubtle)
      Text(t.name)
        .fontSize(DesignTokens.FONT_BODY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(t.id === this.activeTab ? this.th.surface : this.th.inkSubtle)
        .constraintSize({ maxWidth: 180 })
      Stack() {
        Text(AppIcons.OP_DELETE)
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.hoverOn && this.hoverTip === ('close' + t.id.toString()) ? this.th.danger : (t.id === this.activeTab ? this.th.surface : this.th.inkSubtle))
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius(DesignTokens.RADIUS_SM)
      }
      .width(28)
      .height(24)
      .hitTestBehavior(HitTestMode.Default)
      .accessibilityText('关闭标签 ' + t.name)
      .onClick(() => this.closeTab(t.id))
      .onHover((h: boolean) => {
        this.hoverTip = h ? ('close' + t.id.toString()) : ''
        this.hoverOn = h
      })
      .bindPopup(this.hoverOn && this.hoverTip === ('close' + t.id.toString()), {
        message: '关闭标签 ' + t.name,
        placementOnTop: true
      })
    }
    .height(24)
    .constraintSize({ minWidth: 110 })
    .padding({ left: 10, right: 6 })
    .borderRadius(DesignTokens.RADIUS_LG)
    .backgroundColor(t.id === this.activeTab ? this.th.brand : this.th.panel)
    .border({ width: 1, color: t.id === this.activeTab ? this.th.brand : this.th.hairline })
    .margin({ left: 2, right: 2 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.activeTab = t.id
    })
  }

  // ===== 左坞图标钮(窄态56/宽态200 共用;宽态右侧带文字) =====
  @Builder
  DockIcon(idx: number) {
    Row({ space: 8 }) {
      Text(this.sideIcons[idx])
        .fontSize(DesignTokens.FONT_DISPLAY)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.sideView === idx ? this.th.surface : this.th.iconStrong)
        .width(LayoutConstants.DOCK_ICON_SIZE)
        .height(LayoutConstants.DOCK_ICON_SIZE)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
      if (this.dockWide) {
        Text(this.sideViewNames[idx])
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(this.sideView === idx ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.sideView === idx ? this.th.surface : this.th.inkSubtle)
          .layoutWeight(1)
      }
    }
    .height(32)
    .width(this.dockWide ? '100%' : 56)
    .padding({ left: this.dockWide ? 10 : 14 })
    .borderRadius(this.dockWide ? 8 : 6)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.sideView === idx ? this.th.brand : (this.hoverOn && this.hoverTip === ('side' + idx.toString()) ? this.th.hover : Color.Transparent))
    .onClick(() => {
      this.sideView = idx
      this.sidebarVisible = true
    })
    .onHover((h: boolean) => {
      this.hoverTip = h ? ('side' + idx.toString()) : ''
      this.hoverOn = h
    })
    .bindPopup(this.hoverOn && this.hoverTip === ('side' + idx.toString()) && !this.dockWide, {
      message: this.sideTips[idx],
      placementOnTop: true
    })
  }

  // ===== 工作台卡片辅助 =====
  cardMeta(c: ConnRec): string {
    if (c.type === 'local') return 'local';
    let s = c.user + '@' + c.host;
    if (c.port !== 22) s += ':' + c.port.toString();
    return s;
  }

  cardIcon(c: ConnRec): string {
    if (c.type === 'local') return AppIcons.CONN_LOCAL;
    if (c.type === 'rdp') return AppIcons.CONN_RDP;
    if (c.type === 'vnc') return AppIcons.CONN_VNC;
    if (c.type === 'k8s') return AppIcons.CONN_K8S;
    if (c.type === 'redis' || c.type === 'mysql' || c.type === 'pg') return AppIcons.CONN_DB;
    return AppIcons.CONN_SSH;
  }

  cardIconColor(c: ConnRec): string {
    if (c.type === 'local') return '#34d399';
    if (c.type === 'rdp') return '#60a5fa';
    return '#' + this.th.brand.toString(16).padStart(6, '0');
  }

  @Builder
  StartConnCard(c: ConnRec) {
    Row({ space: 10 }) {
      Text(this.cardIcon(c))
        .fontSize(DesignTokens.FONT_DISPLAY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cardIconColor(c))
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th.surfaceRaised)
      Column({ space: 2 }) {
        Text(c.name)
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.cardMeta(c))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th.inkSubtle)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(230)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(DesignTokens.RADIUS_LG)
    .backgroundColor(this.th.panel)
    .border({ width: 1, color: this.th.hairline })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (c.type === 'ssh') {
        this.openConnTab(c.id)
      }
    })
  }

  // ===== 工作台首页(收藏 pill 横排 + 最近连接卡片流 + 快速新建) =====
  @Builder
  StartPane() {
    Column() {
      Scroll() {
        Column() {
          // 收藏 pill 行(quickItems 范式: 一键直达)
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Text('▍')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.brand)
              Text('本地终端')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.ink)
            }
            .height(30)
            .padding({ left: 14, right: 14 })
            .borderRadius(DesignTokens.RADIUS_LG)
            .backgroundColor(this.th.panel)
            .border({ width: 1, color: this.th.hairline })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openLocalTerminal()
            })
            Text('PostgreSQL')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th.ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .onClick(() => {
                this.openKindTab('pg', 'PostgreSQL')
              })
            Text('Redis')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th.ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .onClick(() => {
                this.openKindTab('redis', 'Redis')
              })
            Text('MySQL')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th.ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .onClick(() => {
                this.openKindTab('mysql', 'MySQL')
              })
            Text('VNC')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th.ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .onClick(() => {
                this.openKindTab('vnc', 'VNC')
              })
            Text('RDP')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th.ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .onClick(() => {
                this.openKindTab('rdp', 'RDP')
              })
          }
          .margin({ top: 28, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          // 快速新建行
          Row({ space: 10 }) {
            Row({ space: 6 }) {
              Text(AppIcons.OP_ADD)
                .fontSize(DesignTokens.FONT_HEADING)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th.surface)
              Text('新建连接')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.surface)
            }
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th.brand)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.sideView = 0
              this.sidebarVisible = true
            })
            // M5 relay4 fix(bug1): Local Terminal 按钮原先无 onClick,点击无反应。
            Row({ space: 6 }) {
              Text(AppIcons.CONN_LOCAL)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.ink)
              Text('本地终端')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.ink)
            }
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th.panel)
            .border({ width: 1, color: this.th.hairline })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openLocalTerminal()
            })
          }
          .margin({ top: 8, bottom: 24 })
          .alignItems(VerticalAlign.Center)

          Text('最近连接')
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th.inkSubtle)
            .letterSpacing(1)
            .alignSelf(ItemAlign.Start)
            .margin({ left: 40, bottom: 10 })
          Column({ space: 10 }) {
            // relay4 C3: 空状态引导卡(替代单行文案)
            Column({ space: 8 }) {
              Text(AppIcons.OP_ADD)
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th.brand)
                .width(52)
                .height(52)
                .textAlign(TextAlign.Center)
                .borderRadius(26)
                .backgroundColor(this.th.surfaceRaised)
                .border({ width: 1, color: this.th.hairline })
              Text('新建第一个连接')
                .fontSize(DesignTokens.FONT_HEADING)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.th.ink)
              Text('连接一台远程主机,或直接开本地终端')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th.inkSubtle)
              Row({ space: 10 }) {
                Text('打开连接面板')
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th.surface)
                  .height(34)
                  .padding({ left: 18, right: 18 })
                  .borderRadius(DesignTokens.RADIUS_XL)
                  .backgroundColor(this.th.brand)
                  .onClick(() => {
                    this.sideView = 0
                    this.sidebarVisible = true
                  })
                Text('本地终端')
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th.ink)
                  .height(34)
                  .padding({ left: 18, right: 18 })
                  .borderRadius(DesignTokens.RADIUS_XL)
                  .backgroundColor(this.th.surfaceRaised)
                  .border({ width: 1, color: this.th.hairline })
                  .onClick(() => this.openLocalTerminal())
              }
              .alignItems(VerticalAlign.Center)
            }
            .padding({ top: 36, bottom: 36, left: 24, right: 24 })
            .borderRadius(DesignTokens.RADIUS_LG)
            .backgroundColor(this.th.panel)
            .border({ width: 1, color: this.th.hairline })
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 24 })
          }
          .width('100%')
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th.surface)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 命令面板下拉(focus 搜索框时展开;点击条目执行) =====
  @Builder
  PaletteRow(item: PaletteItem, idx: number) {
    Row({ space: 8 }) {
      Text(item.icon)
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.paletteSel === idx ? this.th.brand : this.th.iconStrong)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(item.label)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.paletteSel === idx ? this.th.ink : this.th.inkSubtle)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(item.hint)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th.inkSubtle)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(30)
    .padding({ left: 12, right: 12 })
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.paletteSel === idx ? this.th.hover : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.paletteFocus = false
      item.run()
    })
    .onHover((h: boolean) => {
      if (h) {
        this.paletteSel = idx
      }
    })
  }

  @Builder
  CommandPalette() {
    Column() {
      ForEach(this.paletteItems(), (item: PaletteItem, idx: number) => {
        this.PaletteRow(item, idx)
      }, (item: PaletteItem) => item.key + '.' + this.searchText)
    }
    .width(360)
    .constraintSize({ maxHeight: 300 })
    .padding(DesignTokens.SPACE_SM)
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.th.surfaceRaised)
    .border({ width: 1, color: this.th.hairline })
    .shadow({ radius: DesignTokens.SHADOW_LG_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_LG_OFFSET_Y })
    .position({ x: 210, y: 4 })
  }

  // ===== 设置下拉菜单(命令栏齿轮) =====
  @Builder
  SettingsMenu() {
    Column({ space: 1 }) {
      Text('主题')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th.inkSubtle)
        .padding({ left: 10, right: 10, top: 6, bottom: 4 })
        .alignSelf(ItemAlign.Start)
      ForEach(['dark', 'light'], (n: string) => {
        Text(n === 'dark' ? '● 暗色' : '● 浅色')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.themeName === n ? this.th.brand : this.th.ink)
          .padding({ left: 24, right: 10, top: 6, bottom: 6 })
          .borderRadius(DesignTokens.RADIUS_SM)
          .backgroundColor(this.themeName === n ? this.th.panel : Color.Transparent)
          .alignSelf(ItemAlign.Start)
          .onClick(() => this.applyTheme(n))
      }, (n: string) => n)
      Divider()
        .strokeWidth(1)
        .color(this.th.hairline)
        .margin({ top: 4, bottom: 4 })
      Text('设置')
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th.ink)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(DesignTokens.RADIUS_SM)
        .alignSelf(ItemAlign.Start)
        .onClick(() => {
          this.openSettingsTab()
          this.showSettingsMenu = false
        })
      Text('导入 / 导出')
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th.ink)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(DesignTokens.RADIUS_SM)
        .alignSelf(ItemAlign.Start)
        .onClick(() => {
          this.showSettingsMenu = false
          this.sideView = 0
          this.sidebarVisible = true
        })
      Text('关于')
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th.ink)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(DesignTokens.RADIUS_SM)
        .alignSelf(ItemAlign.Start)
        .onClick(() => {
          this.showSettingsMenu = false
          this.openSettingsTab()
        })
      Divider()
        .strokeWidth(1)
        .color(this.th.hairline)
        .margin({ top: 4, bottom: 4 })
      Text('Redis / K8s / PostgreSQL / MySQL / VNC / RDP / SPICE')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th.inkSubtle)
        .padding({ left: 10, right: 40, top: 4, bottom: 6 })
        .alignSelf(ItemAlign.Start)
    }
    .width(LayoutConstants.DOCK_WIDE_WIDTH)
    .padding(DesignTokens.SPACE_SM)
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.th.hover)
    .border({ width: 1, color: this.th.hairline })
    .position({ x: '78%', y: 4 })
    .shadow({ radius: DesignTokens.SHADOW_LG_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_LG_OFFSET_Y })
  }

  build() {
    Stack() {
      Column() {
      // ===== 命令栏(44px): 品牌 + 坞折叠钮 + 搜索命令面板 + AI/齿轮/分屏 =====
      Row() {
        Text('一站AI终端')
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th.brand)
          .margin({ left: 12, right: 4 })
        this.HeaderBtn(this.dockWide ? '«' : '»', this.dockWide ? '收起侧坞' : '展开侧坞', () => {
          this.dockWide = !this.dockWide
          this.sidebarVisible = true
        })
        this.HeaderBtn(AppIcons.PANEL_CONNECTIONS, '连接列表', () => {
          this.sideView = 0
          this.sidebarVisible = !this.sidebarVisible
        })
        // 搜索命令面板(focus 展开;失焦收起;回车执行选中项)
        Stack({ alignContent: Alignment.TopStart }) {
          TextInput({ placeholder: '搜索命令或连接...', text: this.searchText })
            .onChange((v: string) => {
              this.searchText = v
              this.paletteSel = 0
            })
            .onFocus(() => {
              this.paletteFocus = true
            })
            .onBlur(() => {
              this.paletteFocus = false
            })
            .onSubmit(() => {
              const items = this.paletteItems()
              if (items.length > 0) {
                const pick = items[Math.min(this.paletteSel, items.length - 1)]
                this.paletteFocus = false
                pick.run()
              }
            })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th.ink)
            .placeholderColor(this.th.inkSubtle)
            .height(30)
            .width(240)
            .backgroundColor(this.th.inputBg)
            .borderRadius(DesignTokens.RADIUS_MD)
            .padding({ left: 12, right: 12 })
            .underlineColor(Color.Transparent)
            .caretColor(this.th.brand)
          if (this.paletteFocus) {
            this.CommandPalette()
          }
        }
        .width(240)
        .height(30)
        Blank()
        this.HeaderBtn(AppIcons.CMD_SPLIT, '分屏', () => this.toggleSplit())
        // M6 relay3: 智能体 Dock 切换钮
        this.HeaderBtn('✧', '智能体', () => {
          this.aiDockOpen = !this.aiDockOpen
        })
        this.HeaderBtn(AppIcons.CMD_SETTINGS, '设置', () => {
          this.showSettingsMenu = !this.showSettingsMenu
        })
      }
      .width('100%')
      .height(LayoutConstants.CMD_BAR_HEIGHT)
      .padding({ left: 0, right: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.th.surfaceRaised)
      .border({ width: { bottom: 1 }, color: this.th.hairline })

      // ===== TabsList pill 条(28px,命令栏正下方,可横滚) =====
      Scroll() {
          Row({ space: 2 }) {
            ForEach(this.tabs, (t: TabInfo) => {
              this.TabItem(t)
            }, (t: TabInfo) => t.id.toString())
            Text(AppIcons.OP_ADD)
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th.iconMuted)
              .width(26)
              .height(26)
              .textAlign(TextAlign.Center)
              .borderRadius(DesignTokens.RADIUS_LG)
              .backgroundColor(this.th.panel)
              .border({ width: 1, color: this.th.hairline })
              .accessibilityText('新建标签')
              .onClick(() => this.addStartTab())
              .onHover((h: boolean) => {
                this.hoverTip = h ? 'newTab' : ''
                this.hoverOn = h
              })
              .bindPopup(this.hoverOn && this.hoverTip === 'newTab', {
                message: '新建开始标签页',
                placementOnTop: true
              })
          }
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(LayoutConstants.TAB_BAR_HEIGHT)
        .width('100%')
        .padding({ left: 12 })
        .margin({ top: 4, bottom: 4 })
        .backgroundColor(this.th.surfaceRaised)
        .border({ width: { top: 1, bottom: 1 }, color: this.th.hairline })

      // ===== 主体 =====
      Stack({ alignContent: Alignment.TopEnd }) {
        Row() {
          if (this.sidebarVisible) {
            Column() {
              // 坞顶: 视图切换 icon(双态)
              Column({ space: 2 }) {
                ForEach([0, 1, 2, 3, 4, 5, 6], (i: number) => {
                  this.DockIcon(i)
                }, (i: number) => i.toString() + (this.dockWide ? 'w' : 'n'))
              }
              .width('100%')
              .padding({ top: 8, bottom: 4 })

              // 宽态: 视图名 + 面板内容(连接视图嵌 ConnList)
              if (this.dockWide) {
                Text(this.sideViewNames[this.sideView])
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th.inkSubtle)
                  .letterSpacing(1)
                  .width('100%')
                  .padding({ left: 12, right: 10, top: 6, bottom: 6 })
                  .border({ width: { bottom: 1 }, color: this.th.hairline })
                  .margin({ bottom: 4 })

                if (this.sideView === 0) {
                  ConnList({
                    onOpenConn: (id: string) => {
                      this.openConnTab(id)
                    },
                    onNeedStore: (): ConnectionStore => {
                      const ctx = getContext(this) as common.UIAbilityContext
                      return new ConnectionStore(ctx.filesDir)
                    }
                  })
                    .layoutWeight(1)
                } else if (this.sideView === 1) {
                  FileSidebar()
                    .layoutWeight(1)
                } else if (this.sideView === 2) {
                  MonitorPanel()
                    .layoutWeight(1)
                } else if (this.sideView === 3) {
                  // M8 relay-3: 隧道面板(-L 端口转发)
                  TunnelPanel()
                    .layoutWeight(1)
                } else if (this.sideView === 4) {
                  QuickCommandsPanel()
                    .layoutWeight(1)
                } else if (this.sideView === 5) {
                  HistoryPanel()
                    .layoutWeight(1)
                } else if (this.sideView === 6) {
                  PersonalizationPanel({
                    onThemeChange: (t: string) => this.applyTheme(t)
                  })
                    .layoutWeight(1)
                } else if (this.sideView === 7) {
                  // M6 relay5: 工作台(补位,行为同 sideView=0 开始页)
                  ConnList({
                    onOpenConn: (id: string) => {
                      this.openConnTab(id)
                    },
                    onNeedStore: (): ConnectionStore => {
                      const ctx = getContext(this) as common.UIAbilityContext
                      return new ConnectionStore(ctx.filesDir)
                    }
                  })
                    .layoutWeight(1)
                } else {
                  Column() {
                    Text(this.sideTips[this.sideView])
                      .fontSize(DesignTokens.FONT_BODY)
                      .fontColor(this.th.inkSubtle)
                      .margin(DesignTokens.SPACE_LG)
                    Text('按官方路线图逐步开放')
                      .fontSize(DesignTokens.FONT_CAPTION)
                      .fontColor(this.th.inkSubtle)
                  }
                  .layoutWeight(1)
                  .width('100%')
                }
              } else {
                Blank()
              }
            }
            .width(this.dockWide ? 200 : 56)
            .height('100%')
            .backgroundColor(this.th.surface)
            .border({ width: { right: 1 }, color: this.th.hairline })
          }

          // 内容区:主栏 + 可选分屏右栏(relay4: 业务窗口外框 1px hairline+圆角,
          // 外层 Column 承载边框属性,内层保留 layoutWeight/height 链防塌缩)
          Row() {
            Column() {
              Column() {
              if (this.activeTabKind() === 'terminal') {
                TerminalPage({ connIdIn: this.activeConnId() })
              } else if (this.activeTabKind() === 'sftp') {
                SftpPanel({
                  connIdIn: this.activeConnId(),
                  onClose: () => {
                    const t = this.tabs.find(x => x.id === this.activeTab)
                    if (t !== undefined) {
                      this.closeTab(t.id)
                    }
                  }
                })
              } else if (this.activeTabKind() === 'settings') {
                SettingsTab({
                  onThemeChange: (t: string) => this.applyTheme(t)
                })
              } else if (this.activeTabKind() === 'redis') {
                RedisTab()
              } else if (this.activeTabKind() === 'k8s') {
                K8sTab()
              } else if (this.activeTabKind() === 'pg') {
                PgTab()
              } else if (this.activeTabKind() === 'mysql') {
                MySqlTab()
              } else if (this.activeTabKind() === 'vnc') {
                VncTab()
              } else if (this.activeTabKind() === 'rdp') {
                RdpTab()
              } else if (this.activeTabKind() === 'spice') {
                SpiceTab()
              } else {
                this.StartPane()
              }
              }
              .layoutWeight(1)
              .height('100%')
              .margin(DesignTokens.SPACE_SM)
              .borderRadius(DesignTokens.RADIUS_MD)
              .border({ width: 1, color: this.th.hairline })
              .clip(true)
              .backgroundColor(this.th.surface)
            }
            .layoutWeight(1)
            .height('100%')

            if (this.splitTab() !== null && this.splitTabId !== this.activeTab) {
              Column() {
                Column() {
                if (this.splitTab()!.kind === 'sftp') {
                  SftpPanel({
                    connIdIn: this.splitTab()!.connId,
                    onClose: () => {
                      this.splitTabId = -1
                    }
                  })
                } else if (this.splitTab()!.kind === 'settings') {
                  SettingsTab({
                    onThemeChange: (t: string) => this.applyTheme(t)
                  })
                } else {
                  this.StartPane()
                }
                }
                .layoutWeight(1)
                .height('100%')
                .margin(DesignTokens.SPACE_SM)
                .borderRadius(DesignTokens.RADIUS_MD)
                .border({ width: 1, color: this.th.hairline })
                .clip(true)
                .backgroundColor(this.th.surface)
              }
              .layoutWeight(1)
              .height('100%')
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')

        if (this.showSettingsMenu) {
          this.SettingsMenu()
        }
      }
      .layoutWeight(1)
      .width('100%')

      // ===== M6 relay3: AI 智能体 Dock(主体与状态栏之间) =====
      // 2026-10-07 对齐修复: dock 左缘与终端内容列对齐(左侧留出侧坞宽度),
      // 不再横跨全宽压在菜单栏上;输入框同步放大(AIDock 内)。
      if (this.aiDockOpen) {
        Row() {
          Row()
            .width(this.sidebarVisible
              ? (this.dockWide ? LayoutConstants.DOCK_WIDE_WIDTH : LayoutConstants.DOCK_NARROW_WIDTH)
              : 0)
          Column() {
            AIDock({
              autoPrompt: WantParams.getAgentPrompt(),
              autoEngine: WantParams.getAgentEngine()
            })
          }
          .layoutWeight(1)
        }
        .width('100%')
      }

      // ===== 底部状态栏(24px) =====
      Row({ space: 10 }) {
        Row({ space: 6 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.statusConn !== '' ? this.th.success : this.th.inkSubtle)
          Text(this.statusConn !== '' ? this.statusConn : '未连接')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.statusConn !== '' ? this.th.ink : this.th.inkSubtle)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 200 })
        }
        .alignItems(VerticalAlign.Center)

        Text('UTF-8')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th.inkSubtle)
        Text('v1.1.0')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th.inkSubtle)
        Blank()
        Text('一站AI终端 · One AI Term')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th.inkSubtle)
      }
      .width('100%')
      .height(24)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.th.surfaceRaised)
      .border({ width: { top: 1 }, color: this.th.hairline })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th.surface)

      if (this.guideShow) {
        GuideOverlay({ onFinish: () => this.finishGuide() })
      }
    }
    .width('100%')
    .height('100%')
  }
}

