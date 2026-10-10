/**
 * tty7 RightPanel 上下文抽屉纯逻辑(任务 tty7-M6b,非 UI)。
 *
 * 三个职责,全纯函数(单测共靶,无网/无会话环境可测):
 *  1. drawerTabOf:页签归一(白名单 agent/sftp,非法值回 agent——UI 状态
 *     切换守卫;Agent 页事件列表是组件 @State,tab 切换只换分支不改数组,
 *     事件不丢由 RightPanel 的 if/else 分支保证,这里保证 tab 值域);
 *  2. joinDir/parentDir:SFTP 远程路径拼接(POSIX 语义;'.' 起点与根边界,
 *     照抄 pages/SftpPanel.joinPath/parentPath 同规则——不碰原文件);
 *  3. sortEntries:目录在前文件在后 + 名称序 stable 排序(照抄 SftpPanel
 *     列表排序;Array.sort 在 ArkTS 为 stable,等值不换位)。
 *
 * 红线:零 service import;零凭据;路径运算不含连接语义(不重连)。
 */

/** SFTP 列表条目(展示字段;来源 sftpList JSON 的 files 元素)。 */
export class DrawerEntry {
  name: string = ''
  isDir: boolean = false
}

/** 页签归一:'agent'/'sftp'/'git' 白名单,其余(含 '')回 'agent'。 */
export function drawerTabOf(next: string): string {
  if (next === 'sftp') {
    return 'sftp'
  }
  if (next === 'git') { // +tty7-M7a: Git 页签
    return 'git'
  }
  return 'agent'
}

/** 目录拼接:base 为 '.'/空 → name;尾斜杠直接接;否则补 '/'。 */
export function joinDir(base: string, name: string): string {
  if (base === '.' || base.length === 0) {
    return name
  }
  if (base.charAt(base.length - 1) === '/') {
    return base + name
  }
  return base + '/' + name
}

/** 父目录:'.'/'/'/空原样;无斜杠回 '.';根下回 '/';否则砍最后一段。 */
export function parentDir(p: string): string {
  if (p === '.' || p === '/' || p.length === 0) {
    return p
  }
  const i = p.lastIndexOf('/')
  if (i < 0) {
    return '.'
  }
  if (i === 0) {
    return '/'
  }
  return p.substring(0, i)
}

/** 目录在前 + 名称升序 stable(新数组,不动入参)。 */
export function sortEntries(src: DrawerEntry[]): DrawerEntry[] {
  const out = src.slice()
  out.sort((a: DrawerEntry, b: DrawerEntry): number => {
    if (a.isDir !== b.isDir) {
      return a.isDir ? -1 : 1
    }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })
  return out
}
