/**
 * upstream M2 relay-4 - Terminal page (rendered terminal + key passthrough).
 *
 * On top of relay-3b's line stream:
 *  - TermModel ANSI emulator: colors (SGR/256), cursor control, line rewrites
 *    (prompt editing via BS/EL), implicit scrollback up to 5000 lines;
 *  - rendered lines are Row{ForEach(run->Text)} spans with per-run fg/bg
 *    (incl. cursor block at the logical cursor cell), monospace concatenated;
 *  - hardware keyboard passthrough: the terminal area is focusable, focused
 *    on touch/connect; printable keys + arrows/Tab/Enter/Backspace/Ctrl+X
 *    go straight to the ssh stdin (Enter=\r, arrows=\x1b[A.., Ctrl+\x01..\x1a);
 *    the bottom input line stays as IME fallback (Chinese input etc);
 *  - status bar shows lines/bytes + last command latency for benchmarks;
 *  - only the visible window (rows+overscan) of the scrollback is snapshotted
 *    into @State winRows each poll, keeps 20000-line floods smooth.
 */
import { MeasureText, MeasureOptions, display } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ConnRec, ConnectionStore, getSharedStore } from '../store/ConnStore';
import { SessionService, TermStats, TermView } from '../service/SessionService';
import { TelnetService, TelKind } from '../service/TelnetService';
import { LocalTerminalService } from '../service/LocalTerminalService';
import { TermModel, TermLine, lineToSpans, SpanRun, TERM_DEFAULT_FG, TERM_DEFAULT_BG } from '../components/TermModel';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { TimingConstants } from '../common/TimingConstants';

const TERM_FONT_SIZE: number = 14;
const TERM_FONT_FAMILY: string = 'monospace';
const BODY_PAD: number = 8;
const WIN_OVERSCAN: number = TimingConstants.TERMINAL_OVERSCAN;
const POLL_MS: number = TimingConstants.TERMINAL_POLL_MS;

// KeyCode values (api/@ohos.multimodalInput.keyCode.d.ts, API24)
const KC_DPAD_UP: number = 2012;
const KC_DPAD_DOWN: number = 2013;
const KC_DPAD_LEFT: number = 2014;
const KC_DPAD_RIGHT: number = 2015;
const KC_DPAD_CENTER: number = 2016;
const KC_A: number = 2017;
const KC_Z: number = 2042;
const KC_TAB: number = 2049;
const KC_ENTER: number = 2054;
const KC_DEL: number = 2055;
const KC_GRAVE: number = 2056;
const KC_ESCAPE: number = 2070;
const KC_MOVE_HOME: number = 2081;
const KC_MOVE_END: number = 2082;
const KC_PAGE_UP: number = 2068;
const KC_PAGE_DOWN: number = 2069;
const KC_BACKSLASH: number = 2061;

interface Dims {
  cols: number;
  rows: number;
  charWidth: number;
}

@Component
export struct TerminalPage {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @StorageProp('ut.term.status') storageStatus: string = 'idle';
  @StorageProp('ut.term.reason') storageReason: string = '';
  @Prop connIdIn: string = '';
  @State title: string = '';
  @State input: string = '';
  @State cols: number = 80;
  @State rows: number = 24;
  @State measureNote: string = '';
  @State statText: string = '';
  @State passthrough: boolean = true;
  @State focused: boolean = false;
  @State winTop: number = 0; // first bound scrollback row index
  @State winSize: number = 60; // number of bound rows
  @State winRows: TermLine[] = []; // bound window snapshot (state!)
  @State tick: number = 0; // bump to force span re-render (cursor moves)
  private view: TermBufferView = new TermBufferView();
  private model: TermModel = new TermModel(80, 24);
  private scroller: Scroller = new Scroller();
  private pollTimer: number = -1;
  private resizeTimer: number = -1;
  private lastTickMs: number = 0; // r6e: timer 链健康监测
  private watchdogTimer: number = -1; // r6e: 独立看门狗
  private opened: boolean = false;
  private connId: string = '';
  private followTail: boolean = true;
  private isLocal: boolean = false; // M5 relay6: 本地终端标志(stats 显示用)
  private hb: number = 0; // r6 心跳计数

