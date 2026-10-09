/**
 * tty7 Tab 状态模型(任务 tty7-M2a,01 文档 Workspace→Tab→Pane→Session 四级模型的
 * Tab 级;Workspace 层与 SessionSlot 真会话挂载留 M2b)。
 *
 * 设计约定:
 * - 每 tab 独立一棵布局树(L1;M1 时代全 tab 共享一棵树,切 tab 布局不跟随——
 *   本文件即该修复的数据载体)。
 * - 纯数据:无方法、无 UI、无 service import;一切变换仍在 LayoutOps/WorkbenchVm。
 * - 秘密红线:SessionSlot.connKey 只存连接键名(如 ConnRec.id),绝不存密码/密钥
 *   内容——存档序列化(WorkbenchStore)原样落此结构,明文秘密即污染存档。
 * - M2a 阶段 sessions 恒为空数组(占位元数据结构,真会话 M2b 挂)。
 */
import { LayoutTreeModel } from '../layout/LayoutTree';

/** pane↔会话 绑定槽(M2a 仅占位元数据;M2b 挂真会话)。 */
export class SessionSlot {
  paneId: string = ''
  /** 会话种类:'local'|'ssh'|'stub'(M2a 恒 'stub')。 */
  kind: string = 'stub'
  /** 连接键名(M2b 用;秘密绝不进此结构)。 */
  connKey: string = ''
  title: string = ''
}

/** Tab 状态:独立布局树 + 会话槽表。 */
export class TabState {
  /** tab 标识('t'+自增,持久化保持稳定)。 */
  tabId: string = ''
  title: string = 'tty7'
  /** 本 tab 独立布局树;空模型(root 叶 paneId='')=单空叶。 */
  layout: LayoutTreeModel = new LayoutTreeModel()
  /** paneId → 会话槽;M2a 恒空数组。 */
  sessions: SessionSlot[] = []
}
