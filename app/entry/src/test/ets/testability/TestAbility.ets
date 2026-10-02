import testsuite from '../List.test.ets';

@Entry
@Component
struct TestAbility {
  @State message: string = 'TestAbility'

  build() {
    Column() {
      Text(this.message)
        .fontSize(20)
    }
    .width('100%')
    .height('100%')
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    testsuite()
    windowStage.loadUIContent(this.context, 'pages/Index', (err) => {})
  }
}