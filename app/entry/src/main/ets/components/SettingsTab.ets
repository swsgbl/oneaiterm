// 官方 SettingsTab 复刻:左侧分类(基础/终端/主题/语言/AI)+ 右侧配置区
// M6 relay1: 全量主题化(P0-4) + 保存 toast(P0-1/3) + 密钥框可见性修复(P0-2) + 悬停 tooltip(P0-6) + 版本号 v1.1.0
// 升级 Phase 1 / 任务 2.11 改造: 仅依赖 AgentProvider/AgentAdapter 收口——
//   engines.hmh.baseUrl 经 AgentSettingsStore 管理（原 LlmConfigStore.harnessUrl 迁移）、
//   审批策略三档新语义（strict/standard/open，open 档显式"风险自担"标注）、
//   HMH 连接测试经 AgentAdapter.testHmh（不直接 import HarnessClient）。
import { LlmConfigStore } from '../service/LlmConfigStore';
import { AgentSettings, AgentSettingsStore } from '../service/AgentSettingsStore';
import { AgentAdapter } from '../agent/AgentAdapter';
import { ApprovalPolicyKind } from '../agent/AgentProvider';
import { common } from '@kit.AbilityKit';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { AppIcons } from '../common/AppIcons';

@Component
export struct SettingsTab {
  @StorageProp('ut.theme') themeName: string = 'dark'
  @State cat: number = 0 // 0基础 1终端 2主题 3语言 4AI
  // 基础
  @State autoReconnect: boolean = true
  @State confirmClose: boolean = true
  // 终端
  @State fontSize: number = 14
  @State scrollback: number = 10000
  @State cols: number = 120
  // 主题
  @State theme: string = 'dark'
  onThemeChange: (t: string) => void = (t: string) => {
  }
  // 语言
  @State lang: string = 'zh-CN'
  // AI
  @State cfgProvider: string = 'anthropic'
  @State cfgBaseUrl: string = 'https://api.anthropic.com'
  @State cfgApiKey: string = ''
  @State cfgModel: string = 'claude-sonnet-4-5'
  @State showKey: boolean = false // 密钥明文切换(P0-2)
  @State toast: string = '' // 保存反馈(P0-3)
  @State toastErr: boolean = false
  // 升级 Phase 1: 智能体审批策略三档（strict 每次审批 / standard 仅危险 / open 风险自担）
  @State agentMode: ApprovalPolicyKind = 'strict'
  @State agentToast: string = ''
  // 升级 Phase 1: HMH 引擎地址（engines.hmh.baseUrl，原 harnessUrl 迁移目标）
  @State cfgHarnessUrl: string = ''
  @State harnessToast: string = ''
  @State harnessTesting: boolean = false
  // tooltip 公共悬停态(P0-6)
  @State hoverTip: string = ''
  @State hoverOn: boolean = false
  private filesDir: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    this.filesDir = ctx.filesDir
    const cfg = LlmConfigStore.read(this.filesDir)
    this.cfgProvider = cfg.provider
    this.cfgBaseUrl = cfg.baseUrl
    this.cfgApiKey = cfg.apiKey
    this.cfgModel = cfg.model
    const s = AgentSettingsStore.read(this.filesDir)
    this.cfgHarnessUrl = s.engines.hmh.baseUrl
    this.theme = this.themeName
    this.agentMode = s.security.approvalPolicy
  }

  // 升级 Phase 1: 审批策略三档写入（即时保存+toast）
  saveAgentMode(m: ApprovalPolicyKind): void {
    this.agentMode = m
    const s = AgentSettingsStore.read(this.filesDir)
    s.security.approvalPolicy = m
    const err = AgentSettingsStore.write(this.filesDir, s)
    this.agentToast = err === '' ? '审批策略已保存: ' + this.agentModeLabel(m) : err
  }

  // 升级 Phase 1: HMH 连接测试（经 AgentAdapter，不直接 import 引擎层）
  testHarness(): void {
    const url = this.cfgHarnessUrl.trim()
    if (url === '') {
      this.harnessToast = '请先填写服务地址'
      return
    }
    this.harnessTesting = true
    AgentAdapter.instance().testHmh(url).then((detail: string) => {
      this.harnessTesting = false
      this.harnessToast = detail
    })
  }

  agentModeLabel(m: ApprovalPolicyKind): string {
    if (m === 'strict') {
      return '每次审批'
    }
    if (m === 'standard') {
      return '仅危险审批'
    }
    return '风险自担'
  }

  // 升级 Phase 1: HMH 地址保存到 engines.hmh.baseUrl（原 harnessUrl 迁移目标）
  saveHarnessUrl(): void {
    const s = AgentSettingsStore.read(this.filesDir)
    s.engines.hmh.baseUrl = this.cfgHarnessUrl.trim()
    const err = AgentSettingsStore.write(this.filesDir, s)
    this.harnessToast = err === '' ? 'HMH 引擎地址已保存' : err
  }

  saveAi(): void {
    // P0-1: write() 返回错误消息,保存后立即 toast 反馈
    const err = LlmConfigStore.write(this.filesDir, {
      provider: this.cfgProvider,
      baseUrl: this.cfgBaseUrl,
      apiKey: this.cfgApiKey,
      model: this.cfgModel
    })
    if (err === '') {
      this.toast = 'AI 配置已保存'
      this.toastErr = false
    } else {
      this.toast = err
      this.toastErr = true
    }
  }

  @Builder
  CatItem(icon: string, label: string, idx: number) {
    Row({ space: 8 }) {
      Text(icon)
        .fontSize(DesignTokens.FONT_DISPLAY)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.cat === idx ? this.th().brand : this.th().iconStrong)
      Text(label)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(this.cat === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.cat === idx ? this.th().brand : this.th().ink)
    }
    .width('100%')
    .padding({ left: 12, top: 8, bottom: 8 })
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.cat === idx ? this.th().hover : Color.Transparent)
    .onClick(() => {
      this.cat = idx
    })
  }

  @Builder
  Row1(label: string, val: string): void {
    Row() {
      Text(label)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().ink)
      Blank()
      Text(val)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
    }
    .width('100%')
    .padding(DesignTokens.SPACE_MD)
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.th().panel)
  }

  build() {
    Row() {
      // 左侧分类(relay4: emoji→几何字符 + 第6类使用帮助 + 右边线分区)
      Column({ space: 2 }) {
        this.CatItem(AppIcons.TAB_START, '基础', 0)
        this.CatItem('⌨', '终端', 1)
        this.CatItem('◑', '主题', 2)
        this.CatItem('◎', '语言', 3)
        this.CatItem(AppIcons.CMD_AI, 'AI 模型', 4)
        this.CatItem('☰', '使用帮助', 5)
      }
      .width(140)
      .height('100%')
      .padding(DesignTokens.SPACE_SM)
      .backgroundColor(this.th().surface)
      .border({ width: { right: 1 }, color: this.th().hairline })

      // 右侧配置区
      Scroll() {
        Column({ space: 10 }) {
          if (this.cat === 0) {
            Text('基础')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            this.Row1('启动时恢复上次会话', this.autoReconnect ? '开' : '关')
            this.Row1('关闭标签前确认', this.confirmClose ? '开' : '关')
            this.Row1('应用版本', 'v1.1.0 (KaihongOS 适配)')
            this.Row1('开源协作', 'Apache 2.0')
            Text('© 2026 一站AI终端')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th().inkSubtle)
            Text('基于开源项目 upstream(Apache-2.0)二次开发')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th().inkSubtle)
          } else if (this.cat === 1) {
            Text('终端')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            this.Row1('字号', this.fontSize.toString() + 'px')
            this.Row1('回滚缓冲行数', this.scrollback.toString())
            this.Row1('初始列数', this.cols.toString())
            this.Row1('编码', 'UTF-8')
            this.Row1('退格键映射', 'DEL')
          } else if (this.cat === 2) {
            Text('主题')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            Row({ space: 8 }) {
              ForEach(['dark', 'light'], (n: string) => {
                Text(n === 'dark' ? '暗色' : '浅色')
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontWeight(this.theme === n ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.theme === n ? this.th().brand : this.th().inkSubtle)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .border({ width: 1, color: this.theme === n ? this.th().brand : this.th().hairline })
                  .backgroundColor(this.theme === n ? this.th().hover : this.th().panel)
                  .onClick(() => {
                    this.theme = n
                    this.onThemeChange(n)
                  })
              }, (n: string) => n)
            }
            .width('100%')
          } else if (this.cat === 3) {
            Text('语言')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            Column({ space: 4 }) {
              ForEach(['zh-CN', 'en-US', 'ja-JP', 'ko-KR'], (l: string) => {
                Text(l)
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.lang === l ? this.th().brand : this.th().inkSubtle)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .border({ width: 1, color: this.lang === l ? this.th().brand : this.th().hairline })
                  .backgroundColor(this.lang === l ? this.th().hover : this.th().panel)
                  .alignSelf(ItemAlign.Start)
                  .onClick(() => {
                    this.lang = l
                  })
              }, (l: string) => l)
            }
            .alignItems(HorizontalAlign.Start)
            Text('完整 9 语言按官方 i18n 资源接入')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
          } else if (this.cat === 4) {
            Text('AI 模型')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            Row({ space: 8 }) {
              Text('Anthropic')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.cfgProvider === 'anthropic' ? this.th().brand : this.th().inkSubtle)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(DesignTokens.RADIUS_MD)
                .border({ width: 1, color: this.cfgProvider === 'anthropic' ? this.th().brand : this.th().hairline })
                .backgroundColor(this.cfgProvider === 'anthropic' ? this.th().hover : this.th().panel)
                .onClick(() => {
                  this.cfgProvider = 'anthropic'
                  this.cfgBaseUrl = 'https://api.anthropic.com'
                  this.cfgModel = 'claude-sonnet-4-5'
                })
              Text('OpenAI')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.cfgProvider === 'openai' ? this.th().brand : this.th().inkSubtle)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(DesignTokens.RADIUS_MD)
                .border({ width: 1, color: this.cfgProvider === 'openai' ? this.th().brand : this.th().hairline })
                .backgroundColor(this.cfgProvider === 'openai' ? this.th().hover : this.th().panel)
                .onClick(() => {
                  this.cfgProvider = 'openai'
                  this.cfgBaseUrl = 'https://api.openai.com/v1'
                  this.cfgModel = 'gpt-4o-mini'
                })
            }
            .width('100%')
            Column({ space: 6 }) {
              TextInput({ placeholder: 'Base URL(如 https://api.anthropic.com)', text: this.cfgBaseUrl })
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .placeholderColor(this.th().inkSubtle)
                .backgroundColor(this.th().inputBg)
                .border({ width: 1, color: this.th().hairline })
                .borderRadius(DesignTokens.RADIUS_MD)
                .height(36)
                .onChange((v: string) => {
                  this.cfgBaseUrl = v
                })
              // P0-2: 密钥输入框修复——36px 高 + 12px 字号 + 明文切换 + 边框
              Row({ space: 6 }) {
                TextInput({ placeholder: 'API Key(右侧 👁 切换明文)', text: this.cfgApiKey })
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().ink)
                  .placeholderColor(this.th().inkSubtle)
                  .backgroundColor(this.th().inputBg)
                  .border({ width: 1, color: this.th().hairline })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .height(36)
                  .layoutWeight(1)
                  .type(this.showKey ? InputType.Normal : InputType.Password)
                  .onChange((v: string) => {
                    this.cfgApiKey = v
                  })
                Text('👁')
                  .fontSize(DesignTokens.FONT_HEADING)
                  .fontWeight(this.showKey ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.showKey ? this.th().brand : this.th().inkSubtle)
                  .width(34).height(36)
                  .textAlign(TextAlign.Center)
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .backgroundColor(this.th().inputBg)
                  .border({ width: 1, color: this.th().hairline })
                  .onClick(() => {
                    this.showKey = !this.showKey
                  })
                  .onHover((h: boolean) => {
                    this.hoverTip = h ? 'stKeyEye' : ''
                    this.hoverOn = h
                  })
                  .bindPopup(this.hoverOn && this.hoverTip === 'stKeyEye', {
                    message: this.showKey ? '隐藏密钥' : '显示密钥明文',
                    placementOnTop: true
                  })
              }
              .width('100%')
              TextInput({ placeholder: 'Model(如 claude-sonnet-4-5)', text: this.cfgModel })
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .placeholderColor(this.th().inkSubtle)
                .backgroundColor(this.th().inputBg)
                .border({ width: 1, color: this.th().hairline })
                .borderRadius(DesignTokens.RADIUS_MD)
                .height(36)
                .onChange((v: string) => {
                  this.cfgModel = v
                })
              Text('保存')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().onBrand)
                .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                .backgroundColor(this.th().brand)
                .borderRadius(DesignTokens.RADIUS_MD)
                .alignSelf(ItemAlign.Start)
                .onClick(() => this.saveAi())
                .onHover((h: boolean) => {
                  this.hoverTip = h ? 'stKeySave' : ''
                  this.hoverOn = h
                })
                .bindPopup(this.hoverOn && this.hoverTip === 'stKeySave', {
                  message: '保存模型配置到本地(立即生效)',
                  placementOnTop: true
                })
              // P0-3: 保存结果反馈
              if (this.toast !== '') {
                Text(this.toast)
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.toastErr ? this.th().danger : this.th().success)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(DesignTokens.RADIUS_SM)
                  .backgroundColor(this.th().hover)
                  .alignSelf(ItemAlign.Start)
                  .onClick(() => {
                    this.toast = ''
                  })
              }
            }
            .alignItems(HorizontalAlign.Start)

            // ===== M6 relay3: 智能体审批门三档 =====
            Divider()
              .strokeWidth(1)
              .color(this.th().hairline)
              .margin({ top: 18, bottom: 14 })
            Text('智能体审批')
              .fontSize(DesignTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
              .alignSelf(ItemAlign.Start)
            Column({ space: 6 }) {
              ForEach(['strict', 'standard', 'open'], (m: string) => {
                Text(this.agentModeLabel(m as ApprovalPolicyKind))
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.agentMode === m ? this.th().brand : this.th().inkSubtle)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .border({ width: 1, color: this.agentMode === m ? this.th().brand : this.th().hairline })
                  .backgroundColor(this.agentMode === m ? this.th().hover : this.th().panel)
                  .onClick(() => this.saveAgentMode(m as ApprovalPolicyKind))
              }, (m: string) => m)
            }
            .alignItems(HorizontalAlign.Start)
            Text(this.agentMode === 'strict' ? '每次工具调用都弹审批卡' :
              (this.agentMode === 'standard' ? '只读与普通写入直放, 危险/远端操作才审批' : '所有命令直接执行(风险自担)'))
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.agentMode === 'open' ? this.th().danger : this.th().inkSubtle)
            if (this.agentToast !== '') {
              Text(this.agentToast)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().success)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(DesignTokens.RADIUS_SM)
                .backgroundColor(this.th().hover)
                .alignSelf(ItemAlign.Start)
                .onClick(() => {
                  this.agentToast = ''
                })
            }

            // ===== M6 relay5: 增强模式(模式B: hmharness Web 直连) =====
            Divider()
              .strokeWidth(1)
              .color(this.th().hairline)
              .margin({ top: 18, bottom: 14 })
            Text('增强模式(hmharness 直连)')
              .fontSize(DesignTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
              .alignSelf(ItemAlign.Start)
            Column({ space: 6 }) {
              TextInput({ placeholder: 'harness 服务地址(如 http://192.168.161.1:7860)', text: this.cfgHarnessUrl })
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .placeholderColor(this.th().inkSubtle)
                .backgroundColor(this.th().inputBg)
                .border({ width: 1, color: this.th().hairline })
                .borderRadius(DesignTokens.RADIUS_MD)
                .height(36)
                .onChange((v: string) => {
                  this.cfgHarnessUrl = v
                })
              Row({ space: 8 }) {
                Text(this.harnessTesting ? '测试中…' : '测试连接')
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().surface)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .backgroundColor(this.harnessTesting ? this.th().iconMuted : this.th().brand)
                  .onClick(() => this.testHarness())
                Text('保存')
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().ink)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(DesignTokens.RADIUS_MD)
                  .border({ width: 1, color: this.th().hairline })
                  .backgroundColor(this.th().panel)
                  .onClick(() => this.saveHarnessUrl())
              }
              if (this.harnessToast !== '') {
                Text(this.harnessToast)
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().success)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(DesignTokens.RADIUS_SM)
                  .backgroundColor(this.th().hover)
                  .onClick(() => {
                    this.harnessToast = ''
                  })
              }
            }
            .alignItems(HorizontalAlign.Start)
            Text('连接自建 hmharness 服务(本地/局域网); 开启增强模式后智能体任务经 SSE 流式回显, 服务不可达时自动回落内置内核')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
          } else {
            // ===== relay4 C2: 使用帮助(快捷键 + 连接类型速览 + FAQ) =====
            Text('使用帮助')
              .fontSize(DesignTokens.FONT_HEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            Text('快捷键')
              .fontSize(DesignTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            Row() {
              Text('Ctrl + K')
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().ink)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(DesignTokens.RADIUS_SM)
                .backgroundColor(this.th().surfaceRaised)
                .border({ width: 1, color: this.th().hairline })
              Blank()
              Text('打开命令面板(搜索命令/连接)')
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().inkSubtle)
            }
            .width('100%')
            .padding(DesignTokens.SPACE_SM)
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().panel)
            Row() {
              Text(AppIcons.OP_ADD)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().ink)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(DesignTokens.RADIUS_SM)
                .backgroundColor(this.th().surfaceRaised)
                .border({ width: 1, color: this.th().hairline })
              Blank()
              Text('新建开始标签页(标签条右侧)')
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().inkSubtle)
            }
            .width('100%')
            .padding(DesignTokens.SPACE_SM)
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().panel)
            Row() {
              Text('长按')
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().ink)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(DesignTokens.RADIUS_SM)
                .backgroundColor(this.th().surfaceRaised)
                .border({ width: 1, color: this.th().hairline })
              Blank()
              Text('连接行呼出操作菜单(编辑/删除)')
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().inkSubtle)
            }
            .width('100%')
            .padding(DesignTokens.SPACE_SM)
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().panel)
            Text('连接类型速览')
              .fontSize(DesignTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            ForEach([[AppIcons.CONN_SSH, 'SSH', '远程主机的标准通道,22 端口'],
              [AppIcons.CONN_LOCAL, '本地终端', '设备本地 shell,免配置即开即用'],
              [AppIcons.CONN_DB, 'PostgreSQL / Redis / MySQL', '数据库直连,内置命令面板'],
              [AppIcons.CONN_VNC, 'VNC', '远程桌面(跨平台)'],
              [AppIcons.CONN_RDP, 'RDP', 'Windows 远程桌面'],
              [AppIcons.CONN_SPICE, 'SPICE', 'Linux 虚拟机远程桌面']], (r: string[]) => {
              Row({ space: 8 }) {
                Text(r[0])
                  .fontSize(DesignTokens.FONT_HEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.th().iconStrong)
                  .width(24)
                  .textAlign(TextAlign.Center)
                Text(r[1])
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().ink)
                  .constraintSize({ maxWidth: 180 })
                Blank()
                Text(r[2])
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().inkSubtle)
              }
              .width('100%')
              .padding(DesignTokens.SPACE_SM)
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.th().panel)
            }, (r: string[]) => r[1])
            Text('常见问题')
              .fontSize(DesignTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().ink)
            ForEach([['主密码忘了怎么办?', '首次设置后无法找回,只能重置(数据会清空),请务必牢记。'],
              ['如何导入 .utm 配置?', '连接面板 → 导入,选择导出的 JSON 文件即可(需相同主密码)。'],
              ['API Key 存在哪里?', '本地加密存储,不上传任何服务器;切换设备需重新填写。'],
              ['AI 审批三档有什么区别?', '全部确认=每步都问;仅危险确认=只读直放;全自动=不问(风险自担)。']], (f: string[]) => {
              Column({ space: 3 }) {
                Text('Q: ' + f[0])
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().ink)
                Text('A: ' + f[1])
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().inkSubtle)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(DesignTokens.SPACE_SM)
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.th().panel)
            }, (f: string[]) => f[0])
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(DesignTokens.SPACE_LG)
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(this.th().panel)
    }
    .width('100%')
    .height('100%')
  }
}
