/**
 * 左侧工作区栏(GUI 棒升级:可展开/收起 + 悬停提示 + 图标真实接线 + 设置入口)。
 *
 * - 收起(缺省,44px):纯图标列;悬停图标弹出功能提示(bindPopup 右侧气泡);
 * - 展开(150px):图标+功能标签(工作区名/新建/连接/Git/Agent/设置/主题),
 *   顶部箭头钮切换(animateTo 平滑过渡);
 * - 连接/Git 图标真实接线 vm.openRightTab('conn'/'git');⚙ 打开设置面板。
 * - tooltip 修正(R2):参数化 @Builder 在 bindPopup 内渲染空白(用户实见
 *   「气泡没有字」)——改无参 @Builder 读 @State tipText 的惯用模式;
 * - 文案全部经 tr(ut.locale) 反应式国际化。零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { WorkspaceState } from '../model/WorkspaceState';
import { AppIcons } from '../../common/AppIcons';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr } from '../../common/AppI18n';
import { fsc } from '../../common/UiFont';

@Component
export struct WorkspaceSidebar {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @State hoverId: string = ''
  @State tipText: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 悬停提示显示条件:收起态 + 该图标 hover 中。 */
  private tipShow(id: string): boolean {
    return !this.vm.sidebarExpanded && this.hoverId === id
  }

  /** 悬停进/出统一入口:高亮 + 备好气泡文案(无参 builder 读 tipText)。 */
  private armTip(id: string, text: string, on: boolean): void {
    this.hoverId = on ? id : (this.hoverId === id ? '' : this.hoverId)
    if (on) {
      this.tipText = text
    }
  }

  @Builder
  TipBubble() {
    // GUI-R3: 气泡底色由 builder 自绘(popupColor 对 custom builder 在深色
    // 主题不生效——系统白底+浅字=用户实见「白气泡看不到字」;自带 surfaceRaised
    // 底+hairline 边,两主题均正常)
    Column() {
      Text(this.tipText)
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontColor(this.th().ink)
        .maxLines(2)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(this.th().surfaceRaised)
    .borderRadius(DesignTokens.RADIUS_MD)
    .border({ width: 1, color: this.th().hairline })
  }

  /** bindPopup options 工厂(ArkTS 无对象字面量类型推断,显式组装)。 */
  private tipOptions(): CustomPopupOptions {
    const o: CustomPopupOptions = {
      builder: (): void => {
        this.TipBubble()
      },
      placement: Placement.Right,
      popupColor: Color.Transparent,
      enableArrow: false,
      autoCancel: false
    }
    return o
  }

  build() {
    Column() {
      // 展开/收起切换钮(顶部箭头:收起»/展开«)
      Text(this.vm.sidebarExpanded ? '«' : '»')
        .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.hoverId === 'sbtoggle' ? this.th().brand : this.th().iconMuted)
        .width('100%')
        .height(22)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.hoverId === 'sbtoggle' ? this.th().hover : Color.Transparent)
        .margin({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_XS })
        .accessibilityText(this.vm.sidebarExpanded ? tr(this.locale, 'sb.collapse') : tr(this.locale, 'sb.expand'))
        .onClick(() => {
          animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
            this.vm.toggleSidebar()
          })
        })
        .onHover((h: boolean) => {
          this.armTip('sbtoggle', this.vm.sidebarExpanded ? tr(this.locale, 'sb.collapse') : tr(this.locale, 'sb.expand'), h)
        })
        .bindPopup(this.tipShow('sbtoggle'), this.tipOptions())

      // 工作区图标列(展开态带名称标签;active 高亮,hover 反馈,点击切换)
      ForEach(this.vm.workspaces, (ws: WorkspaceState, idx: number) => {
        Row({ space: 8 }) {
          Text(ws.glyph)
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.vm.activeWs === idx || this.hoverId === 'ws' + idx.toString()
              ? this.th().brand : this.th().inkSubtle)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
          if (this.vm.sidebarExpanded) {
            Text(ws.name)
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.vm.activeWs === idx ? this.th().ink : this.th().inkSubtle)
              .maxLines(1)
              .layoutWeight(1)
          }
        }
        .width('100%')
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.vm.activeWs === idx ? this.th().panel
          : (this.hoverId === 'ws' + idx.toString() ? this.th().hover : Color.Transparent))
        .margin({ bottom: DesignTokens.SPACE_XS })
        .accessibilityText(tr(this.locale, 'sb.tip.switchWs') + ' ' + ws.name)
        .onClick(() => this.vm.switchWorkspace(idx))
        .onHover((h: boolean) => {
          this.armTip('ws' + idx.toString(), tr(this.locale, 'sb.tip.switchWs') + ': ' + ws.name, h)
        })
        .bindPopup(this.tipShow('ws' + idx.toString()), this.tipOptions())
      }, (ws: WorkspaceState, idx: number) => ws.wsId + '#' + idx.toString() + '#' + ws.glyph + '#' + (this.vm.sidebarExpanded ? 'e' : 'c'))

      // + 新建工作区
      Row({ space: 8 }) {
        Text(AppIcons.OP_ADD)
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'wsnew' ? this.th().brand : this.th().iconMuted)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.newWorkspace'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().inkSubtle)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(20)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'wsnew' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.newWorkspace'))
      .onClick(() => this.vm.newWorkspace())
      .onHover((h: boolean) => {
        this.armTip('wsnew', tr(this.locale, 'sb.tip.new'), h)
      })
      .bindPopup(this.tipShow('wsnew'), this.tipOptions())

      // 连接(真实接线 → RightPanel conn 页)
      Row({ space: 8 }) {
        Text(AppIcons.PANEL_CONNECTIONS)
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'conn' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.connections'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'conn' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.connections'))
      .onClick(() => this.vm.openRightTab('conn'))
      .onHover((h: boolean) => {
        this.armTip('conn', tr(this.locale, 'sb.tip.conn'), h)
      })
      .bindPopup(this.tipShow('conn'), this.tipOptions())

      // Git(真实接线 → RightPanel git 页)
      Row({ space: 8 }) {
        Text(AppIcons.PANEL_TUNNEL)
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'git' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.git'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'git' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.git'))
      .onClick(() => this.vm.openRightTab('git'))
      .onHover((h: boolean) => {
        this.armTip('git', tr(this.locale, 'sb.tip.git'), h)
      })
      .bindPopup(this.tipShow('git'), this.tipOptions())

      // Agent(状态点 = Vm.agentOnline 桩;点击切换 RightPanel)
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(AppIcons.CMD_AI)
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.hoverId === 'agent' ? this.th().brand : this.th().iconStrong)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
          Circle()
            .width(7)
            .height(7)
            .fill(this.vm.agentOnline ? this.th().success : this.th().inkSubtle)
            .margin(2)
            .stroke(this.th().surface)
            .strokeWidth(1)
        }
        .width(32)
        .height(32)

        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.agent'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'agent' ? this.th().hover : Color.Transparent)
      .accessibilityText(tr(this.locale, 'sb.agent'))
      .onClick(() => this.vm.toggleRightPanel())
      .onHover((h: boolean) => {
        this.armTip('agent', tr(this.locale, 'sb.tip.agent'), h)
      })
      .bindPopup(this.tipShow('agent'), this.tipOptions())

      Blank()

      // 设置(GUI-R2:侧栏 ⚙ → 设置面板,主题/语言/桥状态/版本)
      Row({ space: 8 }) {
        Text('⚙')
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
          .fontColor(this.hoverId === 'settings' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.settings'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'settings' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.settings'))
      .onClick(() => this.vm.toggleSettings())
      .onHover((h: boolean) => {
        this.armTip('settings', tr(this.locale, 'sb.tip.settings'), h)
      })
      .bindPopup(this.tipShow('settings'), this.tipOptions())

      // 底部主题切换点(暗/浅互切,沿用 AppStorage 'ut.theme' 通道)
      Row({ space: 8 }) {
        Text('●')
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
          .fontColor(this.themeName === 'dark' ? this.th().brand : this.th().inkSubtle)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.theme'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().inkSubtle)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .margin({ bottom: DesignTokens.SPACE_SM })
      .accessibilityText(tr(this.locale, 'sb.theme'))
      .onClick(() => {
        this.themeName = this.themeName === 'dark' ? 'light' : 'dark'
      })
      .onHover((h: boolean) => {
        this.armTip('theme', tr(this.locale, 'sb.tip.theme'), h)
      })
      .bindPopup(this.tipShow('theme'), this.tipOptions())
    }
    .width(this.vm.sidebarExpanded ? 150 : 44)
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { right: 1 }, color: this.th().hairline })
  }
}
