/**
 * UiFont 纯函数单元测试(GUI-R3 界面字号)。
 * 覆盖:fontScaleOf 档位归一、fsc 缩放与防御钳制。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fontScaleOf, fsc } from '../../../main/ets/common/UiFont';

export default function uiFontTest() {
  describe('workbenchUiFont', () => {
    it('fontscaleof_normalizes_to_steps', 0, () => {
      expect(fontScaleOf(1.0)).assertEqual(1.0)
      expect(fontScaleOf(1.3)).assertEqual(1.3)
      expect(fontScaleOf(1.31)).assertEqual(1.3)
      expect(fontScaleOf(1.15)).assertEqual(1.15)
      expect(fontScaleOf(1.2)).assertEqual(1.15)
      expect(fontScaleOf(0.95)).assertEqual(1.0)
      expect(fontScaleOf(0.9)).assertEqual(0.9)
      expect(fontScaleOf(0)).assertEqual(0.9)
    })

    it('fsc_scales_and_rounds', 0, () => {
      expect(fsc(1.0, 13)).assertEqual(13)
      expect(fsc(1.15, 13)).assertEqual(15)
      expect(fsc(1.3, 13)).assertEqual(17)
      expect(fsc(0.9, 13)).assertEqual(12)
    })

    it('fsc_defensive_clamp_out_of_range', 0, () => {
      // 越界档按 1.0 兜底(不放大异常)
      expect(fsc(3.0, 13)).assertEqual(13)
      expect(fsc(0.1, 13)).assertEqual(13)
    })
  })
}
