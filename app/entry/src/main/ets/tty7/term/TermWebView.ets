/**
 * tty7-RD: Web 组件加载系统 ttyd(xterm.js 页面;ADR-0002 运行时探测分流。
 * RD-1:运行时探测可达(PaneSurface probeTtyd/ttydOk);onErrorReceive
 * 主文档失败回调 onUnreachable,宿主 invalidate 探测缓存并降级 TermPaneView。
 *
 * tty7-RD-2(方案 B,VM 实勘定案——多客户端=独立 shell,桥不能自连 WS):
 *  - javaScriptOnDocumentStart 注入两层脚本:
 *    · darkInject:暗色适配(原有);
 *    · hookInject:wrap window.WebSocket——页面 ttyd 客户端的 socket 被
 *      挂钩:onopen 后 hello(置 live);onmessage('0' 帧)→ proxy.push
 *      (UTF-8 解码后的原始流回传 ArkTS 镜像);send 拦截 INPUT 帧送
 *      __tty7rd.inbox(输入探针 → InputHistory)。
 *  - 桥/引擎写入:TtydSession.sendText → runJavaScript('__tty7rd.write(b64)')
 *    → 同一 socket.send('0'+bytes)——与用户所见完全同一会话(A1 判据)。
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
 * RD-2 hook 脚本(document start,先于页面脚本执行):wrap WebSocket。
 * 页面(new WebSocket(url,["tty"]))创建的 socket 被代理:
 *  - onopen(页面注入的 handler 前触发,捕获 this):hello → __tty7rd.hello
 *    → proxy.pushLive(pane);
 *  - onmessage:'0' 前缀帧 = OUTPUT,TextDecoder 解码 → proxy.push(text);
 *    (镜像只要原始流;控制帧 '1'prefs/'2'重构通知忽略)
 *  - send:INPUT 帧('0'+bytes)→ __tty7rd.inbox(text, byBridge)。
 *    byBridge=true(桥注入)不进输入探针;用户手敲 byBridge=false。
 * __tty7rd.write(b64):解码 → Uint8Array('0' 前缀)→ 原始 socket.send
 * (经保存的 realSend,绕开 wrap 防递归计数错位)。
 */
function hookInjectJs(): string {
  const lines: string[] = [
    '(function(){',
    'if(window.__tty7rdInstalled){return;}',
    'window.__tty7rdInstalled=true;',
    'var dec=new TextDecoder();',
    'var st={sock:null,line:"",busy:false};',
    'window.__tty7rd={',
    '  write:function(b64){',
    '    try{',
    '      if(!st.sock||st.sock.readyState!==1){return false;}',
    '      var bin=atob(b64),u8=new Uint8Array(bin.length+1);',
    '      u8[0]=48;',
    '      for(var i=0;i<bin.length;i++){u8[i+1]=bin.charCodeAt(i);}',
    '      var mask=st.realSend?',
    '        (function(u){st.bridgeWriting=true;try{st.realSend(u);}finally{st.bridgeWriting=false;}}):null;',
    '      if(mask){mask(u8);}',
    '      return true;',
    '    }catch(e){return false;}',
    '  }',
    '};',
    'var RealWS=window.WebSocket;',
    // 原型级 message 拦截:覆盖所有实例(含注入迟到时页面已建的 ws——
    // 构造 wrap 拦不到;实勘:feed 仅 2 帧=只拦到重连实例)
    'var OAE=RealWS.prototype.addEventListener;',
    'function __tty7frame(ev){',
    '  if(!window.__tty7rdProxy){return;}',
    '  var d=ev.data;',
    '  if(typeof d==="string"){if(d.charCodeAt(0)===48){window.__tty7rdProxy.push(d.substring(1));}return;}',
    '  if(d&&d instanceof ArrayBuffer){',
    '    var u8=new Uint8Array(d);',
    '    if(u8.length>0&&u8[0]===48){window.__tty7rdProxy.push(dec.decode(u8.subarray(1)));}',
    '  }else if(d&&typeof Blob!=="undefined"&&d instanceof Blob){',
    '    var fr=new FileReader();',
    '    fr.onload=function(){',
    '      try{',
    '        var v=new Uint8Array(fr.result);',
    '        if(v.length>0&&v[0]===48&&window.__tty7rdProxy){window.__tty7rdProxy.push(dec.decode(v.subarray(1)));}',
    '      }catch(e){}',
    '    };',
    '    fr.readAsArrayBuffer(d);',
    '  }else if(d&&d.byteLength!==undefined){',
    '    var u8b=new Uint8Array(d);',
    '    if(u8b.length>0&&u8b[0]===48){window.__tty7rdProxy.push(dec.decode(u8b.subarray(1)));}',
    '  }',
    '}',
    'RealWS.prototype.addEventListener=function(type,fn,opts){',
    '  if(type==="message"){',
    '    var self=this;',
    '    var wrapped=function(ev){__tty7frame(ev);return fn.call(self,ev);};',
    '    return OAE.call(this,type,wrapped,opts);',
    '  }',
    '  return OAE.apply(this,arguments);',
    '};',
    // onmessage 属性赋值劫持(ttyd 页用属性式;addEventListener 拦不到——实勘)
    'var OOMP=Object.getOwnPropertyDescriptor(RealWS.prototype,"onmessage");',
    'if(OOMP&&OOMP.configurable){',
    '  Object.defineProperty(RealWS.prototype,"onmessage",{',
    '    configurable:true,enumerable:true,',
    '    get:function(){return this.__tty7om;},',
    '    set:function(fn){',
    '      this.__tty7om=fn;',
    '      var self=this;',
    '      OOMP.set.call(this,function(ev){__tty7frame(ev);if(fn){return fn.call(self,ev);}});',
    '    }',
    '  });',
    '}',
    'function WrappedWS(url,protocols){',
    '  var w=protocols!==undefined?new RealWS(url,protocols):new RealWS(url);',
    '  var seenOpen=false;',
    '  w.addEventListener("open",function(){',
    '    seenOpen=true;st.sock=w;',
    '    st.realSend=RealWS.prototype.send;',
    '    if(window.__tty7rdProxy){window.__tty7rdProxy.hello();}',
    '  });',
    '  w.addEventListener("close",function(){',
    '    if(window.__tty7rdProxy){window.__tty7rdProxy.bye();}',
    '    if(st.sock===w){st.sock=null;st.realSend=null;}',
    '  });',
    '  var origSend=w.send;',
    '  w.send=function(data){',
    '    try{',
    '      if(!st.bridgeWriting&&window.__tty7rdProxy){',
    '        var u=data instanceof ArrayBuffer?new Uint8Array(data):(data&&data.buffer?new Uint8Array(data.buffer,data.byteOffset,data.byteLength):null);',
    '        if(u&&u.length>1&&u[0]===48){window.__tty7rdProxy.input(dec.decode(u.subarray(1)));}',
    '      }',
    '    }catch(e){}',
    '    return origSend.apply(this,arguments);',
    '  };',
    '  return w;',
    '}',
    'WrappedWS.prototype=RealWS.prototype;',
    'WrappedWS.OPEN=RealWS.OPEN;',
    'window.WebSocket=WrappedWS;',
    '})();'
  ]
  return lines.join('\n')
}

