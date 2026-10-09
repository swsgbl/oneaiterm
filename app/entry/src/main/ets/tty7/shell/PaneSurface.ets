/**
 * tty7 pane 面组件(任务 tty7-M1c,升级自 M1b PanePlaceholder)。
 * 结构:标题行(paneId + zoom 钮 + 关闭钮)+ 内容区(M1c 阶段为 paneId
 * 大字水印;M3 接 Terminal Core 时仅替换内容区)。
 * 交互:点击=focusPane;关闭钮=closePane;zoom 钮回调 onZoom(由 PaneGrid
 * 绑定 vm.zoomToggle)。焦点叶 brand 2px 高亮边框。零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AppIcons } from '../../common/AppIcons';

@Component
export struct PaneSurface {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  paneId: string = ''
  /** zoom 切换回调(PaneGrid 绑定;组件自身不持有 zoom 语义)。 */
  onZoom: () => void = () => {
  }
  @State hoverClose: boolean = false

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Column() {
      // 标题行:paneId + zoom 钮(◎)+ 关闭钮(×)
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(this.paneId)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .layoutWeight(1)
          .fontColor(this.vm.focusedPane === this.paneId ? this.th().brand : this.th().inkSubtle)
        Text('◎')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().iconMuted)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText(this.paneId + ' 缩放切换')
          .onClick(() => {
            this.vm.focusPane(this.paneId)
            this.onZoom()
          })
        Text(AppIcons.OP_DELETE)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.hoverClose ? this.th().danger : this.th().inkSubtle)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText('关闭 ' + this.paneId)
          .onClick(() => this.vm.closePane(this.paneId))
          .onHover((h: boolean) => {
            this.hoverClose = h
          })
      }
      .width('100%')
      .height(20)
      .padding({ left: DesignTokens.SPACE_SM, right: DesignTokens.SPACE_SM })
      .alignItems(VerticalAlign.Center)

      // 内容区:M1c 大字水印,M3 换 Terminal Core
      Column() {
        Text(this.paneId)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().inkSubtle)
          .opacity(0.55)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().panel)
    .borderRadius(DesignTokens.RADIUS_MD)
    .border({
      width: this.vm.focusedPane === this.paneId ? 2 : 1,
      color: this.vm.focusedPane === this.paneId ? this.th().brand : this.th().hairline
    })
    .onClick(() => this.vm.focusPane(this.paneId))
  }
}
