/**
 * upstream M1b - Connection store (connections.json data layer).
 * Schema-compatible with upstream the upstream project (backend/session/session.go):
 *   top-level  { "groups": [...], "connections": [...] }
 *   Group      { id, name, parentId }            parentId null = root
 *   Connection upstream field names verbatim; SSH subset managed in M1b,
 *   all other fields get upstream defaults on write.
 * Unknown fields read from the file are preserved on rewrite so files stay
 * interchangeable with the upstream app.
 */
import { fileIo } from '@kit.CoreFileKit';
import { CredentialManager } from './CredentialManager';
import { isEncrypted } from './EncCrypto';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'oat.store';
const DOMAIN: number = 0x0110;
const STORE_FILE: string = 'connections.json';

/** In-memory group record. */
export class GroupRec {
  id: string = '';
  name: string = '';
  parentId: string | null = null;
}

/** In-memory connection record, upstream ConnectionConfig SSH subset. */
export class ConnRec {
  id: string = '';
  name: string = '';
  remark: string = '';
  type: string = 'ssh';
  host: string = '';
  port: number = 22;
  user: string = '';
  authType: string = 'password';
  /** M3 relay-2: referenced identity id when authType === 'identity'. */
  identityId: string = '';
  password: string = '';
  keyPath: string = '';
  keyContent: string = '';
  groupId: string | null = null;
  encoding: string = 'utf-8';
  backspaceKey: string = 'del';
  /** M3-3a: keepalive interval seconds (<=0 disables; default 30). */
  keepaliveSec: number = 30;
  /** M3-3a: user-pinned favorite. */
  favorite: boolean = false;
  /** M3-3a: epoch ms of the last successful connect (recents ordering). */
  lastUsedAt: number = 0;
  initialCols: number = 0;
  initialRows: number = 0;
  postLoginScript: string = '';
  logOnConnect: boolean = false;
  tunnelSSHConnId: string = '';
  proxyId: string = '';
  /** M3: true when an enc:v1 field could not be decrypted (wrong master password). */
  undecryptable: boolean = false;
  /** M5 parity: initial shell command (e.g. '/bin/sh' for telnet). */
  initialShell: string = '';
}

/** Parsed store file. */
class StoreData {
  groups: Array<GroupRec> = [];
  connections: Array<ConnRec> = [];
}

const GROUP_FIELDS: string[] = ['id', 'name', 'parentId'];
const CONN_FIELDS: string[] = ['id', 'name', 'remark', 'type', 'host', 'port', 'user', 'authType',
  'identityId', 'password', 'keyPath', 'keyContent', 'groupId', 'encoding', 'backspaceKey',
  'keepaliveSec', 'favorite', 'lastUsedAt',
  'initialCols', 'initialRows', 'postLoginScript', 'logOnConnect',
  'tunnelSSHConnId', 'proxyId', 'initialShell'];

function toStr(v: Object | undefined, d: string): string {
  const s = v as string;
  if (typeof s === 'string') {
    return s;
  }
  return d;
}

function toNum(v: Object | undefined, d: number): number {
  const n = v as number;
  if (typeof n === 'number') {
    return n;
  }
  return d;
}

function toBool(v: Object | undefined, d: boolean): boolean {
  const b = v as boolean;
  if (typeof b === 'boolean') {
    return b;
  }
  return d;
}

function randId(prefix: string): string {
  let s: string = '';
  const seed: string = 'abcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 8; i++) {
    const k = Math.floor(Math.random() * seed.length);
    s += seed[k];
  }
  return prefix + s;
}

/**
 * Persistent connection store. Owns files/connections.json in the app sandbox.
 * All mutations go through load-once + modify + save (whole-file rewrite).
 */
/** M3: process-wide shared instance (TerminalPage reads decrypted hosts from it). */
let gSharedStore: ConnectionStore | null = null;

export function setSharedStore(s: ConnectionStore): void {
  gSharedStore = s;
}

export function getSharedStore(): ConnectionStore | null {
  return gSharedStore;
}

