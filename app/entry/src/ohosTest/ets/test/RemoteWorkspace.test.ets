/**
 * tty7 M6a 远程工作区单元测试(ArkTS/hypium,无网环境)。
 *
 * 覆盖(对应 M6a 交付物 5;无档环境走降级断言,ConnStore 真档只读原则):
 *   T1 provider.open 无 connKey 记录 → null + error 事件(store 未就绪分支:
 *      单测环境无 ConnList 注册,getSharedStore() 必为 null)
 *   T2 RemoteTermHost 未 start:write/bound()/term()/stop() 全守卫无抛
 *   T3 vm.bindSshSession('nope'):provider 同步失败 → false 且 slot 不建
 *   T4 bindSession 元数据链:kind/connKey/title 写入 + unbind 清理
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkbenchVm } from '../../../main/ets/tty7/viewmodel/WorkbenchVm';
import { SshWorkspaceProvider } from '../../../main/ets/tty7/remote/RemoteWorkspaceProvider';
import { RemoteTermHost } from '../../../main/ets/tty7/remote/RemoteTermHost';

export default function remoteWorkspaceTest() {
  describe('tty7RemoteWorkspace', () => {
    // ===== T1 provider open:store 未就绪 → null + error 事件 =====
    it('provider_open_no_store_returns_null_with_error_event', 0, () => {
      // 单测环境无 ConnList 注册(它是唯一 setSharedStore 调用方),
      // getSharedStore() 必为 null → open 走 store 未就绪分支
      let ev = ''
      let data = ''
      const h = SshWorkspaceProvider.open('no-such-conn', 80, 24, (e: string, d: string): void => {
        ev = e
        data = d
      })
      expect(h).assertNull()
      expect(ev).assertEqual('error')
      expect(data.length > 0).assertTrue()
      expect(SshWorkspaceProvider.active()).assertFalse()
    })

    // ===== T2 RemoteTermHost 未 start:全静态口守卫无抛 =====
    it('remotehost_unstarted_guards_no_throw', 0, () => {
      RemoteTermHost.stop() // 确保未 start 基线(幂等)
      expect(RemoteTermHost.bound()).assertEqual('')
      expect(RemoteTermHost.term()).assertNull()
      RemoteTermHost.write('ls') // 无句柄 no-op,不抛
      RemoteTermHost.resize(80, 24) // 无 model no-op,不抛
      RemoteTermHost.stop() // 幂等再停,不抛
      expect(RemoteTermHost.bound()).assertEqual('')
    })

    // ===== T3 vm.bindSshSession:同步失败路径 → false 且 slot 不建 =====
    it('vm_bindssh_unknown_conn_returns_false_no_slot', 0, () => {
      const vm = new WorkbenchVm() // 无 context:基线 p1|h|p2,焦点 p1
      expect(vm.focusedPane).assertEqual('p1')
      const before = vm.sessionCount()
      expect(vm.bindSshSession('nope-conn')).assertFalse()
      expect(vm.sessionCount()).assertEqual(before) // slot 不建(不假成功)
      expect(vm.sessionOf('p1')).assertNull()
    })

    // ===== T4 bindSession 元数据链(ssh kind):写入 + unbind 清理 =====
    it('vm_bindsession_ssh_metadata_chain', 0, () => {
      const vm = new WorkbenchVm()
      expect(vm.bindSession('p2', 'ssh', 'conn-1', 'ssh 测试')).assertTrue()
      const s = vm.sessionOf('p2')
      expect(s !== null).assertTrue()
      expect((s as object as Record<string, Object>)['kind']).assertEqual('ssh')
      expect((s as object as Record<string, Object>)['connKey']).assertEqual('conn-1')
      expect((s as object as Record<string, Object>)['title']).assertEqual('ssh 测试')
      // 标题链:sessionTitle 取 slot.title(非空优先)
      expect(vm.sessionTitle('p2')).assertEqual('ssh 测试')
      vm.unbindSession('p2')
      expect(vm.sessionOf('p2')).assertNull()
      expect(vm.sessionCount()).assertEqual(0)
    })
  })
}
