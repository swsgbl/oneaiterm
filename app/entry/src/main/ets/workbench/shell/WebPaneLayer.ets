/**
 * Web 终端常驻层(GUI-R4 生产级修复的核心装载)。
 * AppShell 根 Stack 最底层渲染:ForEach(WebPaneRects.snapshot(), key=paneId)
 * ——布局树(上层 PaneGrid)任何重建/分屏/换页都只改矩形,本层组件实例
 * 按键稳定复用 → web 会话与内容永不因布局操作重载。pane 关闭才卸载。
 *
 * R4f 键盘终修:**本层绝不参与焦点**——Web 组件不 focusable、不请求焦点、
 * 不 defaultFocus(R4c 的 requestFocus 机器与 R4e 透明输入框互相抢焦点,
 * 焦点每次 rev 刷新都被抢回给无法处理按键的 Web,透明输入框永失键盘,
 * 用户实锤「依然输入不了字」的根因)。键盘唯一持有者=PaneSurface 占位
 * 内的透明 TextInput(onKeyEvent 直转);本层纯渲染。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { TermWebView } from '../term/TermWebView';
import { WebPaneRects, WebPaneRect } from '../model/WebPaneRects';

@Component
export struct WebPaneLayer {
  @ObjectLink vm: WorkbenchVm
  @State rev: number = 0

  aboutToAppear(): void {
    WebPaneRects.onRevTap = (): void => {
      this.rev += 1
      // R4f:焦点请求全部废弃(consumePendingFocus 仅清空防悬挂)
      WebPaneRects.consumePendingFocus()
    }
  }

  aboutToDisappear(): void {
    if (WebPaneRects.onRevTap !== null) {
      WebPaneRects.onRevTap = null
    }
  }

  build() {
    // 表达式读 this.rev 建立追踪(snapshot 为纯读)
    if (this.rev >= 0) {
      Stack() {
        ForEach(WebPaneRects.snapshot(), (r: WebPaneRect) => {
          TermWebView({
            paneId: r.paneId,
            onUnreachable: (): void => {
              WebPaneRects.fireUnreach(r.paneId)
            },
            onDone: (): void => {
              this.vm.cmdDone(r.paneId)
            },
            onShortcut: (act: string): void => {
              this.vm.handleShortcut(r.paneId, act)
            }
          })
            .position({ x: r.x, y: r.y })
            .width(r.w)
            .height(r.h)
            .borderRadius(8)
            .clip(true)
            .visibility(r.show ? Visibility.Visible : Visibility.Hidden)
        }, (r: WebPaneRect) => r.paneId)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
