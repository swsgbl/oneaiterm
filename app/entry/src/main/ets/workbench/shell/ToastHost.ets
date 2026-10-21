/**
 * 轻提示浮层(GUI 丝滑棒:ToastHost)。
 * AppShell Stack 顶部居中;vm.toastMsgs 数组整体替换 + toastRev 作
 * 依赖锚(V1 追踪);出入场过渡(淡入+上移/淡出)。上限 3 条由 vm 保证。
 * 零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct ToastHost {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  build() {
    if (this.vm.toastRev >= 0 && this.vm.toastMsgs.length > 0) {
      Column({ space: DesignTokens.SPACE_XS }) {
        ForEach(this.vm.toastMsgs, (msg: string, i: number) => {
          Text(msg)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.RADIUS_XL)
            .backgroundColor(this.th().surfaceRaised)
            .border({ width: 1, color: this.th().hairline })
            .shadow({ radius: DesignTokens.SHADOW_SM_RADIUS, color: DesignTokens.SHADOW_LG_COLOR, offsetX: 0, offsetY: 2 })
            .maxLines(2)
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -6 })).animation({ duration: 160 }),
              TransitionEffect.OPACITY.animation({ duration: 160 })
            ))
        }, (msg: string, i: number) => 'toast#' + i.toString() + '#' + msg)
      }
      .position({ x: '50%', y: 34 })
      .translate({ x: '-50%' })
      .zIndex(60)
    }
  }
}
