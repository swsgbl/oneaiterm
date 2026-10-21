/**
 * 界面国际化基座(GUI-i18n,2026-10-21 用户指令:多语言界面)。
 *
 * 机制:
 *  - 词典:zh-CN 全量(基准)/ en-US(允许缺键→回退 zh);
 *  - 查找:tr(locale, key) —— 当前词典 → zh 词典 → key 原样(永不炸);
 *  - 反应式:组件 @StorageProp('ut.locale') + build 内 tr(this.locale, key),
 *    setLocale 写 AppStorage 即全局重渲(同 'ut.theme' 通道模式);
 *  - 非反应式(事件期文案):t(key) 直读 AppStorage;
 *  - 持久化:persistLocale 钩子由 Index 注入(filesDir/locale.txt),
 *    冷启读回并 applyLocale(检测系统语言只做缺省,用户选择永远优先)。
 * 纯函数区(localeOf/nextLocale/tr)为单测靶,零 UI import。
 */

/** 支持的语言列表(首个=缺省)。 */
export const LOCALES: string[] = ['zh-CN', 'en-US']

/** 归一化:en/en-us/EN → en-US;其余(含空/未知)→ zh-CN。 */
export function localeOf(raw: string): string {
  const l = raw.trim().toLowerCase()
  if (l === 'en' || l === 'en-us' || l === 'en_us') {
    return 'en-US'
  }
  return 'zh-CN'
}

/** 双语互切(列表内循环)。 */
export function nextLocale(cur: string): string {
  return localeOf(cur) === 'zh-CN' ? 'en-US' : 'zh-CN'
}

/** 语言显示名(语言切换命令/侧栏用)。 */
export function localeName(l: string): string {
  return localeOf(l) === 'zh-CN' ? '中文' : 'English'
}

