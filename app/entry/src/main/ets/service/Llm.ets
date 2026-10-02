// LLM 接入:官方兼容 Anthropic / OpenAI 协议(设置中配 base URL + key + model)
// M6 relay3: chatWithTools 支持 OpenAI 兼容 function-calling(tools 参数 +
// assistant tool_calls 回传 + role:tool 结果回填),供 AgentKernel 多轮驱动。
import http from '@ohos.net.http';

export class LlmConfig {
  provider: string = 'anthropic'
  baseUrl: string = 'https://api.anthropic.com'
  apiKey: string = ''
  model: string = 'claude-sonnet-4-5'

}

export class LlmMsg {
  role: string = 'user'
  text: string = ''
  /** M6 relay3: assistant 轮的 tool_calls JSON(OaiToolCall[] 序列化,空串=无) */
  toolCallsJson: string = ''
  /** M6 relay3: role='tool' 轮对应的 tool_call id */
  toolCallId: string = ''
}

/** chatWithTools 的单个 tool_call(拍平 OpenAI 的 function.name/arguments)。 */
export class OaiToolCall {
  id: string = ''
  type: string = 'function'
  name: string = ''
  arguments: string = ''
}

/** chatWithTools 结果。 */
export class ToolCallResult {
  content: string = ''
  toolCallsJson: string = '[]'
  finishReason: string = ''
  raw: string = ''
}

class AnthMsg {
  role: string = 'user'
  content: string = ''
}

class AnthBody {
  model: string = ''
  max_tokens: number = 1024
  system: string = ''
  messages: AnthMsg[] = []
}

export class Llm {
  static async chat(cfg: LlmConfig, msgs: LlmMsg[], system: string): Promise<string> {
    if (cfg.provider === 'anthropic') {
      return Llm.anthropic(cfg, msgs, system)
    }
    const r = await Llm.openaiChat(cfg, msgs, system, null)
    return r.content
  }

  /**
   * M6 relay3: OpenAI 兼容 function-calling 一轮调用。
   * - msgs 中 role='assistant' 且 toolCallsJson 非空 → 序列化为 tool_calls 轮(content 兼容空)
   * - role='tool' → {role, tool_call_id, content}
   * - toolsJson: OpenAI tools 数组 JSON;null=不带 tools(普通 chat)
   */
  static async chatWithTools(cfg: LlmConfig, msgs: LlmMsg[], system: string, toolsJson: string | null): Promise<ToolCallResult> {
    if (cfg.provider === 'anthropic') {
      throw new Error('function-calling 暂不支持 anthropic,请在设置中切换 OpenAI 兼容 provider')
    }
    return Llm.openaiChat(cfg, msgs, system, toolsJson)
  }

  private static async anthropic(cfg: LlmConfig, msgs: LlmMsg[], system: string): Promise<string> {
    const body = new AnthBody()
    body.model = cfg.model
    body.system = system
    for (const m of msgs) {
      const a = new AnthMsg()
      a.role = m.role
      a.content = m.text
      body.messages.push(a)
    }
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'x-api-key': cfg.apiKey,
      'anthropic-version': '2023-06-01'
    }
    const resp = await Llm.post(cfg.baseUrl.replace(/\/+$/, '') + '/v1/messages', JSON.stringify(body), headers)
    class AnthPart { type: string = ''; text: string = '' }
    class AnthResp { content: AnthPart[] = [] }
    const obj = JSON.parse(resp) as AnthResp
    if (obj.content.length === 0) {
      throw new Error('anthropic bad resp: ' + resp.substring(0, 200))
    }
    let out = ''
    for (const p of obj.content) {
      if (p.type === 'text') {
        out += p.text
      }
    }
    return out
  }

  private static async openaiChat(cfg: LlmConfig, msgs: LlmMsg[], system: string, toolsJson: string | null): Promise<ToolCallResult> {
    // 请求体用 Record 组装:assistant tool_calls 轮与 role:tool 轮需精确字段名
    const msgsRec: Record<string, Object>[] = []
    const sysRec: Record<string, Object> = {}
    sysRec['role'] = 'system'
    sysRec['content'] = system
    msgsRec.push(sysRec)
    for (const m of msgs) {
      const r: Record<string, Object> = {}
      r['role'] = m.role
      if (m.role === 'tool') {
        r['tool_call_id'] = m.toolCallId
        r['content'] = m.text
      } else if (m.role === 'assistant' && m.toolCallsJson !== '') {
        r['content'] = m.text
        const tcs = JSON.parse(m.toolCallsJson) as OaiToolCall[]
        const arr: Record<string, Object>[] = []
        for (const t of tcs) {
          const fn: Record<string, Object> = {}
          fn['name'] = t.name
          fn['arguments'] = t.arguments
          const tc: Record<string, Object> = {}
          tc['id'] = t.id
          tc['type'] = t.type
          tc['function'] = fn
          arr.push(tc)
        }
        r['tool_calls'] = arr
      } else {
        r['content'] = m.text
      }
      msgsRec.push(r)
    }
    const body: Record<string, Object> = {}
    body['model'] = cfg.model
    body['max_tokens'] = 1024
    body['messages'] = msgsRec
    if (toolsJson !== null) {
      body['tools'] = JSON.parse(toolsJson) as Object
      const choice: Record<string, Object> = {}
      choice['type'] = 'auto'
      body['tool_choice'] = choice
    }
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + cfg.apiKey
    }
    const resp = await Llm.post(cfg.baseUrl.replace(/\/+$/, '') + '/chat/completions', JSON.stringify(body), headers)
    class OaiFnOut { name: string = ''; arguments: string = '' }
    class OaiToolCallOut { id: string = ''; type: string = ''; function: OaiFnOut = new OaiFnOut() }
    class OaiMsgOut { content: string | null = null; tool_calls: OaiToolCallOut[] | null = null }
    class OaiChoice { message: OaiMsgOut = new OaiMsgOut(); finish_reason: string = '' }
    class OaiResp { choices: OaiChoice[] = [] }
    const obj = JSON.parse(resp) as OaiResp
    if (obj.choices.length === 0) {
      throw new Error('openai bad resp: ' + resp.substring(0, 200))
    }
    const c0 = obj.choices[0]
    const out = new ToolCallResult()
    out.finishReason = c0.finish_reason
    out.raw = resp
    if (c0.message.content !== null && c0.message.content !== undefined) {
      out.content = c0.message.content
    }
    const tcs: OaiToolCall[] = []
    if (c0.message.tool_calls !== null && c0.message.tool_calls !== undefined) {
      for (const t of c0.message.tool_calls) {
        const tc = new OaiToolCall()
        tc.id = t.id
        tc.type = t.type
        tc.name = t.function.name
        tc.arguments = t.function.arguments
        tcs.push(tc)
      }
    }
    out.toolCallsJson = JSON.stringify(tcs)
    return out
  }

  private static async post(url: string, body: string, headers: Record<string, string>): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const h = http.createHttp()
      h.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: 30000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.STRING
      }, (err, resp) => {
        h.destroy()
        if (err) {
          reject(new Error('http ' + JSON.stringify(err)))
          return
        }
        if (resp.responseCode >= 400) {
          let d = ''
          if (typeof resp.result === 'string') {
            d = resp.result
          }
          reject(new Error('http ' + resp.responseCode + ' ' + d.substring(0, 300)))
          return
        }
        resolve(typeof resp.result === 'string' ? resp.result : '')
      })
    })
  }
}
