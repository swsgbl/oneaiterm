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
import { GitBranchInfo, GitFileEntry, GitCommit, GitService,
  isStaged, isUntracked, quoteMsg } from '../git/GitService'; // +tty7-M7b: XY 分类/消息转义纯函数
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
  /** M7b: 提交消息输入行文本。 */
  @State msgInput: string = ''
  /** M7b: 操作反馈行(成功绿/失败红;'' = 不显示)。 */
  @State actionMsg: string = ''
  /** M7b: 反馈行是否成功色。 */
  @State actionOk: boolean = false
  /** M7b: 推送预演结果文本('' = 未预演/清空)。 */
  @State pushText: string = ''
  /** M7b: 写操作进行中(stage/commit/pushDry 任一)——提交钮/微钮禁用。 */
  @State writing: boolean = false
  private loaded: boolean = false
  /** M7b: palette 'Git · 提交' 焦点信号轮询链(自链式 setTimeout)。 */
  private focusTimer: number = -1

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    this.refresh()
    this.startFocusWatch()
  }

  aboutToDisappear(): void {
    if (this.focusTimer >= 0) {
      clearTimeout(this.focusTimer)
      this.focusTimer = -1
    }
  }

  /**
   * M7b: palette 'Git · 提交' 焦点信号轮询(500ms 自链式 setTimeout,
   * 本仓已证 setInterval 不在 SDK)。信号 = AppStorage 'ut.git.focus'
   * 单调递增数;变化且右面板开着 Git 页时 requestFocus 消息输入
   * (组件未挂载/控制器不可用静默降级)。无 staged 时不清信号——由
   * 信号发起方(palette)负责 statusText 提示,轮询侧只管聚焦。
   */
  private startFocusWatch(): void {
    let last = AppStorage.get<number>('ut.git.focus') ?? 0
    const tickFn = (): void => {
      try {
        const cur = AppStorage.get<number>('ut.git.focus') ?? 0
        if (cur !== last) {
          last = cur
          try {
            this.getUIContext().getFocusController().requestFocus('tty7GitMsg')
          } catch (e) {
            // 焦点控制器不可用:降级(用户手动点输入行)
          }
        }
      } finally {
        this.focusTimer = setTimeout(tickFn, 500)
      }
    }
    this.focusTimer = setTimeout(tickFn, 500)
  }

  /** 有已暂存条目(XY 首列非空且非 '?')——提交钮可用条件。 */
  private hasStaged(): boolean {
    for (const f of this.files) {
      if (isStaged(f.xy)) {
        return true
      }
    }
    return false
  }

  /**
   * M7b: 操作后刷新(写链路完成/发起失败都调)。写态未清时不抢跑
   * (loading 守卫内 writing 期跳过,写回调清 writing 后再引)。
   */
  private refreshAfterWrite(): void {
    this.refresh()
  }

  /** 刷新:status + log 串行(runner 单飞;首命令忙 → 忽略本次)。 */
  private refresh(): void {
    if (this.loading || this.writing) {
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

  /**
   * M7b: 条目微钮——已暂存 unstage(git reset HEAD --)/未暂存或
   * untracked stage(git add --)。cwd 取 '.'(同 status/log;SFTP 浏览
   * 路径注入留后续棒——当前语义=远程 home)。完成(含发起失败)后
   * 自动刷新 status+log 并落反馈行。失败文本落错误行(红色)。
   */
  private toggleStage(f: GitFileEntry): void {
    if (this.writing || this.loading) {
      return
    }
    const staged = isStaged(f.xy)
    const fin = (ok: boolean, err: string): void => {
      this.writing = false
      this.actionOk = ok
      this.actionMsg = (staged ? '取消暂存 ' : '暂存 ') + f.path + (ok ? ' ✓' : ' 失败: ' + err)
      this.refreshAfterWrite()
    }
    this.writing = true
    this.actionMsg = ''
    this.pushText = ''
    const started = staged
      ? GitService.unstage('.', f.path, fin)
      : GitService.stage('.', f.path, fin)
    if (!started) {
      // 发起失败(busy/非法路径):fin 已在 GitService 内同步回调
      this.writing = false
    }
  }

  /**
   * M7b: 提交——消息走 quoteMsg 双闸(null 时错误提示且**不清输入**);
   * 成功清输入+反馈;完成后刷新 status+log。无 staged 条目禁用(钮层)。
   */
  private doCommit(): void {
    if (this.writing || this.loading || !this.hasStaged()) {
      return
    }
    const q = quoteMsg(this.msgInput)
    if (q === null) {
      this.actionOk = false
      this.actionMsg = '消息非法(空/超 200 字/含引号·反引号·$·;·|·<>·&)'
      return
    }
    const fin = (ok: boolean, err: string): void => {
      this.writing = false
      this.actionOk = ok
      this.actionMsg = ok ? '已提交' : '提交失败: ' + err
      if (ok) {
        this.msgInput = ''
      }
      this.refreshAfterWrite()
    }
    this.writing = true
    this.actionMsg = ''
    this.pushText = ''
    const started = GitService.commit('.', this.msgInput, fin)
    if (!started) {
      this.writing = false
    }
  }

  /**
   * M7b: 推送预演——pushDry 干跑收集(不真推;真 push 留 M8 CLI 棒
   * 带二次确认)。结果落 pushText 行(inkSubtle 只读);失败落反馈行。
   */
  private doPushDry(): void {
    if (this.writing || this.loading) {
      return
    }
    const fin = (ahead: string, err: string): void => {
      this.writing = false
      if (err !== '') {
        this.actionOk = false
        this.actionMsg = '推送预演失败: ' + err
        this.pushText = ''
        return
      }
      this.actionOk = true
      this.actionMsg = ''
      this.pushText = ahead
    }
    this.writing = true
    this.actionMsg = ''
    this.pushText = ''
    const started = GitService.pushDry('.', 'origin', fin)
    if (!started) {
      this.writing = false
    }
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

      // ===== 操作反馈行(M7b:stage/commit/pushDry 结果;'' 不显示) =====
      if (this.actionMsg !== '') {
        Text(this.actionMsg)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.actionOk ? this.th().success : this.th().danger)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // ===== push 预演结果行(M7b:'推送预演' 钮产出;只读展示) =====
      if (this.pushText !== '') {
        Text(this.pushText)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ top: 2, bottom: 2 })
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
              // M7b: 条目尾操作微钮——XY 首列分类(首列非空且非'?'=已暂存
              // '-取消';首列空或'??'=未暂存/untracked '+暂存');写态中禁用
              if (!this.writing) {
                Text(isStaged(f.xy) ? '-取消' : '+暂存')
                  .fontSize(DesignTokens.FONT_LABEL)
                  .fontColor(isStaged(f.xy) ? this.th().warn : this.th().success)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(DesignTokens.RADIUS_SM)
                  .border({ width: 1, color: isStaged(f.xy) ? this.th().warn : this.th().success })
                  .onClick(() => this.toggleStage(f))
              }
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

      // ===== M7b 底部提交行:推送预演钮 + 消息输入 + 提交钮 =====
      Row({ space: DesignTokens.SPACE_XS }) {
        Text(this.writing ? '…' : '推送预演')
          .fontSize(DesignTokens.FONT_LABEL)
          .fontColor(this.writing ? this.th().inkSubtle : this.th().brand)
          .padding({ left: 6, right: 6, top: 5, bottom: 5 })
          .borderRadius(DesignTokens.RADIUS_SM)
          .border({ width: 1, color: this.writing ? this.th().hairline : this.th().brand })
          .onClick(() => this.doPushDry())
        TextInput({ placeholder: '提交消息…', text: this.msgInput })
          .id('tty7GitMsg') // M7b: palette 焦点信号 requestFocus 靶
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .placeholderColor(this.th().inkSubtle)
          .backgroundColor(this.th().inputBg)
          .border({ width: 1, color: this.th().hairline })
          .borderRadius(DesignTokens.RADIUS_MD)
          .height(30)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.msgInput = v
          })
          .onSubmit(() => this.doCommit())
        if (this.hasStaged() && !this.writing && !this.loading) {
          Text('提交')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().surface)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().brand)
            .onClick(() => this.doCommit())
        } else {
          Text('提交')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().hairline)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: DesignTokens.SPACE_XS })
    }
    .width('100%')
    .height('100%')
    .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: DesignTokens.SPACE_SM })
  }
}
