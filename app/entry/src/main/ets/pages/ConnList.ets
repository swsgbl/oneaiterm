/**
 * upstream M1b - Connection list page with group sections.
 * Sections: each group (in store order), then root-level connections.
 * Rows: name / host:user:port / type. Edit + delete per row.
 * Owns the ConnectionStore: save() after every mutation (immediate persist).
 */
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { WantParams } from '../common/WantParams';
import { router } from '@kit.ArkUI';
import { ConnectionStore, ConnRec, GroupRec, setSharedStore } from '../store/ConnStore';
import { ConnForm } from '../components/ConnForm';
import { TestConn } from '../components/TestConn';
import { parseImport, parseImportEnc, ImportResult, ImportError } from '../store/ConnImporter';
import { CredentialManager, CredError } from '../store/CredentialManager';
import { isEncrypted } from '../store/EncCrypto';
import { exportUtm } from '../store/UtmExport';
import { IdentityStore, IdentityRec } from '../store/IdentityStore';
import { SessionService } from '../service/SessionService';
import { IdentityManager } from '../components/IdentityManager';
import { AppTheme, themeByName } from '../common/AppTheme';

const EDITABLE_TYPES_SET: string[] = ['ssh'];

function decodeUtf8(buf: ArrayBuffer): string {
  const td = util.TextDecoder.create('utf-8');
  return td.decodeWithStream(new Uint8Array(buf));
}

// Developer import shim: /data/local/tmp is outside the app sandbox, so
// direct fileIo reads are denied by DAC. Fallback chain:
//   1) try the direct read anyway (rooted/dev builds may allow it);
//   2) pull the file through the app sandbox temp dir via hdc-side copy
//      (hdc file send targets the same sandbox, so automation pushes the
//      sample there as well);
//   3) give up -> caller shows the "not found" toast.
const DEV_FALLBACK_DIRS: string[] = [''];  // filled at runtime below

function readDevFile(path: string): string | null {
  try {
    const t = fileIo.readTextSync(path, { encoding: 'utf-8' });
    hilog.warn(IDOMAIN, ITAG, 'devimport direct read OK len=%{public}d', t.length);
    return t;
  } catch (e) {
    hilog.warn(IDOMAIN, ITAG, 'devimport direct read FAIL %{public}s', JSON.stringify(e));
  }
  const name = path.substring(path.lastIndexOf('/') + 1);
  try {
    const t = fileIo.readTextSync(gSandboxTmp + '/' + name, { encoding: 'utf-8' });
    hilog.warn(IDOMAIN, ITAG, 'devimport tmp read OK len=%{public}d', t.length);
    return t;
  } catch (e) {
    hilog.warn(IDOMAIN, ITAG, 'devimport tmp read FAIL %{public}s', JSON.stringify(e));
  }
  try {
    const t = fileIo.readTextSync(gSandboxFiles + '/' + name, { encoding: 'utf-8' });
    hilog.warn(IDOMAIN, ITAG, 'devimport files read OK len=%{public}d', t.length);
    return t;
  } catch (e) {
    hilog.warn(IDOMAIN, ITAG, 'devimport files read FAIL %{public}s', JSON.stringify(e));
    return null;
  }
}

let gSandboxFiles: string = '';
let gSandboxTmp: string = '';
function getContextSandboxTmp(): string {
  return gSandboxTmp;
}

const ITAG: string = 'oat.import';
const IDOMAIN: number = 0x0110;
const DEV_IMPORT_PATH: string = '/data/local/tmp/import-test.utm';

@Component
export struct ConnList {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  onOpenConn: (id: string) => void = (id: string) => {
  };
  @State groups: GroupRec[] = [];
  @State conns: ConnRec[] = [];
  @State formVisible: boolean = false;
  @State editing: ConnRec | null = null;
  @State testing: ConnRec | null = null;
  @State testVisible: boolean = false;
  @State rowActionConn: ConnRec | null = null;
  @State rowActionVisible: boolean = false;
  @State groupDialogMode: number = 0; // 0 none, 1 add, 2 rename
  @State groupName: string = '';
  @State renamingId: string = '';
  @State toast: string = '';
  @State cred: CredentialManager | null = null;
  /** M3: connections parsed from the launch want, upserted after load(). */
  private pendingImport: ConnRec[] = [];
  /** M4 relay-2 (fix A): groups parsed from the plaintext want-import, pushed after load(). */
  private pendingImportGroups: GroupRec[] = [];
  @State hasMaster: boolean = false;
  @State unlocked: boolean = false;
  @State credDialog: number = 0; // 0 none 1 setup 2 unlock
  @State credPass1: string = '';
  @State credPass2: string = '';
  @State credErr: string = '';
  /** M3 relay-2: export + encrypted import + identities UI state. */
  @State identities: IdentityRec[] = [];
  @State identVisible: boolean = false;
  @State impDialog: boolean = false;
  @State impText: string = '';
  @State impPassword: string = '';
  @State impErr: string = '';
  @State exportDialog: boolean = false;
  @State exportPassword: string = '';
  @State exportErr: string = '';
  private identStore: IdentityStore | null = null;
  private impPendingText: string = '';
  /** M3 relay-2: in-flight encrypted want import (awaited before store fold-in). */
  private encImportPromise: Promise<ImportResult | null> = Promise.resolve(null);
  private encImportGroups: GroupRec[] = [];
  store: ConnectionStore = new ConnectionStore('');
  onNeedStore: () => ConnectionStore = () => {
    return new ConnectionStore('');
  };

