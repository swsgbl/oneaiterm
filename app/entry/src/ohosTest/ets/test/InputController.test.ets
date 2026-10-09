/**
 * tty7 M4a 单测:InputHistory(入史/去重/环形/前缀匹配) + InputController
 * (差分直写/Tab 补全/历史回溯/ghost 优先级)。
 *
 * InputHistory persist/restore 单测环境无 context 静默降级,不 assert 磁盘
 * (任务书约定);用例间 InputHistory.clear() 复位全局静态,消除顺序耦合。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { InputHistory } from '../../../main/ets/tty7/term/InputHistory';
import { InputController } from '../../../main/ets/tty7/term/InputController';

export default function inputControllerTest() {
  describe('tty7InputController', () => {
    beforeEach(() => {
      InputHistory.clear() // 全局静态复位,用例隔离
    })

    // ===== 1. push/recent/trim/空串拒绝/相邻去重/环形 100 =====
    it('inputhistory_push_dedupe_ring', 0, () => {
      InputHistory.push('  echo hi  ') // trim 入史
      expect(InputHistory.size()).assertEqual(1)
      InputHistory.push('echo hi') // 与最近一条相同不入
      expect(InputHistory.size()).assertEqual(1)
      InputHistory.push('   ') // 空串不入
      expect(InputHistory.size()).assertEqual(1)
      expect(InputHistory.recent()[0]).assertEqual('echo hi')
      for (let i = 1; i <= 105; i++) {
        InputHistory.push('h' + i.toString())
      }
      expect(InputHistory.size()).assertEqual(100) // 环形裁剪
      const r = InputHistory.recent()
      expect(r[0]).assertEqual('h105') // 最新在前
      expect(r[99]).assertEqual('h6') // 裁掉 echo hi+h1..h5 共 6 条,最旧留存 h6
    })

    // ===== 2. matchPrefix 顺序(最新在前)与上限 8 =====
    it('inputhistory_matchprefix_order_and_cap', 0, () => {
      InputHistory.push('echo a')
      InputHistory.push('echo b')
      InputHistory.push('ec')
      InputHistory.push('ls -l')
      const m = InputHistory.matchPrefix('echo')
      expect(m.length).assertEqual(2)
      expect(m[0]).assertEqual('echo b') // 最新在前
      expect(m[1]).assertEqual('echo a')
      expect(InputHistory.matchPrefix('ec').length).assertEqual(3) // ec/echo a/echo b 均前缀命中
      expect(InputHistory.matchPrefix('').length).assertEqual(0) // 空前缀无建议
      for (let i = 1; i <= 10; i++) {
        InputHistory.push('x' + i.toString())
      }
      const mx = InputHistory.matchPrefix('x')
      expect(mx.length).assertEqual(8) // 上限 8
      expect(mx[0]).assertEqual('x10')
    })

    // ===== 3. onInput 差分直写:前缀增长差量/缩短 \x7f/ghost 同步 =====
    it('controller_oninput_diff_write', 0, () => {
      const c = new InputController()
      const a1 = c.onInput('ec')
      expect(a1.writeText).assertEqual('ec') // ''→'ec' 前缀增长直写差量
      expect(a1.setField).assertFalse()
      expect(a1.ghost).assertEqual('ho') // 内建表 echo
      const a2 = c.onInput('ech') // 'ec'→'ech' 差量 'h'
      expect(a2.writeText).assertEqual('h')
      const a3 = c.onInput('ec') // 缩短 1 字符 → \x7f
      expect(a3.writeText).assertEqual('\x7f')
      const a4 = c.onInput('ec') // 恒等重复 onChange → 无操作
      expect(a4.writeText).assertEqual('')
    })

    // ===== 4. onTab 单候选补全:整行重写 \x15+echo,fieldText 对齐 =====
    it('controller_ontab_single_candidate', 0, () => {
      const c = new InputController()
      c.onInput('ec')
      const a = c.onTab()
      expect(a.writeText).assertEqual('\x15echo') // Ctrl-U 清行 + 补全文本
      expect(a.setField).assertTrue()
      expect(a.fieldText).assertEqual('echo')
      expect(a.ghost).assertEqual('') // 补全后无建议
      const a2 = c.onInput('echo') // 程序化设置后的 onChange:幂等
      expect(a2.writeText).assertEqual('')
    })

    // ===== 5. onTab 多候选循环:连续 Tab 依次轮换,回绕 =====
    it('controller_ontab_multi_cycle', 0, () => {
      InputHistory.push('echo hi')
      InputHistory.push('echo ho')
      InputHistory.push('echo ha')
      const c = new InputController()
      c.onInput('ec')
      const t1 = c.onTab() // 候选:[echo ha, echo ho, echo hi, echo(builtin)]
      expect(t1.fieldText).assertEqual('echo ha')
      const t2 = c.onTab() // cycling(未被编辑) → 下一候选
      expect(t2.fieldText).assertEqual('echo ho')
      const t3 = c.onTab()
      expect(t3.fieldText).assertEqual('echo hi')
      const t4 = c.onTab()
      expect(t4.fieldText).assertEqual('echo') // 内建表兜底
      const t5 = c.onTab()
      expect(t5.fieldText).assertEqual('echo ha') // 回绕循环
      // 编辑后重算:基线变化 → 候选重算
      c.onInput('echo h')
      const t6 = c.onTab()
      expect(t6.fieldText).assertEqual('echo ha') // 重算后首候选
    })

    // ===== 6. onArrow 回溯:↑上移/顶钳制/↓下移/超出回空串/回车复位 =====
    it('controller_onarrow_history_nav', 0, () => {
      InputHistory.push('cmd1')
      InputHistory.push('cmd2') // 最新
      const c = new InputController()
      const up1 = c.onArrow(true)
      expect(up1.fieldText).assertEqual('cmd2') // 末尾上移 → 最新一条
      expect(up1.writeText).assertEqual('\x15cmd2')
      expect(up1.setField).assertTrue()
      const up2 = c.onArrow(true)
      expect(up2.fieldText).assertEqual('cmd1')
      const up3 = c.onArrow(true) // 顶钳制
      expect(up3.fieldText).assertEqual('cmd1')
      const dn1 = c.onArrow(false)
      expect(dn1.fieldText).assertEqual('cmd2')
      const dn2 = c.onArrow(false) // 超出最新 → 回空串 + 清游标
      expect(dn2.fieldText).assertEqual('')
      expect(dn2.writeText).assertEqual('\x15')
      const up4 = c.onArrow(true) // 清游标后再 ↑ 仍从最新起
      expect(up4.fieldText).assertEqual('cmd2')
      const en = c.onEnter() // 回车:游标复位 + 入史
      expect(en.writeText).assertEqual('\r')
      const up5 = c.onArrow(true)
      expect(up5.fieldText).assertEqual('cmd2') // histIdx 已复位,仍从最新起
    })

    // ===== 7. ghost 优先级:历史前缀 > 内建表 > 空 =====
    it('controller_ghost_priority', 0, () => {
      const c1 = new InputController()
      expect(c1.onInput('gr').ghost).assertEqual('ep') // 无历史 → 内建表 grep
      InputHistory.push('grep foo bar')
      const c2 = new InputController() // 新实例:同值 onInput 有幂等守卫(sent 未变即返缓存)
      expect(c2.onInput('gr').ghost).assertEqual('ep foo bar') // 历史优先(含参数)
      const c3 = new InputController()
      expect(c3.onInput('xyz').ghost).assertEqual('') // 两级均无 → 空
      expect(c3.onInput('').ghost).assertEqual('') // 空输入无建议
    })

    // ===== 8. onEnter 入史 + 基线清零(submit 后字段清空恒无操作) =====
    it('controller_onenter_resets_and_records', 0, () => {
      const c = new InputController()
      c.onInput('ls -l /data')
      const a = c.onEnter()
      expect(a.writeText).assertEqual('\r')
      expect(a.ghost).assertEqual('')
      expect(InputHistory.size()).assertEqual(1)
      expect(InputHistory.recent()[0]).assertEqual('ls -l /data')
      // submit 后框架静默清字段 → onChange(''):sent 已清零,恒等幂等
      const a2 = c.onInput('')
      expect(a2.writeText).assertEqual('')
      expect(c.ghost()).assertEqual('')
      // reset 后行状态全清(会话停止/开始)
      c.onInput('xx')
      c.reset()
      expect(c.line()).assertEqual('')
      expect(c.ghost()).assertEqual('')
    })

    // ===== 8. M4b onPasteBlock 三行:两处 \r + 末行对齐 + 单行差分 + 尾空行剥 ====
    it('controller_onpasteblock_multiline', 0, () => {
      const c = new InputController()
      const a = c.onPasteBlock('ec\r\nho\r\nfoo') // CRLF 输入
      expect(a.writeText).assertEqual('ec\rho\rfoo')
      expect(a.setField).assertTrue()
      expect(a.fieldText).assertEqual('foo')
      expect(c.line()).assertEqual('foo')
      const a2 = c.onPasteBlock('ls\r\n') // 剥尾空行→单行'ls'→走 onInput 差分:非前缀→整行重写
      expect(a2.writeText).assertEqual('\x15ls')
      expect(a2.setField).assertFalse() // 差分路径不重设字段(字段已是新值)
      expect(c.line()).assertEqual('ls')
      const a3 = c.onPasteBlock('ls -l') // 单行:纯差分
      expect(a3.writeText).assertEqual(' -l')
      expect(a3.setField).assertFalse()
      const c4 = new InputController()
      c4.onInput('ec') // 编辑行残留:块前须 Ctrl-U 清行
      const a4 = c4.onPasteBlock('aa\nbb')
      expect(a4.writeText).assertEqual('\x15aa\rbb')
      expect(a4.setField).assertTrue()
      expect(a4.fieldText).assertEqual('bb')
      expect(c4.line()).assertEqual('bb')
    })

    // ===== 9. M4b onArrow 空历史安全(altScreen 判定在 View 层,Controller 不动) =====
    it('controller_onarrow_empty_history_noop', 0, () => {
      const c = new InputController()
      c.onInput('ec')
      const a = c.onArrow(true) // 空历史:无动作(不炸不重写)
      expect(a.writeText).assertEqual('')
      expect(a.setField).assertFalse()
      const a2 = c.onInput('echo') // 控制器状态未被破坏
      expect(a2.writeText).assertEqual('ho')
    })

    // ===== 10. M4b 回归:Tab 后 line()=候选,onEnter 入史正确行 ====
    it('controller_tab_then_line_matches_pick', 0, () => {
      const c = new InputController()
      c.onInput('ec')
      c.onTab() // → echo
      expect(c.line()).assertEqual('echo') // 回归:M4b 驱动验收的判定源
      const en = c.onEnter()
      expect(en.writeText).assertEqual('\r')
      expect(InputHistory.recent()[0]).assertEqual('echo') // 入史=补全产物
    })
  })
}
