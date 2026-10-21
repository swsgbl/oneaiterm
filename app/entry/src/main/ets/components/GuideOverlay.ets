// GUI 棒 v2:首启五步引导浮层(欢迎→终端即开即用→侧栏展开收起→多窗格
// 多标签→右侧 AI 面板)。用户指令「下一步下一步那种指引」:步序点+上一步
// /跳过/下一步/开始使用;内容对齐当前工作台(旧版描述的连接面板/AI Dock/
// 齿轮设置已退役)。完成/跳过均调 onFinish(Index 写 filesDir/guide_done
// 标记永不再弹);palette「帮助 · 使用指引」可随时重开(AppStorage
// 'ut.guide.show')。文案经 tr(ut.locale) 国际化。
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { AppIcons } from '../common/AppIcons';
import { tr } from '../common/AppI18n';
import { fsc } from '../common/UiFont';

const STEP_KEYS: string[] = ['0', '1', '2', '3', '4']
const STEP_ICONS: string[] = [AppIcons.CMD_AI, AppIcons.OP_ADD, AppIcons.CMD_SETTINGS, AppIcons.CMD_SETTINGS, AppIcons.CMD_AI]

@Component
export struct GuideOverlay {
  @StorageProp('ut.fontScale') fontScale: number = 1
  onFinish: () => void = () => {}
  @State step: number = 0
  @State th: AppTheme = themeByName('dark')
  @StorageProp('ut.locale') locale: string = 'zh-CN'

  aboutToAppear(): void {
    this.th = themeByName(AppStorage.get<string>('ut.theme') ?? 'dark')
  }

  next(): void {
    if (this.step >= 4) {
      this.onFinish()
      return
    }
    this.step++
  }

  prev(): void {
    if (this.step > 0) {
      this.step--
    }
  }

  build() {
    Stack() {
      Column() {
        // 步序点(五步)
        Row({ space: 6 }) {
          ForEach(STEP_KEYS, (i: string) => {
            Circle()
              .width(Number(i) === this.step ? 8 : 6)
              .height(Number(i) === this.step ? 8 : 6)
              .fill(Number(i) <= this.step ? this.th.brand : this.th.hairline)
          }, (i: string) => i.toString() + (Number(i) === this.step ? 'a' : 'b'))
        }
        .margin({ bottom: 16 })

        Text(STEP_ICONS[this.step])
          .fontSize(fsc(this.fontScale, 36))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th.iconStrong)
          .width(72)
          .height(72)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_XL)
          .backgroundColor(this.th.surface)
          .border({ width: 1, color: this.th.hairline })
          .margin({ bottom: 14 })

        Text(tr(this.locale, 'guide.t' + STEP_KEYS[this.step]))
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_DISPLAY))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th.ink)
          .margin({ bottom: 10 })

        Text(tr(this.locale, 'guide.d' + STEP_KEYS[this.step]))
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
          .fontColor(this.th.inkSubtle)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
          .padding({ left: 12, right: 12 })

        Row({ space: 10 }) {
          // 上一步(首步隐藏占位)
          if (this.step > 0) {
            Text(tr(this.locale, 'guide.prev'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th.inkSubtle)
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th.surface)
              .border({ width: 1, color: this.th.hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => this.prev())
          }
          Text(tr(this.locale, 'guide.skip'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
            .fontColor(this.th.inkSubtle)
            .height(36)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th.surface)
            .border({ width: 1, color: this.th.hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => this.onFinish())
          Text(this.step === 4 ? tr(this.locale, 'guide.finish') : tr(this.locale, 'guide.next'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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
      .width(400)
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
