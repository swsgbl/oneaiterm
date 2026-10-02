// 官方 FileSidebar 复刻(本地设备版):文件/目录浏览 + 面包屑 + 基本信息卡
import fs from '@ohos.file.fs';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';

interface FileRow {
  name: string
  isDir: boolean
  size: number
  mtime: number
}

@Component
export struct FileSidebar {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State cwd: string = '/data/local/home'
  @State rows: FileRow[] = []
  @State err: string = ''
  @State selected: string = ''

  aboutToAppear(): void {
    this.list()
  }

  list(): void {
    this.err = ''
    this.rows = []
    try {
      const names = fs.listFileSync(this.cwd)
      const out: FileRow[] = []
      for (const n of names) {
        const full = this.cwd + '/' + n
        let isDir = false
        let size = 0
        let mtime = 0
        try {
          const st = fs.statSync(full)
          isDir = st.isDirectory()
          size = st.size
          mtime = st.mtime
        } catch (e) {
          continue
        }
        out.push({ name: n, isDir: isDir, size: size, mtime: mtime })
      }
      out.sort((a: FileRow, b: FileRow) => {
        if (a.isDir !== b.isDir) {
          return a.isDir ? -1 : 1
        }
        return a.name < b.name ? -1 : 1
      })
      this.rows = out
    } catch (e) {
      this.err = '无法读取目录(权限受限)'
    }
  }

  enter(name: string): void {
    this.cwd = this.cwd + '/' + name
    this.list()
  }

  up(): void {
    const i = this.cwd.lastIndexOf('/')
    if (i > 0) {
      this.cwd = this.cwd.substring(0, i)
      this.list()
    }
  }

  fmtSize(n: number): string {
    if (n < 1024) {
      return n.toString() + 'B'
    }
    if (n < 1048576) {
      return (n / 1024).toFixed(1) + 'K'
    }
    return (n / 1048576).toFixed(1) + 'M'
  }

  build() {
    Column({ space: 6 }) {
      Text('文件')
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .padding({ top: 10, left: 4 })
      // 面包屑 + 上级
      Row({ space: 4 }) {
        Text('↑')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
          .padding(DesignTokens.SPACE_XS)
          .onClick(() => this.up())
        Text(this.cwd)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      if (this.err !== '') {
        Text(this.err)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().danger)
          .padding(DesignTokens.SPACE_SM)
      }
      List({ space: 1 }) {
        ForEach(this.rows, (r: FileRow) => {
          ListItem() {
            Row({ space: 6 }) {
              Text(r.isDir ? '📁' : '📄')
                .fontSize(DesignTokens.FONT_BODY)
              Text(r.name)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.selected === r.name ? this.th().brand : this.th().ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (!r.isDir) {
                Text(this.fmtSize(r.size))
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().inkSubtle)
              }
            }
            .width('100%')
            .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .backgroundColor(this.selected === r.name ? this.th().hover : Color.Transparent)
            .onClick(() => {
              if (r.isDir) {
                this.enter(r.name)
              } else {
                this.selected = r.name
              }
            })
          }
        }, (r: FileRow) => r.name + r.mtime.toString())
      }
      .layoutWeight(1)
      .width('100%')
      Text('本地文件浏览 · SFTP 远程文件经终端标签 ▦ 打开')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .padding(DesignTokens.SPACE_SM)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
  }
}
