/**
 * upstream M1b - Connection add/edit form dialog (SSH subset).
 * Field set matches upstream ConnectionConfig SSH subset; validation:
 * host required, port 1-65535, credential required by authType.
 */
import { ConnRec, GroupRec } from '../store/ConnStore';
import { IdentityRec } from '../store/IdentityStore';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';

const AUTH_TYPES: string[] = ['password', 'key', 'keyText', 'identity'];
const ENCODINGS: string[] = ['utf-8', 'gbk'];
const BACKSPACE_KEYS: string[] = ['del', 'bs', 'vt220'];

@Component
export struct ConnForm {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  editing: ConnRec | null = null;
  onClose: () => void = () => {};
  groups: GroupRec[] = [];
  identities: IdentityRec[] = [];
  onSaved: (c: ConnRec) => void = () => {};

  // form state
  @State fName: string = '';
  @State fHost: string = '';
  @State fPort: string = '22';
  @State fUser: string = '';
  @State fRemark: string = '';
  @State fAuth: string = 'password';
  @State fAuthIdx: number = 0;
  @State fPassword: string = '';
  @State fKeyPath: string = '';
  @State fKeyContent: string = '';
  @State fGroupIdx: number = 0;
  @State fIdentIdx: number = 0;
  // M3-3a: encoding / backspaceKey / keepalive
  @State fEncIdx: number = 0;
  @State fBkIdx: number = 0;
  @State fKeepalive: string = '30';
  @State fTypeIdx: number = 0; // M5 parity: 0 ssh 1 telnet 2 raw 3 local
  @State err: string = '';

  private editId: string = '';

  /** M5 parity: protocol type picker options. */
  private typeOptions(): Array<SelectOption> {
    return [
      { value: 'SSH' } as SelectOption,
      { value: 'Telnet' } as SelectOption,
      { value: 'Raw TCP' } as SelectOption,
      { value: '本地终端' } as SelectOption
    ];
  }

  /** M5 parity: protocol type from picker index. */
  private connType(): string {
    if (this.fTypeIdx === 1) {
      return 'telnet';
    }
    if (this.fTypeIdx === 2) {
      return 'raw';
    }
    if (this.fTypeIdx === 3) {
      return 'local';
    }
    return 'ssh';
  }

  aboutToAppear(): void {
    this.resetForm();
  }

  private resetForm(): void {
    if (this.editing !== null) {
      this.editId = this.editing.id;
      this.fName = this.editing.name;
      this.fHost = this.editing.host;
      this.fPort = this.editing.port.toString();
      this.fUser = this.editing.user;
      this.fRemark = this.editing.remark;
      this.fAuth = this.editing.authType;
      this.fAuthIdx = Math.max(0, AUTH_TYPES.indexOf(this.editing.authType));
      this.fPassword = this.editing.password;
      this.fKeyPath = this.editing.keyPath;
      this.fKeyContent = this.editing.keyContent;
      let ii = 0;
      if (this.editing.identityId.length > 0) {
        for (let i = 0; i < this.identities.length; i++) {
          if (this.identities[i].id === this.editing.identityId) {
            ii = i + 1;
          }
        }
      }
      this.fIdentIdx = ii;
      let gi = 0;
      if (this.editing.groupId !== null) {
        for (let i = 0; i < this.groups.length; i++) {
          if (this.groups[i].id === this.editing.groupId) {
            gi = i + 1;
          }
        }
      }
      this.fGroupIdx = gi;
      this.fEncIdx = Math.max(0, ENCODINGS.indexOf(this.editing.encoding));
      this.fBkIdx = Math.max(0, BACKSPACE_KEYS.indexOf(this.editing.backspaceKey));
      this.fKeepalive = this.editing.keepaliveSec > 0 ? this.editing.keepaliveSec.toString() : '30';
      this.fTypeIdx = this.editing.type === 'telnet' ? 1 : (this.editing.type === 'raw' ? 2 : (this.editing.type === 'local' ? 3 : 0));
    } else {
      this.editId = '';
      this.fName = '';
      this.fHost = '';
      this.fPort = '22';
      this.fUser = '';
      this.fRemark = '';
      this.fAuth = 'password';
      this.fAuthIdx = 0;
      this.fPassword = '';
      this.fKeyPath = '';
      this.fKeyContent = '';
      this.fGroupIdx = 0;
      this.fIdentIdx = 0;
      this.fEncIdx = 0;
      this.fBkIdx = 0;
      this.fKeepalive = '30';
      this.fTypeIdx = 0;
    }
    this.err = '';
  }

