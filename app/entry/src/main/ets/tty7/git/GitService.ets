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
