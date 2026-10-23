/**
 * pane 面组件(任务 M1c,升级自 M1b PanePlaceholder)。
 * 结构:标题行(paneId + zoom 钮 + 关闭钮)+ 内容区(M1c 阶段为 paneId
 * 大字水印;M3 接 Terminal Core 时仅替换内容区)。
 * 交互:点击=focusPane;关闭钮=closePane;zoom 钮回调 onZoom(由 PaneGrid
 * 绑定 vm.zoomToggle)。焦点叶 brand 2px 高亮边框。零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AppIcons } from '../../common/AppIcons';
import { TermHost } from '../term/TermHost';
import { RemoteTermHost } from '../remote/RemoteTermHost';
import { TelTermHost } from '../remote/TelTermHost'; // +LEG-2: telnet 会话宿主
import { TermPaneView } from '../term/TermPaneView';
// RD-1: Web 加载系统 ttyd(ArkWeb;ADR-0002 运行时探测分流)
import { TermWebView } from '../term/TermWebView';
import { probeTtyd, reachState } from '../term/TermReach';
import { HmhEventBridge } from '../agent/HmhEventBridge';
import { AgentEventBus } from '../agent/AgentEventBus';
import { buildFinishedAttention } from './ParityUi';
import { unifiedDataChannel } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PaneDropTargets, PaneRectEntry, PaneDragState } from '../model/PaneDropTargets';
import { WebPaneRects } from '../model/WebPaneRects';
import { TtydSession } from '../term/TtydSession';
import { tr } from '../../common/AppI18n';
import { fsc } from '../../common/UiFont';

const M1E_TAG: string = 'wb.M1e'
const M1E_DOMAIN: number = 0x0301

/** 拖拽数据类型(M1e):自定义类型 'wb.pane-drag'(非 TEXT 家族)——
 *  规避 TextInput 捕获层对 general.plain-text 的默认 drop 消费(文本拖入
 *  编辑框会插字);自定义类型无默认消费方,onDrop 事件可达根容器。
 *  paneId 经 UnifiedRecord(type, value) 泛型构造承载(value:string)。 */
const DRAG_TYPE: string = 'wb.pane-drag'

/** R4e:键码 → 发送序列(单测靶)。字母 a-z=2017-2042 直转(小写;
 *  Shift/大小写由 IME 时代路径不可用,保持小写足够覆盖命令面);
 *  Enter=2054→\r;方向/退格/Tab→ANSI。IME 无关(KeyEvent 直达)。 */
export function keyToSeq(code: number): string {
  if (code >= 2017 && code <= 2042) {
    return String.fromCharCode(97 + code - 2017)
  }
  if (code === 2054) {
    return '\r'
  }
  return ansiOfKeyCode(code)
}

/** R4e:特殊键 → ANSI 序列(方向/退格/Tab/Home/End;单测靶)。 */
export function ansiOfKeyCode(code: number): string {
  if (code === 2034) {
    return '\x1b[D'
  }
  if (code === 2035) {
    return '\x1b[C'
  }
  if (code === 2036) {
    return '\x1b[A'
  }
  if (code === 2037) {
    return '\x1b[B'
  }
  if (code === 2038) {
    return '\x7f'
  }
  if (code === 2049) {
    return '\t'
  }
  if (code === 2078) {
    return '\x1b[H'
  }
  if (code === 2079) {
    return '\x1b[F'
  }
  return ''
}

