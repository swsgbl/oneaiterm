/**
 * upstream M3 relay-3b - SFTP file browser panel (routed page).
 *
 * Operates on the LIVE terminal ssh session (SessionService): sftpOpen
 * reuses the authenticated connection as an extra channel, sftpList
 * renders remote dirs, single-file Get/Put with byte progress (EventHub
 * style via native transfer events type=4 -> here polled from statText).
 *
 * Upstream parity (backend/session/sftp_session.go):
 *  - ListRemote: entries {name,size,modTime,mode,isDir} + dir line
 *  - navigation: tap a dir -> Stat-verified chdir (here: path join + list)
 *  - Get/Put: single file, 32KB loop, bytes + ms logged (hilog sftp dl/ul)
 * Trimmed this relay: owner/group mapping (uid shown instead), recursive
 * transfers, resume, pause, exec-sftp-server fallback.
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SessionService } from '../service/SessionService';
import { libssh } from '@ohos/libssh';
import { AppTheme, themeByName } from '../common/AppTheme';

interface SftpEntry {
  name: string;
  size: number;
  isDir: boolean;
  mtime: number;
  permissions: number;
}

interface SftpListResp {
  dir: string;
  files: SftpEntry[];
}

@Component
export struct SftpPanel {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @Prop connIdIn: string = ''
  @State cwd: string = '.';
  @State entries: SftpEntry[] = [];
  @State status: string = 'idle';
  @State errText: string = '';
  @State busy: boolean = false;
  @State xferText: string = '';
  @State lastOp: string = '';
  @State title: string = 'SFTP';
  onClose: () => void = () => {
  };
  private ssh: libssh | null = null;
  private sid: number = -1;

  aboutToAppear(): void {
    this.ssh = SessionService.sshHandle();
    this.sid = SessionService.getSessionId();
    if (this.ssh === null || this.sid < 0) {
      this.status = 'error';
      this.errText = 'no live session - connect a host first';
      return;
    }
    this.openAndList();
  }

  private openAndList(): void {
    this.status = 'listing';
    this.errText = '';
    this.busy = true;
    const t0 = Date.now();
    this.ssh!.sftpOpen(this.sid).then(() => {
      return this.listDir(this.cwd);
    }).then(() => {
      hilog.info(0x0110, 'oat.sftp', 'panel open+list ms=%{public}d', Date.now() - t0);
      this.busy = false;
    }).catch((e: Object) => {
      this.status = 'error';
      this.errText = e instanceof Error ? e.message : JSON.stringify(e);
      this.busy = false;
      hilog.error(0x0110, 'oat.sftp', 'open+list FAIL %{public}s', this.errText);
    });
  }

  private listDir(path: string): Promise<void> {
    return new Promise<void>((resolve) => {
      this.ssh!.sftpList(this.sid, path).then((json: string) => {
        let dir: string = path;
        let files: SftpEntry[] = [];
        try {
          const resp = JSON.parse(json) as SftpListResp;
          dir = resp.dir;
          files = resp.files;
        } catch (e) {
          hilog.warn(0x0110, 'oat.sftp', 'list parse fail');
        }
        // dirs first, then name order (upstream sorts server-side; we sort for UX)
        files.sort((a: SftpEntry, b: SftpEntry): number => {
          if (a.isDir !== b.isDir) {
            return a.isDir ? -1 : 1;
          }
          return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
        });
        this.cwd = dir;
        this.entries = files;
        this.status = 'ok';
        hilog.info(0x0110, 'oat.sftp', 'list dir=%{public}s n=%{public}d', dir, files.length);
        resolve();
      }).catch((e: Object) => {
        this.status = 'error';
        this.errText = e instanceof Error ? e.message : JSON.stringify(e);
        hilog.error(0x0110, 'oat.sftp', 'list FAIL %{public}s', this.errText);
        resolve();
      });
    });
  }

  private joinPath(base: string, name: string): string {
    if (base === '.' || base.length === 0) {
      return name;
    }
    if (base.charAt(base.length - 1) === '/') {
      return base + name;
    }
    return base + '/' + name;
  }

  private parentPath(p: string): string {
    if (p === '.' || p === '/' || p.length === 0) {
      return p;
    }
    const i = p.lastIndexOf('/');
    if (i < 0) {
      return '.';
    }
    if (i === 0) {
      return '/';
    }
    return p.substring(0, i);
  }

  private onTapEntry(e: SftpEntry): void {
    if (this.busy) {
      return;
    }
    const path = this.joinPath(this.cwd, e.name);
    if (e.isDir) {
      this.busy = true;
      this.status = 'listing';
      this.listDir(path).then(() => {
        this.busy = false;
      });
      return;
    }
    // file: download to filesDir/sftp/<name>
    this.download(path, e.name);
  }

  private localBase(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return ctx.filesDir + '/sftp';
  }

  private ensureLocalDir(): void {
    try {
      if (!fileIo.accessSync(this.localBase())) {
        fileIo.mkdirSync(this.localBase(), true);
      }
    } catch (e) {
      hilog.warn(0x0110, 'oat.sftp', 'mkdir sftp: %{public}s', JSON.stringify(e));
    }
  }

  private download(remotePath: string, name: string): void {
    this.ensureLocalDir();
    const local = this.localBase() + '/' + name;
    this.busy = true;
    this.status = 'downloading';
    this.xferText = 'dl 0B';
    this.ssh!.sftpDownload(this.sid, remotePath, local).then((n: number) => {
      this.xferText = 'dl ' + n.toString() + 'B';
      this.lastOp = 'downloaded ' + name + ' (' + n.toString() + 'B)';
      this.status = 'ok';
      this.busy = false;
      hilog.info(0x0110, 'oat.sftp', 'dl ok %{public}s %{public}d bytes', name, n);
    }).catch((e: Object) => {
      this.status = 'error';
      this.errText = e instanceof Error ? e.message : JSON.stringify(e);
      this.busy = false;
      hilog.error(0x0110, 'oat.sftp', 'dl FAIL %{public}s %{public}s', name, this.errText);
    });
  }

  private upload(): void {
    this.ensureLocalDir();
    // upload the newest file in filesDir/sftp (host pushes via hdc file send)
    const base = this.localBase();
    let name = '';
    let mtime = 0;
    try {
      const names = fileIo.listFileSync(base);
      for (let i = 0; i < names.length; i++) {
        const st = fileIo.statSync(base + '/' + names[i]);
        if (st.isFile() && st.mtime > mtime) {
          mtime = st.mtime;
          name = names[i];
        }
      }
    } catch (e) {
      this.status = 'error';
      this.errText = 'list local sftp dir failed';
      return;
    }
    if (name === '') {
      this.status = 'error';
      this.errText = 'no local file in ' + base + ' (hdc file send one first)';
      return;
    }
    const local = base + '/' + name;
    const remote = this.joinPath(this.cwd, name);
    this.busy = true;
    this.status = 'uploading';
    this.xferText = 'ul 0B';
    this.ssh!.sftpUpload(this.sid, local, remote).then((n: number) => {
      this.xferText = 'ul ' + n.toString() + 'B';
      this.lastOp = 'uploaded ' + name + ' (' + n.toString() + 'B)';
      this.status = 'ok';
      this.busy = false;
      this.listDir(this.cwd); // refresh to show the new file
      hilog.info(0x0110, 'oat.sftp', 'ul ok %{public}s %{public}d bytes', name, n);
    }).catch((e: Object) => {
      this.status = 'error';
      this.errText = e instanceof Error ? e.message : JSON.stringify(e);
      this.busy = false;
      hilog.error(0x0110, 'oat.sftp', 'ul FAIL %{public}s %{public}s', name, this.errText);
    });
  }

  private closePanel(): void {
    if (this.ssh !== null && this.sid >= 0) {
      this.ssh.sftpClose(this.sid);
    }
    this.onClose();
  }

  build() {
    Column() {
      // header
      Column() {
        Row({ space: 8 }) {
          Column() {
            Text(this.title)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().surfaceRaised)
              .maxLines(1)
            Text(this.status + (this.busy ? ' ...' : '') + '  ' + this.entries.length.toString() + ' items')
              .fontSize(11)
              .fontColor(this.th().inkSubtle)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('close')
            .fontSize(13)
            .backgroundColor(this.th().danger)
            .onClick(() => {
              this.closePanel();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

        if (this.status === 'error' && this.errText.length > 0) {
          Text('error: ' + this.errText)
            .fontSize(12)
            .fontColor(this.th().danger)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 6 })
        }
        if (this.lastOp.length > 0) {
          Text(this.lastOp)
            .fontSize(11)
            .fontColor(this.th().success)
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 4 })
        }
      }
      .width('100%')
      .backgroundColor(this.th().panel)

      // cwd bar: [..] path [refresh] [upload]
      Row({ space: 8 }) {
        Button('..')
          .fontSize(13)
          .backgroundColor(this.th().panel)
          .onClick(() => {
            if (this.busy) {
              return;
            }
            const up = this.parentPath(this.cwd);
            this.busy = true;
            this.status = 'listing';
            this.listDir(up).then(() => {
              this.busy = false;
            });
          })
        Text(this.cwd)
          .fontSize(13)
          .fontColor(this.th().ink)
          .layoutWeight(1)
          .maxLines(1)
          .fontFamily('monospace')
        Button('refresh')
          .fontSize(13)
          .backgroundColor(this.th().panel)
          .onClick(() => {
            if (this.busy) {
              return;
            }
            this.busy = true;
            this.status = 'listing';
            this.listDir(this.cwd).then(() => {
              this.busy = false;
            });
          })
        Button('upload')
          .fontSize(13)
          .backgroundColor(this.th().success)
          .onClick(() => {
            if (this.busy) {
              return;
            }
            this.upload();
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.th().surface)

      // transfer line
      if (this.xferText.length > 0) {
        Text(this.xferText)
          .fontSize(11)
          .fontColor(this.th().warn)
          .width('100%')
          .padding({ left: 12, right: 12, top: 2, bottom: 2 })
      }

      // entries
      List({ space: 2 }) {
        ForEach(this.entries, (e: SftpEntry, idx: number) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(e.isDir ? 'd' : '-')
                .fontSize(14)
                .fontColor(e.isDir ? this.th().warn : this.th().inkSubtle)
                .width(16)
              Text(e.name)
                .fontSize(14)
                .fontColor(e.isDir ? this.th().brand : this.th().ink)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.fmtSize(e.size))
                .fontSize(11)
                .fontColor(this.th().inkSubtle)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(idx % 2 === 0 ? this.th().surface : this.th().surface)
            .borderRadius(4)
            .onClick(() => {
              this.onTapEntry(e);
            })
          }
        }, (e: SftpEntry, idx: number) => e.name + ':' + e.size.toString() + ':' + (e.isDir ? '1' : '0'))
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(this.th().surface)

      // footer
      Text('tap dir=navigate  tap file=download to filesDir/sftp/  upload=newest local file')
        .fontSize(10)
        .fontColor(this.th().inkSubtle)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 6 })
    }
    .width('100%')
    .height('100%')
  }

  private fmtSize(n: number): string {
    if (n < 1024) {
      return n.toString() + 'B';
    }
    if (n < 1024 * 1024) {
      return (n / 1024).toFixed(1) + 'K';
    }
    if (n < 1024 * 1024 * 1024) {
      return (n / 1024 / 1024).toFixed(1) + 'M';
    }
    return (n / 1024 / 1024 / 1024).toFixed(1) + 'G';
  }
}
