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
import {
  AgentAdapter, ApprovalView,
  CapabilityLevel
} from '../agent/AgentAdapter';

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
    }, 1000)
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
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().surface)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(levelColor(this.level, this.th()))

        // 工具名 + 参数摘要
        Column({ space: 2 }) {
          Text('⚙ ' + this.toolName)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().brand)
          Text(this.argsDigest)
            .fontSize(11)
            .fontColor(this.th().ink)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 倒计时
        if (this.countdown > 0) {
          Text(Math.floor(this.countdown / 60) + ':' + (this.countdown % 60).toString().padStart(2, '0'))
            .fontSize(10)
            .fontColor(this.countdown < 60 ? this.th().danger : this.th().inkSubtle)
        }

        // 决策按钮
        Row({ space: 8 }) {
          Text('允许')
            .fontSize(11)
            .fontColor(this.th().surface)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(6)
            .backgroundColor(this.th().success)
            .onClick(() => this.approve())
          Text('拒绝')
            .fontSize(11)
            .fontColor(this.th().surface)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(6)
            .backgroundColor(this.th().danger)
            .onClick(() => this.deny())
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.th().surfaceRaised)
      .border({ width: 1, color: levelColor(this.level, this.th()) })
      .borderRadius(8)
      .shadow({ radius: 16, color: '#88000000', offsetX: 0, offsetY: 4 })
    } else {
      Row()
        .width('100%')
        .height(0)
    }
  }
}