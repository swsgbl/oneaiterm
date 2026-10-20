/**
 * 侧 ConnStore 惰性初始化(2026-10-11 Device Smoke 实证修复)。
 *
 * 背景:共享 store 仅由旧界面 ConnList.aboutToAppear 初始化(set+load);
 * 壳经 --ps shell 直启时旧界面从未挂载 → getSharedStore()
 * 恒 null → SshPicker/SSH 命令降级"连接库未就绪"。
 *
 * 修复:null 时最小初始化(new ConnectionStore(filesDir) + CredentialManager
 * + load);**已有实例时原样返回绝不重 load**(重新 load 会用磁盘 enc:v1
 * 密文覆盖内存解密态——M6a 实勘红线)。
 * filesDir 经 AppStorage 'ut.filesDir' 通道(与 WorkbenchStore 同源;
 * 无 context 环境返回 null 由调用方降级)。
 */
import { ConnectionStore, getSharedStore, setSharedStore } from '../../store/ConnStore';
import { CredentialManager } from '../../store/CredentialManager';

export function ensureSharedStore(): ConnectionStore | null {
  const existing = getSharedStore()
  if (existing !== null) {
    return existing
  }
  const dir = AppStorage.get<string>('ut.filesDir')
  if (typeof dir !== 'string' || dir.length === 0) {
    return null
  }
  try {
    const store = new ConnectionStore(dir)
    store.setCredManager(new CredentialManager(dir))
    store.load()
    setSharedStore(store)
    return store
  } catch (e) {
    return null
  }
}
