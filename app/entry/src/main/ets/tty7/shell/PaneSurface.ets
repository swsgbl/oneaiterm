/**
 * tty7 pane 面组件(任务 tty7-M1c,升级自 M1b PanePlaceholder)。
 * 结构:标题行(paneId + zoom 钮 + 关闭钮)+ 内容区(M1c 阶段为 paneId
 * 大字水印;M3 接 Terminal Core 时仅替换内容区)。
 * 交互:点击=focusPane;关闭钮=closePane;zoom 钮回调 onZoom(由 PaneGrid
 * 绑定 vm.zoomToggle)。焦点叶 brand 2px 高亮边框。零业务 import。
 */
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';
import { AppIcons } from '../../common/AppIcons';
import { TermHost } from '../term/TermHost';
import { RemoteTermHost } from '../remote/RemoteTermHost';
import { TermPaneView } from '../term/TermPaneView';
import { HmhEventBridge } from '../agent/HmhEventBridge';
import { AgentEventBus } from '../agent/AgentEventBus';
import { buildFinishedAttention } from './ParityUi';
import { unifiedDataChannel } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PaneDropTargets, PaneRectEntry, PaneDragState } from '../model/PaneDropTargets';

const M1E_TAG: string = 'tty7.M1e'
const M1E_DOMAIN: number = 0x0301

/** 拖拽数据类型(M1e):自定义类型 'tty7.pane-drag'(非 TEXT 家族)——
 *  规避 TextInput 捕获层对 general.plain-text 的默认 drop 消费(文本拖入
 *  编辑框会插字);自定义类型无默认消费方,onDrop 事件可达根容器。
 *  paneId 经 UnifiedRecord(type, value) 泛型构造承载(value:string)。 */
const DRAG_TYPE: string = 'tty7.pane-drag'

@Component
export struct PaneSurface {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  paneId: string = ''
  /** zoom 切换回调(PaneGrid 绑定;组件自身不持有 zoom 语义)。 */
  onZoom: () => void = () => {
  }
  @State hoverClose: boolean = false
  /** M1e:拖拽高亮(可放目标 hover 边框;onDragEnter 置/onDragLeave 清)。 */
  @State dragOver: boolean = false
  /** M1e:本组件 onDragStart 携带的 paneId(onDragEnd 兜底换位用)。 */
  private dragPaneId: string = ''

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  /** 组件销毁清理:矩形注册表剔除本 pane(close/树重建后防幽灵矩形)。 */
  aboutToDisappear(): void {
    PaneDropTargets.unregister(this.paneId)
  }

