/**
 * tty7 工作台存档层(任务 tty7-M2a 建立:多 Tab 布局树 + 恢复;M2b 升 v2:多工作区)。
 *
 * 职责:WorkspaceState[] ↔ JSON 纯序列化/反序列化 + preferences 落盘。
 * 红线:
 * - 不 import 任何 UI 组件/WorkbenchVm(纯数据层,Vm 反向依赖本层)。
 * - 秘密绝不入档:只序列化结构(wsId/name/glyph/tabId/title/layout/sessions 键名),
 *   pane 内容、终端缓冲、凭据一概不落——SessionSlot.connKey 本身就只是键名。
 * - 损坏安全降级:任何解析/结构错误 deserialize 返回 null,调用方回默认基线。
 * - 上下文通道:复用 EntryAbility 发布的 AppStorage 'ut.filesDir'(全仓唯一
 *   context 通道,不新建第二套);无 context(单测环境)→ save/restore 静默不落盘。
 *
 * 存档格式(v2,M2b):
 *   { v:2, activeWs:0, workspaces:[ { wsId,name,glyph,activeTab,
 *     tabs:[ { tabId,title, layout:{ root:<node>, focused:'', zoomed:'' }, sessions:[] } ] } ] }
 * v1 降级读(M2a 档):{ v:1, active, tabs:[...] } → 单工作区包一层。
 * node 递归: {t:'l',id} | {t:'s',id,dir,ratio,ch:[...]}(手写递归,不 JSON 化
 * 类实例——反序列化必须重建 PaneLeaf/SplitNode 类实例,@Observed/V1 组件依赖)。
 */
import { LayoutTreeModel, LayoutNode, PaneLeaf, SplitNode, SplitDir } from '../layout/LayoutTree';
import { TabState, SessionSlot } from '../model/TabState';
import { WorkspaceState } from '../model/WorkspaceState';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'tty7.store';
const DOMAIN: number = 0x0117;
const PREF_NAME: string = 'ut_workbench';
const PREF_KEY: string = 'ut.workbench.v1';

/** 恢复结果载体(ArkTS 不鼓励匿名对象字面量,显式类)。 */
export class WorkbenchSnapshot {
  workspaces: WorkspaceState[] = [];
  activeWs: number = 0;
}

// ===================== 序列化(v2) =====================

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

/** TabState → record(tabToRecord/tabFromRecord 为 v1/v2 共用的 tab 级序列化对,M2b 抽出)。 */
function tabToRecord(t: TabState): Record<string, Object> {
  const rec: Record<string, Object> = {};
  rec['tabId'] = t.tabId;
  rec['title'] = t.title;
  const lay: Record<string, Object> = {};
  lay['root'] = nodeToRecord(t.layout.root);
  lay['focused'] = t.layout.focusedPaneId;
  lay['zoomed'] = t.layout.zoomedPaneId;
  rec['layout'] = lay as Object;
  // sessions: connKey 只存键名,秘密绝不入档
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
  return rec;
}

/** record → TabState;结构损坏返回 null。 */
function tabFromRecord(v: Object): TabState | null {
  if (typeof v !== 'object' || v === null || v === undefined) {
    hilog.warn(DOMAIN, TAG, 'tabFromRecord null: not-object');
    return null;
  }
  const rec = v as Record<string, Object>;
  const t = new TabState();
  t.tabId = toStr(rec['tabId'], '');
  if (t.tabId.length === 0) {
    hilog.warn(DOMAIN, TAG, 'tabFromRecord null: empty-tabId typeofTab=%{public}s', typeof rec['tabId']);
    return null;
  }
  t.title = toStr(rec['title'], 'tty7');
  const rawLay = rec['layout'];
  if (typeof rawLay !== 'object' || rawLay === null || rawLay === undefined) {
    hilog.warn(DOMAIN, TAG, 'tabFromRecord null: layout not-object typeof=%{public}s', typeof rawLay);
    return null;
  }
  const lay = rawLay as Record<string, Object>;
  const rootNode = nodeFromRecord(lay['root']);
  if (rootNode === null) {
    hilog.warn(DOMAIN, TAG, 'tabFromRecord null: bad-root');
    return null;
  }
  t.layout = new LayoutTreeModel();
  t.layout.root = rootNode;
  t.layout.focusedPaneId = toStr(lay['focused'], '');
  t.layout.zoomedPaneId = toStr(lay['zoomed'], '');
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
  return t;
}

