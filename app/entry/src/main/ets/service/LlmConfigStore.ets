// LLM 配置持久化(filesDir/llm_config.json)
// M6 relay1 P0-1: write() 不再静默吞错——返回 ''=成功,否则为可展示给用户的错误消息,
// 并以 hilog 打点(oat.$1)供 E2E 断言。
// 升级 Phase 1 / 任务 2.12: harnessUrl 字段移除（配置迁至 agent_settings.json
// engines.hmh.baseUrl，由 AgentSettingsStore 管理）。
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { LlmConfig } from './Llm';

const CFG_TAG: string = 'oat.llmcfg';
const CFG_DOMAIN: number = 0x0110;

export class LlmConfigStore {
  private static path(filesDir: string): string {
    return filesDir + '/llm_config.json'
  }

  static read(filesDir: string): LlmConfig {
    const p = LlmConfigStore.path(filesDir)
    try {
      if (!fs.accessSync(p)) {
        return { provider: 'anthropic', baseUrl: 'https://api.anthropic.com', apiKey: '', model: 'claude-sonnet-4-5' }
      }
      const raw = fs.readTextSync(p)
      const cfg = JSON.parse(raw) as LlmConfig
      return cfg
    } catch (e) {
      hilog.error(CFG_DOMAIN, CFG_TAG, 'read fail %{public}s', JSON.stringify(e))
      return { provider: 'anthropic', baseUrl: 'https://api.anthropic.com', apiKey: '', model: 'claude-sonnet-4-5' }
    }
  }

  // 返回 '':成功;否则为错误消息(调用方 toast 展示)
  static write(filesDir: string, cfg: LlmConfig): string {
    const p = LlmConfigStore.path(filesDir)
    let f: fs.File | null = null
    try {
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, JSON.stringify(cfg))
      fs.closeSync(f)
      f = null
      // 写后立即回读校验,确保配置真实落盘
      const back = LlmConfigStore.read(filesDir)
      if (back.apiKey !== cfg.apiKey || back.model !== cfg.model || back.provider !== cfg.provider) {
        hilog.error(CFG_DOMAIN, CFG_TAG, 'write verify mismatch p=%{public}s', p)
        return '写入校验不一致,配置可能未保存'
      }
      hilog.info(CFG_DOMAIN, CFG_TAG, 'write OK p=%{public}s provider=%{public}s model=%{public}s', p, cfg.provider, cfg.model)
      return ''
    } catch (e) {
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      const es = JSON.stringify(e)
      const msg = es !== '' ? es.substring(0, 200) : 'unknown'
      hilog.error(CFG_DOMAIN, CFG_TAG, 'write FAIL p=%{public}s err=%{public}s', p, msg)
      return '保存失败: ' + msg
    }
  }
}
