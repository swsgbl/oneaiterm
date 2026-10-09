/**
 * tty7 终端 pane 渲染组件(任务 tty7-M3a)。
 *
 * 机制照抄 TerminalPage(pages/TerminalPage.ets)的终端体与直输捕获层三修,
 * 去业务(无 Zmodem/SFTP/header/主题切换,终端恒暗底):
 *  - 渲染:Scroll + ForEach(winRows 窗口快照) + lineToSpans 行渲染,键含
 *    line.rev + tick(只有脏行换键,大输出不重绑干净行);
 *  - 刷新:自链式 setTimeout 100ms 一拍(tick++ + 快照 + scrollEdge 贴底),
 *    输出数据源是 TermHost.term()(TermHost 自持排水链,组件只读快照);
 *  - 直输捕获层三修(TerminalPage 2026-10-07 实勘):全幅透明 TextInput
 *    承接硬件键/软键盘/IME,onChange 差分重对齐(前缀增长直写差量/缩短
 *    回写 \x7f/非前缀变化整行重发),回车 onSubmit 独占发 '\r',方向键走
 *    mapKey(上/下/C/D/B);
 *  - 尺寸:onAreaChange 算 cols/rows(字符宽 fontSize*0.6 近似,TerminalPage
 *    降级算法),开窗 600ms 只记录 + 后续两拍一致/300ms 防抖才应用(防初次
 *    布局虚假大 resize 撑爆网格)→ TermHost.resize;
 *  - 交互后同步 kick(write + drainOnce + 立即快照,不等下一拍)。
 */
import { TermModel, TermLine, lineToSpans, SpanRun, TERM_DEFAULT_BG } from '../../components/TermModel';
import { TermHost } from './TermHost';

const TERM_FONT_SIZE: number = 13
const TERM_FONT_FAMILY: string = 'monospace'
const TERM_LINE_H: number = TERM_FONT_SIZE * 1.5
const TERM_PAD: number = 4
const TERM_POLL_MS: number = 100

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
  @State tick: number = 0
  @State winRows: TermLine[] = []
  @State winTop: number = 0
  @State capture: string = ''
  private scroller: Scroller = new Scroller()
  private renderTimer: number = -1
  private lastCapture: string = ''
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
    return TermHost.term()
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
    this.winTop = Math.max(0, total - m.rows)
    const end = Math.min(total, this.winTop + m.rows)
    this.winRows = m.lines.slice(this.winTop, end)
    try {
      this.scroller.scrollEdge(Edge.Bottom)
    } catch (e) {
      // 布局阶段不可调时静默(scrollEdge 不得杀链)
    }
  }

  // ===================== 输入(捕获层三修,照抄 TerminalPage) =====================

  /** 统一写:→ TermHost.write + 同步排空回显 + 立即快照(不等下一拍)。 */
  private writeTerm(text: string): void {
    if (text.length === 0) {
      return
    }
    TermHost.write(text)
    try {
      TermHost.drainOnce()
    } catch (e) {
      // 排空失败不阻塞输入
    }
    this.tick += 1
    this.refreshWindow()
  }

  /**
   * onChange 差分重对齐(TerminalPage 实勘三修):
   * 前缀增长 → 直写差量;缩短 → 回写 \x7f;非前缀变化(submit 后框架静默
   * 清空字段)→ 整段重发重新起步。绝不依赖"程序化清空触发 onChange"。
   */
  private onCaptureChange(v: string): void {
    const last = this.lastCapture
    if (v !== last) {
      if (v.length > last.length && v.startsWith(last)) {
        this.writeTerm(v.substring(last.length))
      } else if (v.length < last.length && last.startsWith(v)) {
        const n = last.length - v.length
        let bs = ''
        for (let i = 0; i < n; i++) {
          bs += '\x7f'
        }
        this.writeTerm(bs)
      } else {
        if (v.length > 0) {
          this.writeTerm(v)
        }
      }
    }
    this.lastCapture = v
  }

  /** 回车由 onSubmit 独占('\r',PTY 行规范;onKeyEvent 对 KC_ENTER 放行)。 */
  private onCaptureSubmit(): void {
    this.writeTerm('\r')
  }

  /** 硬件键映射(方向/回车/删除/Tab/Esc + ASCII 可打印)。 */
  private mapKey(code: number, ev: KeyEvent): string {
    switch (code) {
      case KC_ENTER:
      case KC_DPAD_CENTER:
        return '\r'
      case KC_DEL:
        return '\x7f'
      case KC_TAB:
        return '\t'
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
    const s = this.mapKey(ev.keyCode, ev)
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
    TermHost.resize(cols, rows)
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

      // 全幅透明捕获层:承接一切输入;hitTestBehavior Default 保住下方滚动
      TextInput({ text: this.capture, placeholder: '' })
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
          this.onCaptureSubmit()
        })
        .onKeyEvent((ev: KeyEvent) => {
          // 回车让位 onSubmit(双 \r 坑);其余特殊键走 mapKey
          if (ev.keyCode === KC_ENTER) {
            return false
          }
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