/** workspaces → 存档 JSON 字符串(v2 轻结构,无秘密、无 pane 内容)。 */
export function serializeWorkspaces(workspaces: WorkspaceState[], activeWs: number): string {
  const wArr: Array<Record<string, Object>> = [];
  for (let i = 0; i < workspaces.length; i++) {
    const ws = workspaces[i];
    const rec: Record<string, Object> = {};
    rec['wsId'] = ws.wsId;
    rec['name'] = ws.name;
    rec['glyph'] = ws.glyph;
    rec['activeTab'] = ws.activeTab;
    const tArr: Array<Record<string, Object>> = [];
    for (let j = 0; j < ws.tabs.length; j++) {
      tArr.push(tabToRecord(ws.tabs[j]));
    }
    rec['tabs'] = tArr as Object;
    wArr.push(rec);
  }
  const root: Record<string, Object> = {};
  root['v'] = 2;
  root['activeWs'] = activeWs;
  root['workspaces'] = wArr as Object;
  return JSON.stringify(root);
}

// ===================== 反序列化(损坏安全;v2 直读 + v1 降级) =====================

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
    hilog.warn(DOMAIN, TAG, 'nodeFromRecord null: not-object typeof=%{public}s', typeof v);
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
      hilog.warn(DOMAIN, TAG, 'nodeFromRecord null: bad-dir [%{public}s]', dir);
      return null;
    }
    const rawCh = rec['ch'];
    if (!Array.isArray(rawCh)) {
      hilog.warn(DOMAIN, TAG, 'nodeFromRecord null: ch not-array typeof=%{public}s', typeof rawCh);
      return null;
    }
    const chArr = rawCh as Array<Object>;
    if (chArr.length < 2) {
      hilog.warn(DOMAIN, TAG, 'nodeFromRecord null: ch<2 len=%{public}d', chArr.length);
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

/** v1 tabs 数组 → 单工作区包一层(降级读;失败 null)。 */
function workspacesFromV1Tabs(arr: Array<Object>): WorkspaceState[] | null {
  const tabs: TabState[] = [];
  for (let i = 0; i < arr.length; i++) {
    const t = tabFromRecord(arr[i]);
    if (t === null) {
      return null;
    }
    tabs.push(t);
  }
  if (tabs.length === 0) {
    return null;
  }
  const ws = new WorkspaceState();
  ws.wsId = 'w1';
  ws.name = 'workspace';
  ws.glyph = '◈';
  ws.tabs = tabs;
  ws.activeTab = 0;
  return [ws];
}

/** 存档 JSON → WorkspaceState[];任何解析/结构错误(含空 workspaces)返回 null。
 *  v2 直读;v1(单 tabs 数组)降级为单工作区。 */
export function deserializeWorkspaces(json: string): WorkspaceState[] | null {
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
  if (v === 1) {
    const rawTabs = root['tabs'];
    if (!Array.isArray(rawTabs)) {
      hilog.warn(DOMAIN, TAG, 'deserialize v1 null: tabs not-array typeof=%{public}s', typeof rawTabs);
      return null;
    }
    return workspacesFromV1Tabs(rawTabs as Array<Object>);
  }
  if (v !== 2) {
    hilog.warn(DOMAIN, TAG, 'deserialize null: unknown v');
    return null;
  }
  const rawWs = root['workspaces'];
  if (!Array.isArray(rawWs)) {
    return null;
  }
  const wArr = rawWs as Array<Object>;
  if (wArr.length === 0) {
    return null;
  }
  const out: WorkspaceState[] = [];
  for (let i = 0; i < wArr.length; i++) {
    const rec = wArr[i] as Record<string, Object>;
    const ws = new WorkspaceState();
    ws.wsId = toStr(rec['wsId'], '');
    if (ws.wsId.length === 0) {
      return null;
    }
    ws.name = toStr(rec['name'], 'workspace');
    ws.glyph = toStr(rec['glyph'], '◈');
    const rawTabs = rec['tabs'];
    if (!Array.isArray(rawTabs)) {
      return null;
    }
    const tArr = rawTabs as Array<Object>;
    if (tArr.length === 0) {
      return null;
    }
    for (let j = 0; j < tArr.length; j++) {
      const t = tabFromRecord(tArr[j]);
      if (t === null) {
        return null;
      }
      ws.tabs.push(t);
    }
    const at = toNum(rec['activeTab'], 0);
    ws.activeTab = at >= 0 && at < ws.tabs.length ? at : 0;
    out.push(ws);
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
export function saveWorkbench(workspaces: WorkspaceState[], activeWs: number): void {
  const p = openPref();
  if (p === null) {
    return;
  }
  try {
    p.putSync(PREF_KEY, serializeWorkspaces(workspaces, activeWs));
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
    const workspaces = deserializeWorkspaces(raw);
    if (workspaces === null) {
      return null;
    }
    const snap = new WorkbenchSnapshot();
    snap.workspaces = workspaces;
    let activeWs = toNum(snapRaw['activeWs'], 0);
    if (!(activeWs >= 0 && activeWs < workspaces.length)) {
      activeWs = 0;
    }
    snap.activeWs = activeWs;
    return snap;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'restore fail %{public}s', e instanceof Error ? e.message : String(e));
    return null;
  }
}
