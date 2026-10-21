/**
 * UpdateChecker 纯函数单元测试(GUI-R3 检查更新)。
 * 覆盖:extractVersionName 解析、isNewer 语义比较。
 */
import { describe, it, expect } from '@ohos/hypium';
import { extractVersionName, isNewer, repoHome, repoIssues, repoReleases } from '../../../main/ets/service/UpdateChecker';

export default function updateCheckerTest() {
  describe('workbenchUpdateChecker', () => {
    it('repo_urls_localized_zh_vs_intl', 0, () => {
      // 用户指令:国内优先 AtomGit,国际优先 GitHub(按界面语言分流)
      expect(repoHome('zh-CN').indexOf('atomgit.com') >= 0).assertTrue()
      expect(repoHome('en-US').indexOf('github.com') >= 0).assertTrue()
      expect(repoIssues('zh-CN')).assertEqual(repoHome('zh-CN') + '/issues')
      expect(repoReleases('en-US').indexOf('/releases') >= 0).assertTrue()
    })

    it('extract_version_name', 0, () => {
      expect(extractVersionName('{"versionCode":2010000,"versionName":"2.1.0"}')).assertEqual('2.1.0')
      expect(extractVersionName('"versionName": "2.2.0"')).assertEqual('2.2.0')
      expect(extractVersionName('no version here')).assertEqual('')
      expect(extractVersionName('"versionName":"abc"')).assertEqual('')
    })

    it('is_newer_semver', 0, () => {
      expect(isNewer('2.1.0', '2.2.0')).assertTrue()
      expect(isNewer('2.1.0', '3.0.0')).assertTrue()
      expect(isNewer('2.1.0', '2.1.1')).assertTrue()
      expect(isNewer('2.1.0', '2.1.0')).assertFalse()
      expect(isNewer('2.2.0', '2.1.0')).assertFalse()
      expect(isNewer('2.1.0', '')).assertFalse()
      expect(isNewer('', '2.2.0')).assertFalse()
      expect(isNewer('2.1', '2.1.0')).assertFalse()
    })
  })
}
