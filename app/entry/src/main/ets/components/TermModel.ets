/**
 * upstream M2 relay-4 - ANSI terminal emulator model (line grid + cursor).
 *
 * Minimal-but-honest VT100/xterm subset over a row-of-CharCell grid:
 *  - SGR colors: fg 8/16 + 256 + default reset; bg default/black (bold may
 *    brighten fg per xterm convention);
 *  - cursor control: CR LF BS TAB, CUU/CUD/CUF/CUB/CUP/HVP, EL/ED, IL/DL,
 *    CHA/VPA, NEL/RI/ICH/DCH, SU/SD, DECSC/DECRC, hide/show, DECSET modes;
 *  - implicit wrap (DECAWM) with pending-wrap semantics;
 *  - unknown sequences are swallowed (never displayed as garbage);
 *  - scrollback up to MAX_SCROLLBACK lines (older trimmed);
 *  - dirty-flag based redraw: only lines touched since last snapshot change
 *    their ForEach keys, so 20000-line floods do not re-bind clean lines.
 *
 * Screen model: `lines` is a log; the SCREEN is the LAST `rows` entries.
 * cursor.y is screen-relative; all CSI ops translate via screenTop().
 * Feed() takes one decoded UTF-8 chunk (may cut sequences mid-way; the
 * parser carries incomplete CSI/OSC tails across calls).
 */

export const TERM_DEFAULT_FG: string = '#d4f0e0';
export const TERM_DEFAULT_BG: string = '#0d1117';

const MAX_COLS: number = 300;
const MAX_SCROLLBACK: number = 5000;

/** One styled cell; attr groups cells that share SGR state. */
export class CharCell {
  char: string = ' ';
  fg: number = 0; // index into AnsiPalette.FG, 0 = default
  bg: number = 0; // 0 = default bg, 1 = black bg
  bold: boolean = false;
  inv: boolean = false;
}

/** 256-color foreground palette (index 0 = default, 1..16 base, 17..256 cube+gray). */
export class AnsiPalette {
  static readonly FG: string[] = AnsiPalette.build();

  private static build(): string[] {
    const p: string[] = [];
    p.push(TERM_DEFAULT_FG); // 0: default
    const base = ['#c9d1d9', '#ff7b72', '#3fb950', '#d29922',
      '#58a6ff', '#bc8cff', '#39c5cf', '#e6edf3',
      '#ffffff', '#ffa198', '#56d364', '#e3b341',
      '#79c0ff', '#d2a8ff', '#56d4dd', '#f0f6fc'];
    for (let i = 0; i < 16; i++) {
      p.push(base[i]);
    }
    for (let r = 0; r < 6; r++) {
      for (let g = 0; g < 6; g++) {
        for (let b = 0; b < 6; b++) {
          const lv = (v: number): number => v === 0 ? 0 : 55 + v * 40;
          p.push(AnsiPalette.rgb(lv(r), lv(g), lv(b)));
        }
      }
    }
    const grays = ['#080808', '#1c1c1c', '#282828', '#343434', '#404040', '#4c4c4c', '#585858', '#646464',
      '#707070', '#7c7c7c', '#888888', '#949494', '#a0a0a0', '#acacac', '#b8b8b8', '#c4c4c4',
      '#d0d0d0', '#dcdcdc', '#e8e8e8', '#f4f4f4', '#ffffff'];
    for (let i = 0; i < 24; i++) {
      p.push(grays[i]);
    }
    return p;
  }

  static rgb(r: number, g: number, b: number): string {
    const h = (v: number): string => {
      const s = (v < 16 ? '0' : '') + v.toString(16);
      return s;
    };
    return '#' + h(r) + h(g) + h(b);
  }
}

const PALETTE_BG: string[] = [TERM_DEFAULT_BG, '#000000'];
const CURSOR_COLOR: string = '#58a6ff';

/** Visible line snapshot handed to the page render. */
export class TermLine {
  cells: CharCell[] = [];
  rev: number = 0; // bumped on any mutation -> ForEach key
}

export class TermCursor {
  x: number = 0;
  y: number = 0; // screen-relative (0 = top screen row)
  visible: boolean = true;
}