  build() {
    Column() {
      // 标题行:paneId/会话标题 + zoom 钮(◎)+ 关闭钮(×)
      // M2b:绑会话显示 slot.title(非空优先);表达式读 vm.slotsRev(绑定字段)
      // 建立追踪——V1 方法调用不追踪,sessionTitle 纯查询。
      // M1e:整行 draggable,onDragStart 携带自定义类型 'tty7.pane.<id>'
      // (规避 TextInput 捕获层默认吞 plain-text drop);长按 500ms+移 10vp
      // 触发系统拖拽,不影响普通点击(zoom/关闭钮 onClick 正常,实测语义:
      // 点击位移<10vp 不起拖)。onDragEnd 兜底换位(覆盖捕获层吞 drop 场景)。
      Row({ space: DesignTokens.SPACE_XS }) {
        // M5b:agent 活跃标记——表达式读 vm.agentRev 建立追踪后调
        // bridge.activeOnPane 纯查询(run 未 final 时 '✦' 前缀;同 slotsRev 模式)
        Text((this.vm.agentRev >= 0 && HmhEventBridge.activeOnPane(this.paneId) ? '✦ ' : '') +
          (this.vm.slotsRev >= 0 ? this.vm.sessionTitle(this.paneId) : this.paneId))
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .layoutWeight(1)
          .fontColor(this.vm.focusedPane === this.paneId ? this.th().brand : this.th().inkSubtle)
        Text('◎')
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().iconMuted)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText(this.paneId + ' 缩放切换')
          .onClick(() => {
            this.vm.focusPane(this.paneId)
            this.onZoom()
          })
        Text(AppIcons.OP_DELETE)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.hoverClose ? this.th().danger : this.th().inkSubtle)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(DesignTokens.RADIUS_SM)
          .accessibilityText('关闭 ' + this.paneId)
          .onClick(() => this.vm.closePane(this.paneId))
          .onHover((h: boolean) => {
            this.hoverClose = h
          })
      }
      .width('100%')
      .height(20)
      .padding({ left: DesignTokens.SPACE_SM, right: DesignTokens.SPACE_SM })
      .alignItems(VerticalAlign.Center)
      .draggable(this.dragEnabled())
      .onDragStart((e: DragEvent) => {
        // 数据通道(主):同进程静态 PaneDragState——同 app 内拖拽 100% 可达,
        // 不依赖 UDMF 序列化(实勘:自定义类型 getData 取回失配)。
        // setData(bonus):跨窗口场景;try 吞自定义类型校验异常。
        this.dragPaneId = this.paneId
        PaneDragState.current = this.paneId
        try {
          const rec = new unifiedDataChannel.UnifiedRecord(DRAG_TYPE, this.paneId)
          e.setData(new unifiedDataChannel.UnifiedData(rec))
        } catch (e) {
          // UDMF 类型校验拒绝 → 静态通道已够,静默。
        }
        // CustomBuilder 允许 void:不设自定义拖影,系统用组件快照。
        hilog.info(M1E_DOMAIN, M1E_TAG, 'dragStart pane=%{public}s', this.paneId)
      })
      .onDragEnd((e: DragEvent) => {
        // 兜底换位:onDrop 不可达时(捕获层吞事件),以落点窗口坐标在
        // vm.dropTargetAt 找目标 pane 并换位。DRAG_SUCCESSFUL=0 表示
        // onDrop 已处理(主通道成功,不重复);其余(FAILED/CANCELED)走兜底。
        const srcId = this.dragPaneId
        this.dragPaneId = ''
        PaneDragState.current = ''
        hilog.info(M1E_DOMAIN, M1E_TAG, 'dragEnd pane=%{public}s result=%{public}d at %{public}d,%{public}d',
          srcId, e.getResult(), e.getWindowX(), e.getWindowY())
        if (srcId === '') {
          return
        }
        if (e.getResult() === DragResult.DRAG_SUCCESSFUL) {
          return
        }
        const tgt = this.vm.dropTargetAt(e.getWindowX(), e.getWindowY(), srcId)
        if (tgt !== '') {
          this.vm.swapPanes(srcId, tgt)
        }
      })

