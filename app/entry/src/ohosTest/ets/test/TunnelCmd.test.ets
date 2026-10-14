/**
 * tty7-LEG-3b 隧道命令纯函数单测(ArkTS/hypium)。
 * 靶: parseTunnelSpec(规格解析与校验)。
 */
import { describe, it, expect } from '@ohos/hypium';
import { parseTunnelSpec } from '../../../main/ets/tty7/shell/PaletteCommands';

export default function tunnelCmdTest() {
  describe('tty7TunnelCmd', () => {
    it('parse_valid_spec', 0, () => {
      const s = parseTunnelSpec('9432:127.0.0.1:3306')
      expect(s !== null).assertTrue()
      expect(s!.localPort).assertEqual(9432)
      expect(s!.remoteHost).assertEqual('127.0.0.1')
      expect(s!.remotePort).assertEqual(3306)
      const s2 = parseTunnelSpec('8080:db.internal:22')
      expect(s2 !== null).assertTrue()
      expect(s2!.remoteHost).assertEqual('db.internal')
    })

    it('parse_rejects_bad_ports_and_shape', 0, () => {
      expect(parseTunnelSpec('0:127.0.0.1:3306')).assertNull()
      expect(parseTunnelSpec('9432:127.0.0.1:65536')).assertNull()
      expect(parseTunnelSpec('9432::3306')).assertNull() // 空 host
      expect(parseTunnelSpec('9432:127.0.0.1')).assertNull() // 两段
      expect(parseTunnelSpec('')).assertNull()
      expect(parseTunnelSpec('a:b:c')).assertNull() // 非数字
    })

    it('parse_boundary_ports_accepted', 0, () => {
      expect(parseTunnelSpec('1:h:1') !== null).assertTrue()
      expect(parseTunnelSpec('65535:h:65535') !== null).assertTrue()
    })
  })
}
