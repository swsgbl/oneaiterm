// EmptyState — 空状态展示组件
import { AppTheme, themeByName } from '../common/AppTheme'
import { DesignTokens } from '../common/DesignTokens'

@Component
export struct EmptyState {
  @Prop icon: string = ''
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop actionLabel: string = ''
  onAction: () => void = () => {}
  @StorageProp('ut.theme') themeName: string = 'dark'

  private th(): AppTheme { return themeByName(this.themeName) }

  build() {
    Column({ space: DesignTokens.SPACE_MD }) {
      if (this.icon !== '') {
        Text(this.icon)
          .fontSize(DesignTokens.FONT_DISPLAY * 2)
          .fontColor(this.th().iconMuted)
      }
      if (this.title !== '') {
        Text(this.title)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
      }
      if (this.description !== '') {
        Text(this.description)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
      }
      if (this.actionLabel !== '') {
        Text(this.actionLabel)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().onBrand)
          .padding({ left: DesignTokens.SPACE_LG, right: DesignTokens.SPACE_LG, top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.th().brand)
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: DesignTokens.SPACE_LG, right: DesignTokens.SPACE_LG })
  }
}