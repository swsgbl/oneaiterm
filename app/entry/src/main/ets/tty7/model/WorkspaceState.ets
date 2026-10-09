/**
 * tty7 工作区状态模型(任务 tty7-M2b,01 文档四级模型 Workspace→Tab→Pane→Session
 * 的顶层;Sidebar 图标列绑定的数据载体)。
 *
 * 设计约定:
 * - 纯数据:无方法、无 UI、无 service import;一切变换仍在 WorkbenchVm。
 * - 每 workspace 独立一套 tabs(各自独立布局树+会话槽);WorkbenchVm.tabs 为
 *   当前活动工作区 tabs 的同引用投影(切工作区整体替换引用,写路径不变)。
 * - glyph 取现有 AppIcons glyph 字符集内的值(此处本地常量,Vm 不 import UI 模块)。
 * - 持久化:WorkbenchStore v2 存档顶层即 WorkspaceState[](至少 1 个)。
 */
import { TabState } from './TabState';

/** 工作区:命名 + 图标 + tab 集 + 活动记忆。 */
export class WorkspaceState {
  /** 工作区标识('w'+自增,持久化保持稳定)。 */
  wsId: string = ''
  name: string = 'workspace'
  /** Sidebar 图标字符(现有 AppIcons glyph 集内取)。 */
  glyph: string = '◈'
  tabs: TabState[] = []
  activeTab: number = 0
}
