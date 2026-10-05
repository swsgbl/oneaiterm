// M8-relay8 U2 probe: guaranteed-fail assertion injected at the END of
// the real suite chain, so the aa-test client must observe
// TestFinished-ResultCode: -2 (failures present) and gate-unit.cmd's
// FAIL branch must trigger. This file is ONLY synced by the U2 check
// (gate-unit.cmd -u2); the normal chain never installs it.
import { describe, it, expect } from '@ohos/hypium';

export default function u2CanaryTest() {
  describe('u2CanarySuite', () => {
    it('deliberate_fail_probe', 0, () => {
      expect(true).assertFalse();
    });
  });
}
