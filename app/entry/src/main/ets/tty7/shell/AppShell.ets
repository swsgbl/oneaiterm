/**
 * tty7 工作台整页外壳(任务 tty7-M1b,ADR-0001 ArkUI 同构壳)。
 * 非 @Entry 路由页——由宿主(Index/build 顶部 if shellMode)承载。
 * 布局:WorkspaceSidebar(左 44px) | 右 Column{ TabBar(28px) | PaneGrid 占位
 * layoutWeight(1) | StatusBar(22px) };RightPanel(M1d)预留 vm.rightPanelOpen。
 * 自带左上返回钮(onClose 回宿主)。深浅主题沿用 AppTheme/DesignTokens,零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { WorkspaceSidebar } from './WorkspaceSidebar';
import { TabBar } from './TabBar';
import { StatusBar } from './StatusBar';
import { PanePlaceholder } from './PanePlaceholder';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AppIcons } from '../../common/AppIcons';

@Component
export struct AppShell {
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  onClose: () => void = () => {
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Row() {
      WorkspaceSidebar({ vm: this.vm })
      Column() {
        // 顶行:返回钮 + TabBar(28px 合一高度,返回钮嵌在 tab 行左端)
        Row() {
          Text('«')
            .fontSize(DesignTokens.FONT_HEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().brand)
            .width(26)
            .height(22)
            .textAlign(TextAlign.Center)
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: DesignTokens.SPACE_XS })
            .accessibilityText('返回旧界面')
            .onClick(() => this.onClose())
          TabBar({ vm: this.vm, themeName: this.themeName })
        }
        .width('100%')
        .height(28)

        // PaneGrid 占位区(M1c 前固定两 pane 横排;rightPanelOpen 预留 M1d)
        Row({ space: DesignTokens.SPACE_SM }) {
          ForEach(this.vm.panes, (paneId: string) => {
            PanePlaceholder({ vm: this.vm, paneId: paneId, themeName: this.themeName })
          }, (paneId: string) => paneId)
        }
        .layoutWeight(1)
        .width('100%')
        .padding(DesignTokens.SPACE_SM)
        .backgroundColor(this.th().surface)
        .alignItems(VerticalAlign.Center)

        StatusBar({ vm: this.vm, themeName: this.themeName })
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
  }
}
