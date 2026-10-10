import { describe, it, expect } from '@ohos/hypium';
import {
  parseRequest,
  formatResponse,
  linesToText,
  doctorSnapshot,
  handleCmd,
  escapeText,
  waitParams,
  agentsSummary,
  gitSubOk
} from '../../../main/ets/tty7/bridge/CommandBridge';
import { AgentEvent, AgentEventType } from '../../../main/ets/tty7/agent/AgentEvent';

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
    // ---- M8b:escapeText(CLI \r 转义,桥侧统一)----
    it('escapeTextControlChars', 0, () => {
      // 字面两字符 '\r' → 0x0d(CR);'\n' → LF;'\t' → TAB
      expect(escapeText('echo hi\\r')).assertEqual('echo hi\r')
      expect(escapeText('a\\nb')).assertEqual('a\nb')
      expect(escapeText('a\\tb')).assertEqual('a\tb')
      // 其他反斜杠序列不动
      expect(escapeText('a\\xb')).assertEqual('a\\xb')
      expect(escapeText('a\\')).assertEqual('a\\')
      expect(escapeText('plain')).assertEqual('plain')
    })
    // ---- M8b:waitParams(timeout clamp/interval 下限/match 非空)----
    it('waitParamsClamp', 0, () => {
      const bad = waitParams('', 5000, 300)
      expect(bad.ok).assertFalse()
      const d = waitParams('X', 0, 0)
      expect(d.ok).assertTrue()
      expect(d.timeout).assertEqual(10000)
      expect(d.interval).assertEqual(300)
      const big = waitParams('X', 999999, 50000)
      expect(big.timeout).assertEqual(60000)
      expect(big.interval).assertEqual(50000)
      const low = waitParams('X', 5000, 5)
      expect(low.interval).assertEqual(100)
      expect(low.timeout).assertEqual(5000)
    })
    // ---- M8b:agentsSummary(events 聚合纯函数)----
    it('agentsSummaryAggregates', 0, () => {
      const mk = (seq: number, agentId: string, type: string, state: string): AgentEvent => {
        const ev = new AgentEvent()
        ev.seq = seq
        ev.agentId = agentId
        ev.type = type as AgentEventType
        ev.state = state
        ev.ts = seq * 100
        return ev
      }
      const evs: AgentEvent[] = [
        mk(3, 'hmh', 'state_changed', 'working'),
        mk(1, 'hmh', 'state_changed', 'idle'),
        mk(2, 'acp:x', 'final', '')
      ]
      const out = agentsSummary(evs)
      expect(out.length).assertEqual(2)
      const r0 = out[0] as Record<string, Object>
      expect(r0['agentId']).assertEqual('hmh')
      expect(r0['events']).assertEqual(2)
      expect(r0['state']).assertEqual('working')
      const r1 = out[1] as Record<string, Object>
      expect(r1['agentId']).assertEqual('acp:x')
      expect(r1['lastType']).assertEqual('final')
      expect(agentsSummary([]).length).assertEqual(0)
    })
    // ---- M8b:gitSubOk(sub 白名单)----
    it('gitSubWhitelist', 0, () => {
      expect(gitSubOk('status')).assertTrue()
      expect(gitSubOk('log')).assertTrue()
      expect(gitSubOk('push')).assertFalse()
      expect(gitSubOk('commit')).assertFalse()
      expect(gitSubOk('')).assertFalse()
    })
  })
}
