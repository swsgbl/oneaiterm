import { describe, it, expect } from '@ohos/hypium';
import {
  parseRequest,
  formatResponse,
  linesToText,
  doctorSnapshot,
  handleCmd
} from '../../../main/ets/tty7/bridge/CommandBridge';

export default function commandBridgeTest() {
  describe('CommandBridge', () => {
    // ---- parseRequest ----
    it('parseBadJson', 0, () => {
      expect(parseRequest('{oops')).assertNull()
    })
    it('parseNonObject', 0, () => {
      expect(parseRequest('42')).assertNull()
      expect(parseRequest('"str"')).assertNull()
    })
    it('parseMissingId', 0, () => {
      expect(parseRequest('{"cmd":"doctor"}')).assertNull()
      expect(parseRequest('{"id":"x","cmd":"doctor"}')).assertNull()
    })
    it('parseMissingCmd', 0, () => {
      expect(parseRequest('{"id":1}')).assertNull()
      expect(parseRequest('{"id":1,"cmd":""}')).assertNull()
    })
    it('parseOkWithArgs', 0, () => {
      const r = parseRequest('{"id":7,"cmd":"send","args":{"paneId":"p1","text":"hi"}}')
      expect(r !== null).assertTrue()
      expect(r!.id).assertEqual(7)
      expect(r!.cmd).assertEqual('send')
      expect(r!.args!['paneId']).assertEqual('p1')
    })
    // ---- formatResponse ----
    it('formatRoundtrip', 0, () => {
      const s = formatResponse({ id: 3, ok: true, data: 'ok' })
      const obj = JSON.parse(s) as Record<string, Object>
      expect(obj['ok']).assertTrue()
      expect(obj['id']).assertEqual(3)
      const e = formatResponse({ id: 4, ok: false, error: 'boom' })
      const obj2 = JSON.parse(e) as Record<string, Object>
      expect(obj2['ok']).assertFalse()
      expect(obj2['error']).assertEqual('boom')
    })
    // ---- linesToText ----
    it('linesJoin', 0, () => {
      expect(linesToText(['a', 'b', 'c'], 2)).assertEqual('b\nc')
      expect(linesToText(['a'], 40)).assertEqual('a')
      expect(linesToText([], 40)).assertEqual('')
      expect(linesToText(['a', '', 'c'], 3)).assertEqual('a\n\nc')
      expect(linesToText(['x', 'y'], 0)).assertEqual('x\ny')
    })
    // ---- doctorSnapshot / handleCmd 降级(测试进程 vm 未设)----
    it('doctorDegradesWithoutVm', 0, () => {
      const snap = doctorSnapshot()
      expect(snap['app']).assertEqual('oneaiterm')
      expect(snap['vm']).assertEqual(0)
    })
    it('handleVmNotSet', 0, () => {
      const r = handleCmd({ id: 1, cmd: 'workspace.list' })
      expect(r.ok).assertFalse()
      expect(r.error).assertEqual('vm-not-set')
    })
    it('handleUnknownDegrades', 0, () => {
      const r = handleCmd({ id: 2, cmd: 'nope' })
      expect(r.ok).assertFalse()
      expect(r.error !== '').assertTrue()
    })
  })
}
