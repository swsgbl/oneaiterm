/**
 * tty7 M7b Git 写操作单元测试(ArkTS/hypium,无网环境)。
 *
 * 覆盖(对应 M7b 交付物 4;全纯函数,无 SSH 会话依赖):
 *   T1 quoteMsg:合法(中英文/空格/括号)→ 单引号包裹;非法字符集
 *      (单引号/反引号/$(/分号/竖线/>/<&)→ null;长度边界(空/201 字
 *      拒,200 字过;trim 后空拒)
 *   T2 cmdFor:stage/unstage/commit 命令拼接;路径含元字符单引号包裹;
 *      cwd/path/msg 非法 → null;未知 kind → null
 *   T3 isStaged/isUntracked:XY 首列分类全形态('M '/' M'/'??'/'A '/' D'
 *      /'MM'/短串)
 *   T4 pushDryText:空输出 → 一致文案;To 行剔除;更新行保留;>300 截断
 */
import { describe, it, expect } from '@ohos/hypium';
import { quoteMsg, quotePath, cmdFor, isStaged, isUntracked, pushDryText } from '../../../main/ets/tty7/git/GitService';

export default function gitWriteTest() {
  describe('tty7GitWrite', () => {
    // ===== T1 quoteMsg:合法/非法/边界 =====
    it('quotemsg_valid_invalid_and_length', 0, () => {
      // 合法:中英文/空格/括号/冒号 → 单引号包裹
      expect(quoteMsg('fix: 修复登录流程')).assertEqual('\'fix: 修复登录流程\'')
      expect(quoteMsg('add feature (v2)')).assertEqual('\'add feature (v2)\'')
      expect(quoteMsg('  trim me  ')).assertEqual('\'trim me\'') // trim 后包裹
      // 非法字符集逐一拒绝
      expect(quoteMsg('has \' quote')).assertNull()
      expect(quoteMsg('has \u0060 tick')).assertNull()
      expect(quoteMsg('has $(cmd)')).assertNull()
      expect(quoteMsg('has ; semi')).assertNull()
      expect(quoteMsg('has | pipe')).assertNull()
      expect(quoteMsg('has > gt')).assertNull()
      expect(quoteMsg('has < lt')).assertNull()
      expect(quoteMsg('has & amp')).assertNull()
      // 长度边界:空/纯空白 → null
      expect(quoteMsg('')).assertNull()
      expect(quoteMsg('   ')).assertNull()
      // 200 字过 / 201 字拒
      const s200: string = 'a'.repeat(200)
      const s201: string = 'a'.repeat(201)
      expect(quoteMsg(s200)).assertEqual('\'' + s200 + '\'')
      expect(quoteMsg(s201)).assertNull()
    })

    // ===== T2 cmdFor:stage/unstage/commit 命令构造 =====
    it('cmdfor_stage_unstage_commit', 0, () => {
      // stage:常规路径原样
      expect(cmdFor('stage', '.', 'src/a.ts')).assertEqual('git -C . add -- src/a.ts')
      // stage:untracked '??' 路径(含 ?)→ 单引号包裹
      expect(cmdFor('stage', '.', 'new?file.txt')).assertEqual('git -C . add -- \'new?file.txt\'')
      // stage:含空格路径 → 单引号包裹
      expect(cmdFor('stage', '/repo', 'my file.txt')).assertEqual('git -C /repo add -- \'my file.txt\'')
      // unstage:reset HEAD 形态
      expect(cmdFor('unstage', '.', 'src/a.ts')).assertEqual('git -C . reset HEAD -- src/a.ts')
      // commit:合法消息
      expect(cmdFor('commit', '.', 'fix: bug')).assertEqual('git -C . commit -m \'fix: bug\'')
      // commit:非法消息(含;)→ null 不构造
      expect(cmdFor('commit', '.', 'bad; rm -rf')).assertNull()
      // cwd 含空格 → quoteCwd 双引号包裹(既有语义)
      expect(cmdFor('stage', '/my repo', 'a.ts')).assertEqual('git -C "/my repo" add -- a.ts')
      // cwd 含引号 → null
      expect(cmdFor('stage', '/a"b', 'a.ts')).assertNull()
      // 路径含单引号 → null(quotePath 拒)
      expect(cmdFor('stage', '.', 'a\'b')).assertNull()
      // 路径含反斜杠 → null
      expect(cmdFor('stage', '.', 'a\\b')).assertNull()
      // 未知 kind → null
      expect(cmdFor('push', '.', 'origin')).assertNull()
      // 空路径 → null
      expect(cmdFor('stage', '.', '')).assertNull()
    })

    // ===== T3 XY 分类:isStaged/isUntracked 全形态 =====
    it('xystaged_untracked_classification', 0, () => {
      // 首列非空且非 '?' → 已暂存
      expect(isStaged('M ')).assertTrue() // staged 修改
      expect(isStaged('A ')).assertTrue() // staged 新增
      expect(isStaged('D ')).assertTrue() // staged 删除
      expect(isStaged('MM')).assertTrue() // 双态(首列非空)
      expect(isStaged('R ')).assertTrue() // staged 重命名
      // 首列空 → 未暂存
      expect(isStaged(' M')).assertFalse() // worktree 修改
      expect(isStaged(' D')).assertFalse() // worktree 删除
      // '??' untracked:首列 '?' → 未暂存
      expect(isStaged('??')).assertFalse()
      expect(isUntracked('??')).assertTrue()
      expect(isUntracked('M ')).assertFalse()
      expect(isUntracked(' M')).assertFalse()
      // 短串 → 双 false
      expect(isStaged('M')).assertFalse()
      expect(isStaged('')).assertFalse()
      expect(isUntracked('?')).assertFalse()
    })

    // ===== T4 pushDryText:输出解析 =====
    it('pushdrytext_parse_and_cap', 0, () => {
      // 空/纯空白 → 一致文案
      expect(pushDryText('')).assertEqual('无待推送内容(本地与远端一致)')
      expect(pushDryText('  \n  \n')).assertEqual('无待推送内容(本地与远端一致)')
      // 典型输出:To 行剔除,更新行保留
      const out1 = 'To github.com:user/repo.git\n   abc1234..def5678  main -> main'
      expect(pushDryText(out1)).assertEqual('abc1234..def5678  main -> main')
      // rejected 行保留(new branch 拒绝场景)
      const out2 = 'To github.com:user/repo.git\n   def5678..abc1234  HEAD -> main (rejected)\n   [new branch]      dev -> dev'
      const r2 = pushDryText(out2)
      expect(r2.includes('HEAD -> main (rejected)')).assertTrue()
      expect(r2.includes('[new branch]')).assertTrue()
      expect(r2.includes('To github')).assertFalse() // To 行必剔
      // >300 字截断加 …
      const big: string = 'x'.repeat(400)
      const r3 = pushDryText(big)
      expect(r3.length).assertEqual(301)
      expect(r3.substring(300)).assertEqual('…')
      // 'Total 0' 形态(git 2.x 空差异时干跑输出):保留原样
      expect(pushDryText('Everything up-to-date')).assertEqual('Everything up-to-date')
    })
  })
}
