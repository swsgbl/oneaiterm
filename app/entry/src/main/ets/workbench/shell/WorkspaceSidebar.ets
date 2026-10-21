/**
 * 左侧工作区栏(GUI 棒升级:可展开/收起 + 悬停提示 + 图标真实接线)。
 *
 * - 收起(缺省,44px):纯图标列;悬停图标弹出功能提示(bindPopup 右侧
 *   气泡——用户指令「收起状态下悬停提示功能」);
 * - 展开(150px):图标+功能标签(工作区名/新建/连接/Git/Agent/主题),
 *   顶部箭头钮切换(animateTo 平滑过渡);
 * - 连接/Git 图标原为 setStatus 桩,现真实接线 vm.openRightTab
 *  ('conn'/'git')——与 palette「连接 · 管理档案」「Git · 打开面板」同落点;
 * - 文案全部经 tr(ut.locale) 反应式国际化(GUI-i18n 棒)。
 * 零业务 import(vm 通道外无 service 依赖)。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { WorkspaceState } from '../model/WorkspaceState';
import { AppIcons } from '../../common/AppIcons';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr } from '../../common/AppI18n';

@Component
export struct WorkspaceSidebar {
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @State hoverId: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 悬停提示显示条件:收起态 + 该图标 hover 中。 */
  private tipShow(id: string): boolean {
    return !this.vm.sidebarExpanded && this.hoverId === id
  }

  @Builder
  TipText(text: string) {
    Column() {
      Text(text)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().ink)
        .maxLines(2)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
  }

  build() {
    Column() {
      // 展开/收起切换钮(顶部箭头:收起»/展开«)
      Text(this.vm.sidebarExpanded ? '«' : '»')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.hoverId === 'sbtoggle' ? this.th().brand : this.th().iconMuted)
        .width(this.vm.sidebarExpanded ? '100%' : 32)
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
          this.hoverId = h ? 'sbtoggle' : ''
        })
        .bindPopup(this.tipShow('sbtoggle'), {
          builder: (): void => {
            this.TipText(this.vm.sidebarExpanded ? tr(this.locale, 'sb.collapse') : tr(this.locale, 'sb.expand'))
          },
          placement: Placement.Right,
          popupColor: this.th().surfaceRaised,
          enableArrow: true,
          autoCancel: false
        } as CustomPopupOptions)

      // 工作区图标列(展开态带名称标签;active 高亮,hover 反馈,点击切换)
      ForEach(this.vm.workspaces, (ws: WorkspaceState, idx: number) => {
        Row({ space: 8 }) {
          Text(ws.glyph)
            .fontSize(DesignTokens.FONT_HEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.vm.activeWs === idx || this.hoverId === 'ws' + idx.toString()
              ? this.th().brand : this.th().inkSubtle)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
          if (this.vm.sidebarExpanded) {
            Text(ws.name)
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.vm.activeWs === idx ? this.th().ink : this.th().inkSubtle)
              .maxLines(1)
              .layoutWeight(1)
          }
        }
        .width(this.vm.sidebarExpanded ? '100%' : 32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.vm.activeWs === idx ? this.th().panel
          : (this.hoverId === 'ws' + idx.toString() ? this.th().hover : Color.Transparent))
        .margin({ bottom: DesignTokens.SPACE_XS })
        .accessibilityText(tr(this.locale, 'sb.tip.switchWs') + ' ' + ws.name)
        .onClick(() => this.vm.switchWorkspace(idx))
        .onHover((h: boolean) => {
          this.hoverId = h ? 'ws' + idx.toString() : ''
        })
        .bindPopup(this.tipShow('ws' + idx.toString()), {
          builder: (): void => {
            this.TipText(tr(this.locale, 'sb.tip.switchWs') + ': ' + ws.name)
          },
          placement: Placement.Right,
          popupColor: this.th().surfaceRaised,
          enableArrow: true,
          autoCancel: false
        } as CustomPopupOptions)
      }, (ws: WorkspaceState, idx: number) => ws.wsId + '#' + idx.toString() + '#' + ws.glyph + '#' + (this.vm.sidebarExpanded ? 'e' : 'c'))

      // + 新建工作区
      Row({ space: 8 }) {
        Text(AppIcons.OP_ADD)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'wsnew' ? this.th().brand : this.th().iconMuted)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.newWorkspace'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width(this.vm.sidebarExpanded ? '100%' : 32)
      .height(20)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'wsnew' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.newWorkspace'))
      .onClick(() => this.vm.newWorkspace())
      .onHover((h: boolean) => {
        this.hoverId = h ? 'wsnew' : ''
      })
      .bindPopup(this.tipShow('wsnew'), {
        builder: (): void => {
          this.TipText(tr(this.locale, 'sb.tip.new'))
        },
        placement: Placement.Right,
        popupColor: this.th().surfaceRaised,
        enableArrow: true,
        autoCancel: false
      } as CustomPopupOptions)

      // 连接(GUI 棒:真实接线 → RightPanel conn 页,原 setStatus 桩退役)
      Row({ space: 8 }) {
        Text(AppIcons.PANEL_CONNECTIONS)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'conn' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.connections'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width(this.vm.sidebarExpanded ? '100%' : 32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'conn' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.connections'))
      .onClick(() => this.vm.openRightTab('conn'))
      .onHover((h: boolean) => {
        this.hoverId = h ? 'conn' : ''
      })
      .bindPopup(this.tipShow('conn'), {
        builder: (): void => {
          this.TipText(tr(this.locale, 'sb.tip.conn'))
        },
        placement: Placement.Right,
        popupColor: this.th().surfaceRaised,
        enableArrow: true,
        autoCancel: false
      } as CustomPopupOptions)

      // Git(GUI 棒:真实接线 → RightPanel git 页)
      Row({ space: 8 }) {
        Text(AppIcons.PANEL_TUNNEL)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'git' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.git'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width(this.vm.sidebarExpanded ? '100%' : 32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'git' ? this.th().hover : Color.Transparent)
      .margin({ bottom: DesignTokens.SPACE_XS })
      .accessibilityText(tr(this.locale, 'sb.git'))
      .onClick(() => this.vm.openRightTab('git'))
      .onHover((h: boolean) => {
        this.hoverId = h ? 'git' : ''
      })
      .bindPopup(this.tipShow('git'), {
        builder: (): void => {
          this.TipText(tr(this.locale, 'sb.tip.git'))
        },
        placement: Placement.Right,
        popupColor: this.th().surfaceRaised,
        enableArrow: true,
        autoCancel: false
      } as CustomPopupOptions)

      // Agent(状态点 = Vm.agentOnline 桩;点击切换 RightPanel)
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(AppIcons.CMD_AI)
            .fontSize(DesignTokens.FONT_HEADING)
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
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width(this.vm.sidebarExpanded ? '100%' : 32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.hoverId === 'agent' ? this.th().hover : Color.Transparent)
      .accessibilityText(tr(this.locale, 'sb.agent'))
      .onClick(() => this.vm.toggleRightPanel())
      .onHover((h: boolean) => {
        this.hoverId = h ? 'agent' : ''
      })
      .bindPopup(this.tipShow('agent'), {
        builder: (): void => {
          this.TipText(tr(this.locale, 'sb.tip.agent'))
        },
        placement: Placement.Right,
        popupColor: this.th().surfaceRaised,
        enableArrow: true,
        autoCancel: false
      } as CustomPopupOptions)

      Blank()

      // 底部主题切换点(暗/浅互切,沿用 AppStorage 'ut.theme' 通道)
      Row({ space: 8 }) {
        Text('●')
          .fontSize(DesignTokens.FONT_HEADING)
          .fontColor(this.themeName === 'dark' ? this.th().brand : this.th().inkSubtle)
          .width(32)
          .textAlign(TextAlign.Center)
        if (this.vm.sidebarExpanded) {
          Text(tr(this.locale, 'sb.theme'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .maxLines(1)
            .layoutWeight(1)
        }
      }
      .width(this.vm.sidebarExpanded ? '100%' : 32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(DesignTokens.RADIUS_MD)
      .margin({ bottom: DesignTokens.SPACE_SM })
      .accessibilityText(tr(this.locale, 'sb.theme'))
      .onClick(() => {
        this.themeName = this.themeName === 'dark' ? 'light' : 'dark'
      })
      .onHover((h: boolean) => {
        this.hoverId = h ? 'theme' : ''
      })
      .bindPopup(this.tipShow('theme'), {
        builder: (): void => {
          this.TipText(tr(this.locale, 'sb.tip.theme'))
        },
        placement: Placement.Right,
        popupColor: this.th().surfaceRaised,
        enableArrow: true,
        autoCancel: false
      } as CustomPopupOptions)
    }
    .width(this.vm.sidebarExpanded ? 150 : 44)
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { right: 1 }, color: this.th().hairline })
  }
}
