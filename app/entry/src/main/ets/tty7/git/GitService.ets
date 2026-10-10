/**
 * tty7 远程 git 引擎(任务 tty7-M7a,只读态:status/log/diffStat)。
 *
 * 决策(01 文档 M7):复用远程系统 git,经 SSH 会话发命令 + 标记法收集
 * (RemoteCommandRunner),解析成结构化状态;不引入 libgit2,不重造 git。
 * 写操作(stage/commit)留 M7b——本文件命令集只读。
 *
 * 纯函数抽取(porcelainLine/branchLine/logLine/quoteCwd)便于单测;
 * 串行:经 RemoteCommandRunner 单飞特性天然串行(三命令不并发)。
 * 红线:cwd 只来自 SFTP 浏览路径;输出不涉凭据(runner 通道不回显密码);
 * 路径含引号直接拒绝(不构造命令,防注入)。
 */
import { RemoteCommandRunner } from './RemoteCommandRunner';

/** 分支信息(status -b 头行派生;detached 时 branch='HEAD')。 */
export class GitBranchInfo {
  branch: string = ''
  ahead: number = 0
  behind: number = 0
}

/** 文件条目(XY 状态码 + 路径;XY 语义:X=staged,Y=worktree)。 */
export class GitFileEntry {
  path: string = ''
  xy: string = ''
}

/** 提交条目(log --pretty 派生)。 */
export class GitCommit {
  hash: string = ''
  subject: string = ''
  author: string = ''
  date: string = ''
}

/**
 * porcelain 行解析:'XY path' → GitFileEntry;非法(长度不足/空)→ null。
 * 形态:'M '/' M'/'??'/'A '/' D'/'MM'(rename 'R  old -> new'
 * 不在只读态范围,按 path 原样收集)。
 */
export function porcelainLine(line: string): GitFileEntry | null {
  if (line.length < 4) {
    return null
  }
  const e = new GitFileEntry()
  e.xy = line.substring(0, 2)
  e.path = line.substring(3)
  return e
}

/**
 * porcelain -b 头行解析:'## main...origin/main [ahead 2, behind 1]' →
 * branch/ahead/behind;detached('## HEAD (no branch)')→ branch='HEAD';
 * 无上游('## master')→ ahead/behind 0。非法 → null。
 */
export function branchLine(line: string): GitBranchInfo | null {
  if (line.indexOf('## ') !== 0) {
    return null
  }
  const b = new GitBranchInfo()
  let body = line.substring(3)
  // 截掉尾注([ahead 2, behind 1] / [gone] 等),再剥 '...origin/xxx'
  const lb = body.indexOf(' [')
  if (lb >= 0) {
    const note = body.substring(lb)
    const mA = note.indexOf('ahead ')
    if (mA >= 0) {
      b.ahead = numAfter(note, mA + 6)
    }
    const mB = note.indexOf('behind ')
    if (mB >= 0) {
      b.behind = numAfter(note, mB + 7)
    }
    body = body.substring(0, lb)
  }
  const dots = body.indexOf('...')
  if (dots >= 0) {
    body = body.substring(0, dots)
  }
  body = body.trim()
  // detached 形态:'HEAD (no branch)' → 剥后缀只留 'HEAD'
  const nb = body.indexOf(' (no branch)')
  if (nb >= 0) {
    body = body.substring(0, nb)
  }
  b.branch = body
  return b
}

/**
 * log 行解析:'%h|%s|%an|%ad'(ad=--date=short 即 YYYY-MM-DD)。
 * subject 含 '|' 容错:仅按前 1(hash)+后 2(author/date)分界,中段
 * 全归 subject(split 限 3 次后取 [1])。
 */
export function logLine(line: string): GitCommit | null {
  const parts = line.split('|')
  if (parts.length < 4) {
    return null
  }
  const c = new GitCommit()
  c.hash = parts[0]
  c.author = parts[parts.length - 2]
  c.date = parts[parts.length - 1]
  c.subject = parts.slice(1, parts.length - 2).join('|')
  return c
}

