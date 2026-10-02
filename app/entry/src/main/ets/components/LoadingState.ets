// LoadingState — 加载状态展示组件
import { AppTheme, themeByName } from '../common/AppTheme'
import { DesignTokens } from '../common/DesignTokens'

@Component
export struct LoadingState {
  @Prop message: string = '加载中...'
  @StorageProp('ut.theme') themeName: string = 'dark'

  private th(): AppTheme { return themeByName(this.themeName) }

  build() {
    Column({ space: DesignTokens.SPACE_MD }) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(this.th().brand)
      Text(this.message)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().inkSubtle)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}