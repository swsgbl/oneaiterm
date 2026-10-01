/**
 * upstream M3 relay-2 - Importer for upstream the upstream project formats.
 *
 * Supported inputs:
 *   1) connections.json  - { groups: [...], connections: [...] }
 *   2) .utm plaintext    - { format:"upstream", version:1, encrypted:false }
 *   3) .utm ENCRYPTED (M3 relay-2) - encrypted:true + kdf block
 *      { algo:"pbkdf2-sha256", iterations (adaptive from file header),
 *        salt:b64std }; Password fields are enc:v1 sealed under the
 *      PBKDF2(iterations) key. Wrong password => "导入密码错误".
 *
 * Behavior mirrors upstream parseupstream:
 *   - upstream mints fresh ids; M4 relay-3: payload ids are PRESERVED when
 *     present (export round-trips reuse them => idempotent re-imports);
 *     id-less payloads still get fresh ids; groupId/parentId remapped;
 *   - upstream decrypts EVERY non-empty Password when encrypted (no enc:v1
 *     prefix check) - we match that, tolerating plaintext passthrough;
 *   - unknown/uneditable connection types imported as flagged placeholders.
 */
import { ConnRec, GroupRec } from './ConnStore';
import { ENC_PREFIX, isEncrypted, decryptField, deriveKeyPbkdf2 } from './EncCrypto';
import { util } from '@kit.ArkTS';

/** Supported connection types in M1b (SSH subset). */
const EDITABLE_TYPES: string[] = ['ssh'];

export class ImportError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}

/** Normalized import result, ImportResult equivalent (no warnings yet). */
export class ImportResult {
  groups: GroupRec[] = [];
  connections: ConnRec[] = [];
  unsupported: string[] = []; // names of connections whose type is not connectable
}

function newId(prefix: string): string {
  let s = '';
  const seed = 'abcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 8; i++) {
    s += seed.charAt(Math.floor(Math.random() * seed.length));
  }
  return prefix + '-' + Date.now().toString() + '-' + s;
}

function toStr(v: Object | undefined, d: string): string {
  const s = v as string;
  return (typeof s === 'string') ? s : d;
}

function toNum(v: Object | undefined, d: number): number {
  const n = v as number;
  return (typeof n === 'number') ? n : d;
}

function toBool(v: Object | undefined, d: boolean): boolean {
  const b = v as boolean;
  return (typeof b === 'boolean') ? b : d;
}

