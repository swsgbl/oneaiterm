/**
 * 连接档案管理面板(任务 LEG-1;旧界面退役计划棒 1/4)。
 *
 * 旧 ConnList(1410 行)的功能面收拢为 RightPanel 第四页签「连接」:
 * 档案列表 + 删除确认 + 一键连接;新建/编辑走全屏 CustomDialog(内嵌
 * 面板表单在本布局环境连吃六坑——layoutWeight 挤没固定行/滚动区 swipe
 * 不响应/标题行被压 15px;系统弹层布局隔离后稳定)。
 * 服务层零改动(ConnectionStore.upsertConn/deleteConn/save——password
 * 内存明文、save() 内 enc:v1 加密落盘,红线与旧界面一致);telnet 档案
 * 本棒只存不连(LEG-2 接 Telnet 通路,按钮置灰带提示)。
 */
import { ConnRec, getSharedStore } from '../../store/ConnStore';
import { tr } from '../../common/AppI18n';
import { ensureSharedStore } from '../remote/ConnStoreBootstrap';
import { WorkbenchVm } from '../viewmodel/WorkbenchVm';
import { AppTheme, themeByName } from '../../common/AppTheme';
import { DesignTokens } from '../../common/DesignTokens';

/**
 * 表单校验(纯;单测靶):返回 '' = 合法,否则错误文案(UI 直接展示)。
 * 规则:名称非空;类型白名单 ssh|telnet;主机非空;端口 1..65535。
 */
export function connFormValid(name: string, type: string, host: string, port: number): string {
  if (name.trim().length === 0) {
    return '名称不能为空'
  }
  if (type !== 'ssh' && type !== 'telnet') {
    return '类型仅支持 ssh / telnet'
  }
  if (host.trim().length === 0) {
    return '主机不能为空'
  }
  if (!(port >= 1 && port <= 65535)) {
    return '端口需在 1-65535'
  }
  return ''
}

/** 类型默认端口(纯;单测靶):telnet 23,其余(含 ssh)22。 */
export function defaultPortFor(type: string): number {
  return type === 'telnet' ? 23 : 22
}

/** 收藏置顶排序(纯;单测靶):favorite 在前,同组保持原序(稳定)。 */
export function favoriteFirst(list: ConnRec[]): ConnRec[] {
  const fav: ConnRec[] = []
  const rest: ConnRec[] = []
  for (const it of list) {
    if (it.favorite) {
      fav.push(it)
    } else {
      rest.push(it)
    }
  }
  const out: ConnRec[] = []
  for (const f of fav) {
    out.push(f)
  }
  for (const r of rest) {
    out.push(r)
  }
  return out
}

/** 表单字段集(dialog 与面板间的传参载体;纯数据)。 */
export class ConnFormValues {
  id: string = ''
  name: string = ''
  type: string = 'ssh'
  host: string = ''
  port: number = 22
  user: string = ''
  pass: string = ''
}