export class ConnectionStore {
  private dir: string;
  private path: string;
  groups: Array<GroupRec> = [];
  connections: Array<ConnRec> = [];
  loadCount: number = 0;
  saveCount: number = 0;

  private credMgr: CredentialManager | null = null;

  constructor(filesDir: string, credMgr?: CredentialManager) {
    this.dir = filesDir;
    this.path = filesDir + '/' + STORE_FILE;
    if (credMgr !== undefined) {
      this.credMgr = credMgr;
    }
  }

  /** M3: attach or replace the credential manager (after unlock). */
  setCredManager(m: CredentialManager | null): void {
    this.credMgr = m;
  }

  /**
   * M3: seal sensitive fields (password = password auth secret OR the key
   * passphrase for keyText/key, upstream parseAuthKeySigner keeps the
   * passphrase in Password; keyContent = inline PEM). Called from save()
   * before serialization. Async because PBKDF2/GCM are async APIs.
   * Returns the list of fields sealed this round (for the hilog proof).
   */
  async sealSecrets(): Promise<number> {
    const m = this.credMgr;
    if (m === null || !m.isUnlocked()) {
      return 0; // no master password / locked: fields stay as-is in memory
    }
    let n = 0;
    for (let i = 0; i < this.connections.length; i++) {
      const c = this.connections[i];
      if (c.password.length > 0 && !isEncrypted(c.password)) {
        c.password = await m.seal(c.password);
        n++;
      }
      if (c.keyContent.length > 0 && !isEncrypted(c.keyContent)) {
        c.keyContent = await m.seal(c.keyContent);
        n++;
      }
    }
    hilog.info(DOMAIN, TAG, 'sealSecrets sealed=%{public}d conns=%{public}d', n, this.connections.length);
    return n;
  }