const ZH: Record<string, string> = {
  // ===== 侧栏(标签+悬停提示) =====
  'sb.newWorkspace': '新建工作区',
  'sb.connections': '连接',
  'sb.git': 'Git',
  'sb.agent': 'Agent',
  'sb.theme': '切换主题',
  'sb.expand': '展开侧栏',
  'sb.collapse': '收起侧栏',
  'sb.tip.switchWs': '切换工作区',
  'sb.tip.new': '新建一个工作区',
  'sb.tip.conn': '打开连接档案管理(SSH/Telnet/收藏)',
  'sb.tip.git': '打开 Git 面板(状态/暂存/提交)',
  'sb.tip.agent': '打开 AI 智能体面板(事件流/审批)',
  'sb.tip.theme': '切换深色/浅色主题',
  'sb.settings': '设置',
  'sb.tip.settings': '打开设置(主题/语言/版本)',
  // ===== tab/状态/pane 占位 =====
  'tab.default': '终端',
  'status.ready': '就绪',
  'status.ended': '会话已结束',
  'status.nofocus': '无焦点 pane',
  'status.ptyfail': 'PTY 启动失败',
  'status.nobindsess': '无绑定会话(先新建本地/SSH 会话)',
  'status.sshconnecting': 'ssh 连接中…',
  'status.sshok': 'ssh 已连接',
  'status.telnetconnecting': 'telnet 连接中…',
  'status.telnetok': 'telnet 已连接',
  'status.wsnew': '新工作区',
  'status.wsswitch': '工作区',
  'status.wsclose': '关闭工作区,共',
  'status.tabnew': '新标签',
  'status.tabclose': '关闭标签,共',
  'status.done': '✓ 命令完成 · ',
  'pane.probing': 'ttyd 探测中…',
  'pane.waitwin': '等待窗口就绪…',
  'pane.degradedbusy': '降级路径(无 ttyd)单实例占用;web 架构为主',
  'term.unreach': 'ttyd 不可达',
  'term.check': '检查 ttyd 服务(27681 端口)',
  'palette.placeholder': '输入命令...',
  // ===== 引导(GUI-guide 五步) =====
  'guide.t0': '欢迎来到一站AI终端',
  'guide.d0': 'SSH / 本地终端 / 数据库 / 远程桌面,一个应用全搞定。接下来 4 步带你认识工作台。',
  'guide.t1': '终端即开即用',
  'guide.d1': '打开应用就是活终端:点击终端区直接输入;Ctrl+K(或底部 ⌘)打开命令面板,所有功能一键直达。',
  'guide.t2': '左侧栏:展开与收起',
  'guide.d2': '点左上角箭头可展开侧栏查看功能名称;收起后悬停图标会弹出功能提示。',
  'guide.t3': '多窗格与多标签',
  'guide.d3': '命令面板「分屏」可左右/上下拆分窗格;顶部可开多标签,各自独立布局。',
  'guide.t4': '右侧 AI 面板与设置',
  'guide.d4': '✦ 打开 AI 智能体面板:自然语言驱动终端,连接档案与文件传输也在右侧。主题、语言等在左下角 ⚙ 设置里。',
  'guide.prev': '上一步',
  'guide.skip': '跳过',
  'guide.next': '下一步',
  'guide.finish': '开始使用',
  // ===== palette 命令(label=key,渲染端 tr) =====
  'cmd.split.h': '分屏 · 左右',
  'cmd.split.v': '分屏 · 上下',
  'cmd.pane.close': '关闭焦点 pane',
  'cmd.pane.zoom': '缩放焦点 pane',
  'cmd.tab.new': '新建标签',
  'cmd.tab.close': '关闭当前标签',
  'cmd.panel.ai': 'AI · 打开面板',
  'cmd.panel.git': 'Git · 打开面板',
  'cmd.panel.conn': '连接 · 管理档案',
  'cmd.session.local': '会话 · 新建本地',
  'cmd.session.ssh': '会话 · SSH 连接',
  'cmd.tunnel.start': '隧道 · 启动(默认 9432→远程3306)',
  'cmd.tunnel.stop': '隧道 · 停止',
  'cmd.tunnel.status': '隧道 · 状态',
  'cmd.session.end': '会话 · 结束',
  'cmd.session.telnet': '会话 · Telnet 连接',
  'cmd.ws.new': '工作区 · 新建',
  'cmd.cli.status': 'CLI · 桥状态',
  'cmd.term.search': '搜索 · 终端',
  'cmd.theme.toggle': '切换主题',
  'cmd.git.commit': 'Git · 提交',
  'cmd.help.guide': '帮助 · 使用指引',
  'cmd.help.language': '语言 · Language',
  'cmd.settings': '设置 · Settings',
  // ===== 设置面板(GUI-R2) =====
  'set.title': '设置',
  'set.theme': '主题',
  'set.theme.dark': '深色',
  'set.theme.light': '浅色',
  'set.language': '语言',
  'set.bridge': 'CLI 桥',
  'set.version': '版本',
  'set.done': '完成',
  // ===== GUI 丝滑棒:空态/toast/确认/字号 =====
  'pane.empty.hint': '此窗格还没有会话',
  'pane.empty.local': '新建本地',
  'pane.empty.ssh': 'SSH 连接',
  'pane.empty.palette': '命令面板',
  'toast.ended': '会话已结束',
  'toast.localbound': '本地会话已就绪',
  'toast.sshok': 'ssh 已连接',
  'toast.font': '终端字号已调整(Ctrl+Shift+0 重置)',
  'toast.fontreset': '终端字号已重置',
  'confirm.close.title': '关闭确认',
  'confirm.close.msg': '该窗格有正在运行的会话,关闭将结束它',
  'confirm.close.tabMsg': '该标签有正在运行的会话,关闭将结束它们',
  'confirm.close.cancel': '取消',
  'confirm.close.ok': '关闭',
  'cmd.view.fontup': '视图 · 字号增大',
  'cmd.view.fontdown': '视图 · 字号减小',
  'cmd.view.fontreset': '视图 · 字号重置',
  // ===== 深层面板 EN 补齐(GUI 收官棒) =====
  'panel.empty.events': '暂无事件;输入任务后此处实时显示 Agent 事件流',
  'ev.allow': '允许',
  'ev.deny': '拒绝',
  'conn.dlg.new': '新建连接',
  'conn.dlg.edit': '编辑连接',
  'conn.save': '保存',
  'conn.cancel': '取消',
  'conn.f.name': '名称',
  'conn.f.type': '类型',
  'conn.f.host': '主机',
  'conn.f.port': '端口',
  'conn.f.user': '用户名',
  'conn.f.pass': '密码(留空=不修改)',
  'conn.ph.name': '如 我的服务器',
  'conn.ph.host': 'host 或 IP',
  'conn.row.connect': '连',
  'conn.row.edit': '编',
  'conn.row.del': '删',
  'conn.empty': '暂无连接档案;点「新建」添加(旧界面导入的档案自动出现)',
  'conn.del.confirm': '确认删除「',
  'conn.del.confirm2': '」?',
  'conn.del.ok': '确认删除',
  'conn.new': '＋ 新建',
  // ===== GUI-R3:界面字号档 + AI 模型配置 =====
  'set.fontsize': '界面字号',
  'set.font.small': '小',
  'set.font.normal': '标准',
  'set.font.large': '大',
  'set.font.xl': '特大',
  'ai.title': 'AI 模型配置',
  'ai.provider': '供应商',
  'ai.openai': 'OpenAI 兼容',
  'ai.baseUrl': '服务地址(Base URL)',
  'ai.apiKey': 'API 密钥',
  'ai.model': '模型名',
  'ai.save': '保存',
  'ai.saved': 'AI 配置已保存',
  'ai.savefail': '保存失败',
  'ai.hint': '本地引擎(右侧 ✦ 面板选「本地」)用此配置直连模型;密钥仅存本机 llm_config.json。',
  // ===== GUI-R3:反馈与支持 / 检查更新 =====
  'fb.title': '反馈与支持',
  'fb.issue': '问题反馈 · 打开 Issues',
  'fb.star': '给项目点个 Star ⭐',
  'fb.copydiag': '复制诊断信息',
  'fb.copied': '诊断信息已复制',
  'upd.title': '更新',
  'upd.check': '检查更新',
  'upd.checking': '检查中…',
  'upd.latest': '已是最新版本',
  'upd.found': '发现新版本',
  'upd.fail': '检查失败(网络不可达)',
  'upd.auto': '启动时自动检查',
  'upd.repo': '到仓库发布页下载',
  // 单测靶:en 刻意缺键,验证 tr 回退链(当前→zh→key)
  'test.zhoneonly': '仅中文值'
}