@Component
export struct PaneSurface {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  paneId: string = ''
  /** zoom 切换回调(PaneGrid 绑定;组件自身不持有 zoom 语义)。 */
  onZoom: () => void = () => {
  }
  @State hoverClose: boolean = false
  /** M1e:拖拽高亮(可放目标 hover 边框;onDragEnter 置/onDragLeave 清)。 */
  @State dragOver: boolean = false
  /** M1e:本组件 onDragStart 携带的 paneId(onDragEnd 兜底换位用)。 */
  private dragPaneId: string = ''
  /** RD-1: 本 pane ttyd 可达三态(null=探测中;true=web;false=旧自绘)。 */
  @State ttydOk: boolean | null = null
  /** GUI-R4: 根矩形缓存(分支 onAppear 无 Area 上下文,用缓存发布)。 */
  private rectCache: number[] = [0, 0, 0, 0]
  /** R4e 键盘转发:透明 TextInput 控制器 + 影子缓冲(差分出键)。 */
  /** GUI-i18n: 占位/提示文案反应式语言。 */
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  /** RD-1: 退避重探链句柄(-1 未挂;pane 销毁清)。 */
  private reachTimer: number = -1
  /** R4i 自愈看门狗:web 分支激活期间周期性重发布矩形(show=webActive)。
   *  动机:实勘存在「shell 活/镜像活/像素黑」的矩形或显隐卡死形态(启动
   *  路径相关的时序竞速,R4h 修了已知的 0×0 形态,用户路径仍复现)——
   *  看门狗不区分成因,以最新占位面积强制重发布,层侧属性重应用驱动
   *  ArkWeb 表面重排版,任何卡死形态 3 秒内自愈。 */
  private healTimer: number = -1
  private webAreaCache: number[] = [0, 0, 0, 0]

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** RD-1: 探测入口(原:退避窗口内消费会话缓存探测 ttyd)。
   *  R4t:web 通道再次临时下线——R4s 的 SYNC_RENDER 用户实测显示仍零像素
   *  (eglQuerySurface failed 平台缺陷两种渲染模式通杀),回退自绘
   *  TermPaneView(用户实证可见+可打字的配置,R4q/R4r)。web 调查
   *  (EGL 表面/第二 pane 构造)按 HANDOFF-R4Q.md 另案推进,不在
   *  用户路径上试验。 */
  private probeReach(): void {
    this.ttydOk = false
    return
  }

  /** RD-1: 失败退避重试链(TermReach 1s/5s/30s;pane 销毁即断)。 */
  private scheduleReachRetry(): void {
    if (this.reachTimer !== -1) {
      clearTimeout(this.reachTimer)
    }
    const wait = reachState.nextProbeAt - Date.now()
    this.reachTimer = setTimeout(() => {
      this.reachTimer = -1
      this.probeReach()
    }, wait > 0 ? wait : 100)
  }

  /** RD-1: TermWebView 主文档加载失败兜底:invalidate 会话缓存
   *  (可达→unknown 立即重探)并本 pane 先降级旧自绘路径。 */
  private onTtydUnreachable(): void {
    reachState.invalidate(Date.now())
    this.ttydOk = false
    this.scheduleReachRetry()
  }

  /** 组件销毁清理:矩形注册表剔除本 pane(close/树重建后防幽灵矩形)。 */
  /** RD-1: pane 出现即探测 ttyd(会话缓存命中时零网络)。 */
  aboutToAppear(): void {
    this.probeReach()
    // GUI-R4: web 不可达回调注册(常驻层的 TermWebView → 本组件探测状态机)
    WebPaneRects.setUnreach(this.paneId, (): void => {
      this.onTtydUnreachable()
    })
  }

  aboutToDisappear(): void {
    PaneDropTargets.unregister(this.paneId)
    WebPaneRects.setUnreach(this.paneId, null)
    if (this.reachTimer !== -1) {
      clearTimeout(this.reachTimer)
      this.reachTimer = -1
    }
    this.stopHeal()
    // 注:不撤 WebPaneRects 条目——rev 整树重建也触发本回调,真关闭由
    // vm.closePane/closeTab 显式清理(GUI-R4 内容保活的关键约束)
  }

  /** web 分支激活判定(层可见性 = 探测过 + 窗口可见 + 本地会话槽)。 */
  private webActive(): boolean {
    return this.ttydOk === true && this.vm.shellVisibleTick > 0 &&
      this.vm.sessionKindOf(this.paneId) === 'local'
  }

