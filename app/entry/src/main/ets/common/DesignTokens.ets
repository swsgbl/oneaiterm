// DesignTokens — 字体/间距/圆角/阴影/动画 令牌体系
// 5 级字体令牌
export class DesignTokens {
  static readonly FONT_DISPLAY: number = 18
  static readonly FONT_HEADING: number = 15
  static readonly FONT_BODY: number = 12
  static readonly FONT_CAPTION: number = 10
  static readonly FONT_LABEL: number = 9

  // 5 级间距令牌
  static readonly SPACE_XS: number = 4
  static readonly SPACE_SM: number = 8
  static readonly SPACE_MD: number = 12
  static readonly SPACE_LG: number = 16
  static readonly SPACE_XL: number = 24

  // 4 级圆角令牌
  static readonly RADIUS_SM: number = 4
  static readonly RADIUS_MD: number = 8
  static readonly RADIUS_LG: number = 12
  static readonly RADIUS_XL: number = 16

  // 3 级阴影令牌
  static readonly SHADOW_SM_RADIUS: number = 8
  static readonly SHADOW_SM_OFFSET_Y: number = 2
  static readonly SHADOW_SM_COLOR: number = 0x33000000
  static readonly SHADOW_MD_RADIUS: number = 16
  static readonly SHADOW_MD_OFFSET_Y: number = 4
  static readonly SHADOW_MD_COLOR: number = 0x55000000
  static readonly SHADOW_LG_RADIUS: number = 24
  static readonly SHADOW_LG_OFFSET_Y: number = 8
  static readonly SHADOW_LG_COLOR: number = 0x66000000

  // 3 级动画令牌
  static readonly DURATION_FAST: number = 150
  static readonly DURATION_NORMAL: number = 300
  static readonly DURATION_SLOW: number = 500
}