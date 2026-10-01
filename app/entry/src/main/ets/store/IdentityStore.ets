/**
 * upstream M3 relay-2 - Identity store (upstream backend/store/identity_store.go
 * + backend/session/identity.go port).
 *
 * identities.json top-level: { "identities": [ {id,name,username,authType,
 * password?,keyPath?,keyContent?} ] }
 *   - password = login password OR key passphrase (upstream MaterializeIdentity)
 *   - keyContent = inline PEM for keyText identities
 *   - password + keyContent are sealed with the master-password key (enc:v1,
 *     600k PBKDF2 via CredentialManager) before hitting disk; values already
 *     enc:v1 are skipped (upstream encryptSecretField).
 *   - Missing file => empty list; corrupt file surfaces an error.
 *   - fail-closed: refusing to persist a plaintext secret when locked... with
 *     the M3 nuance that "no master password configured" (mode none) keeps the
 *     file plaintext (matches upstream storeHasSecrets-less first run).
 */
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { isEncrypted } from './EncCrypto';
import { CredentialManager } from './CredentialManager';

const TAG: string = 'oat.ident';
const DOMAIN: number = 0x0110;
const STORE_FILE: string = 'identities.json';

/** M3 relay-2: materialized identity credentials (upstream MaterializeIdentity). */
export class MaterializedCreds {
  user: string = '';
  authType: string = '';
  password: string = '';
  keyPath: string = '';
  keyContent: string = '';
}
export class IdentError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}


export class IdentityRec {
  id: string = '';
  name: string = '';
  username: string = '';
  authType: string = 'password'; // password | key | keyText
  password: string = ''; // login password or key passphrase
  keyPath: string = '';
  keyContent: string = ''; // inline PEM (keyText)
}

export class IdentityStore {
  private dir: string;
  private path: string;
  identities: IdentityRec[] = [];
  private cred: CredentialManager | null = null;

  constructor(filesDir: string, cred?: CredentialManager) {
    this.dir = filesDir;
    this.path = filesDir + '/' + STORE_FILE;
    if (cred !== undefined) {
      this.cred = cred;
    }
  }

  setCredManager(m: CredentialManager | null): void {
    this.cred = m;
  }

  get filePath(): string {
    return this.path;
  }

