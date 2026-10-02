// 智能体设置(filesDir/agent_settings.json)——三段独立配置（升级 Phase 1 / 任务 2.4）。
// engines（hmh.baseUrl / acp.agents / local.model 互不干扰）+
// security.approvalPolicy（strict 默认 / standard / open，禁止默认 open）+
// featureFlags（acp_v2=false / a2ui=false）。
// 存量 mode 字段读取映射迁移：confirm_all→strict / confirm_dangerous→standard / bypass→open；
// 首次读取从存量 llm_config.json 单向迁移（harnessUrl→engines.hmh.baseUrl、model→engines.local.model），
// 保留原文件作迁移标记；幂等（已有 engines 字段不重复迁移）。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApprovalPolicyKind } from '../agent/AgentProvider';

const TAG: string = 'oat.agentcfg';
const DOMAIN: number = 0x0110;

/** 存量审批档（仅作迁移输入，新代码勿用）。 */
export type ApprovalMode = 'confirm_all' | 'confirm_dangerous' | 'bypass';

export class HmhEngineConfig {
  /** hmharness 服务地址（原 LlmConfigStore.harnessUrl 迁移目标）。 */
  baseUrl: string = ''
}

export class AcpAgentConfig {
  name: string = ''
  url: string = ''
}

export class LocalEngineConfig {
  /** 本地引擎模型名（覆盖 llm_config.json 的 model；空=用 llm_config 默认）。 */
  model: string = ''
}

export class EnginesConfig {
  hmh: HmhEngineConfig = new HmhEngineConfig()
  acp: AcpAgentConfig[] = []
  local: LocalEngineConfig = new LocalEngineConfig()
}

export class SecurityConfig {
  approvalPolicy: ApprovalPolicyKind = 'strict'
}

export class FeatureFlagsConfig {
  acp_v2: boolean = false
  a2ui: boolean = false
}

export class AgentSettings {
  engines: EnginesConfig = new EnginesConfig()
  security: SecurityConfig = new SecurityConfig()
  featureFlags: FeatureFlagsConfig = new FeatureFlagsConfig()
  /** 存量字段（迁移输入，deprecated）。 */
  mode: ApprovalMode | '' = ''
  /** 迁移标记（幂等）。 */
  migrated: boolean = false
}

export class AgentSettingsStore {
  private static path(filesDir: string): string {
    return filesDir + '/agent_settings.json'
  }

  /** 存量 mode → 新审批策略映射。 */
  static modeToPolicy(mode: ApprovalMode | ''): ApprovalPolicyKind {
    if (mode === 'confirm_all') {
      return 'strict'
    }
    if (mode === 'confirm_dangerous') {
      return 'standard'
    }
    if (mode === 'bypass') {
      return 'open'
    }
    return 'strict'
  }

  /** 从存量 llm_config.json 单向迁移 harnessUrl/model（直接读文件，不依赖 LlmConfigStore）。 */
  private static migrateFromLlm(filesDir: string, s: AgentSettings): void {
    try {
      const p = filesDir + '/llm_config.json'
      if (!fs.accessSync(p)) {
        return
      }
      const obj = JSON.parse(fs.readTextSync(p)) as Record<string, Object>
      const hu = obj['harnessUrl']
      if (typeof hu === 'string' && hu !== '' && s.engines.hmh.baseUrl === '') {
        s.engines.hmh.baseUrl = hu
      }
      const m = obj['model']
      if (typeof m === 'string' && m !== '' && s.engines.local.model === '') {
        s.engines.local.model = m
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'migrateFromLlm fail %{public}s', e instanceof Error ? e.message : String(e))
    }
  }

  static read(filesDir: string): AgentSettings {
    const p = AgentSettingsStore.path(filesDir)
    try {
      if (!fs.accessSync(p)) {
        const fresh = new AgentSettings()
        AgentSettingsStore.migrateFromLlm(filesDir, fresh)
        return fresh
      }
      const raw = fs.readTextSync(p)
      const obj = JSON.parse(raw) as AgentSettings
      const s = new AgentSettings()
      if (obj.engines === undefined) {
        // 旧格式：mode 映射迁移 + llm 单向迁移 + 回写（幂等标记）
        s.security.approvalPolicy = AgentSettingsStore.modeToPolicy(obj.mode)
        s.mode = obj.mode
        AgentSettingsStore.migrateFromLlm(filesDir, s)
        s.migrated = true
        const werr = AgentSettingsStore.write(filesDir, s)
        if (werr !== '') {
          hilog.warn(DOMAIN, TAG, 'migrate write fail %{public}s', werr)
        }
        return s
      }
      // 新格式解析
      if (obj.engines.hmh !== undefined) {
        s.engines.hmh.baseUrl = obj.engines.hmh.baseUrl
      }
      if (obj.engines.local !== undefined) {
        s.engines.local.model = obj.engines.local.model
      }
      if (obj.engines.acp !== undefined && obj.engines.acp.length > 0) {
        for (const a of obj.engines.acp) {
          const c = new AcpAgentConfig()
          c.name = a.name
          c.url = a.url
          s.engines.acp.push(c)
        }
      }
      if (obj.security !== undefined) {
        const pol = obj.security.approvalPolicy
        if (pol === 'strict' || pol === 'standard' || pol === 'open') {
          s.security.approvalPolicy = pol
        }
      }
      if (obj.featureFlags !== undefined) {
        s.featureFlags.acp_v2 = obj.featureFlags.acp_v2 === true
        s.featureFlags.a2ui = obj.featureFlags.a2ui === true
      }
      if (obj.mode === 'confirm_all' || obj.mode === 'confirm_dangerous' || obj.mode === 'bypass') {
        s.mode = obj.mode
      }
      s.migrated = obj.migrated === true
      return s
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read fail %{public}s', e instanceof Error ? e.message : String(e))
      return new AgentSettings()
    }
  }

  static write(filesDir: string, s: AgentSettings): string {
    const p = AgentSettingsStore.path(filesDir)
    let f: fs.File | null = null
    try {
      s.migrated = true
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, JSON.stringify(s))
      fs.closeSync(f)
      f = null
      const back = AgentSettingsStore.read(filesDir)
      if (back.security.approvalPolicy !== s.security.approvalPolicy ||
        back.engines.hmh.baseUrl !== s.engines.hmh.baseUrl ||
        back.engines.local.model !== s.engines.local.model ||
        back.featureFlags.acp_v2 !== s.featureFlags.acp_v2 ||
        back.featureFlags.a2ui !== s.featureFlags.a2ui) {
        return '写入校验不一致'
      }
      hilog.info(DOMAIN, TAG, 'write OK policy=%{public}s', s.security.approvalPolicy)
      return ''
    } catch (e) {
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      return '保存失败: ' + (e instanceof Error ? e.message : String(e)).substring(0, 160)
    }
  }
}
