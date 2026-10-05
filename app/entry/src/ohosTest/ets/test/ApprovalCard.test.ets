/**
 * ApprovalCard 单元测试（补充任务 S1.3，ArkTS/hypium）。
 *
 * 纯函数复制 replicates ApprovalCard 中可测试的纯函数逻辑（dependency-free）。
 * 覆盖：
 *   1. 五档颜色映射（destructive/remote/terminal/workspace_write/read_only）
 *   2. 五档中文标签
 *   3. show/hide 状态设置
 *   4. updateCountdown 倒计时计算（正常/归零）
 *   5. approve/deny 决策回传
 * 关键约束：AppTheme 颜色字段为 number 类型，测试中用 number 值断言
 */
import { describe, it, expect } from '@ohos/hypium';

class TAppTheme {
  surface: number = 0
  surfaceRaised: number = 0
  panel: number = 0
  hover: number = 0
  ink: number = 0
  inkSubtle: number = 0
  brand: number = 0
  hairline: number = 0
  success: number = 0
  warn: number = 0
  danger: number = 0
  inputBg: number = 0
  iconMuted: number = 0
  iconStrong: number = 0
}

const DARK_THEME: TAppTheme = new TAppTheme()
DARK_THEME.surface = 0x0F1220
DARK_THEME.surfaceRaised = 0x1E2438
DARK_THEME.panel = 0x232A44
DARK_THEME.hover = 0x2A3252
DARK_THEME.ink = 0xE8EAF2
DARK_THEME.inkSubtle = 0x8a90a5
DARK_THEME.brand = 0xF5A524
DARK_THEME.hairline = 0x353D5E
DARK_THEME.success = 0x34d399
DARK_THEME.warn = 0xf59e0b
DARK_THEME.danger = 0xf87171
DARK_THEME.inputBg = 0x131729
DARK_THEME.iconMuted = 0x9aa2b8
DARK_THEME.iconStrong = 0xF2F4FA

type TLevel = 'read_only' | 'terminal' | 'workspace_write' | 'remote' | 'destructive'

function levelColor(level: TLevel, th: TAppTheme): number {
  if (level === 'destructive') {
    return th.danger
  }
  if (level === 'remote') {
    return th.warn
  }
  if (level === 'terminal') {
    return th.brand
  }
  if (level === 'workspace_write') {
    return th.success
  }
  return th.inkSubtle
}

function levelLabel(level: TLevel): string {
  if (level === 'destructive') {
    return '危险'
  }
  if (level === 'remote') {
    return '远端'
  }
  if (level === 'terminal') {
    return '终端'
  }
  if (level === 'workspace_write') {
    return '写入'
  }
  return '只读'
}

class TApprovalView {
  toolName: string = ''
  argsDigest: string = ''
  level: TLevel = 'read_only'
  requestId: string = ''
  timeoutAt: number = 0
}

class TCardState {
  visible: boolean = false
  toolName: string = ''
  argsDigest: string = ''
  level: TLevel = 'read_only'
  requestId: string = ''
  sessionId: string = ''
  timeoutAt: number = 0
  countdown: number = 0
  decision: string = ''
}

function showCard(state: TCardState, view: TApprovalView, sid: string): void {
  state.visible = true
  state.toolName = view.toolName
  state.argsDigest = view.argsDigest
  state.level = view.level
  state.requestId = view.requestId
  state.sessionId = sid
  state.timeoutAt = view.timeoutAt
}

function hideCard(state: TCardState): void {
  state.visible = false
}

function updateCountdown(state: TCardState, now: number): void {
  const remaining = Math.max(0, Math.floor((state.timeoutAt - now) / 1000))
  state.countdown = remaining
}

function approveCard(state: TCardState): void {
  state.decision = 'approved'
  state.visible = false
}

function denyCard(state: TCardState): void {
  state.decision = 'denied'
  state.visible = false
}

