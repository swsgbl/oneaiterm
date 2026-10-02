/**
 * AI 智能体 Dock（底部可折叠工作坞）——升级 Phase 4 / 任务 5.1~5.4 改造。
 *
 * 仅依赖 AgentProvider/AgentAdapter（收口）：经 AgentAdapter 六方法调用 AI 能力，
 * UI 只消费统一 AgentEvent（无引擎协议解析）；三引擎选择（本地/HMH/ACP）。
 * 展开态 220px（不遮挡终端下半区，spec 5.5.1.2）：
 *   Dock 头(输入行 + 四类入口 + 审批策略三档 + 引擎选择 + 轮次指示 + 折叠钮) +
 *   消息流(用户气泡/AI 气泡/工具卡三类; 工具卡=命令+结果摘要+审批按钮+档位徽标)。
 * 四类 AI 入口（spec 5.5.1.1）：Explain/Generate/Execute/Agent Session。
 * 档位徽标颜色分级（spec 5.5.1.5）：destructive=红/remote=橙/terminal=蓝/workspace_write=绿/read_only=灰。
 * 折叠态 28px 细条。主题经 @StorageProp('ut.theme') 接入。
 */
import { common } from '@kit.AbilityKit';
import { AppTheme, themeByName } from '../common/AppTheme';
import {
  AgentAdapter
} from '../agent/AgentAdapter';
import {
  AgentEvent, AgentSessionConfig, AgentSessionHandle, PromptAck, PromptInput,
  ApprovalDecision, ApprovalPolicyKind, APPROVAL_TIMEOUT_MS
} from '../agent/AgentProvider';
import { AgentSettings, AgentSettingsStore } from '../service/AgentSettingsStore';
import { DesignTokens } from '../common/DesignTokens';
import { AppIcons } from '../common/AppIcons';
import { EmptyState } from './EmptyState';
import { LoadingState } from './LoadingState';

const TAG: string = 'oat.dock';

/** Dock 消息条目(三类: user/assistant/tool + 审批态)。 */
class DockMsg {
  kind: string = 'user' // 'user' | 'assistant' | 'tool'
  text: string = ''
  name: string = ''
  args: string = ''
  result: string = ''
  requestId: string = ''
  pending: boolean = false // 工具卡待审批(显示允许/拒绝按钮)
  refused: boolean = false
  level: string = '' // 安全分级档位徽标（Phase 4 贯穿 UX）
  note: string = '' // 卡片附注（审批等待/回落提示）
}

@Component
export struct AIDock {
  @StorageProp('ut.theme') themeName: string = 'dark'
  @State open: boolean = false
  @State input: string = ''
  @State msgs: DockMsg[] = []
  @State policy: ApprovalPolicyKind = 'strict'
  @State round: number = 0
  @State running: boolean = false
  @State approvalPending: boolean = false
  @State msgSeq: number = 0
  // 引擎选择（'local' | 'hmh' | 'acp'；三引擎可切换）
  @State engineType: string = 'local'
  // AI 入口模式（'agent' | 'explain' | 'generate' | 'execute'）
  @State aiMode: string = 'agent'
  private sessionId: string = ''
  private unsub: (() => void) | null = null
  private lastTask: string = ''
  private scroller: Scroller = new Scroller()
  private filesDir: string = ''
  private policyNames: string[] = ['每次审批', '仅危险', '风险自担']
  private policyVals: ApprovalPolicyKind[] = ['strict', 'standard', 'open']
  private engineNames: string[] = ['本地', 'HMH', 'ACP']
  private engineVals: string[] = ['local', 'hmh', 'acp']
  private modeNames: string[] = ['会话', '解释', '生成', '执行']
  private modeVals: string[] = ['agent', 'explain', 'generate', 'execute']
  private streamMsg: DockMsg | null = null

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  private inputPlaceholder(): string {
    if (this.aiMode === 'explain') {
      return '选中命令/日志后点击解释，或输入要解释的内容'
    }
    if (this.aiMode === 'generate') {
      return '描述想要的命令，如：查找大文件'
    }
    if (this.aiMode === 'execute') {
      return '输入要执行的命令或描述操作'
    }
    return '描述任务，如：在终端执行 uname -a 并告诉我内核版本号'
  }

  private levelBadgeColor(level: string): number {
    if (level === 'destructive') {
      return this.th().danger
    }
    if (level === 'remote') {
      return this.th().warn
    }
    if (level === 'terminal') {
      return this.th().brand
    }
    if (level === 'workspace_write') {
      return this.th().success
    }
    return this.th().inkSubtle
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext
    this.filesDir = ctx.filesDir
    const s: AgentSettings = AgentSettingsStore.read(this.filesDir)
    this.policy = s.security.approvalPolicy
  }

