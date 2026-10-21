/**
 * 工作台整页外壳(任务 M1b,ADR-0001 ArkUI 同构壳)。
 * 非 @Entry 路由页——由宿主(Index/build 顶部 if shellMode)承载。
 * 布局:WorkspaceSidebar(左 44px) | 右 Column{ TabBar(28px) | PaneGrid
 * layoutWeight(1) | StatusBar(22px) };RightPanel(M1d)预留 vm.rightPanelOpen。
 * M1c:中部占位 Row 换装 PaneGrid(布局树真渲染)。
 * 自带左上返回钮(onClose 回宿主)。深浅主题沿用 AppTheme/DesignTokens,零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { WorkspaceSidebar } from './WorkspaceSidebar';
import { TabBar } from './TabBar';
import { StatusBar } from './StatusBar';
import { PaneGrid } from './PaneGrid';
import { RightPanel } from './RightPanel';
import { WorkbenchPalette } from './WorkbenchPalette';
import { SettingsPanel } from './SettingsPanel';
import { ToastHost } from './ToastHost';
import { WebPaneLayer } from './WebPaneLayer';
import { SshPicker } from './SshPicker';
import { HmhEventBridge } from '../agent/HmhEventBridge';
import { CommandBridge } from '../bridge/CommandBridge';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AppIcons } from '../../common/AppIcons';
import { fsc } from '../../common/UiFont';

@Component
export struct AppShell {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  onClose: () => void = () => {
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    // M5b:桥 emit 含 paneId 的 Agent 事件时驱动 vm.agentRev(PaneSurface
    // '✦' 标记的追踪源;组件销毁置 null 防悬挂回调)
    HmhEventBridge.setAgentRevTap((): void => {
      this.vm.agentRev += 1
    })
    // +M8a: CLI 桥注册 vm 并自动起服(仅 127.0.0.1:18971;失败仅记
    // 日志不阻 UI;socket 回调主线程事件循环交付,vm 直调安全)
    CommandBridge.setVm(this.vm)
    CommandBridge.start(18971)
  }

  aboutToDisappear(): void {
    HmhEventBridge.setAgentRevTap(null)
    // +M8a: 仅注销 vm(server/连接保留;后续命令 doctor 降级不崩)
    CommandBridge.setVm(null)
  }

  build() {
    Stack() {
      // GUI-R4:web 终端常驻层(最底;布局树重建不碰,分屏/换页内容保活)
      WebPaneLayer({ vm: this.vm })
      Row() {
        WorkspaceSidebar({ vm: this.vm })
      Column() {
        // 顶行:返回钮 + TabBar(28px 合一高度,返回钮嵌在 tab 行左端)
        Row() {
          Text('«')
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
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
          // ⌘ 命令面板钮(M1d):开/关 paletteOpen(vm 单源)
          Text('⌘')
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontColor(this.th().iconMuted)
            .width(24)
            .height(22)
            .textAlign(TextAlign.Center)
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.th().panel)
            .border({ width: 1, color: this.th().hairline })
            .margin({ left: DesignTokens.SPACE_XS })
            .accessibilityText('命令面板')
            .onClick(() => this.vm.togglePalette())
        }
        .width('100%')
        .height(28)

        // PaneGrid 真渲染区(M1c:布局树→分屏)叠命令面板浮层(M1d);
        // palette 条件分支直接读 vm.paletteOpen(V1 状态追踪规则)
        Stack() {
          PaneGrid({ vm: this.vm, themeName: this.themeName })
            .width('100%')
            .height('100%')
          if (this.vm.paletteOpen) {
            WorkbenchPalette({
              vm: this.vm,
              themeName: this.themeName,
              onClose: () => {
                this.vm.paletteOpen = false
              }
            })
          }
          // M6a:SSH 连接选择浮层(>1 条 ssh profile 时 palette 打开;纯 vm 态驱动)
          if (this.vm.sshPickerOpen) {
            SshPicker({
              vm: this.vm,
              themeName: this.themeName,
              onClose: () => {
                this.vm.sshPickerOpen = false
              }
            })
          }
          // GUI-R2:设置面板(侧栏 ⚙ / palette「设置」打开;主题/语言/桥/版本)
          if (this.vm.settingsOpen) {
            SettingsPanel({ vm: this.vm })
          }
        }
        .layoutWeight(1)
        .width('100%')

        StatusBar({ vm: this.vm, themeName: this.themeName })
      }
      .layoutWeight(1)
      .height('100%')
      .width('100%')
      // RightPanel 抽屉(M1d 桩):条件分支直接读 vm.rightPanelOpen;
      // GUI 丝滑棒:右侧滑入/淡出过渡
      if (this.vm.rightPanelOpen) {
        RightPanel({ vm: this.vm, themeName: this.themeName })
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 56 })).animation({ duration: 180, curve: Curve.EaseOut }),
            TransitionEffect.OPACITY.animation({ duration: 140 })
          ))
      }
      }
      // GUI 丝滑棒:全局轻提示(顶部居中,自动消退;Stack 兄弟层悬浮)
      ToastHost({ vm: this.vm, themeName: this.themeName })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
  }
}
