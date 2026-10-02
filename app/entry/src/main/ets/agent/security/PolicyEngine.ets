/**
 * PolicyEngine 五档判定（升级 Phase 1 / 任务 2.6，design 2.2.2.3）。
 *
 * 纯函数无副作用：
 *   - 注入类特征（path traversal / command injection）在档位判定前直接 deny；
 *   - 工具注册表声明每工具最低档位（term_read/session_info/sftp_list→read_only；
 *     term_write→terminal，target=remote 提升为 remote）；
 *   - destructive 正则启发式（存量 AgentKernel.riskOf 等价迁移）命中即 destructive；
 *   - terminal/remote/destructive 一律 require_approval。
 */
import { CapabilityLevel } from '../AgentProvider';

export type PolicyDecisionKind = 'allow' | 'require_approval' | 'deny'

/** 判定入参：工具名 + 原始参数 + 目标上下文。 */
export class ToolCallContext {
  toolName: string = ''
  /** 引擎原始参数（JSON 字符串）。 */
  argsJson: string = ''
  /** 执行目标：local=本地终端 / remote=远程会话。 */
  target: 'local' | 'remote' = 'local'
}

/** 判定出参：kind + 档位 + 原因（deny 时给出拦截原因）。 */
export class PolicyDecision {
  kind: PolicyDecisionKind = 'allow'
  level: CapabilityLevel = 'read_only'
  reason: string = ''
}

export class PolicyEngine {
  /**
   * destructive 黑名单（存量 AgentKernel.riskOf 等价迁移；rm -rf 必中: rm 后跟空白）。
   */
  private static readonly DESTRUCTIVE: RegExp =
    /rm\s|mkfs|dd\s|reboot|shutdown|kill|chmod|chown|>\s*\/|curl.*\|\s*sh|wget.*\|\s*sh/

  /** 存量只读白名单（等价迁移：这些命令在存量语义中判定为 read）。 */
  private static readonly READ_CMD: RegExp =
    /^(ls|cat|pwd|whoami|uname|df|free|ps|ip|ifconfig|netstat|uptime|top|head|tail|grep|echo|date|id)\b/

  /**
   * 注入/逃逸特征（用于非 shell 工具参数）：
   * 分号/管道/命令替换/反引号注入、路径穿越。
   */
  private static readonly INJECTION: RegExp = /[;|`]|\$\(|&&/
  private static readonly TRAVERSAL: RegExp = /(\.\.\/)|(\.\.\\)/

  /** 从 JSON 参数中提取字符串字段（无则 ''）。 */
  static argString(argsJson: string, key: string): string {
    try {
      const o = JSON.parse(argsJson) as Record<string, Object>
      const v = o[key]
      if (typeof v === 'string') {
        return v
      }
      if (typeof v === 'number') {
        return (v as number).toString()
      }
    } catch (e) {
    }
    return ''
  }

  /** workspace_write 工具名匹配。 */
  private static readonly WRITE_TOOLS: RegExp =
    /^(write|edit|create|file_write|file_edit|file_create|patch|save)\b/

  /** terminal 类工具名匹配（与 term_write 等价处理）。 */
  private static readonly SHELL_TOOLS: RegExp =
    /^(shell|bash|execute|term_write)\b/

  /** remote 类工具名匹配。 */
  private static readonly REMOTE_TOOLS: RegExp =
    /^(sftp|scp|ssh|remote)\b/

  /** destructive 类工具名匹配。 */
  private static readonly DESTRUCTIVE_TOOLS: RegExp =
    /^(rm|delete|format|destructive)\b/

  /** 全参数拼接（注入扫描用，覆盖全部字段值）。 */
  private static allArgs(argsJson: string): string {
    if (argsJson === '') {
      return ''
    }
    try {
      const o = JSON.parse(argsJson) as Record<string, Object>
      const parts: string[] = []
      for (const k of Object.keys(o)) {
        parts.push(String(o[k]))
      }
      return parts.join(' ')
    } catch (e) {
      return argsJson
    }
  }

  /** 五档判定主入口。 */
  static evaluate(ctx: ToolCallContext): PolicyDecision {
    const d = new PolicyDecision()
    // terminal 类工具（term_write/shell/bash/execute）：destructive 黑名单 → 远端/本地档
    if (PolicyEngine.SHELL_TOOLS.test(ctx.toolName)) {
      const cmd = PolicyEngine.argString(ctx.argsJson, 'cmd')
      if (PolicyEngine.DESTRUCTIVE.test(cmd)) {
        d.kind = 'require_approval'
        d.level = 'destructive'
        d.reason = '危险命令黑名单命中'
        return d
      }
      d.kind = 'require_approval'
      d.level = ctx.target === 'remote' ? 'remote' : 'terminal'
      d.reason = ctx.target === 'remote' ? '远端终端写入' : '终端写入'
      return d
    }
    // destructive 类工具（rm/delete/format）：一律 destructive 档须审批
    if (PolicyEngine.DESTRUCTIVE_TOOLS.test(ctx.toolName)) {
      d.kind = 'require_approval'
      d.level = 'destructive'
      d.reason = '破坏性操作'
      return d
    }
    // remote 类工具（sftp/scp/ssh/remote）：一律 remote 档须审批
    if (PolicyEngine.REMOTE_TOOLS.test(ctx.toolName)) {
      d.kind = 'require_approval'
      d.level = 'remote'
      d.reason = '远端操作'
      return d
    }
    // workspace_write 工具（write/edit/create 等）：注入/逃逸前置 deny，否则 require_approval
    if (PolicyEngine.WRITE_TOOLS.test(ctx.toolName)) {
      const all = PolicyEngine.allArgs(ctx.argsJson)
      if (PolicyEngine.TRAVERSAL.test(all)) {
        d.kind = 'deny'
        d.level = 'workspace_write'
        d.reason = '路径穿越特征（../）被拦截'
        return d
      }
      if (PolicyEngine.INJECTION.test(all)) {
        d.kind = 'deny'
        d.level = 'workspace_write'
        d.reason = '命令注入特征（;/|/`/$() 被拦截'
        return d
      }
      d.kind = 'require_approval'
      d.level = 'workspace_write'
      d.reason = '工作区写入操作'
      return d
    }
    // 只读工具（term_read/session_info/sftp_list）：注入/逃逸前置 deny，否则 allow
    const all = PolicyEngine.allArgs(ctx.argsJson)
    if (PolicyEngine.TRAVERSAL.test(all)) {
      d.kind = 'deny'
      d.level = 'read_only'
      d.reason = '路径穿越特征（../）被拦截'
      return d
    }
    if (ctx.toolName !== 'term_read' && ctx.toolName !== 'session_info' && PolicyEngine.INJECTION.test(all)) {
      d.kind = 'deny'
      d.level = 'read_only'
      d.reason = '命令注入特征（;/|/`/$() 被拦截'
      return d
    }
    d.kind = 'allow'
    d.level = 'read_only'
    d.reason = '只读工具'
    return d
  }

  /** 存量等价：只读命令启发（供 LocalAssistant system 提示与档位辅助说明）。 */
  static isReadCmd(cmd: string): boolean {
    return PolicyEngine.READ_CMD.test(cmd)
  }

  /** A2UI 预留策略分支（schema validation only，不渲染，spec 5.5.1.6）。 */
  static validateUiActionSchema(payload: string): boolean {
    try {
      const o = JSON.parse(payload) as Record<string, Object>
      return typeof o['type'] === 'string'
    } catch (e) {
      return false
    }
  }
}