interface SaveState {
  x: number;
  y: number;
  fg: number;
  bg: number;
  bold: boolean;
  inv: boolean;
}

export class TermModel {
  cols: number;
  rows: number;
  lines: TermLine[] = []; // log; screen = last `rows` entries
  cursor: TermCursor = new TermCursor();
  dirtyAll: boolean = false;

  private pendWrap: boolean = false;
  private fgCur: number = 0;
  private bgCur: number = 0;
  private boldCur: boolean = false;
  private invCur: boolean = false;
  private save: SaveState | null = null;
  private carry: string = ''; // incomplete escape tail across chunks
  private gen: number = 1;
  /** tty7-M4b: alternate screen active (DECSET 1049/1047/47) - input layer
   *  passthrough hint, no separate screen buffer (log model keeps lines). */
  altScreen: boolean = false;

  constructor(cols: number, rows: number) {
    this.cols = Math.min(Math.max(20, cols), MAX_COLS);
    this.rows = Math.max(2, rows);
    this.resetScreen();
  }

  resetScreen(): void {
    this.lines = [];
    for (let r = 0; r < this.rows; r++) {
      this.lines.push(this.blankLine());
    }
    this.cursor.x = 0;
    this.cursor.y = 0;
    this.cursor.visible = true;
    this.pendWrap = false;
    this.fgCur = 0;
    this.bgCur = 0;
    this.boldCur = false;
    this.invCur = false;
    this.carry = '';
    this.markAllDirty();
  }

  /** Full resize: keep log, rebuild screen, clamp cursor. */
  resize(cols: number, rows: number): void {
    const nc = Math.min(Math.max(20, cols), MAX_COLS);
    const nr = Math.max(2, rows);
    if (nc === this.cols && nr === this.rows) {
      return;
    }
    if (nr < this.rows) {
      // M5 relay6: 收缩时回收尾部空行。虚假大 resize(onAreaChange 初开报
      // 未稳定高度)会长出几十行空白,把光标行推到 screenTop 折叠线之下;
      // 回缩后必须裁掉这些尾部空行,否则屏幕永远显示空白窗口。
      const absY = this.lines.length - this.rows + this.cursor.y;
      while (this.lines.length > nr && this.lines[this.lines.length - 1].cells.length === 0
        && this.lines.length - 1 !== absY) {
        this.lines.pop();
      }
      this.cursor.y = Math.min(nr - 1, Math.max(0, absY - (this.lines.length - nr)));
    }
    this.cols = nc;
    this.rows = nr;
    while (this.lines.length < this.rows) {
      this.lines.push(this.blankLine());
    }
    if (this.cursor.y >= this.rows) {
      this.cursor.y = this.rows - 1;
    }
    if (this.cursor.x >= this.cols) {
      this.cursor.x = 0;
    }
    this.markAllDirty();
  }

  /** Index in `lines` of screen row 0. */
  screenTop(): number {
    return Math.max(0, this.lines.length - this.rows);
  }

  /** Absolute index of the cursor line. */
  private absY(): number {
    return this.screenTop() + this.cursor.y;
  }

  private blankLine(): TermLine {
    const l = new TermLine();
    l.cells = [];
    return l;
  }

  private markAllDirty(): void {
    this.dirtyAll = true;
    this.gen++;
    for (let i = 0; i < this.lines.length; i++) {
      this.lines[i].rev = this.gen;
    }
  }

  private touch(row: number): void {
    if (row >= 0 && row < this.lines.length) {
      this.lines[row].rev = this.gen;
    }
  }

