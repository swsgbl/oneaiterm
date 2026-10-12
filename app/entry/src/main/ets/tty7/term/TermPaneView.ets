/**
 * tty7 终端 pane 渲染组件(任务 tty7-M3a;M4a 升级:捕获层接 InputController;M3c:scrollback+搜索)。
 * M3c:渲染源=lines 尾部 SCROLLBACK_MAX 行;贴底跟随 atBottom(上滚不打断);palette 搜索浮层。
 *
 * 机制照抄 TerminalPage(pages/TerminalPage.ets)的终端体与直输捕获层三修,
 * 去业务(无 Zmodem/SFTP/header/主题切换,终端恒暗底):
 *  - 渲染:Scroll + ForEach(lines 尾部 SCROLLBACK_MAX 行,M3c) + lineToSpans 行渲染,
 *    键含 line.rev(只有脏行换键,大输出不重绑干净行);
 *  - 刷新:自链式 setTimeout 100ms 一拍(tick++ + 快照 + scrollEdge 贴底),
 *    输出数据源是 TermHost.term()(TermHost 自持排水链,组件只读快照);
 *  - 直输捕获层三修(M4a 上移至 InputController,组件只执行动作指令):
 *    onChange 差分重对齐(前缀增长直写差量/缩短回写 \x7f/非前缀变化整行
 *    重写),回车 onSubmit 独占发 '\r',Tab 补全/↑↓ 历史回溯由控制器接管;
 *  - ghost 建议(M4a):底部一行,前缀 ink 色+后缀次文色,@State 驱动;
 *  - 尺寸:onAreaChange 算 cols/rows(字符宽 fontSize*0.6 近似,TerminalPage
 *    降级算法),开窗 600ms 只记录 + 后续两拍一致/300ms 防抖才应用(防初次
 *    布局虚假大 resize 撑爆网格)→ TermHost.resize;
 *  - 交互后同步 kick(write + drainOnce + 立即快照,不等下一拍)。
 */
import { TermModel, TermLine, lineToSpans, SpanRun, TERM_DEFAULT_BG, TERM_DEFAULT_FG } from '../../components/TermModel';
import { TermHost } from './TermHost';
import { InputController, InputAction } from './InputController';
import { DoneProbeState, probeSubmit, probeTick, PROBE_TICK_MS, trimBlankTail } from '../shell/ParityUi';
import { searchHits, nextHit, shouldStick, SCROLLBACK_MAX } from './TermScrollback';

const TERM_FONT_SIZE: number = 13
const TERM_FONT_FAMILY: string = 'monospace'
const TERM_LINE_H: number = TERM_FONT_SIZE * 1.5
const TERM_PAD: number = 4
const TERM_POLL_MS: number = 100
/** ghost 后缀色(暗底次文近似,不用 ThemeGet 免 context)。 */
const GHOST_SUBTLE_FG: string = '#7d8590'
/** M3c:搜索命中行高亮(brand #58a6ff 30% 透明近似)。 */
const HIT_CUR_BG: string = '#4d58a6ff'
/** M3c:搜索浮层输入底色(暗底近似)。 */
const SEARCH_BAR_BG: string = '#161b22'

// KeyCode(api/@ohos.multimodalInput.keyCode.d.ts,与 TerminalPage 同源)
const KC_DPAD_UP: number = 2012
const KC_DPAD_DOWN: number = 2013
const KC_DPAD_LEFT: number = 2014
const KC_DPAD_RIGHT: number = 2015
const KC_DPAD_CENTER: number = 2016
const KC_TAB: number = 2049
const KC_ENTER: number = 2054
const KC_DEL: number = 2055
const KC_ESCAPE: number = 2070

