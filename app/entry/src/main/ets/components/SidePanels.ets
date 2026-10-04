// 官方侧栏三视图复刻:快捷命令(QuickCommandsPanel)/历史(HistoryPanel)/个性化(Personalization)
import fs from '@ohos.file.fs';
import { SessionService } from '../service/SessionService';
import { TunnelService } from '../service/TunnelService';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { AppIcons } from '../common/AppIcons';
import { EmptyState } from './EmptyState';

interface QuickCmd {
  id: number
  name: string
  cmd: string
}

interface HistoryItem {
  cmd: string
  ts: number
}

class SideStore {
  static readJson(filesDir: string, file: string): string {
    const p = filesDir + '/' + file
    if (!fs.accessSync(p)) {
      return ''
    }
    try {
      return fs.readTextSync(p)
    } catch (e) {
      return ''
    }
  }

  static writeJson(filesDir: string, file: string, data: string): void {
    try {
      const p = filesDir + '/' + file
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, data)
      fs.closeSync(f)
    } catch (e) {
    }
  }
}

// ===== 快捷命令(官方 QuickCommandsPanel) =====
@Component
export struct QuickCommandsPanel {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State cmds: QuickCmd[] = []
  @State editing: boolean = false
  @State nName: string = ''
  @State nCmd: string = ''
  @State toast: string = ''
  private filesDir: string = ''

  aboutToAppear(): void {
    const ctx = getContext(this) as Context
    this.filesDir = ctx.filesDir
    const raw = SideStore.readJson(this.filesDir, 'quick_commands.json')
    if (raw !== '') {
      try {
        this.cmds = JSON.parse(raw) as QuickCmd[]
      } catch (e) {
        this.cmds = []
      }
    }
    if (this.cmds.length === 0) {
      const defaults: QuickCmd[] = [
        { id: 1, name: '系统信息', cmd: 'uname -a' },
        { id: 2, name: '磁盘', cmd: 'df -h' },
        { id: 3, name: '内存', cmd: 'free -m' },
        { id: 4, name: '进程', cmd: 'ps aux | head -20' },
        { id: 5, name: '网络', cmd: 'ip addr' }
      ]
      this.cmds = defaults
      this.persist()
    }
  }

  persist(): void {
    SideStore.writeJson(this.filesDir, 'quick_commands.json', JSON.stringify(this.cmds))
  }

  run(c: QuickCmd): void {
    const n = SessionService.write(c.cmd + '\n')
    if (n >= 0) {
      this.toast = '已发送: ' + c.name
    } else {
      this.toast = '无活动终端会话'
    }
    setTimeout(() => {
      this.toast = ''
    }, 2000)
  }

  add(): void {
    if (this.nName.trim() === '' || this.nCmd.trim() === '') {
      return
    }
    this.cmds.push({ id: Date.now(), name: this.nName.trim(), cmd: this.nCmd.trim() })
    this.persist()
    this.nName = ''
    this.nCmd = ''
    this.editing = false
  }

  del(id: number): void {
    this.cmds = this.cmds.filter(c => c.id !== id)
    this.persist()
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('快捷命令')
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
        Blank()
        Text(this.editing ? '×' : '✚')
          .fontSize(DesignTokens.FONT_HEADING)
          .fontColor(this.th().brand)
          .padding(DesignTokens.SPACE_XS)
          .onClick(() => {
            this.editing = !this.editing
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 10 })
      if (this.toast !== '') {
        Text(this.toast)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().success)
          .padding(DesignTokens.SPACE_XS)
      }
      if (this.editing) {
        Column({ space: 4 }) {
          TextInput({ placeholder: '名称', text: this.nName })
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().inputBg)
            .borderRadius(DesignTokens.RADIUS_SM)
            .onChange((v: string) => {
              this.nName = v
            })
          TextInput({ placeholder: '命令', text: this.nCmd })
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().inputBg)
            .borderRadius(DesignTokens.RADIUS_SM)
            .onChange((v: string) => {
              this.nCmd = v
            })
          Text('保存')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().onBrand)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(this.th().brand)
            .borderRadius(DesignTokens.RADIUS_SM)
            .alignSelf(ItemAlign.End)
            .onClick(() => this.add())
        }
        .width('100%')
        .padding(DesignTokens.SPACE_SM)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().panel)
      }
      if (this.cmds.length === 0) {
        EmptyState({
          icon: AppIcons.PANEL_QUICK,
          title: '暂无快捷命令',
          description: '点击右上角 + 添加常用命令'
        })
      }
      List({ space: 2 }) {
        ForEach(this.cmds, (c: QuickCmd) => {
          ListItem() {
            Row({ space: 6 }) {
              Text('⚡ ' + c.name)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .layoutWeight(1)
              Text(AppIcons.OP_RUN)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().brand)
                .padding(DesignTokens.SPACE_XS)
                .onClick(() => this.run(c))
              Text(AppIcons.OP_DELETE)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().inkSubtle)
                .padding(DesignTokens.SPACE_XS)
                .onClick(() => this.del(c.id))
            }
            .width('100%')
            .padding(DesignTokens.SPACE_SM)
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.th().panel)
          }
        }, (c: QuickCmd) => c.id.toString())
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6 })
    .backgroundColor(this.th().surface)
  }
}

// ===== 历史命令(官方 HistoryPanel) =====
@Component
export struct HistoryPanel {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State items: HistoryItem[] = []
  private filesDir: string = ''

