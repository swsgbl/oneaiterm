/**
 * 底部状态栏(任务 M1b,底 22px)。
 * 左:Vm.statusText;右:pane 计数 + 焦点 pane id。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr } from '../../common/AppI18n';
import { fsc } from '../../common/UiFont';

@Component
export struct StatusBar {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Row({ space: DesignTokens.SPACE_MD }) {
      // ⌘ 命令面板钮(M1d):与 AppShell 顶行 ⌘ 同源(vm.paletteOpen)
      Text('⌘')
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontColor(this.th().iconMuted)
        .width(18)
        .height(16)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_SM)
        .accessibilityText('命令面板')
        .onClick(() => this.vm.togglePalette())
      // ⌨ 屏幕软键盘钮(R4g:点击式确定性输入;开=brand 高亮)
      Text('⌨')
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontColor(this.vm.softKbOpen ? this.th().brand : this.th().iconMuted)
        .width(18)
        .height(16)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_SM)
        .accessibilityText(tr(this.locale, 'sk.title'))
        .onClick(() => {
          this.vm.softKbOpen = !this.vm.softKbOpen
        })
      Text(this.vm.statusText)
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontColor(this.th().inkSubtle)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
      Blank()
      Text('panes ' + this.vm.panes.length.toString())
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontColor(this.th().inkSubtle)
      Text('focus ' + (this.vm.focusedPane !== '' ? this.vm.focusedPane : '-'))
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
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
