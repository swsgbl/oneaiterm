/**
 * 设置面板(GUI-R2,用户指令「没有设置菜单」)。
 * 居中浮层(同 WorkbenchPalette 装载模式,AppShell Stack 内渲染;
 * 避开窄面板 layoutWeight 挤压坑——居中卡面表单是本仓实证唯一可靠形态)。
 * 内容:主题(深/浅)、语言(中文/English,即时生效并持久化)、
 * CLI 桥说明、版本号。vm.settingsOpen 单源;点遮罩/完成关闭。
 * 文案 tr(ut.locale) 反应式国际化——切语言本面板即时重渲。
 * 注:pill 一律内联(带参 @Builder 冻结坑,PaneGrid 热修实证)。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr, setLocale } from '../../common/AppI18n';
import { bundleManager } from '@kit.AbilityKit';

@Component
export struct SettingsPanel {
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @State verName: string = '2.1.0'

  aboutToAppear(): void {
    // 版本号读运行时 bundle 信息(app.json5 单源;读不到回退缺省)
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      if (info.versionName !== undefined && info.versionName !== '') {
        this.verName = info.versionName
      }
    } catch (e) {
      // 保持缺省
    }
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    Stack() {
      // 遮罩:点空白关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.vm.toggleSettings()
        })

      Column({ space: DesignTokens.SPACE_MD }) {
        Text(tr(this.locale, 'set.title'))
          .fontSize(DesignTokens.FONT_DISPLAY)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().ink)
          .margin({ top: 6 })

        // 主题(深/浅 pill,active=brand)
        Row({ space: 10 }) {
          Text(tr(this.locale, 'set.theme'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
            .width(70)
          Text(tr(this.locale, 'set.theme.dark'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(this.themeName === 'dark' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.themeName === 'dark' ? this.th().surface : this.th().inkSubtle)
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.themeName === 'dark' ? this.th().brand : this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.themeName = 'dark'
            })
          Text(tr(this.locale, 'set.theme.light'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(this.themeName === 'light' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.themeName === 'light' ? this.th().surface : this.th().inkSubtle)
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.themeName === 'light' ? this.th().brand : this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.themeName = 'light'
            })
        }
        .width('100%')

        // 语言(即时生效+持久化;active 判 this.locale 反应式)
        Row({ space: 10 }) {
          Text(tr(this.locale, 'set.language'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
            .width(70)
          Text('中文')
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(this.locale === 'zh-CN' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.locale === 'zh-CN' ? this.th().surface : this.th().inkSubtle)
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.locale === 'zh-CN' ? this.th().brand : this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              setLocale('zh-CN')
            })
          Text('English')
            .fontSize(DesignTokens.FONT_BODY)
            .fontWeight(this.locale === 'en-US' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.locale === 'en-US' ? this.th().surface : this.th().inkSubtle)
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.locale === 'en-US' ? this.th().brand : this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              setLocale('en-US')
            })
        }
        .width('100%')

        // CLI 桥(说明行)
        Row() {
          Text(tr(this.locale, 'set.bridge'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
          Text('127.0.0.1:18971')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().iconMuted)
            .margin({ left: 8 })
        }
        .width('100%')

        // 版本
        Row() {
          Text(tr(this.locale, 'set.version'))
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
          Text(this.verName)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().iconMuted)
            .margin({ left: 8 })
        }
        .width('100%')

        Text(tr(this.locale, 'set.done'))
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().surface)
          .height(36)
          .padding({ left: 26, right: 26 })
          .borderRadius(DesignTokens.RADIUS_XL)
          .backgroundColor(this.th().brand)
          .textAlign(TextAlign.Center)
          .margin({ top: 4, bottom: 4 })
          .onClick(() => {
            this.vm.toggleSettings()
          })
      }
      .width(360)
      .padding({ top: 22, bottom: 18, left: 24, right: 24 })
      .borderRadius(DesignTokens.RADIUS_LG)
      .backgroundColor(this.th().surfaceRaised)
      .border({ width: 1, color: this.th().hairline })
      .shadow({ radius: DesignTokens.SHADOW_LG_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_LG_OFFSET_Y })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}
