/**
 * tty7 tab pill 行(任务 tty7-M1b,顶 28px)。
 * 读 Vm.tabs:active 高亮(brand pill),每 pill 带 × 关闭钮,行尾 + 新建钮。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppIcons } from '../../common/AppIcons';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct TabBar {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  @State hoverClose: number = -1

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Scroll() {
      Row({ space: 2 }) {
        ForEach(this.vm.tabs, (title: string, idx: number) => {
          Row({ space: 4 }) {
            Text(title)
              .fontSize(DesignTokens.FONT_CAPTION)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 120 })
              .fontColor(this.vm.activeTab === idx ? this.th().surface : this.th().inkSubtle)
            // × 关闭钮(至少 1 个 tab 时才可关)
            Text(this.vm.tabs.length > 1 ? AppIcons.OP_DELETE : ' ')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.hoverClose === idx ? this.th().danger
                : (this.vm.activeTab === idx ? this.th().surface : this.th().inkSubtle))
              .width(16)
              .height(16)
              .textAlign(TextAlign.Center)
              .borderRadius(DesignTokens.RADIUS_SM)
              .onClick(() => this.vm.closeTab(idx))
              .onHover((h: boolean) => {
                this.hoverClose = h ? idx : -1
              })
          }
          .height(22)
          .padding({ left: 10, right: 6 })
          .borderRadius(DesignTokens.RADIUS_LG)
          .backgroundColor(this.vm.activeTab === idx ? this.th().brand : this.th().panel)
          .border({ width: 1, color: this.vm.activeTab === idx ? this.th().brand : this.th().hairline })
          .alignItems(VerticalAlign.Center)
          .margin({ left: 2, right: 2 })
          .onClick(() => this.vm.setActiveTab(idx))
        }, (title: string, idx: number) => title + '#' + idx.toString())
        // + 新建钮
        Text(AppIcons.OP_ADD)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().iconMuted)
          .width(22)
          .height(22)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_LG)
          .backgroundColor(this.th().panel)
          .border({ width: 1, color: this.th().hairline })
          .margin({ left: 4 })
          .accessibilityText('新建 pane(左右分)')
          .onClick(() => this.vm.newPane('h'))
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(28)
    .padding({ left: DesignTokens.SPACE_SM, right: DesignTokens.SPACE_SM })
    .align(Alignment.Start)
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { bottom: 1 }, color: this.th().hairline })
  }
}