  aboutToAppear(): void {
    const ctx = getContext(this) as Context
    this.filesDir = ctx.filesDir
    const raw = SideStore.readJson(this.filesDir, 'cmd_history.json')
    if (raw !== '') {
      try {
        this.items = JSON.parse(raw) as HistoryItem[]
      } catch (e) {
        this.items = []
      }
    }
  }

  build() {
    Column({ space: 6 }) {
      Text('历史命令')
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .padding({ top: 10, left: 4 })
      if (this.items.length === 0) {
        EmptyState({
          icon: AppIcons.PANEL_HISTORY,
          title: '暂无历史',
          description: '终端执行命令后记录于此'
        })
      }
      List({ space: 2 }) {
        ForEach(this.items, (h: HistoryItem, idx: number) => {
          ListItem() {
            Row({ space: 6 }) {
              Text(h.cmd)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(AppIcons.OP_RUN)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor(this.th().brand)
                .padding(DesignTokens.SPACE_XS)
                .onClick(() => SessionService.write(h.cmd + '\n'))
            }
            .width('100%')
            .padding(DesignTokens.SPACE_SM)
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.th().panel)
          }
        }, (h: HistoryItem, idx: number) => idx.toString() + h.ts.toString())
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6 })
    .backgroundColor(this.th().surface)
  }
}

// ===== 个性化(官方 SettingsTab→主题/终端主题 子集) =====
@Component
export struct PersonalizationPanel {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State theme: string = 'dark'
  @State termTheme: string = 'default'
  onThemeChange: (t: string) => void = (t: string) => {
  }

  build() {
    Column({ space: 8 }) {
      Text('个性化')
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .padding({ top: 10, left: 4 })
      Text('界面主题')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .alignSelf(ItemAlign.Start)
      Row({ space: 6 }) {
        ForEach(['dark', 'light'], (n: string) => {
          Text(n === 'dark' ? '暗色' : '浅色')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.theme === n ? this.th().brand : this.th().inkSubtle)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.theme === n ? this.th().hover : this.th().panel)
            .onClick(() => {
              this.theme = n
              this.onThemeChange(n)
            })
        }, (n: string) => n)
      }
      .width('100%')
      Text('终端配色')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .alignSelf(ItemAlign.Start)
      Column({ space: 2 }) {
        ForEach(['default', 'dracula', 'solarized-dark', 'gruvbox-dark', 'nord'], (n: string) => {
          Text(n)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.termTheme === n ? this.th().brand : this.th().inkSubtle)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.termTheme === n ? this.th().hover : Color.Transparent)
            .alignSelf(ItemAlign.Start)
            .onClick(() => {
              this.termTheme = n
            })
        }, (n: string) => n)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text('自定义背景/28 终端主题按官方路线接入')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .padding(DesignTokens.SPACE_SM)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6 })
    .backgroundColor(this.th().surface)
    .alignItems(HorizontalAlign.Start)
  }
}

// ===== 端口转发 -L(M8 relay-3 TunnelPanel) =====
@Component
export struct TunnelPanel {
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @StorageProp('ut.tunnel.status') status: string = 'off'
  @StorageProp('ut.tunnel.reason') reason: string = ''
  @StorageProp('ut.tunnel.active') active: number = 0
  @StorageProp('ut.tunnel.conns') conns: number = 0
  @State localPort: string = '9432'
  @State remoteHost: string = '127.0.0.1'
  @State remotePort: string = '22'
  @State busy: boolean = false

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('隧道')
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
        Blank()
        Text(this.status === 'running' ? '●' : '○')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.status === 'running' ? this.th().success : this.th().inkSubtle)
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 10 })

      if (this.status === 'error') {
        Text(this.reason)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().danger)
          .padding(DesignTokens.SPACE_XS)
      }

      Text('本地端口')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .alignSelf(ItemAlign.Start)
      TextInput({ text: this.localPort, placeholder: '9432' })
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().ink)
        .backgroundColor(this.th().inputBg)
        .onChange((v: string) => { this.localPort = v })
      Text('远端主机')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .alignSelf(ItemAlign.Start)
      TextInput({ text: this.remoteHost, placeholder: '127.0.0.1' })
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().ink)
        .backgroundColor(this.th().inputBg)
        .onChange((v: string) => { this.remoteHost = v })
      Text('远端端口')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .alignSelf(ItemAlign.Start)
      TextInput({ text: this.remotePort, placeholder: '22' })
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(this.th().ink)
        .backgroundColor(this.th().inputBg)
        .onChange((v: string) => { this.remotePort = v })

      Button(this.status === 'running' ? '停止' : '启动')
        .width('100%')
        .backgroundColor(this.status === 'running' ? this.th().danger : this.th().brand)
        .fontColor(this.th().surface)
        .enabled(!this.busy)
        .onClick(() => this.toggle())

      if (this.status === 'running') {
        Text('监听中 · 已转发 ' + this.conns.toString() + ' 连接' + (this.reason !== '' ? ' · ' + this.reason : ''))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8, bottom: 8 })
  }

  toggle(): void {
    if (this.busy) {
      return
    }
    if (this.status === 'running') {
      TunnelService.stop()
      return
    }
    const lp = parseInt(this.localPort)
    const rp = parseInt(this.remotePort)
    if (isNaN(lp) || isNaN(rp)) {
      AppStorage.setOrCreate('ut.tunnel.status', 'error')
      AppStorage.setOrCreate('ut.tunnel.reason', '端口必须是数字')
      return
    }
    this.busy = true
    TunnelService.start(lp, this.remoteHost.trim(), rp).then(() => {
      this.busy = false
    }).catch((_e: Object) => {
      this.busy = false
    })
  }
}
