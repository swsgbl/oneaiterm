import { rdpConnect, rdpDisconnect } from 'librdpproxy.so';
import image from '@ohos.multimedia.image';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';

const RDP_TAG: string = 'oat.rdp';
const RDP_DOMAIN: number = 0x0110;

@Component
export struct RdpTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State host: string = '10.0.2.2'
  @State port: string = '3389'
  @State user: string = 'Administrator'
  @State password: string = ''
  @State connected: boolean = false
  @State errText: string = ''
  @State pm: image.PixelMap | null = null
  @State fbW: number = 0
  @State fbH: number = 0
  private fb: Uint8Array | null = null
  private firstFrameLogged: boolean = false

  aboutToDisappear(): void {
    this.disconnect()
  }

  disconnect(): void {
    try {
      rdpDisconnect()
      hilog.info(RDP_DOMAIN, RDP_TAG, 'rdp disconnected');
    } catch (e) {
      hilog.error(RDP_DOMAIN, RDP_TAG, 'rdp disconnect err: %{public}s', (e instanceof Error ? e.message : String(e)).substring(0, 120));
    }
    this.connected = false
  }

  doConnect(): void {
    const h = this.host.trim()
    if (h === '') {
      this.errText = '请输入主机地址'
      return
    }
    this.errText = ''
    hilog.info(RDP_DOMAIN, RDP_TAG, 'rdp connect begin host=%{public}s port=%{public}s user=%{public}s', h, this.port, this.user);
    try {
      this.connected = true
      rdpConnect(h, parseInt(this.port) || 3389, this.user, this.password, 1024, 768,
        (x: number, y: number, w: number, h: number, ab: ArrayBuffer): void => {
          this.deliver(x, y, w, h, new Uint8Array(ab))
        })
    } catch (e) {
      this.connected = false
      this.errText = 'rdpproxy 加载失败: ' + (e instanceof Error ? e.message : String(e)).substring(0, 200)
      hilog.error(RDP_DOMAIN, RDP_TAG, 'rdp connect failed: %{public}s', (e instanceof Error ? e.message : String(e)).substring(0, 200));
    }
  }

  deliver(x: number, y: number, w: number, h: number, rgba: Uint8Array): void {
    if (this.fb === null || this.fbW * this.fbH < (y + h) * (x + w)) {
      // 首帧或 resize:分配全屏缓冲
      this.fbW = x + w
      this.fbH = y + h
      this.fb = new Uint8Array(this.fbW * this.fbH * 4)
    }
    // 贴矩形(首帧/尺寸变化打日志)
    if (!this.firstFrameLogged) {
      this.firstFrameLogged = true
      hilog.info(RDP_DOMAIN, RDP_TAG, 'first frame delivered w=%{public}d h=%{public}d', this.fbW, this.fbH);
    }
    for (let r = 0; r < h; r++) {
      const dOff = ((y + r) * this.fbW + x) * 4
      const sOff = r * w * 4
      for (let c = 0; c < w * 4; c++) {
        this.fb[dOff + c] = rgba[sOff + c]
      }
    }
    image.createPixelMap(this.fb.buffer, { size: { width: this.fbW, height: this.fbH } }).then((pm: image.PixelMap) => {
      this.pm = pm
    })
  }

  build() {
    Column() {
      if (!this.connected) {
        Column({ space: 12 }) {
          Blank()
          Text('🖥').fontSize(40)
          Text('RDP 远程桌面')
            .fontSize(DesignTokens.FONT_DISPLAY)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().ink)
          Text('FreerDP 3.9 · NAPI 桥 · x86_64')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
          TextInput({ placeholder: '主机 (如 192.168.1.10)', text: this.host })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).width(280)
            .onChange((v: string) => {
              this.host = v
            })
          TextInput({ placeholder: '端口 (默认 3389)', text: this.port })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).width(280)
            .type(InputType.Number)
            .onChange((v: string) => {
              this.port = v
            })
          TextInput({ placeholder: '用户名', text: this.user })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).width(280)
            .onChange((v: string) => {
              this.user = v
            })
          TextInput({ placeholder: '密码', text: this.password })
            .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink).backgroundColor(this.th().inputBg).borderRadius(DesignTokens.RADIUS_MD).width(280)
            .type(InputType.Password)
            .onChange((v: string) => {
              this.password = v
            })
          Text('连接')
            .fontSize(DesignTokens.FONT_HEADING).fontColor(this.th().onBrand).fontWeight(FontWeight.Bold)
            .padding({ left: 30, right: 30, top: 9, bottom: 9 })
            .backgroundColor(this.th().brand).borderRadius(DesignTokens.RADIUS_MD)
            .onClick(() => this.doConnect())
          if (this.errText !== '') {
            Text(this.errText).fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().danger).padding(DesignTokens.SPACE_SM)
          }
          Blank()
        }
        .width('100%').height('100%').backgroundColor(this.th().surface)
      } else {
        Column() {
          Row() {
            Text('RDP ' + this.host + ':' + this.port)
              .fontSize(DesignTokens.FONT_BODY).fontColor(this.th().ink)
            Blank()
            Text(this.fbW.toString() + 'x' + this.fbH.toString())
              .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().inkSubtle)
            Text('断开')
              .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().danger)
              .padding({ left: 8, right: 8 })
              .onClick(() => this.disconnect())
          }
          .width('100%').padding(DesignTokens.SPACE_SM).backgroundColor(this.th().panel)
          if (this.pm !== null) {
            Image(this.pm)
              .objectFit(ImageFit.Contain)
              .layoutWeight(1)
              .width('100%')
          } else {
            Column({ space: 8 }) {
              LoadingProgress().width(32).height(32).color(this.th().brand)
              Text('正在协商 RDP 连接…')
                .fontSize(DesignTokens.FONT_CAPTION).fontColor(this.th().inkSubtle)
            }
            .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          }
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }
}