/**
 * cwd 注入转义:路径含单/双引号或反斜杠转义风险 → null(拒绝);
 * 含空格 → 双引号包裹;其余原样。纯函数(单测共靶)。
 */
export function quoteCwd(cwd: string): string | null {
  if (cwd.length === 0) {
    return null
  }
  if (cwd.indexOf('"') >= 0 || cwd.indexOf('\'') >= 0 || cwd.indexOf('\\') >= 0) {
    return null
  }
  if (cwd.indexOf(' ') >= 0) {
    return '"' + cwd + '"'
  }
  return cwd
}

/**
 * git 路径参数转义(M7b,纯函数,单测共靶):单引号包裹语义——
 * 含单引号/反斜杠 → null(拒绝,防闭合逃逸);含空格或任何 shell
 * 元字符($ ~ * ? [ ; | & > < 等,porcelain '??' 路径含 ? 也会走到)
 * → 单引号包裹;纯常规路径原样。单引号内一切字面量,注入面关死。
 */
export function quotePath(p: string): string | null {
  if (p.length === 0) {
    return null
  }
  if (p.indexOf('\'') >= 0 || p.indexOf('\\') >= 0) {
    return null
  }
  if (p.indexOf(' ') >= 0 || p.indexOf('$') >= 0 || p.indexOf('~') >= 0
    || p.indexOf('*') >= 0 || p.indexOf('?') >= 0 || p.indexOf('[') >= 0
    || p.indexOf(';') >= 0 || p.indexOf('|') >= 0 || p.indexOf('&') >= 0
    || p.indexOf('>') >= 0 || p.indexOf('<') >= 0) {
    return '\'' + p + '\''
  }
  return p
}

/**
 * commit 消息转义(M7b,黑名单拒绝式,纯函数,单测共靶):非空(trim 后)
 * 且 ≤200 字;含 单引号/反引号/$( /分号/竖线/重定向/&/裸美元 任一 →
 * null(拒绝,UI 提示非法字符)。合法 → 单引号包裹返回(命令内字面量)。
 * 黑名单覆盖 sh 元字符;ASCII 可打印其余(含中文)均放行。
 */
export function quoteMsg(msg: string): string | null {
  const t = msg.trim()
  if (t.length === 0 || t.length > 200) {
    return null
  }
  if (t.indexOf('\'') >= 0 || t.indexOf('\u0060') >= 0 || t.indexOf('$(') >= 0
    || t.indexOf(';') >= 0 || t.indexOf('$') >= 0 || t.indexOf('|') >= 0
    || t.indexOf('>') >= 0 || t.indexOf('<') >= 0 || t.indexOf('&') >= 0) {
    return null
  }
  return '\'' + t + '\''
}

/**
 * 写命令构造(M7b,纯函数,单测共靶;非法输入 → null 不构造命令):
 *  'stage'   → git -C <cwd> add -- <path>(untracked/修改同 add)
 *  'unstage' → git -C <cwd> reset HEAD -- <path>
 *  'commit'  → git -C <cwd> commit -m '<msg>'
 * cwd 走 quoteCwd,path 走 quotePath,msg 走 quoteMsg——双闸转义。
 */
export function cmdFor(kind: string, cwd: string, p: string): string | null {
  const q = quoteCwd(cwd)
  if (q === null) {
    return null
  }
  if (kind === 'stage' || kind === 'unstage') {
    const pp = quotePath(p)
    if (pp === null) {
      return null
    }
    return 'git -C ' + q + (kind === 'stage' ? ' add -- ' : ' reset HEAD -- ') + pp
  }
  if (kind === 'commit') {
    const mm = quoteMsg(p)
    if (mm === null) {
      return null
    }
    return 'git -C ' + q + ' commit -m ' + mm
  }
  return null
}

/**
 * porcelain XY 分类(M7b,纯函数,单测共靶):首列=staged。
 * 首列非空且非 '?' → 已暂存;首列空或 '??' → 未暂存/untracked。
 */
export function isStaged(xy: string): boolean {
  if (xy.length < 2) {
    return false
  }
  const x = xy.charAt(0)
  return x !== ' ' && x !== '?'
}

