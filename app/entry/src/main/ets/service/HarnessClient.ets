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
  private token: string = ''
  private cbs: HarnessEventCbs | null = null
  private closed: boolean = false
  private firstChunkLogged: boolean = false

  constructor(base: string, token: string = '') {
    this.base = base.replace(/\/+$/, '')
    this.token = token
  }

  /** 建立 SSE 长连接(GET /api/events, Accept: text/event-stream)。 */
  connect(cbs: HarnessEventCbs): void {
    this.cbs = cbs
    this.closed = false
    this.req = http.createHttp()
    this.firstChunkLogged = false
    this.req.on('dataReceive', (buf: ArrayBuffer) => {
      if (!this.firstChunkLogged) {
        this.firstChunkLogged = true
        hilog.info(HS_DOMAIN, HS_TAG, 'sse first chunk bytes=%{public}d', buf.byteLength)
      }
      this.onBytes(buf)
    })
    this.req.on('dataEnd', () => {
      hilog.info(HS_DOMAIN, HS_TAG, 'stream dataEnd lastId=%{public}d', this.lastId)
      this.emitMessage()
      if (this.cbs !== null) {
        this.cbs.onEnd()
      }
    })
    const header: Record<string, string> = { 'Accept': 'text/event-stream' };
    // Last-Event-ID 仅在有效(>=0)时携带;-1 属于未收到任何事件,发送负值头无契约依据(M8 relay13 实勘)
    if (this.lastId >= 0) {
      header['Last-Event-ID'] = this.lastId.toString();
    }
    if (this.token !== '') {
      header['X-Hmh-Key'] = this.token;
    }
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 15000,
      readTimeout: 600000
    }
    hilog.info(HS_DOMAIN, HS_TAG, 'sse opening %{public}s/api/events', this.base)
    this.req.requestInStream(this.base + '/api/events', opts, (err: Error, code: number) => {
      hilog.info(HS_DOMAIN, HS_TAG, 'sse cb err=%{public}s code=%{public}d',
        err === undefined || err === null ? '-' : (err.message === '' ? 'empty-msg' : err.message), code)
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(HS_DOMAIN, HS_TAG, 'stream start fail err=%{public}s', err instanceof Error ? err.message : String(err))
        if (this.cbs !== null) {
          this.cbs.onError('连接失败: ' + (err instanceof Error ? err.message : String(err)).substring(0, 120))
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
    let i = 0
    while (i < u8.length) {
      const b = u8[i]
      if (b < 0x80) {
        out += String.fromCharCode(b)
        i++
      } else if (b < 0xC0) {
        i++
      } else if (b < 0xE0) {
        if (i + 1 < u8.length) {
          out += String.fromCharCode(((b & 0x1F) << 6) | (u8[i + 1] & 0x3F))
          i += 2
        } else {
          i++
        }
      } else if (b < 0xF0) {
        if (i + 2 < u8.length) {
          out += String.fromCharCode(((b & 0x0F) << 12) | ((u8[i + 1] & 0x3F) << 6) | (u8[i + 2] & 0x3F))
          i += 3
        } else {
          i++
        }
      } else {
        if (i + 3 < u8.length) {
          const cp = ((b & 0x07) << 18) | ((u8[i + 1] & 0x3F) << 12) | ((u8[i + 2] & 0x3F) << 6) | (u8[i + 3] & 0x3F)
          const adj = cp - 0x10000
          out += String.fromCharCode(0xD800 + (adj >> 10))
          out += String.fromCharCode(0xDC00 + (adj & 0x3FF))
          i += 4
        } else {
          i++
        }
      }
    }
    return out
  }

  /** 发任务: POST /api/task {text,mode,fresh,sessionId}。fresh 按 daemon 契约发布尔
   *  (服务端 `body.fresh === true` 严格判等,字符串 'true' 会被当 false——M8 relay13 实勘)。失败时经 cbs.onError 上抛。 */
  send(task: string, mode: string, sessionId: string, fresh: boolean): void {
    const bodyObj: Record<string, Object> = {}
    bodyObj['text'] = task
    bodyObj['mode'] = mode
    bodyObj['fresh'] = fresh
    if (sessionId !== '') {
      bodyObj['sessionId'] = sessionId
    }
    const p = this.base + '/api/task'
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.token !== '') {
      header['X-Hmh-Key'] = this.token;
    }
    const r = http.createHttp()
    r.request(p, {
      method: http.RequestMethod.POST,
      header: header,
      extraData: JSON.stringify(bodyObj),
      connectTimeout: 15000,
      readTimeout: 30000
    }, (err: Error, resp: http.HttpResponse) => {
      if (err !== undefined && err !== null && err.message !== '') {
        hilog.error(HS_DOMAIN, HS_TAG, 'task send fail err=%{public}s', err instanceof Error ? err.message : String(err))
        if (this.cbs !== null) {
          this.cbs.onError('任务发送失败: ' + (err instanceof Error ? err.message : String(err)).substring(0, 120))
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
  static test(base: string, token: string = ''): Promise<HarnessTestResult> {
    return new Promise<HarnessTestResult>((resolve) => {
      const r = http.createHttp()
      const header: Record<string, string> = {};
      if (token !== '') {
        header['X-Hmh-Key'] = token;
      }
      r.request(base.replace(/\/+$/, '') + '/api/state', {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 8000,
        readTimeout: 8000
      }, (err: Error, resp: http.HttpResponse) => {
        if (err !== undefined && err !== null && err.message !== '') {
          resolve({ ok: false, detail: '不可达: ' + (err instanceof Error ? err.message : String(err)).substring(0, 80) })
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
