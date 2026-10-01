// VNC 标签页:连接表单 + PixelMap 远程桌面 + 键鼠注入
import { VncClient } from '../service/VncClient';
import { hilog } from '@kit.PerformanceAnalysisKit';
import image from '@ohos.multimedia.image';
import { AppTheme, themeByName } from '../common/AppTheme';

const VNC_TAG: string = 'oat.vnc';
const VNC_DOMAIN: number = 0x0110;

@Component
export struct VncTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State host: string = '10.0.2.2'
  @State port: string = '5900'
  @State st: string = 'idle' // idle connecting running error closed
  @State errText: string = ''
  @State frameTick: number = 0
  @State viewPm: image.PixelMap | null = null
  private vnc: VncClient = new VncClient()
  private lastPtX: number = -1
  private lastPtY: number = -1
  private lastPaintFrame: number = -1
  private lastPaintMs: number = 0

  aboutToDisappear(): void {
    this.vnc.close()
  }

  doConnect(): void {
    const h = this.host.trim()
    const p = parseInt(this.port) || 5900
    if (h === '') {
      this.errText = '请输入主机地址'
      return
    }
    this.st = 'connecting'
    this.errText = ''
    hilog.info(VNC_DOMAIN, VNC_TAG, 'tab connect requested host=%{public}s port=%{public}s', h, this.port);
    this.vnc.onUpdate = (): void => {
      this.frameTick++
    }
    this.vnc.connect(h, p).then(() => {
      // 状态由状态机推进
    }).catch((e: Object) => {
      this.st = 'error'
      this.errText = e.toString().substring(0, 200)
      hilog.error(VNC_DOMAIN, VNC_TAG, 'connect failed: %{public}s', e.toString().substring(0, 100));
    })
    // 轮询状态
    let lastPaintLog = 0
    setInterval(() => {
      const s = this.vnc.status()
      if (s === 'running' && this.st !== 'running') {
        this.st = 'running'
        hilog.info(VNC_DOMAIN, VNC_TAG, 'session running, frames=%{public}d', this.frameTick);
      } else if ((s === 'error' || s === 'closed') && this.st === 'running') {
        this.st = s
      }
      // M5 relay5 fix: 节流重建 PixelMap 引用触发 Image 重绘(500ms/次或帧号变化)
      const now = Date.now()
      if (s === 'running' && now - this.lastPaintMs > 500) {
        this.lastPaintMs = now
        this.viewPm = this.vnc.snapshotPm()
        if (this.frameTick !== this.lastPaintFrame) {
          this.lastPaintFrame = this.frameTick
          if (now - lastPaintLog > 5000) {
            lastPaintLog = now
            hilog.info(VNC_DOMAIN, VNC_TAG, 'view repaint tick frames=%{public}d', this.frameTick);
          }
        }
      }
    }, 500)
  }

  @Builder
  FormPane() {
    Column({ space: 12 }) {
      Blank()
      Text('🖥')
        .fontSize(40)
      Text('VNC 远程桌面')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.th().ink)
      Text('RFB 3.8 · 纯 TS 协议栈 · raw 编码')
        .fontSize(11)
        .fontColor(this.th().inkSubtle)
      TextInput({ placeholder: '主机 (如 192.168.1.10)', text: this.host })
        .fontSize(13)
        .fontColor(this.th().ink)
        .backgroundColor(this.th().inputBg)
        .borderRadius(6)
        .width(260)
        .onChange((v: string) => {
          this.host = v
        })
      TextInput({ placeholder: '端口 (默认 5900)', text: this.port })
        .fontSize(13)
        .fontColor(this.th().ink)
        .backgroundColor(this.th().inputBg)
        .borderRadius(6)
        .width(260)
        .type(InputType.Number)
        .onChange((v: string) => {
          this.port = v
        })
      Text('连接')
        .fontSize(14)
        .fontColor(this.th().surface)
        .fontWeight(FontWeight.Bold)
        .padding({ left: 28, right: 28, top: 9, bottom: 9 })
        .backgroundColor(this.th().brand)
        .borderRadius(6)
        .onClick(() => this.doConnect())
      if (this.errText !== '') {
        Text(this.errText)
          .fontSize(11)
          .fontColor(this.th().danger)
          .padding(6)
      }
      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
  }

  build() {
    Column() {
      if (this.st === 'idle' || this.st === 'error') {
        this.FormPane()
      } else if (this.st === 'connecting') {
        Column({ space: 10 }) {
          Blank()
          LoadingProgress().width(40).height(40).color(this.th().brand)
          Text('正在建立 RFB 会话…')
            .fontSize(13)
            .fontColor(this.th().inkSubtle)
          Blank()
        }
        .width('100%')
        .height('100%')
      } else {
        // 远程桌面视口:PixelMap + 缩放适配 + 键鼠
        Column() {
          Row() {
            Text('VNC ' + this.host + ':' + this.port)
              .fontSize(12)
              .fontColor(this.th().ink)
            Blank()
            Text(this.vnc.width().toString() + 'x' + this.vnc.height().toString() + '  #' + this.frameTick.toString())
              .fontSize(11)
              .fontColor(this.th().inkSubtle)
            Text('断开')
              .fontSize(11)
              .fontColor(this.th().danger)
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                this.vnc.close()
                this.st = 'idle'
              })
          }
          .width('100%')
          .padding(8)
          .backgroundColor(this.th().panel)
          if (this.viewPm !== null) {
            Image(this.viewPm)
              .objectFit(ImageFit.Contain)
              .layoutWeight(1)
              .width('100%')
              .interpolation(ImageInterpolation.None)
              .onTouch((e: TouchEvent) => this.handleTouch(e))
          } else {
            Column() {
              LoadingProgress().width(30).height(30).color(this.th().brand)
              Text('等待首帧…')
                .fontSize(11)
                .fontColor(this.th().inkSubtle)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  private handleTouch(e: TouchEvent): void {
    // 触摸 → VNC 鼠标(左键拖动 = 移动+按下)
    if (e.type === TouchType.Move || e.type === TouchType.Down || e.type === TouchType.Up) {
      const t = e.touches[0]
      const tm = this.vnc.pixelMap()
      if (tm === null) {
        return
      }
      // Image objectFit Contain 的坐标换算(假设近似铺满,按比例)
      const dx = t.x
      const dy = t.y
      const sx = Math.min(this.vnc.width() - 1, Math.max(0, Math.round(dx)))
      const sy = Math.min(this.vnc.height() - 1, Math.max(0, Math.round(dy)))
      const mask = e.type === TouchType.Up ? 0 : 1 // 左键
      this.vnc.sendPointer(sx, sy, mask)
      this.lastPtX = sx
      this.lastPtY = sy
    }
  }
}
