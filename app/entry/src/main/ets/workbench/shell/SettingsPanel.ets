/**
 * 设置面板(GUI-R2 建立,GUI-R3 扩容:界面字号档 + AI 模型配置)。
 * 居中浮层(同 WorkbenchPalette 装载模式);Scroll 容器容纳扩容内容。
 * 内容:主题(深/浅)、语言(中文/English,即时生效并持久化)、
 * 界面字号(小/标准/大/特大,UiFont.fsc 全局缩放,uifont.txt 持久化)、
 * AI 模型配置(供应商/服务地址/API 密钥/模型名 → llm_config.json,
 * 本地引擎 LocalAssistant 消费——一站式 AI 终端初心回归)、
 * CLI 桥、版本(读运行时 bundleManager)。
 * 文案 tr 反应式国际化;pill 一律内联(带参 @Builder 冻结坑)。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr, setLocale } from '../../common/AppI18n';
import { fsc, setFontScale, fontScaleOf } from '../../common/UiFont';
import { bundleManager, common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import { LlmConfigStore } from '../../service/LlmConfigStore';
import { LlmConfig } from '../../service/Llm';
import { UpdateChecker, isNewer, repoHome, repoIssues, repoReleases } from '../../service/UpdateChecker';

@Component
export struct SettingsPanel {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @ObjectLink vm: WorkbenchVm
  @StorageLink('ut.theme') themeName: string = 'dark'
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @State verName: string = '2.1.0'
  // AI 模型配置(llm_config.json;aboutToAppear 载入,保存落盘)
  @State aiProvider: string = 'anthropic'
  @State aiBaseUrl: string = 'https://api.anthropic.com'
  @State aiApiKey: string = ''
  @State aiModel: string = 'claude-sonnet-4-5'
  @State aiMsg: string = ''
  // 更新检查(GUI-R3)
  @State updChecking: boolean = false
  @State updMsg: string = ''
  @State updLatest: string = ''
  @State updFound: boolean = false
  @State updAuto: boolean = false
  // R4f 键盘测试器(最近收到的键)
  @State kbLast: string = ''

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
    // AI 模型配置回放
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const cfg = LlmConfigStore.read(ctx.filesDir)
      this.aiProvider = cfg.provider !== '' ? cfg.provider : 'anthropic'
      this.aiBaseUrl = cfg.baseUrl
      this.aiApiKey = cfg.apiKey
      this.aiModel = cfg.model
    } catch (e) {
      // 保持缺省
    }
    this.loadUpdAuto()
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 打开仓库链接(系统浏览器;失败 toast)。 */
  private openRepo(url: string): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      ctx.openLink(url, { appLinkingOnly: false })
    } catch (e) {
      this.vm.toast(url)
    }
  }

  /** 复制诊断信息(版本/语言/字号档;隐私红线:不含密钥/档案)。 */
  private copyDiag(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        'oneAIterm v' + this.verName + ' locale=' + this.locale +
        ' font=' + this.fontScale.toString() + ' bridge=127.0.0.1:18971')
      pasteboard.getSystemPasteboard().setData(data)
      this.vm.toast(tr(this.locale, 'fb.copied'))
    } catch (e) {
      // 剪贴板失败静默(部分环境无权限)
    }
  }

  /** 检查更新(手动/自动共用;结果显示 + toast)。 */
  private async doCheckUpdate(silent: boolean): Promise<void> {
    if (this.updChecking) {
      return
    }
    this.updChecking = true
    const r = await UpdateChecker.check(this.locale)
    this.updChecking = false
    if (!r.ok) {
      this.updMsg = tr(this.locale, 'upd.fail')
      this.updFound = false
      this.updLatest = ''
      return
    }
    this.updLatest = r.latest
    if (isNewer(this.verName, r.latest)) {
      this.updMsg = tr(this.locale, 'upd.found')
      this.updFound = true
      this.vm.toast(tr(this.locale, 'upd.found') + ' v' + r.latest)
    } else {
      this.updMsg = tr(this.locale, 'upd.latest')
      this.updFound = false
      if (!silent) {
        this.vm.toast(tr(this.locale, 'upd.latest'))
      }
    }
  }

  /** 自动检查开关持久化(filesDir/update_auto.txt:'1'/'0')。 */
  private persistUpdAuto(on: boolean): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const f = fs.openSync(ctx.filesDir + '/update_auto.txt',
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE)
      fs.writeSync(f.fd, on ? '1' : '0')
      fs.closeSync(f)
    } catch (e) {
      // 持久化失败不阻塞会话内
    }
  }

  private loadUpdAuto(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      this.updAuto = fs.readTextSync(ctx.filesDir + '/update_auto.txt').trim() === '1'
    } catch (e) {
      this.updAuto = false
    }
  }

  /** AI 配置保存(llm_config.json;''=成功;toast 反馈)。 */
  private saveAi(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const cfg = new LlmConfig()
      cfg.provider = this.aiProvider
      cfg.baseUrl = this.aiBaseUrl.trim()
      cfg.apiKey = this.aiApiKey.trim()
      cfg.model = this.aiModel.trim()
      const err = LlmConfigStore.write(ctx.filesDir, cfg)
      if (err === '') {
        this.aiMsg = tr(this.locale, 'ai.saved')
        this.vm.toast(tr(this.locale, 'ai.saved'))
      } else {
        this.aiMsg = err
      }
    } catch (e) {
      this.aiMsg = tr(this.locale, 'ai.savefail')
    }
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

      Scroll() {
        Column({ space: DesignTokens.SPACE_MD }) {
          Text(tr(this.locale, 'set.title'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_DISPLAY))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().ink)
            .margin({ top: 6 })

          // 主题
          Row({ space: 10 }) {
            Text(tr(this.locale, 'set.theme'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .width(70)
            Text(tr(this.locale, 'set.theme.dark'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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

          // 语言
          Row({ space: 10 }) {
            Text(tr(this.locale, 'set.language'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .width(70)
            Text('中文')
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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

          // 界面字号(小/标准/大/特大;UiFont 全局缩放+持久化)
          Row({ space: 8 }) {
            Text(tr(this.locale, 'set.fontsize'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .width(70)
            Text(tr(this.locale, 'set.font.small'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(fontScaleOf(this.fontScale) === 0.9 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(fontScaleOf(this.fontScale) === 0.9 ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(fontScaleOf(this.fontScale) === 0.9 ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                setFontScale(0.9)
              })
            Text(tr(this.locale, 'set.font.normal'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(fontScaleOf(this.fontScale) === 1.0 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(fontScaleOf(this.fontScale) === 1.0 ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(fontScaleOf(this.fontScale) === 1.0 ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                setFontScale(1.0)
              })
            Text(tr(this.locale, 'set.font.large'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(fontScaleOf(this.fontScale) === 1.15 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(fontScaleOf(this.fontScale) === 1.15 ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(fontScaleOf(this.fontScale) === 1.15 ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                setFontScale(1.15)
              })
            Text(tr(this.locale, 'set.font.xl'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(fontScaleOf(this.fontScale) === 1.3 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(fontScaleOf(this.fontScale) === 1.3 ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(fontScaleOf(this.fontScale) === 1.3 ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                setFontScale(1.3)
              })
          }
          .width('100%')

          // ===== AI 模型配置(一站式 AI 终端初心:本地引擎直连 LLM) =====
          Divider().color(this.th().hairline).margin({ top: 4, bottom: 0 })

          Text(tr(this.locale, 'ai.title'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().ink)
            .width('100%')

          Row({ space: 10 }) {
            Text(tr(this.locale, 'ai.provider'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .width(70)
            Text('Anthropic')
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(this.aiProvider === 'anthropic' ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.aiProvider === 'anthropic' ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.aiProvider === 'anthropic' ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.aiProvider = 'anthropic'
                this.aiBaseUrl = 'https://api.anthropic.com'
              })
            Text(tr(this.locale, 'ai.openai'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(this.aiProvider === 'openai' ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.aiProvider === 'openai' ? this.th().surface : this.th().inkSubtle)
              .height(30)
              .padding({ left: 12, right: 12 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.aiProvider === 'openai' ? this.th().brand : this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.aiProvider = 'openai'
                this.aiBaseUrl = 'https://api.openai.com'
              })
          }
          .width('100%')

          Column({ space: 6 }) {
            Text(tr(this.locale, 'ai.baseUrl'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .width('100%')
            TextInput({ text: this.aiBaseUrl })
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().ink)
              .backgroundColor(this.th().inputBg)
              .borderRadius(DesignTokens.RADIUS_MD)
              .height(34)
              .width('100%')
              .onChange((v: string) => {
                this.aiBaseUrl = v
              })
            Text(tr(this.locale, 'ai.apiKey'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .width('100%')
            TextInput({ text: this.aiApiKey, placeholder: 'sk-...' })
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().ink)
              .backgroundColor(this.th().inputBg)
              .borderRadius(DesignTokens.RADIUS_MD)
              .height(34)
              .width('100%')
              .type(InputType.Password)
              .onChange((v: string) => {
                this.aiApiKey = v
              })
            Text(tr(this.locale, 'ai.model'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .width('100%')
            TextInput({ text: this.aiModel })
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().ink)
              .backgroundColor(this.th().inputBg)
              .borderRadius(DesignTokens.RADIUS_MD)
              .height(34)
              .width('100%')
              .onChange((v: string) => {
                this.aiModel = v
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Text(tr(this.locale, 'ai.save'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().surface)
              .height(32)
              .padding({ left: 20, right: 20 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().brand)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.saveAi()
              })
            if (this.aiMsg !== '') {
              Text(this.aiMsg)
                .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
                .fontColor(this.th().inkSubtle)
                .maxLines(1)
                .layoutWeight(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(tr(this.locale, 'ai.hint'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().iconMuted)
            .width('100%')

          // ===== 反馈与支持(GUI-R3:问题反馈/点赞/诊断) =====
          Divider().color(this.th().hairline).margin({ top: 2 })

          Text(tr(this.locale, 'fb.title'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().ink)
            .width('100%')

          Column({ space: 8 }) {
            Text(tr(this.locale, 'fb.issue'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().ink)
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.openRepo(repoIssues(this.locale))
              })
            Text(tr(this.locale, 'fb.star'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().ink)
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.openRepo(repoHome(this.locale))
              })
            Text(tr(this.locale, 'fb.copydiag'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.copyDiag()
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ===== 检查更新(GUI-R3:手动检查 + 启动自动检查) =====
          Divider().color(this.th().hairline).margin({ top: 2 })

          Row({ space: 10 }) {
            Text(tr(this.locale, 'upd.title'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
              .width(70)
            Text(this.updChecking ? tr(this.locale, 'upd.checking') : tr(this.locale, 'upd.check'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().surface)
              .height(30)
              .padding({ left: 16, right: 16 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().brand)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.doCheckUpdate(false)
              })
            if (this.updMsg !== '') {
              Text(this.updMsg + (this.updLatest !== '' ? ' v' + this.updLatest : ''))
                .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
                .fontColor(this.updFound ? this.th().brand : this.th().inkSubtle)
                .maxLines(1)
                .layoutWeight(1)
                .onClick(() => {
                  if (this.updFound) {
                    this.openRepo(repoReleases(this.locale))
                  }
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 8 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.updAuto })
              .onChange((on: boolean) => {
                this.updAuto = on
                this.persistUpdAuto(on)
              })
            Text(tr(this.locale, 'upd.auto'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
          }
          .width('100%')

          Divider().color(this.th().hairline).margin({ top: 2 })

          // CLI 桥(说明行)
          Row() {
            Text(tr(this.locale, 'set.bridge'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
            Text('127.0.0.1:18971')
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().iconMuted)
              .margin({ left: 8 })
          }
          .width('100%')

          // 版本
          Row() {
            Text(tr(this.locale, 'set.version'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
              .fontColor(this.th().inkSubtle)
            Text(this.verName)
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().iconMuted)
              .margin({ left: 8 })
          }
          .width('100%')

          // ===== 键盘测试器(R4f:用户自判键盘信号是否到达应用) =====
          Divider().color(this.th().hairline).margin({ top: 2 })

          Text(tr(this.locale, 'kb.title'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().ink)
            .width('100%')
          Text(tr(this.locale, 'kb.hint'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().inkSubtle)
            .width('100%')
          TextInput({ placeholder: '' })
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
            .fontColor(this.th().ink)
            .backgroundColor(this.th().inputBg)
            .borderRadius(DesignTokens.RADIUS_MD)
            .height(36)
            .width('100%')
            .onKeyEvent((e: KeyEvent) => {
              if (e.type === KeyType.Down) {
                this.kbLast = 'key=' + e.keyCode.toString() +
                  (e.keyText !== undefined && e.keyText !== '' ? ' "' + e.keyText + '"' : '')
              }
            })
          Text(tr(this.locale, 'kb.received') + ' ' +
            (this.kbLast !== '' ? this.kbLast : tr(this.locale, 'kb.none')))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.kbLast !== '' ? this.th().brand : this.th().iconMuted)
            .width('100%')

          Text(tr(this.locale, 'set.done'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_BODY))
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
        .width(380)
        .padding({ top: 22, bottom: 18, left: 24, right: 24 })
        .borderRadius(DesignTokens.RADIUS_LG)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: 1, color: this.th().hairline })
        .shadow({ radius: DesignTokens.SHADOW_LG_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_LG_OFFSET_Y })
        .alignItems(HorizontalAlign.Center)
      }
      .scrollBar(BarState.Auto)
      .constraintSize({ maxHeight: '86%' })
      .align(Alignment.Center)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
