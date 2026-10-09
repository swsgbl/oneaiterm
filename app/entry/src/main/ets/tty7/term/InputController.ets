/**
 * tty7 终端输入控制器(任务 tty7-M4a,纯逻辑无 UI,全同步纯计算无 await)。
 *
 * 职责:插在 TermPaneView 捕获层与 TermHost.write 之间,把 M3a 的裸差分
 * 直写升级为编辑器级输入:ghost 建议(历史前缀 > 内建命令表)、Tab 补全
 * (单候选补全/多候选循环/无候选发 '\t' 给 sh)、↑↓ 历史回溯。
 *
 * 行重写原语:换整行 = writeText '\x15'+newText(Ctrl-U 清行 + 新文本,
 * sh 行规范支持,回显由 PTY echo 自动出)+ setField=true fieldText=newText
 * (捕获层字段与终端行重新对齐——差分基线 sent 同步设为 newText,随后
 * 框架若补发 onChange(newText) 因 fieldText===sent 幂等无操作)。
 *
 * 基线语义:sent = 已直写 PTY 的当前行内容(与捕获层字段值同步维护);
 * onInput 差分同 M3a 三修(前缀增长直写差量/缩短回写 \x7f/非前缀变化
 * 整行重写 \x15+v);onEnter 后 sent 清零,submit 引发的框架静默清字段
 * onChange('') 恒无操作(M3a"非前缀变化重发"坑的根治)。
 *
 * ghost 优先级:历史前缀匹配(第一条匹配去前缀) > 内建命令表前缀 > ''。
 * 建议必须严格长于当前输入(去前缀后非空)。
 */
import { InputHistory } from './InputHistory';

/** 内建命令表(01 文档 M4;ghost/Tab 的静态候选源)。 */
const BUILTIN_CMDS: string[] = [
  'ls', 'cd', 'cat', 'echo', 'grep', 'pwd', 'mkdir', 'rm', 'cp', 'mv',
  'touch', 'head', 'tail', 'wc', 'find', 'chmod', 'chown', 'ps', 'top', 'kill',
  'ping', 'ssh', 'scp', 'tar', 'unzip', 'vi', 'sed', 'awk', 'which', 'env',
  'export', 'date', 'whoami', 'uname', 'df', 'du', 'free', 'ifconfig', 'netstat',
  'curl', 'wget', 'git', 'node', 'python', 'busybox', 'hdc', 'hmh'
];

/** 控制器动作指令:捕获层按 writeText → setField → ghost 顺序执行。 */
export class InputAction {
  /** 直写 PTY 的文本('' = 不写)。 */
  writeText: string = ''
  /** 捕获层字段应设为的整行(仅 setField=true 时生效)。 */
  fieldText: string = ''
  /** fieldText 是否生效(整行重写时 true)。 */
  setField: boolean = false
  /** ghost 显示后缀('' 清除)。 */
  ghost: string = ''
}

export class InputController {
  /** 已直写 PTY 的当前行(差分基线,与捕获层字段值同步)。 */
  private sent: string = ''
  private ghostSuf: string = ''
  /** 历史回溯游标:recent() 下标,-1 = 非回溯态。 */
  private histIdx: number = -1
  /** Tab 循环候选(基于 tabBase 计算;编辑后失效重算)。 */
  private tabCands: string[] = []
  private tabIdx: number = -1

  /** onChange 入口:差分直写/整行重写 + ghost 重算;返回动作指令。 */
  onInput(fieldText: string): InputAction {
    const a = new InputAction()
    if (fieldText === this.sent) {
      a.ghost = this.ghostSuf // 程序化设置后的重复 onChange:幂等无操作
      return a
    }
    const last = this.sent;
    if (fieldText.length > last.length && fieldText.startsWith(last)) {
      a.writeText = fieldText.substring(last.length)
    } else if (fieldText.length < last.length && last.startsWith(fieldText)) {
      const n = last.length - fieldText.length
      let bs = ''
      for (let i = 0; i < n; i++) {
        bs += '\x7f'
      }
      a.writeText = bs
    } else {
      // 非前缀变化:整行重写(空串即清行)
      a.writeText = '\x15' + fieldText
    }
    this.sent = fieldText
    this.histIdx = -1 // 手动编辑退出回溯态
    this.tabIdx = -1 // 编辑后 Tab 候选失效
    this.ghostSuf = this.calcGhost(fieldText)
    a.ghost = this.ghostSuf
    return a
  }