  aboutToAppear(): void {
    this.view.attach(this.model);
    SessionService.attachView(this.view);
    const p = (this.connIdIn !== '') ? { 'connId': this.connIdIn } as Record<string, string> : router.getParams() as Record<string, string>;
    if (p !== undefined && p !== null) {
      const cid = p['connId'];
      if (typeof cid === 'string') {
        this.connId = cid;
      }
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    // M3: use the SHARED store (has the unlocked CredentialManager attached,
    // so keyContent/password are decrypted in memory). Do NOT re-load() here:
    // the disk copy holds enc:v1 ciphertext which would overwrite the
    // decrypted in-memory values.
    const store = getSharedStore();
    if (store === null) {
      AppStorage.setOrCreate('ut.term.status', 'error');
      AppStorage.setOrCreate('ut.term.reason', 'store not ready (open the connection list first)');
      return;
    }
    let conn: ConnRec | null = null;
    for (let i = 0; i < store.connections.length; i++) {
      if (store.connections[i].id === this.connId) {
        conn = store.connections[i];
      }
    }
    if (conn === null) {
      this.title = 'unknown';
      AppStorage.setOrCreate('ut.term.status', 'error');
      AppStorage.setOrCreate('ut.term.reason', 'conn not found: ' + this.connId);
      return;
    }
    this.title = conn.type === 'telnet' ? 'telnet ' + conn.host + ':' + conn.port.toString()
      : (conn.type === 'raw' ? 'raw ' + conn.host + ':' + conn.port.toString()
        : conn.user + '@' + conn.host + ':' + conn.port.toString());
    // Telnet / Raw TCP:走 TelnetService(@ohos.net.socket),不经 libssh
    if (conn.type === 'telnet' || conn.type === 'raw') {
      const c2: ConnRec = conn;
      const kind: TelKind = conn.type === 'telnet' ? 'telnet' : 'raw';
      this.title = conn.name !== '' ? conn.name : this.title;
      TelnetService.connect(kind, conn.host, conn.port).then(() => {
        this.opened = true;
        AppStorage.setOrCreate('ut.term.status', 'connected');
        this.startPoll(); // M5 relay4 fix(bug3): 无 poll 则渲染永不刷新
        if (c2.postLoginScript !== null && c2.postLoginScript.length > 0) {
          setTimeout(() => {
            TelnetService.write(c2.postLoginScript + '\n');
          }, TimingConstants.TELNET_POST_LOGIN_DELAY);
        }
      }).catch((e: Object) => {
        AppStorage.setOrCreate('ut.term.status', 'error');
        AppStorage.setOrCreate('ut.term.reason', e.toString().substring(0, 300));
      });
      return;
    }
    // 本地终端:liblocalpty.so(forkpty + /bin/sh)
    if (conn.type === 'local') {
      this.title = conn.name !== '' ? conn.name : '本地终端';
      this.isLocal = true;
      const m0 = this.measureDims();
      this.cols = m0.cols;
      this.rows = m0.rows;
      this.model.resize(this.cols, this.rows);
      this.winSize = this.rows + 2 * WIN_OVERSCAN;
      this.measureNote = 'measured ' + m0.cols + 'x' + m0.rows;
      const ok = LocalTerminalService.open(m0.cols, m0.rows);
      if (ok) {
        this.opened = true;
        AppStorage.setOrCreate('ut.term.status', 'connected');
        this.startPoll(); // M5 relay4 fix(bug3): 无 poll 则渲染永不刷新
      } else {
        AppStorage.setOrCreate('ut.term.status', 'error');
        AppStorage.setOrCreate('ut.term.reason', 'localpty 加载失败(检查 libs/x86_64/liblocalpty.so)');
      }
      return;
    }
    const m = this.measureDims();
    this.cols = m.cols;
    this.rows = m.rows;
    this.model.resize(this.cols, this.rows);
    this.winSize = this.rows + 2 * WIN_OVERSCAN;
    this.measureNote = 'measured ' + m.cols + 'x' + m.rows;
    const connId = conn.id;
    const postScript = conn.postLoginScript;
    SessionService.connect(conn, this.cols, this.rows).then((id: number) => {
      this.opened = true;
      // M3-3a: stamp lastUsedAt for the recents section (persist best-effort)
      try {
        const st = getSharedStore();
        if (st !== null) {
          st.markUsed(connId);
        }
      } catch (e) {
        hilog.warn(0x0110, 'oat.term', 'markUsed failed: %{public}s', e instanceof Error ? e.message : String(e));
      }
      // M3-3a: post-login script - send after the banner settles (~1.2s)
      if (postScript !== null && postScript.length > 0) {
        setTimeout(() => {
          try {
            const n = SessionService.write(postScript + '\r');
            hilog.info(0x0110, 'oat.term', 'postLoginScript sent %{public}d bytes', n);
          } catch (e2) {
            hilog.warn(0x0110, 'oat.term', 'postLoginScript failed: %{public}s', e2 instanceof Error ? e2.message : String(e2));
          }
        }, TimingConstants.POST_LOGIN_SCRIPT_DELAY);
      }
    }).catch((e: Object) => {
      // M3 relay-2d: connect() throws for missing identities / bad args BEFORE
      // publishing status - surface the reason here or the user sees nothing.
      const msg = e instanceof Error ? e.message : String(e);
      AppStorage.setOrCreate('ut.term.status', 'error');
      AppStorage.setOrCreate('ut.term.reason', msg);
      hilog.error(0x0110, 'oat.term', 'connect rejected: %{public}s', msg);
    });
    this.startPoll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
    if (this.resizeTimer >= 0) {
      clearTimeout(this.resizeTimer);
      this.resizeTimer = -1;
    }
    if (LocalTerminalService.active()) {
      LocalTerminalService.close(); // M5 relay4 fix(bug4): 原先泄漏 localpty
    }
    if (TelnetService.active()) {
      TelnetService.disconnect();
    }
    if (this.opened) {
      SessionService.close();
      this.opened = false;
    }
    SessionService.attachView(null);
  }

  private startPoll(): void {
    // M5 relay6: 自链式 setTimeout 替代 setInterval。实测该环境 setInterval
    // 会在 ~20s 后静默停摆;链式重挂必须放 finally——drainTick 抛异常时
    // 若重挂语句被跳过,整条链就地死亡(22:12 实证:accept 231B 后全静默)。
    this.lastTickMs = Date.now();
    const tickFn = (): void => {
      this.lastTickMs = Date.now();
      try {
        this.drainTick();
      } catch (e) {
        // r6d: catch 内不得再抛(JSON.stringify 对循环引用/原生对象会抛,
        // 吞掉日志并向上传播)。安全降级为 String()。
        let msg: string = '';
        try {
          msg = String(e);
        } catch (e2) {
          msg = 'unserializable';
        }
        hilog.error(0x0110, 'oat.r6', 'drainTick threw: %{public}s %{public}s', typeof e, msg);
      } finally {
        this.pollTimer = setTimeout(tickFn, POLL_MS);
      }
    };
    this.pollTimer = setTimeout(tickFn, POLL_MS);
    // r6e: 独立看门狗——timer 链死后自愈重启(渲染期异常会杀链,实证
    // drain+渲染一次后链必死;看门狗 3s 检查一次,链死 >5s 则重挂)。
    if (this.watchdogTimer < 0) {
      const wdFn = (): void => {
        try {
          const now = Date.now();
          if (this.opened && now - this.lastTickMs > 5000 && this.pollTimer >= 0) {
            hilog.warn(0x0110, 'oat.r6', 'watchdog: poll chain dead %{public}dms, restart',
              now - this.lastTickMs);
            clearTimeout(this.pollTimer);
            this.startPoll();
          }
        } catch (e) {
          // 看门狗自身不得抛
        }
        this.watchdogTimer = setTimeout(wdFn, 3000);
      };
      this.watchdogTimer = setTimeout(wdFn, 3000);
    }
  }

  /** r6e: 交互驱动的同步排空(timer 链死时 UI 事件仍是活的)。 */
  private kickPoll(): void {
    if (this.pollTimer >= 0 && Date.now() - this.lastTickMs > 800) {
      try {
        this.drainTick();
      } catch (e) {
        // 排空失败不阻塞交互
      }
    }
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.watchdogTimer >= 0) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  /** Poll: merge ssh bytes into the model, update window + stats. */
  private drainTick(): void {
    // M5 relay4: 本地终端走同步 ptyPoll(tsfn 异步回调在该环境不交付)
    if (LocalTerminalService.active()) {
      let chunk: string = '';
      try {
        chunk = LocalTerminalService.poll()
      } catch (e) {
        hilog.error(0x0110, 'oat.r6', 'poll threw: %{public}s', e instanceof Error ? e.message : String(e))
      }
      const clen = chunk === undefined || chunk === null ? -1 : chunk.length
      if (clen > 0) {
        if (chunk === '__PTY_EOF__') {
          // M5 relay6: sh exit(master EOF)→ native 已自愈关闭;置断开态,
          // tab 保留历史输出(此前 exit 后 master 死,后续 write 全静默失败)
          LocalTerminalService.close()
          AppStorage.setOrCreate('ut.term.status', 'disconnected')
          hilog.info(0x0110, 'oat.r6', 'pty EOF -> disconnected')
        } else {
          this.view.accept(chunk)
          hilog.info(0x0110, 'oat.r6', 'accepted len=%{public}d lines=%{public}d screenTop=%{public}d',
            clen, this.model.lines.length, this.model.screenTop())
        }
      } else {
        // r6 心跳:每 ~10s 一条,证明轮询链活着(诊断 interval 停摆用)
        if ((this.hb++ % 100) === 0) {
          hilog.info(0x0110, 'oat.r6', 'alive lines=%{public}d status=%{public}s',
            this.model.lines.length, this.storageStatus)
        }
      }
    }
    const grew = this.view.drain();
    const st = SessionService.stats();
    // M5 relay6: 本地终端时 SessionService.stats() 恒为 0,用 model 真值
    this.statText = this.isLocal
      ? this.model.lines.length + ' lines (local)  top=' + this.winTop
      : st.lines + ' lines  ' + st.bytes + 'B  ' + st.chunks + ' chunks'
        + (st.lastCmdMs >= 0 ? '  last ' + st.lastCmdMs + 'ms' : '');
    if (grew && this.followTail) {
      this.tick++;
      this.refreshWindow(true);
      try {
        this.scroller.scrollEdge(Edge.Bottom); // M5 relay6: 视口贴住最新输出
      } catch (e) {
        // r6d: scrollEdge 在部分布局阶段不可调用,不得让它杀掉轮询链
      }
    } else if (grew) {
      this.tick++;
      const total = this.model.lines.length;
      this.winTop = Math.max(0, Math.min(this.winTop, total - 1));
      this.refreshWindow(false);
    }
  }

  /** Re-snapshot the bound window from the model into @State winRows. */
  private refreshWindow(follow: boolean): void {
    const total = this.model.lines.length;
    if (follow || this.followTail) {
      this.winTop = Math.max(0, total - this.winSize);
    }
    const top = Math.min(this.winTop, Math.max(0, total - 1));
    const end = Math.min(total, top + this.winSize);
    this.winRows = this.model.lines.slice(top, end);
  }

  private measureDims(): Dims {
    // r6e: display API 在 VM 环境会量出虚假大尺寸(实测 226x59,高度含
    // 导航栏+状态栏且密度异常);终端区真实可用高度以 onAreaChange 实测
    // 为准。measureDims 只给保守初值:onAreaChange 稳定后必然覆盖。
    let bodyW = 1080;
    let bodyH = 600;
    let density = 3;
    try {
      const dd = display.getDefaultDisplaySync();
      // 只信任宽度;高度按典型比例 16:9 保守估算
      if (dd.width > 0 && dd.densityPixels > 0) {
        density = dd.densityPixels;
        bodyW = dd.width / density;
        bodyH = bodyW * 9 / 16;
      }
    } catch (e) {
      // keep defaults
    }
    let charW = TERM_FONT_SIZE * 0.6;
    let lineH = TERM_FONT_SIZE * 1.45;
    try {
      const probe = 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM';
      const opts: MeasureOptions = {
        textContent: probe,
        fontSize: TERM_FONT_SIZE,
        fontFamily: TERM_FONT_FAMILY
      };
      const w = MeasureText.measureText(opts);
      if (w > 0) {
        charW = w / 40 / density;
      }
      const sz = MeasureText.measureTextSize(opts);
      const hh = sz.height as number;
      if (hh > 0) {
        lineH = hh;
      }
    } catch (e) {
      // keep estimates
    }
    bodyH = bodyH - 2 * BODY_PAD - 56 /* header */ - 60 /* footer */;
    const cols = Math.max(20, Math.floor(bodyW / charW));
    const rows = Math.max(6, Math.floor(bodyH / lineH));
    const out: Dims = { cols: cols, rows: rows, charWidth: charW };
    return out;
  }

  private termViewportH: number = 1000;

  private pxPerRowDensity(): number {
    try {
      const d = display.getDefaultDisplaySync();
      return d.densityPixels;
    } catch (e) {
      return 3;
    }
  }

  private pendingCols: number = -1; // M5 relay6: onAreaChange 防抖
  private pendingRows: number = -1;
  private areaOpenMs: number = -1; // <0 = 未开窗;否则 = onBodyArea 首调时间戳

  private onBodyArea(w: number, h: number): void {
    // M5 relay6: 初次布局的 onAreaChange 序列不可信(先报未稳定的大高度,
    // 后报真实值;若中间值被应用,模型会被虚假 resize 撑大)。开窗 700ms 内
    // 只记录最终一对值,开窗结束时统一应用(pending 被后续"回到当前值"的
    // 事件清除 = 布局已稳定,无需 resize)。
    const now = Date.now();
    if (this.areaOpenMs < 0) {
      this.areaOpenMs = now;
      setTimeout(() => {
        // 开窗结束:应用最后见到的一对值(若仍与当前不同)
        if (this.pendingCols > 0 && this.pendingRows > 0
          && (this.pendingCols !== this.cols || this.pendingRows !== this.rows)) {
          this.applyResize(this.pendingCols, this.pendingRows);
        }
        this.pendingCols = -1;
        this.pendingRows = -1;
      }, 750);
    }
    const inOpenWindow = (now - this.areaOpenMs) < 700;
    this.termViewportH = h;
    let density = 1;
    try {
      const d = display.getDefaultDisplaySync();
      density = d.densityPixels;
    } catch (e) {
      // keep 1
    }
    let charW = TERM_FONT_SIZE * 0.6;
    try {
      const probe = 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM';
      const opts: MeasureOptions = {
        textContent: probe,
        fontSize: TERM_FONT_SIZE,
        fontFamily: TERM_FONT_FAMILY
      };
      const mw = MeasureText.measureText(opts);
      if (mw > 0) {
        charW = mw / 40 / density;
      }
    } catch (e) {
      // keep estimate
    }
    const cols = Math.max(20, Math.floor((w - 2 * BODY_PAD) / charW));
    const rows = Math.max(6, Math.floor((h - 2 * BODY_PAD) / (TERM_FONT_SIZE * 1.45)));
    if (cols === this.cols && rows === this.rows) {
      this.pendingCols = -1;
      this.pendingRows = -1;
      if (this.resizeTimer >= 0) {
        clearTimeout(this.resizeTimer);
        this.resizeTimer = -1;
      }
      return;
    }
    if (inOpenWindow) {
      // 只记录,不应用;等开窗结束后第一对稳定值
      this.pendingCols = cols;
      this.pendingRows = rows;
      return;
    }
    if (cols === this.pendingCols && rows === this.pendingRows) {
      this.applyResize(cols, rows);
      return;
    }
    this.pendingCols = cols;
    this.pendingRows = rows;
    if (this.resizeTimer >= 0) {
      clearTimeout(this.resizeTimer);
    }
    this.resizeTimer = setTimeout(() => {
      this.resizeTimer = -1;
      if (this.pendingCols > 0 && this.pendingRows > 0) {
        this.applyResize(this.pendingCols, this.pendingRows);
        this.pendingCols = -1;
        this.pendingRows = -1;
      }
    }, 400);
  }

  private applyResize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) {
      return;
    }
    this.cols = cols;
    this.rows = rows;
    this.winSize = rows + 2 * WIN_OVERSCAN;
    this.model.resize(cols, rows);
    this.measureNote = 'area ' + cols + 'x' + rows;
    if (this.opened) {
      // M5 relay6: 本地终端也要 resize(pty winsize),原实现只通知 ssh
      if (LocalTerminalService.active()) {
        LocalTerminalService.resize(cols, rows);
      } else {
        SessionService.resize(cols, rows);
      }
    }
  }

  private send(): void {
    const text = this.input + '\r';
    if (TelnetService.active()) {
      TelnetService.write(text);
    } else if (LocalTerminalService.active()) {
      LocalTerminalService.write(text);
    } else {
      SessionService.write(text);
    }
    this.input = '';
    this.kickPoll(); // r6e: timer 链会被渲染期异常杀死,交互驱动同步排空兜底
  }

  /** Hardware-key -> terminal byte mapping. Returns the string to write. */
  private mapKey(code: number, ev: KeyEvent): string {
    let ctrl = false;
    try {
      if (ev.getModifierKeyState !== undefined && ev.getModifierKeyState(['Ctrl'])) {
        ctrl = true;
      }
    } catch (e) {
      // modifier probe unsupported: fall through plain
    }
    if (ctrl) {
      if (code >= KC_A && code <= KC_Z) {
        return String.fromCharCode(code - KC_A + 1); // \x01..\x1a (Ctrl+C etc)
      }
      if (code === KC_BACKSLASH) {
        return String.fromCharCode(28); // Ctrl+backslash
      }
      if (code === KC_GRAVE) {
        return String.fromCharCode(0); // Ctrl+Space / NUL
      }
      return '';
    }
    switch (code) {
      case KC_ENTER:
      case KC_DPAD_CENTER:
        return '\r';
      case KC_DEL:
        return '\x7f';
      case KC_TAB:
        return '\t';
      case KC_ESCAPE:
        return '\x1b';
      case KC_DPAD_UP:
        return '\x1b[A';
      case KC_DPAD_DOWN:
        return '\x1b[B';
      case KC_DPAD_RIGHT:
        return '\x1b[C';
      case KC_DPAD_LEFT:
        return '\x1b[D';
      case KC_MOVE_HOME:
        return '\x1b[H';
      case KC_MOVE_END:
        return '\x1b[F';
      case KC_PAGE_UP:
        return '\x1b[5~';
      case KC_PAGE_DOWN:
        return '\x1b[6~';
      default:
        break;
    }
    // printable single chars: keyText covers ASCII printables incl. space
    const t = ev.keyText;
    if (t !== undefined && t !== null && t.length === 1) {
      const c = t.charCodeAt(0);
      if (c >= 0x20 && c < 0x7f) {
        return t;
      }
    }
    return '';
  }

  private onTermKey(ev: KeyEvent): boolean {
    if (ev.type !== KeyType.Down) {
      return false;
    }
    if (!this.passthrough || !this.opened) {
      return false;
    }
    const s = this.mapKey(ev.keyCode, ev);
    if (s.length > 0) {
      if (TelnetService.active()) {
        TelnetService.write(s);
      } else if (LocalTerminalService.active()) {
        LocalTerminalService.write(s);
      } else {
        SessionService.write(s);
      }
      this.kickPoll(); // r6e: 按键后同步排空回显
      return true; // consumed: no focus navigation side effect
    }
    return false;
  }

  @Builder
  StatusBadge() {
    Text(this.badgeText())
      .fontSize(DesignTokens.FONT_BODY)
      .fontColor(this.th().surfaceRaised)
      .backgroundColor(this.badgeColor())
      .borderRadius(DesignTokens.RADIUS_MD)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
  }

  private badgeText(): string {
    const s = this.storageStatus;
    if (s === 'connected') {
      return 'connected';
    }
    if (s === 'connecting') {
      return 'connecting';
    }
    if (s === 'error') {
      return 'error';
    }
    if (s === 'disconnected') {
      return 'disconnected';
    }
    return 'idle';
  }

  private badgeColor(): ResourceColor {
    const s = this.storageStatus;
    if (s === 'connected') {
      return this.th().success;
    }
    if (s === 'connecting') {
      return this.th().warn;
    }
    if (s === 'error') {
      return this.th().danger;
    }
    return this.th().inkSubtle;
  }

  @Builder
  TermLineView(line: TermLine, rowIdx: number) {
    Row() {
      ForEach(lineToSpans(line, this.cursorXFor(rowIdx), this.cursorVisibleFor(rowIdx)),
        (run: SpanRun, idx: number) => {
          Text(run.text.replace(/ /g, '\u00a0'))
            .fontSize(TERM_FONT_SIZE)
            .fontFamily(TERM_FONT_FAMILY)
            .fontColor(run.fg)
            .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(run.bg !== null ? run.bg : Color.Transparent)
        }, (run: SpanRun, idx: number) => rowIdx.toString() + ':' + idx.toString() + ':'
          + run.text.length + ':' + run.fg + ':' + (run.bg ?? '-'))
    }
    .height(TERM_FONT_SIZE * 1.5)
    .width('100%')
  }

  private cursorXFor(rowIdx: number): number {
    if (!this.model.cursor.visible) {
      return -1;
    }
    const cy = this.model.lines.length - this.model.rows + this.model.cursor.y;
    if (rowIdx === cy) {
      return this.model.cursor.x;
    }
    return -1;
  }

  private cursorVisibleFor(rowIdx: number): boolean {
    return this.focused;
  }

  build() {
    Column() {
      // header
      Column() {
        Row({ space: 8 }) {
          Column() {
            Text(this.title)
              .fontSize(DesignTokens.FONT_DISPLAY)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().surfaceRaised)
              .maxLines(1)
            Text(this.cols.toString() + 'x' + this.rows.toString() + '  ' + this.measureNote
              + (this.focused ? '  [key-passthrough]' : ''))
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.StatusBadge()

          Button('SFTP')
            .fontSize(DesignTokens.FONT_BODY)
            .backgroundColor(this.th().brand)
            .enabled(this.storageStatus === 'connected')
            .onClick(() => {
              AppStorage.setOrCreate('ut.openSftp', this.connId);
            })
          Button('close')
            .fontSize(DesignTokens.FONT_BODY)
            .backgroundColor(this.th().danger)
            .onClick(() => {
              if (TelnetService.active()) {
                TelnetService.disconnect();
              }
              SessionService.close();
              AppStorage.setOrCreate('ut.closeTab', this.connId);
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

        Text(this.statText)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 4 })

        if (this.storageStatus === 'error' && this.storageReason.length > 0) {
          Text('error: ' + this.storageReason)
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().danger)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 6 })
        }
      }
      .width('100%')
      .backgroundColor(this.th().panel)

      // terminal body: focusable surface for hardware key passthrough
      Scroll(this.scroller) {
        Column() {
          ForEach(this.winRows, (line: TermLine, idx: number) => {
            this.TermLineView(line, this.winTop + idx)
          }, (line: TermLine, idx: number) => (this.winTop + idx).toString() + ':' + line.rev.toString() + ':'
            + this.tick.toString())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(BODY_PAD)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(TERM_DEFAULT_BG)
      .align(Alignment.Bottom)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
      .focusable(true)
      .focusOnTouch(true)
      .defaultFocus(true)
      .onClick(() => {
        this.focused = true;
        this.tick++;
      })
      .onKeyEvent((ev: KeyEvent) => {
        return this.onTermKey(ev);
      })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w = newArea.width as number;
        const h = newArea.height as number;
        this.onBodyArea(w, h);
      })

      // footer: IME fallback input line + passthrough toggle
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.passthrough })
          .onChange((on: boolean) => {
            this.passthrough = on;
          })
        Text('PT')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.passthrough ? this.th().success : this.th().inkSubtle)
        TextInput({ placeholder: 'input + Enter...', text: this.input })
          .layoutWeight(1)
          .fontSize(DesignTokens.FONT_HEADING)
          .fontFamily(TERM_FONT_FAMILY)
          .backgroundColor(this.th().surface)
          .fontColor(TERM_DEFAULT_FG)
          .placeholderColor(this.th().inkSubtle)
          .onChange((v: string) => {
            this.input = v;
          })
          .onSubmit(() => {
            this.send();
          })
        Button('send')
          .fontSize(DesignTokens.FONT_HEADING)
          .backgroundColor(this.th().success)
          .onClick(() => {
            this.send();
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 10 })
      .backgroundColor(this.th().panel)
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * Bridge from SessionService events to the TermModel. Runs inside the tsfn
 * JS callback (main thread), so attach/drain are same-thread with the page.
 */
class TermBufferView implements TermView {
  private model: TermModel | null = null;
  private dirty: boolean = false;

  attach(m: TermModel): void {
    this.model = m;
  }

  accept(raw: string): void {
    if (this.model !== null && raw.length > 0) {
      this.model.feed(raw);
      this.dirty = true;
    }
  }

  drain(): boolean {
    const d = this.dirty;
    this.dirty = false;
    return d;
  }

  modelOf(): TermModel | null {
    return this.model;
  }
}
