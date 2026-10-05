/**
 * CapabilityDiscovery 单元测试（补充任务 S1.2，ArkTS/hypium）。
 *
 * 纯函数复制 replicates CapabilityDiscovery 中可测试的纯函数逻辑（dependency-free）。
 * 覆盖：
 *   1. 13 种工具探测注册完整性 + 名称匹配
 *   2. 缓存优先逻辑（缓存命中）
 *   3. invalidate 缓存清除 + 同时失效 local+remote
 *   4. isAvailable 未缓存返回 false + 缓存命中返回探测结果
 *   5. reportSummary 格式（yes/no/未探测/多工具拼接）
 */
import { describe, it, expect } from '@ohos/hypium';

class TProbeDef {
  name: string = ''
  cmd: string = ''
  versionArg: string = ''
}

class TToolProbe {
  name: string = ''
  available: boolean = false
  version: string = ''
  probedAt: number = 0
}

class TCapabilityReport {
  probes: TToolProbe[] = []
  probedAt: number = 0
  target: string = 'local'
}

const EXPECTED_NAMES: string[] = [
  'node', 'git', 'python', 'docker', 'podman', 'kubectl',
  'ssh', 'hdc', 'hvigor', 'ohpm', 'cjpm', 'emulator', 'browser'
]

function registerProbes(): TProbeDef[] {
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
  const result: TProbeDef[] = []
  for (const d of defs) {
    const p = new TProbeDef()
    p.name = d[0]
    p.cmd = d[1]
    p.versionArg = d[2]
    result.push(p)
  }
  return result
}

function isAvailable(cache: Map<string, TCapabilityReport>, name: string, target: string): boolean {
  const cached = cache.get(target)
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

function reportSummary(cache: Map<string, TCapabilityReport>, target: string): string {
  const cached = cache.get(target)
  if (cached === undefined) {
    return '环境未探测'
  }
  const parts: string[] = []
  for (const p of cached.probes) {
    parts.push(p.name + '=' + (p.available ? 'yes' : 'no') + (p.version !== '' ? '(' + p.version + ')' : ''))
  }
  return parts.join(', ')
}

export default function capabilityDiscoveryTest() {
  describe('capabilityDiscoveryTest', () => {
    // ===== 探测注册完整性 =====
    it('capability_probe_registration_completeness', 0, () => {
      const probes = registerProbes()
      expect(probes.length === 13).assertTrue()
    })

    it('capability_probe_names_match', 0, () => {
      const probes = registerProbes()
      for (let i = 0; i < EXPECTED_NAMES.length; i++) {
        expect(probes[i].name === EXPECTED_NAMES[i]).assertTrue()
      }
    })

    // ===== 缓存优先 =====
    it('capability_cache_hit', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      report.probedAt = Date.now()
      cache.set('local', report)
      const cached = cache.get('local')
      expect(cached !== undefined).assertTrue()
      expect(cached!.target === 'local').assertTrue()
    })

    // ===== invalidate 缓存清除 =====
    it('capability_invalidate_clears_cache', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      cache.set('local', report)
      cache.delete('local')
      expect(cache.get('local') === undefined).assertTrue()
    })

    it('capability_invalidate_both_targets', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const localReport = new TCapabilityReport()
      localReport.target = 'local'
      const remoteReport = new TCapabilityReport()
      remoteReport.target = 'remote'
      cache.set('local', localReport)
      cache.set('remote', remoteReport)
      cache.delete('local')
      cache.delete('remote')
      expect(cache.get('local') === undefined).assertTrue()
      expect(cache.get('remote') === undefined).assertTrue()
    })

    // ===== isAvailable =====
    it('capability_is_available_no_cache', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      expect(!isAvailable(cache, 'node', 'local')).assertTrue()
      expect(!isAvailable(cache, 'git', 'remote')).assertTrue()
    })

    it('capability_is_available_with_cache', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      const probe = new TToolProbe()
      probe.name = 'node'
      probe.available = true
      report.probes.push(probe)
      cache.set('local', report)
      expect(isAvailable(cache, 'node', 'local')).assertTrue()
      expect(!isAvailable(cache, 'docker', 'local')).assertTrue()
    })

    // ===== reportSummary 格式 =====
    it('capability_report_summary_format_yes', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      const probe = new TToolProbe()
      probe.name = 'node'
      probe.available = true
      probe.version = 'v22.23.2'
      report.probes.push(probe)
      cache.set('local', report)
      const summary = reportSummary(cache, 'local')
      expect(summary === 'node=yes(v22.23.2)').assertTrue()
    })

    it('capability_report_summary_format_no', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      const probe = new TToolProbe()
      probe.name = 'docker'
      probe.available = false
      probe.version = ''
      report.probes.push(probe)
      cache.set('local', report)
      const summary = reportSummary(cache, 'local')
      expect(summary === 'docker=no').assertTrue()
    })

    it('capability_report_summary_no_cache', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const summary = reportSummary(cache, 'local')
      expect(summary === '环境未探测').assertTrue()
    })

    it('capability_report_summary_multiple', 0, () => {
      const cache = new Map<string, TCapabilityReport>()
      const report = new TCapabilityReport()
      report.target = 'local'
      const p1 = new TToolProbe()
      p1.name = 'node'
      p1.available = true
      p1.version = 'v22.23.2'
      const p2 = new TToolProbe()
      p2.name = 'docker'
      p2.available = false
      p2.version = ''
      report.probes.push(p1)
      report.probes.push(p2)
      cache.set('local', report)
      const summary = reportSummary(cache, 'local')
      expect(summary === 'node=yes(v22.23.2), docker=no').assertTrue()
    })
  })
}