/** untracked('??')判定(纯函数)。 */
export function isUntracked(xy: string): boolean {
  return xy.length >= 2 && xy.substring(0, 2) === '??'
}

/**
 * pushDry 输出摘要(M7b,纯函数,单测共靶):干跑输出 → ahead 摘要文本。
 *  - 空输出 → '无待推送内容(本地与远端一致)'
 *  - 剔除 'To <url>' 行(免暴露仓库地址),更新行(abc..def main -> main)
 *    与 rejected 行原样逐行拼
 *  - 截 300 字(溢出加 …)
 */
export function pushDryText(out: string): string {
  const lines: string[] = []
  for (const l of out.split('\n')) {
    const t = l.trim()
    if (t.length === 0) {
      continue
    }
    if (t.indexOf('To ') === 0) {
      continue
    }
    lines.push(t)
  }
  if (lines.length === 0) {
    return '无待推送内容(本地与远端一致)'
  }
  let s = lines.join('\n')
  if (s.length > 300) {
    s = s.substring(0, 300) + '…'
  }
  return s
}

/** Git 只读查询(静态;全经 RemoteCommandRunner 单飞串行)。 */
export class GitService {
  /**
   * status:分支 + 文件表。输出首行为 '## ...' 头(branchLine 解析,
   * 非 git 仓库/失败 → b=null,err 带原因首行);其余行 porcelainLine。
   */
  static status(cwd: string, cb: (b: GitBranchInfo | null, files: GitFileEntry[], err: string) => void): boolean {
    const q = quoteCwd(cwd)
    if (q === null) {
      cb(null, [], '路径含非法字符(引号)')
      return false
    }
    return RemoteCommandRunner.run('git -C ' + q + ' status --porcelain=v1 -b', 15000,
      (out: string, ok: boolean): void => {
        if (!ok) {
          cb(null, [], GitService.firstLine(out, 'status 失败(超时或非零退出)'))
          return
        }
        const lines = GitService.outLines(out)
        let b: GitBranchInfo | null = null
        const files: GitFileEntry[] = []
        for (const l of lines) {
          if (l.indexOf('## ') === 0) {
            b = branchLine(l)
          } else {
            const f = porcelainLine(l)
            if (f !== null) {
              files.push(f)
            }
          }
        }
        if (b === null) {
          // 无 '##' 头:多半 'fatal: not a git repository'
          cb(null, [], GitService.firstLine(out, '非 git 仓库'))
          return
        }
        cb(b, files, '')
      })
  }

  /** log:最近 n 条提交(hash/subject/author/date)。 */
  static log(cwd: string, n: number, cb: (list: GitCommit[], err: string) => void): boolean {
    const q = quoteCwd(cwd)
    if (q === null) {
      cb([], '路径含非法字符(引号)')
      return false
    }
    const cnt = n > 0 && n <= 100 ? n : 10
    return RemoteCommandRunner.run(
      'git -C ' + q + ' log -n ' + cnt.toString() + ' --pretty=%h|%s|%an|%ad --date=short', 15000,
      (out: string, ok: boolean): void => {
        if (!ok) {
          cb([], GitService.firstLine(out, 'log 失败(超时或非零退出)'))
          return
        }
        const list: GitCommit[] = []
        for (const l of GitService.outLines(out)) {
          const c = logLine(l)
          if (c !== null) {
            list.push(c)
          }
        }
        cb(list, '')
      })
  }

  /** diffStat:工作区 diff --stat 文本(原样展示;无差异 → '')。 */
  static diffStat(cwd: string, cb: (text: string, err: string) => void): boolean {
    const q = quoteCwd(cwd)
    if (q === null) {
      cb('', '路径含非法字符(引号)')
      return false
    }
    return RemoteCommandRunner.run('git -C ' + q + ' diff --stat', 15000,
      (out: string, ok: boolean): void => {
        if (!ok) {
          cb('', GitService.firstLine(out, 'diff 失败(超时或非零退出)'))
          return
        }
        cb(out.trim(), '')
      })
  }

