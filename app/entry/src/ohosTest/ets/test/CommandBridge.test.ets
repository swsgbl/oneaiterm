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
  gitSubOk,
  tokenTimeEqual,
  joinUuidHex,
  keysToBytes,
  treeToJson,
  splitDirOf,
  indexArg,
  renameOk,
  statusSnapshot
} from '../../../main/ets/workbench/bridge/CommandBridge';
import { gitAuditRecord } from '../../../main/ets/workbench/git/GitService';
import { AgentEvent, AgentEventType } from '../../../main/ets/workbench/agent/AgentEvent';
import { LayoutOps } from '../../../main/ets/workbench/layout/LayoutOps';
import { SessionSlot } from '../../../main/ets/workbench/model/TabState';
import { WorkbenchVm } from '../../../main/ets/workbench/viewmodel/WorkbenchVm';

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
    // ---- M9:tokenTimeEqual(恒时比较;长度不等早 false 合法——长度公开)----
    it('tokenTimeConst', 0, () => {
      expect(tokenTimeEqual('', '')).assertFalse()
      expect(tokenTimeEqual('', 'abc')).assertFalse()
      expect(tokenTimeEqual('abc', 'abc')).assertTrue()
      expect(tokenTimeEqual('abc', 'abd')).assertFalse()
      expect(tokenTimeEqual('abc', 'ab')).assertFalse()
      expect(tokenTimeEqual('ab', 'abc')).assertFalse()
      expect(tokenTimeEqual('a'.repeat(64), 'a'.repeat(64))).assertTrue()
      expect(tokenTimeEqual('a'.repeat(64), 'a'.repeat(63) + 'b')).assertFalse()
    })
    // ---- M9:joinUuidHex(双 UUID 拼接 64 hex;非法输入拒)----
    it('tokenHexShape', 0, () => {
      const u = '0123456789abcdef0123456789abcdef'
      expect(joinUuidHex(u, u)).assertEqual(u + u)
      expect(joinUuidHex(u, u + '0')).assertEqual('')
      expect(joinUuidHex('', u)).assertEqual('')
      expect(joinUuidHex(u + 'g', u)).assertEqual('')
      // 带 - 的真 UUID 形态
      const v = '01234567-89ab-cdef-0123-456789abcdef'
      expect(joinUuidHex(v, v)).assertEqual(u + u)
    })
    // ---- M9:gitAuditRecord(审计记录构造;tool/摘要/approval)----
    it('gitAuditRecordShape', 0, () => {
      const r = gitAuditRecord('commit', '/w', 'fix: bug', true, '')
      expect(r.tool).assertEqual('git.commit')
      expect(r.argsDigest.indexOf('/w') >= 0).assertTrue()
      expect(r.argsDigest.indexOf('fix: bug') >= 0).assertTrue()
      expect(r.resultDigest).assertEqual('ok')
      expect(r.approval).assertEqual('approved')
      expect(r.ts > 0).assertTrue()
      const bad = gitAuditRecord('stage', '/w', 'a b', false, 'boom')
      expect(bad.resultDigest).assertEqual('boom')
      const bad2 = gitAuditRecord('unstage', '/w', 'a', false, '')
      expect(bad2.resultDigest).assertEqual('failed')
    })
    // ---- PA:treeToJson(2x2 树递归 JSON 形状 + slot 元数据)----
    it('treeToJsonRecursive', 0, () => {
      let m = LayoutOps.single('p1')
      m = LayoutOps.split(m, 'p1', 'h', 'p2')
      m = LayoutOps.split(m, 'p1', 'v', 'p3')
      const slot = new SessionSlot()
      slot.paneId = 'p3'
      slot.kind = 'ssh'
      slot.title = 'ssh dev'
      const slotOf = (pid: string): SessionSlot | null => {
        return pid === 'p3' ? slot : null
      }
      const root = treeToJson(m.root, slotOf)
      expect(root['type']).assertEqual('split')
      expect(root['dir']).assertEqual('h')
      expect(root['ratio']).assertEqual(0.5)
      const ch = root['children'] as object[]
      expect(ch.length).assertEqual(2)
      const left = ch[0] as Record<string, Object>
      expect(left['type']).assertEqual('split')
      expect(left['dir']).assertEqual('v')
      const lch = left['children'] as object[]
      expect(lch.length).assertEqual(2)
      const l2 = lch[1] as Record<string, Object>
      expect(l2['type']).assertEqual('pane')
      expect(l2['paneId']).assertEqual('p3')
      expect(l2['slotKind']).assertEqual('ssh')
      expect(l2['title']).assertEqual('ssh dev')
      const right = ch[1] as Record<string, Object>
      expect(right['paneId']).assertEqual('p2')
      expect(right['slotKind']).assertEqual('')
    })
    // ---- PA:keysToBytes(命名键全表 + C-x 和弦 + 未知拒)----
    it('keysToBytesTable', 0, () => {
      expect(keysToBytes('enter')).assertEqual('\r')
      expect(keysToBytes('escape')).assertEqual('\x1b')
      expect(keysToBytes('tab')).assertEqual('\t')
      expect(keysToBytes('up')).assertEqual('\x1b[A')
      expect(keysToBytes('down')).assertEqual('\x1b[B')
      expect(keysToBytes('right')).assertEqual('\x1b[C')
      expect(keysToBytes('left')).assertEqual('\x1b[D')
      expect(keysToBytes('home')).assertEqual('\x1b[H')
      expect(keysToBytes('end')).assertEqual('\x1b[F')
      expect(keysToBytes('backspace')).assertEqual('\x7f')
      expect(keysToBytes('delete')).assertEqual('\x1b[3~')
      expect(keysToBytes('space')).assertEqual(' ')
      expect(keysToBytes('pgup')).assertEqual('\x1b[5~')
      expect(keysToBytes('pgdn')).assertEqual('\x1b[6~')
      expect(keysToBytes('C-a')).assertEqual('\x01')
      expect(keysToBytes('C-z')).assertEqual('\x1a')
      expect(keysToBytes('C-c')).assertEqual('\x03')
      expect(keysToBytes('C-C')).assertEqual('\x03')
      expect(keysToBytes('C-@')).assertEqual('\x00')
      expect(keysToBytes('C-_')).assertEqual('\x1f')
      expect(keysToBytes('enter,tab')).assertEqual('\r\t')
      expect(keysToBytes(' enter , tab ')).assertEqual('\r\t')
      expect(keysToBytes('nope')).assertEqual('')
      expect(keysToBytes('enter,nope')).assertEqual('')
      expect(keysToBytes('C-1')).assertEqual('')
      expect(keysToBytes('')).assertEqual('')
    })
    // ---- PA:tab.rename 参数校验(空 title 拒 + index 解析)----
    it('renameIndexGuards', 0, () => {
      expect(renameOk('')).assertFalse()
      expect(renameOk('work')).assertTrue()
      expect(indexArg(-1, 0, 2)).assertEqual(0)
      expect(indexArg(1, 0, 2)).assertEqual(1)
      expect(indexArg(5, 0, 2)).assertEqual(-1)
      expect(indexArg(-1, 0, 0)).assertEqual(-1)
      expect(indexArg(0, 0, 1)).assertEqual(0)
    })
    // ---- PA:pane.split dir 白名单(缺省 h,白名单外拒)----
    it('splitDirWhitelist', 0, () => {
      expect(splitDirOf('')).assertEqual('h')
      expect(splitDirOf('h')).assertEqual('h')
      expect(splitDirOf('v')).assertEqual('v')
      expect(splitDirOf('x')).assertEqual('')
      expect(splitDirOf('H')).assertEqual('')
      expect(splitDirOf('hv')).assertEqual('')
    })
    // ---- PA:status 快照降级(vm 未设)----
    it('statusDegradesWithoutVm', 0, () => {
      const s = statusSnapshot()
      expect(s['bridge']).assertEqual(0)
      expect(s['vm']).assertEqual(0)
      expect(s['port']).assertEqual(18971)
      const r = handleCmd({ id: 9, cmd: 'ws.tree' })
      expect(r.ok).assertFalse()
      expect(r.error).assertEqual('vm-not-set')
    })
    // ---- PA:newWorkspaceNamed + 投影不变量 + renameTab(真档链)----
    it('wsNewNamedAndProjection', 0, () => {
      const vm = new WorkbenchVm()
      const id = vm.newWorkspaceNamed('pa-x')
      expect(id).assertEqual('w2')
      expect(vm.workspaces[vm.activeWs].name).assertEqual('pa-x')
      // 投影不变量:newTab 后 workspaces[activeWs].tabs 必须同引用
      vm.newTab()
      expect(vm.workspaces[vm.activeWs].tabs === vm.tabs).assertTrue()
      expect(vm.workspaces[vm.activeWs].tabs.length).assertEqual(2)
      // newPaneId 返回新 pane 且入树;renameTab 走 persist 链(不抛即过)
      const pid = vm.newPaneId('v')
      expect(vm.panes.indexOf(pid) >= 0).assertTrue()
      expect(vm.renameTab(0, 'renamed')).assertTrue()
      expect(vm.tabs[0].title).assertEqual('renamed')
      expect(vm.renameTab(0, '')).assertFalse()
      // 缺省名回退
      const id2 = vm.newWorkspaceNamed('')
      expect(vm.workspaces[vm.activeWs].name).assertEqual('workspace-3')
      expect(id2).assertEqual('w3')
    })
  })
}
