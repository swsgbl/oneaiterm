/**
 * Web 终端常驻层(GUI-R4 生产级修复的核心装载)。
 * AppShell 根 Stack 最底层渲染:ForEach(WebPaneRects.snapshot(), key=paneId)
 * ——布局树(上层 PaneGrid)任何重建/分屏/换页都只改矩形,本层组件实例
 * 按键稳定复用 → web 会话与内容永不因布局操作重载。pane 关闭才卸载。
 * 点击直达本层(上层内容占位 hitTest None);show=false 仅 Hidden(跨页保活)。
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
      // R4b:键盘焦点请求消费(ArkUI 键盘事件走焦点树,Web 组件需显式
      // 拿组件级焦点——解耦后点击穿透只给页面内部焦点,组件焦点要补)
      const pf = WebPaneRects.consumePendingFocus()
      if (pf !== '' && this.vm.focusedPane === pf) {
        try {
          this.getUIContext().getFocusController().requestFocus('webpane-' + pf)
        } catch (e) {
          // 焦点请求失败不阻塞(下次 arm/焦点变化再试)
        }
      }
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
            .id('webpane-' + r.paneId)
            .focusable(true)
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
