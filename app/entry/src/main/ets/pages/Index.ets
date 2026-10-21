/**
 * 一站AI终端 入口页(LEG-4 退役重构,2026-10-15 用户指令:
 * 旧交互界面删除,功能全部收拢 工作台布局)。
 *
 * 本文件从 1313 行 legacy 双分支壳精简为 单模式壳:
 *  - 默认且唯一 GUI = AppShell 工作台(本地/SSH/Telnet 终端、连接管理、
 *    Agent 面板+AI 输入、SFTP、Git、palette、隧道、收藏全在工作台);
 *  - --ps shell legacy 通道退役(参数忽略);--ps agentPrompt/agentEngine
 *    直驱保留(RightPanel 消费);
 *  - 旧界面资产(pages/TerminalPage·ConnList·SftpPanel、AIDock)删除,
 *    服务层(SessionService/TelnetService/TunnelService/ZmodemService/
 *    ConnStore)全部保留——工作台与 legacy 的底层同源。
 * 历史版本见 git(a9cb958 起默认工作台;本提交完成退役)。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { WantParams } from '../common/WantParams';
import { AppShell } from '../workbench/shell/AppShell';
import { WorkbenchVm } from '../workbench/viewmodel/WorkbenchVm';
import { GuideOverlay } from '../components/GuideOverlay';
import { applyLocale, bindPersistLocale } from '../common/AppI18n';
import { applyFontScale, bindFontPersist } from '../common/UiFont';
import { UpdateChecker, UpdateResult, isNewer } from '../service/UpdateChecker';
import { t, curLocale } from '../common/AppI18n';

@Entry
@Component
struct Index {
  // +M1b: 外壳 ViewModel(生命周期与 Index 同;@State 驱动 @ObjectLink)
  @State workbenchVm: WorkbenchVm = new WorkbenchVm()
  @State themeName: string = 'dark'
  // relay4 C1: 首启引导浮层(filesDir/guide_done 存在则不再弹);
  // GUI 棒:StorageLink 接 palette「帮助 · 使用指引」重开信号
  @StorageLink('ut.guide.show') guideShow: boolean = false

  aboutToAppear(): void {
    // GUI-i18n 棒:语言初始化——filesDir/locale.txt(用户选择)回放;
    // 无档=缺省 zh-CN;持久化钩子注入(此后 setLocale 落盘)
    try {
      const ictx = getContext(this) as common.UIAbilityContext
      const lp = ictx.filesDir + '/locale.txt'
      let saved = ''
      try {
        saved = fs.readTextSync(lp).trim()
      } catch (e2) {
        saved = ''
      }
      applyLocale(saved)
      bindPersistLocale((l: string): void => {
        try {
          const f = fs.openSync(lp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE)
          fs.writeSync(f.fd, l)
          fs.closeSync(f)
        } catch (e3) {
          hilog.warn(0x0110, 'oat.index', 'locale persist fail')
        }
      })
    } catch (e) {
      applyLocale('')
    }
    // GUI-R3: 界面字号档回放(filesDir/uifont.txt;无档=1.0)+持久化钩子
    try {
      const fctx = getContext(this) as common.UIAbilityContext
      const fp = fctx.filesDir + '/uifont.txt'
      let savedScale = 1.0
      try {
        savedScale = Number(fs.readTextSync(fp).trim())
        if (Number.isNaN(savedScale)) {
          savedScale = 1.0
        }
      } catch (e2) {
        savedScale = 1.0
      }
      applyFontScale(savedScale)
      bindFontPersist((s: number): void => {
        try {
          const f = fs.openSync(fp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE)
          fs.writeSync(f.fd, s.toString())
          fs.closeSync(f)
        } catch (e3) {
          hilog.warn(0x0110, 'oat.index', 'uifont persist fail')
        }
      })
    } catch (e) {
      applyFontScale(1.0)
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const marker = ctx.filesDir + '/guide_done'
      let exists = false
      try {
        exists = fs.accessSync(marker)
      } catch (e2) {
        exists = false
      }
      if (!exists) {
        this.guideShow = true
      }
    } catch (e) {
      this.guideShow = true // 拿不到路径宁可弹(有跳过钮)
    }
    // FR(冷启即用+恢复复活,UI 层接线):存档恢复 → local 槽复活;
    // 全新基线 → p1 直接绑本地会话。放 aboutToAppear(vm 构造保持纯净,
    // 单测环境不启 PTY);PTY 无窗口依赖,web 挂载由可见性门控兜。
    if (this.workbenchVm.restoredFromArchive) {
      this.workbenchVm.reviveLocalSession()
    } else {
      this.workbenchVm.bindLocalSessionFor('p1')
    }
    // M8-relay14 dev channel: --ps agentPrompt/--ps agentEngine(工作台直驱:
    // 开右栏+落 Agent 页;文本经 AppStorage 信号,RightPanel 挂载后消费)
    if (WantParams.getAgentPrompt() !== '') {
      this.workbenchVm.rightPanelOpen = true
      this.workbenchVm.rightTab = 'agent'
      AppStorage.setOrCreate('ut.agent.prompt', WantParams.getAgentPrompt())
      const eng = WantParams.getAgentEngine()
      if (eng !== '') {
        AppStorage.setOrCreate('ut.agent.engine', eng)
      }
    }
    // --ps termCmd: 信号写入(工作台侧消费端留后续;legacy 直开终端已退役)
    if (WantParams.getTermCmd() !== '') {
      AppStorage.setOrCreate('ut.term.cmd', WantParams.getTermCmd())
    }
    // GUI-R3: 启动自动检查更新(update_auto.txt='1' 时;仅新版本 toast)
    try {
      const uctx = getContext(this) as common.UIAbilityContext
      let auto = false
      try {
        auto = fs.readTextSync(uctx.filesDir + '/update_auto.txt').trim() === '1'
      } catch (e4) {
        auto = false
      }
      if (auto) {
        UpdateChecker.check(curLocale()).then((r: UpdateResult): void => {
          if (r.ok && isNewer('2.1.0', r.latest)) {
            this.workbenchVm.toast(t('upd.found') + ' v' + r.latest)
          }
        }).catch((): void => {
        })
      }
    } catch (e) {
      // 自动检查失败静默
    }
  }

  // FR: 页面可见(冷启后台启动的窗口上前时也触发)——驱动 PaneSurface
  // 的 web 可见性门控(ArkWeb 隐藏窗口创建的 Web 永不 attach 且无重试)
  onPageShow(): void {
    this.workbenchVm.shellVisible()
  }

  // relay4 C1: 引导完成/跳过 → 写标记文件,永不再弹
  finishGuide(): void {
    this.guideShow = false
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const f = fs.openSync(ctx.filesDir + '/guide_done',
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE)
      fs.writeSync(f.fd, 'done')
      fs.closeSync(f)
    } catch (e) {
      hilog.error(0x0110, 'oat.index', 'finishGuide write fail: %{public}s',
        e instanceof Error ? e.message : String(e))
    }
  }

  build() {
    Stack() {
      AppShell({
        vm: this.workbenchVm
      })
      if (this.guideShow) {
        GuideOverlay({
          onFinish: () => {
            this.finishGuide()
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
