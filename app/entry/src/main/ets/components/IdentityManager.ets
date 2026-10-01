/**
 * upstream M3 relay-2 - Identity manager overlay.
 *
 * Lists identities from the shared IdentityStore, supports add/edit/delete.
 * New/edited records get plaintext secrets in memory; ConnList persists via
 * sealAndSave (enc:v1 under the master password, upstream IdentityStore.Save
 * semantics). Also implements the "identity missing" flow: hosts referencing
 * a deleted identity are badged in ConnList (checked at connect time).
 */
import { IdentityRec } from '../store/IdentityStore';
import { CredentialManager } from '../store/CredentialManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, themeByName } from '../common/AppTheme';

const ITAG: string = 'oat.identui';
const IDOMAIN: number = 0x0110;
const AUTH_TYPES: string[] = ['password', 'key', 'keyText'];

@Component
export struct IdentityManager {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @Prop identities: IdentityRec[] = [];
  cred: CredentialManager | null = null;
  onSaved: (changed: IdentityRec[]) => void = () => {};
  onClose: () => void = () => {};
  @State editing: boolean = false;
  @State editIdx: number = -1; // -1 = new
  @State eName: string = '';
  @State eUser: string = '';
  @State eAuth: string = 'password';
  @State ePassword: string = '';
  @State eKeyPath: string = '';
  @State eKeyContent: string = '';
  @State err: string = '';
  /** Working copy (Prop arrays must not be mutated in place). */
  @State list: IdentityRec[] = [];

