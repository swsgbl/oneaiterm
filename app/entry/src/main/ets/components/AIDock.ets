/**
 * M6 relay3 - AI 智能体 Dock(底部可折叠工作坞)。
 * 展开态 ~320px: Dock 头(输入行 + 模式三档切换 + 轮次指示 R1/12 + 折叠钮) +
 * 消息流(用户气泡/AI 气泡/工具卡三类; 工具卡=命令+结果摘要+审批按钮 允许/拒绝)。
 * 折叠态 28px 细条。复用 LlmConfigStore 配置 + AgentSettingsStore 三档。
 * 主题经 @StorageProp('ut.theme') 接入(relay1 P0-4 范式)。
 */
import { common } from '@kit.AbilityKit';
import { AppTheme, themeByName } from '../common/AppTheme';
import { AgentKernel, KernelEvent } from '../service/AgentKernel';
import { AgentSettings, AgentSettingsStore, ApprovalMode } from '../service/AgentSettingsStore';
import { LlmConfigStore } from '../service/LlmConfigStore';
import { HarnessStream, HarnessEventCbs } from '../service/HarnessClient';
import hilog from '@ohos.hilog';

const HS_TAG: string = 'oat.dock';

/** Dock 消息条目(三类: user/assistant/tool + 审批态)。 */
class DockMsg {
  kind: string = 'user' // 'user' | 'assistant' | 'tool'
  text: string = ''
  name: string = ''
  args: string = ''
  result: string = ''
  callId: string = ''
  pending: boolean = false // 工具卡待审批(显示允许/拒绝按钮)
  refused: boolean = false
  // M6 relay5: 增强模式(hmharness SSE)标记
  harnessNote: string = '' // 增强模式卡片附注(等待宿主审批/结果摘要/中断提示)
  harnessDone: boolean = false // 增强模式结果已回填
}

