/**
 * 界面字号缩放(GUI-R3,用户指令「设置里可调界面字体」)。
 *
 * 机制:AppStorage 'ut.fontScale'(0.9/1.0/1.15/1.3,设置面板 pill 写入,
 * filesDir/uifont.txt 持久化由 Index 回放);组件侧
 * `.fontSize(fsc(this.fontScale, DesignTokens.FONT_X))` —— 表达式直读
 * @StorageProp fontScale 建立追踪,切换即时全局重渲(同 ut.locale 模式)。
 * 纯函数 fsc 为单测靶;终端网格(TermPaneView)不缩放(等宽栅格数学)。
 */

/** 缩放档位白名单(设置 pill 与持久化归一共用)。 */
export function fontScaleOf(raw: number): number {
  if (raw >= 1.29) {
    return 1.3
  }
  if (raw >= 1.14) {
    return 1.15
  }
  if (raw >= 0.95) {
    return 1.0
  }
  return 0.9
}

/** 字号缩放(纯,单测靶):px × scale 四舍五入;钳制 0.5~2.0 防御。 */
export function fsc(scale: number, px: number): number {
  const s = scale < 0.5 ? 1.0 : (scale > 2.0 ? 1.0 : scale)
  return Math.round(px * s)
}

/** 应用缩放档(AppStorage 写;持久化由 Index 注入钩子)。 */
export function applyFontScale(scale: number): number {
  const s = fontScaleOf(scale)
  AppStorage.setOrCreate('ut.fontScale', s)
  return s
}

/** 持久化钩子(Index 注入 filesDir/uifont.txt 写)。 */
let fontPersistHook: ((s: number) => void) | null = null

export function bindFontPersist(fn: ((s: number) => void) | null): void {
  fontPersistHook = fn
}

/** 设置面板用:写档位 + 持久化。 */
export function setFontScale(scale: number): number {
  const s = applyFontScale(scale)
  const fn = fontPersistHook
  if (fn !== null) {
    try {
      fn(s)
    } catch (e) {
      // 持久化失败不阻塞会话内生效
    }
  }
  return s
}
