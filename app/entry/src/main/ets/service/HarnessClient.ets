// M6 relay5 - hmharness Web 直连(模式B):纯网络层,不碰 ArkUI。
// 协议(实勘 G:\hmharness\packages\web):
//   POST {base}/api/task   body {text,mode} -> 200 入队/开跑
//   GET  {base}/api/events SSE(text/event-stream,事件带 id,支持 Last-Event-ID 补发)
//   GET  {base}/api/state  连接测试端点
// 流式: @ohos.net.http HttpRequest.requestInStream + on('dataReceive')/on('dataEnd')
//   —— SDK d.ts 实证(SDK 默认 openharmony ets api)支持,无需降级轮询。
// 事件名与载荷(JSON):
//   hello|busy|line|delta|tool|toolResult|approvalReq|approvalDone|final|error|injected|queue|state
// hilog tag: oat.harness(域 0x0111)
import http from '@ohos.net.http';
import hilog from '@ohos.hilog';

const HS_TAG: string = 'oat.harness';
const HS_DOMAIN: number = 0x0111;

/** SSE 事件分发回调(事件名 -> data JSON 解析失败时给出原文)。 */
export interface HarnessEventCbs {
  onEvent: (name: string, data: string) => void
  onError: (msg: string) => void
  onEnd: () => void
}

/** 单条已解析 SSE 消息(事件名+data,可能多行 data: 合并)。 */
class SseMsg {
  name: string = ''
  data: string = ''
}

/**
 * HarnessStream - 一条到 {base}/api/events 的 SSE 流 + /api/task 发任务。
 * 用法: connect(cbs) 建流 -> send(task,mode) 发任务 -> close()。
 * 内部: dataReceive 字节缓冲,按 \n 切行;空行=一条消息边界;
 * 行形如 "event: xxx" / "data: {...}";事件 id 记录(断线重连 Last-Event-ID)。
 */
export class HarnessStream {
  private req: http.HttpRequest | null = null
  private buffer: string = ''
  private curEvent: string = ''
  private curData: string = ''
  private lastId: number = -1
  private base: string = ''
  private cbs: HarnessEventCbs | null = null
  private closed: boolean = false

  constructor(base: string) {
    this.base = base.replace(/\/+$/, '')
  }

