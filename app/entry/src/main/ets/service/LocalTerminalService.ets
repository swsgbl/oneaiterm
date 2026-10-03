// 本地终端服务:liblocalpty.so(/bin/sh PTY)
// M5 relay4 fix: d.ts 原声明 class LocalPtyNapi,但 C++ 实现导出的是
// 模块级函数(ptyOpen/ptyWrite/ptyClose/ptyResize)→ 运行时 named import
// 抛 SyntaxError 崩溃(faultlog jscrash ...no export 'LocalPtyNapi')。
// 另:该环境 tsfn 异步回调不交付(根因未深究),增加 ptyPoll 同步读通道,
// TerminalPage 的 drainTick 每 100ms 调 LocalTerminalService.poll()。
import { ptyOpen, ptyWrite, ptyClose, ptyResize, ptyPoll } from 'liblocalpty.so';
import { SessionService } from './SessionService';

export class LocalTerminalService {
  private static opened: boolean = false

  static active(): boolean {
    return LocalTerminalService.opened
  }

  static open(cols: number, rows: number): boolean {
    if (LocalTerminalService.opened) {
      return true
    }
    try {
      ptyOpen(cols, rows, (text: string): void => {
        SessionService.feedExternal(text)
      })
      LocalTerminalService.opened = true
      // M8 relay2: bridge into SessionService so agent term_write/term_read
      // reach this PTY (hasSession()/write() previously ignored local PTY).
      SessionService.attachLocalPty((t: string): void => {
        LocalTerminalService.write(t)
      })
      return true
    } catch (e) {
      return false
    }
  }

  static write(text: string): void {
    if (LocalTerminalService.opened) {
      ptyWrite(text)
    }
  }

  static resize(cols: number, rows: number): void {
    if (LocalTerminalService.opened) {
      ptyResize(cols, rows)
    }
  }

  static poll(): string {
    if (!LocalTerminalService.opened) {
      return ''
    }
    try {
      return ptyPoll()
    } catch (e) {
      return ''
    }
  }

  static close(): void {
    if (LocalTerminalService.opened) {
      ptyClose()
      LocalTerminalService.opened = false
      // M8 relay2: detach the bridge so hasSession() reflects reality.
      SessionService.attachLocalPty(null)
      AppStorage.setOrCreate('ut.term.status', 'disconnected')
    }
  }
}
