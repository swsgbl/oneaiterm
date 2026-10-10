/**
 * tty7 M7a GitService/RemoteCommandRunner 单元测试(ArkTS/hypium,无网环境)。
 *
 * 覆盖(对应 M7a 交付物 5;全纯函数,无 SSH 会话依赖):
 *   T1 porcelainLine:'XY path' 全形态('M '/' M'/'??'/'A '/' D'/'MM')
 *      → xy/path;短行/空行 → null
 *   T2 branchLine:'## main...origin/main [ahead 2, behind 1]' →
 *      branch/ahead/behind;detached('## HEAD (no branch)')→ branch='HEAD';
 *      无上游('## master')→ 0/0;非法(无 '## ' 前缀)→ null
 *   T3 logLine:'h|s|a|d' 四字段;subject 含 '|' 容错(中段全归 subject);
 *      字段不足 → null
 *   T4 RunnerBuffer:行缓冲切分 + 回显剔除 + __MARK__ 检测;半行碎片
 *      合并场景(一个输出行拆两个 chunk);标记后碎片忽略
 *   T5 quoteCwd:空 → null;含单/双引号/反斜杠 → null;含空格包引号;
 *      普通路径原样
 *   T6 RemoteCommandRunner 守卫:无远程会话(未 start)run → false
 *      (单测环境 RemoteTermHost 必未 start,纯静态查询)
 */
import { describe, it, expect } from '@ohos/hypium';
import { GitBranchInfo, GitFileEntry, GitCommit, GitService,
  porcelainLine, branchLine, logLine, quoteCwd } from '../../../main/ets/tty7/git/GitService';
import { RunnerBuffer, RemoteCommandRunner } from '../../../main/ets/tty7/git/RemoteCommandRunner';

