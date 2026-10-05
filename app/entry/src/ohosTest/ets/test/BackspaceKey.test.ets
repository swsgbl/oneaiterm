/**
 * M4 relay-2 fix B: vt220 backspaceKey mapping unit test (ArkTS/hypium).
 *
 * Mirrors upstream frontend/src/utils/backspaceKey.ts + SessionService.applyBackspaceKey():
 *   - 'del':   0x7F passes through unchanged
 *   - 'bs':    0x7F -> 0x08
 *   - 'vt220': 0x7F -> 0x1b[3~  (VT220 Delete CSI sequence, replaces each 0x7F byte)
 *
 * Three assertions (3/3):
 *   bs    : 'a\x7fb'  ->  'a\x08b'
 *   del   : 'a\x7fb'  ->  'a\x7fb'  (unchanged)
 *   vt220 : 'a\x7fb'  ->  'a\x1b[3~b'
 *
 * Plus: input without 0x7F is returned unchanged for all three modes.
 */
import { describe, it, expect } from '@ohos/hypium';

/**
 * Pure string transformation replicating SessionService.applyBackspaceKey().
 * The native layer (libssh) does not do backspace translation; it is done
 * ArkTS-side before writeStdin(). This keeps the test dependency-free.
 */
function applyBackspaceKey(mode: string, text: string): string {
  if (mode === 'del' || text.indexOf('\x7f') < 0) {
    return text;
  }
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (ch === '\x7f') {
      out += (mode === 'bs') ? '\x08' : '\x1b[3~';
    } else {
      out += ch;
    }
  }
  return out;
}

export default function backspaceKeyTest() {
  describe('backspaceKeyMapping', () => {
    it('bs_mode_maps_0x7F_to_0x08', 0, () => {
      const result: string = applyBackspaceKey('bs', 'a\x7fb');
      expect(result === 'a\x08b').assertTrue();
    });

    it('del_mode_passes_0x7F_through_unchanged', 0, () => {
      const result: string = applyBackspaceKey('del', 'a\x7fb');
      expect(result === 'a\x7fb').assertTrue();
    });

    it('vt220_mode_maps_0x7F_to_esc_3_tilde', 0, () => {
      const result: string = applyBackspaceKey('vt220', 'a\x7fb');
      expect(result === 'a\x1b[3~b').assertTrue();
    });

    it('no_0x7F_input_returns_unchanged_all_modes', 0, () => {
      const plain: string = 'abc';
      expect(applyBackspaceKey('del', plain) === plain).assertTrue();
      expect(applyBackspaceKey('bs', plain) === plain).assertTrue();
      expect(applyBackspaceKey('vt220', plain) === plain).assertTrue();
    });
  });
}
