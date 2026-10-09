/**
 * tty7 终端会话宿主(任务 tty7-M3a,单会话桥接层,非 UI)。
 *
 * 职责:把 LocalTerminalService(单 PTY,liblocalpty.so)桥到 TermModel
 * (自研 VT 解析器),给 TermPaneView 提供静态查询口。不重造 VT、不引第二
 * 套 PTY——纯桥接(ADR-0001:M3a 复用现有资产,多实例留 M3b)。
 *
 * 排水机制照抄 TerminalPage 实勘结论(M5 relay4/r6):
 *  - tsfn 回调在该环境不交付 → 输出靠 poll() 同步拉;
 *  - setInterval 会 ~20s 静默停摆 → 自链式 setTimeout,重挂语句放 finally
 *    (drainTick 抛异常时链不死);
 *  - ptyPoll 返回 '__PTY_EOF__'(master EOF,sh exit)→ halfDead:停链 +
 *    LocalTerminalService.close + onDead 回调(vm 侧 termTick++),但 model
 *    与 boundPane 保留(pane 内历史输出可滚看);stop() 才全清。
 *
 * 幂等:start 已在跑 → 直接 true;start 失败(open 抛/false)→ false 不留
 * 半开状态。所有静态口在未 start 时均安全无抛(单测守卫覆盖)。
 */
import { TermModel } from '../../components/TermModel';
import { LocalTerminalService } from '../../service/LocalTerminalService';
import { InputHistory } from './InputHistory';

const TERM_POLL_MS: number = 100;

export class TermHost {
  private static model: TermModel | null = null
  private static timer: number = -1
  private static boundPane: string = ''
  /** PTY EOF 回调(vm 注册:termTick++ + 状态文案;不抛)。 */
  static onDead: (() => void) | null = null

  /** 启动本地会话:open PTY + 新 model + 100ms 排水链。已在跑 → true。 */
  static start(cols: number, rows: number): boolean {
    if (TermHost.model !== null && TermHost.timer >= 0) {
      return true
    }
    InputHistory.restore() // M4a:会话起时恢复输入历史(无 context 静默)
    if (!LocalTerminalService.open(cols, rows)) {
      return false
    }
    if (TermHost.model === null) {
      TermHost.model = new TermModel(cols, rows)
    }
    TermHost.startChain()
    return true
  }

  /** 记录绑定 pane(paneId;'' = 未绑)。 */
  static bind(paneId: string): void {
    TermHost.boundPane = paneId
  }

  /** 绑定 paneId 查询('' = 未绑;halfDead 后仍保留,stop 才清)。 */
  static bound(): string {
    return TermHost.boundPane
  }

  /** 当前终端模型(未 start / 已 stop → null;halfDead 仍非 null)。 */
  static term(): TermModel | null {
    return TermHost.model
  }

  /** 会话输入(→ PTY;未开时 LocalTerminalService 内部守卫 no-op)。 */
  static write(text: string): void {
    LocalTerminalService.write(text)
  }

  /** 尺寸同步(model 网格 + PTY winsize;未开时后者内部守卫)。 */
  static resize(cols: number, rows: number): void {
    if (TermHost.model === null) {
      return
    }
    TermHost.model.resize(cols, rows)
    LocalTerminalService.resize(cols, rows)
  }

  /** 全清:停链 + PTY 关 + model 置空 + 解绑。未 start 时安全 no-op。 */
  static stop(): void {
    if (TermHost.timer >= 0) {
      clearTimeout(TermHost.timer)
      TermHost.timer = -1
    }
    TermHost.onDead = null
    InputHistory.persist() // M4a:会话停时封存输入历史(无 context 静默)
    if (LocalTerminalService.active()) {
      LocalTerminalService.close()
    }
    TermHost.model = null
    TermHost.boundPane = ''
  }

  /** 单拍排空:poll 一块 → model.feed。UI 交互后同步 kick 复用(TermPaneView)。 */
  static drainOnce(): void {
    if (TermHost.model === null) {
      return
    }
    const chunk = LocalTerminalService.poll()
    if (chunk.length === 0) {
      return
    }
    if (chunk === '__PTY_EOF__') {
      TermHost.stopChain()
      LocalTerminalService.close()
      if (TermHost.onDead !== null) {
        try {
          TermHost.onDead()
        } catch (e) {
          // 回调不得反向杀状态
        }
      }
      return
    }
    TermHost.model.feed(chunk)
  }

  private static startChain(): void {
    // 自链式 setTimeout(TerminalPage M5 relay6 实勘:setInterval ~20s 停摆;
    // 重挂必须放 finally,drainOnce 抛异常时链不断)。
    const tickFn = (): void => {
      try {
        TermHost.drainOnce()
      } catch (e) {
        // 排水异常不杀链
      } finally {
        TermHost.timer = setTimeout(tickFn, TERM_POLL_MS)
      }
    }
    TermHost.timer = setTimeout(tickFn, TERM_POLL_MS)
  }

  private static stopChain(): void {
    if (TermHost.timer >= 0) {
      clearTimeout(TermHost.timer)
      TermHost.timer = -1
    }
  }
}
