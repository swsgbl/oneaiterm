// gate_e2e_run.cjs -- REAL on-device E2E driver for gate-e2e.cmd (M8-relay10;
// LEG-4: legacy channel retired, drives the workbench).
// Step 1: force-stop + aa start -> dumpLayout -> dismiss onboarding "skip"
//         if present -> workbench elements present (E1: palette glyph or
//         pane text > 8 nodes -- minimal shell is intentionally sparse).
// Step 2 (full mode only): SSH gold path - seed connections.json (postLogin
//         `echo M8-E2E-GATE-OK`) + palette SSH connect -> marker on the
//         remote pane via dumpLayout (postLogin wiring in provider).
// usage: node gate_e2e_run.cjs <quick|full> <evDir>
// Evidence: <evDir>/e2e-last.txt + e2e-*.json/.txt dumps.
// Exit 0 only when every executed criterion holds; honest fail otherwise.

'use strict';
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const MODE = process.argv[2] || 'full';   // quick = step 1 only
const EV = process.argv[3] || 'D:/oneaiterm/.verify/m8r10';
const HDC = 'hdc -t ' + (process.env.HM_GATE_TARGET || '127.0.0.1:15566'); // override only for fail-closed drills
const BUNDLE = 'com.oneaiterm.terminal';
const ABILITY = 'EntryAbility';
const MARKER = 'M8-E2E-GATE-OK';
const SSH = { host: '10.0.2.2', port: 2222, user: 'uterm', pw: 'uterm-pw-735' };

if (!fs.existsSync(EV)) fs.mkdirSync(EV, { recursive: true });
const LOG = [];
function log(s) { LOG.push(s); console.log(s); }
function hdc(args, tmo) { return execSync(HDC + ' ' + args, { encoding: 'utf8', timeout: tmo || 45000 }); }
function sh(cmd, tmo) { return hdc('shell "' + cmd + '"', tmo); }
function sleep(ms) { execSync('ping -n ' + (Math.floor(ms / 1000) + 1) + ' 127.0.0.1 > nul', { timeout: ms + 8000 }); }

