// relay4 C1: 首启 4 步引导浮层(欢迎→新建连接→终端与AI Dock→设置与主题)
// 可跳过;完成/跳过均调 onFinish(Index 写 filesDir/guide_done 标记永不再弹)
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { AppIcons } from '../common/AppIcons';

@Component
export struct GuideOverlay {
  onFinish: () => void = () => {}
  @State step: number = 0
  @State th: AppTheme = themeByName('dark')

  aboutToAppear(): void {
    this.th = themeByName(AppStorage.get<string>('ut.theme') ?? 'dark')
  }

  private titles: string[] = [
    '欢迎来到一站AI终端',
    '新建你的第一个连接',
    '终端与 AI 智能体',
    '设置与主题'
  ]
  private descs: string[] = [
    'SSH / 本地终端 / 数据库 / 远程桌面,一个应用全搞定。左侧坞切换功能,顶栏搜索直达一切。',
    '左侧「连接」面板点 + 新建;支持 SSH、本地终端、PostgreSQL、Redis、MySQL、VNC、RDP 等。也可按 Ctrl+K 打开命令面板快速直达。',
    '底部 ✦ 智能体 Dock:用自然语言驱动终端——读写屏幕、执行命令、传输文件,每一步都有审批卡把关。',
    '点顶栏齿轮进设置:AI 模型配置(Anthropic / OpenAI 兼容)、主题深浅切换、数据导入导出都在这里。'
  ]
  private icons: string[] = [AppIcons.CMD_AI, AppIcons.OP_ADD, AppIcons.CONN_RDP, AppIcons.CMD_SETTINGS]

  next(): void {
    if (this.step >= 3) {
      this.onFinish()
      return
    }
    this.step++
  }

  build() {
    Stack() {
      Column() {
        // 步序点
        Row({ space: 6 }) {
          ForEach([0, 1, 2, 3], (i: number) => {
            Circle()
              .width(i === this.step ? 8 : 6)
              .height(i === this.step ? 8 : 6)
              .fill(i <= this.step ? this.th.brand : this.th.hairline)
          }, (i: number) => i.toString() + (i === this.step ? 'a' : 'b'))
        }
        .margin({ bottom: 16 })

        Text(this.icons[this.step])
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th.iconStrong)
          .width(72)
          .height(72)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_XL)
          .backgroundColor(this.th.surface)
          .border({ width: 1, color: this.th.hairline })
          .margin({ bottom: 14 })

        Text(this.titles[this.step])
          .fontSize(DesignTokens.FONT_DISPLAY)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th.ink)
          .margin({ bottom: 10 })

        Text(this.descs[this.step])
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th.inkSubtle)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
          .padding({ left: 12, right: 12 })

        Row({ space: 10 }) {
          Text(this.step === 3 ? '完成' : '跳过')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th.inkSubtle)
            .height(36)
            .padding({ left: 18, right: 18 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th.surface)
            .border({ width: 1, color: this.th.hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => this.onFinish())
          Text(this.step === 3 ? '开始使用' : '下一步')
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th.surface)
            .height(36)
            .padding({ left: 22, right: 22 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th.brand)
            .textAlign(TextAlign.Center)
            .onClick(() => this.next())
        }
        .alignItems(VerticalAlign.Center)
        .margin({ top: 22 })
      }
      .width(380)
      .padding({ top: 30, bottom: 26, left: 24, right: 24 })
      .borderRadius(DesignTokens.RADIUS_LG)
      .backgroundColor(this.th.surfaceRaised)
      .border({ width: 1, color: this.th.hairline })
      .shadow({ radius: DesignTokens.SHADOW_LG_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_LG_OFFSET_Y })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.55)')
    .alignContent(Alignment.Center)
  }
}
