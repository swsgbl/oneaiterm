/**
 * AgentSessionStore 会话持久化（升级 Phase 1 / 任务 2.5，design 2.2.2.10）。
 *
 * - 持久化于 filesDir/agent-sessions/{sessionId}.json（每会话一文件，避免单文件增长）；
 * - AgentSessionMeta：唯一 sessionId / engine 标注（恢复时不得错配）/ state 四态
 *   （active/cancelled/finished/aborted）/ engineRef / historyDigest / title；
 * - 写后回读校验（沿用存量范式）；
 * - 状态每次流转可持久化追溯（spec 6.1.3）。
 */
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AgentEngineType, AgentSessionState } from './AgentProvider';

const TAG: string = 'oat.sessstore';
const DOMAIN: number = 0x0110;

/** 会话元数据（持久化单元）。 */
export class AgentSessionMeta {
  sessionId: string = ''
  engine: AgentEngineType = 'local'
  state: AgentSessionState = 'active'
  createdAt: number = 0
  updatedAt: number = 0
  /** 引擎侧引用（HMH Last-Event-ID / ACP session id / local hist 摘要）。 */
  engineRef: string = ''
  /** 恢复用历史上下文摘要（引擎各自格式）。 */
  historyDigest: string = ''
  /** 会话标题（首条 prompt 摘要）。 */
  title: string = ''
}

export class AgentSessionStore {
  private static dir(filesDir: string): string {
    return filesDir + '/agent-sessions'
  }

  private static path(filesDir: string, sessionId: string): string {
    return AgentSessionStore.dir(filesDir) + '/' + sessionId + '.json'
  }

  private static ensureDir(filesDir: string): boolean {
    const d = AgentSessionStore.dir(filesDir)
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d, true)
      }
      return true
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'mkdir fail %{public}s', e instanceof Error ? e.message : String(e))
      return false
    }
  }

  /** 生成唯一 sessionId（时间戳 + 随机段）。 */
  static newId(): string {
    return 's' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
  }

  /** 创建会话记录（写后回读校验）。 */
  static create(filesDir: string, meta: AgentSessionMeta): string {
    if (!AgentSessionStore.ensureDir(filesDir)) {
      return ''
    }
    const p = AgentSessionStore.path(filesDir, meta.sessionId)
    let f: fs.File | null = null
    try {
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, JSON.stringify(meta))
      fs.closeSync(f)
      f = null
      const back = AgentSessionStore.read(filesDir, meta.sessionId)
      if (back === null || back.sessionId !== meta.sessionId) {
        return ''
      }
      return meta.sessionId
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'create fail %{public}s', e instanceof Error ? e.message : String(e))
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      return ''
    }
  }

  /** 更新会话记录（状态流转持久化）。 */
  static update(filesDir: string, meta: AgentSessionMeta): boolean {
    if (!AgentSessionStore.ensureDir(filesDir)) {
      return false
    }
    const p = AgentSessionStore.path(filesDir, meta.sessionId)
    let f: fs.File | null = null
    try {
      meta.updatedAt = Date.now()
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, JSON.stringify(meta))
      fs.closeSync(f)
      f = null
      const back = AgentSessionStore.read(filesDir, meta.sessionId)
      return back !== null && back.state === meta.state
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'update fail %{public}s', e instanceof Error ? e.message : String(e))
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      return false
    }
  }

  /** 读取会话元数据（不存在/损坏返回 null）。 */
  static read(filesDir: string, sessionId: string): AgentSessionMeta | null {
    const p = AgentSessionStore.path(filesDir, sessionId)
    try {
      if (!fs.accessSync(p)) {
        return null
      }
      const raw = fs.readTextSync(p)
      const obj = JSON.parse(raw) as AgentSessionMeta
      const m = new AgentSessionMeta()
      m.sessionId = obj.sessionId
      if (obj.engine === 'hmh' || obj.engine === 'acp' || obj.engine === 'local') {
        m.engine = obj.engine
      }
      if (obj.state === 'active' || obj.state === 'cancelled' || obj.state === 'finished' || obj.state === 'aborted') {
        m.state = obj.state
      }
      m.createdAt = obj.createdAt
      m.updatedAt = obj.updatedAt
      m.engineRef = obj.engineRef
      m.historyDigest = obj.historyDigest
      m.title = obj.title
      if (m.sessionId === '') {
        return null
      }
      return m
    } catch (e) {
      return null
    }
  }

  /** 列出会话（按 state 过滤；updatedAt 降序）。 */
  static list(filesDir: string, state: AgentSessionState | 'all'): AgentSessionMeta[] {
    const out: AgentSessionMeta[] = []
    const d = AgentSessionStore.dir(filesDir)
    try {
      if (!fs.accessSync(d)) {
        return out
      }
      const names: string[] = fs.listFileSync(d)
      for (const n of names) {
        if (!n.endsWith('.json')) {
          continue
        }
        const m = AgentSessionStore.read(filesDir, n.substring(0, n.length - 5))
        if (m !== null && (state === 'all' || m.state === state)) {
          out.push(m)
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list fail %{public}s', e instanceof Error ? e.message : String(e))
    }
    out.sort((a: AgentSessionMeta, b: AgentSessionMeta): number => b.updatedAt - a.updatedAt)
    return out
  }

  /** 删除会话记录。 */
  static remove(filesDir: string, sessionId: string): void {
    try {
      const p = AgentSessionStore.path(filesDir, sessionId)
      if (fs.accessSync(p)) {
        fs.unlinkSync(p)
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove fail %{public}s', e instanceof Error ? e.message : String(e))
    }
  }
}