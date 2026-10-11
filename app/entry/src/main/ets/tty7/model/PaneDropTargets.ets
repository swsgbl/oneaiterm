/**
 * pane 全窗口矩形注册表(任务 tty7-M1e)。
 *
 * 用途:拖拽换位的 onDragEnd 兜底通道——PaneSurface.onAreaChange 上报
 * 本 pane 的窗口坐标矩形,WorkbenchVm.dropTargetAt 以 DragEvent.
 * getWindowX/Y 落点扫描本表找目标 pane(onDrop 主通道被捕获层吞事件时
 * 的兜底;两通道坐标同系,均为窗口 vp)。
 *
 * 放 model 层(非 UI 组件、非 service):WorkbenchVm 与 PaneSurface 共同
 * import,不引入 vm→UI 依赖(vm 红线:纯状态容器)。
 * 静态单例无状态;组件销毁 unregister 清除,树重建竞态由幂等吸收。
 */

/** 单个 pane 的窗口矩形(vp;globalPosition 同系)。 */
export class PaneRectEntry {
  paneId: string = ''
  x: number = 0
  y: number = 0
  w: number = 0
  h: number = 0
}

/** 拖拽进行态(任务 tty7-M1e):拖源 paneId 的同进程权威通道。
 *  实勘(VM 真机):UnifiedRecord(type,value) 自定义类型经 DragEvent.getData()
 *  取回时 type 失配(UDMF 对非标准类型名的序列化校验),setData/getData 通道
 *  不可靠——pane 拖拽是同 app 内交互,静态单例直读 100% 可达;setData 保留
 *  为跨窗口场景 bonus(try 吞校验异常)。onDragStart 写入,onDrop 消费,
 *  onDragEnd 清空。 */
export class PaneDragState {
  static current: string = ''
}

export class PaneDropTargets {
  private static map: Map<string, PaneRectEntry> = new Map()

  /** 上报/更新(同 paneId 覆盖)。 */
  static update(r: PaneRectEntry): void {
    PaneDropTargets.map.set(r.paneId, r)
  }

  static unregister(paneId: string): void {
    PaneDropTargets.map.delete(paneId)
  }

  /** 全部矩形(落点判定扫描;ArkTS 容器转数组惯用法)。 */
  static all(): PaneRectEntry[] {
    const out: PaneRectEntry[] = []
    PaneDropTargets.map.forEach((v: PaneRectEntry) => {
      out.push(v)
    })
    return out
  }
}