@Component
export struct TermPaneView {
  paneId: string = ''
  /** 输入热修(2026-10-12):仅焦点 pane 挂载时拉焦( PaneSurface 传入
   *  vm.focusedPane === paneId)。无条件拉焦会让非焦点 pane 的重挂载
   *  抢走焦点——焦点 pane 打字全丢。 */
  wantFocus: boolean = false
  /** M6a:外部注入终端模型(远程 SSH pane;缺省回落 TermHost 本地)。 */
  model: TermModel | null = null
  /** M6a:外部注入写口(远程;缺省 TermHost.write+drainOnce 本地语义)。 */
  writeFn: ((t: string) => void) | null = null
  /** M6a:外部注入尺寸口(远程;缺省 TermHost.resize)。 */
  resizeFn: ((c: number, r: number) => void) | null = null
  /** tty7-PB:命令完成回调(探测到提示符回归时 PaneSurface 注入:
   *  vm.setStatus ✓ 通知 + RightPanel 开时 emit attention;缺省 no-op)。 */
  onDone: () => void = () => {
  }
  /** tty7-PB:完成探测状态机(纯;onCaptureSubmit 重置,探测链消费)。 */
  private probe: DoneProbeState = new DoneProbeState()
  /** tty7-PB:完成探测链句柄(-1 未挂)。 */
  private probeTimer: number = -1
  @State tick: number = 0
  /** M3c:渲染源 = lines 尾部最多 SCROLLBACK_MAX 行(winRows 窗口快照语义废弃)。 */
  @State viewRows: TermLine[] = []
  @State viewTop: number = 0
  @State capture: string = ''
  /** M3c:贴底态(用户上滚即失贴;新输出仅贴底态跟随)。 */
  @State atBottom: boolean = true
  /** M3c:搜索浮层开/关键字/命中下标(viewRows 基,升序)/当前命中序号/渲染代。 */
  @State searching: boolean = false
  @State searchText: string = ''
  @State hitIdxs: number[] = []
  @State hitCur: number = 0
  @State searchEpoch: number = 0
  /** ghost 建议行前缀(=当前输入行;'' = 无建议;V1:组件内 @State 驱动渲染)。 */
  @State ghostBase: string = ''
  /** ghost 建议后缀(不含前缀)。 */
  @State ghostSuf: string = ''
  private scroller: Scroller = new Scroller()
  private renderTimer: number = -1
  private lastCapture: string = ''
  /** keyEvent 回车时间戳(onSubmit 去重基准;IME 正常时防双 \r)。 */
  /** 输入热修(2026-10-12):最近一次系统 inputText(onChange)到达时刻;
   *  仅 .onChange 回调处打点——onKeyEvent 兜底路径程序调 onCaptureChange
   *  不打点,否则兜底自我标记 IME 活跃,让路判定失效。 */
  private lastInputTextMs: number = 0
  private lastKeyEnterMs: number = 0
  /** 输入热修(2026-10-12):提交时捕获层显示值(显示不清的 SDK 行为下
   *  的残留对齐锚,见 onCaptureChange)。 */
  private pendingSubmitDisplay: string = ''
  /** M4a 输入控制器(捕获层与 TermHost.write 之间,差分/ghost/Tab/回溯)。 */
  private ctrl: InputController = new InputController()
  /** M4b: full-screen mode mirror (TermModel.altScreen) for arrow passthrough. */
  @State altScr: boolean = false
  /** M4b: last sampled altScreen (dedupe @State writes per tick). */
  private altScrLast: boolean = false
  private cols: number = 80
  private rows: number = 24
  private pendingCols: number = -1
  private pendingRows: number = -1
  private resizeTimer: number = -1
  private firstAreaMs: number = -1
  /** M3c:Scroll 视口高采样(-1 未测;距底判定基准)。 */
  private viewH: number = -1
  /** M3c:贴底过一次后 true(首帧 shouldStick 强制贴底用)。 */
  private everStuck: boolean = false
  /** M3c:可视首行缓存(refreshWindow/updateBottom 刷新;键与 cursorXFor 共用)。 */
  private curSegCache: number = 0
  /** M3c:模型代际(modelOrNull 身份变化 +1;ForEach 键防跨模型键撞)。 */
  private modelEpoch: number = 0
  private modelInit: boolean = false
  private modelLast: TermModel | null = null
  /** M3c:搜索信号轮询句柄(AppStorage 'ut.term.search',照抄 ut.git.focus)。 */
  private searchWatch: number = -1

  aboutToAppear(): void {
    this.startRenderLoop()
    this.refreshWindow()
    this.startSearchWatch() // M3c:palette 搜索信号
    // 输入热修(2026-10-12):仅焦点 pane 挂载时主动拉焦(真键盘/IME 输入
    // 必须 TextInput 持焦点才可达;无条件拉焦=非焦点 pane 抢焦)。
    // 延迟到布局完成后一拍——aboutToAppear 阶段 requestFocus 静默失效
    // (实勘:挂载即拉不打字仍全丢)。
    if (this.wantFocus) {
      setTimeout(() => {
        if (this.wantFocus) {
          this.keepCaptureFocus()
        }
      }, 50)
    }
  }

