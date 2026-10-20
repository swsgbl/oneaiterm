/**
 * RD-1 单测:TermReach 纯逻辑——缓存/退避/异常不抛(任务书交付物:
 * 网络调用注入 mock,真网络永不触达)。
 *
 * 覆盖:
 *  1. backoffAfter 表语义(1/5/30s,失败 3+ 钉 30s);
 *  2. TermReachState 状态机:unknown 立即探、成功钉死、失败退避、
 *     invalidate 仅在 ok=true 时转 unknown;
 *  3. probeTtyd 缓存语义:mock fetcher 只被调 1 次(会话缓存),
 *     退避窗口内重复 probeTtyd 不发网络;
 *  4. mock 抛异常:probeTtyd 绝不抛(外层防御兜底),返回 false;
 *  5. invalidate 后恢复:false → (窗外)重探成功 → invalidate→重探成功;
 *  6. 成功缓存恒真:probe 不再发网络(会话级)。
 *
 * 注:用例为 async it(hypium 支持 Promise 回调;mock fetcher 全同步
 * resolve,无真网络无时序抖动)。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  TermReachState, backoffAfter, BACKOFF_MS, injectFetcher, resetFetcher,
  reachState, probeTtyd
} from '../../../main/ets/workbench/term/TermReach';

export default function termReachTest() {
  describe('TermReach', () => {
    // ===== 1. 退避表语义 =====
    it('backoff_table_1s_5s_30s_cap', 0, () => {
      expect(backoffAfter(0)).assertEqual(0)
      expect(backoffAfter(1)).assertEqual(1000)
      expect(backoffAfter(2)).assertEqual(5000)
      expect(backoffAfter(3)).assertEqual(30000)
      expect(backoffAfter(4)).assertEqual(30000) // 钉尾
      expect(backoffAfter(99)).assertEqual(30000)
      expect(BACKOFF_MS.length).assertEqual(3)
    })

    // ===== 2. 状态机:unknown 立即;成功钉死;失败退避;invalidate 语义 =====
    it('state_machine_success_pins_and_backoff', 0, () => {
      const st = new TermReachState()
      // unknown:立即允许
      expect(st.ok).assertNull()
      expect(st.probe(0)).assertTrue()
      // 成功:钉死 ok=true,probe 永假
      st.setResult(true, 1000)
      expect(st.ok).assertTrue()
      expect(st.probe(999999)).assertFalse()
      // invalidate:ok=true → unknown 立即重探
      st.invalidate(2000)
      expect(st.ok).assertNull()
      expect(st.probe(2000)).assertTrue()
      // 失败×2:退避 1s→5s;窗口内拒,窗外收
      st.setResult(false, 10000)
      expect(st.ok).assertFalse()
      expect(st.failCount).assertEqual(1)
      expect(st.probe(10999)).assertFalse() // 1s 窗内
      expect(st.probe(11000)).assertTrue() // 窗口到点
      st.setResult(false, 11000)
      expect(st.failCount).assertEqual(2)
      expect(st.probe(15999)).assertFalse() // 5s 窗内
      expect(st.probe(16000)).assertTrue()
      // 失败×3:退避 30s;invalidate 对 false 态 no-op(仍退避)
      st.setResult(false, 16000)
      expect(st.failCount).assertEqual(3)
      st.invalidate(17000)
      expect(st.ok).assertFalse()
      expect(st.probe(45999)).assertFalse() // 30s 窗内(invalidate 未开闸)
      expect(st.probe(46000)).assertTrue()
      // 成功清失败计数并钉死
      st.setResult(true, 46000)
      expect(st.failCount).assertEqual(0)
      expect(st.probe(46001)).assertFalse()
    })

    // ===== 3. probeTtyd 缓存语义:mock 只调一次,退避窗内零网络 =====
    it('probe_cached_session_single_fetch', 0, async () => {
      let calls = 0
      injectFetcher((): Promise<boolean> => {
        calls += 1
        return Promise.resolve(false)
      })
      const v1 = await probeTtyd()
      expect(v1).assertFalse()
      expect(calls).assertEqual(1)
      // 会话缓存:退避窗内再 probe 不再发网络——fetcher 调用数不涨
      const v2 = await probeTtyd()
      expect(v2).assertFalse()
      expect(calls).assertEqual(1)
      // 缓存态联动:probeTtyd 已把会话状态置 false+退避
      expect(reachState.ok).assertFalse()
      expect(reachState.failCount).assertEqual(1)
      resetFetcher()
    })

    // ===== 4. mock 抛异常:probeTtyd 绝不抛(防御兜底 false) =====
    it('probe_never_throws_on_fetcher_throw', 0, async () => {
      injectFetcher((): Promise<boolean> => {
        throw new Error('net stack gone')
      })
      // 若 probeTtyd 拒绝/抛出,await 会直接判负——"绝不抛"即断言本身
      const v = await probeTtyd()
      expect(v).assertFalse()
      // 失败也已入缓存(退避生效)
      expect(reachState.ok).assertFalse()
      resetFetcher()
    })

    // ===== 5. 恢复路径:false → (窗外)重探成功 → invalidate→重探成功 =====
    it('probe_recovery_after_backoff_and_invalidate', 0, async () => {
      let okNow = false
      injectFetcher((): Promise<boolean> => Promise.resolve(okNow))
      expect(await probeTtyd()).assertFalse() // 失败 1:1s 退避
      // 退避窗口内强行走缓存(不 fetch)
      expect(await probeTtyd()).assertFalse()
      // 模拟窗外:手动拨状态机时钟再 probe
      reachState.nextProbeAt = 0
      okNow = true
      expect(await probeTtyd()).assertTrue() // 恢复
      expect(reachState.ok).assertTrue()
      // 页面级失败兜底:invalidate → unknown → 再探成功
      reachState.invalidate(Date.now())
      expect(reachState.ok).assertNull()
      expect(await probeTtyd()).assertTrue()
      resetFetcher()
    })

    // ===== 6. 成功缓存恒真:probe 不再发网络(会话级) =====
    it('probe_success_pins_no_refetch', 0, async () => {
      let calls = 0
      injectFetcher((): Promise<boolean> => {
        calls += 1
        return Promise.resolve(true)
      })
      expect(await probeTtyd()).assertTrue()
      expect(await probeTtyd()).assertTrue()
      expect(await probeTtyd()).assertTrue()
      expect(calls).assertEqual(1) // 只探一次
      resetFetcher()
    })
  })
}