@Component
export struct AIDock {
  @StorageProp('ut.theme') themeName: string = 'dark'
  @State open: boolean = false
  @State input: string = ''
  @State msgs: DockMsg[] = []
  @State mode: ApprovalMode = 'confirm_all'
  @State round: number = 0
  @State running: boolean = false
  @State approvalPending: boolean = false
  @State msgSeq: number = 0
  // M6 relay5: 双引擎(内置内核 / 增强模式 hmharness 直连)
  @State enhanced: boolean = false
  private hStream: HarnessStream | null = null
  private hAssistant: DockMsg | null = null
  private hToolMsgs: DockMsg[] = []
  private hPendingApproval: DockMsg | null = null
  private lastTask: string = ''
  private scroller: Scroller = new Scroller()
  private filesDir: string = ''
  private modeNames: string[] = ['全部确认', '仅危险', '全自动']
  private modeVals: ApprovalMode[] = ['confirm_all', 'confirm_dangerous', 'bypass']

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    this.filesDir = ctx.filesDir
    const s = AgentSettingsStore.read(this.filesDir)
    this.mode = s.mode
    AgentKernel.onEvent = (e: KernelEvent): void => {
      this.onKernelEvent(e)
    }
  }

  aboutToDisappear(): void {
    AgentKernel.onEvent = (e: KernelEvent): void => {
    }
    this.closeHarness()
  }

  private closeHarness(): void {
    const st = this.hStream
    this.hStream = null
    if (st !== null) {
      st.close()
    }
    this.hAssistant = null
    this.hToolMsgs = []
    this.hPendingApproval = null
  }

  private pushMsg(m: DockMsg): void {
    this.msgSeq++
    this.msgs.push(m)
  }

  private onKernelEvent(e: KernelEvent): void {
    if (e.kind === 'user') {
      const m = new DockMsg()
      m.kind = 'user'
      m.text = e.text
      this.pushMsg(m)
    } else if (e.kind === 'assistant' || e.kind === 'done') {
      const m = new DockMsg()
      m.kind = 'assistant'
      m.text = e.text
      this.pushMsg(m)
    } else if (e.kind === 'tool') {
      const m = new DockMsg()
      m.kind = 'tool'
      m.name = e.name
      m.args = e.args
      m.result = e.result
      m.callId = e.callId
      this.pushMsg(m)
    } else if (e.kind === 'need_approval') {
      const m = new DockMsg()
      m.kind = 'tool'
      m.name = e.name
      m.args = e.args
      m.callId = e.callId
      m.pending = true
      this.pushMsg(m)
      this.approvalPending = true
    } else if (e.kind === 'round') {
      this.round = e.round
    } else if (e.kind === 'err') {
      const m = new DockMsg()
      m.kind = 'assistant'
      m.text = e.text
      this.pushMsg(m)
    }
    this.scrollBottom()
  }

  private scrollBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom)
    }, 50)
  }

  private send(): void {
    const t = this.input.trim()
    if (t === '' || this.running) {
      return
    }
    this.input = ''
    this.lastTask = t
    this.running = true
    if (this.enhanced) {
      this.sendEnhanced(t)
      return
    }
    AgentKernel.run(t).then(() => {
      this.running = false
    }).catch((e: Object) => {
      this.running = false
    })
  }

  // ===== M6 relay5: 增强模式(hm harness 直连) =====
  private sendEnhanced(task: string): void {
    const cfg = LlmConfigStore.read(this.filesDir)
    const url = cfg.harnessUrl === undefined ? '' : cfg.harnessUrl
    if (url === '') {
      this.pushHarnessError('未配置增强模式服务地址(设置→AI 模型→增强模式)')
      this.running = false
      return
    }
    const m = new DockMsg()
    m.kind = 'user'
    m.text = task
    this.pushMsg(m)
    const st = new HarnessStream(url)
    this.hStream = st
    // 流式 assistant 气泡(打字机追加 line/delta)
    const ab = new DockMsg()
    ab.kind = 'assistant'
    ab.text = ''
    this.hAssistant = ab
    const cbs: HarnessEventCbs = {
      onEvent: (name: string, data: string): void => {
        this.onHarnessEvent(name, data)
      },
      onError: (msg: string): void => {
        this.onHarnessError(msg)
      },
      onEnd: (): void => {
        this.onHarnessEnd()
      }
    }
    st.connect(cbs)
    st.send(task, 'default')
  }

  private onHarnessEvent(name: string, data: string): void {
    let obj: Record<string, string> = {}
    try {
      obj = JSON.parse(data) as Record<string, string>
    } catch (e) {
      obj = {}
    }
    if (name === 'line') {
      const ab = this.hAssistant
      if (ab !== null) {
        ab.text = ab.text === '' ? (obj['text'] === undefined ? '' : obj['text']) : ab.text + '\n' + (obj['text'] === undefined ? '' : obj['text'])
        // 首次有内容时入消息流
        if (this.msgs.indexOf(ab) < 0 && ab.text !== '') {
          this.pushMsg(ab)
        }
      }
      this.scrollBottom()
    } else if (name === 'delta') {
      const ab = this.hAssistant
      if (ab !== null) {
        const chunk = obj['chunk'] === undefined ? '' : obj['chunk']
        ab.text = ab.text + chunk
        if (this.msgs.indexOf(ab) < 0 && ab.text !== '') {
          this.pushMsg(ab)
        }
      }
      this.scrollBottom()
    } else if (name === 'tool') {
      const cm = new DockMsg()
      cm.kind = 'tool'
      cm.name = obj['name'] === undefined ? 'tool' : obj['name']
      cm.args = obj['args'] === undefined ? '' : obj['args'].toString().substring(0, 160)
      this.pushMsg(cm)
      this.hToolMsgs.push(cm)
      this.scrollBottom()
    } else if (name === 'toolResult') {
      const last = this.hToolMsgs.length > 0 ? this.hToolMsgs[this.hToolMsgs.length - 1] : null
      if (last !== null) {
        last.harnessDone = true
        const err = obj['isError'] === undefined ? false : obj['isError'] === 'true'
        last.result = err ? '✗ ' + (obj['preview'] === undefined ? '' : obj['preview'].toString().substring(0, 200))
          : '✓ ' + (obj['preview'] === undefined ? '' : obj['preview'].toString().substring(0, 200))
      }
      this.scrollBottom()
    } else if (name === 'approvalReq') {
      const am = new DockMsg()
      am.kind = 'tool'
      am.name = obj['name'] === undefined ? 'approval' : obj['name']
      am.args = obj['args'] === undefined ? '' : obj['args'].toString().substring(0, 160)
      am.harnessNote = '⚠ hmharness 等待宿主审批(web UI 决定), 5 分钟超时自动拒绝'
      this.pushMsg(am)
      this.hToolMsgs.push(am)
      this.hPendingApproval = am
      this.scrollBottom()
    } else if (name === 'approvalDone') {
      const pa = this.hPendingApproval
      if (pa !== null) {
        const granted = obj['granted'] === undefined ? false : obj['granted'] === 'true'
        pa.harnessDone = true
        pa.harnessNote = granted ? '✓ 宿主已批准' : '✗ 宿主已拒绝/超时'
      }
      this.hPendingApproval = null
      this.scrollBottom()
    } else if (name === 'final') {
      const ab = this.hAssistant
      const full = obj['text'] === undefined ? obj['result'] === undefined ? '' : obj['result'].toString() : obj['text']
      if (ab !== null && full !== '') {
        ab.text = full
      } else if (full !== '') {
        const fm = new DockMsg()
        fm.kind = 'assistant'
        fm.text = full
        this.pushMsg(fm)
      }
      this.finishHarness()
    } else if (name === 'error') {
      const ab = this.hAssistant
      if (ab !== null) {
        ab.text = ab.text === '' ? (obj['message'] === undefined ? '服务报错' : obj['message']) : ab.text + '\n' + (obj['message'] === undefined ? '' : obj['message'])
      }
      this.finishHarness()
    } else if (name === 'busy') {
      const b = obj['busy']
      if (b !== undefined) {
        hilog.info(0x0111, HS_TAG, 'busy=%{public}s', b)
      }
    }
  }

  private onHarnessError(msg: string): void {
    // 连接失败/不可达 -> 回落内置内核
    this.pushHarnessFallback(msg)
  }

  private onHarnessEnd(): void {
    // SSE 流断开: 任务可能仍在宿主跑
    const ab = this.hAssistant
    if (ab !== null && ab.text === '') {
      ab.text = '连接中断, 任务在宿主继续'
      this.pushMsg(ab)
    }
    this.finishHarness()
  }

  private finishHarness(): void {
    this.running = false
    this.closeHarness()
  }

  private pushHarnessError(msg: string): void {
    const m = new DockMsg()
    m.kind = 'assistant'
    m.text = msg
    this.pushMsg(m)
    this.scrollBottom()
  }

  private pushHarnessFallback(msg: string): void {
    this.pushHarnessError('服务不可达(' + msg + '), 已回落内置内核')
    this.closeHarness()
    this.enhanced = false
    const t = this.lastTask
    if (t !== '') {
      this.running = true
      AgentKernel.run(t).then(() => {
        this.running = false
      }).catch((e: Object) => {
        this.running = false
      })
    }
  }


  private setMode(m: ApprovalMode): void {
    this.mode = m
    const s = new AgentSettings()
    s.mode = m
    AgentSettingsStore.write(this.filesDir, s)
  }

  private approve(callId: string): void {
    for (const m of this.msgs) {
      if (m.callId === callId && m.pending) {
        m.pending = false
      }
    }
    this.approvalPending = false
    AgentKernel.approve()
  }

  private deny(callId: string): void {
    for (const m of this.msgs) {
      if (m.callId === callId && m.pending) {
        m.pending = false
        m.refused = true
        m.result = '已拒绝执行'
      }
    }
    this.approvalPending = false
    AgentKernel.deny()
  }

  @Builder
  ModePill(label: string, idx: number) {
    Text(label)
      .fontSize(10)
      .fontColor(this.mode === this.modeVals[idx] ? this.th().surface : this.th().inkSubtle)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(9)
      .border({ width: 1, color: this.mode === this.modeVals[idx] ? this.th().brand : this.th().hairline })
      .backgroundColor(this.mode === this.modeVals[idx] ? this.th().brand : Color.Transparent)
      .margin({ left: 4 })
      .onClick(() => this.setMode(this.modeVals[idx]))
  }

  @Builder
  EnhancedPill() {
    Text('增强')
      .fontSize(10)
      .fontColor(this.enhanced ? this.th().surface : this.th().inkSubtle)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(9)
      .border({ width: 1, color: this.enhanced ? this.th().success : this.th().hairline })
      .backgroundColor(this.enhanced ? this.th().success : Color.Transparent)
      .margin({ left: 4 })
      .onClick(() => {
        this.enhanced = !this.enhanced
      })
  }

  @Builder
  MsgRow(m: DockMsg) {
    if (m.kind === 'user') {
      Row() {
        Blank()
        Text(m.text)
          .fontSize(12)
          .fontColor(this.th().surface)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(10)
          .backgroundColor(this.th().brand)
          .constraintSize({ maxWidth: '80%' })
      }
      .width('100%')
      .margin({ top: 6, bottom: 2 })
    } else if (m.kind === 'assistant') {
      Row() {
        Text(m.text)
          .fontSize(12)
          .fontColor(this.th().ink)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(10)
          .backgroundColor(this.th().panel)
          .border({ width: 1, color: this.th().hairline })
          .constraintSize({ maxWidth: '80%' })
      }
      .width('100%')
      .margin({ top: 6, bottom: 2 })
    } else {
      // 工具卡: 名称+命令 → 结果摘要 → 审批按钮(待审批时)
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text('⚙ ' + m.name)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().brand)
          Text(m.args)
            .fontSize(11)
            .fontColor(this.th().ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        if (m.harnessNote !== '') {
          Text(m.harnessNote)
            .fontSize(10)
            .fontColor(m.harnessDone ? (m.refused ? this.th().danger : this.th().success) : this.th().warn)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(4)
            .backgroundColor(this.th().hover)
        }
        if (m.result !== '' && !m.pending) {
          Text(m.result)
            .fontSize(10)
            .fontColor(this.th().inkSubtle)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(4)
            .backgroundColor(this.th().hover)
        }
        if (m.pending) {
          Row({ space: 8 }) {
            Text('允许')
              .fontSize(11)
              .fontColor(this.th().surface)
              .padding({ left: 14, right: 14, top: 4, bottom: 4 })
              .borderRadius(6)
              .backgroundColor(this.th().success)
              .onClick(() => this.approve(m.callId))
            Text('拒绝')
              .fontSize(11)
              .fontColor(this.th().surface)
              .padding({ left: 14, right: 14, top: 4, bottom: 4 })
              .borderRadius(6)
              .backgroundColor(this.th().danger)
              .onClick(() => this.deny(m.callId))
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
      }
      .width('100%')
      .padding(8)
      .borderRadius(8)
      .backgroundColor(this.th().surfaceRaised)
      .border({ width: 1, color: this.th().hairline })
      .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: 2 })
      .margin({ top: 4, bottom: 4 })
    }
  }

  build() {
    Column() {
      if (this.open) {
        // ===== Dock 头(32px): 标题+轮次 + 模式三档 + 折叠钮 =====
        Row({ space: 6 }) {
          Text('✦ 智能体')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().brand)
            .margin({ left: 10 })
          Text(this.running ? ('R' + this.round.toString() + '/12') : '空闲')
            .fontSize(10)
            .fontColor(this.running ? this.th().brand : this.th().inkSubtle)
          Blank()
          this.ModePill(this.modeNames[0], 0)
          this.ModePill(this.modeNames[1], 1)
          this.ModePill(this.modeNames[2], 2)
          this.EnhancedPill()
          Text('▾')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().iconStrong)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.open = false
            })
        }
        .width('100%')
        .height(32)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: { bottom: 1 }, color: this.th().hairline })
        .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: -4 })

        // ===== 消息流(layoutWeight 撑满中段) =====
        Scroll(this.scroller) {
          Column() {
            ForEach(this.msgs, (m: DockMsg) => {
              this.MsgRow(m)
            }, (m: DockMsg) => m.kind + '|' + m.callId + '|' + m.text.substring(0, 40) + '|' + m.pending.toString() + '|' + m.refused.toString())
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .padding({ left: 12, right: 12 })

        // ===== 输入行 =====
        Row({ space: 8 }) {
          TextInput({ placeholder: '描述任务,如: 在终端执行 uname -a 并告诉我内核版本号', text: this.input })
            .fontSize(12)
            .fontColor(this.th().ink)
            .placeholderColor(this.th().inkSubtle)
            .backgroundColor(this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .borderRadius(6)
            .height(32)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.input = v
            })
            .onSubmit(() => this.send())
          Text(this.running ? '…' : '发送')
            .fontSize(12)
            .fontColor(this.th().surface)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(6)
            .backgroundColor(this.running ? this.th().iconMuted : this.th().brand)
            .onClick(() => this.send())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      } else {
        // ===== 折叠态(28px 细条) =====
        Row({ space: 8 }) {
          Text('✦')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().brand)
          Text('智能体')
            .fontSize(11)
            .fontColor(this.th().ink)
          if (this.enhanced) {
            Text('增')
              .fontSize(9)
              .fontColor(this.th().success)
              .fontWeight(FontWeight.Bold)
          }
          if (this.running) {
            Text('R' + this.round.toString() + '/12')
              .fontSize(10)
              .fontColor(this.th().brand)
          }
          Blank()
          Text('▴')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().iconStrong)
        }
        .width('100%')
        .height(28)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: { top: 1 }, color: this.th().hairline })
        .onClick(() => {
          this.open = true
        })
      }
    }
    .width('100%')
    .height(this.open ? 320 : 28)
  }
}
