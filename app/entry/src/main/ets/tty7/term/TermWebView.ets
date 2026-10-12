/**
 * tty7-RD-POC: Web 组件加载系统 ttyd(xterm.js 页面)的最小 PoC 组件。
 * 依据 docs/ADR-0002-system-terminal.md——渲染/输入/PTY 全归系统栈:
 *   - Web 组件(ArkWeb)加载 http://127.0.0.1:27681/(ttyd 自带 xterm.js);
 *   - javaScriptOnDocumentStart 注入暗色适配(body/xterm 黑底+贴边);
 *   - onControllerAttached/onPageEnd/onErrorReceive 打 hilog(tag RDPOC,
 *     域 0xFF00)留页面加载状态证据;
 *   - PoC 不做注入桥/不做 resize 转发——winsize 由 xterm 自动适配。
 * PTY 仍由 TermHost 并行起着(PaneSurface 本地分支渲染期临时替换,
 * RD_POC 常量开关,指挥官验收后决定去留)。
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RDPOC_TAG: string = 'RDPOC'
const RDPOC_DOMAIN: number = 0xFF00
/** ttyd 服务地址(VM 启动项,root,-W 可写;ADR-0002)。 */
const TTYD_URL: string = 'http://127.0.0.1:27681/'

/**
 * 暗色适配脚本(document start 注入;ttyd 页本身黑底,这里只做贴边+
 * 强制黑底兜底——页面默认 15px padding 在小 pane 里浪费空间)。
 * 用数组 join 拼(ArkTS 模板字符串规避),纯 JS 无依赖。
 */
function darkInjectJs(): string {
  const lines: string[] = [
    '(function(){',
    'try{',
    'var st=document.createElement("style");',
    'var css="html,body{background:#000!important;margin:0!important;padding:0!important;overflow:hidden}";',
    'css+=".terminal{padding:2px!important;background:#000!important}";',
    'st.textContent=css;',
    '(document.head||document.documentElement).appendChild(st);',
    '}catch(e){}',
    '})()'
  ]
  return lines.join('\n')
}

@Component
export struct TermWebView {
  paneId: string = ''
  /** ArkWeb 控制器(PoC 仅持有;不做 loadUrl/refresh 驱动)。 */
  controller: webview.WebviewController = new webview.WebviewController()
  /** 页面加载状态(loading/loaded/error——PoC 证据 + 兜底提示渲染)。 */
  @State pageState: string = 'loading'
  @State pageErr: string = ''

  build() {
    Stack() {
      Web({ src: TTYD_URL, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptOnDocumentStart([{ script: darkInjectJs(), scriptRules: ['*'] }])
        .onControllerAttached(() => {
          hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'controllerAttached pane=%{public}s', this.paneId)
        })
        .onPageEnd((e: OnPageEndEvent) => {
          this.pageState = 'loaded'
          hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'pageEnd pane=%{public}s url=%{public}s',
            this.paneId, e.url)
        })
        .onErrorReceive((e: OnErrorReceiveEvent) => {
          // 主文档加载失败才置 error;子资源失败只留日志(页面仍可能可用)
          let info: string = ''
          try {
            info = e.error.getErrorInfo()
          } catch (err) {
            info = 'n/a'
          }
          hilog.error(RDPOC_DOMAIN, RDPOC_TAG, 'errorReceive pane=%{public}s url=%{public}s err=%{public}s',
            this.paneId, e.request.getRequestUrl(), info)
          try {
            if (e.request.isMainFrame()) {
              this.pageState = 'error'
              this.pageErr = info
            }
          } catch (err) {
            // isMainFrame 不可用:保持 loaded 判定(仅记日志)
          }
        })
      // 加载失败兜底提示(不遮挡正常渲染;loaded 后不显示)
      if (this.pageState === 'error') {
        Column({ space: 6 }) {
          Text('ttyd 不可达')
            .fontSize(14)
            .fontColor('#f85149')
          Text(TTYD_URL)
            .fontSize(11)
            .fontColor('#7d8590')
          Text(this.pageErr.length > 0 ? this.pageErr : '检查 ttyd 服务(27681 端口)')
            .fontSize(11)
            .fontColor('#7d8590')
            .maxLines(2)
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
