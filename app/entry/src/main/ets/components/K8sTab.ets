// K8s 标签页(官方 K8sTab 子集):API server + Token → 资源列表
import { K8sService } from '../service/K8sService';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';

@Component
export struct K8sTab {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State server: string = ''
  @State token: string = ''
  @State configured: boolean = false
  @State resource: string = 'pods'
  @State ns: string = 'default'
  @State out: string = ''
  @State busy: boolean = false

  doConfigure(): void {
    if (this.server.trim() === '') {
      this.out = '请填 API server(如 https://1.2.3.4:6443)'
      return
    }
    K8sService.configure(this.server.trim(), this.token.trim())
    this.configured = true
    this.out = '已配置,选择资源后加载'
  }

  load(): void {
    if (this.busy) {
      return
    }
    const res = this.resource
    let path = ''
    if (res === 'namespaces') {
      path = '/api/v1/namespaces'
    } else if (res === 'nodes') {
      path = '/api/v1/nodes'
    } else if (res === 'pods') {
      path = '/api/v1/namespaces/' + this.ns + '/pods'
    } else if (res === 'deployments') {
      path = '/apis/apps/v1/namespaces/' + this.ns + '/deployments'
    } else if (res === 'services') {
      path = '/api/v1/namespaces/' + this.ns + '/services'
    }
    this.busy = true
    this.out = '加载中...'
    K8sService.get(path).then((json: string) => {
      const names = K8sService.namesOf(json)
      this.out = names.length.toString() + ' 个 ' + res + ':\n' + names.join('\n')
      this.busy = false
    }).catch((e: Object) => {
      this.out = e.toString().substring(0, 400)
      this.busy = false
    })
  }

  build() {
    Column({ space: 10 }) {
      Text('Kubernetes')
        .fontSize(DesignTokens.FONT_HEADING)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .alignSelf(ItemAlign.Start)
      if (!this.configured) {
        TextInput({ placeholder: 'API server(https://host:6443)', text: this.server })
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .backgroundColor(this.th().inputBg)
          .borderRadius(DesignTokens.RADIUS_MD)
          .onChange((v: string) => {
            this.server = v
          })
        TextInput({ placeholder: 'ServiceAccount Token', text: this.token })
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().ink)
          .backgroundColor(this.th().inputBg)
          .borderRadius(DesignTokens.RADIUS_MD)
          .type(InputType.Password)
          .onChange((v: string) => {
            this.token = v
          })
        Text('连接')
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().onBrand)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.th().brand)
          .borderRadius(DesignTokens.RADIUS_MD)
          .alignSelf(ItemAlign.Start)
          .onClick(() => this.doConfigure())
      } else {
        Row({ space: 6 }) {
          ForEach(['pods', 'deployments', 'services', 'namespaces', 'nodes'], (r: string) => {
            Text(r)
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.resource === r ? this.th().brand : this.th().inkSubtle)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.resource === r ? this.th().hover : this.th().inputBg)
              .borderRadius(DesignTokens.RADIUS_SM)
              .onClick(() => {
                this.resource = r
                this.load()
              })
          }, (r: string) => r)
          Blank()
          Text('↻')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(this.th().inkSubtle)
            .padding(DesignTokens.SPACE_XS)
            .onClick(() => this.load())
        }
        .width('100%')
        if (this.resource === 'pods' || this.resource === 'deployments' || this.resource === 'services') {
          Row({ space: 6 }) {
            Text('namespace')
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().inkSubtle)
            TextInput({ text: this.ns })
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor(this.th().ink)
              .backgroundColor(this.th().inputBg)
              .borderRadius(DesignTokens.RADIUS_SM)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.ns = v
              })
          }
          .width('100%')
        }
      }
      Scroll() {
        Text(this.out === '' ? ' ' : this.out)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().ink)
          .fontFamily('monospace')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(this.th().surface)
      .borderRadius(DesignTokens.RADIUS_MD)
      .padding(DesignTokens.SPACE_SM)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding(DesignTokens.SPACE_LG)
    .backgroundColor(this.th().panel)
    .alignItems(HorizontalAlign.Start)
  }
}