  aboutToDisappear(): void {
    this.closeSession()
  }

  private closeSession(): void {
    const u = this.unsub
    this.unsub = null
    if (u !== null) {
      u()
    }
    this.streamMsg = null
  }

  private pushMsg(m: DockMsg): void {
    this.msgSeq++
    this.msgs.push(m)
  }

  private pushAssistant(text: string): void {
    const m = new DockMsg()
    m.kind = 'assistant'
    m.text = text
    this.pushMsg(m)
  }

  // ===== 统一 AgentEvent 消费（UI 无引擎协议解析） =====
  private onAgentEvent(e: AgentEvent): void {
    if (e.kind === 'message') {
      const ab = this.streamMsg
      if (ab !== null) {
        ab.text = ab.text === '' ? e.text : ab.text + '\n' + e.text
        if (this.msgs.indexOf(ab) < 0 && ab.text !== '') {
          this.pushMsg(ab)
        }
      } else if (e.text !== '') {
        this.pushAssistant(e.text)
      }
    } else if (e.kind === 'done') {
      const sm = this.streamMsg
      if (sm !== null) {
        if (e.text !== '' && e.text !== sm.text) {
          sm.text = e.text
        }
      } else if (e.text !== '') {
        this.pushAssistant(e.text)
      }
      this.running = false
      this.streamMsg = null
      this.closeSession()
    } else if (e.kind === 'tool_call') {
      const tv = e.tool
      const m = new DockMsg()
      m.kind = 'tool'
      m.name = tv !== null ? tv.name : 'tool'
      m.args = tv !== null ? tv.argsDigest : ''
      m.result = tv !== null && tv.result !== '' ? (tv.isError ? '✗ ' + tv.result : '✓ ' + tv.result) : ''
      m.level = e.level
      this.pushMsg(m)
    } else if (e.kind === 'need_approval') {
      const av = e.approval
      const m = new DockMsg()
      m.kind = 'tool'
      m.name = av !== null ? av.toolName : 'approval'
      m.args = av !== null ? av.argsDigest : ''
      m.requestId = av !== null ? av.requestId : ''
      m.level = e.level
      m.pending = true
      m.note = '待审批(' + Math.round(APPROVAL_TIMEOUT_MS / 60000).toString() + ' 分钟超时自动拒绝)'
      this.pushMsg(m)
      this.approvalPending = true
    } else if (e.kind === 'approval_result') {
      const decision = e.text as ApprovalDecision
      for (const m of this.msgs) {
        if (m.kind === 'tool' && m.pending) {
          m.pending = false
          if (decision !== 'approved') {
            m.refused = true
            m.result = decision === 'timeout_denied' ? '已超时拒绝' : '已拒绝执行'
          }
        }
      }
      this.approvalPending = false
    } else if (e.kind === 'turn') {
      this.round = e.turn
    } else if (e.kind === 'error') {
      this.pushAssistant(e.text)
      this.running = false
      this.streamMsg = null
      this.closeSession()
    } else if (e.kind === 'state_changed' || e.kind === 'engine_state_changed') {
      this.pushAssistant(e.text)
    } else if (e.kind === 'audit_write_failed') {
      this.pushAssistant('审计写入失败')
    }
    this.scrollBottom()
  }

