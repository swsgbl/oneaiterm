/**
 * upstream M3 relay-2 - .utm export (upstream importer/upstream.go port).
 *
 * Exportupstream semantics (verbatim from upstream):
 *   - envelope: {format:"upstream", version:1, encrypted:bool, kdf?, groups, connections}
 *   - password == "": every connection's Password field is CLEARED, encrypted=false,
 *     no kdf block. keyContent/keyPath stay as they are in memory (upstream only
 *     touches Password).
 *   - password != "": ONE shared random 16B salt for the whole file; kdf block
 *     {algo:"pbkdf2-sha256", iterations:100000 (importer/crypto.go:14), salt:b64std};
 *     per connection: skip when Password is "" or already enc:v1: prefixed
 *     (never double-encrypt); otherwise seal with AES-256-GCM under the
 *     PBKDF2(100k) key => "enc:v1:<b64nonce>:<b64(ct||tag)>".
 *   - output is JSON.stringify(...,2) like Go's json.MarshalIndent(f,"","  ").
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { libssh } from '@ohos/libssh';
import { ConnRec, GroupRec } from './ConnStore';
import { ENC_PREFIX, isEncrypted, encryptField, deriveKeyPbkdf2 } from './EncCrypto';

const TAG: string = 'oat.utm';
const DOMAIN: number = 0x0110;
/** upstream importer/crypto.go:14 kdfIterations (utm export kdf ≠ master-password 600k). */
export const UTM_KDF_ITERATIONS: number = 100000;
export const UTM_KDF_ALGO: string = 'pbkdf2-sha256';

export class UtmError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}

let gSshInst: libssh | null = null;
function gSsh(): libssh {
  if (gSshInst === null) {
    gSshInst = new libssh();
  }
  return gSshInst;
}
function gRandSaltHex(): string {
  return gSsh().randBytes(16);
}

function b64std(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes, util.Type.BASIC);
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** Export the in-memory store (already revealed) to .utm JSON text. */
export async function exportUtm(groups: GroupRec[], conns: ConnRec[], password: string): Promise<string> {
  const root: Record<string, Object> = {};
  root['format'] = 'oatuser';
  root['version'] = 1;
  if (password.length === 0) {
    root['encrypted'] = false;
    const cArr: Array<Record<string, Object>> = [];
    for (let i = 0; i < conns.length; i++) {
      const c = conns[i];
      const obj = connToObj(c);
      // upstream: password=="" clears Password field (others untouched)
      obj['password'] = ''; // Go omits? No: Go sets Password="" which omits via omitempty
      cArr.push(obj);
    }
    root['groups'] = groupArr(groups);
    root['connections'] = cArr as Object;
    return JSON.stringify(root, null, 2);
  }
  // encrypted export: one shared salt for the file
  const helper = new util.Base64Helper();
  const saltHex = gRandSaltHex();
  const salt: Uint8Array = hexToBytes(saltHex);
  const key = await deriveKeyPbkdf2(password, salt, UTM_KDF_ITERATIONS);
  const kdf: Record<string, Object> = {};
  kdf['algo'] = UTM_KDF_ALGO;
  kdf['iterations'] = UTM_KDF_ITERATIONS;
  kdf['salt'] = b64std(salt);
  root['encrypted'] = true;
  root['kdf'] = kdf as Object;
  const cArr: Array<Record<string, Object>> = [];
  for (let i = 0; i < conns.length; i++) {
    const c = conns[i];
    const obj = connToObj(c);
    // upstream skips "" and enc:v1: (no double-encrypt; sealed values pass through)
    if (c.password.length > 0 && !isEncrypted(c.password)) {
      obj['password'] = await encryptField(c.password, key);
    }
    cArr.push(obj);
  }
  root['groups'] = groupArr(groups);
  root['connections'] = cArr as Object;
  hilog.info(DOMAIN, TAG, 'exportUtm enc=1 conns=%{public}d bytes≈%{public}d', conns.length, cArr.length);
  return JSON.stringify(root, null, 2);
}

function groupArr(groups: GroupRec[]): Object {
  const gArr: Array<Record<string, Object>> = [];
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    const obj: Record<string, Object> = {};
    obj['id'] = g.id;
    obj['name'] = g.name;
    if (g.parentId !== null) {
      obj['parentId'] = g.parentId;
    }
    gArr.push(obj);
  }
  return gArr as Object;
}

/** ConnRec -> upstream ConnectionConfig JSON object (subset we manage). */
export function connToObj(c: ConnRec): Record<string, Object> {
  const obj: Record<string, Object> = {};
  obj['id'] = c.id;
  obj['name'] = c.name;
  if (c.remark.length > 0) {
    obj['remark'] = c.remark;
  }
  obj['type'] = c.type;
  obj['host'] = c.host;
  obj['port'] = c.port;
  obj['user'] = c.user;
  obj['authType'] = c.authType;
  if (c.identityId.length > 0) {
    obj['identityId'] = c.identityId;
  }
  if (c.password.length > 0) {
    obj['password'] = c.password;
  }
  if (c.keyPath.length > 0) {
    obj['keyPath'] = c.keyPath;
  }
  if (c.keyContent.length > 0) {
    obj['keyContent'] = c.keyContent;
  }
  if (c.groupId !== null) {
    obj['groupId'] = c.groupId;
  }
  if (c.encoding !== 'utf-8') {
    obj['encoding'] = c.encoding;
  }
  if (c.backspaceKey !== 'del') {
    obj['backspaceKey'] = c.backspaceKey;
  }
  if (c.postLoginScript.length > 0) {
    obj['postLoginScript'] = c.postLoginScript;
  }
  obj['logOnConnect'] = c.logOnConnect;
  return obj;
}
