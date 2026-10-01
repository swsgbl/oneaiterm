/**
 * upstream M3 relay-1 - upstream-compatible credential field crypto (enc:v1).
 *
 * Bit-exact port of upstream backend/credentials/crypto.go:
 *   prefix  = "enc:v1:"
 *   value   = base64Std(nonce) + ":" + base64Std(ciphertext)
 *   cipher  = AES-256-GCM, 12-byte fresh random nonce per encryption,
 *             16-byte tag APPENDED to the ciphertext (Go's gcm.Seal layout).
 *   key     = 32 bytes; derived from the master password via
 *             PBKDF2-SHA256, 600000 iterations, 16-byte random salt
 *             (upstream sync.DeriveKey / GenerateSalt constants - NOTE the
 *             task brief said 210k but the upstream source of truth is
 *             pbkdf2Iterations = 600000 in backend/sync/keychain.go:15).
 *
 * Implemented on @ohos.security.cryptoFramework (PBKDF2 + AES-GCM-256).
 * Cross-verified against Go in both directions (evidence/M3/interop).
 */
import { util } from '@kit.ArkTS';

import { libssh } from '@ohos/libssh';

let gSshInst: libssh | null = null;
function gSsh(): libssh {
  if (gSshInst === null) {
    gSshInst = new libssh();
  }
  return gSshInst;
}

function toHexStr(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}


export const ENC_PREFIX: string = 'enc:v1:';
const PBKDF2_ITERATIONS: number = 600000; // upstream
const KEY_LEN: number = 32; // AES-256
const SALT_LEN: number = 16;
const NONCE_LEN: number = 12;
const TAG_LEN: number = 16;

export class EncError extends Error {
  constructor(msg: string) {
    super(msg);
  }
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

/** true when the stored value carries the upstream enc:v1 prefix. */
export function isEncrypted(v: string): boolean {
  return v.indexOf(ENC_PREFIX) === 0;
}

/**
 * PBKDF2-SHA256(password, salt, 600000, 32) - upstream DeriveKey bit-exact.
 * Exposed for the Go cross-check tool (derived-key digest comparison).
 * M3 relay-2: optional `iterations` override for .utm kdf (100000,
 * upstream importer/crypto.go - a DIFFERENT constant from the master one).
 */
export async function deriveKeyPbkdf2(password: string, salt: Uint8Array, iterations?: number): Promise<Uint8Array> {
  const iter = (iterations === undefined) ? PBKDF2_ITERATIONS : iterations;
  const hex = await gSsh().kdfDerive(password, toHexStr(salt), iter, KEY_LEN);
  return hexToBytes(hex);
}

/** 16-byte random salt - upstream GenerateSalt. */
export function generateSalt(): Uint8Array {
  return hexToBytes(gSsh().randBytes(SALT_LEN));
}

/**
 * EncryptField(plaintext, key) - upstream layout:
 *   "enc:v1:" + base64(nonce12) + ":" + base64(ct||tag16)
 * Fresh random nonce on every call (upstream TestEncryptFieldUsesFreshNonce).
 */
export async function encryptField(plain: string, key: Uint8Array): Promise<string> {
  const sealed = await gSsh().encSeal(plain, toHexStr(key));
  return ENC_PREFIX + sealed;
}

/**
 * DecryptField(value, key) - inverse of encryptField. Throws EncError on
 * malformed input or auth failure (wrong key => tag mismatch, upstream
 * TestDecryptFieldWrongKeyFails).
 */
export async function decryptField(v: string, key: Uint8Array): Promise<string> {
  if (!isEncrypted(v)) {
    throw new EncError('field is not ' + ENC_PREFIX + ' encrypted');
  }
  const body = v.substring(ENC_PREFIX.length);
  return gSsh().encOpen(body, toHexStr(key));
}

/** Debug/interop helper: hex digest of a derived key (never log the key itself). */
export async function deriveKeyHex(password: string, salt: Uint8Array): Promise<string> {
  return toHex(await deriveKeyPbkdf2(password, salt));
}