  private scrollBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom)
    }, 50)
  }

  // ===== 发送（经 AgentAdapter 六方法；每任务新会话） =====
  private send(): void {
    const t = this.input.trim()
    if (t === '' || this.running) {
      return
    }
    this.input = ''
    this.lastTask = t
    this.running = true
    const m = new DockMsg()
    m.kind = 'user'
    m.text = t
    this.pushMsg(m)
    const adapter = AgentAdapter.instance()
    const cfg = new AgentSessionConfig()
    cfg.engine = this.engineType as 'local' | 'acp' | 'hmh'
    cfg.title = t.substring(0, 40)
    adapter.createSession(cfg).then((h: AgentSessionHandle): void => {
      this.sessionId = h.sessionId
      this.closeSession()
      this.unsub = adapter.subscribe(h.sessionId, (e: AgentEvent): void => {
        this.onAgentEvent(e)
      })
      const note = adapter.getFallbackNote()
      if (note !== '') {
        this.pushAssistant(note)
      }
      this.streamMsg = new DockMsg()
      this.streamMsg.kind = 'assistant'
      this.streamMsg.text = ''
      const pi = new PromptInput()
      pi.text = this.buildPromptText(t)
      adapter.prompt(h.sessionId, pi).then((ack: PromptAck): void => {
        if (!ack.accepted) {
          this.running = false
          this.pushAssistant(ack.errCode === 'AGENT_MODEL_NOT_CONFIGURED'
            ? '未配置模型(设置→AI 模型)' : '任务未受理(' + ack.errCode + ')')
          this.closeSession()
        }
      }).catch((e: Object): void => {
        this.running = false
        this.pushAssistant('任务发送失败')
        this.closeSession()
      })
    }).catch((e: Object): void => {
      this.running = false
      const msg = e instanceof Error ? e.message : String(e)
      this.pushAssistant('创建会话失败: ' + msg)
    })
  }

  private buildPromptText(raw: string): string {
    if (this.aiMode === 'explain') {
      return '请解释以下内容：\n' + raw
    }
    if (this.aiMode === 'generate') {
      return '请生成一个命令来完成以下需求（只返回命令，不要执行）：\n' + raw
    }
    if (this.aiMode === 'execute') {
      return '请执行以下操作：\n' + raw
    }
    return raw
  }

  private setPolicy(p: ApprovalPolicyKind): void {
    const prev = this.policy
    this.policy = p
    const s = AgentSettingsStore.read(this.filesDir)
    s.security.approvalPolicy = p
    const err = AgentSettingsStore.write(this.filesDir, s)
    if (err !== '') {
      this.policy = prev
    }
  }

  private approve(requestId: string): void {
    for (const m of this.msgs) {
      if (m.kind === 'tool' && m.requestId === requestId && m.pending) {
        m.pending = false
      }
    }
    this.approvalPending = false
    AgentAdapter.instance().approve(this.sessionId, requestId, 'approved')
  }

  private deny(requestId: string): void {
    for (const m of this.msgs) {
      if (m.kind === 'tool' && m.requestId === requestId && m.pending) {
        m.pending = false
        m.refused = true
        m.result = '已拒绝执行'
      }
    }
    this.approvalPending = false
    AgentAdapter.instance().approve(this.sessionId, requestId, 'denied')
  }

  @Builder
  PolicyPill(label: string, idx: number) {
    Stack() {
      Text(label)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.policy === this.policyVals[idx] ? this.th().surface : this.th().inkSubtle)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(DesignTokens.RADIUS_MD)
        .border({ width: 1, color: this.policy === this.policyVals[idx] ? this.th().brand : this.th().hairline })
        .backgroundColor(this.policy === this.policyVals[idx] ? this.th().brand : Color.Transparent)
    }
    .width(44)
    .height(32)
    .hitTestBehavior(HitTestMode.Default)
    .margin({ left: 2 })
    .onClick(() => this.setPolicy(this.policyVals[idx]))
  }

  @Builder
  EnginePill() {
    Row({ space: 2 }) {
      ForEach(this.engineVals, (val: string, idx?: number) => {
        Stack() {
          Text(this.engineNames[idx ?? 0])
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.engineType === val ? this.th().surface : this.th().inkSubtle)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .border({ width: 1, color: this.engineType === val ? this.th().brand : this.th().hairline })
            .backgroundColor(this.engineType === val ? this.th().brand : Color.Transparent)
        }
        .width(36)
        .height(28)
        .hitTestBehavior(HitTestMode.Default)
        .onClick(() => {
          this.engineType = val
        })
      }, (val: string) => val)
    }
  }

  @Builder
  ModePill() {
    Row({ space: 2 }) {
      ForEach(this.modeVals, (val: string, idx?: number) => {
        Stack() {
          Text(this.modeNames[idx ?? 0])
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.aiMode === val ? this.th().surface : this.th().inkSubtle)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .border({ width: 1, color: this.aiMode === val ? this.th().success : this.th().hairline })
            .backgroundColor(this.aiMode === val ? this.th().success : Color.Transparent)
        }
        .width(36)
        .height(28)
        .hitTestBehavior(HitTestMode.Default)
        .onClick(() => {
          this.aiMode = val
        })
      }, (val: string) => val)
    }
  }

  @Builder
  MsgRow(m: DockMsg) {
    if (m.kind === 'user') {
      Row() {
        Blank()
        Text(m.text)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().onBrand)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.th().brand)
          .constraintSize({ maxWidth: '80%' })
      }
      .width('100%')
      .margin({ top: 6, bottom: 2 })
    } else if (m.kind === 'assistant') {
      Row() {
        Text(m.text)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.th().panel)
          .border({ width: 1, color: this.th().hairline })
          .constraintSize({ maxWidth: '80%' })
      }
      .width('100%')
      .margin({ top: 6, bottom: 2 })
    } else {
      // 工具卡: 名称+命令(脱敏) → 结果摘要 → 审批按钮(待审批时)
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text('⚙ ' + m.name)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().brand)
          if (m.level !== '') {
            Text(m.level)
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.levelBadgeColor(m.level))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(DesignTokens.RADIUS_SM)
              .border({ width: 1, color: this.levelBadgeColor(m.level) })
          }
          Text(m.args)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        if (m.note !== '' && m.pending) {
          Text(m.note)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().warn)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.th().hover)
        }
        if (m.result !== '' && !m.pending) {
          Text(m.result)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.th().hover)
        }
        if (m.pending) {
          Row({ space: 8 }) {
            Text('允许')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().surface)
              .padding({ left: 14, right: 14, top: 4, bottom: 4 })
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.th().success)
              .onClick(() => this.approve(m.requestId))
            Text('拒绝')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().surface)
              .padding({ left: 14, right: 14, top: 4, bottom: 4 })
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.th().danger)
              .onClick(() => this.deny(m.requestId))
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
      }
      .width('100%')
      .padding(DesignTokens.SPACE_SM)
      .borderRadius(DesignTokens.RADIUS_MD)
      .backgroundColor(this.th().surfaceRaised)
      .border({ width: 1, color: this.th().hairline })
      .shadow({ radius: DesignTokens.SHADOW_SM_RADIUS, color: DesignTokens.SHADOW_SM_COLOR, offsetX: 0, offsetY: DesignTokens.SHADOW_SM_OFFSET_Y })
      .margin({ top: 4, bottom: 4 })
    }
  }

  build() {
    Column() {
      if (this.open) {
        // ===== Dock 头(36px): 标题+轮次 + 入口模式 + 审批策略 + 引擎选择 + 折叠钮 =====
        Row({ space: 4 }) {
          Text(AppIcons.CMD_AI)
            .fontSize(DesignTokens.FONT_DISPLAY)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().brand)
            .margin({ left: 8 })
          Text(this.running ? ('R' + this.round.toString() + '/12') : '空闲')
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.running ? this.th().brand : this.th().inkSubtle)
          this.ModePill()
          Blank()
          this.PolicyPill(this.policyNames[0], 0)
          this.PolicyPill(this.policyNames[1], 1)
          this.PolicyPill(this.policyNames[2], 2)
          this.EnginePill()
          Text('▾')
            .fontSize(DesignTokens.FONT_HEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().iconStrong)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .accessibilityText('折叠AI坞')
            .onClick(() => {
              animateTo({
                duration: DesignTokens.DURATION_NORMAL,
                curve: Curve.EaseInOut
              }, () => {
                this.open = false
              })
            })
        }
        .width('100%')
        .height(36)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: { bottom: 1 }, color: this.th().hairline })

        // ===== 消息流(layoutWeight 撑满中段) =====
        Scroll(this.scroller) {
          Column() {
            if (this.msgs.length === 0 && !this.running) {
              EmptyState({
                icon: AppIcons.CMD_AI,
                title: 'AI 智能体',
                description: '输入自然语言指令,AI 将帮你操作终端'
              })
            } else if (this.running && this.msgs.length === 0) {
              LoadingState({ message: 'AI 思考中...' })
            } else {
              ForEach(this.msgs, (m: DockMsg) => {
                this.MsgRow(m)
              }, (m: DockMsg) => m.kind + '|' + m.requestId + '|' + m.text.substring(0, 40) + '|' + m.pending.toString() + '|' + m.refused.toString())
            }
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
          TextInput({ placeholder: this.inputPlaceholder(), text: this.input })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .placeholderColor(this.th().inkSubtle)
            .backgroundColor(this.th().inputBg)
            .border({ width: 1, color: this.th().hairline })
            .borderRadius(DesignTokens.RADIUS_MD)
            .height(32)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.input = v
            })
            .onSubmit(() => this.send())
          Text(this.running ? '…' : '发送')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().surface)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.running ? this.th().iconMuted : this.th().brand)
            .onClick(() => this.send())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      } else {
        // ===== 折叠态(28px 细条) =====
        Row({ space: 8 }) {
          Text(AppIcons.CMD_AI)
            .fontSize(DesignTokens.FONT_DISPLAY)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().brand)
          Text('智能体')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
          if (this.engineType !== 'local') {
            Text(this.engineType === 'hmh' ? 'H' : 'A')
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.th().success)
              .fontWeight(FontWeight.Bold)
          }
          if (this.running) {
            Text('R' + this.round.toString() + '/12')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().brand)
          }
          Blank()
          Text('▴')
            .fontSize(DesignTokens.FONT_DISPLAY)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().iconStrong)
            .accessibilityText('展开AI坞')
        }
        .width('100%')
        .height(28)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: { top: 1 }, color: this.th().hairline })
        .onClick(() => {
          animateTo({
            duration: DesignTokens.DURATION_NORMAL,
            curve: Curve.EaseInOut
          }, () => {
            this.open = true
          })
        })
      }
    }
    .width('100%')
    .height(this.open ? 220 : 28)
  }
}