  /** 建立 SSE 长连接(GET /api/events, Accept: text/event-stream)。 */
  connect(cbs: HarnessEventCbs): void {
    this.cbs = cbs
    this.closed = false
    this.req = http.createHttp()
    this.req.on('dataReceive', (buf: ArrayBuffer) => {
      this.onBytes(buf)
    })
    this.req.on('dataEnd', () => {
      hilog.info(HS_DOMAIN, HS_TAG, 'stream dataEnd lastId=%{public}d', this.lastId)
      this.emitMessage()
      if (this.cbs !== null) {
        this.cbs.onEnd()
      }
    })
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'text/event-stream', 'Last-Event-ID': this.lastId.toString() },
      connectTimeout: 15000,
      readTimeout: 600000
    }
    this.req.requestInStream(this.base + '/api/events', opts, (err: Error, code: number) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(HS_DOMAIN, HS_TAG, 'stream start fail err=%{public}s', JSON.stringify(err))
        if (this.cbs !== null) {
          this.cbs.onError('连接失败: ' + JSON.stringify(err).substring(0, 120))
        }
        return
      }
      if (code !== 200) {
        hilog.error(HS_DOMAIN, HS_TAG, 'stream start code=%{public}d', code)
        if (this.cbs !== null) {
          this.cbs.onError('服务返回 ' + code)
        }
        return
      }
      hilog.info(HS_DOMAIN, HS_TAG, 'stream opened base=%{public}s', this.base)
    })
  }

  private onBytes(buf: ArrayBuffer): void {
    this.buffer += this.buf2str(buf)
    // 逐行处理,末行可能不完整留在 buffer
    let nl = this.buffer.indexOf('\n')
    while (nl >= 0) {
      const line = this.buffer.substring(0, nl)
      this.buffer = this.buffer.substring(nl + 1)
      this.onLine(line)
      nl = this.buffer.indexOf('\n')
    }
  }

  private onLine(raw: string): void {
    const line = raw.replace(/\r$/, '')
    if (line === '') {
      // 空行=一条消息结束
      this.emitMessage()
      return
    }
    if (line.startsWith('event:')) {
      this.curEvent = line.substring(6).trim()
    } else if (line.startsWith('data:')) {
      const d = line.substring(5)
      this.curData = this.curData === '' ? d : this.curData + '\n' + d
    } else if (line.startsWith('id:')) {
      const idStr = line.substring(3).trim()
      const n = Number(idStr)
      if (!isNaN(n)) {
        this.lastId = n
      }
    }
  }

  private emitMessage(): void {
    if (this.curEvent === '' && this.curData === '') {
      return
    }
    const cbs = this.cbs
    if (cbs !== null) {
      cbs.onEvent(this.curEvent, this.curData)
    }
    this.curEvent = ''
    this.curData = ''
  }

  private buf2str(buf: ArrayBuffer): string {
    const u8 = new Uint8Array(buf)
    let out = ''
    for (let i = 0; i < u8.length; i++) {
      out += String.fromCharCode(u8[i])
    }
    return out
  }

  /** 发任务: POST /api/task {text,mode}。失败时经 cbs.onError 上抛。 */
  send(task: string, mode: string): void {
    const bodyObj: Record<string, string> = {}
    bodyObj['text'] = task
    bodyObj['mode'] = mode
    bodyObj['fresh'] = 'true'
    const p = this.base + '/api/task'
    const r = http.createHttp()
    r.request(p, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: JSON.stringify(bodyObj),
      connectTimeout: 15000,
      readTimeout: 30000
    }, (err: Error, resp: http.HttpResponse) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(HS_DOMAIN, HS_TAG, 'task send fail err=%{public}s', JSON.stringify(err))
        if (this.cbs !== null) {
          this.cbs.onError('任务发送失败: ' + JSON.stringify(err).substring(0, 120))
        }
        return
      }
      if (resp.responseCode !== 200) {
        hilog.error(HS_DOMAIN, HS_TAG, 'task send code=%{public}d', resp.responseCode)
        if (this.cbs !== null) {
          this.cbs.onError('服务返回 ' + resp.responseCode + '(busy/入队?看事件流)')
        }
        return
      }
      hilog.info(HS_DOMAIN, HS_TAG, 'task sent len=%{public}d mode=%{public}s', task.length, mode)
    })
  }

  close(): void {
    this.closed = true
    this.cbs = null
    const r = this.req
    this.req = null
    if (r !== null) {
      try {
        r.destroy()
      } catch (e) {
      }
    }
    hilog.info(HS_DOMAIN, HS_TAG, 'stream closed')
  }

  get isClosed(): boolean {
    return this.closed
  }
}

/** 连接测试结果。 */
export interface HarnessTestResult {
  ok: boolean
  detail: string
}

export class HarnessClient {
  /** 连接测试: GET {base}/api/state,断言 200 且 json.model 存在即在线。 */
  static test(base: string): Promise<HarnessTestResult> {
    return new Promise<HarnessTestResult>((resolve) => {
      const r = http.createHttp()
      r.request(base.replace(/\/+$/, '') + '/api/state', {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      }, (err: Error, resp: http.HttpResponse) => {
        if (err !== undefined && err !== null && err.message !== '') {
          resolve({ ok: false, detail: '不可达: ' + JSON.stringify(err).substring(0, 80) })
          return
        }
        if (resp.responseCode !== 200) {
          resolve({ ok: false, detail: '返回 ' + resp.responseCode })
          return
        }
        try {
          const obj = JSON.parse(resp.result as string) as Record<string, string>
          if (obj['model'] !== undefined) {
            resolve({ ok: true, detail: '在线 model=' + obj['model'] })
          } else {
            resolve({ ok: false, detail: '响应无 model 字段' })
          }
        } catch (e) {
          resolve({ ok: false, detail: '响应解析失败' })
        }
      })
    })
  }
}