  private buildRec(): ConnRec {
    const c = new ConnRec();
    if (this.editId.length > 0) {
      c.id = this.editId;
    } else {
      c.id = 'c-' + this.rand8();
    }
    c.name = this.fName.trim().length > 0 ? this.fName.trim() : this.fHost.trim();
    c.host = this.fHost.trim();
    c.type = this.connType();
    const p = parseInt(this.fPort, 10);
    c.port = isNaN(p) ? 22 : p;
    c.user = this.fUser.trim();
    c.remark = this.fRemark;
    c.authType = this.fAuth;
    c.identityId = this.fAuth === 'identity' && this.fIdentIdx > 0 ? this.identities[this.fIdentIdx - 1].id : '';
    c.password = this.fPassword;
    c.keyPath = this.fKeyPath.trim();
    c.keyContent = this.fKeyContent;
    if (this.fGroupIdx === 0) {
      c.groupId = null;
    } else {
      c.groupId = this.groups[this.fGroupIdx - 1].id;
    }
    c.encoding = ENCODINGS[this.fEncIdx] ?? 'utf-8';
    c.backspaceKey = BACKSPACE_KEYS[this.fBkIdx] ?? 'del';
    const ka = parseInt(this.fKeepalive, 10);
    c.keepaliveSec = (isNaN(ka) || ka < 0) ? 30 : ka;
    c.initialShell = c.type === 'local' ? '/bin/sh' : '';
    // preserve favorite/lastUsedAt on edit (not editable in this form)
    if (this.editing !== null) {
      c.favorite = this.editing.favorite;
      c.lastUsedAt = this.editing.lastUsedAt;
    }
    return c;
  }

  private rand8(): string {
    let s = '';
    const seed = 'abcdefghijklmnopqrstuvwxyz0123456789';
    for (let i = 0; i < 8; i++) {
      s += seed.charAt(Math.floor(Math.random() * seed.length));
    }
    return s;
  }

  private validate(c: ConnRec): string {
    if (c.host.length === 0) {
      return 'host 不能为空';
    }
    if (c.port < 1 || c.port > 65535) {
      return '端口必须在 1-65535';
    }
    if (c.authType === 'password' && c.password.length === 0) {
      return '密码认证需要填写密码';
    }
    if (c.authType === 'key' && c.keyPath.length === 0) {
      return '密钥认证需要填写密钥路径';
    }
    if (c.authType === 'keyText' && c.keyContent.trim().length === 0) {
      return '密钥文本认证需要填写私钥内容';
    }
    if (c.authType === 'keyText' && c.keyContent.indexOf('PRIVATE KEY') < 0) {
      return '私钥内容需为 PEM 文本(含 PRIVATE KEY 行)';
    }
    if (c.authType === 'identity' && c.identityId.length === 0) {
      return '身份认证需要先选择一个身份(在"身份"里创建)';
    }
    return '';
  }

  private authOptions(): Array<SelectOption> {
    const list: Array<SelectOption> = [];
    for (let i = 0; i < AUTH_TYPES.length; i++) {
      const o: SelectOption = { value: AUTH_TYPES[i] };
      list.push(o);
    }
    return list;
  }

  private groupOptions(): Array<SelectOption> {
    const list: Array<SelectOption> = [];
    const root: SelectOption = { value: '(根级/不分组)' };
    list.push(root);
    for (let i = 0; i < this.groups.length; i++) {
      const o: SelectOption = { value: this.groups[i].name };
      list.push(o);
    }
    return list;
  }

