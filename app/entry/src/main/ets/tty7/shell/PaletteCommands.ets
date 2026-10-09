/**
 * tty7 命令面板注册表(任务 tty7-M1d,纯函数表,便于单测)。
 *
 * 红线:注册表保持纯——AppStorage 主题读取放 run 内,不污染表构造;
 * 所有 run 均为同步轻操作(只调 WorkbenchVm 纯状态方法),不阻塞 UI。
 * WorkbenchVm 属 viewmodel,非业务 service import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';

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
    label: 'Agent 面板',
    run: (vm: WorkbenchVm) => {
      vm.toggleRightPanel()
    }
  }
  // M2b:会话挂接(本地元数据级,真会话 M3 接终端核)与工作区新建
  const sessionLocal: PaletteCmd = {
    key: 'session.new.local',
    label: '会话 · 新建本地',
    run: (vm: WorkbenchVm) => {
      if (vm.focusedPane !== '') {
        vm.bindSession(vm.focusedPane, 'local', '', 'local shell')
      }
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
  cmds.push(sessionLocal)
  cmds.push(wsNew)
  cmds.push(themeToggle)
  return cmds
}
