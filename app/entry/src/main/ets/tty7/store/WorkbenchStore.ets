/**
 * tty7 工作台存档层(任务 tty7-M2a:多 Tab 布局树 + 恢复)。
 *
 * 职责:TabState[] ↔ JSON 纯序列化/反序列化 + preferences 落盘。
 * 红线:
 * - 不 import 任何 UI 组件/WorkbenchVm(纯数据层,Vm 反向依赖本层)。
 * - 秘密绝不入档:只序列化结构(tabId/title/layout/sessions 键名),
 *   pane 内容、终端缓冲、凭据一概不落——SessionSlot.connKey 本身就只是键名。
 * - 损坏安全降级:任何解析/结构错误 deserialize 返回 null,调用方回默认基线。
 * - 上下文通道:复用 EntryAbility 发布的 AppStorage 'ut.filesDir'(全仓唯一
 *   context 通道,不新建第二套);无 context(单测环境)→ save/restore 静默不落盘。
 *
 * 存档格式(v1):
 *   { v:1, active:0, tabs:[ { tabId,title, layout:{ root:<node>, focused:'', zoomed:'' },
 *     sessions:[] } ] }
 * node 递归: {t:'l',id} | {t:'s',id,dir,ratio,ch:[...]}(手写递归,不 JSON 化
 * 类实例——反序列化必须重建 PaneLeaf/SplitNode 类实例,@Observed/V1 组件依赖)。
 */
import { LayoutTreeModel, LayoutNode, PaneLeaf, SplitNode, SplitDir } from '../layout/LayoutTree';
import { TabState, SessionSlot } from '../model/TabState';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'tty7.store';
const DOMAIN: number = 0x0117;
const PREF_NAME: string = 'ut_workbench';
const PREF_KEY: string = 'ut.workbench.v1';

/** 恢复结果载体(ArkTS 不鼓励匿名对象字面量,显式类)。 */
export class WorkbenchSnapshot {
  tabs: TabState[] = [];
  active: number = 0;
}

// ===================== 序列化 =====================

/** node → {t:'l',id} | {t:'s',id,dir,ratio,ch:[...]}(手写递归)。 */
function nodeToRecord(node: LayoutNode): Record<string, Object> {
  if (node instanceof SplitNode) {
    const sp = node as SplitNode;
    const rec: Record<string, Object> = {};
    rec['t'] = 's';
    rec['id'] = sp.id;
    rec['dir'] = sp.dir;
    rec['ratio'] = sp.ratio;
    const ch: Array<Object> = [];
    for (let i = 0; i < sp.children.length; i++) {
      ch.push(nodeToRecord(sp.children[i]));
    }
    rec['ch'] = ch as Object;
    return rec;
  }
  const leaf = node as PaneLeaf;
  const rec: Record<string, Object> = {};
  rec['t'] = 'l';
  rec['id'] = leaf.paneId;
  return rec;
}

/** tabs → 存档 JSON 字符串(轻结构,无秘密、无 pane 内容)。 */
export function serializeTabs(tabs: TabState[], activeTab: number): string {
  const tArr: Array<Record<string, Object>> = [];
  for (let i = 0; i < tabs.length; i++) {
    const t = tabs[i];
    const rec: Record<string, Object> = {};
    rec['tabId'] = t.tabId;
    rec['title'] = t.title;
    const lay: Record<string, Object> = {};
    lay['root'] = nodeToRecord(t.layout.root);
    lay['focused'] = t.layout.focusedPaneId;
    lay['zoomed'] = t.layout.zoomedPaneId;
    rec['layout'] = lay as Object;
    // sessions: M2a 恒空——仍按结构序列化(前向兼容 M2b)
    const sArr: Array<Record<string, Object>> = [];
    for (let s = 0; s < t.sessions.length; s++) {
      const slot = t.sessions[s];
      const sr: Record<string, Object> = {};
      sr['paneId'] = slot.paneId;
      sr['kind'] = slot.kind;
      sr['connKey'] = slot.connKey;
      sr['title'] = slot.title;
      sArr.push(sr);
    }
    rec['sessions'] = sArr as Object;
    tArr.push(rec);
  }
  const root: Record<string, Object> = {};
  root['v'] = 1;
  root['active'] = activeTab;
  root['tabs'] = tArr as Object;
  return JSON.stringify(root);
}

// ===================== 反序列化(损坏安全) =====================

function toStr(v: Object | undefined, d: string): string {
  const s = v as string;
  return typeof s === 'string' ? s : d;
}

function toNum(v: Object | undefined, d: number): number {
  const n = v as number;
  return typeof n === 'number' ? n : d;
}

/** record → 类实例树;任何结构错误返回 null(dir 只认 'h'/'v',
 *  ratio clamp 0.1..0.9,children 长度>=2)。 */
