/**
 * AuditWriter 脱敏审计（升级 Phase 1 / 任务 2.7，design 2.2.2.5）。
 *
 * - jsonl 追加写 filesDir/agent-audit.jsonl（延续存量文件）；
 * - 新行结构含 ts/sessionId/turn/tool/level/argsDigest/resultDigest/approval/writeOk
 *   （旧行 {ts,round,tool,args,ok,approved,result} 缺字段按默认值解释，向后兼容）；
 * - redact() 凭据脱敏过滤器在序列化前强制执行（spec 6.3.3 / 4.3.5）；
 * - 参数/结果摘要截断 300 字符；写入失败不阻断结果回显，返回 false 由调用方
 *   发 audit_write_failed 事件提示（不静默丢弃）。
 */
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApprovalDecision, CapabilityLevel } from '../AgentProvider';

const TAG: string = 'oat.audit';
const DOMAIN: number = 0x0110;
const DIGEST_MAX: number = 300;

/** 审计单行结构。 */
export class AuditRecord {
  ts: number = 0
  sessionId: string = ''
  turn: number = 0
  tool: string = ''
  level: CapabilityLevel | '' = ''
  argsDigest: string = ''
  resultDigest: string = ''
  approval: ApprovalDecision | '' = ''
  writeOk: boolean = true
}

export class AuditWriter {
  /** 凭据脱敏过滤器：密码/密钥/口令/token 特征替换为 ***。 */
  static redact(s: string): string {
    if (s === '') {
      return ''
    }
    let out = s
    // key=value 形态（password/passwd/pwd/pass/token/secret/api_key/...）
    out = out.replace(
      /(password|passwd|pwd|pass|token|secret|api[-_]?key|apikey|access[-_]?key|private[-_]?key)\s*[:=]\s*[^\s,;"'&]+/gi,
      '$1=***')
    // Bearer / Authorization 头
    out = out.replace(/(Authorization\s*[:=]\s*(Bearer|Basic)?\s*)\S+/gi, '$1***')
    // PEM 私钥块
    out = out.replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
      '-----PRIVATE KEY ***')
    // 连接串口令（scheme://user:pass@host）
    out = out.replace(/(\w+:\/\/[^:/\s]+:)[^@/\s]+@/g, '$1***@')
    return out
  }

  /** 摘要：脱敏 + 截断 300 字符。 */
  static digest(s: string): string {
    const r = AuditWriter.redact(s)
    if (r.length <= DIGEST_MAX) {
      return r
    }
    return r.substring(0, DIGEST_MAX)
  }

  /** 追加一行 jsonl；写入失败返回 false（不抛异常、不阻断回显）。 */
  static append(filesDir: string, rec: AuditRecord): boolean {
    if (filesDir === '') {
      return false
    }
    let f: fs.File | null = null
    try {
      rec.argsDigest = AuditWriter.digest(rec.argsDigest)
      rec.resultDigest = AuditWriter.digest(rec.resultDigest)
      rec.writeOk = true
      const p = filesDir + '/agent-audit.jsonl'
      f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
      fs.writeSync(f.fd, JSON.stringify(rec) + '\n')
      fs.closeSync(f)
      f = null
      return true
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audit append fail %{public}s', e instanceof Error ? e.message : String(e))
      if (f !== null) {
        try {
          fs.closeSync(f)
        } catch (e2) {
        }
      }
      return false
    }
  }
}