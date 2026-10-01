// M6 relay3: 智能体审批门设置(filesDir/agent_settings.json)
// 三档: confirm_all=全部确认(默认) / confirm_dangerous=仅危险确认 / bypass=全自动
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'oat.agentcfg';
const DOMAIN: number = 0x0110;

export type ApprovalMode = 'confirm_all' | 'confirm_dangerous' | 'bypass';

export class AgentSettings {
  mode: ApprovalMode = 'confirm_all'
}

export class AgentSettingsStore {
  private static path(filesDir: string): string {
    return filesDir + '/agent_settings.json'
  }

  static read(filesDir: string): AgentSettings {
    const p = AgentSettingsStore.path(filesDir)
    try {
      if (!fs.accessSync(p)) {
        return new AgentSettings()
      }
      const raw = fs.readTextSync(p)
      const obj = JSON.parse(raw) as AgentSettings
      const s = new AgentSettings()
      if (obj.mode === 'confirm_all' || obj.mode === 'confirm_dangerous' || obj.mode === 'bypass') {
        s.mode = obj.mode
      }
      return s
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read fail %{public}s', JSON.stringify(e))
      return new AgentSettings()
    }
  }

  static write(filesDir: string, s: AgentSettings): string {
    const p = AgentSettingsStore.path(filesDir)
    let f: fs.File | null = null
    try {
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, JSON.stringify(s))
      fs.closeSync(f)
      f = null
      const back = AgentSettingsStore.read(filesDir)
      if (back.mode !== s.mode) {
        return '写入校验不一致'
      }
      hilog.info(DOMAIN, TAG, 'write OK mode=%{public}s', s.mode)
      return ''
    } catch (e) {
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      return '保存失败: ' + JSON.stringify(e).substring(0, 160)
    }
  }
}
