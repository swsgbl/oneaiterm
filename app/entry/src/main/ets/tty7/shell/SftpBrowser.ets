/**
 * tty7 SFTP 目录浏览子组件(任务 tty7-M6b,RightPanel SFTP 页内容)。
 *
 * 复用现有 SFTP 能力只读浏览(不新建协议实现):SessionService.sshHandle()
 * + sftpOpen(sid) + sftpList(sid, path) —— 与 pages/SftpPanel 同一通道,
 * service 零改动。路径/排序纯函数抽 SftpDrawerLogic(单测共靶)。
 *
 * 挂载语义:if 分支重建(父级 termTick/active 条件驱动)→ aboutToAppear
 * 每次进入页签/连接刷新一次;目录点击 → list 重载;不做自动轮询。
 * V1 规则:entries/cwd @State 整体替换驱动 ForEach。
 *
 * 红线:下载/上传留 M7/M8(文件项点击 no-op);Zmodem 走旧界面通道不动;
 * 连接态判断纯查询(SessionService.getSessionId),绝不重连;错误只展示
 * + 重试,不崩不外抛。
 */
import { SessionService } from '../../service/SessionService';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { DrawerEntry, joinDir, parentDir, sortEntries } from './SftpDrawerLogic';

/** sftpList JSON 响应结构(与 pages/SftpPanel 同形;只取展示字段)。 */
interface DrawerListResp {
  dir: string
  files: DrawerEntry[]
}

@Component
export struct SftpBrowser {
  @Prop themeName: string = 'dark'
  @State cwd: string = '.'
  @State entries: DrawerEntry[] = []
  @State listing: boolean = false
  @State errText: string = ''
  private listed: boolean = false

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    this.refresh('.')
  }

  /** 首列(或重试)目录。失败只置错误态,不外抛。 */
  private refresh(path: string): void {
    const ssh = SessionService.sshHandle()
    const sid = SessionService.getSessionId()
    if (ssh === null || sid < 0) {
      this.errText = 'SSH 会话未连接'
      this.entries = []
      return
    }
    this.listing = true
    this.errText = ''
    const t0 = Date.now()
    ssh.sftpOpen(sid)
      .then((): Promise<string> => {
        return ssh.sftpList(sid, path)
      })
      .then((json: string): void => {
        let dir: string = path
        let files: DrawerEntry[] = []
        try {
          const resp = JSON.parse(json) as DrawerListResp
          dir = resp.dir
          if (resp.files !== null && resp.files !== undefined) {
            files = resp.files
          }
        } catch (e) {
          // 解析失败:留 path/空表,置错误态(不崩)
          this.errText = '目录列表解析失败'
        }
        this.cwd = dir
        this.entries = sortEntries(files) // V1:整体替换
        this.listed = true
        this.listing = false
        console.info(`sftp drawer list dir=${dir} n=${this.entries.length} ms=${Date.now() - t0}`)
      })
      .catch((e: Object): void => {
        this.listing = false
        this.errText = (e instanceof Error ? e.message : String(e)).substring(0, 60)
        if (!this.listed) {
          this.entries = []
        }
      })
  }

  /** 目录进入/返回统一入口(busy 守卫防连点)。 */
  private go(path: string): void {
    if (this.listing) {
      return
    }
    this.refresh(path)
  }

  build() {
    Column({ space: DesignTokens.SPACE_XS }) {
      // ===== 路径行:cwd + '..' 返回 =====
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(this.cwd)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('..')
          .fontSize(DesignTokens.FONT_LABEL)
          .fontColor(this.th().brand)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(DesignTokens.RADIUS_SM)
          .border({ width: 1, color: this.th().hairline })
          .onClick(() => this.go(parentDir(this.cwd)))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ===== 错误/加载态(短文,不占满) =====
      if (this.errText !== '') {
        Row({ space: DesignTokens.SPACE_SM }) {
          Text(this.errText)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().danger)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('重试')
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.th().brand)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .border({ width: 1, color: this.th().brand })
            .onClick(() => this.go(this.cwd))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else if (this.listing) {
        Text('加载中…')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
      }

      // ===== 条目列表(V1:entries 整体替换驱动) =====
      Scroll() {
        Column() {
          if (!this.listing && this.errText === '' && this.entries.length === 0) {
            Text('空目录')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
              .padding({ top: DesignTokens.SPACE_SM })
          }
          ForEach(this.entries, (e: DrawerEntry) => {
            Row({ space: DesignTokens.SPACE_XS }) {
              Text(e.isDir ? '▸' : '·')
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(e.isDir ? this.th().brand : this.th().inkSubtle)
              Text(e.name)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(e.isDir ? this.th().ink : this.th().inkSubtle)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 3, bottom: 3, left: 2, right: 2 })
            .borderRadius(DesignTokens.RADIUS_SM)
            .onClick(() => {
              if (e.isDir) {
                this.go(joinDir(this.cwd, e.name))
              } // 文件 no-op(下载/上传留 M7/M8)
            })
          }, (e: DrawerEntry) => this.cwd + '/' + e.name + (e.isDir ? '/d' : '/f'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: DesignTokens.SPACE_SM })
  }
}
