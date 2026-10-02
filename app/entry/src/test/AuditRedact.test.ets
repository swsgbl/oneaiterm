/**
 * AuditWriter 脱敏过滤器单元测试（升级 Phase 1 / 任务 2.2，ArkTS/hypium）。
 *
 * 纯函数复制 replicates AuditWriter.redact()/digest()（dependency-free）。
 * 覆盖：密码/密钥/口令/token 特征替换、Bearer 头、PEM 私钥块、
 * 连接串口令、digest 300 字符截断（spec 6.3.3 / 4.3.5：审计中不出现凭据）。
 */

const DIGEST_MAX: number = 300

function redact(s: string): string {
  if (s === '') {
    return ''
  }
  let out = s
  out = out.replace(
    /(password|passwd|pwd|pass|token|secret|api[-_]?key|apikey|access[-_]?key|private[-_]?key)\s*[:=]\s*[^\s,;"'&]+/gi,
    '$1=***')
  out = out.replace(/(Authorization\s*[:=]\s*(Bearer|Basic)?\s*)\S+/gi, '$1***')
  out = out.replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
    '-----PRIVATE KEY ***')
  out = out.replace(/(\w+:\/\/[^:/\s]+:)[^@/\s]+@/g, '$1***@')
  return out
}

function digest(s: string): string {
  const r = redact(s)
  if (r.length <= DIGEST_MAX) {
    return r
  }
  return r.substring(0, DIGEST_MAX)
}

export default function auditRedactTest() {
  describe('auditRedactFilter', () => {
    it('password_kv_is_redacted', 0, () => {
      expect(redact('password=hunter2').indexOf('hunter2') < 0).assertTrue();
    });

    it('passwd_and_pass_kv_redacted', 0, () => {
      expect(redact('passwd=abc123').indexOf('abc123') < 0).assertTrue();
      expect(redact('pass=xyz').indexOf('xyz') < 0).assertTrue();
    });

    it('token_and_apikey_kv_redacted', 0, () => {
      expect(redact('token=eyJhbGci').indexOf('eyJhbGci') < 0).assertTrue();
      expect(redact('api_key=sk-1234').indexOf('sk-1234') < 0).assertTrue();
      expect(redact('apiKey=sk-5678').indexOf('sk-5678') < 0).assertTrue();
    });

    it('bearer_header_redacted', 0, () => {
      expect(redact('Authorization: Bearer abc.def.ghi').indexOf('abc.def.ghi') < 0).assertTrue();
    });

    it('pem_private_key_block_redacted', 0, () => {
      const pem = '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----'
      expect(redact(pem).indexOf('MIIEpAIBAAKCAQEA') < 0).assertTrue();
    });

    it('url_credential_redacted', 0, () => {
      expect(redact('ssh://admin:p4ssw0rd@host:22').indexOf('p4ssw0rd') < 0).assertTrue();
    });

    it('plain_text_untouched', 0, () => {
      const t = 'ls -la /home/user; uname -a'
      expect(redact(t) === t).assertTrue();
    });

    it('digest_truncates_to_300', 0, () => {
      let long = ''
      for (let i = 0; i < 500; i++) {
        long += 'a'
      }
      expect(digest(long).length === DIGEST_MAX).assertTrue();
    });

    it('digest_redacts_before_truncate', 0, () => {
      let long = 'password=secret123 '
      for (let i = 0; i < 400; i++) {
        long += 'x'
      }
      expect(digest(long).indexOf('secret123') < 0).assertTrue();
    });

    it('empty_string_passthrough', 0, () => {
      expect(redact('') === '').assertTrue();
    });
  });
}