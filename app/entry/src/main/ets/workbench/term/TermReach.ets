/**
 * RD-1: ttyd 可达性运行时探测 + 渲染分流(ADR-0002 集成棒 1)。
 *
 * PoC 期的编译期常量 RD_POC 升级为运行时分流:
 *  - probeTtyd(): 轻量 GET http://127.0.0.1:27681/(netstack http.createHttp,
 *    短超时,任意响应码=可达;异常/超时=不可达)。绝不抛出。
 *  - 会话级缓存 + 失败指数退避重探(1s/5s/30s;成功后缓存恒真,
 *    onErrorReceive 页面级失败兜底可 invalidate)。
 *  - 网络调用与缓存策略分离(fetcher 注入):单测 mock 网络栈,
 *    纯逻辑(缓存/退避/异常不抛)全覆盖,VM 真机可达性走验收 A1/A2。
 *
 * 设计约束(ArkTS):
 *  - 状态机纯同步类 TermReachState,不 import @ohos 网络栈——单测靶;
 *  - 真网络 fetcher 只在 probeTtyd() 里组装,测试永不触达。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RD1_TAG: string = 'wb.RD1'
const RD1_DOMAIN: number = 0x0302

/** ttyd 服务地址(VM 启动项,root,-W 可写;ADR-0002,同 TermWebView)。 */
export const TTYD_URL: string = 'http://127.0.0.1:27681/'
/** 探测 HTTP 短超时(ms)——UI 分流探测要求快,800ms 内无响应判不可达。 */
export const PROBE_TIMEOUT_MS: number = 800

/**
 * 失败指数退避表(ms):失败次数 1/2/3+ → 1s/5s/30s 后允许重探。
 * 成功后状态钉在 ok=true(缓存恒真,不重探——ttyd 是 VM 启动项,
 * 会话内消失属页面级错误,由 onErrorReceive 兜底置 fail)。
 */
export const BACKOFF_MS: number[] = [1000, 5000, 30000]

/** 退避取值:第 n 次失败(n 从 1 起)后距下次允许探测的间隔。 */
export function backoffAfter(failCount: number): number {
  if (failCount <= 0) {
    return 0
  }
  const idx = failCount - 1
  if (idx >= BACKOFF_MS.length) {
    return BACKOFF_MS[BACKOFF_MS.length - 1]
  }
  return BACKOFF_MS[idx]
}

/** 网络探测函数签名(注入靶):resolve(true)=可达;false=不可达/异常。 */
export type ProbeFetcher = () => Promise<boolean>

/**
 * 会话级探测状态机(纯同步,单测靶):
 *  - probe(now): 是否允许发起探测(退避窗口外);
 *  - setResult(ok, now): 记录结果(ok=true 钉死;false 计失败数开退避);
 *  - invalidate(now): 页面级失败兜底(web onErrorReceive 主文档失败):
 *    若当前 ok=true 转 unknown 并立即允许重探(退避窗口 0)。
 *    ok=false 时 no-op(已在退避中,重复 invalidate 无意义)。
 *  - unknown 态(now=0)允许立即探测(应用冷启首轮)。
 */
export class TermReachState {
  /** null=unknown(未探测/被 invalidate);true=可达(钉死);false=不可达。 */
  ok: boolean | null = null
  /** 连续失败次数(成功或 invalidate 转unknown 时清 0)。 */
  failCount: number = 0
  /** 距下次允许探测的时刻(ms 单调时钟);0=立即允许。 */
  nextProbeAt: number = 0

  /** now 时刻是否允许发起探测(unknown 立即;false 退避窗外)。 */
  probe(now: number): boolean {
    if (this.ok === true) {
      return false
    }
    return now >= this.nextProbeAt
  }

  /** 记录一次探测结果。 */
  setResult(ok: boolean, now: number): void {
    if (ok) {
      this.ok = true
      this.failCount = 0
      this.nextProbeAt = 0
    } else {
      this.ok = false
      this.failCount += 1
      this.nextProbeAt = now + backoffAfter(this.failCount)
    }
  }

  /** 页面级失败兜底:可达→unknown 立即重探;不可达 no-op。 */
  invalidate(now: number): void {
    if (this.ok === true) {
      this.ok = null
      this.failCount = 0
      this.nextProbeAt = 0
    }
  }
}

/**
 * 会话级共享状态(PaneSurface 各 pane 共用;module 级单例)。
 * probeTtyd() 每次成功/失败后更新;PaneSurface 新 pane 消费缓存。
 */
export const reachState: TermReachState = new TermReachState()

/** 单测注入口(生产恒 null):非 null 时 probeTtyd 不触网络栈。
 *  模块私有可变绑定(export let 在 ArkTS 严格模式禁),经 inject/reset 操作。 */
let probeFetcher: ProbeFetcher | null = null

/** 单测/重置用:恢复真实网络 fetcher。 */
export function resetFetcher(): void {
  probeFetcher = null
  reachState.ok = null
  reachState.failCount = 0
  reachState.nextProbeAt = 0
}

/** 单测注入 mock fetcher 并复位状态。 */
export function injectFetcher(f: ProbeFetcher): void {
  probeFetcher = f
  reachState.ok = null
  reachState.failCount = 0
  reachState.nextProbeAt = 0
}

/** 单调时钟(Date.now 同源,注入点留给测试间接驱动)。 */
export function nowMs(): number {
  return Date.now()
}

/**
 * 真网络 fetcher:GET TTYD_URL,短超时,任意响应码=可达。
 * 绝不抛出:无网络栈/异常/超时一律 false。
 */
async function netFetch(): Promise<boolean> {
  let req: http.HttpRequest | null = null
  try {
    req = http.createHttp()
    const resp = await req.request(TTYD_URL, {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'text/html' },
      connectTimeout: PROBE_TIMEOUT_MS,
      readTimeout: PROBE_TIMEOUT_MS,
      usingCache: false,
      expectDataType: http.HttpDataType.STRING
    })
    // 任意响应码(含 4xx/5xx)= 服务在听 → 可达
    return true
  } catch (e) {
    return false
  } finally {
    try {
      if (req !== null) {
        req.destroy()
      }
    } catch (e2) {
      // destroy 兜底失败(连接已断等)静默
    }
  }
}

/**
 * ttyd 可达性探测(入口,PaneSurface aboutToAppear 调):
 *  - 退避窗口内直接返回缓存(false),不发网络;
 *  - 发探测(注入 mock 或真网络),结果入会话缓存;
 *  - 绝不抛出(内层全 try;最外层理论不可达,防御再兜一层)。
 */
export async function probeTtyd(): Promise<boolean> {
  try {
    if (!reachState.probe(nowMs())) {
      // 退避窗口内:消费缓存(unknown 不可能走到这——probe()==true 才放行,
      // 且这里 ok 必为 false:unknown 的 nextProbeAt=0 恒放行)
      return reachState.ok === true
    }
    let ok = false
    if (probeFetcher !== null) {
      ok = await probeFetcher()
    } else {
      ok = await netFetch()
    }
    reachState.setResult(ok, nowMs())
    hilog.info(RD1_DOMAIN, RD1_TAG, 'probeTtyd result=%{public}s failCount=%{public}d',
      ok ? 'ok' : 'unreachable', reachState.failCount)
    return ok
  } catch (e) {
    // 防御兜底:任何意外都不抛出(UI 探测绝不崩应用)
    try {
      reachState.setResult(false, nowMs())
    } catch (e3) {
      // 状态机纯内存操作,理论不可达
    }
    return false
  }
}