function nodeFromRecord(v: Object | undefined): LayoutNode | null {
  if (typeof v !== 'object' || v === null || v === undefined) {
    return null;
  }
  const rec = v as Record<string, Object>;
  const t = toStr(rec['t'], '');
  if (t === 'l') {
    const leaf = new PaneLeaf();
    leaf.paneId = toStr(rec['id'], '');
    leaf.sizeRatio = 1;
    return leaf;
  }
  if (t === 's') {
    const dir = toStr(rec['dir'], '');
    if (dir !== 'h' && dir !== 'v') {
      return null;
    }
    const rawCh = rec['ch'];
    if (!Array.isArray(rawCh)) {
      return null;
    }
    const chArr = rawCh as Array<Object>;
    if (chArr.length < 2) {
      return null;
    }
    const sp = new SplitNode();
    sp.id = toStr(rec['id'], '');
    sp.dir = dir as SplitDir;
    sp.ratio = Math.min(0.9, Math.max(0.1, toNum(rec['ratio'], 0.5)));
    for (let i = 0; i < chArr.length; i++) {
      const child = nodeFromRecord(chArr[i]);
      if (child === null) {
        return null;
      }
      sp.children.push(child);
    }
    return sp;
  }
  return null;
}

/** 存档 JSON → TabState[];任何解析/结构错误(含空 tabs 数组)返回 null。 */
export function deserializeTabs(json: string): TabState[] | null {
  let parsed: Object;
  try {
    parsed = JSON.parse(json);
  } catch (e) {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null || parsed === undefined) {
    return null;
  }
  const root = parsed as Record<string, Object>;
  const v = toNum(root['v'], -1);
  if (v !== 1) {
    return null;
  }
  const rawTabs = root['tabs'];
  if (!Array.isArray(rawTabs)) {
    return null;
  }
  const arr = rawTabs as Array<Object>;
  if (arr.length === 0) {
    return null;
  }
  const out: TabState[] = [];
  for (let i = 0; i < arr.length; i++) {
    const rec = arr[i] as Record<string, Object>;
    const t = new TabState();
    t.tabId = toStr(rec['tabId'], '');
    if (t.tabId.length === 0) {
      return null;
    }
    t.title = toStr(rec['title'], 'tty7');
    const rawLay = rec['layout'];
    if (typeof rawLay !== 'object' || rawLay === null || rawLay === undefined) {
      return null;
    }
    const lay = rawLay as Record<string, Object>;
    const rootNode = nodeFromRecord(lay['root']);
    if (rootNode === null) {
      return null;
    }
    t.layout = new LayoutTreeModel();
    t.layout.root = rootNode;
    t.layout.focusedPaneId = toStr(lay['focused'], '');
    t.layout.zoomedPaneId = toStr(lay['zoomed'], '');
    // sessions: M2a 只读结构,不做存在性校验(恒空数组)
    const rawS = rec['sessions'];
    if (Array.isArray(rawS)) {
      const sArr = rawS as Array<Object>;
      for (let s = 0; s < sArr.length; s++) {
        const sr = sArr[s] as Record<string, Object>;
        const slot = new SessionSlot();
        slot.paneId = toStr(sr['paneId'], '');
        slot.kind = toStr(sr['kind'], 'stub');
        slot.connKey = toStr(sr['connKey'], '');
        slot.title = toStr(sr['title'], '');
        t.sessions.push(slot);
      }
    }
    out.push(t);
  }
  return out;
}

// ===================== preferences 落盘(复用 ut.filesDir 通道) =====================

/** 单测/无 ability 环境守卫:AppStorage 无 ut.filesDir → null(不落盘不恢复)。 */
function filesDir(): string {
  const d = AppStorage.get<string>('ut.filesDir');
  return typeof d === 'string' ? d : '';
}

/** 打开 preferences(无 context 环境/打开失败 → null)。 */
function openPref(): preferences.Preferences | null {
  const dir = filesDir();
  if (dir.length === 0) {
    return null;
  }
  try {
    const ctx = getContext() as Context;
    return preferences.getPreferencesSync(ctx, { name: PREF_NAME });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'openPref fail %{public}s', e instanceof Error ? e.message : String(e));
    return null;
  }
}

/** 持久化(put 失败静默,不阻塞 UI,绝不外抛)。 */
export function saveWorkbench(tabs: TabState[], active: number): void {
  const p = openPref();
  if (p === null) {
    return;
  }
  try {
    p.putSync(PREF_KEY, serializeTabs(tabs, active));
    p.flushSync();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'save fail %{public}s', e instanceof Error ? e.message : String(e));
  }
}

/** 恢复;失败(无档/损坏/无 context)返回 null。 */
export function restoreWorkbench(): WorkbenchSnapshot | null {
  const p = openPref();
  if (p === null) {
    return null;
  }
  try {
    const raw = p.getSync(PREF_KEY, '') as string;
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    const snapRaw = JSON.parse(raw) as Record<string, Object>;
    const tabs = deserializeTabs(raw);
    if (tabs === null) {
      return null;
    }
    const snap = new WorkbenchSnapshot();
    snap.tabs = tabs;
    let active = toNum(snapRaw['active'], 0);
    if (!(active >= 0 && active < tabs.length)) {
      active = 0;
    }
    snap.active = active;
    return snap;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'restore fail %{public}s', e instanceof Error ? e.message : String(e));
    return null;
  }
}
