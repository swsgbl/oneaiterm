/**
 * tty7 pane 占位组件(任务 tty7-M1b)。
 * M1c 前的 pane 内容桩:显示 paneId + "pane (M1c)",点击切换焦点;
 * M1c 起被 XComponent 终端渲染替换,本组件保留作空槽回退。
 * 零业务 import(只 Vm + 主题 Token)。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct PanePlaceholder {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  paneId: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Column({ space: DesignTokens.SPACE_XS }) {
      Text(this.paneId)
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.vm.focusedPane === this.paneId ? this.th().brand : this.th().inkSubtle)
      Text('pane (M1c)')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
    .borderRadius(DesignTokens.RADIUS_MD)
    .border({
      width: 1,
      color: this.vm.focusedPane === this.paneId ? this.th().brand : this.th().hairline
    })
    .onClick(() => {
      this.vm.focusPane(this.paneId)
    })
  }
}
