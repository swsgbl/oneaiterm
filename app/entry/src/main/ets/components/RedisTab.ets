// Redis 标签页(官方 DatabaseTab→Redis 子集):连接 + 命令执行
import { RedisService } from '../service/RedisService';
import { AppTheme, themeByName } from '../common/AppTheme';

@Component
export struct RedisTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State host: string = ''
  @State port: string = '6379'
  @State connected: boolean = false
  @State cmd: string = ''
  @State out: string = ''
  @State busy: boolean = false

  doConnect(): void {
    if (this.host.trim() === '') {
      this.out = '请填 host'
      return
    }
    const p = parseInt(this.port) || 6379
    RedisService.connect(this.host.trim(), p).then(() => {
      this.connected = true
      this.out = '已连接 ' + this.host + ':' + this.port
    }).catch((e: Object) => {
      this.out = '连接失败: ' + e.toString().substring(0, 200)
    })
  }

  doExec(): void {
    if (this.cmd.trim() === '' || this.busy) {
      return
    }
    this.busy = true
    this.out = '...'
    RedisService.exec(this.cmd).then((r: string) => {
      this.out = r
      this.busy = false
    }).catch((e: Object) => {
      this.out = e.toString().substring(0, 500)
      this.busy = false
    })
  }

  build() {
    Column({ space: 10 }) {
      Text('Redis')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .alignSelf(ItemAlign.Start)
      if (!this.connected) {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'host', text: this.host })
            .fontSize(12)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().inputBg)
            .borderRadius(6)
            .layoutWeight(2)
            .onChange((v: string) => {
              this.host = v
            })
          TextInput({ placeholder: '端口', text: this.port })
            .fontSize(12)
            .fontColor(this.th().ink)
            .backgroundColor(this.th().inputBg)
            .borderRadius(6)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.port = v
            })
          Text('连接')
            .fontSize(12)
            .fontColor(0xffffff)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.th().brand)
            .borderRadius(6)
            .onClick(() => this.doConnect())
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Text('● ' + this.host + ':' + this.port)
            .fontSize(12)
            .fontColor(this.th().success)
            .layoutWeight(1)
          Text('断开')
            .fontSize(11)
            .fontColor(this.th().danger)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.th().hover)
            .borderRadius(4)
            .onClick(() => {
              RedisService.close()
              this.connected = false
              this.out = ''
            })
        }
        .width('100%')
        TextInput({ placeholder: '命令,如 PING / INFO / KEYS *', text: this.cmd })
          .fontSize(12)
          .fontColor(this.th().ink)
          .backgroundColor(this.th().inputBg)
          .borderRadius(6)
          .onChange((v: string) => {
            this.cmd = v
          })
          .onSubmit(() => this.doExec())
        Row({ space: 6 }) {
          ForEach(['PING', 'INFO server', 'DBSIZE', 'GET upstream:key'], (q: string) => {
            Text(q)
              .fontSize(10)
              .fontColor(this.th().inkSubtle)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.th().inputBg)
              .borderRadius(4)
              .onClick(() => {
                this.cmd = q
                this.doExec()
              })
          }, (q: string) => q)
        }
        .width('100%')
      }
      Scroll() {
        Text(this.out === '' ? ' ' : this.out)
          .fontSize(11)
          .fontColor(this.th().ink)
          .fontFamily('monospace')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(this.th().surface)
      .borderRadius(6)
      .padding(8)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor(this.th().panel)
    .alignItems(HorizontalAlign.Start)
  }
}
