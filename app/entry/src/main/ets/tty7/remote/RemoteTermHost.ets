/**
 * tty7 远程终端会话宿主(任务 tty7-M6a,单 SSH 会话桥接层,非 UI)。
 *
 * 镜像 tty7/term/TermHost(本地宿主):静态单会话 + boundPane + onDead。
 * 差异(实勘结论):
 *  - SSH 数据是 SessionService TermView.accept 回调推送(非 PTY poll)
 *    → dataSink 直 feed model,无排水链;
 *  - 断线/错误经 provider 内部状态观察链(SshWorkspaceProvider)→ onDead,
 *    宿主不再自持 timer;
 *  - start 同步签名对齐 TermHost:true 仅代表已发起(connect 异步进行中,
 *    失败经 onEvent('error')→ onDead 异步到,vm 侧清 slot 防幽灵)。
 *
 * halfDead 语义同 TermHost:远程死时 model 与 boundPane 保留(pane 内
 * 历史输出可滚看),stop() 才全清。
 */
import { TermModel } from '../../components/TermModel';
import { SshWorkspaceProvider, RemoteSessionHandle } from './RemoteWorkspaceProvider';

export class RemoteTermHost {
  private static model: TermModel | null = null
  private static boundPane: string = ''
  private static handle: RemoteSessionHandle | null = null
  /** 远程死亡回调(vm 注册:清 slot + termTick++;不抛)。 */
  static onDead: (() => void) | null = null
  /** 连接建立回调(M6b:vm 注册 statusText 'ssh 已连接';不抛;可空)。 */
  static onOpen: (() => void) | null = null
  /** 最近一次错误原因(诊断用;不含凭据——只有 connKey 与错误文本)。 */
  static lastError: string = ''
  /** 数据旁路订阅口(+tty7-M7a:feed TermModel 的同时复制给 tap;
   *  单订阅口,置 null 摘除;runner 标记法收集用,不碰渲染)。 */
  private static tap: ((text: string) => void) | null = null

  /** 启动远程会话:SshWorkspaceProvider.open 成功建句柄即 true(连接异步)。 */
  static start(connKey: string, cols: number, rows: number): boolean {
    RemoteTermHost.lastError = ''
    const h = SshWorkspaceProvider.open(connKey, cols, rows, (ev: string, data: string): void => {
      if (ev === 'error') {
        RemoteTermHost.lastError = data
      }
      if (ev === 'error' || ev === 'closed') {
        // connect 失败/断线:通知 vm 清 slot(stop 由 onDead 路径统一做)
        const cb = RemoteTermHost.onDead
        if (cb !== null) {
          try {
            cb()
          } catch (e) {
            // 回调不得反向杀状态
          }
        }
      }
      // 'open' 事件:数据经 dataSink 自然流;M6b:通知 vm 连接已建立
      if (ev === 'open') {
        const cb = RemoteTermHost.onOpen
        if (cb !== null) {
          try {
            cb()
          } catch (e) {
            // 回调不得反向杀状态
          }
        }
      }
    })
    if (h === null) {
      return false
    }
    RemoteTermHost.handle = h
    RemoteTermHost.model = new TermModel(cols, rows)
    h.dataSink = (t: string): void => {
      const m = RemoteTermHost.model
      if (m !== null) {
        m.feed(t)
      }
      const tap = RemoteTermHost.tap // +tty7-M7a: 旁路复制(不碰渲染)
      if (tap !== null) {
        try {
          tap(t)
        } catch (e) {
          // tap 异常不得杀主链
        }
      }
    }
    h.onClosed = (): void => {
      // 主动 close():model 保留由 stop() 决定,这里只防幽灵(无动作)
    }
    return true
  }

  /** 记录绑定 pane(paneId;'' = 未绑)。 */
  static bind(paneId: string): void {
    RemoteTermHost.boundPane = paneId
  }

  /** 绑定 paneId 查询('' = 未绑;halfDead 后仍保留,stop 才清)。 */
  static bound(): string {
    return RemoteTermHost.boundPane
  }

  /** 当前终端模型(未 start / 已 stop → null;halfDead 仍非 null)。 */
  static term(): TermModel | null {
    return RemoteTermHost.model
  }

  /** 会话输入(→ SSH stdin;句柄内部 owner 守卫,死后 no-op)。 */
  static write(text: string): void {
    const h = RemoteTermHost.handle
    if (h !== null) {
      h.write(text)
    }
  }

  /** 尺寸同步(model 网格 + 远程 PTY;未开时句柄内部守卫)。 */
  static resize(cols: number, rows: number): void {
    if (RemoteTermHost.model === null) {
      return
    }
    RemoteTermHost.model.resize(cols, rows)
    const h = RemoteTermHost.handle
    if (h !== null) {
      h.resize(cols, rows)
    }
  }

  /** 数据旁路订阅(+tty7-M7a:runner 标记法收集口;单订阅,null 摘除)。 */
  static tapData(fn: ((text: string) => void) | null): void {
    RemoteTermHost.tap = fn
  }

  /** 全清:关句柄 + model 置空 + 解绑。未 start 时安全 no-op。
   *  注意:不置空 onDead(与 TermHost 不同)——vm 的 onDead 回调内部会调
   *  stop(),置空会丢后续远程会话的死亡通知(connect 失败 → 幽灵 slot);
   *  回调由 vm 构造注册、app 生命周期持有,无泄漏。 */
  static stop(): void {
    const h = RemoteTermHost.handle
    RemoteTermHost.handle = null
    if (h !== null) {
      h.close()
    }
    RemoteTermHost.model = null
    RemoteTermHost.boundPane = ''
    RemoteTermHost.tap = null // +tty7-M7a: 会话终结摘旁路(tap 悬空防幽灵回调)
  }
}
