/**
 * ApprovalCard 审批卡组件（升级 Phase 4 / 任务 5.3，design 1.1.3-G）。
 *
 * 消费 need_approval 事件，展示档位徽标 + 命令摘要（脱敏）+ 超时倒计时；
 * 独立于终端工作区弹出（不遮挡终端操作）；
 * 用户决策经 AgentProvider.approve 回传（spec 5.5.1.3）。
 * 审批卡即时呈现（不延迟到执行后，spec 4.1.2）；
 * 拒绝/超时后操作不执行且审计记录。
 */
import { AppTheme, themeByName } from '../common/AppTheme';
import { TimingConstants } from '../common/TimingConstants';
import { DesignTokens } from '../common/DesignTokens';
import {
  AgentAdapter
} from '../agent/AgentAdapter';
import {
  ApprovalView,
  CapabilityLevel
} from '../agent/AgentProvider';

/** 档位徽标颜色映射。 */
function levelColor(level: CapabilityLevel, th: AppTheme): number {
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

/** 档位中文标签。 */
function levelLabel(level: CapabilityLevel): string {
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

@Component
export struct ApprovalCard {
  @StorageProp('ut.theme') themeName: string = 'dark'
  @State visible: boolean = false
  @State toolName: string = ''
  @State argsDigest: string = ''
  @State level: CapabilityLevel = 'read_only'
  @State requestId: string = ''
  @State sessionId: string = ''
  @State timeoutAt: number = 0
  @State countdown: number = 0
  private timerId: number = -1

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 显示审批卡（由 AIDock/AiPanel 在收到 need_approval 事件时调用）。 */
  show(view: ApprovalView, sid: string): void {
    this.visible = true
    this.toolName = view.toolName
    this.argsDigest = view.argsDigest
    this.level = view.level
    this.requestId = view.requestId
    this.sessionId = sid
    this.timeoutAt = view.timeoutAt
    this.startCountdown()
  }

  /** 隐藏审批卡。 */
  hide(): void {
    this.visible = false
    this.stopCountdown()
  }

  private startCountdown(): void {
    this.stopCountdown()
    this.updateCountdown()
    this.timerId = setInterval(() => {
      this.updateCountdown()
      if (this.countdown <= 0) {
        this.hide()
      }
    }, TimingConstants.APPROVAL_COUNTDOWN_MS)
  }

  private stopCountdown(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
  }

  private updateCountdown(): void {
    const remaining = Math.max(0, Math.floor((this.timeoutAt - Date.now()) / 1000))
    this.countdown = remaining
  }

  private approve(): void {
    AgentAdapter.instance().approve(this.sessionId, this.requestId, 'approved')
    this.hide()
  }

  private deny(): void {
    AgentAdapter.instance().approve(this.sessionId, this.requestId, 'denied')
    this.hide()
  }

  aboutToDisappear(): void {
    this.stopCountdown()
  }

  build() {
    if (this.visible) {
      Row({ space: 10 }) {
        // 档位徽标
        Text(levelLabel(this.level))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().surface)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(DesignTokens.RADIUS_SM)
          .backgroundColor(levelColor(this.level, this.th()))

        // 工具名 + 参数摘要
        Column({ space: 2 }) {
          Text('⚙ ' + this.toolName)
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().brand)
          Text(this.argsDigest)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 倒计时
        if (this.countdown > 0) {
          Text(Math.floor(this.countdown / 60) + ':' + (this.countdown % 60).toString().padStart(2, '0'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.countdown < 60 ? this.th().danger : this.th().inkSubtle)
        }

        // 决策按钮
        Row({ space: 8 }) {
          Text('允许')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().onSuccess)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().success)
            .accessibilityText('允许执行')
            .onClick(() => this.approve())
          Text('拒绝')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().onDanger)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().danger)
            .accessibilityText('拒绝执行')
            .onClick(() => this.deny())
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.th().surfaceRaised)
      .border({ width: 1, color: levelColor(this.level, this.th()) })
      .borderRadius(DesignTokens.RADIUS_MD)
      .shadow({ radius: DesignTokens.SHADOW_MD_RADIUS, color: DesignTokens.SHADOW_MD_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_MD_OFFSET_Y })
      .transition(TransitionEffect.OPACITY.animation({ duration: DesignTokens.DURATION_FAST }))
    } else {
      Row()
        .width('100%')
        .height(0)
        .transition(TransitionEffect.OPACITY.animation({ duration: DesignTokens.DURATION_FAST }))
    }
  }
}