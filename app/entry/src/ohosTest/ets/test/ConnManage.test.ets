/**
 * LEG-1 连接档案管理表单校验单测(ArkTS/hypium)。
 * 靶: ConnManagePanel 导出的纯函数 connFormValid/defaultPortFor。
 */
import { describe, it, expect } from '@ohos/hypium';
import { ConnRec } from '../../../main/ets/store/ConnStore';
import { connFormValid, defaultPortFor, favoriteFirst } from '../../../main/ets/workbench/shell/ConnManagePanel';

export default function connManageTest() {
  describe('ConnManage', () => {
    it('form_valid_happy_path', 0, () => {
      expect(connFormValid('dev', 'ssh', '10.0.2.2', 2222)).assertEqual('')
      expect(connFormValid(' 交换机 ', 'telnet', '192.168.1.1', 23)).assertEqual('')
    })

    it('form_valid_name_host_required', 0, () => {
      expect(connFormValid('', 'ssh', 'h', 22)).assertEqual('名称不能为空')
      expect(connFormValid('   ', 'ssh', 'h', 22)).assertEqual('名称不能为空')
      expect(connFormValid('n', 'ssh', '', 22)).assertEqual('主机不能为空')
    })

    it('form_valid_type_whitelist_and_port_range', 0, () => {
      expect(connFormValid('n', 'rdp', 'h', 3389)).assertEqual('类型仅支持 ssh / telnet')
      expect(connFormValid('n', 'ssh', 'h', 0)).assertEqual('端口需在 1-65535')
      expect(connFormValid('n', 'ssh', 'h', 65536)).assertEqual('端口需在 1-65535')
      expect(connFormValid('n', 'ssh', 'h', 65535)).assertEqual('')
      expect(connFormValid('n', 'ssh', 'h', 1)).assertEqual('')
    })

    it('default_port_by_type', 0, () => {
      expect(defaultPortFor('ssh')).assertEqual(22)
      expect(defaultPortFor('telnet')).assertEqual(23)
      expect(defaultPortFor('')).assertEqual(22)
    })

    it('favorite_first_stable_partition', 0, () => {
      const a = new ConnRec()
      a.favorite = false
      a.name = 'a'
      const b = new ConnRec()
      b.favorite = true
      b.name = 'b'
      const c = new ConnRec()
      c.favorite = false
      c.name = 'c'
      const d = new ConnRec()
      d.favorite = true
      d.name = 'd'
      const out = favoriteFirst([a, b, c, d])
      expect(out.map(x => x.name).join('')).assertEqual('bdac') // 收藏前置+组内原序
      const x2 = new ConnRec()
      x2.favorite = false
      x2.name = 'x'
      const y2 = new ConnRec()
      y2.favorite = false
      y2.name = 'y'
      const none = favoriteFirst([x2, y2])
      expect(none.map(z => z.name).join('')).assertEqual('xy') // 无收藏原样
      expect(favoriteFirst([]).length).assertEqual(0)
    })
  })
}
