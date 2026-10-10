/**
 * tty7 远程工作区 Provider(任务 tty7-M6a,SSH 单会话桥接层,非 UI)。
 *
 * 职责:把 SessionService(静态单 SSH 会话,只读调用)桥成
 * RemoteSessionHandle 生命周期对象,给 RemoteTermHost 提供宿主语义。
 * 红线:service//store/ 零改动;凭据只经 getSharedStore() 内存解密态流动
 * (绝不重新 load()——磁盘是 enc:v1 密文);slot/事件/日志只见 connKey。
 *
 * 实勘结论(CONTINUE-M6a):
 *  - SSH 数据到达方式=SessionService TermView.accept 回调推送(非 poll)
 *    → 内部 ProviderTermView 把数据引到 handle.dataSink(免排水链);
 *  - connect() async,失败 throw(不回调);closed/error 事件只写 AppStorage
 *    'ut.term.status'(无回调口)→ open 成功后起 100ms 自链 setTimeout 轮询
 *    status(VM 内 setInterval ~20s 停摆,自链 + finally 重挂照抄 TermHost);
 *  - 单会话语义:谁后开谁占——open 前 hasSession() 先 close(本地 tty7 会话
 *    由 vm 层先 unbindTerm,provider 兜底)。
 */
import type { TermModel } from '../../components/TermModel';
import { SessionService, TermView } from '../../service/SessionService';
import { getSharedStore, ConnRec } from '../../store/ConnStore';

const STATUS_POLL_MS: number = 100;

/** 远程会话句柄(生命周期 + IO;宿主赋 dataSink/onClosed)。 */
export interface RemoteSessionHandle {
  kind: string
  connKey: string
  title: string
  write(text: string): void
  resize(cols: number, rows: number): void
  close(): void
  dataSink: (text: string) => void
  onClosed: () => void
}

/** provider 内部 TermView:SessionService 推送 → handle.dataSink(直 feed)。 */
class ProviderTermView implements TermView {
  private h: SshRemoteHandle

  constructor(h: SshRemoteHandle) {
    this.h = h
  }

  accept(raw: string): void {
    this.h.dataSink(raw)
  }

  modelOf(): TermModel | null {
    return null // agent 屏读不在 M6a 范围(dataSink 已喂宿主侧 model)
  }
}

/**
 * SSH 会话句柄实现。owner 标志守护生命周期:close()(主动)与 die()(远程
 * 死亡,状态链发现)互斥一次;两者均停链 + fire onClosed(置空防重入)。
 */
class SshRemoteHandle implements RemoteSessionHandle {
  kind: string = 'ssh'
  connKey: string = ''
  title: string = ''
  dataSink: (text: string) => void = (_t: string): void => {
  }
  onClosed: () => void = (): void => {
  }
  private owner: boolean = true
  private pollTimer: number = -1
  private view: ProviderTermView
  private notify: (ev: string, data: string) => void

  constructor(connKey: string, title: string, notify: (ev: string, data: string) => void) {
    this.connKey = connKey
    this.title = title
    this.notify = notify
    this.view = new ProviderTermView(this)
  }

  /** open 内部用:注册数据视图(attachView 只认最后注册者)。 */
  attach(): void {
    SessionService.attachView(this.view)
  }

  write(text: string): void {
    if (!this.owner) {
      return
    }
    SessionService.write(text)
  }

  resize(cols: number, rows: number): void {
    if (!this.owner) {
      return
    }
    SessionService.resize(cols, rows)
  }

  /** connect 成功后调:起状态观察链(自链 setTimeout,重挂放 finally)。 */
  startWatch(): void {
    if (!this.owner) {
      return
    }
    const tickFn = (): void => {
      try {
        this.checkStatus()
      } catch (e) {
        // 观察异常不杀链
      } finally {
        if (this.owner) {
          this.pollTimer = setTimeout(tickFn, STATUS_POLL_MS)
        }
      }
    }
    this.pollTimer = setTimeout(tickFn, STATUS_POLL_MS)
  }

  /** 主动关(单会话让位/pane 关闭):幂等,重入 no-op。 */
  close(): void {
    if (!this.owner) {
      return
    }
    this.owner = false
    this.stopTimer()
    if (SessionService.hasSession()) {
      SessionService.close()
    }
    SessionService.attachView(null)
    SshWorkspaceProvider.release(this)
    this.fireClosed()
  }

  /** connect 失败入口(provider open 的 catch 调):error 事件 + 清理。 */
  fail(reason: string): void {
    this.die('error', reason)
  }

  /** 远程侧死亡(状态链发现):与 close 同构,不重复 close 会话(已死)。 */
  private die(ev: string, reason: string): void {
    if (!this.owner) {
      return
    }
    this.owner = false
    this.stopTimer()
    SessionService.attachView(null)
    SshWorkspaceProvider.release(this)
    this.notify(ev, reason)
    this.fireClosed()
  }

  private fireClosed(): void {
    const cb = this.onClosed
    this.onClosed = (): void => {
    }
    if (cb !== null) {
      try {
        cb()
      } catch (e) {
        // 回调不得反向杀状态
      }
    }
  }

  private checkStatus(): void {
    if (!this.owner) {
      return
    }
    const st = AppStorage.get<string>('ut.term.status')
    if (st === 'disconnected') {
      this.die('closed', '')
    } else if (st === 'error') {
      this.die('error', AppStorage.get<string>('ut.term.reason') ?? '')
    }
  }

  private stopTimer(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer)
      this.pollTimer = -1
    }
  }
}

/** SSH 工作区 Provider(静态单会话,只读调用 SessionService)。 */
export class SshWorkspaceProvider {
  private static cur: SshRemoteHandle | null = null

  /** 是否有本 provider 打开的活句柄。 */
  static active(): boolean {
    return SshWorkspaceProvider.cur !== null
  }

  /**
   * 打开 SSH 会话:同步返回句柄占位(connect 异步补判,成败经 onEvent)。
   * 失败(store 未就绪/无记录)同步 null + onEvent('error', 原因)。
   */
  static open(connKey: string, cols: number, rows: number,
    onEvent: (ev: string, data: string) => void): RemoteSessionHandle | null {
    const store = getSharedStore()
    if (store === null) {
      onEvent('error', '连接库未就绪(先在旧界面打开连接列表)')
      return null
    }
    let conn: ConnRec | null = null
    for (const c of store.connections) {
      if (c.id === connKey) {
        conn = c
        break
      }
    }
    if (conn === null) {
      onEvent('error', '无连接记录 ' + connKey)
      return null
    }
    // 单会话语义:谁后开谁占(旧界面同义);本地 tty7 会话由 vm 层先解绑
    if (SessionService.hasSession()) {
      SessionService.close()
    }
    const h = new SshRemoteHandle(connKey, conn.name, onEvent)
    h.attach()
    SshWorkspaceProvider.cur = h
    SessionService.connect(conn, cols, rows)
      .then((id: number): void => {
        try {
          store.markUsed(connKey) // best-effort(照抄 TerminalPage)
        } catch (e) {
          // 记账失败不杀会话
        }
        onEvent('open', id.toString())
        h.startWatch()
      })
      .catch((e: Object): void => {
        const msg = e instanceof Error ? e.message : String(e)
        h.fail(msg) // 内部 onEvent+onClosed:vm 侧清 slot 防幽灵
      })
    return h
  }

  /** provider open 的 catch 调:句柄注销(handle 不暴露 public release)。 */
  static release(h: RemoteSessionHandle): void {
    if (SshWorkspaceProvider.cur === h) {
      SshWorkspaceProvider.cur = null
    }
  }
}
