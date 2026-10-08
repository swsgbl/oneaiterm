/**
 * tty7 底部状态栏(任务 tty7-M1b,底 22px)。
 * 左:Vm.statusText;右:pane 计数 + 焦点 pane id。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct StatusBar {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Row({ space: DesignTokens.SPACE_MD }) {
      Text(this.vm.statusText)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
      Blank()
      Text('panes ' + this.vm.panes.length.toString())
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
      Text('focus ' + (this.vm.focusedPane !== '' ? this.vm.focusedPane : '-'))
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.vm.focusedPane !== '' ? this.th().ink : this.th().inkSubtle)
    }
    .width('100%')
    .height(22)
    .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { top: 1 }, color: this.th().hairline })
  }
}