  aboutToAppear(): void {
    this.list = this.identities.slice();
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('身份库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('关闭')
          .fontSize(14)
          .fontColor(this.th().inkSubtle)
          .padding(6)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      if (this.cred === null || !this.cred.hasMasterPassword()) {
        Text('提示: 未设置主密码,身份密钥/密码将以明文保存(建议先设置主密码)')
          .fontSize(12)
          .fontColor(this.th().warn)
      }

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.list, (id: IdentityRec, idx: number) => {
            Row({ space: 8 }) {
              Text(id.authType)
                .fontSize(10)
                .fontColor(this.th().surfaceRaised)
                .backgroundColor(id.authType === 'password' ? this.th().success :
                  (id.authType === 'keyText' ? this.th().brand : this.th().inkSubtle))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              Column({ space: 2 }) {
                Text(id.name)
                  .fontSize(15)
                  .fontColor(this.th().surface)
                Text(id.username + (id.keyPath.length > 0 ? ' key:' + id.keyPath : ''))
                  .fontSize(12)
                  .fontColor(this.th().inkSubtle)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('编辑')
                .fontSize(13)
                .fontColor(this.th().inkSubtle)
                .padding(4)
                .onClick(() => {
                  this.beginEdit(idx);
                })
              Text('删除')
                .fontSize(13)
                .fontColor(this.th().danger)
                .padding(4)
                .onClick(() => {
                  this.deleteIdent(idx);
                })
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 4, bottom: 4 })
          }, (id: IdentityRec) => id.id + id.name + id.authType)
          if (this.list.length === 0) {
            Text('(空) 添加一个身份后,主机可选择"身份"认证引用它')
              .fontSize(13)
              .fontColor(this.th().inkSubtle)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')

      Button('+ 新增身份')
        .width('100%')
        .backgroundColor(this.th().brand)
        .onClick(() => {
          this.beginEdit(-1);
        })

      if (this.editing) {
        this.EditForm()
      }
    }
    .width('86%')
    .height('86%')
    .padding(16)
    .backgroundColor(this.th().surfaceRaised)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  private beginEdit(idx: number): void {
    this.err = '';
    if (idx >= 0 && idx < this.list.length) {
      const id = this.list[idx];
      this.eName = id.name;
      this.eUser = id.username;
      this.eAuth = id.authType;
      this.ePassword = id.password; // revealed plaintext (or '' when locked)
      this.eKeyPath = id.keyPath;
      this.eKeyContent = id.keyContent;
    } else {
      this.eName = '';
      this.eUser = '';
      this.eAuth = 'password';
      this.ePassword = '';
      this.eKeyPath = '';
      this.eKeyContent = '';
    }
    this.editIdx = idx;
    this.editing = true;
  }

  private deleteIdent(idx: number): void {
    if (idx < 0 || idx >= this.list.length) {
      return;
    }
    const victim = this.list[idx];
    this.list.splice(idx, 1);
    this.onSaved(this.list.slice()); // persist; hosts referencing victim now badge missing
    hilog.info(IDOMAIN, ITAG, 'identity deleted id=%{public}s (hosts will badge missing)', victim.id);
  }

  @Builder
  EditForm() {
    Column({ space: 8 }) {
      Text(this.editIdx >= 0 ? '编辑身份' : '新增身份')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
      TextInput({ placeholder: '名称(如: prod-root)', text: this.eName })
        .onChange((v: string) => {
          this.eName = v;
        })
      TextInput({ placeholder: '用户名', text: this.eUser })
        .onChange((v: string) => {
          this.eUser = v;
        })
      Row({ space: 8 }) {
        ForEach(AUTH_TYPES, (t: string) => {
          Text(t)
            .fontSize(13)
            .fontColor(this.eAuth === t ? this.th().surfaceRaised : this.th().ink)
            .backgroundColor(this.eAuth === t ? this.th().brand : this.th().panel)
            .borderRadius(6)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              this.eAuth = t;
            })
        }, (t: string) => t)
      }
      if (this.eAuth === 'password') {
        TextInput({ placeholder: '密码', text: this.ePassword })
          .type(InputType.Password)
          .onChange((v: string) => {
            this.ePassword = v;
          })
      } else if (this.eAuth === 'key') {
        TextInput({ placeholder: '私钥文件路径(sandbox)', text: this.eKeyPath })
          .onChange((v: string) => {
            this.eKeyPath = v;
          })
        TextInput({ placeholder: '密钥口令(可空)', text: this.ePassword })
          .type(InputType.Password)
          .onChange((v: string) => {
            this.ePassword = v;
          })
      } else {
        TextArea({ placeholder: '私钥 PEM 文本(-----BEGIN...)', text: this.eKeyContent })
          .height(90)
          .onChange((v: string) => {
            this.eKeyContent = v;
          })
        TextInput({ placeholder: '密钥口令(可空)', text: this.ePassword })
          .type(InputType.Password)
          .onChange((v: string) => {
            this.ePassword = v;
          })
      }
      if (this.err.length > 0) {
        Text(this.err).fontSize(13).fontColor(this.th().danger)
      }
      Row({ space: 10 }) {
        Button('取消')
          .backgroundColor(this.th().inkSubtle)
          .layoutWeight(1)
          .onClick(() => {
            this.editing = false;
          })
        Button('保存')
          .layoutWeight(1)
          .onClick(() => {
            this.saveForm();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(this.th().surfaceRaised)
  }

  private saveForm(): void {
    if (this.eName.trim().length === 0 || this.eUser.trim().length === 0) {
      this.err = '名称和用户名必填';
      return;
    }
    if (this.eAuth === 'keyText' && this.eKeyContent.trim().length === 0) {
      this.err = 'keyText 身份需要私钥 PEM 文本';
      return;
    }
    if (this.eAuth === 'key' && this.eKeyPath.trim().length === 0) {
      this.err = 'key 身份需要私钥文件路径';
      return;
    }
    const rec = new IdentityRec();
    if (this.editIdx >= 0 && this.editIdx < this.list.length) {
      rec.id = this.list[this.editIdx].id;
    } else {
      rec.id = 'ident-' + Date.now().toString() + '-' + Math.floor(Math.random() * 1e8).toString();
    }
    rec.name = this.eName.trim();
    rec.username = this.eUser.trim();
    rec.authType = this.eAuth;
    rec.password = this.ePassword;
    rec.keyPath = this.eAuth === 'key' ? this.eKeyPath.trim() : '';
    rec.keyContent = this.eAuth === 'keyText' ? this.eKeyContent : '';
    if (this.editIdx >= 0 && this.editIdx < this.list.length) {
      this.list[this.editIdx] = rec;
    } else {
      this.list.push(rec);
    }
    this.editing = false;
    this.onSaved(this.list.slice());
    hilog.info(IDOMAIN, ITAG, 'identity saved id=%{public}s auth=%{public}s', rec.id, rec.authType);
  }
}