  /**
   * stage 单文件(M7b 最小写集):git add -- <path>(untracked/工作区
   * 修改同 add)。路径走 quotePath 转义;runner 单飞串行;成功后由
   * UI 侧自动刷新 status+log。返回 false = 命令未发起(通道忙/非法路径)。
   */
  static stage(cwd: string, path: string, cb: (ok: boolean, err: string) => void): boolean {
    const c = cmdFor('stage', cwd, path)
    if (c === null) {
      cb(false, '路径含非法字符')
      return false
    }
    return RemoteCommandRunner.run(c, 15000, (out: string, ok: boolean): void => {
      cb(ok, ok ? '' : GitService.firstLine(out, 'stage 失败(超时或非零退出)'))
    })
  }

  /**
   * unstage 单文件:git reset HEAD -- <path>(仅退索引,不动工作区,
   * 非破坏性)。同 stage 协议。
   */
  static unstage(cwd: string, path: string, cb: (ok: boolean, err: string) => void): boolean {
    const c = cmdFor('unstage', cwd, path)
    if (c === null) {
      cb(false, '路径含非法字符')
      return false
    }
    return RemoteCommandRunner.run(c, 15000, (out: string, ok: boolean): void => {
      cb(ok, ok ? '' : GitService.firstLine(out, 'unstage 失败(超时或非零退出)'))
    })
  }

  /**
   * commit:git commit -m '<msg>'。消息走 quoteMsg 双闸(非法字符/
   * 超 200 字在纯函数层拒绝,不构造命令);成功后 UI 刷新 status+log。
   */
  static commit(cwd: string, msg: string, cb: (ok: boolean, err: string) => void): boolean {
    const c = cmdFor('commit', cwd, msg)
    if (c === null) {
      cb(false, '消息含非法字符或为空')
      return false
    }
    return RemoteCommandRunner.run(c, 20000, (out: string, ok: boolean): void => {
      cb(ok, ok ? '' : GitService.firstLine(out, 'commit 失败(超时或非零退出)'))
    })
  }

  /**
   * pushDry 推送预演:git push --dry-run <remote> 2>&1 收集——只展示
   * 将要推什么,**不真推**(真 push 留 M8 CLI 棒带二次确认)。
   * 输出经 pushDryText 提炼 ahead 摘要(剔 To 行)。
   */
  static pushDry(cwd: string, remote: string, cb: (ahead: string, err: string) => void): boolean {
    const q = quoteCwd(cwd)
    if (q === null) {
      cb('', '路径含非法字符(引号)')
      return false
    }
    const r = quotePath(remote)
    if (r === null) {
      cb('', '远端名含非法字符')
      return false
    }
    return RemoteCommandRunner.run('git -C ' + q + ' push --dry-run ' + r + ' 2>&1', 20000,
      (out: string, ok: boolean): void => {
        if (!ok) {
          cb('', GitService.firstLine(out, 'push 预演失败(超时或非零退出)'))
          return
        }
        cb(pushDryText(out), '')
      })
  }


  /** 输出按行切(去空行;trim 兜底)。 */
  private static outLines(out: string): string[] {
    const arr: string[] = []
    for (const l of out.split('\n')) {
      const t = l.trim()
      if (t.length > 0) {
        arr.push(t)
      }
    }
    return arr
  }

  /** 错误摘要:输出首行(截 60 字);空输出回 fallback。 */
  private static firstLine(out: string, fallback: string): string {
    for (const l of out.split('\n')) {
      const t = l.trim()
      if (t.length > 0) {
        return t.length > 60 ? t.substring(0, 60) : t
      }
    }
    return fallback
  }

}

/** 数字解析助手('[ahead 2...' 段后取正整数;失败 0;模块级纯函数)。 */
function numAfter(s: string, from: number): number {
  let i = from
  while (i < s.length && s.charAt(i) >= '0' && s.charAt(i) <= '9') {
    i++
  }
  if (i === from) {
    return 0
  }
  return Number(s.substring(from, i))
}
