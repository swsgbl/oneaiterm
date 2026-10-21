/**
 * AppI18n 纯函数单元测试(GUI-i18n 棒)。
 * 覆盖:localeOf 归一/缺省、nextLocale 循环、tr 三级回退
 * (当前词典→zh→key)、关键界面键在 zh 词典全量存在
 * (侧栏/引导五步/palette 命令——防 label=key 转换漏键)。
 */
import { describe, it, expect } from '@ohos/hypium';
import { localeOf, nextLocale, localeName, tr } from '../../../main/ets/common/AppI18n';

export default function appI18nTest() {
  describe('workbenchAppI18n', () => {
    it('localeof_normalizes_and_defaults', 0, () => {
      expect(localeOf('en')).assertEqual('en-US')
      expect(localeOf('EN-US')).assertEqual('en-US')
      expect(localeOf('en-us')).assertEqual('en-US')
      expect(localeOf('zh-CN')).assertEqual('zh-CN')
      expect(localeOf('')).assertEqual('zh-CN')
      expect(localeOf('fr-FR')).assertEqual('zh-CN')
    })

    it('nextlocale_cycles_between_two', 0, () => {
      expect(nextLocale('zh-CN')).assertEqual('en-US')
      expect(nextLocale('en-US')).assertEqual('zh-CN')
      expect(nextLocale('garbage')).assertEqual('en-US')
    })

    it('localename_display', 0, () => {
      expect(localeName('zh-CN')).assertEqual('中文')
      expect(localeName('en-US')).assertEqual('English')
    })

    it('tr_resolves_both_locales', 0, () => {
      expect(tr('zh-CN', 'sb.connections')).assertEqual('连接')
      expect(tr('en-US', 'sb.connections')).assertEqual('Connect')
      expect(tr('zh-CN', 'guide.finish')).assertEqual('开始使用')
      expect(tr('en-US', 'guide.finish')).assertEqual('Get started')
    })

    it('tr_en_falls_back_to_zh_then_key', 0, () => {
      // en 刻意缺键(单测靶 test.zhoneonly)→ zh 兜底
      expect(tr('en-US', 'test.zhoneonly')).assertEqual('仅中文值')
      expect(tr('zh-CN', 'test.zhoneonly')).assertEqual('仅中文值')
      // 双语都缺 → key 原样
      expect(tr('zh-CN', 'no.such.key')).assertEqual('no.such.key')
      expect(tr('en-US', 'no.such.key')).assertEqual('no.such.key')
    })

    it('palette_command_keys_all_in_dict', 0, () => {
      // label=key 转换防漏:palette 命令键必须全部可译(至少 zh 基准)
      const keys: string[] = [
        'cmd.split.h', 'cmd.split.v', 'cmd.pane.close', 'cmd.pane.zoom',
        'cmd.tab.new', 'cmd.tab.close', 'cmd.panel.ai', 'cmd.panel.git',
        'cmd.panel.conn', 'cmd.session.local', 'cmd.session.ssh',
        'cmd.tunnel.start', 'cmd.tunnel.stop', 'cmd.tunnel.status',
        'cmd.session.end', 'cmd.session.telnet', 'cmd.ws.new',
        'cmd.cli.status', 'cmd.term.search', 'cmd.theme.toggle',
        'cmd.git.commit', 'cmd.help.guide', 'cmd.help.language', 'cmd.settings'
      ]
      for (const k of keys) {
        expect(tr('zh-CN', k) !== k).assertTrue()
        expect(tr('en-US', k) !== k).assertTrue()
      }
    })

    it('settings_panel_keys_translatable', 0, () => {
      const keys: string[] = ['set.title', 'set.theme', 'set.theme.dark', 'set.theme.light',
        'set.language', 'set.bridge', 'set.version', 'set.done']
      for (const k of keys) {
        expect(tr('zh-CN', k) !== k).assertTrue()
        expect(tr('en-US', k) !== k).assertTrue()
      }
    })

    it('ux_polish_keys_translatable', 0, () => {
      // GUI 丝滑棒:空态/toast/确认/字号命令键
      const keys: string[] = ['pane.empty.hint', 'pane.empty.local', 'pane.empty.ssh', 'pane.empty.palette',
        'toast.ended', 'toast.localbound', 'toast.sshok', 'toast.font', 'toast.fontreset',
        'confirm.close.title', 'confirm.close.msg', 'confirm.close.tabMsg', 'confirm.close.cancel', 'confirm.close.ok',
        'cmd.view.fontup', 'cmd.view.fontdown', 'cmd.view.fontreset']
      for (const k of keys) {
        expect(tr('zh-CN', k) !== k).assertTrue()
        expect(tr('en-US', k) !== k).assertTrue()
      }
    })

    it('guide_five_steps_translatable', 0, () => {
      for (let i = 0; i < 5; i++) {
        expect(tr('zh-CN', 'guide.t' + i.toString()) !== 'guide.t' + i.toString()).assertTrue()
        expect(tr('en-US', 'guide.t' + i.toString()) !== 'guide.t' + i.toString()).assertTrue()
      }
    })

    it('sidebar_labels_and_tips_translatable', 0, () => {
      const keys: string[] = [
        'sb.newWorkspace', 'sb.connections', 'sb.git', 'sb.agent', 'sb.theme',
        'sb.expand', 'sb.collapse', 'sb.tip.switchWs', 'sb.tip.new',
        'sb.tip.conn', 'sb.tip.git', 'sb.tip.agent', 'sb.tip.theme'
      ]
      for (const k of keys) {
        expect(tr('zh-CN', k) !== k).assertTrue()
        expect(tr('en-US', k) !== k).assertTrue()
      }
    })
  })
}