@CustomDialog
struct ConnFormDialog {
  controller?: CustomDialogController
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  @State vName: string = ''
  @State vType: string = 'ssh'
  @State vHost: string = ''
  @State vPort: string = '22'
  @State vUser: string = ''
  @State vPass: string = ''
  @State formErr: string = ''
  title: string = '新建连接'
  init: ConnFormValues = new ConnFormValues()
  themeName: string = 'dark'
  onSave: (v: ConnFormValues) => string = () => ''
  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    this.vName = this.init.name
    this.vType = this.init.type
    this.vHost = this.init.host
    this.vPort = this.init.port.toString()
    this.vUser = this.init.user
    this.vPass = this.init.pass
  }

  private submit(): void {
    const err = connFormValid(this.vName, this.vType, this.vHost, Number(this.vPort))
    if (err !== '') {
      this.formErr = err
      return
    }
    const out = new ConnFormValues()
    out.id = this.init.id
    out.name = this.vName.trim()
    out.type = this.vType
    out.host = this.vHost.trim()
    out.port = Number(this.vPort)
    out.user = this.vUser.trim()
    out.pass = this.vPass
    const saveErr = this.onSave(out)
    if (saveErr !== '') {
      this.formErr = '保存失败:' + saveErr.substring(0, 40)
      return
    }
    this.controller?.close()
  }

  build() {
    Column({ space: DesignTokens.SPACE_SM }) {
      Text(tr(this.locale, this.title))
        .fontSize(DesignTokens.FONT_HEADING)
        .fontColor(this.th().ink)
        .padding({ top: DesignTokens.SPACE_MD, bottom: DesignTokens.SPACE_SM })
      Text(tr(this.locale, 'conn.save'))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().surface)
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().brand)
        .onClick(() => this.submit())
      Scroll() {
        Column() {
          Text(tr(this.locale, 'conn.f.name'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          TextInput({ text: this.vName, placeholder: tr(this.locale, 'conn.ph.name') })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().panel)
            .width('100%')
            .defaultFocus(true) // dialog 打开即聚焦名称字段——否则键盘焦点
            // 漏给下层 web 终端(用户在表单打的字会进 ttyd 会话,实勘)
            .onChange((x: string) => {
              this.vName = x
            })
          Text(tr(this.locale, 'conn.f.type'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          Row({ space: DesignTokens.SPACE_SM }) {
            Text('SSH')
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.vType === 'ssh' ? this.th().surface : this.th().inkSubtle)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.vType === 'ssh' ? this.th().brand : this.th().hover)
              .onClick(() => {
                this.vType = 'ssh'
                this.vPort = defaultPortFor('ssh').toString()
              })
            Text('Telnet')
              .fontSize(DesignTokens.FONT_LABEL)
              .fontColor(this.vType === 'telnet' ? this.th().surface : this.th().inkSubtle)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .borderRadius(DesignTokens.RADIUS_MD)
              .backgroundColor(this.vType === 'telnet' ? this.th().brand : this.th().hover)
              .onClick(() => {
                this.vType = 'telnet'
                this.vPort = defaultPortFor('telnet').toString()
              })
          }
          .alignItems(VerticalAlign.Center)
          .width('100%')
          Text(tr(this.locale, 'conn.f.host'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          TextInput({ text: this.vHost, placeholder: tr(this.locale, 'conn.ph.host') })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().panel)
            .width('100%')
            .onChange((x: string) => {
              this.vHost = x
            })
          Text(tr(this.locale, 'conn.f.port'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          TextInput({ text: this.vPort, placeholder: '22' })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().panel)
            .width('100%')
            .type(InputType.Number)
            .onChange((x: string) => {
              this.vPort = x
            })
          Text(tr(this.locale, 'conn.f.user'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          TextInput({ text: this.vUser, placeholder: 'root' })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().panel)
            .width('100%')
            .onChange((x: string) => {
              this.vUser = x
            })
          Text(tr(this.locale, 'conn.f.pass'))
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ top: DesignTokens.SPACE_SM, bottom: 2 })
          TextInput({ text: this.vPass, placeholder: '' })
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().panel)
            .width('100%')
            .type(InputType.Password)
            .onChange((x: string) => {
              this.vPass = x
            })
          if (this.formErr !== '') {
            Text(this.formErr)
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor('#e5534b')
              .padding({ top: 4 })
          }
          Text(tr(this.locale, 'conn.cancel'))
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.th().inkSubtle)
            .padding({ left: 14, right: 14, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().hover)
            .margin({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_MD })
            .onClick(() => {
              this.controller?.close()
            })
        }
        .width('90%')
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
    }
    .width('92%')
    .height('85%')
    .backgroundColor(this.th().panel)
    .borderRadius(DesignTokens.RADIUS_LG)
  }
}

@Component
export struct ConnManagePanel {
  @ObjectLink vm: WorkbenchVm
  @Prop themeName: string = 'dark'
  @StorageProp('ut.locale') locale: string = 'zh-CN'
  /** 列表快照(aboutToAppear/保存后刷新)。 */
  @State conns: ConnRec[] = []
  /** 删除确认态:待删档案 id;'' = 无。 */
  @State deleting: string = ''
  @State hint: string = ''
  private dialogController: CustomDialogController = new CustomDialogController({
    builder: ConnFormDialog({
      title: 'conn.dlg.new',
      init: new ConnFormValues(),
      onSave: (v: ConnFormValues): string => this.saveFromForm(v)
    }),
    autoCancel: false,
    customStyle: true
  })