  /** 分支 onAppear 入口:用缓存矩形发布(分支切换无 Area 回调)。
   *  R4h:缓存未测得(0×0)时强制 show=false——web 若以 0×0 创建会永久
   *  不可见(时序竞速实锤:快探路径下分支先于首布局激活,缓存为空);
   *  保持隐藏,待占位 onAreaChange 上报真实矩形后再显示。 */
  private publishFromCache(show: boolean): void {
    const real = this.rectCache[2] > 0 && this.rectCache[3] > 0
    WebPaneRects.update(this.paneId, this.rectCache[0], this.rectCache[1], this.rectCache[2], this.rectCache[3], show && real)
  }

  /** web 层矩形上报(布局变化/分支切换统一入口;show=false 仅隐藏保活)。 */
  private publishWebRect(show: boolean, n: Area): void {
    WebPaneRects.update(this.paneId,
      Number(n.globalPosition.x), Number(n.globalPosition.y),
      Number(n.width), Number(n.height), show)
  }

  /** R4i:自愈看门狗启动(幂等;3s 周期重发布,webActive 且面积有效才发)。 */
  private startHeal(): void {
    if (this.healTimer !== -1) {
      return
    }
    this.healTimer = setInterval((): void => {
      if (this.webActive() && this.webAreaCache[2] > 0 && this.webAreaCache[3] > 0) {
        WebPaneRects.update(this.paneId,
          this.webAreaCache[0], this.webAreaCache[1],
          this.webAreaCache[2], this.webAreaCache[3], true)
      }
    }, 3000)
  }

  private stopHeal(): void {
    if (this.healTimer !== -1) {
      clearInterval(this.healTimer)
      this.healTimer = -1
    }
  }

