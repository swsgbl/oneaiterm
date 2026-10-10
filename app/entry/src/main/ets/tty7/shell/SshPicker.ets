/**
 * tty7 SSH 连接选择浮层(任务 tty7-M6a;>1 条 ssh profile 时经 palette
 * '会话 · SSH 连接'打开)。结构镜像 WorkbenchPalette:全幅遮罩(点击关闭)
 * + 居中列表面板(名称 + user@host,点击→vm.bindSshSession(id)+关浮层)。
 *
 * 数据源:getSharedStore() 内存解密态(只读,绝不 load());列表在 build
 * 直接读(打开瞬间快照,浮层生命周期内不追新——添加连接走旧界面语义)。
 * 红线:零业务 service import;凭据字段(password/keyContent)绝不渲染。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { getSharedStore } from '../../store/ConnStore';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

/** 列表行展示模型(只保留展示字段)。 */
class SshRow {
  id: string = ''
  label: string = ''
}

@Component
export struct SshPicker {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  onClose: () => void = () => {
  }

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** ssh 类型连接列表(打开瞬间快照;只留 id/名称/user@host 展示字段)。 */
  private rows(): SshRow[] {
    const out: SshRow[] = []
    const store = getSharedStore()
    if (store === null) {
      return out
    }
    for (const c of store.connections) {
      if (c.type === 'ssh') {
        const r = new SshRow()
        r.id = c.id
        r.label = c.name + '  ' + c.user + '@' + c.host + ':' + c.port.toString()
        out.push(r)
      }
    }
    return out
  }

  build() {
    Stack() {
      // 全幅遮罩:点击空白关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(DesignTokens.SHADOW_LG_COLOR)
        .onClick(() => this.onClose())

      // 居中面板
      Column({ space: DesignTokens.SPACE_XS }) {
        Text('选择 SSH 连接')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .width('100%')

        Scroll() {
          Column({ space: DesignTokens.SPACE_XS }) {
            ForEach(this.rows(), (r: SshRow) => {
              Text(r.label)
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
                  this.onClose()
                  if (!this.vm.bindSshSession(r.id)) {
                    this.vm.setStatus('SSH 会话发起失败')
                  }
                })
            }, (r: SshRow) => r.id)
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
