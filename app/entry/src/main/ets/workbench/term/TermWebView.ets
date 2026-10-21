/**
 * RD: Web 组件加载系统 ttyd(xterm.js 页面;ADR-0002 运行时探测分流。
 * RD-1:运行时探测可达(PaneSurface probeTtyd/ttydOk);onErrorReceive
 * 主文档失败回调 onUnreachable,宿主 invalidate 探测缓存并降级 TermPaneView。
 *
 * RD-2(方案 B,VM 实勘定案——多客户端=独立 shell,桥不能自连 WS):
 *  全部挂钩收敛到 term 层(pageEnd 同步直装, ArkTS 侧有限重试——pageEnd
 *  可能早于前端 bundle 建 window.term;ws 层 wrap 依赖 documentStart 注入
 *  时序竞速,间歇双喂/漏拦,RD-2b 已弃用):
 *    · 输出镜像:wrap window.term.write → __oatrdProxy.push;
 *    · 输入探针:term.onData(用户键入)→ proxy.input(行完成→ InputHistory);
 *    · 桥写入:__oatrd.write(b64) → triggerDataEvent(页内 paste 同机制)
 *      → ttyd onData → sendData → 同一 socket INPUT 帧(与用户所见同一会话);
 *    · 活性:armed 时 proxy.hello(markLive;桥路由判定源)。
 *  - 完成探测(PB DoneProbeState 复用):300ms 链 capture 尾 3 行
 *    isPromptBack → '✓ 命令完成 · pane'(onDone 回调,PaneSurface 已接
 *    StatusBar+attention 双落点)。
 *  - 输入探针:用户手敲行完成(\n)且非桥注入 → InputHistory.push
 *    (palette 最近命令区在 web 分支恢复语义)。
 * 组件销毁:TtydSession.detach 全清 + 探测链停。
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TtydSession } from './TtydSession';
import { DoneProbeState, probeSubmit, probeTick, PROBE_TICK_MS } from '../shell/ParityUi';
import { InputHistory } from './InputHistory';
import { tr } from '../../common/AppI18n';
import { fsc } from '../../common/UiFont';
import { WebPaneRects } from '../model/WebPaneRects';

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

/**
 * term 层同步直装(RD-2b 终局;幂等 __oattw 守卫,重复执行无害):
 *  - 输出镜像:wrap term.write → proxy.push(镜像原始流);
 *  - 输入探针:term.onData(用户键入)→ proxy.input(bridging 旁路桥注入);
 *  - 桥写入:__oatrd.write(b64) → UTF-8 文本 → triggerDataEvent —— 页内
 *    paste 同机制(bundle 实勘:coreService.triggerDataEvent(e,!0)),触发
 *    ttyd onData → sendData → 同一 socket INPUT 帧;不依赖 ws 拦截时序;
 *  - armed 时 proxy.hello → markLive(桥路由判定源)。
 * 机制依据(bundle 源码实证):window.term 由前端 bundle 设置;
 *  term.onData 转发自 coreService.onData。
 */
function syncTermHookJs(): string {
  const L: string[] = [
    '(function(){',
    'var t=window.term;',
    'if(!t||typeof t.write!=="function"||t.__oattw){return "skip";}',
    't.__oattw=1;',
    'var dec=new TextDecoder();',
    'var ow=t.write.bind(t);',
    't.write=function(d){',
    '  try{',
    '    if(window.__oatrdProxy){',
    '      var s=d;',
    '      if(d&&typeof d!=="string"){',
    '        try{s=dec.decode(new Uint8Array(d.buffer||d));}catch(e2){s=null;}',
    '      }',
    '      if(s){window.__oatrdProxy.push(s);}',
    '    }',
    '  }catch(e){}',
    '  return ow(d);',
    '};',
    'var bridging=false;',
    'try{t.onData(function(d){',
    '  try{if(!bridging&&window.__oatrdProxy){window.__oatrdProxy.input(d);}}catch(e){}',
    '});}catch(e){}',
    'window.__oatrd={',
    '  write:function(b64){',
    '    try{',
    '      var cs=t._core&&t._core.coreService;',
    '      if(!cs||typeof cs.triggerDataEvent!=="function"){return false;}',
    '      var bin=atob(b64),u8=new Uint8Array(bin.length);',
    '      for(var i=0;i<bin.length;i++){u8[i]=bin.charCodeAt(i);}',
    '      var txt=dec.decode(u8);',
    '      bridging=true;',
    '      try{cs.triggerDataEvent(txt,true);}finally{bridging=false;}',
    '      return true;',
    '    }catch(e){return false;}',
    '  }',
    '};',
    // GUI 丝滑棒:字号钳制页内实现(fontDelta 注入调用) + 快捷键层——
    // Ctrl+Shift+P 命令面板 / T 新标签 / W 关标签 / = - 0 字号,
    // 终端聚焦时也可直达(浏览器级快捷键体验);返回 false 吞键防进 shell
    'window.__oatClamp=function(c,d){if(d===0){return 14;}var n=c+d;' +
    'return n<8?8:(n>32?32:n);};',
    'try{t.attachCustomKeyEventHandler(function(e){',
    '  try{',
    '    if(e&&e.type==="keydown"&&e.ctrlKey&&e.shiftKey&&!e.altKey){',
    '      var k=(e.key||"").toLowerCase();var act="";',
    '      if(k==="p"){act="palette";}',
    '      else if(k==="t"){act="newtab";}',
    '      else if(k==="w"){act="closetab";}',
    '      else if(k==="="||k==="+"){act="fontup";}',
    '      else if(k==="-"||k==="_"){act="fontdown";}',
    '      else if(k==="0"){act="fontreset";}',
    '      if(act){if(window.__oatrdProxy){window.__oatrdProxy.shortcut(act);}return false;}',
    '    }',
    '  }catch(e2){}',
    '  return true;',
    '});}catch(e){}',
    // R4b 诊断(隐私安全):首次任意 keydown 推一次性 [KB-REACH] 标记
    // 进镜像——只报"键盘到达过页面"这一事实,不记键值不记内容;判别
    // ArkWeb 组件焦点是否通(不通时键盘根本到不了页面)。
    'try{var __kbOnce=function(ev){try{if(window.__oatrdProxy){' +
    'window.__oatrdProxy.push("[KB-REACH]\\r\\n");}' +
    'document.removeEventListener("keydown",__kbOnce,true);}catch(e){}};' +
    'document.addEventListener("keydown",__kbOnce,true);}catch(e){}',
    'if(window.__oatrdProxy){window.__oatrdProxy.hello();}',
    'return "armed";',
    '})()'
  ]
  return L.join('\n')
}