function b64stdToBytes(s: string): Uint8Array | null {
  try {
    const helper = new util.Base64Helper();
    return helper.decodeSync(s);
  } catch (e) {
    return null;
  }
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toHexStr(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

/** Parsed .utm envelope fields (format/version/encrypted detection). */
class UtmHead {
  hasHead: boolean = false;
  formatOk: boolean = false;
  encrypted: boolean = false;
}

function readHead(root: Record<string, Object>): UtmHead {
  const h = new UtmHead();
  const fmt = root['format'];
  if (fmt === undefined) {
    return h; // plain connections.json
  }
  h.hasHead = true;
  h.formatOk = toStr(fmt, '') === 'oatuser';
  h.encrypted = toBool(root['encrypted'], false);
  return h;
}

/**
 * M4 relay-3: stable id passthrough for idempotent re-imports.
 * When the payload carries its own ids (export round-trips reuse them), keep
 * them for groups / connections so a re-import of the same payload upserts
 * instead of appending. Payloads without ids get the historical fresh-id
 * behavior.
 */
function stableId(v: Object | undefined): string {
  const s = v as string;
  return (typeof s === 'string' && s.length > 0) ? s : '';
}

/**
 * Main entry (M3 relay-2): parse text; when the file is an encrypted .utm,
 * decrypt Password fields with `password` under the file-header kdf params.
 * Throws ImportError with a clear message on any failure (wrong password,
 * missing kdf, bad json, wrong format).
 */
export async function parseImportEnc(text: string, password: string): Promise<ImportResult> {
  let parsed: Object;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    throw new ImportError('文件不是有效的 JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || parsed === undefined) {
    throw new ImportError('文件内容不是对象');
  }
  const root = parsed as Record<string, Object>;
  const head = readHead(root);
  if (head.hasHead && !head.formatOk) {
    throw new ImportError('不是 upstream 文件 (format 不是 upstream)');
  }
  if (head.encrypted) {
    if (password.length === 0) {
      throw new ImportError('文件已加密:请输入导入密码');
    }
    const kdfRaw = root['kdf'];
    if (kdfRaw === undefined || kdfRaw === null) {
      throw new ImportError('加密文件缺少 kdf 块');
    }
    const kdf = kdfRaw as Record<string, Object>;
    const algo = toStr(kdf['algo'], '');
    if (algo !== 'pbkdf2-sha256') {
      throw new ImportError('不支持的 kdf 算法: ' + algo);
    }
    const iterations = toNum(kdf['iterations'], 100000);
    const saltB64 = toStr(kdf['salt'], '');
    const salt = b64stdToBytes(saltB64);
    if (salt === null || salt.length === 0) {
      throw new ImportError('kdf salt 解码失败');
    }
    const key = await deriveKeyPbkdf2(password, salt, iterations);
    // upstream: decrypt EVERY non-empty Password (adaptive per file header)
    const connsRaw0 = root['connections'];
    if (connsRaw0 !== undefined && connsRaw0 !== null) {
      const arr0 = connsRaw0 as Array<Object>;
      for (let i = 0; i < arr0.length; i++) {
        const r = arr0[i] as Record<string, Object>;
        const p = toStr(r['password'], '');
        if (p.length === 0) {
          continue;
        }
        try {
          r['password'] = await decryptField(p, key);
        } catch (e) {
          throw new ImportError('导入密码错误或密文损坏');
        }
      }
    }
  }
  // plaintext .utm / connections.json: reject stray enc:v1 fields (same as M1b)
  if (!head.encrypted) {
    const connsRaw = root['connections'];
    if (connsRaw !== undefined && connsRaw !== null) {
      const arr = connsRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const r = arr[i] as Record<string, Object>;
        const p = toStr(r['password'], '');
        if (p.indexOf('enc:v1:') === 0) {
          throw new ImportError('文件包含加密字段但未标记 encrypted,请用加密导入');
        }
      }
    }
  }
  return buildResult(root);
}

function buildResult(root: Record<string, Object>): ImportResult {
  const res = new ImportResult();

  // 1) groups: M4 relay-3 - reuse the payload's own id when present
  // (export round-trips / upstream files carry ids; re-import then upserts
  // instead of appending). Id-less payloads keep the historical fresh-id map.
  const idMap: Record<string, string> = {};
  const gs = root['groups'];
  if (gs !== undefined && gs !== null) {
    const arr = gs as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i] as Record<string, Object>;
      const oldId = toStr(r['id'], '');
      const name = toStr(r['name'], '');
      if (name.length === 0) {
        continue; // no name -> broken record, skip
      }
      const g = new GroupRec();
      const keepId = stableId(r['id']);
      const newIdFinal = (keepId.length > 0) ? keepId : newId('grp');
      g.id = newIdFinal;
      g.name = name;
      // id-less group: map synthetic fresh id to itself so parentId/groupId
      // refs inside the same payload still resolve; no old id available.
      idMap[newIdFinal] = newIdFinal;
      if (oldId.length > 0) {
        idMap[oldId] = newIdFinal;
      }
      res.groups.push(g);
    }
    // remap parentId (nested groups keep their hierarchy if parent was imported)
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i] as Record<string, Object>;
      const oldId = toStr(r['id'], '');
      const pid = r['parentId'];
      if ((typeof (pid as string) === 'string') && idMap[oldId] !== undefined) {
        const np = idMap[pid as string];
        if (np !== undefined) {
          for (let k = 0; k < res.groups.length; k++) {
            if (res.groups[k].id === idMap[oldId]) {
              res.groups[k].parentId = np;
            }
          }
        }
      }
    }
  }

  // 2) connections: M4 relay-3 - reuse payload id when present (idempotent
  // re-import), otherwise fresh id as before.
  const connsRaw = root['connections'];
  if (connsRaw !== undefined && connsRaw !== null) {
    const arr = connsRaw as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i] as Record<string, Object>;
      const c = new ConnRec();
      const oldId = toStr(r['id'], '');
      if (oldId.length === 0 && toStr(r['host'], '').length === 0) {
        continue; // no id and no host -> unrecognizable, skip
      }
      const keepId = stableId(r['id']);
      c.id = (keepId.length > 0) ? keepId : newId('conn');
      c.name = toStr(r['name'], toStr(r['host'], oldId));
      c.remark = toStr(r['remark'], '');
      c.type = toStr(r['type'], 'ssh');
      c.host = toStr(r['host'], '');
      c.port = toNum(r['port'], 22);
      c.user = toStr(r['user'], '');
      c.authType = toStr(r['authType'], 'password');
      c.identityId = toStr(r['identityId'], '');
      c.password = toStr(r['password'], '');
      c.keyPath = toStr(r['keyPath'], '');
      c.keyContent = toStr(r['keyContent'], '');
      const gid = r['groupId'];
      if (typeof (gid as string) === 'string') {
        const ng = idMap[gid as string];
        c.groupId = (ng !== undefined) ? ng : null;
      }
      c.encoding = toStr(r['encoding'], 'utf-8');
      c.backspaceKey = toStr(r['backspaceKey'], 'del');
      c.keepaliveSec = toNum(r['keepaliveSec'], 30);
      c.favorite = toBool(r['favorite'], false);
      c.lastUsedAt = toNum(r['lastUsedAt'], 0);
      c.initialCols = toNum(r['initialCols'], 0);
      c.initialRows = toNum(r['initialRows'], 0);
      c.postLoginScript = toStr(r['postLoginScript'], '');
      c.logOnConnect = toBool(r['logOnConnect'], false);
      c.tunnelSSHConnId = toStr(r['tunnelSSHConnId'], '');
      c.proxyId = toStr(r['proxyId'], '');
      if (EDITABLE_TYPES.indexOf(c.type) < 0) {
        res.unsupported.push(c.name);
      }
      res.connections.push(c);
    }
  }
  return res;
}

/** Legacy sync entry (plaintext only) - kept for the want autoimport channel. */
export function parseImport(text: string): ImportResult {
  let parsed: Object;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    throw new ImportError('文件不是有效的 JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || parsed === undefined) {
    throw new ImportError('文件内容不是对象');
  }
  const root = parsed as Record<string, Object>;
  const head = readHead(root);
  if (head.hasHead && !head.formatOk) {
    throw new ImportError('不是 upstream 文件 (format 不是 upstream)');
  }
  if (head.encrypted) {
    throw new ImportError('加密文件请用带密码的导入入口');
  }
  const connsRaw = root['connections'];
  if (connsRaw !== undefined && connsRaw !== null) {
    const arr = connsRaw as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i] as Record<string, Object>;
      const p = toStr(r['password'], '');
      if (p.indexOf('enc:v1:') === 0) {
        throw new ImportError('文件包含加密字段但未标记 encrypted,请用加密导入');
      }
    }
  }
  return buildResult(root);
}

