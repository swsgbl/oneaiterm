/**
 * tty7 右侧 Agent 面板(任务 tty7-M1d 桩 → M5a 实时化)。
 *
 * M5a:接 AgentEvent v1 总线(AgentEventBus)——事件流 List(正序贴底)+
 * 四类简化事件卡(state_changed/delta/tool_call/final)+底部输入行
 * (TextInput+发送钮,经 HmhEventBridge.sendTask 走 hmh 引擎)。
 * 状态点:bus 最近 state_changed 事件派生(working=brand/idle=success/
 * error=danger;无事件默认在线)。不发假事件(本地占位 delta 禁止),
 * 引擎未配置时 statusText 提示不崩溃。
 * V1 刷新纪律:事件数组**整体替换**(concat+slice)触发 ForEach 重评;
 * 同步分发回调轻(只拼数组+贴底)。红线:零业务 import(只消费总线/桥/VM)。
 *
 * M5b:审批卡(approval_required 渲染风险色边框+两钮[允许][拒绝],决策经
 * HmhEventBridge.decide 走 ApprovalManager 原通道——只调不造,决策不进 bus;
 * approval_result 同 toolId 回流后置灰;决策调用失败卡片保持可点+状态栏提示,
 * 永不 fail-open)。checkpoint 卡 '↻ 会话恢复'桩(M8 CLI 接 resume)。
 * 发送时传 vm.focusedPane(pane 绑定;run_started.paneId 落到焦点 pane)。
 *
 * M6b:上下文抽屉页签化(Agent | SFTP)。Agent 页=原事件流零功能改动(只挪
 * if 层级——events 为组件 @State,分支切换不重建组件不丢列表);SFTP 页接
 * 现有 SessionService.sshHandle 只读目录浏览(SftpBrowser,独立文件)。
 * 连接态=vm.termTick + SshWorkspaceProvider.active() 纯查询组合(同
 * PaneSurface termTick 模式;断线 onDead → termTick++ → 条件重评回未连接态)。
 * M7a:页签扩三页(Agent | SFTP | Git);drawerTab 提升为 vm.rightTab
 * (palette 'Git · 打开面板' 命令可指定落页);Git 页连接态 GitBrowser
 * (status/log 只读,写操作留 M7b),未连接态同 SFTP 文案模式。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AgentEvent } from '../agent/AgentEvent';
import { AgentEventBus } from '../agent/AgentEventBus';
import { HmhEventBridge } from '../agent/HmhEventBridge';
import { approvalToneOf, approvalSettled, checkpointLabel } from '../agent/ApprovalCardLogic';
import { drawerTabOf } from './SftpDrawerLogic';
import { SshWorkspaceProvider } from '../remote/RemoteWorkspaceProvider';
import { SftpBrowser } from './SftpBrowser';
import { GitBrowser } from './GitBrowser'; // +tty7-M7a: Git 只读页

/** delta 单条正文显示上限(溢出省略)。 */
const TEXT_CAP: number = 200;
/** 面板事件缓冲上限(>200 砍头;与 bus 环形一致)。 */
const PANEL_MAX: number = 200;

@Component
export struct RightPanel {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  @State events: AgentEvent[] = []
  @State input: string = ''
  @State agentState: string = '' // '' = 无事件(默认在线);idle|working|waiting|done|error
  // M7a:drawerTab 提升为 vm.rightTab(palette 命令可指定落页;组件不再自持)
  private subId: number = -1
  private scroller: Scroller = new Scroller()

  /** 页签切换(经 drawerTabOf 归一;Agent 事件列表是组件 @State,
   *  if/else 分支切换不销毁重建,列表天然不丢)。 */
  private switchTab(next: string): void {
    this.vm.setRightTab(drawerTabOf(next)) // +tty7-M7a: 经 vm 单源(白名单守卫)
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    // 挂载回放:取总线历史(面板级+全部;pane 过滤 M5b)
    this.events = AgentEventBus.instance().recent(50)
    this.agentState = this.lastState(this.events)
    this.subId = AgentEventBus.instance().subscribe((ev: AgentEvent): void => {
      // V1 规则:整体替换触发 ForEach 刷新(>200 砍头)
      this.events = this.events.concat([ev]).slice(-PANEL_MAX)
      if (ev.type === 'state_changed') {
        this.agentState = ev.state
      } else if (ev.type === 'run_started') {
        this.agentState = 'working'
      } else if (ev.type === 'final') {
        this.agentState = 'done'
      }
      this.scrollBottom()
    })
  }