  /** M3 relay-2: identity picker options ("(不引用)" = index 0). */
  private identOptions(): Array<SelectOption> {
    const list: Array<SelectOption> = [];
    const none: SelectOption = { value: '(选择身份)' };
    list.push(none);
    for (let i = 0; i < this.identities.length; i++) {
      const id = this.identities[i];
      const o: SelectOption = { value: id.name + ' (' + id.username + '/' + id.authType + ')' };
      list.push(o);
    }
    return list;
  }

  private identLabel(): string {
    if (this.fIdentIdx === 0) {
      return '(选择身份)';
    }
    if (this.fIdentIdx - 1 < this.identities.length) {
      const id = this.identities[this.fIdentIdx - 1];
      return id.name + ' (' + id.username + '/' + id.authType + ')';
    }
    return '(选择身份)';
  }

  /** M3-3a: encoding picker options. */
  private encOptions(): Array<SelectOption> {
    const list: Array<SelectOption> = [];
    for (let i = 0; i < ENCODINGS.length; i++) {
      list.push({ value: ENCODINGS[i] } as SelectOption);
    }
    return list;
  }

  /** M3-3a: backspace-key picker options with human labels. */
  private backspaceOptions(): Array<SelectOption> {
    return [
      { value: 'del (0x7F 默认)' } as SelectOption,
      { value: 'bs (0x08)' } as SelectOption,
      { value: 'vt220 (ESC[3~)' } as SelectOption
    ];
  }

  private bkLabel(): string {
    if (this.fBkIdx === 1) {
      return 'bs (0x08)';
    }
    if (this.fBkIdx === 2) {
      return 'vt220 (ESC[3~)';
    }
    return 'del (0x7F 默认)';
  }

  private groupLabel(): string {
    if (this.fGroupIdx === 0) {
      return '(根级/不分组)';
    }
    if (this.fGroupIdx - 1 < this.groups.length) {
      return this.groups[this.fGroupIdx - 1].name;
    }
    return '(根级/不分组)';
  }

