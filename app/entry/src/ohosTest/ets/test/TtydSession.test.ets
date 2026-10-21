/**
 * RD-2 TtydSession 纯函数单测(ArkTS/hypium)。
 * 靶: stripAnsi / splitFeedLines(ttyd 输出流的镜像前处理)。
 */
import { describe, it, expect } from '@ohos/hypium';
import { stripAnsi, splitFeedLines, TtydSession } from '../../../main/ets/workbench/term/TtydSession';

export default function ttydSessionTest() {
  describe('TtydSession', () => {
    it('clampfont_bounds_and_reset', 0, () => {
      // GUI 丝滑棒:字号钳制 [8,32];delta=0 重置 14
      expect(TtydSession.clampFont(14, 1)).assertEqual(15)
      expect(TtydSession.clampFont(14, -1)).assertEqual(13)
      expect(TtydSession.clampFont(32, 1)).assertEqual(32)
      expect(TtydSession.clampFont(8, -1)).assertEqual(8)
      expect(TtydSession.clampFont(20, 0)).assertEqual(14)
    })

    it('strip_ansi_removes_escape_sequences', 0, () => {
      expect(stripAnsi('\x1b[31mred\x1b[0m')).assertEqual('red')
      expect(stripAnsi('\x1b[2J\x1b[Hclean')).assertEqual('clean')
      expect(stripAnsi('plain')).assertEqual('plain')
      expect(stripAnsi('a\rb')).assertEqual('a\rb') // 裸 \r 原样保留——
      // 行内覆盖近似由 splitFeedLines 的行拆分承担,stripAnsi 只删 ANSI 序列
    })

    it('split_feed_lines_crlf_lf_cr', 0, () => {
      const r1 = splitFeedLines('', 'a\r\nb\n')
      expect(r1.lines.length).assertEqual(2)
      expect(r1.lines[0]).assertEqual('a')
      expect(r1.lines[1]).assertEqual('b')
      expect(r1.pending).assertEqual('')
      const r2 = splitFeedLines('', 'x\ry')
      expect(r2.lines.length).assertEqual(1)
      expect(r2.pending).assertEqual('y')
    })

    it('split_feed_lines_pending_carries_across_chunks', 0, () => {
      const r1 = splitFeedLines('', 'partial')
      expect(r1.pending).assertEqual('partial')
      const r2 = splitFeedLines(r1.pending, ' line\r\nnext')
      expect(r2.lines.length).assertEqual(1)
      expect(r2.lines[0]).assertEqual('partial line')
      expect(r2.pending).assertEqual('next')
    })

    it('split_feed_lines_empty_chunk_keeps_pending', 0, () => {
      const r1 = splitFeedLines('keep', '')
      expect(r1.pending).assertEqual('keep')
      expect(r1.lines.length).assertEqual(0)
    })
  })
}