const EN: Record<string, string> = {
  'sb.newWorkspace': 'New workspace',
  'sb.connections': 'Connect',
  'sb.git': 'Git',
  'sb.agent': 'Agent',
  'sb.theme': 'Theme',
  'sb.expand': 'Expand sidebar',
  'sb.collapse': 'Collapse sidebar',
  'sb.tip.switchWs': 'Switch workspace',
  'sb.tip.new': 'Create a new workspace',
  'sb.tip.conn': 'Open connection profiles (SSH/Telnet/favorites)',
  'sb.tip.git': 'Open Git panel (status/stage/commit)',
  'sb.tip.agent': 'Open AI agent panel (events/approvals)',
  'sb.tip.theme': 'Toggle dark/light theme',
  'sb.settings': 'Settings',
  'sb.tip.settings': 'Open settings (theme/language/version)',
  'tab.default': 'Terminal',
  'status.ready': 'Ready',
  'status.ended': 'Session ended',
  'status.nofocus': 'No focused pane',
  'status.ptyfail': 'Failed to start PTY',
  'status.nobindsess': 'No bound session (create a local/SSH session first)',
  'status.sshconnecting': 'ssh connecting…',
  'status.sshok': 'ssh connected',
  'status.telnetconnecting': 'telnet connecting…',
  'status.telnetok': 'telnet connected',
  'status.wsnew': 'New workspace',
  'status.wsswitch': 'Workspace',
  'status.wsclose': 'Closed workspace, total',
  'status.tabnew': 'New tab',
  'status.tabclose': 'Closed tab, total',
  'status.done': '✓ Command done · ',
  'pane.probing': 'Probing ttyd…',
  'pane.waitwin': 'Waiting for window…',
  'pane.degradedbusy': 'Degraded path (no ttyd) is single-instance; web is primary',
  'term.unreach': 'ttyd unreachable',
  'term.check': 'Check the ttyd service (port 27681)',
  'palette.placeholder': 'Type a command...',
  'guide.t0': 'Welcome to OneAI Terminal',
  'guide.d0': 'SSH / local terminal / database / remote desktop — one app for all. Four quick steps to get oriented.',
  'guide.t1': 'Terminal, ready out of the box',
  'guide.d1': 'A live terminal greets you on launch. Click and type. Ctrl+K (or the ⌘ at the bottom) opens the command palette.',
  'guide.t2': 'Sidebar: expand and collapse',
  'guide.d2': 'Click the arrow at the top to expand the sidebar and see feature names. When collapsed, hovering an icon shows a tooltip.',
  'guide.t3': 'Panes and tabs',
  'guide.d3': 'Use "Split" in the palette to split panes horizontally or vertically. Open multiple tabs, each with its own layout.',
  'guide.t4': 'AI panel & settings',
  'guide.d4': '✦ opens the AI agent panel: drive the terminal in natural language. Theme, language and more live in ⚙ Settings at the bottom left.',
  'guide.prev': 'Back',
  'guide.skip': 'Skip',
  'guide.next': 'Next',
  'guide.finish': 'Get started',
  'cmd.split.h': 'Split · Horizontal',
  'cmd.split.v': 'Split · Vertical',
  'cmd.pane.close': 'Close focused pane',
  'cmd.pane.zoom': 'Zoom focused pane',
  'cmd.tab.new': 'New tab',
  'cmd.tab.close': 'Close current tab',
  'cmd.panel.ai': 'AI · Open panel',
  'cmd.panel.git': 'Git · Open panel',
  'cmd.panel.conn': 'Connections · Manage profiles',
  'cmd.session.local': 'Session · New local',
  'cmd.session.ssh': 'Session · SSH connect',
  'cmd.tunnel.start': 'Tunnel · Start (default 9432→remote 3306)',
  'cmd.tunnel.stop': 'Tunnel · Stop',
  'cmd.tunnel.status': 'Tunnel · Status',
  'cmd.session.end': 'Session · End',
  'cmd.session.telnet': 'Session · Telnet connect',
  'cmd.ws.new': 'Workspace · New',
  'cmd.cli.status': 'CLI · Bridge status',
  'cmd.term.search': 'Search · Terminal',
  'cmd.theme.toggle': 'Toggle theme',
  'cmd.git.commit': 'Git · Commit',
  'cmd.help.guide': 'Help · Show guide',
  'cmd.help.language': '语言 · Language',
  'cmd.settings': '设置 · Settings',
  'set.title': 'Settings',
  'set.theme': 'Theme',
  'set.theme.dark': 'Dark',
  'set.theme.light': 'Light',
  'set.language': 'Language',
  'set.bridge': 'CLI bridge',
  'set.version': 'Version',
  'set.done': 'Done',
  'pane.empty.hint': 'No session in this pane yet',
  'pane.empty.local': 'New local',
  'pane.empty.ssh': 'SSH connect',
  'pane.empty.palette': 'Palette',
  'toast.ended': 'Session ended',
  'toast.localbound': 'Local session ready',
  'toast.sshok': 'ssh connected',
  'toast.font': 'Terminal font adjusted (Ctrl+Shift+0 to reset)',
  'toast.fontreset': 'Terminal font reset',
  'confirm.close.title': 'Close confirmation',
  'confirm.close.msg': 'This pane has a running session; closing will end it',
  'confirm.close.tabMsg': 'This tab has running sessions; closing will end them',
  'confirm.close.cancel': 'Cancel',
  'confirm.close.ok': 'Close',
  'cmd.view.fontup': 'View · Font larger',
  'cmd.view.fontdown': 'View · Font smaller',
  'cmd.view.fontreset': 'View · Font reset',
  'panel.empty.events': 'No events yet; type a task to see the live agent event stream',
  'ev.allow': 'Allow',
  'ev.deny': 'Deny',
  'conn.dlg.new': 'New connection',
  'conn.dlg.edit': 'Edit connection',
  'conn.save': 'Save',
  'conn.cancel': 'Cancel',
  'conn.f.name': 'Name',
  'conn.f.type': 'Type',
  'conn.f.host': 'Host',
  'conn.f.port': 'Port',
  'conn.f.user': 'Username',
  'conn.f.pass': 'Password (empty = keep)',
  'conn.ph.name': 'e.g. my-server',
  'conn.ph.host': 'host or IP',
  'conn.row.connect': 'Go',
  'conn.row.edit': 'Edit',
  'conn.row.del': 'Del',
  'conn.empty': 'No profiles yet; click "New" to add (imported profiles appear automatically)',
  'conn.del.confirm': 'Delete "',
  'conn.del.confirm2': '"?',
  'conn.del.ok': 'Delete',
  'conn.new': '＋ New',
  'set.fontsize': 'UI font size',
  'set.font.small': 'Small',
  'set.font.normal': 'Normal',
  'set.font.large': 'Large',
  'set.font.xl': 'X-Large',
  'ai.title': 'AI model settings',
  'ai.provider': 'Provider',
  'ai.openai': 'OpenAI-compatible',
  'ai.baseUrl': 'Base URL',
  'ai.apiKey': 'API key',
  'ai.model': 'Model',
  'ai.save': 'Save',
  'ai.saved': 'AI settings saved',
  'ai.savefail': 'Save failed',
  'ai.hint': 'The local engine (pick "Local" in the ✦ panel) connects to your model with these settings; the key is stored locally in llm_config.json.',
  'fb.title': 'Feedback & support',
  'fb.issue': 'Report an issue · open Issues',
  'fb.star': 'Star the project ⭐',
  'fb.copydiag': 'Copy diagnostics',
  'fb.copied': 'Diagnostics copied',
  'upd.title': 'Update',
  'upd.check': 'Check for updates',
  'upd.checking': 'Checking…',
  'upd.latest': 'You are up to date',
  'upd.found': 'New version available',
  'upd.fail': 'Check failed (network unreachable)',
  'upd.auto': 'Auto-check on launch',
  'upd.repo': 'Open the releases page',
}