export default function gitServiceTest() {
  describe('tty7GitService', () => {
    // ===== T1 porcelainLine:全形态 =====
    it('porcelainline_all_xy_forms', 0, () => {
      // 'M ' staged 修改
      const a = porcelainLine('M  src/a.ts')
      expect(a !== null).assertTrue()
      expect((a as object as Record<string, Object>)['xy']).assertEqual('M ')
      expect((a as object as Record<string, Object>)['path']).assertEqual('src/a.ts')
      // ' M' worktree 修改
      const b = porcelainLine(' M src/b.ts')
      expect((b as object as Record<string, Object>)['xy']).assertEqual(' M')
      expect((b as object as Record<string, Object>)['path']).assertEqual('src/b.ts')
      // '??' 未跟踪
      const c = porcelainLine('?? new.txt')
      expect((c as object as Record<string, Object>)['xy']).assertEqual('??')
      expect((c as object as Record<string, Object>)['path']).assertEqual('new.txt')
      // 'A ' 新增
      const d = porcelainLine('A  add.ts')
      expect((d as object as Record<string, Object>)['xy']).assertEqual('A ')
      // ' D' 删除
      const e = porcelainLine(' D del.ts')
      expect((e as object as Record<string, Object>)['xy']).assertEqual(' D')
      // 'MM' 双态
      const f = porcelainLine('MM both.ts')
      expect((f as object as Record<string, Object>)['xy']).assertEqual('MM')
      expect((f as object as Record<string, Object>)['path']).assertEqual('both.ts')
      // 非法:短行/空行
      expect(porcelainLine('')).assertNull()
      expect(porcelainLine('ab')).assertNull()
      expect(porcelainLine('abc')).assertNull()
    })

    // ===== T2 branchLine:ahead/behind + detached + 无上游 =====
    it('branchline_ahead_behind_and_detached', 0, () => {
      const a = branchLine('## main...origin/main [ahead 2, behind 1]')
      expect(a !== null).assertTrue()
      expect((a as object as Record<string, Object>)['branch']).assertEqual('main')
      expect((a as object as Record<string, Object>)['ahead']).assertEqual(2)
      expect((a as object as Record<string, Object>)['behind']).assertEqual(1)
      // detached
      const b = branchLine('## HEAD (no branch)')
      expect((b as object as Record<string, Object>)['branch']).assertEqual('HEAD')
      expect((b as object as Record<string, Object>)['ahead']).assertEqual(0)
      // 无上游
      const c = branchLine('## master')
      expect((c as object as Record<string, Object>)['branch']).assertEqual('master')
      expect((c as object as Record<string, Object>)['ahead']).assertEqual(0)
      expect((c as object as Record<string, Object>)['behind']).assertEqual(0)
      // 只 ahead
      const d = branchLine('## dev...origin/dev [ahead 3]')
      expect((d as object as Record<string, Object>)['ahead']).assertEqual(3)
      expect((d as object as Record<string, Object>)['behind']).assertEqual(0)
      // 非 '## ' 前缀 → null
      expect(branchLine('main')).assertNull()
      expect(branchLine('')).assertNull()
    })

    // ===== T3 logLine:四字段 + '|' 容错 =====
    it('logline_fields_and_pipe_in_subject', 0, () => {
      const a = logLine('abc1234|fix: login flow|张三|2026-10-10')
      expect(a !== null).assertTrue()
      expect((a as object as Record<string, Object>)['hash']).assertEqual('abc1234')
      expect((a as object as Record<string, Object>)['subject']).assertEqual('fix: login flow')
      expect((a as object as Record<string, Object>)['author']).assertEqual('张三')
      expect((a as object as Record<string, Object>)['date']).assertEqual('2026-10-10')
      // subject 含 '|':中段全归 subject(仅按首尾分界)
      const b = logLine('def5678|use A || B in parser|李四|2026-10-09')
      expect((b as object as Record<string, Object>)['subject']).assertEqual('use A || B in parser')
      expect((b as object as Record<string, Object>)['author']).assertEqual('李四')
      expect((b as object as Record<string, Object>)['date']).assertEqual('2026-10-09')
      // 字段不足 → null
      expect(logLine('abc|only|three')).assertNull()
      expect(logLine('')).assertNull()
    })

    // ===== T4 RunnerBuffer:行缓冲 + 回显剔除 + 标记检测 + 半行合并 =====
    it('runnerbuffer_feed_echo_strip_marker_detect', 0, () => {
      const cmd = 'git -C . status --porcelain=v1 -b'
      const full = cmd + '; echo __MARK__$?'
      // 模拟真实流:命令回显(带提示符) → 真实输出两行(半行碎片拆开)
      // → 标记行 → 后续提示符
      const buf = new RunnerBuffer()
      buf.prepare(full)
      // chunk1:提示符回显行 + 真实输出第一行前半
      let done = buf.feed('$ ' + full + '\r\n## main...origin/main [ahead 1]\r\n M src')
      expect(done).assertFalse() // 未收标记
      // chunk2:第一行后半 + 第二行整行 + 标记行(半行碎片合并验证)
      done = buf.feed('/a.ts\r\n?? new.txt\r\n__MARK__0\r\n$ ')
      expect(done).assertTrue() // 标记到
      expect(buf.out).assertEqual('## main...origin/main [ahead 1]\n M src/a.ts\n?? new.txt')
      expect(buf.rcOf()).assertEqual(0)
      expect(buf.code).assertEqual('0')
      // 标记后再喂碎片:忽略(不崩不追加)
      expect(buf.feed('garbage\nmore')).assertTrue()

      // 裸回显形态(无提示符前缀,整行等于命令行)也被剔除
      const b2 = new RunnerBuffer()
      b2.prepare(full)
      b2.feed(full + '\nok-line\n__MARK__0\n')
      expect(b2.out).assertEqual('ok-line')
      expect(b2.rcOf()).assertEqual(0)

      // 非零退出码:rc=128 → ok 判定 false 依据
      const b3 = new RunnerBuffer()
      b3.prepare(full)
      b3.feed('fatal: not a git repository\n__MARK__128\n')
      expect(b3.rcOf()).assertEqual(128)
      expect(b3.out).assertEqual('fatal: not a git repository')

      // reset 复位可复用
      b3.reset()
      expect(b3.rcOf()).assertEqual(-1)
      expect(b3.out).assertEqual('')
    })

    // ===== T5 quoteCwd:转义与拒绝 =====
    it('quotecwd_space_quote_rules', 0, () => {
      expect(quoteCwd('')).assertNull()
      expect(quoteCwd('/home/user')).assertEqual('/home/user')
      expect(quoteCwd('/path with space/repo')).assertEqual('"/path with space/repo"')
      expect(quoteCwd('/a"b')).assertNull() // 双引号拒绝
      expect(quoteCwd('/a\'b')).assertNull() // 单引号拒绝
      expect(quoteCwd('/a\\b')).assertNull() // 反斜杠拒绝
    })

    // ===== T6 RemoteCommandRunner 守卫:无远程会话 → false =====
    it('commandrunner_no_session_returns_false', 0, () => {
      // 单测环境无 SSH 会话(RemoteTermHost 未 start):run 必拒绝,
      // 不启动定时器不发命令(纯静态守卫,无网依赖)
      let called = false
      const started = RemoteCommandRunner.run('echo hi', 100, (_out: string, _ok: boolean): void => {
        called = true
      })
      expect(started).assertFalse()
      expect(called).assertFalse()
    })
  })
}
