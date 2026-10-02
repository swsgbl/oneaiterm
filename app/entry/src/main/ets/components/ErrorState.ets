(// ErrorState — 错误状态展示组件
import { AppTheme, themeByName } from '../common/AppTheme'
import { DesignTokens } from '../common/DesignTokens'

@Component
export struct ErrorState {
  @Prop icon: string = '✗'
  @Prop title: string = '出错了'
  @Prop description: string = ''
  @Prop retryLabel: string = '重试'
  onRetry: () => void = () => {}
  @StorageProp('ut.theme') themeName: string = 'dark'

  private th(): AppTheme { return themeByName(this.themeName) }

  build() {
    Column({ space: DesignTokens.SPACE_MD }) {
      Text(this.icon)
        .fontSize(DesignTokens.FONT_DISPLAY * 2)
        .fontColor(this.th().danger)
      Text(this.title)
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().danger)
      if (this.description !== '') {
        Text(this.description)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
      }
      Text(this.retryLabel)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().onDanger)
        .padding({ left: DesignTokens.SPACE_LG, right: DesignTokens.SPACE_LG, top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().danger)
        .onClick(() => this.onRetry())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: DesignTokens.SPACE_LG, right: DesignTokens.SPACE_LG })
  }
}