  /**
   * M3: decrypt sensitive fields into memory. Called from load(). Fields
   * that fail to decrypt (wrong master password) are marked with a sentinel
   * prefix so the UI can badge them; the raw ciphertext stays on disk.
   * Returns the count of fields that FAILED to decrypt.
   */
  async revealSecrets(): Promise<number> {
    const m = this.credMgr;
    if (m === null) {
      return 0; // no encryption configured: plaintext file
    }
    let fails = 0;
    for (let i = 0; i < this.connections.length; i++) {
      const c = this.connections[i];
      if (isEncrypted(c.password)) {
        try {
          c.password = await m.open(c.password);
        } catch (e) {
          c.password = '';
          c.undecryptable = true;
          fails++;
        }
      }
      if (isEncrypted(c.keyContent)) {
        try {
          c.keyContent = await m.open(c.keyContent);
        } catch (e) {
          c.keyContent = '';
          c.undecryptable = true;
          fails++;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'revealSecrets fail=%{public}d conns=%{public}d', fails, this.connections.length);
    return fails;
  }

  get filePath(): string {
    return this.path;
  }

  /** Load from disk. Missing file => empty store (upstream Load behavior). */
  load(): Promise<void> {
    this.loadSyncInner();
    return Promise.resolve();
  }

  loadSyncInner(): void {
    let raw: string = '';
    try {
      if (!fileIo.accessSync(this.path)) {
        this.groups = [];
        this.connections = [];
        this.loadCount++;
        hilog.info(DOMAIN, TAG, 'load #%{public}d file-missing path=%{public}s', this.loadCount, this.path);
        return;
      }
      raw = fileIo.readTextSync(this.path, { encoding: 'utf-8' });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'load read-fail %{public}s', JSON.stringify(e));
      this.groups = [];
      this.connections = [];
      return;
    }
    const data = this.parse(raw);
    this.groups = data.groups;
    this.connections = data.connections;
    this.loadCount++;
    hilog.info(DOMAIN, TAG, 'load #%{public}d ok groups=%{public}d conns=%{public}d',
      this.loadCount, this.groups.length, this.connections.length);
  }

  /** Parse JSON text into typed records (defensive against shape drift). */
  private parse(text: string): StoreData {
    const out = new StoreData();
    let parsed: Object = JSON.parse(text);
    if (typeof parsed !== 'object' || parsed === null || parsed === undefined) {
      return out;
    }
    const root = parsed as Record<string, Object>;
    const gs = root['groups'];
    if (gs !== undefined && gs !== null) {
      const arr = gs as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const g = new GroupRec();
        const r = arr[i] as Record<string, Object>;
        g.id = toStr(r['id'], '');
        g.name = toStr(r['name'], '');
        const pid = r['parentId'];
        g.parentId = (typeof (pid as string) === 'string') ? pid as string : null;
        if (g.id.length > 0) {
          out.groups.push(g);
        }
      }
    }
    const cs = root['connections'];
    if (cs !== undefined && cs !== null) {
      const arr = cs as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const r = arr[i] as Record<string, Object>;
        const c = new ConnRec();
        c.id = toStr(r['id'], '');
        if (c.id.length === 0) {
          continue;
        }
        c.name = toStr(r['name'], c.id);
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
        c.groupId = (typeof (gid as string) === 'string') ? gid as string : null;
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
        c.initialShell = toStr(r['initialShell'], '');
        out.connections.push(c);
      }
    }
    return out;
  }

  /**
   * Serialize + atomic write (tmp file + rename).
   * Unknown fields present in the on-disk JSON are preserved by re-parsing
   * the current file and rebuilding each record object around them.
   */
  async saveEnc(): Promise<string> {
    await this.sealSecrets();
    return this.save();
  }

  save(): string {
    let rawGroups: Array<Record<string, Object>> = [];
    let rawConns: Array<Record<string, Object>> = [];
    let haveRaw = false;
    try {
      if (fileIo.accessSync(this.path)) {
        const prev = JSON.parse(fileIo.readTextSync(this.path, { encoding: 'utf-8' })) as Record<string, Object>;
        const gs = prev['groups'];
        if (gs !== undefined && gs !== null) {
          rawGroups = gs as Array<Record<string, Object>>;
        }
        const cs = prev['connections'];
        if (cs !== undefined && cs !== null) {
          rawConns = cs as Array<Record<string, Object>>;
        }
        haveRaw = true;
      }
    } catch (e) {
      haveRaw = false; // corrupt or unreadable previous file -> clean rewrite
    }

    const gArr: Array<Record<string, Object>> = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g = this.groups[i];
      let base: Record<string, Object> = {};
      if (haveRaw) {
        base = this.findRawById(rawGroups, g.id);
      }
      const obj: Record<string, Object> = {};
      obj['id'] = g.id;
      obj['name'] = g.name;
      if (g.parentId !== null) {
        obj['parentId'] = g.parentId;
      }
      this.copyUnknown(base, obj, GROUP_FIELDS);
      gArr.push(obj);
    }

    const cArr: Array<Record<string, Object>> = [];
    for (let i = 0; i < this.connections.length; i++) {
      const c = this.connections[i];
      let base: Record<string, Object> = {};
      if (haveRaw) {
        base = this.findRawById(rawConns, c.id);
      }
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
      if (c.keepaliveSec !== 30) {
        obj['keepaliveSec'] = c.keepaliveSec;
      }
      if (c.favorite) {
        obj['favorite'] = c.favorite;
      }
      if (c.lastUsedAt > 0) {
        obj['lastUsedAt'] = c.lastUsedAt;
      }
      if (c.initialCols !== 0) {
        obj['initialCols'] = c.initialCols;
      }
      if (c.initialRows !== 0) {
        obj['initialRows'] = c.initialRows;
      }
      if (c.postLoginScript.length > 0) {
        obj['postLoginScript'] = c.postLoginScript;
      }
      obj['logOnConnect'] = c.logOnConnect;
      if (c.tunnelSSHConnId.length > 0) {
        obj['tunnelSSHConnId'] = c.tunnelSSHConnId;
      }
      if (c.initialShell.length > 0) {
        obj['initialShell'] = c.initialShell;
      }
      if (c.proxyId.length > 0) {
        obj['proxyId'] = c.proxyId;
      }
      this.copyUnknown(base, obj, CONN_FIELDS);
      cArr.push(obj);
    }

    const root: Record<string, Object> = {};
    root['groups'] = gArr as Object;
    root['connections'] = cArr as Object;
    const json: string = JSON.stringify(root, null, 2);

    const tmp = this.path + '.tmp';
    const file = fileIo.openSync(tmp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save write-fail %{public}s', JSON.stringify(e));
      return '';
    }
    try {
      fileIo.renameSync(tmp, this.path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save rename-fail %{public}s', JSON.stringify(e));
      return '';
    }
    this.saveCount++;
    hilog.info(DOMAIN, TAG, 'save #%{public}d ok groups=%{public}d conns=%{public}d bytes=%{public}d',
      this.saveCount, gArr.length, cArr.length, json.length);
    return json;
  }

  private findRawById(arr: Array<Record<string, Object>>, id: string): Record<string, Object> {
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i];
      const rid = r['id'];
      if (typeof (rid as string) === 'string' && rid as string === id) {
        return r;
      }
    }
    const empty: Record<string, Object> = {};
    return empty;
  }

  /** Copy keys not in `known` from `src` into `dst`. */
  private copyUnknown(src: Record<string, Object>, dst: Record<string, Object>, known: string[]): void {
    const ks = Object.keys(src);
    for (let i = 0; i < ks.length; i++) {
      const k = ks[i];
      let isKnown = false;
      for (let f = 0; f < known.length; f++) {
        if (known[f] === k) {
          isKnown = true;
          break;
        }
      }
      if (!isKnown) {
        dst[k] = src[k];
      }
    }
  }

  // ---- CRUD helpers ----

  addGroup(name: string): GroupRec {
    const g = new GroupRec();
    g.id = randId('g-');
    g.name = name;
    g.parentId = null;
    this.groups.push(g);
    return g;
  }

  /** M4 relay-3: upsert a group by id - same id => update in place
   * (name/parentId), new id => append. Idempotent against repeated
   * imports of the same payload. */
  upsertGroup(g: GroupRec): void {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === g.id) {
        this.groups[i] = g;
        return;
      }
    }
    this.groups.push(g);
  }

  renameGroup(id: string, name: string): boolean {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === id) {
        this.groups[i].name = name;
        return true;
      }
    }
    return false;
  }

  /** Delete a group; member connections move to root (groupId null). */
  deleteGroup(id: string): boolean {
    let found = false;
    const ng: Array<GroupRec> = [];
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === id) {
        found = true;
      } else {
        ng.push(this.groups[i]);
      }
    }
    if (!found) {
      return false;
    }
    this.groups = ng;
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].groupId === id) {
        this.connections[i].groupId = null;
      }
    }
    return true;
  }

  upsertConn(c: ConnRec): void {
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === c.id) {
        this.connections[i] = c;
        return;
      }
    }
    this.connections.push(c);
  }

  deleteConn(id: string): boolean {
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === id) {
        this.connections.splice(i, 1);
        return true;
      }
    }
    return false;
  }

  /** M3-3a: stamp lastUsedAt=now on a connection (recents ordering) + persist. */
  markUsed(id: string): void {
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === id) {
        this.connections[i].lastUsedAt = Date.now();
        this.save();
        return;
      }
    }
  }

  /** M3-3a: flip the favorite pin + persist. Returns the new state. */
  toggleFavorite(id: string): boolean {
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === id) {
        this.connections[i].favorite = !this.connections[i].favorite;
        this.save();
        return this.connections[i].favorite;
      }
    }
    return false;
  }

  /** M3-3a: most recently used connections (lastUsedAt desc), max n. */
  recents(n: number): ConnRec[] {
    const list: ConnRec[] = [];
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].lastUsedAt > 0) {
        list.push(this.connections[i]);
      }
    }
    list.sort((a: ConnRec, b: ConnRec): number => b.lastUsedAt - a.lastUsedAt);
    return list.slice(0, n);
  }

  /** M3-3a: favorite connections (definition order). */
  favorites(): ConnRec[] {
    const list: ConnRec[] = [];
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].favorite) {
        list.push(this.connections[i]);
      }
    }
    return list;
  }
}
