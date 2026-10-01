/**
 * upstream M3 relay-1 - credential encryption manager (master-password mode).
 *
 * Upstream port (backend/credentials/store.go + backend/sync):
 *   - credentials.meta (PLAINTEXT JSON): { "mode": "master-password",
 *     "salt": base64(16B) } - upstream meta.go shape;
 *   - the AES key is derived in memory from the master password + salt
 *     (PBKDF2-SHA256 600k) and is NEVER persisted;
 *   - password / keyContent fields inside connections.json are stored as
 *     enc:v1:<b64nonce>:<b64(ct||tag)>;
 *   - fail-closed: without an unlocked master password the store refuses to
 *     save/return plaintext credentials (upstream PasswordStore semantics
 *     when no backend is available), fields decrypt only after unlock;
 *   - forgetting the master password = credentials unrecoverable (salt is
 *     regenerated on reset, upstream re-key path).
 *
 * M3 scope decisions:
 *   - passphrase field: upstream stores the key passphrase in
 *     config.Password (parseAuthKeySigner), so the passphrase is encrypted
 *     as part of the "password" field - no separate on-disk field.
 */
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import {
  ENC_PREFIX, EncError, isEncrypted, encryptField, decryptField,
  deriveKeyPbkdf2, generateSalt
} from './EncCrypto';

const TAG: string = 'oat.cred';
const DOMAIN: number = 0x0110;
const META_FILE: string = 'credentials.meta';

export class CredError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}

/** credentials.meta on-disk shape (upstream metaJSON). */
export class CredMeta {
  mode: string = ''; // "master-password" (or "" when no file)
  saltB64: string = '';
}

export type UnlockListener = () => void;

export class CredentialManager {
  private dir: string = '';
  private key: Uint8Array | null = null; // derived AES key, memory only
  private meta: CredMeta | null = null; // null = no meta file yet
  private listeners: UnlockListener[] = [];

  constructor(filesDir: string) {
    this.dir = filesDir;
    this.meta = this.readMeta();
  }

  get metaPath(): string {
    return this.dir + '/' + META_FILE;
  }

  /** True when a master password exists (meta file present). */
  hasMasterPassword(): boolean {
    return this.meta !== null && this.meta.mode === 'master-password';
  }

  /** True when the derived key is live in memory. */
  isUnlocked(): boolean {
    return this.key !== null;
  }

  onUnlock(l: UnlockListener): void {
    this.listeners.push(l);
  }

  private fireUnlock(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  private readMeta(): CredMeta | null {
    try {
      if (!fileIo.accessSync(this.metaPath)) {
        return null;
      }
      const raw = JSON.parse(fileIo.readTextSync(this.metaPath, { encoding: 'utf-8' })) as Record<string, Object>;
      const m = new CredMeta();
      m.mode = (raw['mode'] as string) ?? '';
      m.saltB64 = (raw['salt'] as string) ?? '';
      return m;
    } catch (e) {
      const be = e as Error;
      hilog.error(DOMAIN, TAG, 'readMeta fail %{public}s', JSON.stringify(be.message));
      return null;
    }
  }

  private writeMeta(m: CredMeta): void {
    const obj: Record<string, Object> = {};
    obj['mode'] = m.mode;
    if (m.saltB64.length > 0) {
      obj['salt'] = m.saltB64;
    }
    fileIo.writeSync(fileIo.openSync(this.metaPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd,
    JSON.stringify(obj));
  }

  /**
   * First-time setup: generate a fresh salt, persist meta, derive the key.
   * Upstream EnableMasterPassword path.
   */
  public async setupMasterPassword(password: string): Promise<void> {
    if (password.length === 0) {
      throw new CredError('master password must not be empty');
    }
    const salt = generateSalt();
    const m = new CredMeta();
    m.mode = 'master-password';
    m.saltB64 = b64u(salt);
    this.writeMeta(m);
    this.meta = m;
    this.key = await deriveKeyPbkdf2(password, salt);
    this.fireUnlock();
    hilog.info(DOMAIN, TAG, 'master password set (mode=master-password)');
  }

  /**
   * Unlock with an existing master password. Wrong password is detected
   * lazily at decrypt time (upstream semantics: no verifier blob on disk).
   * Returns true when a key was derived.
   */
  public async unlock(password: string): Promise<boolean> {
    if (!this.hasMasterPassword()) {
      throw new CredError('no master password configured');
    }
    const salt = b64d(this.meta!.saltB64);
    if (salt === null) {
      throw new CredError('credentials.meta has no salt');
    }
    this.key = await deriveKeyPbkdf2(password, salt);
    this.fireUnlock();
    return true;
  }

  /** Drop the in-memory key (lock). */
  public lock(): void {
    this.key = null;
    hilog.info(DOMAIN, TAG, 'locked');
  }

  /**
   * Reset: forget the master password + salt. Existing enc:v1 fields become
   * permanently unreadable (upstream "forget = unrecoverable").
   */
  public reset(): void {
    try {
      if (fileIo.accessSync(this.metaPath)) {
        fileIo.unlinkSync(this.metaPath);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'reset unlink fail %{public}s', JSON.stringify(e));
    }
    this.meta = null;
    this.key = null;
    hilog.info(DOMAIN, TAG, 'master password reset (old ciphertexts unrecoverable)');
  }

  /** Encrypt one field. Fails closed when not unlocked. */
  public async seal(plain: string): Promise<string> {
    if (this.key === null) {
      throw new CredError('fail-closed: master password not unlocked');
    }
    return encryptField(plain, this.key);
  }

  /**
   * Decrypt one field. Fails closed when not unlocked. Returns null when the
   * value is empty; caller marks enc:v1 values it cannot decrypt (wrong
   * master password) instead of silently emptying them.
   */
  public async open(value: string): Promise<string> {
    if (value.length === 0) {
      return '';
    }
    if (!isEncrypted(value)) {
      return value; // legacy plaintext (imported file without master password)
    }
    if (this.key === null) {
      throw new CredError('fail-closed: enc:v1 field present but master password not unlocked');
    }
    try {
      return await decryptField(value, this.key);
    } catch (e) {
      if (e instanceof EncError) {
        throw new CredError('decrypt failed (wrong master password?)');
      }
      const be = e as Error;
      throw new CredError(be.message);
    }
  }

  /** Prefix check helper for UI badging. */
  public static isEnc(value: string): boolean {
    return value.indexOf(ENC_PREFIX) === 0;
  }
}

function b64u(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  const out = helper.encodeSync(bytes, util.Type.BASIC);
  const td = util.TextDecoder.create('utf-8');
  return td.decodeWithStream(out);
}

function b64d(s: string): Uint8Array | null {
  try {
    const helper = new util.Base64Helper();
    return helper.decodeSync(s);
  } catch (e) {
    return null;
  }
}
