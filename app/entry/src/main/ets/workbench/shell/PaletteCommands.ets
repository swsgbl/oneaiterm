/**
 * 命令面板注册表(任务 M1d,纯函数表,便于单测)。
 *
 * 红线:注册表保持纯——AppStorage 主题读取放 run 内,不污染表构造;
 * 所有 run 均为同步轻操作(只调 WorkbenchVm 纯状态方法),不阻塞 UI。
 * WorkbenchVm 属 viewmodel,非业务 service import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { t, setLocale, nextLocale, curLocale, localeName } from '../../common/AppI18n';
import { getSharedStore, ConnRec } from '../../store/ConnStore';
import { ensureSharedStore } from '../remote/ConnStoreBootstrap';
import { CommandBridge } from '../bridge/CommandBridge';
import { TunnelService } from '../../service/TunnelService';

/** 面板命令项:key 唯一;run 同步轻操作。 */
export interface PaletteCmd {
  key: string
  label: string
  run: (vm: WorkbenchVm) => void
}

/** 命令注册表(每次调用返回新数组,消费方不可缓存共享引用)。 */
/** 隧道规格解析(纯;单测靶):localPort:remoteHost:remotePort;
 * 端口 1-65535、主机非空才合法;返回 null=非法。 */
export class TunnelSpec {
  localPort: number = 0
  remoteHost: string = ' '
  remotePort: number = 0
}

export function parseTunnelSpec(raw: string): TunnelSpec | null {
  const parts = raw.split(':')
  if (parts.length !== 3) {
    return null
  }
  const lp = Number(parts[0])
  const rp = Number(parts[2])
  const host = parts[1].trim()
  if (!(lp >= 1 && lp <= 65535) || !(rp >= 1 && rp <= 65535) || host.length === 0) {
    return null
  }
  const s = new TunnelSpec()
  s.localPort = lp
  s.remoteHost = host
  s.remotePort = rp
  return s
}

