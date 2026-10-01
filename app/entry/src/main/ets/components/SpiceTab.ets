// SPICE 标签页(连接 + 状态显示;帧渲染管线后续棒)
import { SpiceClient } from '../service/SpiceClient';
import { AppTheme, themeByName } from '../common/AppTheme';

@Component
export struct SpiceTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State host: string = ''
  @State port: string = '5900'
  @State password: string = ''
  @State st: string = 'idle'
  @State errText: string = ''
  private cli: SpiceClient | null = null

  aboutToDisappear(): void {
    if (this.cli !== null) {
      this.cli.close()
    }
  }

  doConnect(): void {
    if (this.host.trim() === '') {
      this.errText = '请填 host'
      return
    }
    this.errText = ''
    this.st = 'connecting'
    const c = new SpiceClient()
    this.cli = c
    c.onStatus = (s: string): void => {
      if (s.indexOf('surface') >= 0) {
        this.st = 'connected'
      }
      this.errText = s
    }
    c.connect(this.host.trim(), parseInt(this.port) || 5900, this.password).catch((e: Object) => {
      this.st = 'error'
      this.errText = e.toString().substring(0, 250)
    })
  }

  build() {
    Column({ space: 10 }) {
      if (this.st !== 'connected') {
        Text('SPICE')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().ink)
          .alignSelf(ItemAlign.Start)
        Row({ space: 6 }) {
          TextInput({ placeholder: 'host', text: this.host })
            .fontSize(12).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(6).layoutWeight(2)
            .onChange((v: string) => {
              this.host = v
            })
          TextInput({ placeholder: '端口', text: this.port })
            .fontSize(12).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(6).layoutWeight(1)
            .onChange((v: string) => {
              this.port = v
            })
        }
        .width('100%')
        Row({ space: 6 }) {
          TextInput({ placeholder: '密码(可空)', text: this.password })
            .fontSize(12).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(6).layoutWeight(1)
            .type(InputType.Password)
            .onChange((v: string) => {
              this.password = v
            })
          Text(this.st === 'connecting' ? '连接中…' : '连接')
            .fontSize(12).fontColor(0xffffff)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.th().brand).borderRadius(6)
            .onClick(() => this.doConnect())
        }
        .width('100%')
        Text(this.errText === '' ? ' ' : this.errText)
          .fontSize(11).fontColor(this.st === 'error' ? this.th().danger : this.th().inkSubtle)
          .width('100%')
      } else {
        Column({ space: 10 }) {
          Blank()
          Text('🌶')
            .fontSize(40)
          Text('SPICE 会话已建立')
            .fontSize(14)
            .fontColor(this.th().success)
          Text(this.errText)
            .fontSize(11)
            .fontColor(this.th().inkSubtle)
          Text('显示表面 ' + (this.cli !== null ? this.cli.width.toString() + 'x' + this.cli.height.toString() : '-'))
            .fontSize(12)
            .fontColor(this.th().ink)
          Text('断开')
            .fontSize(12).fontColor(this.th().danger)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(this.th().hover).borderRadius(6)
            .onClick(() => {
              if (this.cli !== null) {
                this.cli.close()
              }
              this.st = 'idle'
              this.errText = ''
            })
          Blank()
        }
        .width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor(this.th().panel)
    .alignItems(HorizontalAlign.Start)
  }
}
