/**
 * tty7 Git 页只读子组件(任务 tty7-M7a,RightPanel Git 页内容)。
 *
 * 经 GitService(status/log)只读查询远程仓库:顶行 branch + ahead/behind,
 * 文件列表(XY 徽标色),最近提交列表(≤10);diffStat 摘要行。写操作
 * (stage/commit)留 M7b——本页零写入口。
 *
 * 挂载语义(照抄 SftpBrowser):if 分支重建(父级 termTick/active 条件
 * 驱动)→ aboutToAppear 每次进入页签自动刷一次;刷新钮手动重刷;
 * 无轮询。V1 规则:全部 @State 数组/对象整体替换驱动 ForEach。
 *
 * 错误态:err 非空显示错误行 + 重试钮(不崩不外抛;busy 守卫防连点)。
 * 红线:cwd 只来自 SFTP 浏览路径(当前取 SessionService 当前会话语义,
 * M7b 接 SFTP 浏览路径注入);输出不涉凭据。
 */
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { GitBranchInfo, GitFileEntry, GitCommit, GitService } from '../git/GitService';
import { RemoteCommandRunner } from '../git/RemoteCommandRunner';

@Component
export struct GitBrowser {
  @Prop themeName: string = 'dark'
  @State branch: string = ''
  @State ahead: number = 0
  @State behind: number = 0
  @State files: GitFileEntry[] = []
  @State commits: GitCommit[] = []
  @State errText: string = ''
  @State loading: boolean = false
  private loaded: boolean = false

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    this.refresh()
  }

  /** 刷新:status + log 串行(runner 单飞;首命令忙 → 忽略本次)。 */
  private refresh(): void {
    if (this.loading) {
      return
    }
    // cwd:当前默认 '.'(远程 home;M7b 接 SFTP 浏览路径注入)
    this.loading = true
    this.errText = ''
    GitService.status('.', (b: GitBranchInfo | null, files: GitFileEntry[], err: string): void => {
      if (b !== null) {
        this.branch = b.branch
        this.ahead = b.ahead
        this.behind = b.behind
      }
      this.files = files // V1:整体替换
      if (err !== '') {
        this.errText = err
        this.loading = false
        return
      }
      GitService.log('.', 10, (list: GitCommit[], lerr: string): void => {
        this.commits = list // V1:整体替换
        if (lerr !== '') {
          this.errText = lerr
        }
        this.loading = false
      })
    })
  }

  /** 分支行文案:'main ↑2 ↓1' / 无 ahead-behind 只 branch。 */
  private branchText(): string {
    let s = this.branch !== '' ? this.branch : '…'
    if (this.ahead > 0) {
      s += ' ↑' + this.ahead.toString()
    }
    if (this.behind > 0) {
      s += ' ↓' + this.behind.toString()
    }
    return s
  }

  /** XY 徽标色:A=success,M=brand,D=danger,??/其余=inkSubtle。 */
  private xyColor(xy: string): number {
    if (xy.charAt(0) === 'A' || xy.charAt(1) === 'A') {
      return this.th().success
    }
    if (xy.charAt(0) === 'D' || xy.charAt(1) === 'D') {
      return this.th().danger
    }
    if (xy.charAt(0) === 'M' || xy.charAt(1) === 'M') {
      return this.th().brand
    }
    return this.th().inkSubtle
  }

  /** 徽标显示:去尾空格('M ' → 'M';' M' → 'M';'??' 原样)。 */
  private xyLabel(xy: string): string {
    const t = xy.trim()
    return t === '' ? '?' : t
  }

  build() {
    Column({ space: DesignTokens.SPACE_XS }) {
      // ===== 顶行:branch + ahead/behind + 刷新钮 =====
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(this.branchText())
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.loading ? '…' : '↻')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().brand)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .border({ width: 1, color: this.th().hairline })
          .accessibilityText('刷新 git 状态')
          .onClick(() => this.refresh())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ===== 错误行 + 重试 =====
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
            .onClick(() => this.refresh())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ===== 变更文件列表 =====
      Scroll() {
        Column() {
          if (this.errText === '' && this.files.length === 0 && !this.loading) {
            Text('无变更文件')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
              .padding({ top: DesignTokens.SPACE_XS })
          }
          ForEach(this.files, (f: GitFileEntry) => {
            Row({ space: DesignTokens.SPACE_XS }) {
              Text(this.xyLabel(f.xy))
                .fontSize(DesignTokens.FONT_LABEL)
                .fontColor(this.xyColor(f.xy))
                .width(18)
                .textAlign(TextAlign.Center)
                .padding({ top: 1, bottom: 1 })
                .borderRadius(DesignTokens.RADIUS_SM)
                .border({ width: 1, color: this.xyColor(f.xy) })
              Text(f.path)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 2, bottom: 2 })
          }, (f: GitFileEntry) => f.xy + ':' + f.path)

          // ===== 最近提交列表(hash 前 7 + subject + date) =====
          if (this.commits.length > 0) {
            Text('最近提交')
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.th().inkSubtle)
              .padding({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_XS })
            ForEach(this.commits, (c: GitCommit) => {
              Row({ space: DesignTokens.SPACE_XS }) {
                Text(c.hash.length >= 7 ? c.hash.substring(0, 7) : c.hash)
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().brand)
                Text(c.subject)
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().ink)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(c.date)
                  .fontSize(DesignTokens.FONT_CAPTION)
                  .fontColor(this.th().inkSubtle)
              }
              .width('100%')
              .padding({ top: 2, bottom: 2 })
            }, (c: GitCommit) => c.hash + ':' + c.date)
          }
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
