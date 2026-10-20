/**
 * parity 棒 B 纯函数(任务 PB;PARITY-AUDIT.md B 节收口)。
 * 两块 UI 差距的判定逻辑,全部纯函数/纯状态机,零 UI import:
 *  - palette 最近命令区:recentMatches(最近 5 条 InputHistory,query
 *    前缀过滤;空 query 全量截 5);
 *  - 命令完成通知:isPromptBack(提示符回归判定——尾行 trim 后缀 $/#/>)
 *    + DoneProbeState/probeSubmit/probeTick(探测状态机:距提交 >800ms
 *    且提示符回归 → done;60s 上限 giveup;期间新提交重置计时——去抖);
 *  - buildFinishedAttention:attention 事件构造(type 'attention' /
 *    kind 'finished' / paneId——Agent 面板可见通知,StatusBar 之外的
 *    第二落点)。
 * 红线:不 import 任何组件/服务;秘密不进事件文本(只带 paneId)。
 */
import { AgentEvent } from '../agent/AgentEvent';

/** palette 最近命令区块条数上限。 */
export const RECENT_MAX: number = 5;
/** 完成探测轮询周期(ms;红线:轻——每拍只 capture 尾 3 行)。 */
export const PROBE_TICK_MS: number = 300;
/** 完成判定最短静默(ms):提交后立即提示符回归不算完成(回显误判防)。 */
export const PROBE_MIN_MS: number = 800;
/** 完成探测上限(ms):超过放弃(永不通知)。 */
export const PROBE_GIVEUP_MS: number = 60000;

/**
 * 提示符回归判定(纯):lines 为 pane 尾部若干行文本;
 * 尾行 trim 后以 $ / # / > 结尾 = shell 回到提示符等待输入。
 * 空数组 / 尾行全空白 → false(输出进行中或空模型)。
 */
export function isPromptBack(lines: string[]): boolean {
  if (lines.length === 0) {
    return false
  }
  const last = lines[lines.length - 1].trim()
  if (last.length === 0) {
    return false
  }
  const c = last.charAt(last.length - 1)
  return c === '$' || c === '#' || c === '>'
}

/**
 * palette 最近命令过滤(纯):recent 最新在前(InputHistory.recent() 形状);
 * query 空/全空白 → 截前 RECENT_MAX 条全量;否则前缀匹配(大小写不敏感,
 * 与命令过滤的 toLowerCase 口径一致)。返回保序子集(拷贝,不改入参)。
 */
export function recentMatches(recent: string[], query: string): string[] {
  const cap = recent.length > RECENT_MAX ? recent.slice(0, RECENT_MAX) : recent.slice()
  const q = query.trim().toLowerCase()
  if (q === '') {
    return cap
  }
  const out: string[] = []
  for (const r of cap) {
    if (r.toLowerCase().startsWith(q)) {
      out.push(r)
    }
  }
  return out
}

/**
 * 完成探测状态机(纯状态,组件持有实例;时间由外部注入可测)。
 * submitMs=最近一次提交时刻;active=探测中;notified=最近一轮已通知
 * (观测用;done 后 active 立即 false)。
 */
export class DoneProbeState {
  submitMs: number = 0
  active: boolean = false
  notified: boolean = false
}

/** 提交(或期间再提交):重置计时并保持/重启探测(去抖——新提交覆盖旧轮)。 */
export function probeSubmit(st: DoneProbeState, nowMs: number): void {
  st.submitMs = nowMs
  st.active = true
  st.notified = false
}

/**
 * 一拍探测(纯):返回 'none'(继续)/ 'done'(完成,通知一次)/ 'giveup'
 * (超上限放弃)。done/giveup 后 active=false,链停;下次 submit 重启。
 * 判定:active 且 距提交 >PROBE_MIN_MS 且 isPromptBack(lines) → done;
 * 距提交 >PROBE_GIVEUP_MS → giveup(先于 done 检查:永不晚于上限通知)。
 */
export function probeTick(st: DoneProbeState, lines: string[], nowMs: number): string {
  if (!st.active) {
    return 'none'
  }
  const el = nowMs - st.submitMs
  if (el > PROBE_GIVEUP_MS) {
    st.active = false
    st.notified = false
    return 'giveup'
  }
  if (el > PROBE_MIN_MS && isPromptBack(lines)) {
    st.active = false
    st.notified = true
    return 'done'
  }
  return 'none'
}

/** attention 事件构造(纯):type 'attention' / kind 'finished' / paneId;
 *  text 为面板展示文案(只含 paneId,无命令内容——秘密红线)。 */
export function buildFinishedAttention(paneId: string): AgentEvent {
  const ev = new AgentEvent()
  ev.type = 'attention'
  ev.kind = 'finished'
  ev.paneId = paneId
  ev.text = '✓ 命令完成 · ' + paneId
  return ev
}

/**
 * 尾部空行剪除(纯;PB 热修):log 模型提示符之后垫底的全空行不构成
 * "最近输出"——新会话 '$ ' 在屏顶时尾 N 行全 blank,capture/tailTexts
 * 取窗前先剪(实勘:tmLines=46 尾窗全空 → capture 空串 → 桥误报
 * 'pane not bound';done 探测同理 isPromptBack 恒 false)。
 * 全空/全空白行 → 空数组;无尾空行原样(拷贝)。
 */
export function trimBlankTail(texts: string[]): string[] {
  let end = texts.length
  while (end > 0 && texts[end - 1].trim().length === 0) {
    end--
  }
  return texts.slice(0, end)
}
