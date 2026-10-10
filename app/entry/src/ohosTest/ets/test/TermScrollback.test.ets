/**
 * tty7 M3c:scrollback 渲染 + 终端搜索纯函数单测(ArkTS/hypium)。
 *
 * 覆盖:
 *   1. tailLines:尾部截取(不足/超出/max<=0 守卫)
 *   2. searchHits:大小写不敏感匹配(命中序/空关键字/无命中)
 *   3. nextHit:环绕步进(+1/-1/越界回绕/n<=0 守卫)
 *   4. shouldStick:贴底语义(用户上滚不打断/首帧强制贴)
 *   5. 注册表:term.search 命令存在 + AppStorage 信号单调 +1
 */
import { describe, it, expect } from '@ohos/hypium';
import { tailLines, searchHits, nextHit, shouldStick, SCROLLBACK_MAX } from '../../../main/ets/tty7/term/TermScrollback';
import { paletteCmds, PaletteCmd } from '../../../main/ets/tty7/shell/PaletteCommands';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';

export default function termScrollbackTest() {
  describe('tty7TermScrollback', () => {
    // ===== 1. tailLines 尾部截取 =====
    it('tail_lines_takes_last_max', 0, () => {
      const texts: string[] = []
      for (let i = 1; i <= 2010; i++) {
        texts.push('L' + i.toString())
      }
      const out = tailLines(texts, SCROLLBACK_MAX)
      expect(out.length).assertEqual(2000)
      expect(out[0]).assertEqual('L11') // 尾截:丢最前 10 行
      expect(out[1999]).assertEqual('L2010')
    })

    it('tail_lines_short_input_untouched', 0, () => {
      const out = tailLines(['a', 'b'], SCROLLBACK_MAX)
      expect(out.length).assertEqual(2)
      expect(out[0]).assertEqual('a')
      expect(out[1]).assertEqual('b')
    })

    it('tail_lines_guards_empty', 0, () => {
      expect(tailLines([], SCROLLBACK_MAX).length).assertEqual(0)
      expect(tailLines(['x'], 0).length).assertEqual(0)
      expect(tailLines(['x'], -5).length).assertEqual(0)
    })

    // ===== 2. searchHits 大小写不敏感匹配 =====
    it('search_hits_case_insensitive_ordered', 0, () => {
      const texts = ['abc', 'nope', 'ABC def', 'zz abc', '']
      const hits = searchHits(texts, 'abc')
      expect(hits.length).assertEqual(3)
      expect(hits[0]).assertEqual(0)
      expect(hits[1]).assertEqual(2)
      expect(hits[2]).assertEqual(3)
    })

    it('search_hits_empty_keyword_or_no_match', 0, () => {
      expect(searchHits(['abc'], '').length).assertEqual(0)
      expect(searchHits(['abc'], '   ').length).assertEqual(0)
      expect(searchHits(['abc', 'def'], 'xyz').length).assertEqual(0)
    })

    // ===== 3. nextHit 环绕步进 =====
    it('next_hit_wraps_both_directions', 0, () => {
      expect(nextHit(0, 3, 1)).assertEqual(1)
      expect(nextHit(2, 3, 1)).assertEqual(0) // 右越界回绕
      expect(nextHit(0, 3, -1)).assertEqual(2) // 左越界回绕
      expect(nextHit(1, 3, -1)).assertEqual(0)
    })

    it('next_hit_guards_nonpositive_n', 0, () => {
      expect(nextHit(0, 0, 1)).assertEqual(0)
      expect(nextHit(2, -1, 1)).assertEqual(0)
    })

    // ===== 4. shouldStick 贴底语义 =====
    it('should_stick_only_when_bottom_or_initial', 0, () => {
      expect(shouldStick(true, false)).assertTrue() // 贴底:跟随
      expect(shouldStick(false, false)).assertFalse() // 上滚:不打断
      expect(shouldStick(false, true)).assertTrue() // 首帧:强制贴底
    })

    // ===== 5. 注册表:term.search 信号 =====
    it('term_search_cmd_bumps_appstorage_signal', 0, () => {
      let cmd: PaletteCmd | null = null
      for (const c of paletteCmds()) {
        if (c.key === 'term.search') {
          cmd = c
        }
      }
      expect(cmd !== null).assertTrue()
      AppStorage.setOrCreate('ut.term.search', 41)
      ;(cmd as PaletteCmd).run(new WorkbenchVm())
      expect(AppStorage.get<number>('ut.term.search')).assertEqual(42)
    })
  })
}
