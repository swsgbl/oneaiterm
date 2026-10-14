/**
 * tty7 Agent 面板纯逻辑(任务 tty7-LEG-2;旧界面退役计划棒 2/4)。
 *
 * AI prompt 输入迁 tty7 的守卫/文案纯函数(单测靶;零 UI/IO import):
 *  - promptGuard:trim/空守卫(Enter 发送前的统一闸)
 *  - engineLabel / engineOfKey:三引擎(local/hmh/acp)pill 文案与归一
 *  - wantPromptValid:--ps agentPrompt 直驱通道的合法性(非空即驱)
 * 红线:prompt 原文绝不落日志(本文件所有函数不触 hilog/console);
 *  事件文本截断 120 字由消费方 capText 兜(RightPanel TEXT_CAP 更严)。
 */

/** 引擎键白名单('' 视为默认 hmh)。 */
export function engineOfKey(k: string): string {
  if (k === 'local' || k === 'acp' || k === 'hmh') {
    return k
  }
  return 'hmh'
}

/** 引擎 pill 文案(hmh=HMH 本机引擎;local=本地;acp=ACP)。 */
export function engineLabel(k: string): string {
  const e = engineOfKey(k)
  if (e === 'local') {
    return '本地'
  }
  if (e === 'acp') {
    return 'ACP'
  }
  return 'HMH'
}

/** prompt 守卫:trim 后非空才可发('' = 拦截)。 */
export function promptGuard(raw: string): string {
  const t = raw.trim()
  return t !== '' ? t : ''
}

/** want --ps agentPrompt 直驱判定:非空(已 trim)即合法直驱。 */
export function wantPromptValid(raw: string): boolean {
  return raw.trim() !== ''
}
