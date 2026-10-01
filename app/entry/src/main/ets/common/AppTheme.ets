// 一站AI终端(One AI Term)自有主题色板 —— M6 relay2 品牌差异化定案
// 深色: 深夜蓝紫底 + 琥珀 brand;浅色: 暖白底 + 深琥珀 brand(可读性)。
// 字段语义: surface=全局底/surfaceRaised=浮层/panel=面板/hover=悬停/ink=主文/inkSubtle=次文/
// brand=品牌色/hairline=发丝线;success/warn/danger/inputBg/iconMuted 保留 relay1 语义。
export class AppTheme {
  surface: number
  surfaceRaised: number
  panel: number
  hover: number
  ink: number
  inkSubtle: number
  brand: number
  hairline: number
  success: number
  warn: number
  danger: number
  inputBg: number
  iconMuted: number
  iconStrong: number

  constructor(surface: number, surfaceRaised: number, panel: number, hover: number,
    ink: number, inkSubtle: number, brand: number, hairline: number,
    success: number, warn: number, danger: number, inputBg: number, iconMuted: number,
    iconStrong: number) {
    this.surface = surface
    this.surfaceRaised = surfaceRaised
    this.panel = panel
    this.hover = hover
    this.ink = ink
    this.inkSubtle = inkSubtle
    this.brand = brand
    this.hairline = hairline
    this.success = success
    this.warn = warn
    this.danger = danger
    this.inputBg = inputBg
    this.iconMuted = iconMuted
    this.iconStrong = iconStrong
  }
}

// dark: 深夜蓝紫底 + 琥珀 brand(relay4: 分层亮度差拉大 ≥8%,hairline 提亮,新增 iconStrong 高对比图标色)
export const THEME_DARK: AppTheme = new AppTheme(0x0F1220, 0x1E2438, 0x232A44, 0x2A3252,
  0xE8EAF2, 0x8a90a5, 0xF5A524, 0x353D5E, 0x34d399, 0xf59e0b, 0xf87171, 0x131729, 0x9aa2b8,
  0xF2F4FA)
// light: 暖白底 + 深琥珀 brand(relay4: 分层亮度差拉大 ≥8%,hairline 加深,新增 iconStrong)
export const THEME_LIGHT: AppTheme = new AppTheme(0xFAFAF7, 0xE8E5DA, 0xEBE8DE, 0xE0DCCF,
  0x1c1c1a, 0x6b6a66, 0xD97706, 0xCFCABC, 0x108038, 0xb45309, 0xc62828, 0xF6F5F1, 0x6b6a66,
  0x26262B)

export function themeByName(name: string): AppTheme {
  if (name === 'light') {
    return THEME_LIGHT
  }
  return THEME_DARK
}
