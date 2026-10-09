/**
 * tty7 M3a 单测:TermHost 守卫 + TermModel feed 渲染 + WorkbenchVm
 * bindLocalSession 时序(任务 tty7-M3a 交付物 6)。
 *
 * 环境说明:ohosTest 跑在 KaihongOS 真机,liblocalpty.so 可用,PTY open
 * 真会成功——故 vm 用例按"成功路径 + 幂等 + 回收"设计(任务书预案 B);
 * TermModel 用例纯内存,不碰 PTY。
 *
 * 用例间强制 TermHost.stop() 复位单例,消除顺序耦合。
 */
import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { TermHost } from '../../../main/ets/tty7/term/TermHost';
import { TermModel, TermLine, lineToSpans } from '../../../main/ets/components/TermModel';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';

export default function termHostTest() {
  describe('tty7TermHost', () => {
    beforeAll(() => {
      TermHost.stop() // 干净起点
    })

    // ===== 1. TermModel.feed 基本渲染:'hi\r\n' 落行、rev 跟当前代对齐 =====
    it('termmodel_feed_renders_and_bumps_rev', 0, () => {
      const m = new TermModel(80, 24)
      m.feed('hi\r\n')
      // 'hi' 落在屏幕首行(行网格为日志,屏幕=末 rows 行)
      expect(m.textOf(m.lines[m.screenTop()])).assertEqual('hi')
      // 判脏语义:touch() 把行 rev 置为当前 gen(markAllDirty 才递增);
      // 写过的行 rev 必须 == 当前 gen(渲染层据此换 ForEach 键)
      expect(m.lines[m.screenTop()].rev > 0).assertTrue()
      // CR 后光标归 0,LF 落到下一行
      expect(m.cursor.x).assertEqual(0)
      expect(m.cursor.y).assertEqual(1)
    })

    // ===== 2. feed ANSI 色彩序列:文本正确、不崩、span 带色 =====
    it('termmodel_feed_ansi_color_sequences', 0, () => {
      const m = new TermModel(80, 24)
      m.feed('\x1b[31mRED\x1b[0m')
      const line: TermLine = m.lines[m.screenTop()]
      expect(m.textOf(line)).assertEqual('RED')
      const spans = lineToSpans(line, -1, false)
      expect(spans.length >= 1).assertTrue()
      expect(spans[0].fg).assertEqual('#ff7b72') // 31 = 亮红(AnsiPalette.FG[2])
    })

    // ===== 3. TermHost 未 start:全静态口安全无抛 =====
    it('termhost_guards_when_not_started', 0, () => {
      TermHost.stop()
      expect(TermHost.bound()).assertEqual('')
      expect(TermHost.term()).assertNull()
      TermHost.write('x') // 未开 PTY:内部守卫 no-op
      TermHost.resize(80, 24) // 未建 model:no-op
      TermHost.drainOnce()
      TermHost.stop() // 重复 stop 幂等
      expect(TermHost.bound()).assertEqual('')
    })

    // ===== 4. bindLocalSession 成功路径:绑定焦点 pane + slot + termTick =====
    it('vm_bindlocal_binds_focused_pane', 0, () => {
      TermHost.stop()
      const vm = new WorkbenchVm() // p1|h|p2,焦点 p1
      const t0 = vm.termTick
      expect(vm.bindLocalSession()).assertTrue()
      expect(TermHost.bound()).assertEqual('p1')
      expect(TermHost.term() !== null).assertTrue()
      expect(vm.sessionOf('p1') !== null).assertTrue()
      expect(vm.termTick > t0).assertTrue()
      expect(vm.statusText.indexOf('sess 1') >= 0).assertTrue()
    })

    // ===== 5. 二次调用幂等:绑定他 pane 先迁再绑;unbindTerm 后全清 =====
    it('vm_bindlocal_idempotent_and_unbind_reaps', 0, () => {
      TermHost.stop()
      const vm = new WorkbenchVm() // 焦点 p1
      expect(vm.bindLocalSession()).assertTrue()
      expect(TermHost.bound()).assertEqual('p1')
      // 幂等:同 pane 再调 → true,bound 不变,不重起 PTY
      expect(vm.bindLocalSession()).assertTrue()
      expect(TermHost.bound()).assertEqual('p1')
      // 换绑:p1 释放,p2 接管(单会话迁移)
      vm.focusPane('p2')
      expect(vm.bindLocalSession()).assertTrue()
      expect(TermHost.bound()).assertEqual('p2')
      expect(vm.sessionOf('p1')).assertNull()
      expect(vm.sessionOf('p2') !== null).assertTrue()
      // 结束:PTY 关、slot 清、termTick 再 ++
      const t1 = vm.termTick
      vm.unbindTerm()
      expect(TermHost.bound()).assertEqual('')
      expect(TermHost.term()).assertNull()
      expect(vm.sessionOf('p2')).assertNull()
      expect(vm.termTick > t1).assertTrue()
    })

    // ===== 6. closePane 联动回收:被删 pane 持 PTY → stop + slot 清 =====
    it('vm_closepane_reaps_bound_term', 0, () => {
      TermHost.stop()
      const vm = new WorkbenchVm() // 焦点 p1
      expect(vm.bindLocalSession()).assertTrue()
      expect(TermHost.bound()).assertEqual('p1')
      vm.closePane('p1') // 树折叠为单叶 p2,焦点内建迁移
      expect(TermHost.bound()).assertEqual('')
      expect(TermHost.term()).assertNull()
      expect(vm.sessionOf('p1')).assertNull()
      expect(vm.sessionCount()).assertEqual(0)
      expect(vm.statusText.indexOf('sess') < 0).assertTrue()
    })
  })
}