/** proxy 方法名清单(registerJavaScriptProxy methodList)。 */
const PROXY_METHODS: string[] = ['push', 'input', 'hello', 'bye', 'shortcut']

/** term 钩子直装重试梯参数(10×600ms:覆盖前端 bundle 建 term 的窗口)。 */
const ARM_MAX_TRIES: number = 10
const ARM_RETRY_MS: number = 600

@Component
export struct TermWebView {
  @StorageProp('ut.fontScale') fontScale: number = 1
  paneId: string = ''
  /** ArkWeb 控制器(PoC 仅持有;不做 loadUrl/refresh 驱动)。 */
  controller: webview.WebviewController = new webview.WebviewController()
  /** 页面加载状态(loading/loaded/error——PoC 证据 + 兜底提示渲染)。 */
  @State pageState: string = 'loading'
  @State pageErr: string = ''
  /** RD-1: 主文档加载失败回调(PaneSurface 注入:invalidate 缓存+降级)。 */
  onUnreachable: () => void = () => {
  }
  /** GUI-i18n: 兜底提示文案反应式语言。 */
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  /** RD-2: 命令完成通知(PB 双落点;PaneSurface onCmdDone 注入)。 */
  onDone: () => void = () => {
  }
  /** GUI 丝滑棒: 页面快捷键上抛(Ctrl+Shift+P/T/W/=/- /0;PaneSurface
   *  接线 vm.handleShortcut)。 */
  onShortcut: (act: string) => void = () => {
  }
  /** RD-2: 完成探测状态(PB 复用;桥注入/用户提交均 probeSubmit 重启)。 */
  private probe: DoneProbeState = new DoneProbeState()
  private probeTimer: number = -1
  /** RD-2b: term 钩子直装重试梯(pageEnd 可能早于前端 bundle 建
   *  window.term;ArkTS 侧 setTimeout 驱动——页内轮询闭包在本 ArkWeb
   *  不驻留。幂等 __oattw 守卫;armed(hello→markLive)后停)。 */
  private armTries: number = 0
  private armTimer: number = -1

  /** 注入代理对象(方法名固定;paneId 由组件字段闭包捕获;
   *  ArkTS 禁无类型对象字面量——具名 class 包装)。 */
  private setupProxy(): void {
    const pane = this.paneId
    const self = this
    class TtydProxyObj {
      push(text: string): void {
        TtydSession.feed(pane, text)
      }

      input(text: string): void {
        // 输入探针:行完成(含 \r 或 \n)才入史;控制符剥除
        if (text.indexOf('\r') >= 0 || text.indexOf('\n') >= 0) {
          const line = text.replace(/[\r\n]/g, '')
          if (line.trim().length > 0) {
            InputHistory.push(line)
          }
        }
        self.kickProbe()
      }

      hello(): void {
        TtydSession.markLive(pane, true)
        hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'rd2 armed pane=%{public}s', pane)
        // R4b:armed 即请求键盘焦点(ArkUI 键盘事件走焦点树——解耦后
        // Web 组件需显式拿组件级焦点) + 页面 textarea 聚焦兜底
        WebPaneRects.requestFocus(pane)
        try {
          self.controller.runJavaScript('try{window.term&&window.term.focus&&window.term.focus()}catch(e){}')
        } catch (e) {
          // 页面未就绪由重试梯兜
        }
      }

      bye(): void {
        TtydSession.markLive(pane, false)
        hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'rd2 ws bye pane=%{public}s', pane)
      }

