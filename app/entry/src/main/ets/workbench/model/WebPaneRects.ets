/**
 * Web 终端层窗格矩形注册表(GUI-R4 生产级修复)。
 *
 * 根因:PaneGrid 的 rev 整树重建(M1c 冻结热修)在分屏/换布局时销毁重建
 * TermWebView → web 页重载 → ttyd 换新 shell → 原终端内容全部丢失
 * (用户实锤「新建分屏把第一屏内容刷掉」)。
 * 方案:Web 视图与布局树解耦——AppShell 常驻 WebPaneLayer(按本注册表
 * 矩形绝对定位),布局树随便重建只更新矩形;pane 关闭才真正卸载。
 * 顺带收益:切工作区/页签只置 Hidden,终端内容跨页存活。
 * 同 PaneDropTargets 模式:globalPosition 即窗口坐标;onRevTap 驱动层重渲。
 */

export class WebPaneRect {
  paneId: string = ''
  x: number = 0
  y: number = 0
  w: number = 0
  h: number = 0
  /** false=占位隐藏(非本页/等待窗口/探测未过)——组件保留,内容存活。 */
  show: boolean = false
}

export class WebPaneRects {
  private static panes: Map<string, WebPaneRect> = new Map()
  /** 版本号(每次增删改 +1;WebPaneLayer 重渲依赖锚)。 */
  static rev: number = 0
  /** 层重渲回调(WebPaneLayer 注册;null 清除)。 */
  static onRevTap: (() => void) | null = null

  private static bump(): void {
    WebPaneRects.rev += 1
    const tap = WebPaneRects.onRevTap
    if (tap !== null) {
      tap()
    }
  }

  static update(paneId: string, x: number, y: number, w: number, h: number, show: boolean): void {
    let e = WebPaneRects.panes.get(paneId)
    if (e === undefined) {
      e = new WebPaneRect()
      e.paneId = paneId
      WebPaneRects.panes.set(paneId, e)
    }
    e.x = x
    e.y = y
    e.w = w
    e.h = h
    e.show = show
    WebPaneRects.bump()
  }

  static remove(paneId: string): void {
    if (WebPaneRects.panes.delete(paneId)) {
      WebPaneRects.bump()
    }
  }

  /** 快照(层渲染只读源;变更经 rev 驱动重取)。 */
  static snapshot(): WebPaneRect[] {
    const out: WebPaneRect[] = []
    WebPaneRects.panes.forEach((v: WebPaneRect) => {
      out.push(v)
    })
    return out
  }

  /** web 主文档不可达回调注册(probe invalidate 由 PaneSurface 处理)。 */
  private static unreachHandlers: Map<string, () => void> = new Map()

  static setUnreach(paneId: string, fn: (() => void) | null): void {
    if (fn === null) {
      WebPaneRects.unreachHandlers.delete(paneId)
    } else {
      WebPaneRects.unreachHandlers.set(paneId, fn)
    }
  }

  static fireUnreach(paneId: string): void {
    const fn = WebPaneRects.unreachHandlers.get(paneId)
    if (fn !== undefined) {
      fn()
    }
  }

  /** 单测复位。 */
  static reset(): void {
    WebPaneRects.panes = new Map()
    WebPaneRects.unreachHandlers = new Map()
    WebPaneRects.onRevTap = null
  }
}