  build() {
    Column({ space: 10 }) {
      Text(this.editId.length > 0 ? '编辑主机' : '新增主机')
        .fontSize(DesignTokens.FONT_DISPLAY)
        .fontWeight(FontWeight.Bold)

      // M5 parity: protocol type selector
      Row({ space: 8 }) {
        Text('协议')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
          .width(48)
        Select(this.typeOptions())
          .selected(this.fTypeIdx)
          .value(this.connType())
          .fontColor(this.th().ink)
          .font({ size: 12 })
          .backgroundColor(this.th().inputBg)
          .borderRadius(DesignTokens.RADIUS_MD)
          .layoutWeight(1)
          .onSelect((idx: number) => {
            this.fTypeIdx = idx;
            if (idx === 1 || idx === 2) {
              this.fPort = '23';
            } else {
              this.fPort = '22';
            }
          })
      }
      .width('100%')

      TextInput({ placeholder: '名称(可空,默认用 host)', text: this.fName })
        .onChange((v) => {
          this.fName = v;
        })

      TextInput({ placeholder: 'host *', text: this.fHost })
        .onChange((v) => {
          this.fHost = v;
        })

      Row({ space: 10 }) {
        TextInput({ placeholder: '端口', text: this.fPort })
          .type(InputType.Number)
          .layoutWeight(1)
          .onChange((v) => {
            this.fPort = v;
          })
        TextInput({ placeholder: '用户名', text: this.fUser })
          .layoutWeight(1)
          .onChange((v) => {
            this.fUser = v;
          })
      }
      .width('100%')

      Row() {
        Text('认证方式').fontSize(DesignTokens.FONT_HEADING).width(70)
        Select(this.authOptions())
          .selected(this.fAuthIdx)
          .value(this.fAuth)
          .fontColor(Color.Black)
          .onSelect((idx: number, val: string) => {
            this.fAuthIdx = idx;
            this.fAuth = val;
          })
      }
      .width('100%')

      if (this.fAuth === 'password') {
        TextInput({ placeholder: '密码 *', text: this.fPassword })
          .type(InputType.Password)
          .onChange((v) => {
            this.fPassword = v;
          })
      } else if (this.fAuth === 'key') {
        TextInput({ placeholder: '私钥路径 *', text: this.fKeyPath })
          .onChange((v) => {
            this.fKeyPath = v;
          })
        TextInput({ placeholder: '密钥口令(加密私钥时填)', text: this.fPassword })
          .type(InputType.Password)
          .onChange((v) => {
            this.fPassword = v;
          })
      } else {
        TextArea({ placeholder: '私钥内容(PEM) *', text: this.fKeyContent })
          .height(72)
          .onChange((v) => {
            this.fKeyContent = v;
          })
        TextInput({ placeholder: '密钥口令(加密私钥时填,可空)', text: this.fPassword })
          .type(InputType.Password)
          .onChange((v) => {
            this.fPassword = v;
          })
      }

      if (this.fAuth === 'identity') {
        if (this.identities.length === 0) {
          Text('(尚无身份:先在主页"身份"里创建)')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().warn)
        } else {
          Row() {
            Text('引用身份').fontSize(DesignTokens.FONT_HEADING).width(70)
            Select(this.identOptions())
              .selected(this.fIdentIdx)
              .value(this.identLabel())
              .fontColor(Color.Black)
              .onSelect((idx: number) => {
                this.fIdentIdx = idx;
              })
          }
          .width('100%')
        }
      }

      Row() {
        Text('所属分组').fontSize(DesignTokens.FONT_HEADING).width(70)
        Select(this.groupOptions())
          .selected(this.fGroupIdx)
          .value(this.groupLabel())
          .fontColor(Color.Black)
          .onSelect((idx: number) => {
            this.fGroupIdx = idx;
          })
      }
      .width('100%')

      Row() {
        Text('编码').fontSize(DesignTokens.FONT_HEADING).width(70)
        Select(this.encOptions())
          .selected(this.fEncIdx)
          .value(ENCODINGS[this.fEncIdx] ?? 'utf-8')
          .fontColor(Color.Black)
          .onSelect((idx: number) => {
            this.fEncIdx = idx;
          })
      }
      .width('100%')

      Row() {
        Text('退格键').fontSize(DesignTokens.FONT_HEADING).width(70)
        Select(this.backspaceOptions())
          .selected(this.fBkIdx)
          .value(this.bkLabel())
          .fontColor(Color.Black)
          .onSelect((idx: number) => {
            this.fBkIdx = idx;
          })
      }
      .width('100%')

      Row() {
        Text('保活(秒)').fontSize(DesignTokens.FONT_HEADING).width(70)
        TextInput({ placeholder: '30', text: this.fKeepalive })
          .type(InputType.Number)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.fKeepalive = v;
          })
      }
      .width('100%')

      TextInput({ placeholder: '备注', text: this.fRemark })
        .onChange((v) => {
          this.fRemark = v;
        })

      if (this.err.length > 0) {
        Text(this.err).fontSize(DesignTokens.FONT_BODY).fontColor(this.th().danger)
      }

      Row({ space: 12 }) {
        Button('取消')
          .backgroundColor(this.th().inkSubtle)
          .layoutWeight(1)
          .onClick(() => {
            this.onClose();
          })
        Button('保存')
          .layoutWeight(1)
          .onClick(() => {
            const c = this.buildRec();
            const e = this.validate(c);
            if (e.length > 0) {
              this.err = e;
              return;
            }
            this.onSaved(c);
            this.onClose();
          })
      }
      .width('100%')
    }
    .width('88%')
    .padding(DesignTokens.SPACE_LG)
    .backgroundColor(this.th().surfaceRaised)
    .borderRadius(DesignTokens.RADIUS_LG)
  }
}
