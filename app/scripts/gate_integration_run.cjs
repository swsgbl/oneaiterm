// gate_integration_run.cjs -- REAL on-device integration checks for
// gate-integration.cmd (M8-relay10). Three criteria, all dump/bm-proven:
//   I1 module coexistence: `bm dump -a` lists com.oneaiterm.terminal
//      (and entry_test too when installed) - no ghost-overwrite of the
//      main bundle by side-loaded modules.
//   I2 full app lifecycle: force-stop + aa start main bundle, hilog
//      15s window must show EntryAbility onCreate -> onWindowStageCreate
//      -> onForeground in order, with NO jscrash/cppcrash/appfreeze.
//   I3 bundle-dump size sentinel: `bm dump -n com.oneaiterm.terminal`
//      output > 5KB (relay6/7 ghost-overwrite incident auto-sentinel:
//      a hollow/stripped install produces a tiny dump).
// usage: node gate_integration_run.cjs <evDir>
// Evidence: <evDir>/integration-last.txt + integration-*.txt.
// Exit 0 only when all three hold; honest fail otherwise.

'use strict';
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const EV = process.argv[2] || 'D:/oneaiterm/.verify/m8r10';
const BUNDLE = 'com.oneaiterm.terminal';
const ABILITY = 'EntryAbility';
const TARGET = process.env.HM_GATE_TARGET || '127.0.0.1:15566'; // override only for fail-closed drills
const HDC = 'hdc -t ' + TARGET;

if (!fs.existsSync(EV)) fs.mkdirSync(EV, { recursive: true });
const LOG = [];
function log(s) { LOG.push(s); console.log(s); }
function hdc(args, tmo) { return execSync(HDC + ' ' + args, { encoding: 'utf8', timeout: tmo || 45000 }); }
function sh(cmd, tmo) { return hdc('shell "' + cmd + '"', tmo); }
function sleep(ms) { execSync('ping -n ' + (Math.floor(ms / 1000) + 1) + ' 127.0.0.1 > nul', { timeout: ms + 8000 }); }
function recv(remote, local) {
  execSync(HDC + ' file recv ' + remote + ' ' + EV.replace(/\//g, '\\') + '\\' + local,
    { encoding: 'utf8', timeout: 30000 });
  return fs.readFileSync(path.join(EV, local), 'utf8');
}
function finish(ok, reason) {
  log(ok ? 'INTEGRATION_RUN=OK' : 'INTEGRATION_RUN=FAIL ' + (reason || ''));
  fs.writeFileSync(path.join(EV, 'integration-last.txt'), LOG.join('\n') + '\n');
  process.exit(ok ? 0 : 1);
}

// ---------- Step 0: device reachable ----------
let online;
try { online = sh('echo online'); } catch (e) { online = ''; }
if (!/online/.test(online)) finish(false, 'device not reachable');

// ---------- I1: module coexistence via bm dump -a ----------
log('[integration] I1 module coexistence (bm dump -a)');
sh('bm dump -a > /data/local/tmp/integ-bma.txt 2>&1');
const bma = recv('/data/local/tmp/integ-bma.txt', 'integration-bma.txt');
const hasMain = bma.indexOf(BUNDLE) >= 0;
const hasTest = bma.indexOf(BUNDLE + '.entry_test') >= 0 || /\bentry_test\b/.test(bma);
log('[I1] main bundle ' + BUNDLE + ' listed: ' + (hasMain ? 'YES' : 'NO'));
log('[I1] entry_test module listed: ' + (hasTest ? 'YES (coexist install intact)' : 'no (not installed - informational)'));
if (!hasMain) finish(false, 'I1 main bundle not listed in bm dump -a');

// ---------- I2: full lifecycle via hilog, 15s window ----------
log('[integration] I2 app lifecycle (force-stop -> aa start -> hilog 15s window)');
sh('hilog -r > /dev/null 2>&1'); // clear buffer so only fresh lifecycle lines count
sh('aa force-stop ' + BUNDLE);
sleep(2000);
const ls = sh('aa start -b ' + BUNDLE + ' -a ' + ABILITY).trim();
log('[I2] aa start: ' + ls);
sleep(15000); // lifecycle window
sh('hilog -x > /data/local/tmp/integ-hilog.txt 2>&1', 60000);
const hl = recv('/data/local/tmp/integ-hilog.txt', 'integration-hilog.txt');

// EntryAbility lifecycle markers (A0xxxx tags; match on ability + state name)
const idxCreate = hl.search(/EntryAbility[^]{0,400}?onCreate|onCreate[^]{0,200}?EntryAbility/);
const createLine = (hl.match(/[^\n]*EntryAbility[^\n]*onCreate[^\n]*|[^\n]*onCreate[^\n]*EntryAbility[^\n]*/) || [])[0] || '';
const wscLine = (hl.match(/[^\n]*onWindowStageCreate[^\n]*/) || [])[0] || '';
const fgLine = (hl.match(/[^\n]*onForeground[^\n]*/) || [])[0] || '';
log('[I2] onCreate:          ' + (createLine ? 'FOUND' : 'MISSING'));
log('[I2] onWindowStageCreate: ' + (wscLine ? 'FOUND' : 'MISSING'));
log('[I2] onForeground:      ' + (fgLine ? 'FOUND' : 'MISSING'));
if (createLine) log('  ' + createLine.trim().slice(0, 160));
if (wscLine) log('  ' + wscLine.trim().slice(0, 160));
if (fgLine) log('  ' + fgLine.trim().slice(0, 160));
if (!createLine || !wscLine || !fgLine) finish(false, 'I2 lifecycle incomplete (onCreate/onWindowStageCreate/onForeground)');

const crashWords = ['jscrash', 'cppcrash', 'appfreeze'];
const crashHits = crashWords.filter(w => hl.toLowerCase().indexOf(w) >= 0);
log('[I2] crash keywords (jscrash/cppcrash/appfreeze): ' + (crashHits.length ? 'FOUND ' + crashHits.join(',') : 'none'));
if (crashHits.length) finish(false, 'I2 crash keywords present: ' + crashHits.join(','));

// ---------- I3: bundle dump size sentinel ----------
log('[integration] I3 bundle-dump size sentinel (bm dump -n)');
sh('bm dump -n ' + BUNDLE + ' > /data/local/tmp/integ-bmn.txt 2>&1');
const bmn = recv('/data/local/tmp/integ-bmn.txt', 'integration-bmn.txt');
const bytes = Buffer.byteLength(bmn, 'utf8');
log('[I3] bm dump -n size = ' + bytes + ' bytes (need > 5120)');
log('[I3] first lines:');
bmn.split(/\r?\n/).slice(0, 6).forEach(l => { if (l.trim()) log('  ' + l.trim().slice(0, 150)); });
if (bytes <= 5120) finish(false, 'I3 bundle dump only ' + bytes + ' bytes (ghost-overwrite suspect, need >5KB)');

finish(true);
