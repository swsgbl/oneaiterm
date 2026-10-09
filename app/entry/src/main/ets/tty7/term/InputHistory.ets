/**
 * tty7 终端输入历史(任务 tty7-M4a,纯数据+持久化)。
 *
 * 明文命令行环形历史:TermHost 级全局(所有本地会话共享,M3b 多实例后再
 * 分会话)。历史本就是终端可见的明文命令行,无秘密性红线;单测/无 ability
 * 环境静默降级不落盘(照 WorkbenchStore 模式:AppStorage 'ut.filesDir'
 * 守卫,复用全仓唯一 context 通道,不新建第二套)。
 *
 * 存储:items 最旧在前/最新在后(push 追加);环形裁剪 100(超长丢最旧)。
 * 持久化:preferences 'ut.termhist.v1'(JSON 数组,独立 pref 文件不与
 * workbench 混);push 时 persist(轻量,百条短串 putSync+flushSync 微秒级);
 * TermHost.start 时 restore,TermHost.stop 时 persist 封存。
 */
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'tty7.hist';
const DOMAIN: number = 0x0117;
const PREF_NAME: string = 'ut_termhist';
const PREF_KEY: string = 'ut.termhist.v1';
const HIST_MAX: number = 100;
const MATCH_MAX: number = 8;

export class InputHistory {
  private static items: string[] = [];

  /** 入史:去首尾空白;空串/与最近一条相同不入;环形裁剪;轻量落盘。 */
  static push(line: string): void {
    const s = line.trim();
    if (s.length === 0) {
      return;
    }
    const n = InputHistory.items.length;
    if (n > 0 && InputHistory.items[n - 1] === s) {
      return;
    }
    InputHistory.items.push(s);
    if (InputHistory.items.length > HIST_MAX) {
      InputHistory.items = InputHistory.items.slice(InputHistory.items.length - HIST_MAX);
    }
    InputHistory.persist();
  }

  /** 最新在前,拷贝。 */
  static recent(): string[] {
    const out: string[] = [];
    for (let i = InputHistory.items.length - 1; i >= 0; i--) {
      out.push(InputHistory.items[i]);
    }
    return out;
  }

  /** 前缀匹配(大小写敏感),最新在前,最多 8 条。 */
  static matchPrefix(prefix: string): string[] {
    if (prefix.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (let i = InputHistory.items.length - 1; i >= 0 && out.length < MATCH_MAX; i--) {
      if (InputHistory.items[i].startsWith(prefix)) {
        out.push(InputHistory.items[i]);
      }
    }
    return out;
  }

  static size(): number {
    return InputHistory.items.length;
  }

  /** 清空内存(单测复位用;不触磁盘)。 */
  static clear(): void {
    InputHistory.items = [];
  }

  /** 落盘(无 context/失败静默,绝不外抛)。 */
  static persist(): void {
    const p = InputHistory.openPref();
    if (p === null) {
      return;
    }
    try {
      p.putSync(PREF_KEY, JSON.stringify(InputHistory.items));
      p.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persist fail %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /** 恢复(无 context/无档/损坏 → 内存保持原状,绝不外抛)。 */
  static restore(): void {
    const p = InputHistory.openPref();
    if (p === null) {
      return;
    }
    try {
      const raw = p.getSync(PREF_KEY, '') as string;
      if (typeof raw !== 'string' || raw.length === 0) {
        return;
      }
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return;
      }
      const arr = parsed as Array<Object>;
      const out: string[] = [];
      for (let i = 0; i < arr.length && out.length < HIST_MAX; i++) {
        const s = arr[i] as string;
        if (typeof s === 'string' && s.length > 0) {
          out.push(s);
        }
      }
      InputHistory.items = out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'restore fail %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /** 打开 preferences(无 context 环境/打开失败 → null;全仓唯一通道复用)。 */
  private static openPref(): preferences.Preferences | null {
    const d = AppStorage.get<string>('ut.filesDir');
    if (typeof d !== 'string' || d.length === 0) {
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
}
