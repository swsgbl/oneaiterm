/**
 * tty7 M3c:scrollback 渲染 + 终端搜索纯函数(无 UI import,单测友好)。
 *
 * 设计要点:
 *  - tailLines:渲染源从 winRows 窗口改为 lines 尾部最多 max 行(2000);
 *    TermModel 的 MAX_SCROLLBACK=5000 硬上限已兜底,此处再截一次是渲染
 *    侧性能护栏(ForEach 挂载量)。
 *  - searchHits:在文本数组里大小写不敏感找关键字,返回命中下标数组
 *    (升序);空关键字返回空(不开搜)。
 *  - nextHit:命中间跳转的环绕步进(0..n-1 循环,右侧越界回 0);
 *    prev = nextHit(idx, n, -1)。
 *  - shouldStick:贴底语义——用户上滚(非贴底)时新输出不打断;
 *    initial 首帧强制贴底。
 */
export const SCROLLBACK_MAX: number = 2000

/** 行文本(尾截后)尾部最多 max 行;max<=0 返回空数组(守卫)。 */
export function tailLines(texts: string[], max: number): string[] {
  if (max <= 0 || texts.length === 0) {
    return []
  }
  if (texts.length <= max) {
    return texts.slice()
  }
  return texts.slice(texts.length - max)
}

/** keyword 在 texts 中的命中下标(升序,大小写不敏感);空关键字→[]。 */
export function searchHits(texts: string[], keyword: string): number[] {
  const out: number[] = []
  const kw = keyword.trim().toLowerCase()
  if (kw.length === 0) {
    return out
  }
  for (let i = 0; i < texts.length; i++) {
    if (texts[i].toLowerCase().indexOf(kw) >= 0) {
      out.push(i)
    }
  }
  return out
}

/** 命中列表环绕步进:idx+step 在 [0,n) 循环;n<=0 返回 0(守卫)。 */
export function nextHit(idx: number, n: number, step: number): number {
  if (n <= 0) {
    return 0
  }
  const r = (idx + step) % n
  return r < 0 ? r + n : r
}

/**
 * 新输出到达时是否贴底:非用户上滚态才贴(上滚看历史不打断)。
 * initial=true 首帧无条件贴底(否则初始 yOffset=0 被判非贴底,首屏空)。
 */
export function shouldStick(isAtBottom: boolean, initial: boolean): boolean {
  return initial || isAtBottom
}
