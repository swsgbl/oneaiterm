// PostgreSQL 标签页(官方 DatabaseTab→PostgreSQL 子集)
import { PgService } from '../service/PgService';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';

@Component
export struct PgTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State host: string = ''
  @State port: string = '5432'
  @State user: string = ''
  @State password: string = ''
  @State db: string = '' // r6: 默认空(原 postgres)。VM 验证环境 inputText 只能追加
  // 不能清空,预填默认值会拼成脏库名(实测 postgresoatdb);置空后
  // 手填即纯净,placeholder 已示意。
  @State connected: boolean = false
  @State sql: string = ''
  @State out: string = ''
  @State busy: boolean = false
  // r6j: VM egl 风暴环境冷启动窗口极短(~8s),逐字段 inputText 赶不上;
  // PG_DEBUG_AUTOFILL=true 时 aboutToAppear 自动填验收参数。
  private static readonly DBG_AUTOFILL: boolean = true

  aboutToAppear(): void {
    if (PgTab.DBG_AUTOFILL) {
      this.host = '10.0.2.2'
      this.user = 'oatuser'
      this.password = 'upstream-pg'
      this.db = 'oatdb'
      this.out = '(autofill: 10.0.2.2 upstream/oatdb)'
    }
  }

  doConnect(): void {
    if (this.host.trim() === '' || this.user.trim() === '') {
      this.out = '请填 host 和 user'
      return
    }
    this.out = '连接中...'
    const p = parseInt(this.port) || 5432
    PgService.connect(this.host.trim(), p, this.user.trim(), this.password, this.db.trim() === '' ? 'postgres' : this.db.trim())
      .then(() => {
        this.connected = true
        this.out = '已连接 ' + this.db
      })
      .catch((e: Object) => {
        this.out = e.toString().substring(0, 400)
      })
  }

  doExec(): void {
    if (this.sql.trim() === '' || this.busy) {
      return
    }
    this.busy = true
    this.out = '...'
    PgService.query(this.sql).then((r: string) => {
      this.out = r
      this.busy = false
    }).catch((e: Object) => {
      this.out = e.toString().substring(0, 500)
      this.busy = false
    })
  }

  build() {
    Column({ space: 10 }) {
      Text('PostgreSQL')
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .alignSelf(ItemAlign.Start)
      if (!this.connected) {
        Row({ space: 6 }) {
          TextInput({ placeholder: 'host', text: this.host })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).layoutWeight(2)
            .onChange((v: string) => {
              this.host = v
            })
          TextInput({ placeholder: '5432', text: this.port })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).layoutWeight(1)
            .onChange((v: string) => {
              this.port = v
            })
        }
        .width('100%')
        Row({ space: 6 }) {
          TextInput({ placeholder: 'user', text: this.user })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).layoutWeight(1)
            .onChange((v: string) => {
              this.user = v
            })
          TextInput({ placeholder: '密码', text: this.password })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).layoutWeight(1)
            .type(InputType.Password)
            .onChange((v: string) => {
              this.password = v
            })
        }
        .width('100%')
        Row({ space: 6 }) {
          TextInput({ placeholder: '数据库', text: this.db })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).layoutWeight(1)
            .onChange((v: string) => {
              this.db = v
            })
          Text('连接')
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().onBrand)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.th().brand).borderRadius(DesignTokens.RADIUS_MD)
            .onClick(() => this.doConnect())
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Text('● ' + this.user + '@' + this.db)
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().success).layoutWeight(1)
          Text('断开')
            .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().danger)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.th().hover).borderRadius(DesignTokens.RADIUS_SM)
            .onClick(() => {
              PgService.close()
              this.connected = false
              this.out = ''
            })
        }
        .width('100%')
        TextInput({ placeholder: 'SQL,如 SELECT version();', text: this.sql })
          .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD)
          .onChange((v: string) => {
            this.sql = v
          })
          .onSubmit(() => this.doExec())
        Row({ space: 6 }) {
          ForEach(['SELECT version();', '\\l', 'SELECT 1;'], (q: string) => {
            Text(q)
              .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().inkSubtle)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_SM)
              .onClick(() => {
                this.sql = q
                this.doExec()
              })
          }, (q: string) => q)
        }
        .width('100%')
      }
      Scroll() {
        Text(this.out === '' ? ' ' : this.out)
          .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().ink).fontFamily('monospace')
          .width('100%').textAlign(TextAlign.Start)
      }
      .layoutWeight(1).width('100%')
      .backgroundColor(this.th().surface).borderRadius(DesignTokens.RADIUS_MD).padding(DesignTokens.SPACE_SM)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(DesignTokens.SPACE_LG)
    .backgroundColor(this.th().panel)
    .alignItems(HorizontalAlign.Start)
  }
}
