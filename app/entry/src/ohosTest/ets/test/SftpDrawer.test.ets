/**
 * tty7 M6b RightPanel 抽屉化单元测试(ArkTS/hypium,无网环境)。
 *
 * 覆盖(对应 M6b 交付物 4;tab 切换逻辑在组件,事件列表保留由组件 @State +
 * if/else 分支结构保证,此处测纯函数值域 + 连接守卫):
 *   T1 drawerTabOf:页签白名单归一('sftp' 直通;其余含 ''/非法回 'agent')
 *   T2 joinDir/parentDir:远程路径拼接边界('.' 起点/根/尾斜杠/无斜杠相对名)
 *   T3 sortEntries:目录在前文件在后 + 名称序 + stable(等值保输入序)
 *   T4 连接守卫:SshWorkspaceProvider.active() 未连接纯查询 false(不重连;
 *      RightPanel SFTP 页连接态条件项,无会话环境即此态)
 */
import { describe, it, expect } from '@ohos/hypium';
import { DrawerEntry, drawerTabOf, joinDir, parentDir, sortEntries } from '../../../main/ets/tty7/shell/SftpDrawerLogic';
import { SshWorkspaceProvider } from '../../../main/ets/tty7/remote/RemoteWorkspaceProvider';

export default function sftpDrawerTest() {
  describe('tty7SftpDrawer', () => {
    // ===== T1 drawerTabOf:白名单归一 =====
    it('drawertab_of_normalizes_to_whitelist', 0, () => {
      expect(drawerTabOf('agent')).assertEqual('agent')
      expect(drawerTabOf('sftp')).assertEqual('sftp')
      expect(drawerTabOf('')).assertEqual('agent')
      expect(drawerTabOf('bogus')).assertEqual('agent')
      expect(drawerTabOf('SFTP')).assertEqual('agent') // 大小写敏感:非白名单回 agent
    })

    // ===== T2 joinDir/parentDir:路径拼接边界 =====
    it('joindir_parentdir_path_edges', 0, () => {
      // joinDir:'.'/空起点 → 裸名;尾斜杠直连;否则补 '/'
      expect(joinDir('.', 'home')).assertEqual('home')
      expect(joinDir('', 'home')).assertEqual('home')
      expect(joinDir('/', 'home')).assertEqual('/home')
      expect(joinDir('/home', 'src')).assertEqual('/home/src')
      expect(joinDir('/home/', 'src')).assertEqual('/home/src')
      // parentDir:'.'/'/'/空原样;无斜杠回 '.';根下回 '/';否则砍尾段
      expect(parentDir('.')).assertEqual('.')
      expect(parentDir('/')).assertEqual('/')
      expect(parentDir('')).assertEqual('')
      expect(parentDir('home')).assertEqual('.')
      expect(parentDir('/home')).assertEqual('/')
      expect(parentDir('/home/src')).assertEqual('/home')
      expect(parentDir('/a/b/c')).assertEqual('/a/b')
    })

    // ===== T3 sortEntries:目录在前 + 名称序 + stable =====
    it('sortentries_dirs_first_name_order_stable', 0, () => {
      const mk = (name: string, isDir: boolean): DrawerEntry => {
        const e = new DrawerEntry()
        e.name = name
        e.isDir = isDir
        return e
      }
      const src: DrawerEntry[] = [
        mk('zeta.txt', false),
        mk('beta', true),
        mk('alpha.txt', false),
        mk('alpha', true)
      ]
      const out = sortEntries(src)
      expect(out.length).assertEqual(4)
      // 目录在前(名称序):alpha, beta;文件在后:alpha.txt, zeta.txt
      expect(out[0].name).assertEqual('alpha')
      expect(out[0].isDir).assertTrue()
      expect(out[1].name).assertEqual('beta')
      expect(out[1].isDir).assertTrue()
      expect(out[2].name).assertEqual('alpha.txt')
      expect(out[2].isDir).assertFalse()
      expect(out[3].name).assertEqual('zeta.txt')
      // stable:等值(同 isDir 同名)保输入序
      const dup: DrawerEntry[] = [mk('x', false), mk('x', false)]
      const out2 = sortEntries(dup)
      expect(out2[0] === dup[0]).assertTrue()
      expect(out2[1] === dup[1]).assertTrue()
      // 入参不被动(新数组)
      expect(src !== out).assertTrue()
      expect(src[0].name).assertEqual('zeta.txt')
    })

    // ===== T4 连接守卫:未连接纯查询 false(不重连) =====
    it('sshprovider_active_false_when_no_session', 0, () => {
      // 单测环境无会话(getSharedStore() 为 null,open 必失败):active() 纯
      // 静态字段查询,无网络动作——RightPanel SFTP 页未连接分支依据
      expect(SshWorkspaceProvider.active()).assertFalse()
    })
  })
}
