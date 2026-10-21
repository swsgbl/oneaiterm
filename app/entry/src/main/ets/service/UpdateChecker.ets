/**
 * 检查更新(GUI-R3,用户指令「检查更新/默认更新」)。
 * 数据源:仓库 app/AppScope/app.json5 的 versionName(raw 文本,多源
 * 依次尝试:atomgit 主源→github 镜像);解析/比较为纯函数(单测靶)。
 * 红线:密钥/隐私不外传——仅 GET 仓库公开文件;失败返回 err 不抛。
 */
import http from '@ohos.net.http';

/** 仓库双源(用户指令:国内优先 AtomGit,国际优先 GitHub;按界面语言分流)。 */
const REPO_ATOMGIT: string = 'https://atomgit.com/hongfu/oneAIterm'
const REPO_GITHUB: string = 'https://github.com/swsgbl/oneaiterm'

/** 仓库首页(纯;zh-CN→AtomGit,其它→GitHub)。 */
export function repoHome(locale: string): string {
  return locale === 'zh-CN' ? REPO_ATOMGIT : REPO_GITHUB
}

/** Issues 页(纯)。 */
export function repoIssues(locale: string): string {
  return repoHome(locale) + '/issues'
}

/** 发布页(纯)。 */
export function repoReleases(locale: string): string {
  return repoHome(locale) + '/releases'
}

/** 更新数据源(raw app.json5;zh 优先 AtomGit,国际优先 GitHub)。 */
function rawUrls(locale: string): string[] {
  const a = REPO_ATOMGIT + '/raw/main/app/AppScope/app.json5'
  const g = 'https://raw.githubusercontent.com/swsgbl/oneaiterm/main/app/AppScope/app.json5'
  return locale === 'zh-CN' ? [a, g] : [g, a]
}

/** 从 app.json5 文本抽取 versionName(纯;失败 '')。 */
export function extractVersionName(text: string): string {
  const m = /"versionName"\s*:\s*"([0-9][0-9A-Za-z.\-]*)"/.exec(text)
  return m === null ? '' : m[1]
}

/** 版本比较(纯,x.y.z 数值逐段;remote>cur=true;解析失败=false)。 */
export function isNewer(cur: string, remote: string): boolean {
  if (remote === '' || cur === '') {
    return false
  }
  const a = cur.split('.')
  const b = remote.split('.')
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) {
    const x = i < a.length ? Number(a[i]) : 0
    const y = i < b.length ? Number(b[i]) : 0
    if (Number.isNaN(x) || Number.isNaN(y)) {
      return false
    }
    if (y > x) {
      return true
    }
    if (y < x) {
      return false
    }
  }
  return false
}

export class UpdateResult {
  ok: boolean = false
  latest: string = ''
  err: string = ''
}

export class UpdateChecker {
  /** 依次尝试数据源(按语言排序);任一成功即返回(8s 超时/源)。 */
  static async check(locale: string): Promise<UpdateResult> {
    const r = new UpdateResult()
    for (const url of rawUrls(locale)) {
      try {
        const req = http.createHttp()
        const resp = await req.request(url, {
          connectTimeout: 8000,
          readTimeout: 8000,
          method: http.RequestMethod.GET,
          header: { 'Content-Type': 'application/json' } as Record<string, string>
        })
        const body = typeof resp.result === 'string' ? resp.result : ''
        req.destroy()
        const ver = extractVersionName(body)
        if (ver !== '') {
          r.ok = true
          r.latest = ver
          r.err = ''
          return r
        }
      } catch (e) {
        // 换下一源
      }
    }
    r.ok = false
    r.latest = ''
    r.err = 'network'
    return r
  }
}