  private th(): AppTheme {
    return themeByName(this.themeName)
  }

  aboutToAppear(): void {
    this.reload()
  }

  private reload(): void {
    let store = getSharedStore()
    if (store === null) {
      ensureSharedStore() // 惰性引导(同 session.new.ssh 2026-10-11 热修)
      store = getSharedStore() // 引导后必须重取——否则首挂载恒空列表(load #1 实勘)
      if (store === null) {
        this.conns = []
        return
      }
    }
    this.conns = favoriteFirst(store.connections.slice())
  }

  /** dialog 保存回调:落 store + 刷新;返回 ''=成功(错误文案回显 dialog)。 */
  private saveFromForm(v: ConnFormValues): string {
    const store = getSharedStore()
    if (store === null) {
      return '连接库未就绪'
    }
    const rec = new ConnRec()
    rec.type = v.type
    rec.port = v.port
    if (v.id !== '') {
      const old = store.connections.find((c: ConnRec): boolean => c.id === v.id)
      if (old !== undefined) {
        // 保留不可编辑字段(收藏/分组/隧道等旧界面语义字段)
        rec.id = old.id
        rec.groupId = old.groupId
        rec.favorite = old.favorite
        rec.lastUsedAt = old.lastUsedAt
        rec.authType = old.authType
        rec.identityId = old.identityId
        rec.password = old.password
        rec.keyPath = old.keyPath
        rec.keyContent = old.keyContent
        rec.encoding = old.encoding
        rec.backspaceKey = old.backspaceKey
        rec.keepaliveSec = old.keepaliveSec
        rec.initialShell = old.initialShell
        rec.postLoginScript = old.postLoginScript
        rec.remark = old.remark
      }
    }
    rec.name = v.name
    rec.host = v.host
    rec.user = v.user
    if (v.pass.length > 0) {
      rec.password = v.pass // 留空=不改;非空覆盖(save 加密落盘)
    }
    store.upsertConn(rec)
    // save() 语义:成功返回序列化 JSON(非空),失败返回 ''(ConnStore.ets:454)
    const saved = store.save()
    if (saved === '') {
      return '写入磁盘失败'
    }
    this.reload()
    this.hint = '已保存 ' + rec.name
    return ''
  }

  private openForm(title: string, init: ConnFormValues): void {
    // V1 惯用法:builder 闭包持旧参——重开前重建 controller 换参
    this.dialogController = new CustomDialogController({
      builder: ConnFormDialog({
        title: title,
        init: init,
        themeName: this.themeName,
        onSave: (v: ConnFormValues): string => this.saveFromForm(v)
      }),
      autoCancel: false,
      customStyle: true
    })
    this.dialogController.open()
  }

  private startNew(): void {
    this.openForm('conn.dlg.new', new ConnFormValues())
  }

  private startEdit(rec: ConnRec): void {
    const v = new ConnFormValues()
    v.id = rec.id
    v.name = rec.name
    v.type = rec.type
    v.host = rec.host
    v.port = rec.port
    v.user = rec.user
    this.openForm('conn.dlg.edit', v)
  }

  private doDelete(): void {
    const store = getSharedStore()
    if (store !== null) {
      store.deleteConn(this.deleting)
      store.save()
    }
    this.deleting = ''
    this.reload()
  }

  private connect(rec: ConnRec): void {
    if (rec.type === 'telnet') {
      // LEG-2: telnet 通路已接(异步连接,状态栏反馈)
      this.hint = this.vm.bindTelnetSession(rec.id) ? '已发起 telnet 连接 ' + rec.name : '连接发起失败'
      return
    }
    this.hint = this.vm.bindSshSession(rec.id) ? '已发起连接 ' + rec.name : '连接发起失败'
  }