      shortcut(act: string): void {
        // GUI 丝滑棒:页面快捷键(Ctrl+Shift+P/T/W/=/- /0)上抛宿主
        hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'shortcut pane=%{public}s act=%{public}s', pane, act)
        self.onShortcut(act)
      }
    }
    const proxyObj = new TtydProxyObj()
    // registerJavaScriptProxy 需在 controller attached 后调用;刷新生效
    try {
      this.controller.registerJavaScriptProxy(proxyObj, '__oatrdProxy', PROXY_METHODS)
    } catch (e) {
      hilog.warn(RDPOC_DOMAIN, RDPOC_TAG, 'registerProxy fail pane=%{public}s', pane)
    }
  }

  /** term 钩子直装(立即一次 + 重试梯;armed 后 isLive=true 停)。 */
  private armTermHook(): void {
    if (TtydSession.isLive(this.paneId)) {
      return
    }
    try {
      this.controller.runJavaScript(syncTermHookJs())
    } catch (err) {
      // 页面未就绪等瞬时失败:由重试梯兜
    }
    if (this.armTries < ARM_MAX_TRIES) {
      this.armTries++
      this.armTimer = setTimeout(() => {
        this.armTimer = -1
        this.armTermHook()
      }, ARM_RETRY_MS)
    }
  }

  /** 完成探测启动(用户提交/桥写入锚点:probeSubmit 重启计时)。 */
  private kickProbe(): void {
    probeSubmit(this.probe, Date.now())
    if (this.probeTimer === -1) {
      this.chainProbe()
    }
  }

  private chainProbe(): void {
    this.probeTimer = setTimeout(() => {
      this.probeTimer = -1
      const lines: string[] = TtydSession.capture(this.paneId, 3).split('\n')
      const verdict = probeTick(this.probe, lines, Date.now())
      if (verdict === 'done') {
        this.onDone()
        return
      }
      if (verdict === 'giveup') {
        return
      }
      if (TtydSession.isLive(this.paneId)) {
        this.chainProbe()
      }
    }, PROBE_TICK_MS)
  }

  aboutToAppear(): void {
    // 桥写入锚点:sendText 成功即重启完成探测(同用户提交语义)
    TtydSession.onWriteTap = (pane: string): void => {
      if (pane === this.paneId) {
        this.kickProbe()
      }
    }
  }

  aboutToDisappear(): void {
    TtydSession.detach(this.paneId)
    if (this.armTimer !== -1) {
      clearTimeout(this.armTimer)
      this.armTimer = -1
    }
    if (this.probeTimer !== -1) {
      clearTimeout(this.probeTimer)
      this.probeTimer = -1
    }
    if (TtydSession.onWriteTap !== null) {
      TtydSession.onWriteTap = null
    }
  }

  build() {
    Stack() {
      Web({ src: TTYD_URL, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptOnDocumentStart([
          { script: darkInjectJs(), scriptRules: ['*'] }
        ])
        .onControllerAttached(() => {
          hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'controllerAttached pane=%{public}s', this.paneId)
          this.setupProxy()
          TtydSession.setSender(this.paneId, (js: string): void => {
            try {
              this.controller.runJavaScript(js)
            } catch (e) {
              hilog.warn(RDPOC_DOMAIN, RDPOC_TAG, 'runJavaScript fail pane=%{public}s', this.paneId)
            }
          })
          // RD-2b 终修:一次性 refresh 已移除——它制造第二个页面/term 实例
          // (屏渲染新实例,镜像钩子挂旧实例,屏/镜分叉——「屏无 PROBE 而
          // capture 有」实勘);pageEnd 同步直装已覆盖注入时序,refresh 冗余。
        })
        .onPageEnd((e: OnPageEndEvent) => {
          this.pageState = 'loaded'
          hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'pageEnd pane=%{public}s url=%{public}s',
            this.paneId, e.url)
          // RD-2b: term 钩子直装重试梯起步(pageEnd 可能早于前端 bundle 建
          // window.term——runJavaScript result 恒 null 读不回,靠幂等重试兜)
          this.armTries = 0
          this.armTermHook()
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
              TtydSession.markLive(this.paneId, false)
              this.onUnreachable() // RD-1: 页面级失败兜底降级通知宿主
            }
          } catch (err) {
            // isMainFrame 不可用:保持 loaded 判定(仅记日志)
          }
        })
      // 加载失败兜底提示(不遮挡正常渲染;loaded 后不显示)
      if (this.pageState === 'error') {
        Column({ space: 6 }) {
          Text(tr(this.locale, 'term.unreach'))
            .fontSize(fsc(this.fontScale, 14))
            .fontColor('#f85149')
          Text(TTYD_URL)
            .fontSize(fsc(this.fontScale, 11))
            .fontColor('#7d8590')
          Text(this.pageErr.length > 0 ? this.pageErr : tr(this.locale, 'term.check'))
            .fontSize(fsc(this.fontScale, 11))
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
