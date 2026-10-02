import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { WantParams } from '../common/WantParams';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'hmh', '%{public}s', 'EntryAbility onCreate');
    WantParams.setWant(want);
    // M5 parity: publish the app sandbox root for SidePanels/FileSidebar rawfile access
    AppStorage.setOrCreate('ut.filesDir', this.context.filesDir);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    WantParams.setWant(want);
  }

  onDestroy(): void {}

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'hmh', 'Failed to load content: %{public}s', err instanceof Error ? err.message : String(err));
        return;
      }
    });
  }

  onWindowStageDestroy(): void {}
  onForeground(): void {}
  onBackground(): void {}
}
