/**
 * tty7 远程命令收集引擎(任务 tty7-M7a,非 UI)。
 *
 * 机制:经 RemoteTermHost.write 发 `cmd + '; echo __MARK__<rc>'`,在
 * RemoteTermHost.tapData 旁路流上做行缓冲标记检测——见到 __MARK__<rc>
 * 行即完成,out = 标记前的真实输出行,ok = rc === '0'。
 *
 * 回显处理(sh 实勘语义):
 *  - 终端会把输入的命令行本身回显出来,回显行含提示符('$ '/'# ')或
 *    直接是命令文本;发送前把命令行(去 \n 尾)记下来,流中与命令行
 *    相等或以其开头的行整行丢弃(不含标记时不会与真实输出撞行);
 *  - 命令内含 echo 自身的回显(`$ ...; echo __MARK__$?`)以提示符
 *    ('$ '/'# ')开头的行整行丢弃;
 *  - __MARK__ 行(无前缀)是结束信号本身,不进输出。
 *
 * 单飞(busy 守卫):同一时刻只允许一个 run——busy 时 run 返回 false
 * (UI 侧等待/禁用),GitService 三命令经此天然串行。
 * 纯净红线:不碰 TermModel 渲染(输出同时照常进终端 pane,语义=用户
 * 在终端里敲了这条命令);不碰 provider 凭据链;不 import UI 组件。
 */
import { RemoteTermHost } from '../remote/RemoteTermHost';

/** 结束标记(避开常见输出词;单飞下同标记不会与用户命令互串)。 */
const MARK = '__MARK__'

/**
 * 行缓冲状态机(纯数据+纯转移,抽离便于单测:半行碎片合并/回显剔除/
 * 标记检测/终止输出)。reset() 复位后可复用。
 */
export class RunnerBuffer {
  private buf: string = ''
  private lines: string[] = []
  private echo1: string = '' // 回显行 1:命令行本身(不含尾 \n)
  private echo2: string = '' // 回显行 2:提示符 + 命令行(sh 回显形态)
  private rc: number = -1 // -1 = 未收标记
  out: string = ''
  code: string = ''

  /** 装载命令行(发送前调):计算两条待剔除回显。 */
  prepare(cmdLine: string): void {
    const c = cmdLine.replace('\n', '')
    this.echo1 = c
    this.echo2 = '$ ' + c
  }

  /**
   * 喂一个数据碎片(可含 \r\n/半行)。返回 true = 已收标记终止。
   * 纯转移:只改 this 与产出 out/code,无 IO。
   */
  feed(chunk: string): boolean {
    if (this.rc >= 0) {
      return true // 已终止:后续碎片忽略
    }
    this.buf += chunk
    let ni = this.buf.indexOf('\n')
    while (ni >= 0) {
      const raw = this.buf.substring(0, ni)
      this.buf = this.buf.substring(ni + 1)
      this.takeLine(raw.replace('\r', ''))
      if (this.rc >= 0) {
        this.buf = ''
        return true
      }
      ni = this.buf.indexOf('\n')
    }
    return false
  }

  /** 单行处理:标记检测 → 回显剔除 → 收集。 */
  private takeLine(line: string): void {
    if (line.length === 0) {
      return // 空行不收集
    }
    if (line.indexOf(MARK) === 0) {
      this.code = line.substring(MARK.length).trim()
      const n = Number(this.code)
      if (!Number.isNaN(n)) {
        this.rc = n
      } else {
        this.rc = -2 // 形如标记但无码:当 0 处理(保守成功)
        this.code = '0'
      }
      this.out = this.lines.join('\n').trim()
      return
    }
    if (line === this.echo1 || (this.echo2 !== '' && line === this.echo2)) {
      return // 命令行回显(裸/带提示符两种形态)
    }
    // 热修:提示符行判定收紧为 '$ '/'# '(提示符+空格)——git porcelain 的
    // '## branch' 行首字符也是 #,原宽判定误杀真输出(M7a 单测实证)。
    if ((line.length >= 2 && line.substring(0, 2) === '$ ')
      || (line.length >= 2 && line.substring(0, 2) === '# ')) {
      return // 提示符开头的 shell 回显行(如 $ ...; echo MARK$?)
    }
    this.lines.push(line)
  }

  /** 终止码(-1 未终止;-2 形如标记无码按 0)。 */
  rcOf(): number {
    return this.rc
  }

  /** 复位(下轮 run 前)。 */
  reset(): void {
    this.buf = ''
    this.lines = []
    this.echo1 = ''
    this.echo2 = ''
    this.rc = -1
    this.out = ''
    this.code = ''
  }
}

/** 远程命令执行器(静态单飞)。 */
export class RemoteCommandRunner {
  private static busy: boolean = false

  /**
   * 执行命令:RemoteTermHost 句柄在线(有 SSH 会话)才受理;发送
   * `cmd + '; echo __MARK__$?'`(尾 \n),tapData 流上行缓冲检测标记。
   * - onDone(out, ok):标记行收到(out=收集行,ok=rc==='0')或超时
   *   (out='', ok=false);回调恰好一次
   * - 返回 false:busy(并发 run)或无远程会话(不启动)
   * 超时兜底:到点未收标记 → 取消订阅 + 单次 onDone('', false)。
   */
  static run(cmd: string, timeoutMs: number, onDone: (out: string, ok: boolean) => void): boolean {
    if (RemoteCommandRunner.busy) {
      return false
    }
    if (RemoteTermHost.term() === null || RemoteTermHost.bound() === '') {
      return false // 无远程会话(未 start/已 stop):不受理
    }
    RemoteCommandRunner.busy = true
    let fired = false
    const fin = (out: string, ok: boolean): void => {
      if (fired) {
        return
      }
      fired = true
      RemoteTermHost.tapData(null) // 摘除旁路
      RemoteCommandRunner.busy = false
      try {
        onDone(out, ok)
      } catch (e) {
        // 回调不得反向杀状态
      }
    }
    const buf = new RunnerBuffer()
    const line = cmd + '; echo ' + MARK + '$?'
    buf.prepare(line)
    RemoteTermHost.tapData((t: string): void => {
      if (buf.feed(t)) {
        const rc = buf.rcOf()
        fin(rc === 0 ? buf.out : '', rc === 0)
      }
    })
    setTimeout((): void => {
      fin('', false) // 超时兜底(fired 防双发)
    }, timeoutMs)
    RemoteTermHost.write(line + '\n')
    return true
  }
}