  aboutToDisappear(): void {
    if (this.subId >= 0) {
      AgentEventBus.instance().unsubscribe(this.subId)
      this.subId = -1
    }
  }

  /** 回放缓冲里最近的 state(run_started/final/state_changed 均算)。 */
  private lastState(evs: AgentEvent[]): string {
    for (let i = evs.length - 1; i >= 0; i--) {
      const e = evs[i]
      if (e.type === 'state_changed') {
        return e.state
      }
      if (e.type === 'run_started') {
        return 'working'
      }
      if (e.type === 'final') {
        return 'done'
      }
    }
    return ''
  }

  private scrollBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom)
      } catch (e) {
        // 布局阶段不可调时静默(scrollEdge 不得杀刷新)
      }
    }, 50)
  }

  /** 状态点颜色:working/waiting=brand,error=danger,done/idle/''=success。 */
  private stateColor(): number {
    if (this.agentState === 'error') {
      return this.th().danger
    }
    if (this.agentState === 'working' || this.agentState === 'waiting') {
      return this.th().brand
    }
    return this.th().success
  }

  private stateLabel(): string {
    if (this.agentState === '') {
      return 'Agent'
    }
    if (this.agentState === 'working') {
      return 'Agent · 运行中'
    }
    if (this.agentState === 'waiting') {
      return 'Agent · 待审批'
    }
    if (this.agentState === 'error') {
      return 'Agent · 异常'
    }
    return 'Agent'
  }

  /** riskLevel 高危着色(remote/destructive=danger,terminal=warn)。 */
  private riskColor(ev: AgentEvent): number {
    if (ev.riskLevel === 'destructive' || ev.riskLevel === 'remote') {
      return this.th().danger
    }
    if (ev.riskLevel === 'terminal') {
      return this.th().warn
    }
    return this.th().inkSubtle
  }

  /** 审批风险色档(ApprovalCardLogic 纯函数;单测共靶)。 */
  private toneColor(tone: string): number {
    if (tone === 'danger') {
      return this.th().danger
    }
    if (tone === 'warn') {
      return this.th().warn
    }
    return this.th().brand
  }

  /** 审批决策:经桥走 ApprovalManager 原通道;失败卡片保持可点+状态栏提示
   *  (永不 fail-open——异常不吞、不假成功、不置灰)。 */
  private decideApproval(ev: AgentEvent, decision: string): void {
    HmhEventBridge.decide(ev.runId, ev.toolId, decision).then((ok: boolean): void => {
      if (!ok) {
        this.vm.setStatus('审批提交失败(通道异常),卡片保持可点')
      }
    }).catch((_e: Object): void => {
      this.vm.setStatus('审批提交失败(通道异常),卡片保持可点')
    })
  }

  /** 审批卡收口判定:事件流里同 toolId 的 approval_result 已回流 → 置灰。
   *  V1 规则:events 为 @State 数组,读即建立追踪(approval_result 回流时
   *  数组整体替换驱动卡片重评)。 */
  private approvalSettledFor(ev: AgentEvent): boolean {
    return approvalSettled(this.events, ev.toolId)
  }

  /** 超长文本截断(省略)。 */
  private capText(s: string): string {
    if (s.length <= TEXT_CAP) {
      return s
    }
    return s.substring(0, TEXT_CAP) + '…'
  }

  /** 发送:经 HmhEventBridge(hmh 引擎);未配置→提示不假成功;成功→只清输入。
   *  M5b:传 vm.focusedPane(pane 绑定;无引擎时 sendTask 返回 no_engine
   *  不产事件,pane 零标记——零回归)。 */
  private send(): void {
    const t = this.input.trim()
    if (t === '') {
      return
    }
    HmhEventBridge.sendTask(t, this.vm.focusedPane).then((r: string): void => {
      if (r === 'no_engine') {
        this.vm.setStatus('AI 引擎未配置')
      } else if (r.indexOf('reject:') === 0 || r.indexOf('fail:') === 0) {
        this.vm.setStatus('AI 任务未受理(' + r + ')')
      } else if (r === 'ok') {
        this.vm.setStatus('AI 任务已提交')
      }
    }).catch((_e: Object): void => {
      this.vm.setStatus('AI 任务发送失败')
    })
    this.input = '' // 不发假事件,只清输入行
  }

  @Builder
  EventCard(ev: AgentEvent) {
    if (ev.type === 'state_changed') {
      Row({ space: DesignTokens.SPACE_XS }) {
        Circle({ width: 5, height: 5 })
          .fill(ev.state === 'error' ? this.th().danger : this.th().success)
        Text(ev.text !== '' ? ev.text : ev.state)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'delta') {
      Text(this.capText(ev.text))
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(ev.kind === 'reasoning' ? this.th().inkSubtle : this.th().ink)
        .fontStyle(ev.kind === 'reasoning' ? FontStyle.Italic : FontStyle.Normal)
        .maxLines(6)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'tool_call') {
      Row({ space: DesignTokens.SPACE_XS }) {
        Text('🔧 ' + (ev.toolName !== '' ? ev.toolName : 'tool'))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.riskColor(ev))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (ev.riskLevel !== '') {
          Text('· ' + ev.riskLevel)
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.riskColor(ev))
        }
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'tool_result') {
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(ev.ok ? '✓ ' : '✗ ')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(ev.ok ? this.th().success : this.th().danger)
        Text(this.capText(ev.text !== '' ? ev.text : (ev.toolName !== '' ? ev.toolName : '')))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'approval_required') {
      // M5b 审批卡:风险色边框 + '需要审批: tool·digest' + [允许][拒绝]两钮;
      // approval_result 同 toolId 回流后置灰(决策不重发);未收口前可点。
      Column({ space: DesignTokens.SPACE_XS }) {
        Text('需要审批: ' + (ev.toolName !== '' ? ev.toolName : '') + '·' + this.capText(ev.argsDigest))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.approvalSettledFor(ev) ? this.th().inkSubtle : this.th().ink)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: DesignTokens.SPACE_SM }) {
          if (ev.riskLevel !== '') {
            Text('· ' + ev.riskLevel)
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.toneColor(approvalToneOf(ev.riskLevel)))
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          Text('允许')
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.approvalSettledFor(ev) ? this.th().inkSubtle : this.th().success)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .border({
              width: 1,
              color: this.approvalSettledFor(ev) ? this.th().hairline : this.th().success
            })
            .onClick(() => {
              if (!this.approvalSettledFor(ev)) {
                this.decideApproval(ev, 'approved')
              }
            })
          Text('拒绝')
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.approvalSettledFor(ev) ? this.th().inkSubtle : this.th().danger)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .border({
              width: 1,
              color: this.approvalSettledFor(ev) ? this.th().hairline : this.th().danger
            })
            .onClick(() => {
              if (!this.approvalSettledFor(ev)) {
                this.decideApproval(ev, 'denied')
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4, left: 6, right: 6 })
      .borderRadius(DesignTokens.RADIUS_SM)
      .border({
        width: 1,
        color: this.approvalSettledFor(ev) ? this.th().hairline : this.toneColor(approvalToneOf(ev.riskLevel))
      })
      .opacity(this.approvalSettledFor(ev) ? 0.55 : 1)
    } else if (ev.type === 'final') {
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(ev.ok ? '✓ 完成' : '✗ 失败')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(ev.ok ? this.th().success : this.th().danger)
        Text(this.capText(ev.text))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'run_started') {
      Row({ space: DesignTokens.SPACE_XS }) {
        Text('▶ 任务 ' + ev.runId)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().brand)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (ev.type === 'session_checkpoint') {
      // M5b 桩:'↻ 会话恢复 sessionId 前缀'(HMH resume 机制接入留 M8 CLI 棒)
      Text(checkpointLabel(ev.text === '' ? 'resumed' : ev.text))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().inkSubtle)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: 2, bottom: 2 })
    } else {
      // attention:轻提示行
      Text('· ' + this.capText(ev.text))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().inkSubtle)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: 2, bottom: 2 })
    }
  }

  build() {
    Column() {
      // ===== 标题行:Agent + 真实状态点(bus 最近 state 派生) =====
      Row({ space: DesignTokens.SPACE_SM }) {
        Text(this.stateLabel())
          .fontSize(DesignTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Circle({ width: 7, height: 7 })
          .fill(this.stateColor())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: DesignTokens.SPACE_MD,
        right: DesignTokens.SPACE_MD,
        top: DesignTokens.SPACE_MD,
        bottom: DesignTokens.SPACE_SM
      })
      .border({ width: { bottom: 1 }, color: this.th().hairline })

      // ===== M6b 页签行:Agent | SFTP pill(active=brand 底/surface 字) =====
      Row({ space: DesignTokens.SPACE_XS }) {
        Text('Agent')
          .fontSize(DesignTokens.FONT_LABEL)
          .fontColor(this.vm.rightTab === 'agent' ? this.th().surface : this.th().inkSubtle)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.vm.rightTab === 'agent' ? this.th().brand : Color.Transparent)
          .onClick(() => this.switchTab('agent'))
        Text('SFTP')
          .fontSize(DesignTokens.FONT_LABEL)
          .fontColor(this.vm.rightTab === 'sftp' ? this.th().surface : this.th().inkSubtle)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.vm.rightTab === 'sftp' ? this.th().brand : Color.Transparent)
          .onClick(() => this.switchTab('sftp'))
        Text('Git') // +tty7-M7a: Git 只读页
          .fontSize(DesignTokens.FONT_LABEL)
          .fontColor(this.vm.rightTab === 'git' ? this.th().surface : this.th().inkSubtle)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.vm.rightTab === 'git' ? this.th().brand : Color.Transparent)
          .onClick(() => this.switchTab('git'))
        Blank().layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_XS })

      // ===== Agent 页:事件流(正序贴底;V1 整体替换驱动 ForEach)。
      //  M6b:与底部输入行同包 'agent' 分支——分支切换不销毁组件,events
      //  (@State)不丢;SFTP 页为并列分支。 =====
      if (this.vm.rightTab === 'agent') {
        Scroll(this.scroller) {
        Column() {
          if (this.events.length === 0) {
            Text('暂无事件;输入任务后此处实时显示 Agent 事件流')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
              .padding(DesignTokens.SPACE_MD)
          }
          ForEach(this.events, (ev: AgentEvent) => {
            this.EventCard(ev)
          }, (ev: AgentEvent) => ev.seq.toString() + ':' + ev.type + ':' + ev.text.length.toString())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Bottom)
      .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD })

      // ===== 底部输入行:TextInput + 发送钮 =====
      Row({ space: DesignTokens.SPACE_SM }) {
        TextInput({ placeholder: '向 Agent 发任务…', text: this.input })
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
        Text('发送')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().surface)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(DesignTokens.RADIUS_MD)
          .backgroundColor(this.th().brand)
          .onClick(() => this.send())
      }
      .width('100%')
      .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
      .alignItems(VerticalAlign.Center)
      .border({ width: { top: 1 }, color: this.th().hairline })
      } else if (this.vm.rightTab === 'git') {
        // ===== Git 页(+tty7-M7a):连接态 GitBrowser(status/log 只读);
        //  未连接态同 SFTP 文案模式。条件读 vm.rightTab(@Observed 字段)
        //  + termTick/active() 纯查询组合(断线 onDead → termTick++ 重评)。 =====
        if (this.vm.termTick >= 0 && SshWorkspaceProvider.active()) {
          GitBrowser({ themeName: this.themeName })
        } else {
          Column({ space: DesignTokens.SPACE_XS }) {
            Text('SSH 会话未连接')
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor(this.th().inkSubtle)
            Text('先在 palette 建立 SSH 会话')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
          }
          .width('100%')
          .padding({ top: DesignTokens.SPACE_LG })
        }
      } else if (this.vm.termTick >= 0 && SshWorkspaceProvider.active()) {
        // ===== SFTP 页·连接态:只读目录浏览(SftpBrowser;
        //  条件读 vm.termTick + active() 纯查询——断线 onDead →
        //  termTick++ → 重评回未连接分支;组件重建即重列目录) =====
        SftpBrowser({ themeName: this.themeName })
      } else {
        // ===== SFTP 页·未连接态 =====
        Column({ space: DesignTokens.SPACE_XS }) {
          Text('SSH 会话未连接')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
          Text('先在 palette 建立 SSH 会话')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
        }
        .width('100%')
        .padding({ top: DesignTokens.SPACE_LG })
      }
    }
    .width(300)
    .height('100%')
    .backgroundColor(this.th().panel)
    .border({ width: { left: 1 }, color: this.th().hairline })
  }
}
