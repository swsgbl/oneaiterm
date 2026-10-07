/**
 * Holds the launch want so pages can read parameters (dev import channel:
 * `aa start -b com.oneaiterm.terminal -a EntryAbility --ps importText '<json>'`).
 * Single-instance ability keeps the last want; onNewWant overwrites.
 */
import { Want } from '@kit.AbilityKit';

export class WantParams {
  private static want: Want | null = null;

  static setWant(w: Want): void {
    WantParams.want = w;
  }

  /** M3 dev channel: --ps credSetup <pass> / credUnlock <pass>. */
  static getCredSetup(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['credSetup'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  static getCredUnlock(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['credUnlock'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  static getImportText(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['importText'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M3 relay-2 dev channel: --ps importEncText '<json>' + importEncPass <p>. */
  static getImportEncText(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['importEncText'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M3 relay-2 dev channel: --ps exportPass <p> (empty = plaintext). */
  static getExportPass(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['exportPass'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  static getImportEncPass(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['importEncPass'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M3 relay-2d dev channel: --ps identityParams '<json array of IdentityRec>'. */
  static getIdentityParams(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['identityParams'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M3-3a dev channel: --ps connectNow <connName> - auto-connect that row. */
  static getConnectNow(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['connectNow'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M8-relay14 dev channel: --ps agentPrompt <text> - open AI dock and auto-send. */
  static getAgentPrompt(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['agentPrompt'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M8 native-input dev channel: --ps termCmd <cmd> - write a command into the local PTY (terminal has no visible input row). */
  static getTermCmd(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['termCmd'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }

  /** M8-relay14 dev channel: --ps agentEngine <local|hmh|acp> - engine pill preselect. */
  static getAgentEngine(): string {
    const w = WantParams.want;
    if (w === null || w.parameters === undefined || w.parameters === null) {
      return '';
    }
    const v = w.parameters['agentEngine'];
    if (typeof v === 'string') {
      return v;
    }
    return '';
  }
}