  aboutToDisappear(): void {
    if (this.renderTimer >= 0) {
      clearTimeout(this.renderTimer)
      this.renderTimer = -1
    }
    if (this.resizeTimer >= 0) {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = -1
    }
    if (this.searchWatch >= 0) {
      clearTimeout(this.searchWatch)
      this.searchWatch = -1
    }
    // tty7-PB:完成探测链销毁清(pane close/unmount 红线)
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer)
      this.probeTimer = -1
    }
  }

  private modelOrNull(): TermModel | null {
    return this.model !== null ? this.model : TermHost.term()
  }

  /** 渲染链:自链式 setTimeout,重挂放 finally(照抄 TerminalPage 链式纪律)。 */
  private startRenderLoop(): void {
    const tickFn = (): void => {
      try {
        this.tick += 1
        this.refreshWindow()
      } catch (e) {
        // 快照异常不杀链
      } finally {
        this.renderTimer = setTimeout(tickFn, TERM_POLL_MS)
      }
    }
    this.renderTimer = setTimeout(tickFn, TERM_POLL_MS)
  }

  /**
   * M3c:渲染快照 = lines 尾部最多 SCROLLBACK_MAX 行(scrollback 全量可滚);
   * 贴底只在 atBottom(用户未上滚)时跟随——上滚看历史时新输出不打断。
   */
  private refreshWindow(): void {
    const m = this.modelOrNull()
    if (m === null) {
      if (this.viewRows.length > 0) {
        this.viewRows = []
        this.viewTop = 0
      }
      return
    }
    if (!this.modelInit) {
      this.modelInit = true
      this.modelLast = m
    } else if (this.modelLast !== m) {
      this.modelLast = m
      this.modelEpoch += 1
    }
    if (m.altScreen !== this.altScrLast) { this.altScrLast = m.altScreen; this.altScr = m.altScreen } // M4b sample
    const total = m.lines.length
    const take = Math.min(total, SCROLLBACK_MAX)
    this.viewTop = total - take
    this.viewRows = m.lines.slice(this.viewTop, total)
    this.curSegCache = this.computeSeg()
    if (shouldStick(this.atBottom, !this.everStuck)) {
      this.everStuck = true
      try {
        this.scroller.scrollEdge(Edge.Bottom)
      } catch (e) {
        // 布局阶段不可调时静默(scrollEdge 不得杀链)
      }
    }
  }

  // ===================== M3c:贴底判定 + 搜索浮层(组件内 @State,不进 vm) =====================

  /** 可视首行近似(lines 绝对索引):yOffset/行高四舍五入,夹 [0,∞)。 */
  private computeSeg(): number {
    try {
      return Math.max(0, Math.round(this.scroller.currentOffset().yOffset / TERM_LINE_H))
    } catch (e) {
      return 0
    }
  }

  /** 距底判定:yOffset 距内容底 ≤20vp 视为贴底(≈40px@2x;本 SDK Scroll 无 onReachEnd)。 */
  private updateBottom(): void {
    if (this.viewH <= 0) {
      return // 视口未测:保持现值(初始贴底)
    }
    try {
      const off = this.scroller.currentOffset()
      this.curSegCache = Math.max(0, Math.round(off.yOffset / TERM_LINE_H))
      const max = Math.max(0, this.viewRows.length * TERM_LINE_H + 2 * TERM_PAD - this.viewH)
      const at = (max - off.yOffset) <= 20
      if (at !== this.atBottom) {
        this.atBottom = at
      }
    } catch (e) {
      // currentOffset 不可用:保持现值
    }
  }

  /** palette 信号轮询:ut.term.search 单调 +1 → 开浮层(500ms 自链,照抄 ut.git.focus)。 */
  private startSearchWatch(): void {
    let last = AppStorage.get<number>('ut.term.search') ?? 0
    const tickFn = (): void => {
      try {
        const cur = AppStorage.get<number>('ut.term.search') ?? 0
        if (cur !== last) {
          last = cur
          this.openSearch()
        }
      } finally {
        this.searchWatch = setTimeout(tickFn, 500)
      }
    }
    this.searchWatch = setTimeout(tickFn, 500)
  }

  /** 打开浮层:清搜索态 + 焦点落搜索框。 */
  private openSearch(): void {
    this.searching = true
    this.searchText = ''
    this.hitIdxs = []
    this.hitCur = 0
    this.recomputeHits(true)
    try {
      this.getUIContext().getFocusController().requestFocus('tty7TermSearch_' + this.paneId)
    } catch (e) {
      // 焦点控制器不可用:降级为手动点击搜索框
    }
  }

  /** 关闭浮层:清搜索态(高亮随 searchEpoch 失效)+ 焦点回捕获层。 */
  private closeSearch(): void {
    this.searching = false
    this.searchText = ''
    this.hitIdxs = []
    this.hitCur = 0
    this.searchEpoch += 1
    this.keepCaptureFocus()
  }

  /** 重算命中:textOf 快照(viewRows 同源)大小写不敏感;reset 归零当前序号。 */
  private recomputeHits(reset: boolean): void {
    const m = this.modelOrNull()
    const texts: string[] = []
    if (m !== null) {
      for (let i = 0; i < this.viewRows.length; i++) {
        texts.push(m.textOf(this.viewRows[i]))
      }
    }
    this.hitIdxs = searchHits(texts, this.searchText)
    if (reset) {
      this.hitCur = 0
    } else if (this.hitCur >= this.hitIdxs.length) {
      this.hitCur = Math.max(0, this.hitIdxs.length - 1)
    }
    this.searchEpoch += 1
  }

  /** 跳到命中序号 cur(0 基)并滚该行入视(行号×行高近似,vp≈px)。 */
  private jumpHit(cur: number): void {
    this.hitCur = cur
    if (cur < 0 || cur >= this.hitIdxs.length) {
      return
    }
    const y = this.hitIdxs[cur] * TERM_LINE_H + TERM_PAD
    try {
      this.scroller.scrollTo({ xOffset: 0, yOffset: y, animation: { duration: 120, curve: Curve.EaseOut } })
    } catch (e) {
      // 布局期不可调:静默(高亮仍切换)
    }
  }

  /** ↑↓:命中间环绕步进(先重算防新输出致命中漂移)。 */
  private hitStep(step: number): void {
    this.recomputeHits(false)
    const n = this.hitIdxs.length
    if (n === 0) {
      return
    }
    this.jumpHit(nextHit(this.hitCur, n, step))
  }

  /** 计数文本:'3/17';空关键字 '';无命中 '0/0'。 */
  private hitText(): string {
    if (this.searchText.trim().length === 0) {
      return ''
    }
    const n = this.hitIdxs.length
    return (n === 0 ? 0 : this.hitCur + 1).toString() + '/' + n.toString()
  }

  /** 当前行(viewRows 下标)是否为当前命中行(高亮分支)。 */
  private isHitRowCur(viewIdx: number): boolean {
    if (!this.searching || this.hitCur >= this.hitIdxs.length) {
      return false
    }
    return this.hitIdxs[this.hitCur] === viewIdx
  }

  /** 搜索框 keyEvent(IME 坏环境主通道,照抄捕获层热修):Esc 关/↑↓ 跳/回车搜/ASCII·DEL。 */
  private onSearchKey(ev: KeyEvent): boolean {
    if (ev.type !== KeyType.Down) {
      return false
    }
    if (ev.keyCode === KC_ESCAPE) {
      this.closeSearch()
      return true
    }
    if (ev.keyCode === KC_DPAD_UP) {
      this.hitStep(-1)
      return true
    }
    if (ev.keyCode === KC_DPAD_DOWN) {
      this.hitStep(1)
      return true
    }
    if (ev.keyCode === KC_ENTER || ev.keyCode === KC_DPAD_CENTER) {
      this.recomputeHits(true)
      if (this.hitIdxs.length > 0) {
        this.jumpHit(0)
      }
      return true
    }
    const t = ev.keyText
    if (t !== undefined && t !== null && t.length === 1) {
      const c = t.charCodeAt(0)
      if (c >= 0x20 && c < 0x7f) {
        this.searchText = this.searchText + t
        this.recomputeHits(false)
        return true
      }
    }
    if (ev.keyCode === KC_DEL) {
      if (this.searchText.length > 0) {
        this.searchText = this.searchText.substring(0, this.searchText.length - 1)
        this.recomputeHits(false)
      }
      return true
    }
    return false
  }

  // ===================== 输入(M4a:捕获层三修 + InputController) =====================

  /** 统一写:→ TermHost.write + 同步排空回显 + 立即快照(不等下一拍)。 */
  /**
   * M4b 焦点保持:捕获层 .id() + UIContext.getFocusController().requestFocus。
   * 本 SDK 索引已证 FocusController.requestFocus 存在(@ohos.arkui.UIContext.d.ts
   * :3264);Tab/↑↓ 后系统焦点转移副作用会把输入焦点带走 → 处理完主动拉回,
   * 不重点击即可连续输入/回车。requestFocus 不存在的旧场景静默降级(不杀输入)。
   */
  /** 捕获层焦点 id(paneId 唯一化:多 pane 同 id 会让 requestFocus 命中
   *  任意实例——后挂载的无会话 pane 抢走焦点,焦点 pane 打字全丢,
   *  2026-10-12「无法输入」根因)。 */
  private captureId(): string {
    return 'tty7TermCapture_' + this.paneId
  }

  private keepCaptureFocus(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(this.captureId())
    } catch (e) {
      // 焦点控制器不可用:降级为靠 focusOnTouch(用户点击恢复)
    }
  }

  private writeTerm(text: string): void {
    if (text.length === 0) {
      return
    }
    if (this.writeFn !== null) {
      this.writeFn(text) // M6a 远程:SSH 回调推送,免本地排水
    } else {
      TermHost.write(text)
      try {
        TermHost.drainOnce()
      } catch (e) {
        // 排空失败不阻塞输入
      }
    }
    this.tick += 1
    this.refreshWindow()
  }

  // ===================== tty7-PB:命令完成探测 =====================

  /** 提交后启动/重置探测(期间新提交重置计时——去抖);链已在跑则仅重置
   *  状态机(不叠链;轻——每拍只 capture 尾 3 行)。 */
  private startDoneProbe(): void {
    probeSubmit(this.probe, Date.now())
    if (this.probeTimer >= 0) {
      return
    }
    const tickFn = (): void => {
      this.probeTimer = -1
      try {
        const lines = this.tailTexts(3)
        const r = probeTick(this.probe, lines, Date.now())
        if (r === 'done') {
          try {
            this.onDone()
          } catch (e) {
            // 回调异常不杀链(通知失败静默)
          }
          return // done:链止(下次 submit 重启)
        }
        if (r === 'giveup') {
          return // 上限放弃:链止
        }
      } catch (e) {
        // 探测异常不杀链
      } finally {
        if (this.probeTimer < 0 && this.probe.active) {
          this.probeTimer = setTimeout(tickFn, PROBE_TICK_MS)
        }
      }
    }
    this.probeTimer = setTimeout(tickFn, PROBE_TICK_MS)
  }

  /** pane 尾部 N 行纯文本(modelOrNull 源;无模型空数组)。
   *  tty7-PB 热修:先剪尾空行——短输出命令后提示符在中部、垫底 blank
   *  会让 isPromptBack 恒 false → done 通知永不触发。 */
  private tailTexts(n: number): string[] {
    const m = this.modelOrNull()
    if (m === null) {
      return []
    }
    const all: string[] = []
    for (const ln of m.lines) {
      all.push(m.textOf(ln))
    }
    const src = trimBlankTail(all)
    const take = Math.min(n, src.length)
    const out: string[] = []
    for (let i = src.length - take; i < src.length; i++) {
      out.push(src[i])
    }
    return out
  }

  /** 统一执行控制器动作:writeText → setField(fieldText+基线) → ghost。 */
  private applyAction(a: InputAction): void {
    if (a.writeText.length > 0) {
      this.writeTerm(a.writeText)
    }
    if (a.setField) {
      this.capture = a.fieldText
      this.lastCapture = a.fieldText // 差分基线与控制器 sent 重新对齐
    }
    this.ghostBase = a.setField ? '' : this.ctrl.line()
    this.ghostSuf = a.ghost
  }

  /**
   * onChange → 控制器差分(M3a 三修语义上移至 InputController.onInput):
   * 前缀增长直写差量/缩短回写 \x7f/非前缀变化整行重写;ghost 同步重算。
   */
  private onCaptureChange(v: string): void {
    if (v.indexOf('\n') >= 0) { this.applyAction(this.ctrl.onPasteBlock(v)); return } // M4b paste
    // 输入热修(2026-10-12):显示值回写——IME 活路径下 inputText 只改
    // TextInput 显示,组件字段不跟随(V1 构造参数),不回写则提交时
    // pendingSubmitDisplay 恒空,残留对齐失效(datepwd 实勘)。
    this.capture = v
    // 输入热修(2026-10-12):提交后显示残留对齐——本 SDK 的 TextInput 在
    // onSubmit 后不自动清显示(V1 下 text 参数不跟随 @State),显示残留
    // 提交词;后续 inputText 以「残留+新增后缀」形态到达,直接整行差分
    // 会把残留一起重写给 PTY(date 后打 pwd → datepwd 实勘)。遇此前缀
    // 形态只把新增后缀喂差分;DEL/整改形态则清登记走原差分兜底。
    if (this.pendingSubmitDisplay.length > 0) {
      if (v === this.pendingSubmitDisplay) {
        this.lastCapture = v
        return // 框架回放原值:无新增,无操作
      }
      if (v.startsWith(this.pendingSubmitDisplay)) {
        const a = this.ctrl.onInput(v.substring(this.pendingSubmitDisplay.length))
        this.lastCapture = v
        this.pendingSubmitDisplay = ''
        this.applyAction(a)
        return
      }
      this.pendingSubmitDisplay = ''
    }
    const a = this.ctrl.onInput(v)
    this.lastCapture = v
    this.applyAction(a)
  }

  /** 输入热修(2026-10-12):IME 活性探测。IME 正常环境(inputText 通道通)
   *  字母/DEL/ENTER 由 onChange+onSubmit 单路径送达;本机 VM IME 损坏环境
   *  inputText 恒不达,onKeyEvent 兜底直写。两环境共存的双写/吞字根因:
   *  IME 活时兜底成第二写源(echo→echoecho 实勘),IME 坏时 inputText 半
   *  接管吞字。判据:onChange(仅系统 inputText 到达处打点)2 秒内活跃
   *  → onKeyEvent 字符/DEL/ENTER 让路。
   */
  private imeAlive(): boolean {
    return Date.now() - this.lastInputTextMs < 2000
  }

  /** 回车:onSubmit 独占 → 控制器 onEnter('\r' + 历史 push + 行复位清 ghost)。 */
  private onCaptureSubmit(): void {
    // 双路径去重:keyEvent 直发与 onSubmit 系统派发在同一 ENTER 上都会到达
    // (LPDBG 实勘 4ms 内双 \r——TextInput 持焦点时两条都活)。旧界面走
    // 「keyEvent 让位」单路径;本机 VM IME 损坏时 onSubmit 不触发,keyEvent
    // 路径必须保留 → 入口时间戳幂等统一拦截(400ms 与旧三修口径一致)。
    if (Date.now() - this.lastKeyEnterMs < 400) {
      return
    }
    this.lastKeyEnterMs = Date.now()
    const a = this.ctrl.onEnter()
    // keyEvent 路径框架不清字段(原依赖 submit 的框架清空),自清受控值;
    // IME 正常时框架再清 onChange('') 幂等无操作。
    // 输入热修(2026-10-12):登记提交时显示值——显示不清的 SDK 行为下,
    // 后续 onChange 以「残留+后缀」形态到达时只差分后缀(见 onCaptureChange)。
    this.pendingSubmitDisplay = this.capture
    this.capture = ''
    this.lastCapture = this.pendingSubmitDisplay
    this.applyAction(a)
    this.startDoneProbe() // tty7-PB:提交后启动完成探测(重置计时)
    // 输入热修(2026-10-12):提交后拉回焦点——onSubmit/submit 链会把系统
    // 焦点带走(实勘:date 后连续 pwd 全丢,重点击才恢复)。同步调用在
    // onSubmit 上下文静默失效(实勘),延迟到事件处理完成后一拍。
    setTimeout(() => {
      this.keepCaptureFocus()
    }, 50)
  }

  /** 硬件键映射(方向/回车/删除/Esc + ASCII 可打印;Tab 与 ↑↓ 由控制器接管)。 */
  private mapKey(code: number, ev: KeyEvent): string {
    switch (code) {
      case KC_ENTER:
      case KC_DPAD_CENTER:
        return '\r'
      case KC_DEL:
        return '\x7f'
      case KC_ESCAPE:
        return '\x1b'
      case KC_DPAD_UP:
        return '\x1b[A'
      case KC_DPAD_DOWN:
        return '\x1b[B'
      case KC_DPAD_RIGHT:
        return '\x1b[C'
      case KC_DPAD_LEFT:
        return '\x1b[D'
      default:
        break
    }
    const t = ev.keyText
    if (t !== undefined && t !== null && t.length === 1) {
      const c = t.charCodeAt(0)
      if (c >= 0x20 && c < 0x7f) {
        return t
      }
    }
    return ''
  }

  private onTermKey(ev: KeyEvent): boolean {
    if (ev.type !== KeyType.Down) {
      return false
    }
    // M4a:Tab 补全;↑↓ 历史回溯(输入行态;箭头键不再透传 sh)。
    // 已知限制:Tab/↑↓ 的系统焦点转移副作用会带走捕获层焦点(实测后续
    // Enter 落到别处)——M4b 需产品级焦点保持;驱动验收每步前重点击规避。
    if (ev.keyCode === KC_TAB) {
      this.applyAction(this.ctrl.onTab())
      this.keepCaptureFocus() // M4b: pull focus back after Tab completion
      return true
    }
    if (ev.keyCode === KC_DPAD_UP) {
      if (this.altScr) { this.writeTerm('\x1b[A'); return true } // M4b: alt-screen raw passthrough
      this.applyAction(this.ctrl.onArrow(true))
      this.keepCaptureFocus() // M4b: pull focus back after history recall
      return true
    }
    if (ev.keyCode === KC_DPAD_DOWN) {
      if (this.altScr) { this.writeTerm('\x1b[B'); return true } // M4b: alt-screen raw passthrough
      this.applyAction(this.ctrl.onArrow(false))
      this.keepCaptureFocus() // M4b: pull focus back after history recall
      return true
    }
    // 热修(M4a 验收实证):ASCII 可打印/DEL 必须走受控字段+onChange→Controller
    // 统一入口(直写 writeTerm 绕过差分/ghost/Tab 基线,IME 路径在本机 VM
    // 已坏,inputText 无法兜底);转义序列与 \r 保持直写。
    // 输入热修(2026-10-12):IME 活性让路——IME 正常时这三类键由 inputText/
    // onSubmit 单路径送达(onKeyEvent 兜底会双写:echo→echoecho 实勘),
    // 恒不达(坏 IME)时兜底独活。onSubmit 双路径到达由 onCaptureSubmit
    // 入口 400ms 幂等统一去重(防双 \r)。
    if (ev.keyCode === KC_ENTER) {
      if (this.imeAlive()) {
        return false // IME 活:onSubmit 独走(入口幂等兜底防漏)
      }
      this.onCaptureSubmit()
      return true
    }
    const s = this.mapKey(ev.keyCode, ev)
    if (s.length === 1 && s.charCodeAt(0) >= 0x20 && s.charCodeAt(0) < 0x7f) {
      if (this.imeAlive()) {
        return false // IME 活:inputText/onChange 独走
      }
      this.capture = this.capture + s
      this.onCaptureChange(this.capture) // 程序赋值不保证触发 onChange;幂等兜底
      return true
    }
    if (ev.keyCode === KC_DEL) {
      if (this.imeAlive()) {
        return false // IME 活:inputText 删字符→onChange 差分回写 \x7f
      }
      if (this.capture.length > 0) {
        this.capture = this.capture.substring(0, this.capture.length - 1)
        this.onCaptureChange(this.capture)
      }
      return true
    }
    if (s.length > 0) {
      this.writeTerm(s)
      return true
    }
    return false
  }

  // ===================== 尺寸(onAreaChange,照抄 TerminalPage 防抖) =====================

  private charWidth(): number {
    // 等宽 ASCII 半宽近似(TerminalPage 降级算法;MeasureText 在 pane 级
    // 密度换算易飘,固定近似够用——cols 只影响 PTY winsize 精度)
    return TERM_FONT_SIZE * 0.6
  }

  private calcCols(w: number): number {
    return Math.max(20, Math.floor((w - 2 * TERM_PAD) / this.charWidth()))
  }

  private calcRows(h: number): number {
    return Math.max(4, Math.floor((h - 2 * TERM_PAD) / TERM_LINE_H))
  }

  private onBodyArea(w: number, h: number): void {
    const now = Date.now()
    if (this.firstAreaMs < 0) {
      this.firstAreaMs = now
      setTimeout(() => {
        if (this.pendingCols > 0 && this.pendingRows > 0) {
          this.applyResize(this.pendingCols, this.pendingRows)
        }
        this.pendingCols = -1
        this.pendingRows = -1
      }, 700)
    }
    const cols = this.calcCols(w)
    const rows = this.calcRows(h)
    if ((now - this.firstAreaMs) < 600) {
      // 初次布局序列不可信(先报虚假大值):开窗内只记录,窗末统一应用
      this.pendingCols = cols
      this.pendingRows = rows
      return
    }
    if (cols === this.cols && rows === this.rows) {
      this.pendingCols = -1
      this.pendingRows = -1
      if (this.resizeTimer >= 0) {
        clearTimeout(this.resizeTimer)
        this.resizeTimer = -1
      }
      return
    }
    if (cols === this.pendingCols && rows === this.pendingRows) {
      this.applyResize(cols, rows)
      return
    }
    this.pendingCols = cols
    this.pendingRows = rows
    if (this.resizeTimer >= 0) {
      clearTimeout(this.resizeTimer)
    }
    this.resizeTimer = setTimeout(() => {
      this.resizeTimer = -1
      if (this.pendingCols > 0 && this.pendingRows > 0) {
        this.applyResize(this.pendingCols, this.pendingRows)
        this.pendingCols = -1
        this.pendingRows = -1
      }
    }, 300)
  }

  private applyResize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) {
      return
    }
    this.cols = cols
    this.rows = rows
    if (this.resizeFn !== null) {
      this.resizeFn(cols, rows) // M6a 远程
    } else {
      TermHost.resize(cols, rows)
    }
    this.refreshWindow()
  }

  // ===================== 渲染 =====================

  private cursorXFor(rowIdx: number): number {
    const m = this.modelOrNull()
    if (m === null || !m.cursor.visible) {
      return -1
    }
    const cy = m.lines.length - m.rows + m.cursor.y
    if (rowIdx === cy && rowIdx >= this.viewTop + this.curSegCache
      && rowIdx < this.viewTop + this.curSegCache + m.rows) { // M3c:仅可视段亮块(上滚不残留)
      return m.cursor.x
    }
    return -1
  }

  @Builder
  TermLineRow(line: TermLine, rowIdx: number, viewIdx: number) {
    Row() {
      ForEach(lineToSpans(line, this.cursorXFor(rowIdx), true), (run: SpanRun, idx: number) => {
        Text(run.text.replace(/ /g, '\u00a0'))
          .fontSize(TERM_FONT_SIZE)
          .fontFamily(TERM_FONT_FAMILY)
          .fontColor(run.fg)
          .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
          .backgroundColor(run.bg !== null ? run.bg : Color.Transparent)
      }, (run: SpanRun, idx: number) => rowIdx.toString() + ':' + idx.toString() + ':'
        + run.text.length + ':' + run.fg + ':' + (run.bg ?? '-') + ':' + this.cursorXFor(rowIdx))
    }
    .height(TERM_LINE_H)
    .width('100%')
    .backgroundColor(this.isHitRowCur(viewIdx) ? HIT_CUR_BG : Color.Transparent) // M3c 命中高亮
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Scroll(this.scroller) {
        Column() {
          ForEach(this.viewRows, (line: TermLine, idx: number) => {
            this.TermLineRow(line, this.viewTop + idx, idx)
          }, (line: TermLine, idx: number) => (this.viewTop + idx).toString() + ':' + line.rev.toString() + ':'
            + this.curSegCache.toString() + ':e' + this.modelEpoch.toString() + ':s' + this.searchEpoch.toString()
            + (this.isHitRowCur(idx) ? ':h' + this.hitCur.toString() : ''))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(TERM_PAD)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
      .onDidScroll((_x: number, _y: number, _st: ScrollState) => {
        this.updateBottom() // M3c:贴底态跟踪(上滚即失贴)
      })
      .onAreaChange((_o: Area, n: Area) => {
        this.viewH = Number(n.height) // M3c:视口高采样
        this.updateBottom()
      })

      // ghost 建议行(M4a):前缀 ink 色 + 后缀 inkSubtle 色,终端区底部一行,
      // 与捕获层同层不拦截(Text 天然不拦截,不用 hitTest 设置)
      if (this.ghostSuf.length > 0) {
        Row() {
          Text(this.ghostBase)
            .fontSize(TERM_FONT_SIZE)
            .fontFamily(TERM_FONT_FAMILY)
            .fontColor(TERM_DEFAULT_FG)
          Text(this.ghostSuf)
            .fontSize(TERM_FONT_SIZE)
            .fontFamily(TERM_FONT_FAMILY)
            .fontColor(GHOST_SUBTLE_FG)
        }
        .height(TERM_LINE_H)
        .alignItems(VerticalAlign.Bottom)
        .padding({ left: TERM_PAD * 2, bottom: TERM_PAD * 2 })
      }

      // 全幅透明捕获层:承接一切输入;hitTestBehavior Default 保住下方滚动
      TextInput({ text: this.capture, placeholder: '' })
        .id(this.captureId()) // M4b: requestFocus 目标(paneId 唯一化,防跨 pane 抢焦)
        .width('100%')
        .height('100%')
        .fontSize(1)
        .padding(0)
        .opacity(0.01)
        .backgroundColor(Color.Transparent)
        .caretColor(Color.Transparent)
        .placeholderColor(Color.Transparent)
        .focusable(true)
        .focusOnTouch(true)
        .hitTestBehavior(HitTestMode.Default)
        .onChange((v: string) => {
          this.lastInputTextMs = Date.now() // IME 活性打点(仅系统 inputText 到达处)
          this.onCaptureChange(v)
        })
        .onSubmit(() => {
          this.onCaptureSubmit() // 双路径到达由 onCaptureSubmit 入口幂等去重
        })
        .onKeyEvent((ev: KeyEvent) => {
          return this.onTermKey(ev)
        })

      // M3c 搜索浮层:顶部一条(输入+计数+↑↓+×);Stack 后声明=顶层可点
      if (this.searching) {
        Row({ space: 6 }) {
          TextInput({ text: this.searchText, placeholder: '搜索...' })
            .id('tty7TermSearch_' + this.paneId) // requestFocus 目标(paneId 唯一化)
            .focusable(true)
            .focusOnTouch(true)
            .layoutWeight(1)
            .height(30)
            .fontSize(14)
            .fontColor(TERM_DEFAULT_FG)
            .placeholderColor(GHOST_SUBTLE_FG)
            .caretColor('#58a6ff')
            .backgroundColor(SEARCH_BAR_BG)
            .borderRadius(4)
            .padding({ left: 8, right: 8 })
            .onChange((v: string) => {
              this.searchText = v
              this.recomputeHits(false)
            })
            .onSubmit(() => {
              this.recomputeHits(true)
              if (this.hitIdxs.length > 0) {
                this.jumpHit(0)
              }
            })
            .onKeyEvent((ev: KeyEvent) => {
              return this.onSearchKey(ev)
            })
          Text(this.hitText())
            .fontSize(12)
            .fontColor(TERM_DEFAULT_FG)
            .maxLines(1)
          Text('↑')
            .fontSize(14)
            .fontColor(TERM_DEFAULT_FG)
            .width(24)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => this.hitStep(-1))
          Text('↓')
            .fontSize(14)
            .fontColor(TERM_DEFAULT_FG)
            .width(24)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => this.hitStep(1))
          Text('×')
            .fontSize(16)
            .fontColor(TERM_DEFAULT_FG)
            .width(24)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => this.closeSearch())
        }
        .position({ x: 0, y: 0 }) // M3c 顶部绝对定位(Stack alignContent 不管辖 position)
        .width('100%')
        .padding({ left: TERM_PAD, right: TERM_PAD, top: TERM_PAD })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TERM_DEFAULT_BG)
    .onAreaChange((_o: Area, n: Area) => {
      this.onBodyArea(Number(n.width), Number(n.height))
    })
  }
}
