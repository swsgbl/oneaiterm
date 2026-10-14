/**
 * tty7 Telnet 会话宿主(任务 tty7-LEG-2;TelnetService 的 tty7 桥接层,非 UI)。
 *
 * 镜像 RemoteTermHost(SSH)三件套:静态单会话 + boundPane + onDead/onOpen。
 * 数据路径:TelnetService 收包 → onData 旁路 → 本宿主 feed TermModel
 * (TelnetService 原有 SessionService.feedExternal 路径仅在无旁路时走,
 * 旧界面零改动);输入 → write → TelnetService.write(socket send)。
 * IAC 协商过滤/编码由 TelnetService 原样承担(不在本层重复)。
 * 红线:旁路回调不触日志;lastError 只存错误文本(不含凭据)。
 */
import { TermModel } from '../../components/TermModel';
import { TelnetService } from '../../service/TelnetService';

export class TelTermHost {
  private static model: TermModel | null = null
  private static boundPane: string = ''
  private static host: string = ''
  private static port: number = 0
  /** 会话死亡回调(vm 注册:清 slot + termTick++;不抛)。 */
  static onDead: (() => void) | null = null
  /** 连接建立回调(vm 注册 statusText;不抛;可空)。 */
  static onOpen: (() => void) | null = null
  /** 最近一次错误原因(诊断用;只存文本,不含凭据)。 */
  static lastError: string = ''

  /** 启动 telnet 会话:true 仅代表已发起(connect 异步,失败经 onDead 到)。
   *  首次 start 挂旁路;telnet kind 固定(TelKind='telnet')。 */
  static start(host: string, port: number, cols: number, rows: number): boolean {
    TelTermHost.lastError = ''
    TelTermHost.host = host
    TelTermHost.port = port
    TelTermHost.model = new TermModel(cols, rows)
    TelnetService.onData((text: string): void => {
      const m = TelTermHost.model
      if (m !== null) {
        m.feed(text)
      }
    })
    TelnetService.onEvent((ev: string, data: string): void => {
      if (ev === 'error') {
        TelTermHost.lastError = data.length > 60 ? data.substring(0, 60) : data
        TelTermHost.notifyDead()
      } else if (ev === 'closed') {
        TelTermHost.notifyDead()
      } else if (ev === 'open') {
        const cb = TelTermHost.onOpen
        if (cb !== null) {
          try {
            cb()
          } catch (e) {
          }
        }
      }
    })
    TelnetService.connect('telnet', host, port).catch((e: Object): void => {
      // connect reject(网络不可达/参数错)→ 统一走 onDead 通道
      TelTermHost.lastError = e instanceof Error ? e.message : String(e)
      TelTermHost.notifyDead()
    })
    return true
  }

  private static notifyDead(): void {
    const cb = TelTermHost.onDead
    if (cb !== null) {
      try {
        cb()
      } catch (e) {
        // 回调不得反向杀状态
      }
    }
  }

  /** 记录绑定 pane(paneId;'' = 未绑)。 */
  static bind(paneId: string): void {
    TelTermHost.boundPane = paneId
  }

  /** 绑定 paneId 查询('' = 未绑;halfDead 后仍保留,stop 才清)。 */
  static bound(): string {
    return TelTermHost.boundPane
  }

  /** 当前终端模型(未 start / 已 stop → null;halfDead 仍非 null)。 */
  static term(): TermModel | null {
    return TelTermHost.model
  }

  /** 目标地址摘要(诊断展示;无凭据)。 */
  static endpoint(): string {
    return TelTermHost.host + ':' + TelTermHost.port.toString()
  }

  /** 会话输入(→ TelnetService socket send;未连时内部 no-op)。 */
  static write(text: string): void {
    TelnetService.write(text)
  }

  /** 尺寸同步(model 网格;telnet 无 RFC 远程 resize 通知,只调本地)。 */
  static resize(cols: number, rows: number): void {
    if (TelTermHost.model !== null) {
      TelTermHost.model.resize(cols, rows)
    }
  }

  /** 全清:断 socket + model 置空 + 解绑 + 摘旁路。未 start 时安全 no-op。
   *  onDead/onOpen 不置空(同 RemoteTermHost 语义:vm 回调长生命周期持有)。 */
  static stop(): void {
    TelnetService.disconnect().catch(() => {
    })
    TelnetService.onData(null)
    TelnetService.onEvent(null)
    TelTermHost.model = null
    TelTermHost.boundPane = ''
  }
}