  /** Feed one decoded ssh chunk into the parser. */
  feed(raw: string): void {
    let s = this.carry + raw;
    this.carry = '';
    let i = 0;
    while (i < s.length) {
      const code = s.charCodeAt(i);
      if (code === 0x1b) {
        const end = TermModel.seqEnd(s, i);
        if (end < 0) {
          this.carry = s.substring(i);
          return;
        }
        this.execSeq(s.substring(i, end));
        i = end;
        continue;
      }
      if (code < 0x20 || code === 0x7f) {
        this.execCtl(code);
        i++;
        continue;
      }
      let cp = 1;
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
        const c2 = s.charCodeAt(i + 1);
        if (c2 >= 0xdc00 && c2 <= 0xdfff) {
          cp = 2;
        }
      }
      this.putChar(s.substring(i, i + cp));
      i += cp;
    }
  }

  /** Returns index AFTER the sequence end char, or -1 if incomplete. */
  private static seqEnd(s: string, start: number): number {
    const n = s.length;
    let i = start + 1;
    if (i >= n) {
      return -1;
    }
    const c = s.charCodeAt(i);
    if (c === 0x5b) { // CSI  ESC [
      i++;
      while (i < n) {
        const d = s.charCodeAt(i);
        if (d >= 0x40 && d <= 0x7e) {
          return i + 1;
        }
        i++;
      }
      return -1;
    }
    if (c === 0x5d) { // OSC  ESC ]
      while (i < n) {
        const d = s.charCodeAt(i);
        if (d === 0x07) {
          return i + 1;
        }
        if (d === 0x1b && i + 1 < n && s.charCodeAt(i + 1) === 0x5c) {
          return i + 2;
        }
        i++;
      }
      return -1;
    }
    return i + 1; // two-char ESC X
  }

  private execCtl(code: number): void {
    switch (code) {
      case 0x0d: // CR
        this.cursor.x = 0;
        this.pendWrap = false;
        break;
      case 0x0a:
      case 0x0b:
      case 0x0c:
        this.lf();
        break;
      case 0x08: // BS
        if (this.cursor.x > 0) {
          this.cursor.x--;
        }
        this.pendWrap = false;
        break;
      case 0x09: { // TAB
        const nx = Math.min(this.cols - 1, (Math.floor(this.cursor.x / 8) + 1) * 8);
        this.cursor.x = nx;
        this.pendWrap = false;
        break;
      }
      default:
        break;
    }
  }

  private lf(): void {
    if (this.cursor.y === this.rows - 1) {
      // bottom newline: append a row; screen slides up by construction
      this.lines.push(this.blankLine());
      this.trimScrollback();
    } else {
      this.cursor.y++;
    }
    this.pendWrap = false;
  }

  private scrollUp(n: number): void {
    for (let k = 0; k < n; k++) {
      this.lines.push(this.blankLine());
    }
    this.trimScrollback();
    this.markAllDirty();
  }

  private scrollDown(n: number): void {
    for (let k = 0; k < n; k++) {
      this.lines.pop();
      if (this.lines.length < this.rows) {
        this.lines.unshift(this.blankLine());
      }
    }
    this.markAllDirty();
  }

  private trimScrollback(): void {
    while (this.lines.length > this.rows + MAX_SCROLLBACK) {
      this.lines.shift();
    }
  }

  private ensureCell(line: TermLine, x: number): void {
    while (line.cells.length <= x) {
      const c = new CharCell();
      line.cells.push(c);
    }
  }

  private putChar(ch: string): void {
    if (this.pendWrap) {
      this.cursor.x = 0;
      this.lf();
    }
    if (this.cursor.x >= this.cols) {
      this.cursor.x = this.cols - 1;
    }
    const ay = this.absY();
    if (ay >= this.lines.length) {
      return; // defensive
    }
    const line = this.lines[ay];
    this.ensureCell(line, this.cursor.x);
    const cell = line.cells[this.cursor.x];
    cell.char = ch;
    cell.fg = this.fgCur;
    cell.bg = this.bgCur;
    cell.bold = this.boldCur;
    cell.inv = this.invCur;
    this.touch(ay);
    if (this.cursor.x === this.cols - 1) {
      this.pendWrap = true;
    } else {
      this.cursor.x++;
    }
  }

  // ---- CSI parameter parsing ----
  private static parseParams(body: string): number[] {
    const out: number[] = [];
    let cur = '';
    let any = false;
    for (let i = 0; i < body.length; i++) {
      const ch = body.charAt(i);
      if (ch >= '0' && ch <= '9') {
        cur += ch;
        any = true;
      } else if (ch === ';') {
        out.push(cur.length === 0 ? 0 : parseInt(cur));
        cur = '';
      }
    }
    if (any || cur.length > 0) {
      out.push(cur.length === 0 ? 0 : parseInt(cur));
    }
    return out;
  }

  private static p(params: number[], idx: number, def: number): number {
    if (idx < params.length && params[idx] > 0) {
      return params[idx];
    }
    return def;
  }

  private execSeq(seq: string): void {
    if (seq.length < 2) {
      return;
    }
    const t = seq.charCodeAt(1);
    if (t === 0x5b) { // CSI
      const body = seq.substring(2, seq.length - 1);
      const fin = seq.charAt(seq.length - 1);
      const params = TermModel.parseParams(body);
      this.execCsi(body, fin, params);
      return;
    }
    if (t === 0x5d) { // OSC
      return;
    }
    switch (t) {
      case 0x37: // DECSC
        this.save = { x: this.cursor.x, y: this.cursor.y, fg: this.fgCur, bg: this.bgCur,
          bold: this.boldCur, inv: this.invCur };
        break;
      case 0x39: // DECRC
        if (this.save !== null) {
          this.cursor.x = this.save.x;
          this.cursor.y = Math.min(this.rows - 1, this.save.y);
          this.fgCur = this.save.fg;
          this.bgCur = this.save.bg;
          this.boldCur = this.save.bold;
          this.invCur = this.save.inv;
        }
        break;
      case 0x4d: // RI
        if (this.cursor.y === 0) {
          this.scrollDown(1);
        } else {
          this.cursor.y--;
        }
        break;
      default:
        break;
    }
  }

  private execCsi(body: string, fin: string, params: number[]): void {
    if (body.startsWith('?')) {
      this.execPrivateMode(body, fin);
      return;
    }
    if (body.startsWith('>') || body.startsWith('<') || body.startsWith('=') || body.startsWith('!')) {
      return;
    }
    switch (fin) {
      case 'A':
        this.cursor.y = Math.max(0, this.cursor.y - TermModel.p(params, 0, 1));
        this.pendWrap = false;
        break;
      case 'B':
        this.cursor.y = Math.min(this.rows - 1, this.cursor.y + TermModel.p(params, 0, 1));
        this.pendWrap = false;
        break;
      case 'C':
        this.cursor.x = Math.min(this.cols - 1, this.cursor.x + TermModel.p(params, 0, 1));
        this.pendWrap = false;
        break;
      case 'D':
        this.cursor.x = Math.max(0, this.cursor.x - TermModel.p(params, 0, 1));
        this.pendWrap = false;
        break;
      case 'E':
        this.cursor.y = Math.min(this.rows - 1, this.cursor.y + TermModel.p(params, 0, 1));
        this.cursor.x = 0;
        this.pendWrap = false;
        break;
      case 'F':
        this.cursor.y = Math.max(0, this.cursor.y - TermModel.p(params, 0, 1));
        this.cursor.x = 0;
        this.pendWrap = false;
        break;
      case 'G':
        this.cursor.x = Math.min(this.cols - 1, Math.max(0, TermModel.p(params, 0, 1) - 1));
        this.pendWrap = false;
        break;
      case 'H':
      case 'f':
        this.cursor.y = Math.min(this.rows - 1, Math.max(0, TermModel.p(params, 0, 1) - 1));
        this.cursor.x = Math.min(this.cols - 1, Math.max(0, TermModel.p(params, 1, 1) - 1));
        this.pendWrap = false;
        break;
      case 'd': // VPA
        this.cursor.y = Math.min(this.rows - 1, Math.max(0,
          (params.length > 0 && params[0] > 0 ? params[0] : 1) - 1));
        this.pendWrap = false;
        break;
      case 'J': { // ED
        const m = params.length > 0 ? params[0] : 0;
        const base = this.screenTop();
        if (m === 0) {
          this.eraseInLine(0);
          for (let r = this.cursor.y + 1; r < this.rows; r++) {
            this.lines[base + r] = this.blankLine();
            this.touch(base + r);
          }
        } else if (m === 1) {
          this.eraseInLine(1);
          for (let r = 0; r < this.cursor.y; r++) {
            this.lines[base + r] = this.blankLine();
            this.touch(base + r);
          }
        } else {
          for (let r = 0; r < this.rows; r++) {
            this.lines[base + r] = this.blankLine();
            this.touch(base + r);
          }
        }
        break;
      }
      case 'K':
        this.eraseInLine(params.length > 0 ? params[0] : 0);
        break;
      case 'L': { // IL (insert blank lines at cursor, screen-local)
        const n = Math.min(TermModel.p(params, 0, 1), this.rows - this.cursor.y);
        for (let k = 0; k < n; k++) {
          this.lines.splice(this.absY(), 0, this.blankLine());
          this.lines.pop(); // keep screen size
        }
        this.markAllDirty();
        break;
      }
      case 'M': { // DL
        const n2 = Math.min(TermModel.p(params, 0, 1), this.rows - this.cursor.y);
        this.lines.splice(this.absY(), n2);
        for (let k = 0; k < n2; k++) {
          this.lines.push(this.blankLine());
        }
        this.markAllDirty();
        break;
      }
      case 'P': { // DCH
        const line = this.lines[this.absY()];
        const n = TermModel.p(params, 0, 1);
        if (this.cursor.x < line.cells.length) {
          line.cells.splice(Math.min(this.cursor.x, line.cells.length - 1), n);
          this.touch(this.absY());
        }
        break;
      }
      case '@': { // ICH
        const line2 = this.lines[this.absY()];
        const n = TermModel.p(params, 0, 1);
        for (let k = 0; k < n; k++) {
          const c = new CharCell();
          line2.cells.splice(this.cursor.x, 0, c);
        }
        this.touch(this.absY());
        break;
      }
      case 'S':
        this.scrollUp(Math.min(TermModel.p(params, 0, 1), this.rows));
        break;
      case 'T':
        this.scrollDown(Math.min(TermModel.p(params, 0, 1), this.rows));
        break;
      case 'X': { // ECH
        const line = this.lines[this.absY()];
        const n = TermModel.p(params, 0, 1);
        this.ensureCell(line, this.cursor.x + n - 1);
        for (let k = 0; k < n; k++) {
          const c = line.cells[this.cursor.x + k];
          c.char = ' ';
          c.fg = 0;
          c.bg = 0;
          c.bold = false;
          c.inv = false;
        }
        this.touch(this.absY());
        break;
      }
      case 'm':
        this.execSgr(params);
        break;
      case 'h':
      case 'l':
        break;
      case 'n':
        break;
      case 's':
        this.save = { x: this.cursor.x, y: this.cursor.y, fg: this.fgCur, bg: this.bgCur,
          bold: this.boldCur, inv: this.invCur };
        break;
      case 'u':
        if (this.save !== null) {
          this.cursor.x = this.save.x;
          this.cursor.y = Math.min(this.rows - 1, this.save.y);
        }
        break;
      default:
        break;
    }
  }

  private execPrivateMode(body: string, fin: string): void {
    if (fin !== 'h' && fin !== 'l') {
      return;
    }
    const set = fin === 'h';
    const bodyNums = body.replace('?', '');
    const parts = bodyNums.split(';');
    for (let i = 0; i < parts.length; i++) {
      const m = parseInt(parts[i]);
      if (isNaN(m)) {
        continue;
      }
      if (m === 25) {
        this.cursor.visible = set;
      }
    }
  }

  private execSgr(params: number[]): void {
    if (params.length === 0) {
      params = [0];
    }
    let i = 0;
    while (i < params.length) {
      const v = params[i];
      switch (v) {
        case 0:
          this.fgCur = 0;
          this.bgCur = 0;
          this.boldCur = false;
          this.invCur = false;
          break;
        case 1:
          this.boldCur = true;
          break;
        case 2:
          break;
        case 22:
          this.boldCur = false;
          break;
        case 7:
          this.invCur = true;
          break;
        case 27:
          this.invCur = false;
          break;
        case 39:
          this.fgCur = 0;
          break;
        case 49:
          this.bgCur = 0;
          break;
        case 30:
        case 31:
        case 32:
        case 33:
        case 34:
        case 35:
        case 36:
        case 37:
          this.fgCur = 1 + (v - 30);
          break;
        case 90:
        case 91:
        case 92:
        case 93:
        case 94:
        case 95:
        case 96:
        case 97:
          this.fgCur = 9 + (v - 90);
          break;
        case 40:
        case 41:
        case 42:
        case 43:
        case 44:
        case 45:
        case 46:
        case 47:
        case 100:
        case 101:
        case 102:
        case 103:
        case 104:
        case 105:
        case 106:
        case 107:
          this.bgCur = 1;
          break;
        case 38:
        case 48: {
          const target = v === 38;
          if (i + 1 < params.length && params[i + 1] === 5 && i + 2 < params.length) {
            const c = params[i + 2];
            if (c >= 0 && c <= 255) {
              if (target) {
                this.fgCur = c === 0 ? 1 : c + 1;
              } else {
                this.bgCur = 1;
              }
              i += 2;
            }
          } else if (i + 1 < params.length && params[i + 1] === 2 && i + 4 < params.length) {
            if (target) {
              const r = params[i + 2] & 0xff;
              const g = params[i + 3] & 0xff;
              const b = params[i + 4] & 0xff;
              this.fgCur = this.nearestPalette(r, g, b);
            }
            i += 4;
          }
          break;
        }
        default:
          break;
      }
      i++;
    }
  }

  private nearestPalette(r: number, g: number, b: number): number {
    let best = 1;
    let bestD = Number.MAX_VALUE;
    for (let idx = 17; idx < AnsiPalette.FG.length; idx++) {
      const hex = AnsiPalette.FG[idx];
      const pr = parseInt(hex.substring(1, 3), 16);
      const pg = parseInt(hex.substring(3, 5), 16);
      const pb = parseInt(hex.substring(5, 7), 16);
      const dr = pr - r;
      const dg = pg - g;
      const db = pb - b;
      const d = dr * dr + dg * dg + db * db;
      if (d < bestD) {
        bestD = d;
        best = idx;
      }
    }
    return best;
  }

  private eraseInLine(mode: number): void {
    const ay = this.absY();
    const line = this.lines[ay];
    if (mode === 0) {
      if (this.cursor.x < line.cells.length) {
        line.cells.length = this.cursor.x;
      }
    } else if (mode === 1) {
      const tail = line.cells.slice(this.cursor.x + 1);
      line.cells = tail;
    } else {
      line.cells = [];
    }
    this.touch(ay);
  }

  textOf(line: TermLine): string {
    let s = '';
    for (let i = 0; i < line.cells.length; i++) {
      s += line.cells[i].char;
    }
    return s;
  }
}