  /** LEG-3a: 切换收藏(落盘+刷新置顶排序)。 */
  private toggleFav(rec: ConnRec): void {
    const store = getSharedStore()
    if (store === null) {
      return
    }
    const hit = store.connections.find((c: ConnRec): boolean => c.id === rec.id)
    if (hit === undefined) {
      return
    }
    hit.favorite = !hit.favorite
    store.save()
    this.reload()
  }

  @Builder
  private recRow(rec: ConnRec) {
    Row({ space: DesignTokens.SPACE_SM }) {
      Column({ space: 2 }) {
        Text(rec.name !== '' ? rec.name : rec.id)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .maxLines(1)
        Text(rec.type + ' · ' + rec.user + '@' + rec.host + ':' + rec.port.toString())
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // LEG-3a: 收藏星标(置顶排序;★实/☆虚)
      Text(rec.favorite ? '★' : '☆')
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor(rec.favorite ? '#e3b341' : this.th().inkSubtle)
        .onClick(() => this.toggleFav(rec))
      Text(tr(this.locale, 'conn.row.connect'))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().surface)
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().brand) // ssh/telnet 均可连(LEG-2)
        .onClick(() => this.connect(rec))
      Text(tr(this.locale, 'conn.row.edit'))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().inkSubtle)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().hover)
        .onClick(() => this.startEdit(rec))
      Text(tr(this.locale, 'conn.row.del'))
        .fontSize(DesignTokens.FONT_LABEL)
        .fontColor(this.th().inkSubtle)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().hover)
        .onClick(() => {
          this.deleting = rec.id
        })
    }
    .width('100%')
    .padding({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
  }

  build() {
    Column({ space: DesignTokens.SPACE_SM }) {
      if (this.hint !== '') {
        Text(this.hint)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().inkSubtle)
          .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD, top: DesignTokens.SPACE_XS })
          .onClick(() => {
            this.hint = ''
          })
      }
      Scroll() {
        Column() {
          if (this.conns.length === 0) {
            Text(tr(this.locale, 'conn.empty'))
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
              .padding(DesignTokens.SPACE_MD)
          }
          ForEach(this.conns, (rec: ConnRec) => {
            if (this.deleting === rec.id) {
              Column({ space: DesignTokens.SPACE_XS }) {
                Text(tr(this.locale, 'conn.del.confirm') + (rec.name !== '' ? rec.name : rec.id) + tr(this.locale, 'conn.del.confirm2'))
                  .fontSize(DesignTokens.FONT_BODY)
                  .fontColor(this.th().ink)
                Row({ space: DesignTokens.SPACE_MD }) {
                  Text(tr(this.locale, 'conn.del.ok'))
                    .fontSize(DesignTokens.FONT_LABEL)
                    .fontColor('#e5534b')
                    .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                    .borderRadius(DesignTokens.RADIUS_MD)
                    .backgroundColor(this.th().hover)
                    .onClick(() => this.doDelete())
                  Text(tr(this.locale, 'conn.cancel'))
                    .fontSize(DesignTokens.FONT_LABEL)
                    .fontColor(this.th().inkSubtle)
                    .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                    .borderRadius(DesignTokens.RADIUS_MD)
                    .backgroundColor(this.th().hover)
                    .onClick(() => {
                      this.deleting = ''
                    })
                }
              }
              .width('100%')
              .padding({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_SM })
            } else {
              this.recRow(rec)
            }
          }, (rec: ConnRec) => rec.id + ':' + (rec.favorite ? '1' : '0')) // 收藏态入键:favorite 翻转驱动行重建(V1 键不变不刷新)
          Text(tr(this.locale, 'conn.new'))
            .fontSize(DesignTokens.FONT_LABEL)
            .fontColor(this.th().surface)
            .padding({ left: 14, right: 14, top: 5, bottom: 5 })
            .borderRadius(DesignTokens.RADIUS_MD)
            .backgroundColor(this.th().brand)
            .margin({ top: DesignTokens.SPACE_SM, bottom: DesignTokens.SPACE_MD })
            .onClick(() => this.startNew())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: DesignTokens.SPACE_MD, right: DesignTokens.SPACE_MD })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