/** proxy 方法名清单(registerJavaScriptProxy methodList)。 */
const PROXY_METHODS: string[] = ['push', 'input', 'hello', 'bye']

@Component
export struct TermWebView {
  paneId: string = ''
  /** ArkWeb 控制器(PoC 仅持有;不做 loadUrl/refresh 驱动)。 */
  controller: webview.WebviewController = new webview.WebviewController()
  /** 页面加载状态(loading/loaded/error——PoC 证据 + 兜底提示渲染)。 */
  @State pageState: string = 'loading'
  @State pageErr: string = ''
  /** RD-1: 主文档加载失败回调(PaneSurface 注入:invalidate 缓存+降级)。 */
  onUnreachable: () => void = () => {
  }
  /** RD-2: 命令完成通知(PB 双落点;PaneSurface onCmdDone 注入)。 */
  onDone: () => void = () => {
  }
  /** RD-2: 完成探测状态(PB 复用;桥注入/用户提交均 probeSubmit 重启)。 */
  private probe: DoneProbeState = new DoneProbeState()
  private probeTimer: number = -1

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
        hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'rd2 ws hello pane=%{public}s', pane)
      }

      bye(): void {
        TtydSession.markLive(pane, false)
        hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'rd2 ws bye pane=%{public}s', pane)
      }
    }
    const proxyObj = new TtydProxyObj()
    // registerJavaScriptProxy 需在 controller attached 后调用;刷新生效
    try {
      this.controller.registerJavaScriptProxy(proxyObj, '__tty7rdProxy', PROXY_METHODS)
    } catch (e) {
      hilog.warn(RDPOC_DOMAIN, RDPOC_TAG, 'registerProxy fail pane=%{public}s', pane)
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
    if (this.probeTimer !== -1) {
      clearTimeout(this.probeTimer)
      this.probeTimer = -1
    }
    if (TtydSession.onWriteTap !== null) {
      TtydSession.onWriteTap = null
    }
  }

  /** RD-2: 首挂载后一次性 refresh——javaScriptOnDocumentStart 的注入在本
   *  ArkWeb 上晚于页面脚本(ws 已建,wrap/patch 拦不到;实勘 feed 仅 2 帧)。
   *  refresh 使页面重载,注入先于脚本执行,钩子全面生效。一次性守卫防环。 */
  private refreshed: boolean = false

  build() {
    Stack() {
      Web({ src: TTYD_URL, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptOnDocumentStart([
          { script: darkInjectJs(), scriptRules: ['*'] },
          { script: hookInjectJs(), scriptRules: ['*'] }
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
          if (!this.refreshed) {
            this.refreshed = true
            try {
              this.controller.refresh()
              hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'one-shot refresh pane=%{public}s (inject-order fix)', this.paneId)
            } catch (e) {
              hilog.warn(RDPOC_DOMAIN, RDPOC_TAG, 'refresh fail pane=%{public}s', this.paneId)
            }
          }
        })
        .onPageEnd((e: OnPageEndEvent) => {
          this.pageState = 'loaded'
          hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'pageEnd pane=%{public}s url=%{public}s',
            this.paneId, e.url)
          // RD-2 诊断:页面钩子实况(注入是否生效/ws 是否被拦)
          try {
            this.controller.runJavaScript(
              'JSON.stringify({installed:!!window.__tty7rdInstalled,rd:!!window.__tty7rd,' +
              'ws:!!window.__tty7ws,proxy:!!window.__tty7rdProxy,' +
              'term:!!window.term,ready:window.__tty7ws?window.__tty7ws.readyState:-1})',
              (err: Error, result: string): void => {
                hilog.info(RDPOC_DOMAIN, RDPOC_TAG, 'hookstate pane=%{public}s %{public}s',
                  this.paneId, result)
              })
          } catch (err) {
            hilog.warn(RDPOC_DOMAIN, RDPOC_TAG, 'hookstate fail pane=%{public}s', this.paneId)
          }
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
