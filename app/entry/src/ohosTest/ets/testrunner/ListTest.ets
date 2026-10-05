import hilog from '@ohos.hilog';
import { Hypium } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import testsuite from '../test/List.test';

// M8-relay8: legacy TestRunner layout. `aa test -s unittest ListTest`
// (KaihongOS 5.0 / API14) loads <module>/ets/TestRunner/ListTest.abc and
// invokes its default export -- this file IS that entry. The hypium
// bootstrap mirrors the official TestAbility page pattern: fetch the
// delegator + args, then hand the testsuite to Hypium.hypiumTest.
export default function main() {
  hilog.info(0x0000, 'm8r8', '%{public}s', 'ListTest runner main() enter');
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const args = abilityDelegatorRegistry.getArguments();
  Hypium.hypiumTest(delegator, args, testsuite);
  hilog.info(0x0000, 'm8r8', '%{public}s', 'ListTest runner main() hypiumTest dispatched');
}
