/**
 * tty7 左侧窄工作区栏(任务 tty7-M1b,44px 图标列)。
 * 工作区/连接/Git/Agent 四图标(AppIcons 现有 glyph;Git 用 ⇄ 代理),
 * Agent 带状态点(读 Vm.agentOnline 桩),底部主题切换点(AppStorage 'ut.theme')。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { WorkspaceState } from '../model/WorkspaceState';
import { AppIcons } from '../../common/AppIcons';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct WorkspaceSidebar {
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  @State hoverId: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Column() {
      // 工作区图标列(M2b:绑定 vm.workspaces;activeWs 高亮,hover 反馈,点击切换)
      ForEach(this.vm.workspaces, (ws: WorkspaceState, idx: number) => {
        Text(ws.glyph)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.vm.activeWs === idx || this.hoverId === 'ws' + idx.toString()
            ? this.th().brand : this.th().inkSubtle)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.vm.activeWs === idx ? this.th().panel
            : (this.hoverId === 'ws' + idx.toString() ? this.th().hover : Color.Transparent))
          .margin({ top: idx === 0 ? DesignTokens.SPACE_SM : 0, bottom: DesignTokens.SPACE_XS })
          .accessibilityText('切换工作区 ' + ws.name)
          .onClick(() => this.vm.switchWorkspace(idx))
          .onHover((h: boolean) => {
            this.hoverId = h ? 'ws' + idx.toString() : ''
          })
      }, (ws: WorkspaceState, idx: number) => ws.wsId + '#' + idx.toString() + '#' + ws.glyph)
      // + 新建工作区小钮
      Text(AppIcons.OP_ADD)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.hoverId === 'wsnew' ? this.th().brand : this.th().iconMuted)
        .width(32)
        .height(20)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.hoverId === 'wsnew' ? this.th().hover : Color.Transparent)
        .margin({ bottom: DesignTokens.SPACE_XS })
        .accessibilityText('新建工作区')
        .onClick(() => this.vm.newWorkspace())
        .onHover((h: boolean) => {
          this.hoverId = h ? 'wsnew' : ''
        })
      // 连接
      Text(AppIcons.PANEL_CONNECTIONS)
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.hoverId === 'conn' ? this.th().brand : this.th().iconStrong)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.hoverId === 'conn' ? this.th().hover : Color.Transparent)
        .margin({ bottom: DesignTokens.SPACE_XS })
        .onClick(() => this.vm.setStatus('连接面板 (M2)'))
        .onHover((h: boolean) => {
          this.hoverId = h ? 'conn' : ''
        })
      // Git(⇄ 代理 glyph)
      Text(AppIcons.PANEL_TUNNEL)
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.hoverId === 'git' ? this.th().brand : this.th().iconStrong)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.hoverId === 'git' ? this.th().hover : Color.Transparent)
        .margin({ bottom: DesignTokens.SPACE_XS })
        .onClick(() => this.vm.setStatus('Git 面板 (M6)'))
        .onHover((h: boolean) => {
          this.hoverId = h ? 'git' : ''
        })
      // Agent(状态点 = Vm.agentOnline 桩;点击切换 RightPanel)
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(AppIcons.CMD_AI)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hoverId === 'agent' ? this.th().brand : this.th().iconStrong)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.hoverId === 'agent' ? this.th().hover : Color.Transparent)
          .onClick(() => this.vm.toggleRightPanel())
          .onHover((h: boolean) => {
            this.hoverId = h ? 'agent' : ''
          })
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

      Blank()

      // 底部主题切换点(暗/浅互切,沿用 AppStorage 'ut.theme' 通道)
      Text('●')
        .fontSize(DesignTokens.FONT_HEADING)
        .fontColor(this.themeName === 'dark' ? this.th().brand : this.th().inkSubtle)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(DesignTokens.RADIUS_MD)
        .margin({ bottom: DesignTokens.SPACE_SM })
        .accessibilityText('切换主题')
        .onClick(() => {
          this.themeName = this.themeName === 'dark' ? 'light' : 'dark'
        })
    }
    .width(44)
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { right: 1 }, color: this.th().hairline })
  }
}
