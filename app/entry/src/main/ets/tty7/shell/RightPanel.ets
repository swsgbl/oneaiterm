/**
 * tty7 右侧上下文抽屉(任务 tty7-M1d,Agent 面板桩)。
 * M1d 仅骨架:标题行 + 状态点 + 会话/审批占位;M5 接 HMH Provider 真数据。
 * 红线:零业务 import(不 import service/PTY/SSH/AI),只消费 WorkbenchVm。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct RightPanel {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Column() {
      // 标题行:Agent + 在线状态点(agentOnline 桩,M5 接真状态)
      Row({ space: DesignTokens.SPACE_SM }) {
        Text('Agent')
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().ink)
        Blank()
        Circle({ width: 7, height: 7 })
          .fill(this.vm.agentOnline ? this.th().success : this.th().inkSubtle)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: DesignTokens.SPACE_MD,
        right: DesignTokens.SPACE_MD,
        top: DesignTokens.SPACE_MD,
        bottom: DesignTokens.SPACE_SM
      })
      .border({ width: { bottom: 1 }, color: this.th().hairline })

      // 正文占位(M5:Agent 会话流)
      Column() {
        Text('Agent 会话 (M5)')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 底部占位(M5:审批流)
      Text('审批流 (M5)')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
        .border({ width: { top: 1 }, color: this.th().hairline })
    }
    .width(300)
    .height('100%')
    .backgroundColor(this.th().panel)
    .border({ width: { left: 1 }, color: this.th().hairline })
  }
}