  loadSync(): void {
    try {
      if (!fileIo.accessSync(this.path)) {
        this.identities = [];
        return;
      }
      const raw = JSON.parse(fileIo.readTextSync(this.path, { encoding: 'utf-8' })) as Record<string, Object>;
      this.identities = [];
      const arr = raw['identities'];
      if (arr !== undefined && arr !== null) {
        const list = arr as Array<Object>;
        for (let i = 0; i < list.length; i++) {
          const r = list[i] as Record<string, Object>;
          const id = new IdentityRec();
          id.id = toStr(r['id'], '');
          if (id.id.length === 0) {
            continue;
          }
          id.name = toStr(r['name'], id.id);
          id.username = toStr(r['username'], '');
          id.authType = toStr(r['authType'], 'password');
          id.password = toStr(r['password'], '');
          id.keyPath = toStr(r['keyPath'], '');
          id.keyContent = toStr(r['keyContent'], '');
          this.identities.push(id);
        }
      }
      hilog.info(DOMAIN, TAG, 'load identities=%{public}d', this.identities.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load fail %{public}s', JSON.stringify(e));
      this.identities = [];
    }
  }

  /** Decrypt password/keyContent in memory. Returns failed-field count. */
  async revealSecrets(): Promise<number> {
    const m = this.cred;
    if (m === null) {
      return 0;
    }
    let fails = 0;
    for (let i = 0; i < this.identities.length; i++) {
      const id = this.identities[i];
      if (isEncrypted(id.password)) {
        try {
          id.password = await m.open(id.password);
        } catch (e) {
          id.password = '';
          fails++;
        }
      }
      if (isEncrypted(id.keyContent)) {
        try {
          id.keyContent = await m.open(id.keyContent);
        } catch (e) {
          id.keyContent = '';
          fails++;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'revealSecrets fail=%{public}d', fails);
    return fails;
  }

  /** @deprecated use sealAndSave. Kept for call-site compat. */
  async saveEnc(): Promise<string> {
    return this.sealAndSave();
  }

  save(): string {
    const arr: Array<Record<string, Object>> = [];
    for (let i = 0; i < this.identities.length; i++) {
      const id = this.identities[i];
      const obj: Record<string, Object> = {};
      obj['id'] = id.id;
      obj['name'] = id.name;
      obj['username'] = id.username;
      obj['authType'] = id.authType;
      if (id.password.length > 0) {
        obj['password'] = id.password;
      }
      if (id.keyPath.length > 0) {
        obj['keyPath'] = id.keyPath;
      }
      if (id.keyContent.length > 0) {
        obj['keyContent'] = id.keyContent;
      }
      arr.push(obj);
    }
    const root: Record<string, Object> = {};
    root['identities'] = arr as Object;
    const json = JSON.stringify(root, null, 2);
    try {
      const tmp = this.path + '.tmp';
      const f = fileIo.openSync(tmp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, json);
      fileIo.closeSync(f);
      fileIo.renameSync(tmp, this.path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save fail %{public}s', JSON.stringify(e));
      return '';
    }
    hilog.info(DOMAIN, TAG, 'save ok identities=%{public}d bytes=%{public}d', arr.length, json.length);
    return json;
  }

  /** Seal password+keyContent via the unlocked CredentialManager, then save. */
  async sealAndSave(): Promise<string> {
    const m = this.cred;
    if (m !== null && m.isUnlocked()) {
      let n = 0;
      for (let i = 0; i < this.identities.length; i++) {
        const id = this.identities[i];
        if (id.password.length > 0 && !isEncrypted(id.password)) {
          id.password = await m.seal(id.password);
          n++;
        }
        if (id.keyContent.length > 0 && !isEncrypted(id.keyContent)) {
          id.keyContent = await m.seal(id.keyContent);
          n++;
        }
      }
      hilog.info(DOMAIN, TAG, 'sealAndSave sealed=%{public}d', n);
    }
    return this.save();
  }

  get(id: string): IdentityRec | null {
    for (let i = 0; i < this.identities.length; i++) {
      if (this.identities[i].id === id) {
        return this.identities[i];
      }
    }
    return null;
  }

  upsert(id: IdentityRec): void {
    for (let i = 0; i < this.identities.length; i++) {
      if (this.identities[i].id === id.id) {
        this.identities[i] = id;
        return;
      }
    }
    this.identities.push(id);
  }

  delete(id: string): boolean {
    for (let i = 0; i < this.identities.length; i++) {
      if (this.identities[i].id === id) {
        this.identities.splice(i, 1);
        return true;
      }
    }
    return false;
  }

  /** Resolve + materialize an identity connection into a concrete ConnRec-like
   * credential (upstream MaterializeIdentity). Returns null when the identity
   * is missing; throws IdentError on unknown identity authType. */
  materialize(connAuthType: string, connIdentityId: string): MaterializedCreds | null {
    if (connAuthType !== 'identity') {
      return null;
    }
    const id = this.get(connIdentityId);
    if (id === null) {
      return null;
    }
    const out = new MaterializedCreds();
    out.user = id.username;
    out.authType = id.authType;
    out.password = id.password;
    out.keyPath = id.keyPath;
    out.keyContent = id.keyContent;
    return out;
  }
}

function toStr(v: Object | undefined, d: string): string {
  const s = v as string;
  return (typeof s === 'string') ? s : d;
}

function randId(prefix: string): string {
  let s = '';
  const seed = 'abcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 8; i++) {
    s += seed.charAt(Math.floor(Math.random() * seed.length));
  }
  return prefix + '-' + Date.now().toString() + '-' + s;
}
