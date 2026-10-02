// AppIcons — 统一图标常量模块
export class AppIcons {
  // 连接类型图标
  static readonly CONN_SSH: string = '⌗'
  static readonly CONN_LOCAL: string = '▤'
  static readonly CONN_RDP: string = '▣'
  static readonly CONN_VNC: string = '◫'
  static readonly CONN_K8S: string = '☸'
  static readonly CONN_DB: string = '⬮'
  static readonly CONN_TELNET: string = '∿'
  static readonly CONN_SPICE: string = '◈'

  // 功能面板图标
  static readonly PANEL_CONNECTIONS: string = '⌗'
  static readonly PANEL_FILES: string = '▤'
  static readonly PANEL_MONITOR: string = '∿'
  static readonly PANEL_TUNNEL: string = '⇄'
  static readonly PANEL_QUICK: string = '⚡'
  static readonly PANEL_HISTORY: string = '◷'
  static readonly PANEL_WORKSPACE: string = '◈'

  // 命令栏图标
  static readonly CMD_AI: string = '✦'
  static readonly CMD_SETTINGS: string = '⚙'
  static readonly CMD_SPLIT: string = '⬜'
  static readonly CMD_SEARCH: string = '🔍'

  // Tab 图标
  static readonly TAB_START: string = '⌂'
  static readonly TAB_SFTP: string = '▦'
  static readonly TAB_SETTINGS: string = '⚙'
  static readonly TAB_TERMINAL: string = '▸'

  // 审批档位标签
  static readonly LEVEL_DESTRUCTIVE: string = '危险'
  static readonly LEVEL_REMOTE: string = '远端'
  static readonly LEVEL_TERMINAL: string = '终端'
  static readonly LEVEL_WORKSPACE_WRITE: string = '写入'
  static readonly LEVEL_READ_ONLY: string = '只读'

  // 操作图标
  static readonly OP_RUN: string = '▶'
  static readonly OP_DELETE: string = '×'
  static readonly OP_ADD: string = '+'
  static readonly OP_EDIT: string = '✎'
  static readonly OP_APPROVE: string = '✓'
  static readonly OP_DENY: string = '✗'
}