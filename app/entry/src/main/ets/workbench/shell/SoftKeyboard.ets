/**
 * 屏幕软键盘(R4g 确定性输入通路)。
 *
 * 背景:VM 的物理/合成键盘链路(输入服务→焦点树→IME)多轮修复后仍不可靠
 * (合成注入系统级死亡、IME 断连、焦点路由不稳),而点击通道在全部历史
 * 验收中 100% 可达。本组件把「打字」降维成「点击」:每个键 onClick →
 * vm.sendToFocusedPane(seq) —— 与物理键盘同一 shell 会话(web 桥/降级
 * PTY/远程 SSH/telnet 统一路由),彻底绕开键盘子系统。
 *
 * 布局:数字行+三行字母(⇧ 大小写)+控制行(Esc/Tab/Ctrl 组合/方向)+空格行。
 * 键表为纯数据(skSeqOf/skLetterRows 单测靶);组件零业务路由(全走 vm)。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { tr } from '../../common/AppI18n';
import { fsc } from '../../common/UiFont';

/** 键标签 → 发送序列(控制/功能键;纯函数,单测靶)。 */
export function skSeqOf(label: string): string {
  if (label === '⌫') {
    return '\x7f'
  }
  if (label === 'Enter') {
    return '\r'
  }
  if (label === 'Tab') {
    return '\t'
  }
  if (label === 'Esc') {
    return '\x1b'
  }
  if (label === '←') {
    return '\x1b[D'
  }
  if (label === '→') {
    return '\x1b[C'
  }
  if (label === '↑') {
    return '\x1b[A'
  }
  if (label === '↓') {
    return '\x1b[B'
  }
  if (label === 'Ctrl-C') {
    return '\x03'
  }
  if (label === 'Ctrl-D') {
    return '\x04'
  }
  if (label === 'Ctrl-L') {
    return '\x0c'
  }
  if (label === '␣') {
    return ' '
  }
  return label
}

/** 字母行键表(小写;⇧ 时由组件按码位转大写展示)。 */
export function skLetterRows(): string[][] {
  return [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm']
  ]
}

/** 数字/符号行键表(shift 无关,恒定)。 */
export function skDigitRow(): string[] {
  return ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '.', '/']
}

/** 字母行两侧常量符号(补齐行宽视觉;shift 无关)。 */
export function skSymbolEdges(): string[][] {
  return [
    ['[', ']'],
    [';', '\'', '\\', '`'],
    [',', '~', '|']
  ]
}

@Component
export struct SoftKeyboard {
  @StorageProp('ut.fontScale') fontScale: number = 1
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  /** ⇧ 大写锁定(仅字母行;符号行恒定,行为可预期)。 */
  @State shift: boolean = false

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 展示标签:字母按 ⇧ 转大写,其余原样。 */
  private labelOf(k: string): string {
    if (this.shift && k.length === 1 && k >= 'a' && k <= 'z') {
      return k.toUpperCase()
    }
    return k
  }

  /** 发送序列:字母按 ⇧ 取实际大小写字符,功能键查表。 */
  private seqOf(k: string): string {
    if (k.length === 1 && k >= 'a' && k <= 'z') {
      return this.shift ? k.toUpperCase() : k
    }
    return skSeqOf(k)
  }

  private tap(k: string): void {
    if (k === '⇧') {
      this.shift = !this.shift
      return
    }
    const sent = this.vm.sendToFocusedPane(this.seqOf(k))
    if (!sent && this.vm.focusedPane === '') {
      this.vm.toast(tr(this.locale, 'kb.nofocus'))
    }
  }

  /** 普通键位(等宽,layoutWeight 1)。 */
  @Builder
  charKey(k: string) {
    Text(this.labelOf(k))
      .fontSize(fsc(this.fontScale, 13))
      .fontColor(this.th().ink)
      .height(30)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(DesignTokens.RADIUS_SM)
      .backgroundColor(this.th().inputBg)
      .border({ width: 1, color: this.th().hairline })
      .onClick(() => this.tap(k))
  }

  /** 功能键(窄标签,等宽)。 */
  @Builder
  fnKey(k: string) {
    Text(k)
      .fontSize(fsc(this.fontScale, 12))
      .fontColor(this.th().brand)
      .height(30)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(DesignTokens.RADIUS_SM)
      .backgroundColor(this.th().inputBg)
      .border({ width: 1, color: this.th().hairline })
      .onClick(() => this.tap(k))
  }

  build() {
    Column({ space: 4 }) {
      // 标题行:说明 + 收起
      Row({ space: DesignTokens.SPACE_SM }) {
        Text('⌨ ' + tr(this.locale, 'sk.title'))
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontColor(this.th().inkSubtle)
          .layoutWeight(1)
          .maxLines(1)
        Text('✕')
          .fontSize(fsc(this.fontScale, DesignTokens.FONT_CAPTION))
          .fontColor(this.th().inkSubtle)
          .width(22)
          .height(18)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText(tr(this.locale, 'sk.close'))
          .onClick(() => {
            this.vm.softKbOpen = false
          })
      }
      .width('100%')

      // 数字/符号行 + 退格
      Row({ space: 4 }) {
        ForEach(skDigitRow(), (k: string) => {
          this.charKey(k)
        }, (k: string) => 'd' + k)
        this.fnKey('⌫')
      }
      .width('100%')

      // 字母三行(两侧常量符号补齐)
      ForEach(skLetterRows(), (row: string[], ri: number) => {
        Row({ space: 4 }) {
          ForEach(row, (k: string) => {
            this.charKey(k)
          }, (k: string) => 'L' + k + (this.shift ? 'S' : 's'))
          ForEach(skSymbolEdges()[ri], (k: string) => {
            this.charKey(k)
          }, (k: string) => 'E' + k)
          if (ri === 2) {
            this.fnKey('Enter')
          }
        }
        .width('100%')
      }, (row: string[], ri: number) => 'row' + ri.toString() + (this.shift ? 'S' : 's'))

      // 控制行:Esc/Tab/Ctrl 组合/方向键
      Row({ space: 4 }) {
        Text('⇧')
          .fontSize(fsc(this.fontScale, 13))
          .fontColor(this.shift ? this.th().surface : this.th().brand)
          .height(30)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .backgroundColor(this.shift ? this.th().brand : this.th().inputBg)
          .border({ width: 1, color: this.th().hairline })
          .onClick(() => this.tap('⇧'))
        this.fnKey('Esc')
        this.fnKey('Tab')
        this.fnKey('Ctrl-C')
        this.fnKey('Ctrl-D')
        this.fnKey('Ctrl-L')
        this.fnKey('←')
        this.fnKey('↑')
        this.fnKey('↓')
        this.fnKey('→')
      }
      .width('100%')

      // 空格行
      Row({ space: 4 }) {
        Text('␣')
          .fontSize(fsc(this.fontScale, 13))
          .fontColor(this.th().inkSubtle)
          .height(30)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .backgroundColor(this.th().inputBg)
          .border({ width: 1, color: this.th().hairline })
          .onClick(() => this.tap('␣'))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: 6, bottom: 8 })
    .backgroundColor(this.th().surfaceRaised)
    .border({ width: { top: 1 }, color: this.th().hairline })
  }
}
