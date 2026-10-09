/**
 * tty7 壳内命令面板浮层(任务 tty7-M1d)。
 * 叠在 PaneGrid 之上(AppShell Stack):全幅半透明遮罩(点击空白 onClose)
 * + 居中 420px 面板(输入过滤 + 命令列表;点项 run() 后 onClose)。
 *
 * V1 响应式红线遵守:
 * - 过滤列表 = build 内直接表达式(this.visibleCmds() 读 @State query),
 *   query 变更 → build 重评 → ForEach 重 diff;不经 @Builder 传参。
 * - 命令点击回调直接闭包捕获 cmd 与 this.vm,无状态穿越。
 * 红线:零业务 import;命令集来自 PaletteCommands 纯注册表。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { paletteCmds, PaletteCmd } from './PaletteCommands';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

@Component
export struct WorkbenchPalette {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  onClose: () => void = () => {
  }
  @State query: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 过滤:label 含输入文本(大小写不敏感);空输入返回全表。 */
  private visibleCmds(): PaletteCmd[] {
    const all = paletteCmds()
    const q = this.query.trim().toLowerCase()
    if (q === '') {
      return all
    }
    const out: PaletteCmd[] = []
    for (const c of all) {
      if (c.label.toLowerCase().indexOf(q) >= 0) {
        out.push(c)
      }
    }
    return out
  }

  build() {
    Stack() {
      // 全幅遮罩:点击空白关闭(独立兄弟层,面板点击不冒泡到遮罩)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(DesignTokens.SHADOW_LG_COLOR)
        .onClick(() => this.onClose())

      // 居中面板(Stack 默认 Center)
      Column({ space: DesignTokens.SPACE_XS }) {
        TextInput({ placeholder: '输入命令...' })
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .placeholderColor(this.th().inkSubtle)
          .caretColor(this.th().brand)
          .backgroundColor(this.th().inputBg)
          .borderRadius(DesignTokens.RADIUS_MD)
          .height(34)
          .width('100%')
          .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD })
          .onChange((v: string) => {
            this.query = v
          })

        Scroll() {
          Column({ space: DesignTokens.SPACE_XS }) {
            ForEach(this.visibleCmds(), (c: PaletteCmd) => {
              Text(c.label)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor(this.th().ink)
                .width('100%')
                .height(44)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD })
                .borderRadius(DesignTokens.RADIUS_SM)
                .backgroundColor(this.th().hover)
                .onClick(() => {
                  c.run(this.vm)
                  this.onClose()
                })
            }, (c: PaletteCmd) => c.key)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Start)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width(420)
      .constraintSize({ maxHeight: '82%' })
      .padding(DesignTokens.SPACE_SM)
      .backgroundColor(this.th().panel)
      .borderRadius(DesignTokens.RADIUS_LG)
      .border({ width: 1, color: this.th().hairline })
    }
    .width('100%')
    .height('100%')
  }
}
