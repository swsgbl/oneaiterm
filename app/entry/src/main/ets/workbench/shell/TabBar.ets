/**
 * tab pill 行(任务 M1b,顶 28px)。
 * 读 Vm.tabs:active 高亮(brand pill),每 pill 带 × 关闭钮,行尾 + 新建钮。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { TabState } from '../model/TabState';
import { AppIcons } from '../../common/AppIcons';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr } from '../../common/AppI18n';

@Component
export struct TabBar {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  @State hoverClose: number = -1
  @StorageProp('ut.locale') locale: string = 'zh-CN'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** GUI 丝滑棒:tab 内有活会话时关闭二次确认(防误杀整 tab 会话)。 */
  private closeWithConfirm(idx: number): void {
    const tab = this.vm.tabs[idx]
    if (tab === undefined || tab.sessions.length === 0) {
      this.vm.closeTab(idx)
      return
    }
    this.getUIContext().showAlertDialog({
      title: tr(this.locale, 'confirm.close.title'),
      message: tr(this.locale, 'confirm.close.tabMsg') + ' [' + tab.title + ']',
      primaryButton: {
        value: tr(this.locale, 'confirm.close.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: tr(this.locale, 'confirm.close.ok'),
        fontColor: this.th().danger,
        action: (): void => {
          this.vm.closeTab(idx)
        }
      },
      cancel: (): void => {
      }
    })
  }

  build() {
    Scroll() {
      Row({ space: 2 }) {
        ForEach(this.vm.tabs, (t: TabState, idx: number) => {
          Row({ space: 4 }) {
            Text(t.title)
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
              .onClick(() => this.closeWithConfirm(idx))
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
        }, (t: TabState, idx: number) => t.title + '#' + idx.toString())
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