  build() {
    Column() {
      // 标题行:paneId/会话标题 + zoom 钮(◎)+ 关闭钮(×)
      // M2b:绑会话显示 slot.title(非空优先);表达式读 vm.slotsRev(绑定字段)
      // 建立追踪——V1 方法调用不追踪,sessionTitle 纯查询。
      // M1e:整行 draggable,onDragStart 携带自定义类型 'wb.pane.<id>'
      // (规避 TextInput 捕获层默认吞 plain-text drop);长按 500ms+移 10vp
      // 触发系统拖拽,不影响普通点击(zoom/关闭钮 onClick 正常,实测语义:
      // 点击位移<10vp 不起拖)。onDragEnd 兜底换位(覆盖捕获层吞 drop 场景)。
      Row({ space: DesignTokens.SPACE_XS }) {
        // M5b:agent 活跃标记——表达式读 vm.agentRev 建立追踪后调
        // bridge.activeOnPane 纯查询(run 未 final 时 '✦' 前缀;同 slotsRev 模式)
        Text((this.vm.agentRev >= 0 && HmhEventBridge.activeOnPane(this.paneId) ? '✦ ' : '') +
          (this.vm.slotsRev >= 0 ? this.vm.sessionTitle(this.paneId) : this.paneId))
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .layoutWeight(1)
          .fontColor(this.vm.focusedPane === this.paneId ? this.th().brand : this.th().inkSubtle)
        Text('◎')
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontColor(this.th().iconMuted)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText(this.paneId + ' 缩放切换')
          .onClick(() => {
            this.vm.focusPane(this.paneId)
            this.onZoom()
          })
        Text(AppIcons.OP_DELETE)
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontColor(this.hoverClose ? this.th().danger : this.th().inkSubtle)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText('关闭 ' + this.paneId)
          .onClick(() => this.closeWithConfirm())
          .onHover((h: boolean) => {
            this.hoverClose = h
          })
      }
      .width('100%')
      .height(20)
      .padding({ left: DesignTokens.SPACE_SM, right: DesignTokens.SPACE_SM })
      .alignItems(VerticalAlign.Center)
      .draggable(this.dragEnabled())
      .onDragStart((e: DragEvent) => {
        // 数据通道(主):同进程静态 PaneDragState——同 app 内拖拽 100% 可达,
        // 不依赖 UDMF 序列化(实勘:自定义类型 getData 取回失配)。
        // setData(bonus):跨窗口场景;try 吞自定义类型校验异常。
        this.dragPaneId = this.paneId
        PaneDragState.current = this.paneId
        try {
          const rec = new unifiedDataChannel.UnifiedRecord(DRAG_TYPE, this.paneId)
          e.setData(new unifiedDataChannel.UnifiedData(rec))
        } catch (e) {
          // UDMF 类型校验拒绝 → 静态通道已够,静默。
        }
        // CustomBuilder 允许 void:不设自定义拖影,系统用组件快照。
        hilog.info(M1E_DOMAIN, M1E_TAG, 'dragStart pane=%{public}s', this.paneId)
      })
      .onDragEnd((e: DragEvent) => {
        // 兜底换位:onDrop 不可达时(捕获层吞事件),以落点窗口坐标在
        // vm.dropTargetAt 找目标 pane 并换位。DRAG_SUCCESSFUL=0 表示
        // onDrop 已处理(主通道成功,不重复);其余(FAILED/CANCELED)走兜底。
        const srcId = this.dragPaneId
        this.dragPaneId = ''
        PaneDragState.current = ''
        hilog.info(M1E_DOMAIN, M1E_TAG, 'dragEnd pane=%{public}s result=%{public}d at %{public}d,%{public}d',
          srcId, e.getResult(), e.getWindowX(), e.getWindowY())
        if (srcId === '') {
          return
        }
        if (e.getResult() === DragResult.DRAG_SUCCESSFUL) {
          return
        }
        const tgt = this.vm.dropTargetAt(e.getWindowX(), e.getWindowY(), srcId)
        if (tgt !== '') {
          this.vm.swapPanes(srcId, tgt)
        }
      })
      .onClick(() => this.vm.focusPane(this.paneId)) // GUI-R4:焦点动作迁标题行(根容器不消费点击)

      // 内容区(M3a):绑定本 pane 的本地终端优先;否则 paneId 大字水印。
      // V1 规则:if 表达式直接读 vm 绑定字段 termTick 建立追踪(TermHost.bound()
      // 静态查询不追踪,termTick 变化驱动表达式重评,同 slotsRev 模式)。
      // M6a:本地或远程任一宿主 bound==paneId 均渲染终端;远程分支注入
      // model/writeFn/resizeFn(渲染键/捕获层/InputController 全复用)
      if (this.vm.termTick >= 0 && RemoteTermHost.bound() === this.paneId && RemoteTermHost.term() !== null) {
        TermPaneView({
          paneId: this.paneId,
          model: RemoteTermHost.term(),
          writeFn: (t: string): void => { RemoteTermHost.write(t) },
          resizeFn: (c: number, r: number): void => { RemoteTermHost.resize(c, r) },
          onDone: (): void => { this.onCmdDone(this.paneId) }, // PB:完成通知
          wantFocus: this.vm.focusedPane === this.paneId // 输入热修:仅焦点 pane 拉焦
        })
      } else if (this.vm.termTick >= 0 && TelTermHost.bound() === this.paneId && TelTermHost.term() !== null) {
        // LEG-2: telnet 会话 pane(model 注入渲染;80x24 固定网格,
        // resizeFn 省略——缺省 TermHost.resize 内部 model 守卫无害)
        TermPaneView({
          paneId: this.paneId,
          model: TelTermHost.term(),
          writeFn: (t: string): void => { TelTermHost.write(t) },
          onDone: (): void => { this.onCmdDone(this.paneId) },
          wantFocus: this.vm.focusedPane === this.paneId
        })
      } else if (this.vm.slotsRev >= 0 && this.vm.sessionKindOf(this.paneId) === 'local') {
        // GUI-R3 多本地:本地分支改按会话槽判定——web 架构下每个 pane 的
        // ttyd 即独立 shell,不再被 TermHost 单例锁死(「开新终端杀旧终端」
        // 修复);降级分支(ttyd 不可达)保留单例并给出占位提示(web 为主)。
        // RD-1: 运行时探测分流:ttydOk=null 探测中;true→TermWebView
        // (可见性门控);false→降级 TermPaneView。
        if (this.ttydOk === null) {
          Column() {
            Text(this.paneId)
              .fontSize(fsc(this.fontScale, 20))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().inkSubtle)
              .opacity(0.55)
            Text(tr(this.locale, 'pane.probing'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .opacity(0.7)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .onAppear(() => {
            this.publishFromCache(false)
          })
        } else if (this.ttydOk === true && this.vm.shellVisibleTick > 0) {
          // GUI-R4 生产级修复:web 终端与布局树解耦——本分支只画「透明
          // 占位 + 矩形上报」(WebPaneRects),真身在 AppShell 常驻
          // WebPaneLayer。布局树 rev 重建/分屏/换页只改矩形,web 实例
          // 与会话内容永不重载(用户实锤「新建分屏刷掉第一屏」根治)。
          // R4e 键盘确定性通路:全幅透明 TextInput 持焦点并把按键转发到
          // 同一 shell(视觉零存在)。**全部走 onKeyEvent 直转**(字母
          // 键码→字符,2054→\r,功能键→ANSI)——不依赖 IME 文本插入
          // (实勘:IME 连接断后 onChange 永不触发,但 KeyEvent 始终
          // 到达节点,昨夜 AceFocus 日志实锤);返回 true 消费防双发。
          Stack() {
            TextInput({
              placeholder: '',
            })
              .fontSize(fsc(this.fontScale, 13))
              .fontColor(Color.Transparent)
              .caretColor(Color.Transparent)
              .placeholderColor(Color.Transparent)
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .padding(0)
              .width('100%')
              .height('100%')
              .defaultFocus(this.vm.focusedPane === this.paneId)
              .onKeyEvent((e: KeyEvent) => {
                if (e.type === KeyType.Down) {
                  const seq = keyToSeq(e.keyCode)
                  if (seq !== '') {
                    TtydSession.sendText(this.paneId, seq)
                    return true
                  }
                }
                return false
              })
          }
          .layoutWeight(1)
          .width('100%')
          .backgroundColor(Color.Transparent)
          .onAppear(() => {
            this.publishFromCache(true)
          })
          // R4h:占位自身区域=web 真身矩形——分支切换/布局变化必触发本回调
          // (根容器 onAreaChange 在纯分支切换时不触发,0×0 卡死根源)。
          // R4i:缓存面积 + 启动自愈看门狗(周期重发布,兜住一切卡死形态)。
          .onAreaChange((_o: Area, n: Area) => {
            this.webAreaCache = [Number(n.globalPosition.x), Number(n.globalPosition.y), Number(n.width), Number(n.height)]
            this.publishWebRect(true, n)
            this.startHeal()
          })
        } else if (this.ttydOk === true) {
          // FR: 探测 ok 但窗口未上前——等待可见(shellVisibleTick 变化
          // 驱动翻转到 web 分支;冷启 aa start 不抢前台的窗口属此态)
          Column() {
            Text(this.paneId)
              .fontSize(fsc(this.fontScale, 20))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().inkSubtle)
              .opacity(0.55)
            Text(tr(this.locale, 'pane.waitwin'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .opacity(0.7)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .onAppear(() => {
            this.publishFromCache(false)
          })
        } else {
          // 降级路径(ttyd 不可达):TermPaneView 依赖 TermHost 单例——
          // 归属本 pane 才渲染;被其它 pane 占用时占位提示(web 为主)
          if (this.vm.termTick >= 0 && TermHost.bound() === this.paneId && TermHost.term() !== null) {
            TermPaneView({
              paneId: this.paneId,
              onDone: (): void => { this.onCmdDone(this.paneId) },
              wantFocus: this.vm.focusedPane === this.paneId
            })
          } else {
            Column() {
              Text(this.paneId)
                .fontSize(fsc(this.fontScale, DesignTokens.FONT_HEADING))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th().inkSubtle)
                .opacity(0.55)
              Text(tr(this.locale, 'pane.degradedbusy'))
                .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
                .fontColor(this.th().inkSubtle)
                .opacity(0.7)
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .onAppear(() => {
              this.publishFromCache(false)
            })
          }
        }
      } else {
        // GUI 丝滑棒:未绑会话 pane 的引导空态(原裸 paneId 水印)——
        // 快速动作直达:新建本地 / SSH 连接 / 命令面板
        Column({ space: DesignTokens.SPACE_SM }) {
          Text(this.paneId)
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().iconMuted)
            .opacity(0.7)
          Text(tr(this.locale, 'pane.empty.hint'))
            .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
            .fontColor(this.th().inkSubtle)
            .opacity(0.8)
          Row({ space: DesignTokens.SPACE_SM }) {
            Text(tr(this.locale, 'pane.empty.local'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().surface)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().brand)
              .textAlign(TextAlign.Center)
              .onClick(() => this.vm.bindLocalSessionFor(this.paneId))
            Text(tr(this.locale, 'pane.empty.ssh'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().ink)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => this.vm.openRightTab('conn'))
            Text('⌘ ' + tr(this.locale, 'pane.empty.palette'))
              .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
              .fontColor(this.th().inkSubtle)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(DesignTokens.RADIUS_XL)
              .backgroundColor(this.th().inputBg)
              .border({ width: 1, color: this.th().hairline })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.vm.paletteOpen = true
              })
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .onAppear(() => {
          this.publishFromCache(false)
        })
      }
    }
    .width('100%')
    .height('100%')
    // GUI-R4:web 分支激活时透明——真身在 AppShell 底层 WebPaneLayer,
    // 本容器仅画边框/标题。**根容器不绑任何点击/触摸处理器**:命中测试
    // 经未消费节点直达下层 web(绑定 onClick 会消费命中→web 失焦→终端
    // 打不了字,R4 解耦回归,用户实锤「输入不了字」)。焦点动作在标题行。
    .backgroundColor(this.webActive() ? Color.Transparent : this.th().panel)
    .borderRadius(DesignTokens.RADIUS_MD)
    .border({
      width: this.dragOver ? 2 : (this.vm.focusedPane === this.paneId ? 2 : 1),
      color: this.dragOver ? this.th().danger :
        (this.vm.focusedPane === this.paneId ? this.th().brand : this.th().hairline)
    })
    // M1e drop 目标:onDragEnter/Leave 高亮(danger 2px 边框近似"可放");
    // onDrop 读拖源 paneId 换位。不设 allowDrop = 默认接受全部数据类型
    // (API12 枚举 Array<UniformDataType> 无自定义成员,设了反而拒收)。
    // 同 pane 自身 drop 忽略(dragIdFrom 提取后 id 相等守卫);命中矩形即
    // 整个 PaneSurface(含标题行/终端区),拖到内容区任意点都可换位。
    .onDragEnter((_e: DragEvent) => {
      this.dragOver = true
    })
    .onDragLeave((_e: DragEvent) => {
      this.dragOver = false
    })
    .onDrop((e: DragEvent) => {
      this.dragOver = false
      // 拖源 paneId:同进程静态通道优先(权威),UDMF getData 回落。
      let srcId = PaneDragState.current
      if (srcId === '') {
        srcId = this.dragIdFrom(e)
      }
      hilog.info(M1E_DOMAIN, M1E_TAG, 'drop on=%{public}s src=%{public}s', this.paneId, srcId)
      if (srcId === '' || srcId === this.paneId) {
        return
      }
      this.vm.swapPanes(srcId, this.paneId)
      // 标记成功:拖源 onDragEnd 见 SUCCESSFUL 即跳过兜底(否则换位被
      // 兜底二次 swap 换回)。
      e.setResult(DragResult.DRAG_SUCCESSFUL)
    })
    .onAreaChange((_o: Area, n: Area) => {
      // 矩形注册(onDragEnd 兜底落点判定数据源):globalPosition 即窗口坐标,
      // 与 DragEvent.getWindowX/Y 同系(v)。宽高数字化兜底 Length 联合类型。
      const r = new PaneRectEntry()
      r.paneId = this.paneId
      r.x = Number(n.globalPosition.x)
      r.y = Number(n.globalPosition.y)
      r.w = Number(n.width)
      r.h = Number(n.height)
      PaneDropTargets.update(r)
      // GUI-R4:缓存 + web 层矩形同源上报(show=当前分支判定)
      this.rectCache = [r.x, r.y, r.w, r.h]
      // R4h:web 分支激活时矩形由分支内占位自身 onAreaChange 上报(内容区
      // 更准且分支切换必触发);根容器仅在非 web 分支时发布隐藏保活语义。
      if (!this.webActive()) {
        this.publishWebRect(false, n)
      }
    })
  }

  /** PB:命令完成通知两层落点(探测 done 回调):
   *  a. StatusBar——vm.setStatus('✓ 命令完成 · paneId')(现有通道);
   *  b. RightPanel 开着时 emit attention 事件到 AgentEventBus
   *     (type 'attention' kind 'finished' paneId——Agent 面板可见)。 */
  /** GUI 丝滑棒:带活会话的 pane 关闭二次确认(防误杀会话;
   *  未绑会话直接关)。 */
  private closeWithConfirm(): void {
    const slot = this.vm.sessionOf(this.paneId)
    if (slot === null) {
      this.vm.closePane(this.paneId)
      return
    }
    this.getUIContext().showAlertDialog({
      title: tr(this.locale, 'confirm.close.title'),
      message: tr(this.locale, 'confirm.close.msg') + ' [' + (slot.title !== '' ? slot.title : this.paneId) + ']',
      primaryButton: {
        value: tr(this.locale, 'confirm.close.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: tr(this.locale, 'confirm.close.ok'),
        fontColor: this.th().danger,
        action: (): void => {
          this.vm.closePane(this.paneId)
        }
      },
      cancel: (): void => {
      }
    })
  }

  private onCmdDone(paneId: string): void {
    this.vm.setStatus(tr(this.locale, 'status.done') + paneId)
    if (this.vm.rightPanelOpen) {
      AgentEventBus.instance().emit(buildFinishedAttention(paneId))
    }
  }

  /** 拖源可用:zoom 态禁拖(单叶无换位对象);多 pane 才有换位意义。 */
  private dragEnabled(): boolean {
    return this.vm.layout.zoomedPaneId === '' && this.vm.panes.length > 1
  }

  /** 从 DragEvent 提取拖源 paneId:UnifiedRecord(type,value) 消费侧——
   *  getType() 命中 DRAG_TYPE 后 getValue() 取 string paneId。 */
  private dragIdFrom(e: DragEvent): string {
    try {
      const ud = e.getData()
      const records = ud.getRecords()
      for (const rec of records) {
        if (rec.getType() === DRAG_TYPE) {
          const v = rec.getValue()
          if (typeof v === 'string') {
            return v
          }
        }
      }
    } catch (e) {
      // getData 无数据(BusinessError 190001/190002)→ 无拖源,静默。
    }
    return ''
  }
}