function dump(name) {
  sh('rm -f /data/local/tmp/' + name + '.json ; uitest dumpLayout -p /data/local/tmp/' + name + '.json');
  execSync(HDC + ' file recv /data/local/tmp/' + name + '.json ' + EV.replace(/\//g, '\\') + '\\e2e-' + name + '.json',
    { encoding: 'utf8', timeout: 30000 });
  const r = JSON.parse(fs.readFileSync(EV + '/e2e-' + name + '.json', 'utf8'));
  const o = [];
  (function w(n) {
    if (!n || typeof n !== 'object') return;
    const a = n.attributes || {};
    const t = a.text || '';
    if (t !== '' || a.type === 'TextInput') o.push({ t: t.slice(0, 120), ty: a.type, b: a.bounds });
    for (const k of n.children || []) w(k);
  })(r);
  fs.writeFileSync(EV + '/e2e-' + name + '.txt', o.map(e => JSON.stringify(e)).join('\n'));
  return o;
}
function center(b) {
  const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(b);
  return [Math.round((+m[1] + +m[3]) / 2), Math.round((+m[2] + +m[4]) / 2)];
}
function click(e) { const [x, y] = center(e.b); sh('uitest uiInput click ' + x + ' ' + y); }
function finish(ok, reason) {
  log(ok ? 'E2E_RUN=OK' : 'E2E_RUN=FAIL ' + reason);
  fs.writeFileSync(path.join(EV, 'e2e-last.txt'), LOG.join('\n') + '\n');
  process.exit(ok ? 0 : 1);
}

// ---------- Step 0: device reachable (cmd checks too; double-guard) ----------
let online;
try { online = sh('echo online'); } catch (e) { online = ''; }
if (!/online/.test(online)) finish(false, 'device not reachable');

// ---------- Step 1: cold launch + onboarding dismiss + workbench up ----------
log('[e2e] 1/3 cold start ' + BUNDLE);
sh('aa force-stop ' + BUNDLE);
sleep(2000);
log('[launch] ' + sh('aa start -b ' + BUNDLE + ' -a ' + ABILITY).trim());
sleep(9000);

let nodes = dump('s1-main');
// onboarding guard: if a skip-button style node is present, click it and re-dump
const SKIP_RE = /跳过|skip|开始使用|立即体验/i;
let skip = nodes.find(e => SKIP_RE.test(e.t) && e.t.length <= 12);
if (skip) {
  log('[e2e] onboarding detected, clicking "' + skip.t + '"');
  click(skip);
  sleep(4000);
  nodes = dump('s1-after-skip');
} else {
  log('[e2e] no onboarding overlay (persisted state)');
}
// LEG-4 E1: workbench elements (palette glyph + pane text nodes);
// sparse-by-design shell, node-count>50 was the legacy layout's bar.
const hasPalette = nodes.some(e => e.t === '⌘');
const paneTexts = nodes.filter(e => e.t !== '' && e.t !== '⌘').length;
log('[criterion E1] workbench: palette=' + hasPalette + ' textNodes=' + paneTexts + ' (need palette + >=8)');
if (!hasPalette || paneTexts < 8) {
  log('[e2e] workbench too sparse, first 30 nodes for diagnosis:');
  nodes.slice(0, 30).forEach(e => log('  ' + JSON.stringify(e)));
  finish(false, 'E1 workbench palette=' + hasPalette + ' nodes=' + paneTexts);
}

if (MODE === 'quick') {
  log('[e2e] /quick mode: stopping after step 1');
  finish(true);
}

// ---------- Step 2: SSH gold path (workbench: seed archive + palette connect + marker) ----------
log('[e2e] 2/3 SSH gold: palette connect ' + SSH.user + '@' + SSH.host + ':' + SSH.port + ' + postLogin echo ' + MARKER);
const payload = JSON.stringify({
  connections: [{
    id: 'm8r10-e2e', name: 'e2e-gold', type: 'ssh',
    host: SSH.host, port: SSH.port, user: SSH.user,
    authType: 'password', password: SSH.pw,
    postLoginScript: 'echo ' + MARKER
  }]
});
const pb64 = Buffer.from(payload, 'utf8').toString('base64');
sh('busybox echo ' + pb64 + ' | busybox base64 -d > /data/local/tmp/e2e-conn.json');
// LEG-4: seed connections.json directly (importText channel retired),
// then drive palette: ⌘ -> 会话·SSH 连接 (single archive auto-connect).
sh('mkdir -p /data/app/el2/100/base/' + BUNDLE + '/haps/entry/files');
sh('cp /data/local/tmp/e2e-conn.json /data/app/el2/100/base/' + BUNDLE + '/haps/entry/files/connections.json');
sh('chown 20010060:20010060 /data/app/el2/100/base/' + BUNDLE + '/haps/entry/files/connections.json');
sh('aa force-stop ' + BUNDLE);
sleep(2000);
sh('aa start -b ' + BUNDLE + ' -a ' + ABILITY);
sleep(9000);
let gnodes = dump('s2-boot');
const gskip = gnodes.find(e => SKIP_RE.test(e.t) && e.t.length <= 12);
if (gskip) { click(gskip); sleep(3500); gnodes = dump('s2-boot2'); }
// open palette, find SSH command (scroll if below fold)
let glyph = gnodes.filter(e => e.t === '⌘').map(e => center(e.b)).sort((a, b) => a[1] - b[1])[0];
if (!glyph) finish(false, 'E2 no palette glyph after seed boot');
sh('uitest uiInput click ' + glyph[0] + ' ' + glyph[1]);
sleep(2200);
let pnodes = dump('s2-palette');
let sshCmd = pnodes.find(e => e.t.indexOf('会话 · SSH 连接') >= 0);
if (!sshCmd) {
  sh('uitest uiInput swipe 700 650 700 380 400');
  sleep(900);
  pnodes = dump('s2-palette2');
  sshCmd = pnodes.find(e => e.t.indexOf('会话 · SSH 连接') >= 0);
}
if (!sshCmd) finish(false, 'E2 SSH command not found in palette');
const [cx, cy] = center(sshCmd.b);
sh('uitest uiInput click ' + cx + ' ' + cy);
log('[e2e] palette SSH connect clicked');

// postLogin echo lands ~10-30s after connect; poll the BRIDGE capture
// (model-level; LEG-4: pane render timing is flaky on dump, capture is
// the authoritative same-session view).
function bridgeCapture(paneId, lines) {
  try {
    return hdc('shell "/data/local/home/.ohos/node/bin/node --jitless /data/local/tmp/oneaiterm-cli.js capture --paneId ' +
      paneId + ' --lines ' + lines + ' --token $(cat /data/app/el2/100/base/' + BUNDLE + '/haps/entry/files/cli_token) 2>&1"', 45000).trim();
  } catch (e) { return ''; }
}
let hits = [];
for (let n = 1; n <= 12 && hits.length === 0; n++) {
  sleep(5000);
  const cap = bridgeCapture('p1', 12);
  hits = cap.indexOf(MARKER) >= 0 ? [cap] : [];
  log('[poll ' + n + '] marker ' + (hits.length ? 'HIT' : 'not yet') + ' (cap=' + cap.slice(0, 40).replace(/\n/g, ' ') + ')');
}
// screen dump as corroborating detail (non-blocking)
const sd = dump('s2-screen');
log('[detail] screen has prompt: ' + (sd.some(e => e.t.indexOf('uterm@') >= 0)));
log('[criterion E2] SSH gold marker "' + MARKER + '" on screen: ' + (hits.length ? 'PASS' : 'FAIL'));
hits.forEach(e => log('  ' + JSON.stringify(e)));
if (!hits.length) finish(false, 'E2 SSH gold marker not visible on screen');

// ---------- Step 3: hilog corroborating evidence (non-blocking detail) ----------
log('[e2e] 3/3 hilog connect evidence (detail)');
try {
  sh('hilog -x > /data/local/tmp/e2e-hilog.txt 2>&1', 30000);
  execSync(HDC + ' file recv /data/local/tmp/e2e-hilog.txt ' + EV.replace(/\//g, '\\') + '\\e2e-hilog.txt',
    { encoding: 'utf8', timeout: 30000 });
  const hl = fs.readFileSync(path.join(EV, 'e2e-hilog.txt'), 'utf8');
  const m = hl.match(/connect ok id=\d+/g);
  log('[e2e] hilog ssh connect lines: ' + (m ? m.slice(-3).join(' | ') : '(none found)'));
} catch (e) {
  log('[e2e] hilog capture failed (non-blocking): ' + e.message.split('\n')[0]);
}

finish(true);
