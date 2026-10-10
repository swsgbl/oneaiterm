/**
 * tty7 终端 pane 渲染组件(任务 tty7-M3a;M4a 升级:捕获层接 InputController)。
 *
 * 机制照抄 TerminalPage(pages/TerminalPage.ets)的终端体与直输捕获层三修,
 * 去业务(无 Zmodem/SFTP/header/主题切换,终端恒暗底):
 *  - 渲染:Scroll + ForEach(winRows 窗口快照) + lineToSpans 行渲染,键含
 *    line.rev + tick(只有脏行换键,大输出不重绑干净行);
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

const TERM_FONT_SIZE: number = 13
const TERM_FONT_FAMILY: string = 'monospace'
const TERM_LINE_H: number = TERM_FONT_SIZE * 1.5
const TERM_PAD: number = 4
const TERM_POLL_MS: number = 100
/** ghost 后缀色(暗底次文近似,不用 ThemeGet 免 context)。 */
const GHOST_SUBTLE_FG: string = '#7d8590'

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
  /** M6a:外部注入终端模型(远程 SSH pane;缺省回落 TermHost 本地)。 */
  model: TermModel | null = null
  /** M6a:外部注入写口(远程;缺省 TermHost.write+drainOnce 本地语义)。 */
  writeFn: ((t: string) => void) | null = null
  /** M6a:外部注入尺寸口(远程;缺省 TermHost.resize)。 */
  resizeFn: ((c: number, r: number) => void) | null = null
  @State tick: number = 0
  @State winRows: TermLine[] = []
  @State winTop: number = 0
  @State capture: string = ''
  /** ghost 建议行前缀(=当前输入行;'' = 无建议;V1:组件内 @State 驱动渲染)。 */
  @State ghostBase: string = ''
  /** ghost 建议后缀(不含前缀)。 */
  @State ghostSuf: string = ''
  private scroller: Scroller = new Scroller()
  private renderTimer: number = -1
  private lastCapture: string = ''
  /** keyEvent 回车时间戳(onSubmit 去重基准;IME 正常时防双 \r)。 */
  private lastKeyEnterMs: number = 0
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

  aboutToAppear(): void {
    this.startRenderLoop()
    this.refreshWindow()
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

  /** 窗口快照:贴底模式(winTop=total-rows;回看历史留 M3b)。 */
  private refreshWindow(): void {
    const m = this.modelOrNull()
    if (m === null) {
      if (this.winRows.length > 0) {
        this.winRows = []
      }
      return
    }
    const total = m.lines.length
    if (m.altScreen !== this.altScrLast) { this.altScrLast = m.altScreen; this.altScr = m.altScreen } // M4b sample
    this.winTop = Math.max(0, total - m.rows)
    const end = Math.min(total, this.winTop + m.rows)
    this.winRows = m.lines.slice(this.winTop, end)
    try {
      this.scroller.scrollEdge(Edge.Bottom)
    } catch (e) {
      // 布局阶段不可调时静默(scrollEdge 不得杀链)
    }
  }

  // ===================== 输入(M4a:捕获层三修 + InputController) =====================

  /** 统一写:→ TermHost.write + 同步排空回显 + 立即快照(不等下一拍)。 */
  /**
   * M4b 焦点保持:捕获层 .id() + UIContext.getFocusController().requestFocus。
   * 本 SDK 索引已证 FocusController.requestFocus 存在(@ohos.arkui.UIContext.d.ts
   * :3264);Tab/↑↓ 后系统焦点转移副作用会把输入焦点带走 → 处理完主动拉回,
   * 不重点击即可连续输入/回车。requestFocus 不存在的旧场景静默降级(不杀输入)。
   */
  private keepCaptureFocus(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('tty7TermCapture')
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
    const a = this.ctrl.onInput(v)
    this.lastCapture = v
    this.applyAction(a)
  }

  /** 回车:onSubmit 独占 → 控制器 onEnter('\r' + 历史 push + 行复位清 ghost)。 */
  private onCaptureSubmit(): void {
    const a = this.ctrl.onEnter()
    // keyEvent 路径框架不清字段(原依赖 submit 的框架清空),自清受控值;
    // IME 正常时框架再清 onChange('') 幂等无操作。
    this.capture = ''
    this.lastCapture = ''
    this.applyAction(a)
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
    // 热修(M4a 验收实证):onSubmit 走 IME 通道,本机 VM IME 损坏时永不触发
    // → Enter 死路。keyEvent 直发 onCaptureSubmit,onSubmit 以时间戳去重
    // (400ms 内的 onSubmit 视为同一回车,防双 \r)。
    if (ev.keyCode === KC_ENTER) {
      this.lastKeyEnterMs = Date.now()
      this.onCaptureSubmit()
      return true
    }
    const s = this.mapKey(ev.keyCode, ev)
    if (s.length === 1 && s.charCodeAt(0) >= 0x20 && s.charCodeAt(0) < 0x7f) {
      this.capture = this.capture + s
      this.onCaptureChange(this.capture) // 程序赋值不保证触发 onChange;幂等兜底
      return true
    }
    if (ev.keyCode === KC_DEL) {
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
    if (rowIdx === cy) {
      return m.cursor.x
    }
    return -1
  }

  @Builder
  TermLineRow(line: TermLine, rowIdx: number) {
    Row() {
      ForEach(lineToSpans(line, this.cursorXFor(rowIdx), true), (run: SpanRun, idx: number) => {
        Text(run.text.replace(/ /g, '\u00a0'))
          .fontSize(TERM_FONT_SIZE)
          .fontFamily(TERM_FONT_FAMILY)
          .fontColor(run.fg)
          .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
          .backgroundColor(run.bg !== null ? run.bg : Color.Transparent)
      }, (run: SpanRun, idx: number) => rowIdx.toString() + ':' + idx.toString() + ':'
        + run.text.length + ':' + run.fg + ':' + (run.bg ?? '-') + ':' + this.tick.toString())
    }
    .height(TERM_LINE_H)
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Scroll(this.scroller) {
        Column() {
          ForEach(this.winRows, (line: TermLine, idx: number) => {
            this.TermLineRow(line, this.winTop + idx)
          }, (line: TermLine, idx: number) => (this.winTop + idx).toString() + ':' + line.rev.toString() + ':'
            + this.tick.toString())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(TERM_PAD)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)

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
        .id('tty7TermCapture') // M4b: FocusController.requestFocus target
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
          this.onCaptureChange(v)
        })
        .onSubmit(() => {
          if (Date.now() - this.lastKeyEnterMs < 400) {
            return // keyEvent 已处理同一回车(防双 \r)
          }
          this.onCaptureSubmit()
        })
        .onKeyEvent((ev: KeyEvent) => {
          return this.onTermKey(ev)
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TERM_DEFAULT_BG)
    .onAreaChange((_o: Area, n: Area) => {
      this.onBodyArea(Number(n.width), Number(n.height))
    })
  }
}
