/**
 * CapabilityDiscovery 环境探测（升级 Phase 4 / 任务 5.5，design 2.2.2.6）。
 *
 * 探测目标工具清单（node/git/python/docker/podman/kubectl/ssh/hdc/hvigor/ohpm/cjpm/emulator/browser）：
 *   - 本地经会话执行探测命令（read-only 档免审批）；
 *   - 远程经 SSH 会话执行；
 *   - 探测超时/失败标记"不可用"；
 *   - 会话生命周期内缓存，终端会话切换/重连时失效重探；
 *   - AI 任务依赖环境工具时以探测结果为唯一环境事实，禁止模型猜测（spec 5.5.1.4）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SessionService } from '../../service/SessionService';

const TAG: string = 'oat.discovery';
const DOMAIN: number = 0x0110;
const PROBE_TIMEOUT_MS: number = 5000;

/** 探测目标类型。 */
export type ProbeTarget = 'local' | 'remote'

/** 单工具探测结果。 */
export class ToolProbe {
  name: string = ''
  available: boolean = false
  version: string = ''
  probedAt: number = 0
}

/** 探测报告。 */
export class CapabilityReport {
  probes: ToolProbe[] = []
  probedAt: number = 0
  target: ProbeTarget = 'local'
}

/** 探测命令定义。 */
class ProbeDef {
  name: string = ''
  cmd: string = ''
  versionArg: string = ''
}

export class CapabilityDiscovery {
  private static inst: CapabilityDiscovery | null = null
  private cache: Map<string, CapabilityReport> = new Map()
  private probes: ProbeDef[] = []

  private constructor() {
    this.registerProbes()
  }

  static instance(): CapabilityDiscovery {
    if (CapabilityDiscovery.inst === null) {
      CapabilityDiscovery.inst = new CapabilityDiscovery()
    }
    return CapabilityDiscovery.inst
  }

  private registerProbes(): void {
    const defs: string[][] = [
      ['node', 'node --version', ''],
      ['git', 'git --version', ''],
      ['python', 'python3 --version', ''],
      ['docker', 'docker --version', ''],
      ['podman', 'podman --version', ''],
      ['kubectl', 'kubectl version --client', ''],
      ['ssh', 'ssh -V', ''],
      ['hdc', 'hdc version', ''],
      ['hvigor', 'hvigorw --version', ''],
      ['ohpm', 'ohpm --version', ''],
      ['cjpm', 'cjpm --version', ''],
      ['emulator', 'emulator -version', ''],
      ['browser', 'which browser', '']
    ]
    for (const d of defs) {
      const p = new ProbeDef()
      p.name = d[0]
      p.cmd = d[1]
      p.versionArg = d[2]
      this.probes.push(p)
    }
  }

  /** 执行探测（缓存优先；缓存失效后重新探测）。 */
  async discover(target: ProbeTarget): Promise<CapabilityReport> {
    const cacheKey = target
    const cached = this.cache.get(cacheKey)
    if (cached !== undefined) {
      return cached
    }
    const report = new CapabilityReport()
    report.target = target
    report.probedAt = Date.now()
    for (const def of this.probes) {
      const probe = new ToolProbe()
      probe.name = def.name
      probe.probedAt = Date.now()
      if (target === 'local') {
        probe.available = await this.probeLocal(def.cmd)
        if (probe.available) {
          probe.version = await this.probeLocalVersion(def.cmd)
        }
      } else {
        probe.available = await this.probeRemote(def.cmd)
        if (probe.available) {
          probe.version = await this.probeRemoteVersion(def.cmd)
        }
      }
      report.probes.push(probe)
    }
    this.cache.set(cacheKey, report)
    hilog.info(DOMAIN, TAG, 'discover %{public}s: %{public}d/%{public}d available',
      target, report.probes.filter((p: ToolProbe): boolean => p.available).length, report.probes.length)
    return report
  }