function dictOf(locale: string): Record<string, string> {
  return localeOf(locale) === 'en-US' ? EN : ZH
}

/** 查找:当前词典 → zh 词典 → key(纯函数,单测靶)。 */
export function tr(locale: string, key: string): string {
  const d = dictOf(locale)
  const v = d[key]
  if (v !== undefined) {
    return v
  }
  const z = ZH[key]
  return z !== undefined ? z : key
}

/** 当前 locale(AppStorage;非 UI 上下文安全,缺省 zh-CN)。 */
export function curLocale(): string {
  const v = AppStorage.get<string>('ut.locale')
  return v === undefined ? 'zh-CN' : localeOf(v)
}

/** 非反应式查找(事件期文案,如 setStatus)。 */
export function t(key: string): string {
  return tr(curLocale(), key)
}

/** 持久化钩子(Index 注入 filesDir 写;null=未接线只存内存)。 */
let persistHook: ((l: string) => void) | null = null

export function bindPersistLocale(fn: ((l: string) => void) | null): void {
  persistHook = fn
}

/** 仅应用(AppStorage;冷启回放持久值,不触发持久化钩子)。 */
export function applyLocale(l: string): string {
  const loc = localeOf(l)
  AppStorage.setOrCreate('ut.locale', loc)
  return loc
}

/** 切换语言:AppStorage 全局重渲 + 持久化钩子。 */
export function setLocale(l: string): string {
  const loc = localeOf(l)
  AppStorage.setOrCreate('ut.locale', loc)
  const fn = persistHook
  if (fn !== null) {
    try {
      fn(loc)
    } catch (e) {
      // 持久化失败不阻塞会话内切换
    }
  }
  return loc
}
