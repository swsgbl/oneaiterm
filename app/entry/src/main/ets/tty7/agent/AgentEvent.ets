/**
 * tty7 AgentEvent v1 统一事件(任务 tty7-M5a,纯类型;01 文档 AgentEvent v1 规格)。
 * 九类事件总线载荷:agent/ 引擎事件(HmhAdapter/AcpClient/LocalAssistant)映射的
 * 唯一靶型;单类多字段(ArkTS 无联合字面量,按 type 使用对应负载字段)。
 * 红线:秘密不进事件文本(argsDigest 只放脱敏摘要,维持引擎层原有脱敏)。
 */
export type AgentEventType = 'run_started' | 'state_changed' | 'delta' | 'tool_call' |
  'approval_required' | 'tool_result' | 'final' | 'attention' | 'session_checkpoint'

export class AgentEvent {
  seq: number = 0            // 总线单调序号(乱序检测/重播用;emit 时填充)
  ts: number = 0             // epoch ms(emit 时填充)
  runId: string = ''         // 桥侧任务号('r1','r2'…;'' = 面板级)
  paneId: string = ''        // 关联 pane('' = 面板级;M5b 做 pane 绑定)
  agentId: string = ''       // 'hmh'|'acp:*'|'local'
  type: AgentEventType = 'state_changed'
  state: string = ''         // state_changed: idle|working|waiting|done|error
  kind: string = ''          // delta: reasoning|message
  text: string = ''          // delta 文本 / final summary / attention 文本等
  toolId: string = ''
  toolName: string = ''
  argsDigest: string = ''    // 脱敏摘要(不进原文)
  riskLevel: string = ''     // 档位(read_only..destructive;展示层分级着色)
  ok: boolean = true         // tool_result/final 成败
}