  /** 会话切换/重连时失效缓存。 */
  invalidate(sessionId: string): void {
    this.cache.delete('local')
    this.cache.delete('remote')
    hilog.info(DOMAIN, TAG, 'invalidate cache (session=%{public}s)', sessionId)
  }

  /** 查询某工具是否可用（缓存优先）。 */
  isAvailable(name: string, target: ProbeTarget): boolean {
    const cached = this.cache.get(target)
    if (cached === undefined) {
      return false
    }
    for (const p of cached.probes) {
      if (p.name === name) {
        return p.available
      }
    }
    return false
  }

  /** 获取探测报告摘要（供 AI system prompt 注入）。 */
  reportSummary(target: ProbeTarget): string {
    const cached = this.cache.get(target)
    if (cached === undefined) {
      return '环境未探测'
    }
    const parts: string[] = []
    for (const p of cached.probes) {
      parts.push(p.name + '=' + (p.available ? 'yes' : 'no') + (p.version !== '' ? '(' + p.version + ')' : ''))
    }
    return parts.join(', ')
  }

  // ===== 探测执行 =====
  private async probeLocal(cmd: string): Promise<boolean> {
    if (!SessionService.hasSession()) {
      return false
    }
    try {
      const before = SessionService.screenText(2000)
      SessionService.write(cmd + '\n')
      const result = await this.waitScreen(before, PROBE_TIMEOUT_MS)
      return result !== before && !/not found|not recognized|No such file/.test(result)
    } catch (e) {
      return false
    }
  }

  private async probeLocalVersion(cmd: string): Promise<string> {
    if (!SessionService.hasSession()) {
      return ''
    }
    try {
      const before = SessionService.screenText(2000)
      SessionService.write(cmd + '\n')
      const result = await this.waitScreen(before, PROBE_TIMEOUT_MS)
      const lines = result.split('\n')
      for (const line of lines) {
        const trimmed = line.trim()
        if (trimmed !== '' && !/[$#❯]\s*$/.test(trimmed) && trimmed !== cmd) {
          return trimmed.substring(0, 60)
        }
      }
      return ''
    } catch (e) {
      return ''
    }
  }

  private async probeRemote(cmd: string): Promise<boolean> {
    const ssh = SessionService.sshHandle()
    const sid = SessionService.getSessionId()
    if (ssh === null || sid < 0) {
      return false
    }
    try {
      const json = await ssh.exec(sid, cmd, PROBE_TIMEOUT_MS)
      const obj = JSON.parse(json) as Record<string, Object>
      const code = typeof obj['code'] === 'number' ? obj['code'] as number : -1
      return code === 0
    } catch (e) {
      return false
    }
  }

  private async probeRemoteVersion(cmd: string): Promise<string> {
    const ssh = SessionService.sshHandle()
    const sid = SessionService.getSessionId()
    if (ssh === null || sid < 0) {
      return ''
    }
    try {
      const json = await ssh.exec(sid, cmd, PROBE_TIMEOUT_MS)
      const obj = JSON.parse(json) as Record<string, Object>
      const stdout = typeof obj['stdout'] === 'string' ? obj['stdout'] as string : ''
      return stdout.trim().split('\n')[0].substring(0, 60)
    } catch (e) {
      return ''
    }
  }

  private waitScreen(before: string, maxMs: number): Promise<string> {
    return new Promise<string>((resolve) => {
      const t0 = Date.now()
      let last = ''
      let stable = 0
      const poll = (): void => {
        if (Date.now() - t0 > maxMs) {
          resolve(last)
          return
        }
        setTimeout(() => {
          const cur = SessionService.screenText(2000)
          if (cur !== before && cur === last) {
            stable++
            if (stable >= 2) {
              resolve(cur)
              return
            }
          } else {
            stable = 0
          }
          last = cur
          const lines = cur.split('\n')
          const lastLine = lines.length > 0 ? lines[lines.length - 2] : ''
          if (cur !== before && lastLine !== '' && /[$#❯]\s*$/.test(lastLine)) {
            resolve(cur)
            return
          }
          poll()
        }, 300)
      }
      poll()
    })
  }
}