      // 内容区(M3a):绑定本 pane 的本地终端优先;否则 paneId 大字水印。
      // V1 规则:if 表达式直接读 vm 绑定字段 termTick 建立追踪(TermHost.bound()
      // 静态查询不追踪,termTick 变化驱动表达式重评,同 slotsRev 模式)。
      // M6a:本地或远程任一宿主 bound==paneId 均渲染终端;远程分支注入
      // model/writeFn/resizeFn(渲染键/捕获层/InputController 全复用)
      if (this.vm.termTick >= 0 && RemoteTermHost.bound() === this.paneId && RemoteTermHost.term() !== null) {
        TermPaneView({
          paneId: this.paneId,
          model: RemoteTermHost.term(),
          writeFn: (t: string): void => { RemoteTermHost.write(t) },
          resizeFn: (c: number, r: number): void => { RemoteTermHost.resize(c, r) },
          onDone: (): void => { this.onCmdDone(this.paneId) } // tty7-PB:完成通知
        })
      } else if (this.vm.termTick >= 0 && TermHost.bound() === this.paneId && TermHost.term() !== null) {
        TermPaneView({ paneId: this.paneId, onDone: (): void => { this.onCmdDone(this.paneId) } })
      } else {
        Column() {
          Text(this.paneId)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().inkSubtle)
            .opacity(0.55)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().panel)
    .borderRadius(DesignTokens.RADIUS_MD)
    .border({
      width: this.dragOver ? 2 : (this.vm.focusedPane === this.paneId ? 2 : 1),
      color: this.dragOver ? this.th().danger :
        (this.vm.focusedPane === this.paneId ? this.th().brand : this.th().hairline)
    })
    .onClick(() => this.vm.focusPane(this.paneId))
    // M1e drop 目标:onDragEnter/Leave 高亮(danger 2px 边框近似"可放");
    // onDrop 读拖源 paneId 换位。不设 allowDrop = 默认接受全部数据类型
    // (API12 枚举 Array<UniformDataType> 无自定义成员,设了反而拒收)。
    // 同 pane 自身 drop 忽略(dragIdFrom 提取后 id 相等守卫);命中矩形即
    // 整个 PaneSurface(含标题行/终端区),拖到内容区任意点都可换位。
    .onDragEnter((_e: DragEvent) => {
      this.dragOver = true
    })
    .onDragLeave((_e: DragEvent) => {
      this.dragOver = false
    })
    .onDrop((e: DragEvent) => {
      this.dragOver = false
      // 拖源 paneId:同进程静态通道优先(权威),UDMF getData 回落。
      let srcId = PaneDragState.current
      if (srcId === '') {
        srcId = this.dragIdFrom(e)
      }
      hilog.info(M1E_DOMAIN, M1E_TAG, 'drop on=%{public}s src=%{public}s', this.paneId, srcId)
      if (srcId === '' || srcId === this.paneId) {
        return
      }
      this.vm.swapPanes(srcId, this.paneId)
      // 标记成功:拖源 onDragEnd 见 SUCCESSFUL 即跳过兜底(否则换位被
      // 兜底二次 swap 换回)。
      e.setResult(DragResult.DRAG_SUCCESSFUL)
    })
    .onAreaChange((_o: Area, n: Area) => {
      // 矩形注册(onDragEnd 兜底落点判定数据源):globalPosition 即窗口坐标,
      // 与 DragEvent.getWindowX/Y 同系(v)。宽高数字化兜底 Length 联合类型。
      const r = new PaneRectEntry()
      r.paneId = this.paneId
      r.x = Number(n.globalPosition.x)
      r.y = Number(n.globalPosition.y)
      r.w = Number(n.width)
      r.h = Number(n.height)
      PaneDropTargets.update(r)
    })
  }

  /** tty7-PB:命令完成通知两层落点(探测 done 回调):
   *  a. StatusBar——vm.setStatus('✓ 命令完成 · paneId')(现有通道);
   *  b. RightPanel 开着时 emit attention 事件到 AgentEventBus
   *     (type 'attention' kind 'finished' paneId——Agent 面板可见)。 */
  private onCmdDone(paneId: string): void {
    this.vm.setStatus('✓ 命令完成 · ' + paneId)
    if (this.vm.rightPanelOpen) {
      AgentEventBus.instance().emit(buildFinishedAttention(paneId))
    }
  }

  /** 拖源可用:zoom 态禁拖(单叶无换位对象);多 pane 才有换位意义。 */
  private dragEnabled(): boolean {
    return this.vm.layout.zoomedPaneId === '' && this.vm.panes.length > 1
  }

  /** 从 DragEvent 提取拖源 paneId:UnifiedRecord(type,value) 消费侧——
   *  getType() 命中 DRAG_TYPE 后 getValue() 取 string paneId。 */
  private dragIdFrom(e: DragEvent): string {
    try {
      const ud = e.getData()
      const records = ud.getRecords()
      for (const rec of records) {
        if (rec.getType() === DRAG_TYPE) {
          const v = rec.getValue()
          if (typeof v === 'string') {
            return v
          }
        }
      }
    } catch (e) {
      // getData 无数据(BusinessError 190001/190002)→ 无拖源,静默。
    }
    return ''
  }
}