/** One run of equally-styled cells -> one Text node. */
export class SpanRun {
  text: string = '';
  fg: string = TERM_DEFAULT_FG;
  bg: string | null = null;
  bold: boolean = false;
}

/** Convert a line to spans (merging equal attrs); cursor cell gets a block. */
export function lineToSpans(line: TermLine, cursorAt: number, cursorVisible: boolean): SpanRun[] {
  const runs: SpanRun[] = [];
  let cur: SpanRun | null = null;
  for (let x = 0; x < line.cells.length; x++) {
    const c = line.cells[x];
    const isCursor = cursorVisible && x === cursorAt;
    const fgIdx = c.fg;
    let fg = fgIdx >= 0 && fgIdx < AnsiPalette.FG.length ? AnsiPalette.FG[fgIdx] : TERM_DEFAULT_FG;
    if (c.bold && fgIdx >= 1 && fgIdx <= 8) {
      fg = AnsiPalette.FG[fgIdx + 8];
    }
    let bg: string | null = null;
    if (c.bg === 1) {
      bg = PALETTE_BG[1];
    } else if (c.inv) {
      bg = '#3a4b63';
    }
    if (isCursor) {
      fg = TERM_DEFAULT_FG;
      bg = CURSOR_COLOR;
    }
    if (cur !== null && cur.fg === fg && cur.bg === bg && cur.bold === c.bold) {
      cur.text += c.char;
    } else {
      cur = new SpanRun();
      cur.text = c.char;
      cur.fg = fg;
      cur.bg = bg;
      cur.bold = c.bold;
      runs.push(cur);
    }
  }
  return runs;
}
