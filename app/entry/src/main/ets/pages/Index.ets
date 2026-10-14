/**
 * 一站AI终端 入口页(tty7-LEG-4 退役重构,2026-10-15 用户指令:
 * 旧交互界面删除,功能全部收拢 tty7 工作台布局)。
 *
 * 本文件从 1313 行 legacy 双分支壳精简为 tty7 单模式壳:
 *  - 默认且唯一 GUI = AppShell 工作台(本地/SSH/Telnet 终端、连接管理、
 *    Agent 面板+AI 输入、SFTP、Git、palette、隧道、收藏全在 tty7);
 *  - --ps shell legacy 通道退役(参数忽略);--ps agentPrompt/agentEngine
 *    直驱保留(RightPanel 消费);
 *  - 旧界面资产(pages/TerminalPage·ConnList·SftpPanel、AIDock)删除,
 *    服务层(SessionService/TelnetService/TunnelService/ZmodemService/
 *    ConnStore)全部保留——tty7 与 legacy 的底层同源。
 * 历史版本见 git(a9cb958 起默认 tty7;本提交完成退役)。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { WantParams } from '../common/WantParams';
import { AppShell } from '../tty7/shell/AppShell';
import { WorkbenchVm } from '../tty7/viewmodel/WorkbenchVm';
import { GuideOverlay } from '../components/GuideOverlay';

@Entry
@Component
struct Index {
  // +tty7-M1b: tty7 外壳 ViewModel(生命周期与 Index 同;@State 驱动 @ObjectLink)
  @State tty7Vm: WorkbenchVm = new WorkbenchVm()
  @State themeName: string = 'dark'
  // relay4 C1: 首启引导浮层(filesDir/guide_done 存在则不再弹)
  @State guideShow: boolean = false

  aboutToAppear(): void {
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
    // M8-relay14 dev channel: --ps agentPrompt/--ps agentEngine(tty7 直驱:
    // 开右栏+落 Agent 页;文本经 AppStorage 信号,RightPanel 挂载后消费)
    if (WantParams.getAgentPrompt() !== '') {
      this.tty7Vm.rightPanelOpen = true
      this.tty7Vm.rightTab = 'agent'
      AppStorage.setOrCreate('ut.agent.prompt', WantParams.getAgentPrompt())
      const eng = WantParams.getAgentEngine()
      if (eng !== '') {
        AppStorage.setOrCreate('ut.agent.engine', eng)
      }
    }
    // --ps termCmd: 信号写入(tty7 侧消费端留后续;legacy 直开终端已退役)
    if (WantParams.getTermCmd() !== '') {
      AppStorage.setOrCreate('ut.term.cmd', WantParams.getTermCmd())
    }
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
        vm: this.tty7Vm
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