  /** Tab:单候选补全;多候选循环(上次产物未被编辑时继续循环,否则重算);
   *  无候选发 '\t' 给 sh(交给 shell 原生补全)。 */
  onTab(): InputAction {
    const a = new InputAction()
    const cur = this.sent
    if (cur.length === 0) {
      a.writeText = '\t'
      return a
    }
    const cycling = this.tabIdx >= 0 && this.tabCands.length > 0 && this.sent === this.tabCands[this.tabIdx]
    if (!cycling) {
      this.tabCands = this.tabCandidates(cur)
      this.tabIdx = -1
    }
    if (this.tabCands.length === 0) {
      a.writeText = '\t'
      a.ghost = this.ghostSuf
      return a
    }
    this.tabIdx = (this.tabIdx + 1) % this.tabCands.length
    const pick = this.tabCands[this.tabIdx]
    a.writeText = '\x15' + pick
    a.fieldText = pick
    a.setField = true
    a.ghost = ''
    this.sent = pick
    this.ghostSuf = ''
    return a
  }

  /** ↑↓ 历史回溯:游标从末尾上移/下移,行重写;↓ 超出最新 → 回空串+清游标。 */
  onArrow(up: boolean): InputAction {
    const a = new InputAction()
    const rec = InputHistory.recent()
    if (rec.length === 0) {
      return a
    }
    let ni: number
    if (up) {
      ni = this.histIdx < 0 ? 0 : Math.min(this.histIdx + 1, rec.length - 1)
    } else {
      ni = this.histIdx - 1
    }
    this.histIdx = ni
    this.ghostSuf = ''
    a.ghost = ''
    if (ni < 0) {
      // ↓ 超出最新:回空串 + 清游标(回溯结束回当前编辑行)
      a.writeText = '\x15'
      a.fieldText = ''
      a.setField = true
      this.sent = ''
      return a
    }
    const pick = rec[ni]
    a.writeText = '\x15' + pick
    a.fieldText = pick
    a.setField = true
    this.sent = pick
    return a
  }

  /** 回车:发 '\r' + 历史入档 + 行状态复位(submit 后框架清字段的
   *  onChange('') 因 sent 已清零恒无操作)。 */
  onEnter(): InputAction {
    const a = new InputAction()
    a.writeText = '\r'
    InputHistory.push(this.sent)
    this.reset()
    return a
  }

  /** 当前建议后缀(不含已输入前缀;'' = 无)。 */
  ghost(): string {
    return this.ghostSuf
  }

  /** 当前行文本(ghost 渲染的前缀部分;与捕获层字段同步)。 */
  line(): string {
    return this.sent
  }

  /** 行状态复位(会话停止/开始;历史不受影响)。 */
  reset(): void {
    this.sent = ''
    this.ghostSuf = ''
    this.histIdx = -1
    this.tabCands = []
    this.tabIdx = -1
  }

  /** ghost 优先级:历史前缀(第一条匹配去前缀) > 内建命令表 > ''。 */
  private calcGhost(cur: string): string {
    if (cur.length === 0) {
      return ''
    }
    const h = InputHistory.matchPrefix(cur)
    if (h.length > 0 && h[0].length > cur.length) {
      return h[0].substring(cur.length)
    }
    for (let i = 0; i < BUILTIN_CMDS.length; i++) {
      const cmd = BUILTIN_CMDS[i]
      if (cmd.startsWith(cur) && cmd.length > cur.length) {
        return cmd.substring(cur.length)
      }
    }
    return ''
  }

  /** Tab 候选:历史前缀匹配(最新在前) + 内建表前缀匹配,去重,均严格长于前缀。 */
  private tabCandidates(cur: string): string[] {
    const out: string[] = []
    const hist = InputHistory.matchPrefix(cur)
    for (let i = 0; i < hist.length; i++) {
      const h = hist[i]
      if (h.length > cur.length && out.indexOf(h) < 0) {
        out.push(h)
      }
    }
    for (let i = 0; i < BUILTIN_CMDS.length; i++) {
      const cmd = BUILTIN_CMDS[i]
      if (cmd.startsWith(cur) && cmd.length > cur.length && out.indexOf(cmd) < 0) {
        out.push(cmd)
      }
    }
    return out
  }
}
