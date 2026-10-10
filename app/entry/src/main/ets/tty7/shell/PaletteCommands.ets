/**
 * tty7 命令面板注册表(任务 tty7-M1d,纯函数表,便于单测)。
 *
 * 红线:注册表保持纯——AppStorage 主题读取放 run 内,不污染表构造;
 * 所有 run 均为同步轻操作(只调 WorkbenchVm 纯状态方法),不阻塞 UI。
 * WorkbenchVm 属 viewmodel,非业务 service import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { getSharedStore, ConnRec } from '../../store/ConnStore';

/** 面板命令项:key 唯一;run 同步轻操作。 */
export interface PaletteCmd {
  key: string
  label: string
  run: (vm: WorkbenchVm) => void
}

/** 命令注册表(每次调用返回新数组,消费方不可缓存共享引用)。 */
export function paletteCmds(): PaletteCmd[] {
  const cmds: PaletteCmd[] = []
  const splitH: PaletteCmd = {
    key: 'split.h',
    label: '分屏 · 左右',
    run: (vm: WorkbenchVm) => {
      vm.newPane('h')
    }
  }
  const splitV: PaletteCmd = {
    key: 'split.v',
    label: '分屏 · 上下',
    run: (vm: WorkbenchVm) => {
      vm.newPane('v')
    }
  }
  const closePane: PaletteCmd = {
    key: 'pane.close',
    label: '关闭焦点 pane',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane !== '') {
        vm.closePane(vm.focusedPane)
      }
    }
  }
  const zoom: PaletteCmd = {
    key: 'pane.zoom',
    label: '缩放焦点 pane',
    run: (vm: WorkbenchVm) => {
      vm.zoomToggle()
    }
  }
  const newTab: PaletteCmd = {
    key: 'tab.new',
    label: '新建标签',
    run: (vm: WorkbenchVm) => {
      vm.newTab()
    }
  }
  const closeTab: PaletteCmd = {
    key: 'tab.close',
    label: '关闭当前标签',
    run: (vm: WorkbenchVm) => {
      vm.closeTab(vm.activeTab)
    }
  }
  const agentPanel: PaletteCmd = {
    key: 'panel.agent',
    label: 'AI · 打开面板', // +tty7-M5a: palette 一键唤起 Agent 面板
    run: (vm: WorkbenchVm) => {
      vm.toggleRightPanel()
    }
  }
  // +tty7-M7a: Git 面板一键唤起——开抽屉 + 落 Git 页(rightTab 已提升
  // 为 vm 字段;已开时仅切页)
  const gitPanel: PaletteCmd = {
    key: 'panel.git',
    label: 'Git · 打开面板',
    run: (vm: WorkbenchVm) => {
      vm.setRightTab('git')
      if (!vm.rightPanelOpen) {
        vm.toggleRightPanel()
      }
    }
  }
  // M2b:会话挂接(M3a 起本地命令为真启动:焦点 pane 起单例 PTY shell)与工作区新建
  const sessionLocal: PaletteCmd = {
    key: 'session.new.local',
    label: '会话 · 新建本地',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane === '') {
        vm.setStatus('无焦点 pane')
        return
      }
      if (!vm.bindLocalSession()) {
        vm.setStatus('PTY 启动失败')
      }
    }
  }
  // M6a:会话 · SSH 连接(store 未就绪/无 ssh profile → 状态栏提示;单条直连;
  // 多条打开选择浮层 vm.sshPickerOpen,WorkbenchPalette 渲染列表)
  const sessionSsh: PaletteCmd = {
    key: 'session.new.ssh',
    label: '会话 · SSH 连接',
    run: (vm: WorkbenchVm) => {
      const store = getSharedStore()
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
  const sessionEnd: PaletteCmd = {
    key: 'session.end',
    label: '会话 · 结束',
    run: (vm: WorkbenchVm) => {
      vm.unbindTerm()
    }
  }
  const wsNew: PaletteCmd = {
    key: 'ws.new',
    label: '工作区 · 新建',
    run: (vm: WorkbenchVm) => {
      vm.newWorkspace()
    }
  }
  const themeToggle: PaletteCmd = {
    key: 'theme.toggle',
    label: '切换主题',
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
  cmds.push(gitPanel) // +tty7-M7a: Git 页签唤起
  // +tty7-M7b: Git · 提交——开右面板落 Git 页 + 焦点信号投递(AppStorage
  // 'ut.git.focus' 单调 +1;GitBrowser 轮询侧 requestFocus 消息输入行)。
  // staged 判定不在 palette 侧(组件 @State 私有;无 staged 时输入行聚焦
  // 后提交钮自然禁用,statusText 提示由信号语义兜底)
  const gitCommit: PaletteCmd = {
    key: 'git.commit',
    label: 'Git · 提交',
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
  cmds.push(gitCommit) // +tty7-M7b
  cmds.push(sessionLocal)
  cmds.push(sessionSsh) // +tty7-M6a: pane 挂 SSH 远程会话
  cmds.push(sessionEnd)
  cmds.push(wsNew)
  cmds.push(themeToggle)
  return cmds
}