  async aboutToAppear(): Promise<void> {
    this.store = this.onNeedStore();
    setSharedStore(this.store);
    let filesDir = '';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      filesDir = ctx.filesDir;
    } catch (e) {
      filesDir = '';
    }
    if (filesDir.length > 0) {
      this.cred = new CredentialManager(filesDir);
      this.store.setCredManager(this.cred);
      this.identStore = new IdentityStore(filesDir, this.cred);
      this.identStore.loadSync();
      await this.identStore.revealSecrets();
      SessionService.setIdentities(this.identStore);
      this.identities = this.identStore.identities.slice();
      this.hasMaster = this.cred.hasMasterPassword();
      this.unlocked = this.cred.isUnlocked();
      hilog.info(IDOMAIN, ITAG, 'credmgr hasMaster=%{public}d unlocked=%{public}d',
        this.hasMaster ? 1 : 0, this.unlocked ? 1 : 0);
    }
    // M3: auto-consume the launch-want import (E2E channel) so imported
    // hosts appear without pressing the developer-import button.
    const wantText0 = WantParams.getImportText();
    if (wantText0.length > 0) {
      try {
        const res0 = parseImport(wantText0);
        this.pendingImport = res0.connections;
        this.pendingImportGroups = res0.groups; // M4 relay-2 fix A
        hilog.info(IDOMAIN, ITAG, 'want autoimport conns=%{public}d groups=%{public}d',
          res0.connections.length, res0.groups.length);
      } catch (e) {
        hilog.warn(IDOMAIN, ITAG, 'want autoimport parse fail');
      }
    }
    // M3 relay-2: encrypted .utm via want (importEncText + importEncPass).
    const encText0 = WantParams.getImportEncText();
    const encPass0 = WantParams.getImportEncPass();
    const encImport: Promise<ImportResult | null> =
      (encText0.length > 0) ? parseImportEnc(encText0, encPass0) : Promise.resolve(null);
    this.encImportPromise = encImport;
    this.encImportGroups = [];
    // M3 dev channel: credSetup/credUnlock via launch want (E2E without IME).
    const credSetup0 = WantParams.getCredSetup();
    const credUnlock0 = WantParams.getCredUnlock();
    // M3 relay-2d: identity bootstrap via want (password fields would double-
    // write under uitest IME; PEM TextArea is safe but one channel covers all).
    const identParams0 = WantParams.getIdentityParams();
    // r2d: exportPass snapshot + single consume point (all readers above ran).
    const expPassSnap = WantParams.getExportPass();
    // M3-3a: connectNow snapshot (must be read before the consume below)
    const connNowSnap = WantParams.getConnectNow();
    WantParams.setWant({} as Want); // consume once
    this.store.load().then(async (): Promise<void> => {
      // M3 relay-2: wait for the encrypted want import (race fix: parse is
      // async and load() used to resolve first, losing the result).
      try {
        const encRes = await this.encImportPromise;
        if (encRes !== null) {
          this.encImportGroups = encRes.groups;
          this.pendingImport = this.pendingImport.concat(encRes.connections);
          hilog.info(IDOMAIN, ITAG, 'want enc autoimport merged=%{public}d', encRes.connections.length);
        }
      } catch (e0) {
        hilog.error(IDOMAIN, ITAG, 'want enc autoimport FAIL %{public}s',
          e0 instanceof ImportError ? e0.message : JSON.stringify(e0));
      }
      // M3: fold in want-imported connections now that the store is loaded.
      // M4 relay-2 (fix A): fold in the PLAINTEXT want-import groups so
      // connections.json persists groups (previously only encImportGroups was
      // pushed, leaving groups=0 for plaintext .utm imports).
      for (let pgi = 0; pgi < this.pendingImportGroups.length; pgi++) {
        this.store.upsertGroup(this.pendingImportGroups[pgi]); // M4 relay-3: dedup by id
      }
      if (this.pendingImportGroups.length > 0) {
        hilog.info(IDOMAIN, ITAG, 'want plat groups pushed=%{public}d', this.pendingImportGroups.length);
      }
      this.pendingImportGroups = [];
      if (this.encImportGroups.length > 0) {
        for (let gi = 0; gi < this.encImportGroups.length; gi++) {
          this.store.upsertGroup(this.encImportGroups[gi]); // M4 relay-3: dedup by id
        }
        hilog.info(IDOMAIN, ITAG, 'want enc groups pushed=%{public}d', this.encImportGroups.length);
      }
      if (this.pendingImport.length > 0) {
        for (let pi = 0; pi < this.pendingImport.length; pi++) {
          this.store.upsertConn(this.pendingImport[pi]);
        }
        hilog.info(IDOMAIN, ITAG, 'want autoimport upserted=%{public}d', this.pendingImport.length);
        this.pendingImport = [];
        this.store.save();
      }
      // M3-3a dev channel: --ps connectNow <name> - jump straight to terminal
      const connNow = connNowSnap;
      if (connNow.length > 0) {
        const hit = this.store.connections.find((c: ConnRec) => c.name === connNow);
        if (hit !== undefined) {
          WantParams.setWant({} as Want);
          hilog.info(IDOMAIN, ITAG, 'connectNow -> %{public}s', connNow);
          this.onOpenConn(hit.id);
          return;
        }
      }
      const fails = await this.store.revealSecrets();
      if (fails > 0) {
        this.showToast('有 ' + fails + ' 个凭据字段无法解密(主密码未解锁或错误)');
      }
      // M3 relay-2 dev channel: auto-export once data is folded in
      // (exportPass="-" means plaintext; any other value is the password).
      const expPass0 = expPassSnap;
      if (expPass0 === '-') {
        WantParams.setWant({} as Want);
        this.exportPassword = '';
        this.doExport();
      } else if (expPass0.length > 0) {
        WantParams.setWant({} as Want);
        this.exportPassword = expPass0;
        this.doExport();
      }
            // M3 dev channel execution after unlock object exists
      if (credSetup0.length > 0 && this.cred !== null && !this.cred.hasMasterPassword()) {
        try {
          await this.cred.setupMasterPassword(credSetup0);
          this.hasMaster = true;
          this.unlocked = true;
          hilog.info(IDOMAIN, ITAG, 'credSetup via want OK');
          this.showToast('主密码已设置(want 通道)');
        } catch (e) {
          hilog.error(IDOMAIN, ITAG, 'credSetup via want FAIL %{public}s %{public}s', (e as Error).name, (e as Error).message);
        }
      }
      if (credUnlock0.length > 0 && this.cred !== null && this.cred.hasMasterPassword()) {
        try {
          await this.cred.unlock(credUnlock0);
          this.unlocked = true;
          // reload + reveal AFTER unlocking (the earlier load ran while locked)
          this.store.load();
          await this.store.revealSecrets();
          if (this.identStore !== null) {
            this.identStore.loadSync();
            await this.identStore.revealSecrets();
            this.identities = this.identStore.identities.slice();
          }
          this.sync();
          hilog.info(IDOMAIN, ITAG, 'credUnlock via want OK');
          this.showToast('已解锁(want 通道)');
        } catch (e) {
          hilog.error(IDOMAIN, ITAG, 'credUnlock via want FAIL %{public}s', JSON.stringify(e));
        }
      }
      // M3 relay-2d: apply want-injected identities (create or update by id),
      // seal+persist, then RELOAD+REVEAL so in-memory records hold plaintext
      // (materialize() reads memory; sealed leftovers would break connects).
      if (identParams0.length > 0) {
        this.applyIdentityParams(identParams0);
      }
      this.sync();
    }).catch(() => {});

    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      gSandboxTmp = ctx.tempDir;
      gSandboxFiles = ctx.filesDir;
    } catch (e) {
      gSandboxTmp = '';
      gSandboxFiles = '';
    }
    this.sync();
  }

  private sync(): void {
    this.groups = this.store.groups.slice();
    this.conns = this.store.connections.slice();
  }

  /** M3 relay-2: persist the identity store (sealing when unlocked) + refresh.
   * relay-2d fix: after seal+save, reload from disk and reveal again so the
   * IN-MEMORY records keep plaintext secrets - SessionService.materialize()
   * reads memory and sealed leftovers broke identity connects. */
  private refreshIdentities(): void {
    if (this.identStore === null) {
      return;
    }
    this.identStore.sealAndSave().then(async (j: string) => {
      hilog.info(IDOMAIN, ITAG, 'identities saved ok=%{public}d', j.length > 0 ? 1 : 0);
      this.identStore!.loadSync();
      await this.identStore!.revealSecrets();
      this.identities = this.identStore!.identities.slice();
    }).catch((e: Object) => {
      hilog.error(IDOMAIN, ITAG, 'identities save fail %{public}s', JSON.stringify(e));
    });
    this.identities = this.identStore.identities.slice();
  }

  /** M3 relay-2: write the edited identity list into the store + persist. */
  private saveIdentities(changed: IdentityRec[]): void {
    if (this.identStore === null) {
      return;
    }
    this.identStore.identities = changed;
    this.refreshIdentities();
  }

  /** M3 relay-2: does the identity id still exist (missing badge source). */
  private identityExists(id: string): boolean {
    for (let i = 0; i < this.identities.length; i++) {
      if (this.identities[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** M3 relay-2d: apply want-injected identities (array of IdentityRec JSON,
   * matched by id => create or update), then seal+persist + reload/reveal. */
  private async applyIdentityParams(text: string): Promise<void> {
    if (this.identStore === null) {
      hilog.error(IDOMAIN, ITAG, 'identityParams skip: no identStore');
      return;
    }
    let arr: Array<Object>;
    try {
      arr = JSON.parse(text) as Array<Object>;
    } catch (e) {
      hilog.error(IDOMAIN, ITAG, 'identityParams parse fail');
      return;
    }
    let created = 0;
    let updated = 0;
    for (let i = 0; i < arr.length; i++) {
      const r = arr[i] as Record<string, Object>;
      const rec = new IdentityRec();
      rec.id = toIdentStr(r['id'], '');
      rec.name = toIdentStr(r['name'], rec.id);
      rec.username = toIdentStr(r['username'], '');
      rec.authType = toIdentStr(r['authType'], 'password');
      rec.password = toIdentStr(r['password'], '');
      rec.keyPath = toIdentStr(r['keyPath'], '');
      rec.keyContent = toIdentStr(r['keyContent'], '');
      if (rec.id.length === 0) {
        continue;
      }
      const prev = this.identStore.get(rec.id);
      if (prev !== null && isEncrypted(prev.password)) {
        rec.password = prev.password; // keep disk ciphertext, revealed below
      }
      if (prev !== null && isEncrypted(prev.keyContent)) {
        rec.keyContent = prev.keyContent;
      }
      const existed = prev !== null;
      this.identStore.upsert(rec);
      if (existed) {
        updated++;
      } else {
        created++;
      }
    }
    hilog.info(IDOMAIN, ITAG, 'identityParams applied created=%{public}d updated=%{public}d total=%{public}d',
      created, updated, this.identStore.identities.length);
    this.refreshIdentities(); // seal + save + reload + reveal (memory plaintext)
  }

  private persist(): void {
    if (this.cred !== null && this.cred.isUnlocked()) {
      this.store.saveEnc().then((j: string) => {
        if (j.length === 0) {
          hilog.error(IDOMAIN, ITAG, 'saveEnc failed');
        } else {
          hilog.info(IDOMAIN, ITAG, 'saveEnc ok');
        }
      });
    } else {
      this.store.save();
    }
    this.sync();
  }

  private showToast(msg: string): void {
    this.toast = msg;
  }

  private connsOf(gid: string | null): ConnRec[] {
    const out: ConnRec[] = [];
    for (let i = 0; i < this.conns.length; i++) {
      const c = this.conns[i];
      if (gid === null) {
        if (c.groupId === null) {
          out.push(c);
        }
      } else if (c.groupId === gid) {
        out.push(c);
      }
    }
    return out;
  }

  private hostLine(c: ConnRec): string {
    return (c.user.length > 0 ? c.user + '@' : '') + c.host + ':' + c.port;
  }

  private beginAdd(): void {
    this.editing = null;
    this.formVisible = true;
  }

  private beginEdit(c: ConnRec): void {
    this.editing = c;
    this.formVisible = true;
  }

  private onFormSaved(c: ConnRec): void {
    this.store.upsertConn(c);
    this.persist();
    this.showToast('已保存 ' + c.name);
  }

  private doDeleteConn(c: ConnRec): void {
    this.store.deleteConn(c.id);
    this.persist();
    this.showToast('已删除 ' + c.name);
  }

  // ---- import ----

  /** Entry 1: system file picker (DocumentViewPicker). */
  private pickAndImport(): void {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this));
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['upstream|.utm,.json'];
      docPicker.select(opts).then((uris: Array<string>) => {
        if (uris === undefined || uris === null || uris.length === 0) {
          this.showToast('未选择文件');
          return;
        }
        this.importFromUri(uris[0]);
      }).catch((e: Object) => {
        this.showToast('选择文件失败: ' + JSON.stringify(e));
      });
    } catch (e) {
      this.showToast('打开选择器失败: ' + JSON.stringify(e));
    }
  }

  private importFromUri(uri: string): void {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let text = '';
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        // ArrayBuffer -> string (utf-8): decode via util.TextDecoder
        text = decodeUtf8(buf);
      } finally {
        fileIo.closeSync(file);
      }
      // M3 relay-2: encrypted .utm => password dialog first (needs the file
      // text to decide, kept in impPendingText).
      if (this.isEncryptedUtm(text)) {
        this.impPendingText = text;
        this.impPassword = '';
        this.impErr = '';
        this.impDialog = true;
        return;
      }
      this.applyImportText(text, '');
    } catch (e) {
      this.showToast('读取文件失败: ' + JSON.stringify(e));
    }
  }

  /** Quick sniff: .utm with encrypted:true (no full parse). */
  private isEncryptedUtm(text: string): boolean {
    try {
      const o = JSON.parse(text) as Record<string, Object>;
      if (o['format'] === undefined) {
        return false; // connections.json: enc:v1 fields rejected by parseImport
      }
      const enc = o['encrypted'] as boolean;
      return enc === true;
    } catch (e) {
      return false;
    }
  }

  /** M3 relay-2: parse (+ optional password decrypt) and merge into the store. */
  private applyImportText(text: string, password: string): void {
    parseImportEnc(text, password).then((res: ImportResult) => {
      this.mergeImport(res);
    }).catch((e: Object) => {
      const em = e instanceof ImportError ? e.message : JSON.stringify(e);
      this.showToast('导入失败: ' + em);
      if (this.impDialog) {
        this.impErr = em; // keep dialog open for retry with corrected password
      }
    });
  }

  private mergeImport(res: ImportResult): void {
    // M4 relay-3: groups deduped by id (same id => update in place);
    // connections keep upstream semantics (upsertConn by fresh id per import).
    for (let i = 0; i < res.groups.length; i++) {
      this.store.upsertGroup(res.groups[i]);
    }
    for (let i = 0; i < res.connections.length; i++) {
      this.store.upsertConn(res.connections[i]);
    }
    this.persist();
    let msg = '导入完成: +' + res.groups.length.toString() + ' 组 +' + res.connections.length.toString() + ' 主机';
    if (res.unsupported.length > 0) {
      msg += '(暂不支持连接: ' + res.unsupported.join(',') + ')';
    }
    this.impDialog = false;
    this.showToast(msg);
    hilog.info(IDOMAIN, ITAG, 'imported groups=%{public}d conns=%{public}d unsupported=%{public}d',
      res.groups.length, res.connections.length, res.unsupported.length);
  }

  /** Entry 2: developer import - /data/local/tmp/import-test.utm|json. */
  /** Entry 2: developer import - /data/local/tmp/import-test.utm|json.
   * hdc file send pushes the sample to /data/local/tmp (world-readable);
   * the app cannot read that path directly (DAC), so we first try the
   * direct read, then the sandbox temp/cache copies created by
   * `hdc app install -r` + shell cp as root workaround. */
  private devImport(): void {
    // Channel 1 (preferred on device): launch want parameter.
    //   hdc shell aa start -b com.oneaiterm.terminal -a EntryAbility
    //     --ps importText "$(cat /data/local/tmp/import-test.utm)"
    const wantText = WantParams.getImportText();
    if (wantText.length > 0) {
      WantParams.setWant({} as Want); // consume once
      this.applyImport(wantText);
      return;
    }
    // Channel 2: direct path reads (work on rooted/dev images where the
    // app sandbox permits /data/local/tmp; on stock emulator they return
    // ENOENT because fileIo is sandbox-scoped).
    const candidates: string[] = ['/data/local/tmp/import-test.utm', '/data/local/tmp/import-test.json'];
    for (let i = 0; i < candidates.length; i++) {
      const text = readDevFile(candidates[i]);
      if (text !== null) {
        this.applyImport(text);
        return;
      }
    }
    this.showToast('未找到导入源(需 aa start --ps importText 或 /data/local/tmp 可读)');
  }

  private applyImport(text: string): void {
    // M3 relay-2: dev channel may hand an encrypted .utm; route through the
    // password dialog in that case.
    if (this.isEncryptedUtm(text)) {
      this.impPendingText = text;
      this.impPassword = '';
      this.impErr = '';
      this.impDialog = true;
      return;
    }
    this.applyImportText(text, '');
  }

  /** M3 relay-2: export the current store to filesDir/export.utm (+encryption). */
  private doExport(): void {
    const groups = this.store.groups.slice();
    const conns = this.store.connections.slice();
    exportUtm(groups, conns, this.exportPassword).then((json: string) => {
      if (this.identStore === null) {
        this.exportErr = '内部错误: 无 filesDir';
        return;
      }
      const dest = (getContext(this) as common.UIAbilityContext).filesDir + '/export.utm';
      try {
        const f = fileIo.openSync(dest,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, json);
        fileIo.closeSync(f);
      } catch (e) {
        this.exportErr = '写入失败: ' + JSON.stringify(e);
        return;
      }
      this.exportDialog = false;
      this.showToast('已导出 ' + conns.length + ' 主机 -> ' + dest +
        (this.exportPassword.length > 0 ? ' (加密)' : ' (明文)'));
      hilog.info(IDOMAIN, ITAG, 'exported conns=%{public}d enc=%{public}d bytes=%{public}d path=%{public}s',
        conns.length, this.exportPassword.length > 0 ? 1 : 0, json.length, dest);
      // relay-2 interop channel: hdc shell cannot see the app sandbox, so the
      // export payload itself is mirrored to hilog in UTMB64 chunks (rebuilt
      // host-side into a real .utm for the Go parser cross-check).
      const helper = new util.Base64Helper();
      const b64 = helper.encodeToStringSync(stringToBytes(json), util.Type.BASIC);
      for (let ci = 0; ci < b64.length; ci += 3000) {
        hilog.info(IDOMAIN, ITAG, 'UTMB64 %{public}d %{public}s', ci, b64.substring(ci, ci + 3000));
      }
    }).catch((e: Object) => {
      this.exportErr = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(IDOMAIN, ITAG, 'export fail %{public}s', JSON.stringify(e));
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // header(官方 sidebar-header 紧凑风:深色、小字号)
        Row({ space: 8 }) {
          Text('连接')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().ink)
          Blank()
          Text('+ 分组')
            .fontSize(11)
            .fontColor(this.th().inkSubtle)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(4)
            .onClick(() => {
              this.groupDialogMode = 1;
              this.groupName = '';
            })
          Text('+ 主机')
            .fontSize(11)
            .fontColor(this.th().brand)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.th().hover)
            .borderRadius(4)
            .onClick(() => {
              this.beginAdd();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 6 })

        Row({ space: 8 }) {
          Text('🔒 ' + (this.hasMaster ? (this.unlocked ? '已解锁' : '主密码未解锁') : '未设主密码'))
            .fontSize(10)
            .fontColor(this.hasMaster && this.unlocked ? this.th().success : this.th().warn)
          if (!this.hasMaster) {
            Text('设置')
              .fontSize(10).fontColor(this.th().ink)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(4).backgroundColor(this.th().hover)
              .onClick(() => {
                this.credPass1 = '';
                this.credPass2 = '';
                this.credErr = '';
                this.credDialog = 1;
              })
          } else {
            if (!this.unlocked) {
              Text('解锁')
                .fontSize(10).fontColor(this.th().ink)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(4).backgroundColor(this.th().hover)
                .onClick(() => {
                  this.credPass1 = '';
                  this.credErr = '';
                  this.credDialog = 2;
                })
            } else {
              Text('锁定')
                .fontSize(10).fontColor(this.th().inkSubtle)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(4).backgroundColor(this.th().hover)
                .onClick(() => {
                  this.cred!.lock();
                  this.unlocked = false;
                  this.store.load().then(async (): Promise<void> => {
                    await this.store.revealSecrets();
                    if (this.identStore !== null) {
                      this.identStore.loadSync();
                      await this.identStore.revealSecrets();
                      this.identities = this.identStore.identities.slice();
                    }
                    this.sync();
                  }).catch(() => {});
                  this.showToast('已锁定:凭据已从内存清除');
                })
            }
            Text('忘记主密码')
              .fontSize(10).fontColor(this.th().danger)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(4).backgroundColor('#26f87171')
              .onClick(() => {
                this.cred!.reset();
                this.hasMaster = false;
                this.unlocked = false;
                this.showToast('已重置:旧密文将永久无法解密');
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 4 })

        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
          Text('导入:')
            .fontSize(10)
            .fontColor(this.th().inkSubtle)
            .margin({ right: 6 })
          Text('选择文件(.utm/.json)')
            .fontSize(10).fontColor(this.th().inkSubtle)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(3).backgroundColor(this.th().hover)
            .margin({ right: 4 })
            .onClick(() => {
              this.pickAndImport();
            })
          Text('开发者导入')
            .fontSize(10).fontColor(this.th().inkSubtle)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(3).backgroundColor(this.th().hover)
            .margin({ right: 4 })
            .onClick(() => {
              this.devImport();
            })
          Text('导出.utm')
            .fontSize(10).fontColor(this.th().inkSubtle)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(3).backgroundColor(this.th().hover)
            .margin({ right: 4 })
            .onClick(() => {
              this.exportPassword = '';
              this.exportErr = '';
              this.exportDialog = true;
            })
          Text('身份')
            .fontSize(10).fontColor(this.th().inkSubtle)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(3).backgroundColor(this.th().hover)
            .onClick(() => {
              this.identVisible = true;
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 10 })

        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(11)
            .fontColor(this.th().success)
            .padding({ left: 12 })
            .alignSelf(ItemAlign.Start)
        }

        // list
        Scroll() {
          Column() {
            this.QuickAccess()
            ForEach(this.groups, (g: GroupRec) => {
              this.GroupSection(g)
            }, (g: GroupRec) => g.id + g.name)
            this.RootSection()
          }
          .width('100%')
          .padding({ bottom: 20 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      this.RowActionMenu()

      if (this.formVisible) {
        Column() {
          ConnForm({
            editing: this.editing,
            groups: this.groups,
            identities: this.identities,
            onClose: () => {
              this.formVisible = false;
            },
            onSaved: (c: ConnRec) => {
              this.onFormSaved(c);
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.formVisible = false;
        })
      }

      if (this.groupDialogMode > 0) {
        Column({ space: 12 }) {
          Text(this.groupDialogMode === 1 ? '新增分组' : '重命名分组')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
          TextInput({ placeholder: '分组名称', text: this.groupName })
            .onChange((v: string) => {
              this.groupName = v;
            })
          Row({ space: 12 }) {
            Button('取消')
              .backgroundColor(this.th().inkSubtle)
              .layoutWeight(1)
              .onClick(() => {
                this.groupDialogMode = 0;
              })
            Button('确定')
              .layoutWeight(1)
              .onClick(() => {
                const n = this.groupName.trim();
                if (n.length === 0) {
                  return;
                }
                if (this.groupDialogMode === 1) {
                  this.store.addGroup(n);
                  this.persist();
                  this.showToast('已建分组 ' + n);
                } else {
                  if (this.store.renameGroup(this.renamingId, n)) {
                    this.persist();
                    this.showToast('已重命名 ' + n);
                  }
                }
                this.groupDialogMode = 0;
              })
          }
          .width('100%')
        }
        .width('60%')
        .padding(18)
        .backgroundColor(this.th().surfaceRaised)
        .borderRadius(12)
        .shadow({ radius: 24, color: '#99000000', offsetX: 0, offsetY: 8 })
        .justifyContent(FlexAlign.Center)
      }

      this.CredDialog();

      // M3 relay-2: encrypted-import password dialog
      if (this.impDialog) {
        Column() {
          Column({ space: 12 }) {
            Text('加密 .utm 导入')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
            Text('该文件已加密,请输入导出时设置的密码')
              .fontSize(12)
              .fontColor(this.th().inkSubtle)
            TextInput({ placeholder: '导入密码' })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.impPassword = v;
              })
            if (this.impErr.length > 0) {
              Text(this.impErr).fontSize(13).fontColor(this.th().danger)
            }
            Row({ space: 12 }) {
              Button('取消')
                .backgroundColor(this.th().inkSubtle)
                .layoutWeight(1)
                .onClick(() => {
                  this.impDialog = false;
                })
              Button('导入')
                .layoutWeight(1)
                .onClick(() => {
                  this.impErr = '';
                  this.applyImportText(this.impPendingText, this.impPassword);
                })
            }
            .width('100%')
          }
          .width('72%')
          .padding(18)
          .backgroundColor(this.th().surfaceRaised)
          .borderRadius(12)
          .shadow({ radius: 24, color: '#99000000', offsetX: 0, offsetY: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.impDialog = false;
        })
      }

      // M3 relay-2: export dialog
      if (this.exportDialog) {
        Column() {
          Column({ space: 12 }) {
            Text('导出 .utm')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
            Text('密码留空导出明文(密码字段清空);输入密码则用 PBKDF2(100k)+AES-GCM 加密')
              .fontSize(12)
              .fontColor(this.th().inkSubtle)
            TextInput({ placeholder: '导出密码(可留空)' })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.exportPassword = v;
              })
            if (this.exportErr.length > 0) {
              Text(this.exportErr).fontSize(13).fontColor(this.th().danger)
            }
            Row({ space: 12 }) {
              Button('取消')
                .backgroundColor(this.th().inkSubtle)
                .layoutWeight(1)
                .onClick(() => {
                  this.exportDialog = false;
                })
              Button('导出')
                .layoutWeight(1)
                .onClick(() => {
                  this.doExport();
                })
            }
            .width('100%')
          }
          .width('72%')
          .padding(18)
          .backgroundColor(this.th().surfaceRaised)
          .borderRadius(12)
          .shadow({ radius: 24, color: '#99000000', offsetX: 0, offsetY: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.exportDialog = false;
        })
      }

      // M3 relay-2: identity manager overlay
      if (this.identVisible) {
        Column() {
          IdentityManager({
            identities: this.identities,
            cred: this.cred,
            onSaved: (changed: IdentityRec[]): void => {
              this.saveIdentities(changed);
            },
            onClose: () => {
              this.identVisible = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.identVisible = false;
        })
      }

      if (this.testVisible) {
        Column() {
          TestConn({
            conn: this.testing,
            onClose: () => {
              this.testVisible = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.testVisible = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 官方外壳:行内操作收进长按菜单(连接/测试/编辑/删除),深色样式 */
  @Builder
  RowActionMenu() {
    if (this.rowActionVisible && this.rowActionConn !== null) {
      Column() {
        Column({ space: 2 }) {
          Text('连接 ' + this.rowActionConn.name)
            .fontSize(12).fontColor(this.th().ink)
            .width('100%').padding(8).borderRadius(4).textAlign(TextAlign.Start)
            .onClick(() => { this.rowActionVisible = false; this.onOpenConn(this.rowActionConn!.id); })
          Text('测试连通')
            .fontSize(12).fontColor(this.th().ink)
            .width('100%').padding(8).borderRadius(4).textAlign(TextAlign.Start)
            .onClick(() => { this.testing = this.rowActionConn; this.testVisible = true; this.rowActionVisible = false; })
          Text('编辑')
            .fontSize(12).fontColor(this.th().ink)
            .width('100%').padding(8).borderRadius(4).textAlign(TextAlign.Start)
            .onClick(() => { this.beginEdit(this.rowActionConn!); this.rowActionVisible = false; })
          Divider().strokeWidth(1).color(this.th().hover).margin({ top: 2, bottom: 2 })
          Text('删除')
            .fontSize(12).fontColor(this.th().danger)
            .width('100%').padding(8).borderRadius(4).textAlign(TextAlign.Start)
            .onClick(() => { this.doDeleteConn(this.rowActionConn!); this.rowActionVisible = false; })
        }
        .width(150)
        .padding(6)
        .borderRadius(8)
        .backgroundColor(this.th().surfaceRaised)
        .border({ width: 1, color: this.th().hairline })
        .shadow({ radius: 24, color: '#99000000', offsetX: 0, offsetY: 8 })
      }
      .position({ x: 100, y: 200 })
      .onClick(() => { this.rowActionVisible = false; })
    }
  }

  @Builder
  CredDialog() {
    if (this.credDialog > 0) {
      Column() {
        Column({ space: 12 }) {
          Text(this.credDialog === 1 ? '设置主密码' : '解锁主密码')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
          if (this.credDialog === 1) {
            Text('主密码用于加密 connections.json 中的密码/私钥字段,忘记后不可恢复')
              .fontSize(12)
              .fontColor(this.th().inkSubtle)
          }
          TextInput({ placeholder: this.credDialog === 1 ? '主密码(至少4字符)' : '主密码' })
            .type(InputType.Password)
            .onChange((v: string) => {
              this.credPass1 = v;
            })
          if (this.credDialog === 1) {
            TextInput({ placeholder: '再次输入' })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.credPass2 = v;
              })
          }
          if (this.credErr.length > 0) {
            Text(this.credErr).fontSize(13).fontColor(this.th().danger)
          }
          Row({ space: 12 }) {
            Button('取消')
              .backgroundColor(this.th().inkSubtle)
              .layoutWeight(1)
              .onClick(() => {
                this.credDialog = 0;
              })
            Button('确定')
              .layoutWeight(1)
              .onClick(async () => {
                try {
                  if (this.cred === null) {
                    this.credErr = '内部错误';
                    return;
                  }
                  if (this.credDialog === 1) {
                    if (this.credPass1.length < 4) {
                      this.credErr = '主密码至少 4 个字符';
                      return;
                    }
                    if (this.credPass1 !== this.credPass2) {
                      this.credErr = '两次输入不一致';
                      return;
                    }
                    hilog.info(IDOMAIN, ITAG, 'setupMasterPassword begin p1len=%{public}d', this.credPass1.length);
                    await this.cred.setupMasterPassword(this.credPass1);
                    hilog.info(IDOMAIN, ITAG, 'setupMasterPassword done');
                    this.hasMaster = true;
                    this.unlocked = true;
                    this.credDialog = 0;
                    this.showToast('主密码已设置,后续保存的凭据将加密落盘');
                  } else {
                    await this.cred.unlock(this.credPass1);
                    this.unlocked = true;
                    this.credDialog = 0;
                    this.store.load().then(async (): Promise<void> => {
                      await this.store.revealSecrets();
                      if (this.identStore !== null) {
                        this.identStore.loadSync();
                        await this.identStore.revealSecrets();
                        this.identities = this.identStore.identities.slice();
                      }
                      this.sync();
                    }).catch(() => {});
                    this.showToast('已解锁');
                  }
                } catch (e) {
                  const em = e instanceof CredError ? e.message : JSON.stringify(e);
                  hilog.error(IDOMAIN, ITAG, 'cred dialog error: %{public}s', em);
                  this.credErr = em;
                }
              })
          }
          .width('100%')
        }
        .width('72%')
        .padding(18)
        .backgroundColor(this.th().surfaceRaised)
        .borderRadius(12)
        .shadow({ radius: 24, color: '#99000000', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.credDialog = 0;
      })
    }
  }

  @Builder
  GroupSection(g: GroupRec) {
    Column() {
      Row({ space: 6 }) {
        Text('▸ ' + g.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().inkSubtle)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.connsOf(g.id).length.toString())
          .fontSize(9)
          .fontColor(this.th().inkSubtle)
          .backgroundColor(this.th().hover)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(8)
        Text('⋯')
          .fontSize(13)
          .fontColor(this.th().inkSubtle)
          .width(22)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.renamingId = g.id;
            this.groupName = g.name;
            this.groupDialogMode = 2;
          })
          .gesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.store.deleteGroup(g.id);
                this.persist();
                this.showToast('已删除分组 ' + g.name + ',成员移到根级');
              })
          )
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 8, bottom: 4 })

      ForEach(this.connsOf(g.id), (c: ConnRec) => {
        this.ConnRow(c)
      }, (c: ConnRec) => c.id + c.name + c.port.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** M3-3a: pinned favorites + most-recently-used quick strip. */
  @Builder
  QuickAccess() {
    if (this.quickItems().length > 0) {
      Column() {
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
          ForEach(this.quickItems(), (c: ConnRec) => {
            Row({ space: 8 }) {
              Text('◷')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th().brand)
                .width(16)
                .textAlign(TextAlign.Center)
              Column({ space: 1 }) {
                Text(c.name)
                  .fontSize(12)
                  .fontColor(this.th().ink)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.hostLineOf(c))
                  .fontSize(10)
                  .fontColor(this.th().inkSubtle)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(4)
            .onClick(() => {
              this.onOpenConn(c.id);
            })
          }, (c: ConnRec) => c.id + (c.favorite ? 'F' : 'R') + c.name + c.lastUsedAt.toString())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })
    }
  }

  /** host line helper reused by quick strip (dark theme). */
  private hostLineOf(c: ConnRec): string {
    return this.hostLine(c);
  }

  /** favorites first (definition order), then recents (lastUsedAt desc), deduped, max 8. */
  private quickItems(): ConnRec[] {
    const out: ConnRec[] = [];
    const seen: string[] = [];
    const favs = this.store.favorites();
    for (let i = 0; i < favs.length && out.length < 8; i++) {
      out.push(favs[i]);
      seen.push(favs[i].id);
    }
    const rec = this.store.recents(8);
    for (let i = 0; i < rec.length && out.length < 8; i++) {
      if (seen.indexOf(rec[i].id) < 0) {
        out.push(rec[i]);
        seen.push(rec[i].id);
      }
    }
    return out;
  }

  @Builder
  RootSection() {    Column() {
      if (this.connsOf(null).length > 0) {
        Text('▸ 未分组')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().inkSubtle)
          .width('100%')
          .padding({ left: 12, top: 8, bottom: 4 })
      }
      ForEach(this.connsOf(null), (c: ConnRec) => {
        this.ConnRow(c)
      }, (c: ConnRec) => c.id + c.name + c.port.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ConnRow(c: ConnRec) {
    Row({ space: 8 }) {
      // 左侧协议小图标(relay4: 16px iconStrong Bold 高对比)
      Text(c.type === 'ssh' ? '⌗' : (c.type === 'rdp' ? '▤' : (c.type === 'vnc' ? '▣' : '○')))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.th().iconStrong)
        .width(16)
        .textAlign(TextAlign.Center)
      if (c.undecryptable) {
        Text('密文不可读')
          .fontSize(9)
          .fontColor(this.th().surfaceRaised)
          .backgroundColor(this.th().warn)
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      }
      if (c.authType === 'identity' && !this.identityExists(c.identityId)) {
        Text('身份缺失')
          .fontSize(9)
          .fontColor(this.th().surfaceRaised)
          .backgroundColor(this.th().danger)
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      }
      Column({ space: 1 }) {
        Text(c.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(EDITABLE_TYPES_SET.indexOf(c.type) >= 0 ? this.hostLine(c) :
          this.hostLine(c) + '(暂不支持连接)')
          .fontSize(10)
          .fontColor(this.th().inkSubtle)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 官方:右缘仅星标;连接=整行点击
      Text(c.favorite ? '★' : '☆')
        .fontSize(13)
        .fontColor(c.favorite ? this.th().warn : this.th().inkSubtle)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          const nowFav = this.store.toggleFavorite(c.id);
          this.persist();
          this.showToast(nowFav ? '已收藏 ' + c.name : '已取消收藏 ' + c.name);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 10, top: 7, bottom: 7 })
    .borderRadius(4)
    .margin({ bottom: 2 })
    .onClick(() => {
      if (EDITABLE_TYPES_SET.indexOf(c.type) >= 0) {
        this.onOpenConn(c.id);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction((e: GestureEvent) => {
          // 长按弹出操作菜单(编辑/测试/删除)——保留 M1-M4 全部能力
          this.rowActionConn = c;
          this.rowActionVisible = true;
        })
    )
  }
}

/** M3 relay-2d: string field reader for want-injected identity records. */
function toIdentStr(v: Object | undefined, d: string): string {
  const s = v as string;
  return (typeof s === 'string') ? s : d;
}

function stringToBytes(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        i++;
      } else {
        out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      }
    } else {
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    }
  }
  return new Uint8Array(out);
}
