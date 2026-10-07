// hilog_stats.cjs -- M8-relay8 gate-unit hilog fallback parser.
// Input: raw `hilog -x` dump (argv[2]). Finds the NEWEST
// "ListTest runner main() enter" marker (tag m8r8), takes its pid, then
// requires a hypium summary "total cases:N;failure X,error Y,pass Z"
// line from the SAME pid AFTER the marker. Freshness: the marker must
// be within FRESH_SECS of the newest hilog line's timestamp (buffer
// head = "now"), so a stale leftover from an old run can never satisfy
// the gate. Output (single line, machine-readable):
//   HILOG_STATS=OK,<run>,<fail>,<err>,<pass>,pid=<pid>
//   HILOG_STATS=STALE   (marker found but too old / no newer lines)
//   HILOG_STATS=MISSING (no marker, or no same-pid total line after it)
//   HILOG_STATS=FAIL,<fail>,<err>,<pass>  (ran, with failures)
const fs = require("fs");

const FRESH_SECS = 420; // gate runs aa test -w 180; allow generous margin

// Measured KaihongOS 5.0 hilog line shape (final-hilog.txt, 2026-10-05):
//   10-05 18:14:38.623 28480 28480 I A00000/m8r8: ListTest runner main() enter
//   10-05 18:14:38.676 28480 28480 I A03d00/JSAPP: total cases:130;failure 0,...
// i.e. "<ts> <pid> <tid> <level> <tag>: <msg>" -- pid sits directly after
// the timestamp (no domain column).
const PID_RE = /^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+(\d+)\s+\d+/;

function ts(line) {
  const m = line.match(/^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})/);
  if (!m) return null;
  // date-aware seconds: month-day folded in, else a pre-midnight buffer line
  // looks "newer" than a post-midnight marker and inflates age by a day
  // (M8 closeout: age=47557s false STALE right after midnight)
  const day = (+m[1]) * 31 + (+m[2]);
  return { h: +m[3], m: +m[4], s: +m[5], ms: +m[6],
    sec: day * 86400 + (+m[3]) * 3600 + (+m[4]) * 60 + (+m[5]) + (+m[6]) / 1000 };
}

const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");

// newest timestamp in the whole dump == effective "now" of the buffer
let now = null;
for (const l of lines) { const t = ts(l); if (t && (now === null || t.sec > now.sec)) now = t; }
if (now === null) { console.log("HILOG_STATS=MISSING"); process.exit(0); }

// newest enter marker (scan from the end)
let enter = null;
for (let i = lines.length - 1; i >= 0; i--) {
  if (/ListTest runner main\(\) enter/.test(lines[i])) {
    const pid = (lines[i].match(PID_RE) || [])[1];
    const t = ts(lines[i]);
    if (pid && t) { enter = { i, pid, t }; break; }
  }
}
if (!enter) { console.log("HILOG_STATS=MISSING"); process.exit(0); }

const age = now.sec - enter.t.sec;
if (age < 0 || age > FRESH_SECS) { console.log("HILOG_STATS=STALE,age=" + Math.round(age)); process.exit(0); }

// same-pid total line AFTER the marker
for (let i = enter.i + 1; i < lines.length; i++) {
  const m = lines[i].match(/total cases:(\d+);failure (\d+),error (\d+),pass (\d+)/);
  if (!m) continue;
  const pid = (lines[i].match(PID_RE) || [])[1];
  if (pid !== enter.pid) continue;
  const run = +m[1], fail = +m[2], err = +m[3], pass = +m[4];
  if (fail === 0 && err === 0 && pass >= 1) {
    console.log(`HILOG_STATS=OK,${run},${fail},${err},${pass},pid=${enter.pid},age=${Math.round(age)}`);
  } else {
    console.log(`HILOG_STATS=FAIL,${fail},${err},${pass},pid=${enter.pid}`);
  }
  process.exit(0);
}
console.log("HILOG_STATS=MISSING,pid=" + enter.pid);