export function paletteCmds(): PaletteCmd[] {
  const cmds: PaletteCmd[] = []
  const splitH: PaletteCmd = {
    key: 'split.h',
    label: 'cmd.split.h',
    run: (vm: WorkbenchVm) => {
      vm.newPane('h')
    }
  }
  const splitV: PaletteCmd = {
    key: 'split.v',
    label: 'cmd.split.v',
    run: (vm: WorkbenchVm) => {
      vm.newPane('v')
    }
  }
  const closePane: PaletteCmd = {
    key: 'pane.close',
    label: 'cmd.pane.close',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane !== '') {
        vm.closePane(vm.focusedPane)
      }
    }
  }
  const zoom: PaletteCmd = {
    key: 'pane.zoom',
    label: 'cmd.pane.zoom',
    run: (vm: WorkbenchVm) => {
      vm.zoomToggle()
    }
  }
  const newTab: PaletteCmd = {
    key: 'tab.new',
    label: 'cmd.tab.new',
    run: (vm: WorkbenchVm) => {
      vm.newTab()
    }
  }
  const closeTab: PaletteCmd = {
    key: 'tab.close',
    label: 'cmd.tab.close',
    run: (vm: WorkbenchVm) => {
      vm.closeTab(vm.activeTab)
    }
  }
  const agentPanel: PaletteCmd = {
    key: 'panel.agent',
    label: 'cmd.panel.ai', // +M5a: palette 一键唤起 Agent 面板
    run: (vm: WorkbenchVm) => {
      vm.toggleRightPanel()
    }
  }
  // +M7a: Git 面板一键唤起——开抽屉 + 落 Git 页(rightTab 已提升
  // 为 vm 字段;已开时仅切页)
  const gitPanel: PaletteCmd = {
    key: 'panel.git',
    label: 'cmd.panel.git',
    run: (vm: WorkbenchVm) => {
      vm.setRightTab('git')
      if (!vm.rightPanelOpen) {
        vm.toggleRightPanel()
      }
    }
  }
  // +LEG-1: 连接档案管理一键唤起(旧 ConnList 功能面收拢的入口)
  const connPanel: PaletteCmd = {
    key: 'panel.conn',
    label: 'cmd.panel.conn',
    run: (vm: WorkbenchVm) => {
      vm.setRightTab('conn')
      if (!vm.rightPanelOpen) {
        vm.toggleRightPanel()
      }
    }
  }
  // M2b:会话挂接(M3a 起本地命令为真启动:焦点 pane 起单例 PTY shell)与工作区新建
  const sessionLocal: PaletteCmd = {
    key: 'session.new.local',
    label: 'cmd.session.local',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane === '') {
        vm.setStatus(t('status.nofocus'))
        return
      }
      if (!vm.bindLocalSession()) {
        vm.setStatus(t('status.ptyfail'))
      }
    }
  }
  // M6a:会话 · SSH 连接(store 未就绪/无 ssh profile → 状态栏提示;单条直连;
  // 多条打开选择浮层 vm.sshPickerOpen,WorkbenchPalette 渲染列表)
  const sessionSsh: PaletteCmd = {
    key: 'session.new.ssh',
    label: 'cmd.session.ssh',
    run: (vm: WorkbenchVm) => {
      // 2026-10-11 热修:工作台直启时旧界面未挂载,store 从未初始化——
      // 惰性引导(ConnStoreBootstrap,null 时最小 load,已有实例不动)
      const store = ensureSharedStore()
      if (store === null) {
        vm.setStatus('连接库未就绪(先在旧界面打开连接列表)')
        return
      }
      const ssh: ConnRec[] = []
      for (const c of store.connections) {
        if (c.type === 'ssh') {
          ssh.push(c)
        }
      }
      if (ssh.length === 0) {
        vm.setStatus('无保存的 SSH 连接(旧界面添加)')
        return
      }
      if (ssh.length === 1) {
        if (!vm.bindSshSession(ssh[0].id)) {
          vm.setStatus('SSH 会话发起失败')
        }
        return
      }
      vm.sshPickerOpen = true // >1:浮层选择(不关 palette 的关闭逻辑由浮层自管)
    }
  }
  // +LEG-3b: 隧道(-L)三命令——句柄源 SessionService(工作台 SSH 底层同源,
  // provider.open→SessionService.connect 实证);默认规格 ut.tunnel.spec
  // (缺省 9432:127.0.0.1:3306,M8-relay4 MySQL 场景);参数进阶走桥/CLI。
  const tunnelStart: PaletteCmd = {
    key: 'tunnel.start',
    label: 'cmd.tunnel.start',
    run: (vm: WorkbenchVm) => {
      const spec = parseTunnelSpec(AppStorage.get<string>('ut.tunnel.spec') ?? '9432:127.0.0.1:3306')
      if (spec === null) {
        vm.setStatus('隧道规格无效(local:host:remote)')
        return
      }
      vm.setStatus('隧道启动中 ' + spec.localPort + '→' + spec.remoteHost + ':' + spec.remotePort)
      TunnelService.start(spec.localPort, spec.remoteHost, spec.remotePort).then((): void => {
        vm.setStatus(TunnelService.active() ? '隧道已启动 :' + spec.localPort : '隧道启动失败(需先连 SSH)')
      })
    }
  }
  const tunnelStop: PaletteCmd = {
    key: 'tunnel.stop',
    label: 'cmd.tunnel.stop',
    run: (vm: WorkbenchVm) => {
      TunnelService.stop()
      vm.setStatus('隧道已停止')
    }
  }
  const tunnelStatus: PaletteCmd = {
    key: 'tunnel.status',
    label: 'cmd.tunnel.status',
    run: (vm: WorkbenchVm) => {
      if (TunnelService.active()) {
        vm.setStatus('隧道运行中 · 已转发 ' + TunnelService.totalForwarded() + ' 连接')
      } else {
        vm.setStatus('隧道未运行')
      }
    }
  }
  const sessionEnd: PaletteCmd = {
    key: 'session.end',
    label: 'cmd.session.end',
    run: (vm: WorkbenchVm) => {
      vm.unbindTerm()
    }
  }
  // +LEG-2: Telnet 会话(单条直连;多条提示走连接面板;无档案提示)
  const sessionTelnet: PaletteCmd = {
    key: 'session.new.telnet',
    label: 'cmd.session.telnet',
    run: (vm: WorkbenchVm) => {
      const store = ensureSharedStore()
      if (store === null) {
        vm.setStatus('连接库未就绪(先在连接面板新建档案)')
        return
      }
      const tel: ConnRec[] = []
      for (const c of store.connections) {
        if (c.type === 'telnet') {
          tel.push(c)
        }
      }
      if (tel.length === 0) {
        vm.setStatus('无 telnet 档案(连接面板新建,type=Telnet)')
        return
      }
      if (tel.length === 1) {
        if (!vm.bindTelnetSession(tel[0].id)) {
          vm.setStatus('telnet 会话发起失败')
        }
        return
      }
      vm.setRightTab('conn')
      if (!vm.rightPanelOpen) {
        vm.toggleRightPanel()
      }
      vm.setStatus('多条 telnet 档案——连接面板选择')
    }
  }
  const wsNew: PaletteCmd = {
    key: 'ws.new',
    label: 'cmd.ws.new',
    run: (vm: WorkbenchVm) => {
      vm.newWorkspace()
    }
  }
  // +M8a: CLI 桥状态(纯展示:running+port 写状态栏)
  const cliStatus: PaletteCmd = {
    key: 'cli.status',
    label: 'cmd.cli.status',
    run: (_vm: WorkbenchVm) => {
      if (CommandBridge.isRunning()) {
        const tp = CommandBridge.tokenPrefix()
        _vm.setStatus('CLI 桥运行中 · 127.0.0.1:18971' + (tp !== '' ? ' · token ' + tp + '…' : ''))
      } else {
        _vm.setStatus('CLI 桥未运行')
      }
    }
  }
  // +M3c: 终端搜索浮层——AppStorage 'ut.term.search' 单调 +1 信号,
  // 焦点 pane 的 TermPaneView 500ms 轮询侧开浮层(搜索态组件内,不进 vm)
  const termSearch: PaletteCmd = {
    key: 'term.search',
    label: 'cmd.term.search',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane === '') {
        vm.setStatus(t('status.nofocus'))
        return
      }
      const cur = AppStorage.get<number>('ut.term.search') ?? 0
      AppStorage.setOrCreate('ut.term.search', cur + 1)
      vm.setStatus('终端搜索:输入关键字回车,↑↓ 跳转,×/Esc 关闭')
    }
  }
  const themeToggle: PaletteCmd = {
    key: 'theme.toggle',
    label: 'cmd.theme.toggle',
    run: (_vm: WorkbenchVm) => {
      const cur = AppStorage.get<string>('ut.theme')
      AppStorage.setOrCreate('ut.theme', cur === 'light' ? 'dark' : 'light')
    }
  }
  cmds.push(splitH)
  cmds.push(splitV)
  cmds.push(closePane)
  cmds.push(zoom)
  cmds.push(newTab)
  cmds.push(closeTab)
  cmds.push(agentPanel)
  cmds.push(gitPanel) // +M7a: Git 页签唤起
  // +M7b: Git · 提交——开右面板落 Git 页 + 焦点信号投递(AppStorage
  // 'ut.git.focus' 单调 +1;GitBrowser 轮询侧 requestFocus 消息输入行)。
  // staged 判定不在 palette 侧(组件 @State 私有;无 staged 时输入行聚焦
  // 后提交钮自然禁用,statusText 提示由信号语义兜底)
  const gitCommit: PaletteCmd = {
    key: 'git.commit',
    label: 'cmd.git.commit',
    run: (vm: WorkbenchVm) => {
      vm.setRightTab('git')
      if (!vm.rightPanelOpen) {
        vm.toggleRightPanel()
      }
      const cur = AppStorage.get<number>('ut.git.focus') ?? 0
      AppStorage.setOrCreate('ut.git.focus', cur + 1)
      vm.setStatus('Git:输入提交消息(无已暂存条目时先暂存)')
    }
  }
  cmds.push(gitCommit) // +M7b
  cmds.push(sessionLocal)
  cmds.push(sessionSsh) // +M6a: pane 挂 SSH 远程会话
  cmds.push(sessionTelnet) // +LEG-2: pane 挂 Telnet 会话
  cmds.push(sessionEnd)
  cmds.push(wsNew)
  cmds.push(cliStatus) // +M8a
  cmds.push(termSearch) // +M3c: 终端搜索浮层信号
  cmds.push(themeToggle)
  cmds.push(connPanel) // +LEG-1: 连接档案管理面板
  cmds.push(tunnelStart) // +LEG-3b: 隧道三命令(启动/停止/状态)
  cmds.push(tunnelStop)
  cmds.push(tunnelStatus)
  // GUI 棒:帮助 · 使用指引(重开五步引导浮层;AppStorage 信号 Index 消费)
  const helpGuide: PaletteCmd = {
    key: 'help.guide',
    label: 'cmd.help.guide',
    run: (vm: WorkbenchVm) => {
      AppStorage.setOrCreate('ut.guide.show', true)
    }
  }
  // GUI 棒:语言切换(zh↔en 循环;setLocale 触发 AppStorage 'ut.locale'
  // 全局重渲 + Index 注入的持久化钩子)
  const helpLanguage: PaletteCmd = {
    key: 'help.language',
    label: 'cmd.help.language',
    run: (vm: WorkbenchVm) => {
      const next = setLocale(nextLocale(curLocale()))
      vm.setStatus(localeName(next))
    }
  }
  // 顶部置入(免滚动可达:palette 列表不自动滚到底)
  cmds.unshift(helpLanguage)
  cmds.unshift(helpGuide)
  return cmds
}
