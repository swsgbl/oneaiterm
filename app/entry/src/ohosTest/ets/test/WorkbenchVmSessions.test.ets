/**
 * tty7 WorkbenchVm 会话挂接 + 多工作区单元测试(任务 tty7-M2b,ArkTS/hypium)。
 *
 * 单测环境无 ability context:AppStorage 无 'ut.filesDir',WorkbenchVm 构造走
 * 恢复失败降级分支(单工作区单 tab 双 pane 基线),persist() 静默不落盘
 * (与 M2a WorkbenchStore.test 同模式)。
 *
 * 覆盖(对应 M2b 交付物 5):
 *   1. bind/unbind/sessionOf 基本链 + 重复绑定覆盖
 *   2. bind 不存在 pane → false
 *   3. closePane 联动清理 slot
 *   4. 多工作区:newWorkspace 后 tab 操作互不串(切回原工作区布局原样)
 *   5. 存档 v2 往返(2 工作区各 1 tab,含 1 个 slot)
 *   6. 存档 v1 降级读(手工构造 v1 JSON → 单工作区)
 *   7. slotsRev 递增(绑定/解绑各 +1)
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';
import { serializeWorkspaces, deserializeWorkspaces } from '../../../main/ets/tty7/store/WorkbenchStore';
import { WorkspaceState } from '../../../main/ets/tty7/model/WorkspaceState';

export default function workbenchVmSessionsTest() {
  describe('tty7WorkbenchVmSessions', () => {
    // ===== 1. bind/unbind/sessionOf 基本链 + 覆盖 =====
    it('bind_unbind_sessionof_chain_with_override', 0, () => {
      const vm = new WorkbenchVm() // p1|h|p2,焦点 p1
      expect(vm.sessionOf('p1')).assertNull()
      expect(vm.bindSession('p1', 'local', '', 'local shell')).assertTrue()
      const s = vm.sessionOf('p1')
      expect(s !== null).assertTrue()
      expect((s as object as Record<string, Object>)['title']).assertEqual('local shell')
      expect(vm.sessionCount()).assertEqual(1)
      expect(vm.statusText.indexOf('sess 1') >= 0).assertTrue()
      // 重复绑定=覆盖(不新增槽)
      expect(vm.bindSession('p1', 'ssh', 'conn-1', 'prod-box')).assertTrue()
      expect(vm.sessionCount()).assertEqual(1)
      const s2 = vm.sessionOf('p1')
      expect((s2 as object as Record<string, Object>)['kind']).assertEqual('ssh')
      expect((s2 as object as Record<string, Object>)['connKey']).assertEqual('conn-1')
      // 解除
      vm.unbindSession('p1')
      expect(vm.sessionOf('p1')).assertNull()
      expect(vm.sessionCount()).assertEqual(0)
      // assertLessThan 本机 hypium 无此方法(TypeError)——indexOf<0 用 assertTrue 表达
      expect(vm.statusText.indexOf('sess') < 0).assertTrue()
      // 再解(no-op,不炸)
      vm.unbindSession('p1')
      expect(vm.sessionCount()).assertEqual(0)
    })

    // ===== 2. bind 不存在 pane → false =====
    it('bind_unknown_pane_returns_false', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.bindSession('Z', 'local', '', 'x')).assertFalse()
      expect(vm.sessionCount()).assertEqual(0)
      expect(vm.slotsRev).assertEqual(0)
    })

    // ===== 3. closePane 联动清理 slot =====
    it('closepane_prunes_orphan_slot', 0, () => {
      const vm = new WorkbenchVm() // p1|h|p2
      vm.bindSession('p2', 'local', '', 'local shell')
      expect(vm.sessionCount()).assertEqual(1)
      vm.closePane('p2') // 树折叠为单叶 p1
      expect(vm.panes.join(',')).assertEqual('p1')
      expect(vm.sessionOf('p2')).assertNull()
      expect(vm.sessionCount()).assertEqual(0)
      // assertLessThan 本机 hypium 无此方法(TypeError)——indexOf<0 用 assertTrue 表达
      expect(vm.statusText.indexOf('sess') < 0).assertTrue()
    })

    // ===== 4. 多工作区独立 =====
    it('workspaces_tabs_are_isolated', 0, () => {
      const vm = new WorkbenchVm() // ws1 tab1: p1|h|p2
      expect(vm.workspaces.length).assertEqual(1)
      vm.newWorkspace() // ws2:空工作区(单 tab 空模型)
      expect(vm.workspaces.length).assertEqual(2)
      expect(vm.activeWs).assertEqual(1)
      expect(vm.panes.join(',')).assertEqual('') // 空模型引导
      vm.newPane('v') // ws2 首 pane p1
      expect(vm.panes.join(',')).assertEqual('p1')
      // 切回 ws1:布局原样
      vm.switchWorkspace(0)
      expect(vm.panes.join(',')).assertEqual('p1,p2')
      // 再切 ws2:其布局原样(记忆)
      vm.switchWorkspace(1)
      expect(vm.panes.join(',')).assertEqual('p1')
      // 切换守卫:越界/同位 no-op
      vm.switchWorkspace(9)
      expect(vm.activeWs).assertEqual(1)
      vm.switchWorkspace(1)
      expect(vm.activeWs).assertEqual(1)
    })

    // ===== 5. 存档 v2 往返(含 slot) =====
    it('archive_v2_roundtrip_with_slot', 0, () => {
      const vm = new WorkbenchVm() // ws1: p1|h|p2
      vm.bindSession('p1', 'local', '', 'local shell')
      vm.newWorkspace() // ws2: 单 tab 空模型 → 建 p1
      vm.newPane('h')
      const json = serializeWorkspaces(vm.workspaces, vm.activeWs)
      const back = deserializeWorkspaces(json)
      expect(back !== null).assertTrue()
      const wss = back as WorkspaceState[]
      expect(wss.length).assertEqual(2)
      expect(wss[0].tabs[0].sessions.length).assertEqual(1)
      expect(wss[0].tabs[0].sessions[0].paneId).assertEqual('p1')
      expect(wss[0].tabs[0].sessions[0].kind).assertEqual('local')
      expect(wss[0].tabs[0].sessions[0].title).assertEqual('local shell')
      expect(wss[0].tabs[0].sessions[0].connKey).assertEqual('')
      expect(wss[1].tabs[0].sessions.length).assertEqual(0)
    })

    // ===== 6. 存档 v1 降级读 =====
    it('archive_v1_downgrades_to_single_workspace', 0, () => {
      // 2 tab 的 v1 档(M2a 真实形态):降级后应包成 1 工作区 2 tab
      // (片段需包成 {...} 对象再入数组——裸 "key":value 拼接是非法 JSON)
      const t1 = '{"tabId":"t1","title":"tty7","layout":{"root":{"t":"s","id":"sp1","dir":"h","ratio":0.5,"ch":[{"t":"l","id":"p1"},{"t":"l","id":"p2"}]},"focused":"p1","zoomed":""},"sessions":[]}'
      const t2 = '{"tabId":"t2","title":"tty7-2","layout":{"root":{"t":"l","id":"p1"},"focused":"p1","zoomed":""},"sessions":[]}'
      const v1 = '{"v":1,"active":1,"tabs":[' + t1 + ',' + t2 + ']}'
      const back = deserializeWorkspaces(v1)
      expect(back !== null).assertTrue()
      const wss = back as WorkspaceState[]
      expect(wss.length).assertEqual(1)
      expect(wss[0].wsId).assertEqual('w1')
      expect(wss[0].tabs.length).assertEqual(2)
      expect(wss[0].tabs[0].tabId).assertEqual('t1')
      expect(wss[0].tabs[1].tabId).assertEqual('t2')
      expect(wss[0].tabs[1].title).assertEqual('tty7-2')
    })

    // ===== 7. slotsRev 递增 =====
    it('slotsrev_increments_on_bind_and_unbind', 0, () => {
      const vm = new WorkbenchVm()
      const r0 = vm.slotsRev
      vm.bindSession('p1', 'local', '', 'a')
      expect(vm.slotsRev).assertEqual(r0 + 1)
      vm.bindSession('p2', 'local', '', 'b')
      expect(vm.slotsRev).assertEqual(r0 + 2)
      vm.unbindSession('p1')
      expect(vm.slotsRev).assertEqual(r0 + 3)
      // no-op 解绑不递增
      vm.unbindSession('p1')
      expect(vm.slotsRev).assertEqual(r0 + 3)
      // 覆盖绑定也递增(标题变了需刷新)
      vm.bindSession('p2', 'ssh', 'k', 'c')
      expect(vm.slotsRev).assertEqual(r0 + 4)
    })
  })
}