export default function approvalCardTest() {
  describe('approvalCardTest', () => {
    // ===== 五档颜色映射 =====
    it('approval_level_color_destructive', 0, () => {
      expect(levelColor('destructive', DARK_THEME) === DARK_THEME.danger).assertTrue()
      expect(levelColor('destructive', DARK_THEME) === 0xf87171).assertTrue()
    })

    it('approval_level_color_remote', 0, () => {
      expect(levelColor('remote', DARK_THEME) === DARK_THEME.warn).assertTrue()
      expect(levelColor('remote', DARK_THEME) === 0xf59e0b).assertTrue()
    })

    it('approval_level_color_terminal', 0, () => {
      expect(levelColor('terminal', DARK_THEME) === DARK_THEME.brand).assertTrue()
      expect(levelColor('terminal', DARK_THEME) === 0xF5A524).assertTrue()
    })

    it('approval_level_color_workspace_write', 0, () => {
      expect(levelColor('workspace_write', DARK_THEME) === DARK_THEME.success).assertTrue()
      expect(levelColor('workspace_write', DARK_THEME) === 0x34d399).assertTrue()
    })

    it('approval_level_color_read_only', 0, () => {
      expect(levelColor('read_only', DARK_THEME) === DARK_THEME.inkSubtle).assertTrue()
      expect(levelColor('read_only', DARK_THEME) === 0x8a90a5).assertTrue()
    })

    // ===== 五档中文标签 =====
    it('approval_level_label_destructive', 0, () => {
      expect(levelLabel('destructive') === '危险').assertTrue()
    })

    it('approval_level_label_remote', 0, () => {
      expect(levelLabel('remote') === '远端').assertTrue()
    })

    it('approval_level_label_terminal', 0, () => {
      expect(levelLabel('terminal') === '终端').assertTrue()
    })

    it('approval_level_label_workspace_write', 0, () => {
      expect(levelLabel('workspace_write') === '写入').assertTrue()
    })

    it('approval_level_label_read_only', 0, () => {
      expect(levelLabel('read_only') === '只读').assertTrue()
    })

    // ===== show/hide =====
    it('approval_show_sets_visible_true', 0, () => {
      const state = new TCardState()
      const view = new TApprovalView()
      view.toolName = 'term_write'
      view.argsDigest = 'touch f.txt'
      view.level = 'terminal'
      view.requestId = 'req-1'
      view.timeoutAt = Date.now() + 300000
      showCard(state, view, 'sess-1')
      expect(state.visible).assertTrue()
      expect(state.toolName === 'term_write').assertTrue()
      expect(state.argsDigest === 'touch f.txt').assertTrue()
      expect(state.level === 'terminal').assertTrue()
      expect(state.requestId === 'req-1').assertTrue()
      expect(state.sessionId === 'sess-1').assertTrue()
    })

    it('approval_hide_sets_visible_false', 0, () => {
      const state = new TCardState()
      state.visible = true
      hideCard(state)
      expect(!state.visible).assertTrue()
    })

    // ===== 倒计时 =====
    it('approval_countdown_calculation', 0, () => {
      const state = new TCardState()
      state.timeoutAt = Date.now() + 120000
      updateCountdown(state, Date.now())
      expect(state.countdown > 0).assertTrue()
      expect(state.countdown <= 120).assertTrue()
    })

    it('approval_countdown_zero', 0, () => {
      const state = new TCardState()
      state.timeoutAt = Date.now() - 5000
      updateCountdown(state, Date.now())
      expect(state.countdown === 0).assertTrue()
    })

    // ===== 决策回传 =====
    it('approval_approve_decision', 0, () => {
      const state = new TCardState()
      state.visible = true
      approveCard(state)
      expect(state.decision === 'approved').assertTrue()
      expect(!state.visible).assertTrue()
    })

    it('approval_deny_decision', 0, () => {
      const state = new TCardState()
      state.visible = true
      denyCard(state)
      expect(state.decision === 'denied').assertTrue()
      expect(!state.visible).assertTrue()
    })
  })
}