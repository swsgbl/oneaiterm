/**
 * tty7-PB parity 棒 B 纯函数单测(ArkTS/hypium)。
 *
 * 覆盖(任务书 ≥4):
 *   1. isPromptBack:尾行 trim 后缀 $/#/> 判定(含空数组/空白守卫)
 *   2. recentMatches:空 query 全 5 条/前缀过滤大小写不敏感/截 5 上限
 *   3. 通知去抖:提交→完成→再提交 探测重置(probeSubmit/probeTick 状态机;
 *      800ms 内提示符回归不算完成、60s 上限 giveup、再提交重置)
 *   4. buildFinishedAttention:type/kind/paneId/text 字段
 *   5. 总线链:attention 事件 emit → recent() 可见(Agent 面板挂载回放同路径)
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  isPromptBack, recentMatches, DoneProbeState, probeSubmit, probeTick,
  buildFinishedAttention, RECENT_MAX, trimBlankTail
} from '../../../main/ets/tty7/shell/ParityUi';
import { AgentEventBus } from '../../../main/ets/tty7/agent/AgentEventBus';

export default function parityUiTest() {
  describe('tty7ParityUi', () => {
    // ===== 1. isPromptBack 提示符回归判定 =====
    it('prompt_back_detects_suffix_dollar_hash_gt', 0, () => {
      expect(isPromptBack(['out line', 'hongfu@vm:~$'])).assertTrue()
      expect(isPromptBack(['x', 'root #'])).assertTrue()
      expect(isPromptBack(['x', 'bash-5.1>'])).assertTrue()
    })

    it('prompt_back_guards', 0, () => {
      expect(isPromptBack([])).assertFalse()
      expect(isPromptBack(['   '])).assertFalse() // 尾行全空白
      expect(isPromptBack(['echo hi', 'hi'])).assertFalse() // 输出进行中
      expect(isPromptBack(['a', 'done?no'])).assertFalse() // '?' 不算
      expect(isPromptBack(['a', '  root@x:~$  '])).assertTrue() // trim 后命中
    })

    // ===== 2. recentMatches 最近命令过滤 =====
    it('recent_matches_empty_query_takes_five', 0, () => {
      const recent = ['one', 'two', 'three', 'four', 'five', 'six', 'seven']
      const out = recentMatches(recent, '')
      expect(out.length).assertEqual(RECENT_MAX)
      expect(out[0]).assertEqual('one') // 保序(最新在前)
      expect(out[4]).assertEqual('five')
    })

    it('recent_matches_prefix_filter', 0, () => {
      const recent = ['git status', 'git log', 'echo hi', 'ls -l']
      const out = recentMatches(recent, 'GIT')
      expect(out.length).assertEqual(2) // 大小写不敏感
      expect(out[0]).assertEqual('git status')
      expect(out[1]).assertEqual('git log')
      expect(recentMatches(recent, 'zzz').length).assertEqual(0)
      expect(recentMatches(recent, '   ').length).assertEqual(4) // 全空白=空 query
    })

    // ===== 3. 通知去抖:探测状态机 =====
    it('probe_debounce_submit_done_resubmit', 0, () => {
      const st = new DoneProbeState()
      const prompt = ['x', 'hongfu@vm:~$']
      // 提交 → 500ms(不足 800ms)提示符已回归:不算完成(回显防误判)
      probeSubmit(st, 1000)
      expect(probeTick(st, prompt, 1500)).assertEqual('none')
      expect(st.active).assertTrue()
      // 900ms(>800ms)提示符回归 → done 一次,链止(active=false)
      expect(probeTick(st, prompt, 1900)).assertEqual('done')
      expect(st.active).assertFalse()
      expect(st.notified).assertTrue()
      // done 后再 tick:none(active 已 false,不重复通知)
      expect(probeTick(st, prompt, 2200)).assertEqual('none')
      // 再提交(探测重启):重置计时——新命令 500ms 内提示符(旧尾行)不算
      probeSubmit(st, 5000)
      expect(st.active).assertTrue()
      expect(st.notified).assertFalse()
      expect(probeTick(st, prompt, 5500)).assertEqual('none')
      expect(probeTick(st, prompt, 5900)).assertEqual('done')
    })

    it('probe_giveup_at_60s', 0, () => {
      const st = new DoneProbeState()
      probeSubmit(st, 0)
      expect(probeTick(st, ['running...'], 59000)).assertEqual('none') // 未到上限继续
      expect(probeTick(st, ['running...'], 61000)).assertEqual('giveup') // 上限放弃
      expect(st.active).assertFalse()
      // giveup 后即使提示符回归也不通知
      expect(probeTick(st, ['hongfu@vm:~$'], 62000)).assertEqual('none')
    })

    // ===== 4. attention 事件构造 =====
    it('attention_event_shape', 0, () => {
      const ev = buildFinishedAttention('p2')
      expect(ev.type).assertEqual('attention')
      expect(ev.kind).assertEqual('finished')
      expect(ev.paneId).assertEqual('p2')
      expect(ev.text).assertEqual('✓ 命令完成 · p2')
    })

    // ===== 5. 总线链:emit → recent 可见(面板回放同路径) =====
    it('attention_emitted_visible_in_bus', 0, () => {
      const bus = AgentEventBus.instance()
      bus.clear()
      bus.emit(buildFinishedAttention('p9'))
      const r = bus.recent(5)
      expect(r.length).assertEqual(1)
      expect(r[0].type).assertEqual('attention')
      expect(r[0].kind).assertEqual('finished')
      expect(r[0].paneId).assertEqual('p9')
      bus.clear()
    })

    // ===== 6. trimBlankTail 尾空行剪除(capture/tailTexts 取窗前置;
    // 实勘:新会话 '$ ' 在屏顶、垫底 blank 使尾 N 行全空 → capture 空串
    // 误报 pane not bound、done 探测 isPromptBack 恒 false) =====
    it('trim_blank_tail_strips_trailing_blank_rows', 0, () => {
      // 新会话形态:['$ '] + 45 个空行垫底
      const rows: string[] = ['$ ']
      for (let i = 0; i < 45; i++) {
        rows.push('')
      }
      const out = trimBlankTail(rows)
      expect(out.length).assertEqual(1)
      expect(out[0]).assertEqual('$ ')
      // 入参不被改写(纯拷贝)
      expect(rows.length).assertEqual(46)
    })

    it('trim_blank_tail_guards_and_whitespace', 0, () => {
      expect(trimBlankTail([]).length).assertEqual(0) // 全空
      expect(trimBlankTail(['', '']).length).assertEqual(0) // 全空白
      // 只剪尾部;中部空行保留
      const mixed = trimBlankTail(['a', '', 'b', ' ', ''])
      expect(mixed.length).assertEqual(3)
      expect(mixed[0]).assertEqual('a')
      expect(mixed[1]).assertEqual('')
      expect(mixed[2]).assertEqual('b')
      // 无尾空行原样返回
      expect(trimBlankTail(['x', 'y']).length).assertEqual(2)
    })
  })
}
