#!/usr/bin/env node
/**
 * oneaiterm-cli(任务 tty7-M8a 首发六命令;M8b 加 agents/events/wait/git
 * + 桥侧 \r 转义约定):驱动 app 内 tty7 CommandBridge 的 VM 侧 node 工具。
 * 协议:TCP 127.0.0.1:18971,首行 token('dev-local',TODO-M9),之后每行
 * 一个 JSON 请求 {id,cmd,args},响应 {id,ok,data|error}(按 id 匹配;wait/git
 * 响应异步到——M8b 起同连接并发,等 id 即可)。
 *
 * 用法(node 在 app files/tools/ 下,--jitless):
 *   node --jitless oneaiterm-cli.js <cmd> [args...] [--token dev-local]
 *   node --jitless oneaiterm-cli.js doctor
 *   node --jitless oneaiterm-cli.js workspace.list
 *   node --jitless oneaiterm-cli.js tab.list
 *   node --jitless oneaiterm-cli.js pane.list
 *   node --jitless oneaiterm-cli.js send --paneId p1 --text 'echo CLI-OK\r'
 *   node --jitless oneaiterm-cli.js capture --paneId p1 [--lines 40]
 *   node --jitless oneaiterm-cli.js agents
 *   node --jitless oneaiterm-cli.js events [--n 20]
 *   node --jitless oneaiterm-cli.js wait --paneId p1 --match CLI-OK [--timeout 8000] [--interval 300]
 *   node --jitless oneaiterm-cli.js git --sub status [--cwd .]
 *   node --jitless oneaiterm-cli.js git --sub log [--cwd .]
 *
 * \r 转义(M8b):--text 值里的字面 '\r' '\n' '\t' 两字符序列由【桥侧】
 * 转成真控制符——CLI 原样传(单引号 shell 传参友好,不用键真 CR)。
 *
 * 退出码:ok=0,error=1,连接失败=2。pretty 输出(capture 原样文本)。
 * 红线:token 只经 env/参数收,不落盘;秘密不进任何日志。
 */
'use strict';
const net = require('net');

const argv = process.argv.slice(2);
const PORT = 18971;
const HOST = '127.0.0.1';

// ---- 参数解析:首位置参数 = cmd;--key value 其余 ----
let cmd = null;
const args = {};
let token = 'dev-local';
for (let i = 0; i < argv.length; i++) {
  const t = argv[i];
  if (t === '--token') {
    token = argv[++i] || '';
  } else if (t.startsWith('--')) {
    const key = t.slice(2);
    args[key] = argv[++i];
  } else if (cmd === null) {
    cmd = t;
  } else {
    args['pos' + i] = t;
  }
}
if (!cmd) {
  console.error('usage: oneaiterm-cli.js <cmd> [args...] [--token dev-local]');
  console.error('  cmd: doctor | workspace.list | tab.list | pane.list | send | capture');
  console.error('       agents | events | wait | git');
  process.exit(1);
}

// 数字 flag 数字化(bridge 侧 intArg 要 number;非数字丢弃走桥默认)
for (const k of ['lines', 'n', 'timeout', 'interval']) {
  if (args[k] !== undefined) {
    const v = parseInt(args[k], 10);
    if (Number.isFinite(v) && String(v) === String(args[k]).trim()) {
      args[k] = v;
    } else {
      delete args[k];
    }
  }
}
// wait:CLIENT-SIDE polling loop (bridge async push crashes the app - M8b finding).
// Polls capture over a persistent connection until match or timeout.
async function waitClient(paneId, match, timeoutMs, intervalMs) {
  const net = require('net');
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve) => {
    const sock = net.connect(PORT, HOST, () => {
      sock.write(token + '\n');
    });
    let buf = '';
    let timer = null;
    const fail = (msg) => { if (timer) clearTimeout(timer); try { sock.destroy(); } catch (e) {} resolve({ ok: false, error: msg }); };
    sock.on('error', (e) => fail('connect failed: ' + e.message));
    sock.on('data', (d) => {
      buf += d.toString();
      let nl = buf.indexOf('\n');
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line === '') { nl = buf.indexOf('\n'); continue; }
        let resp = null;
        try { resp = JSON.parse(line); } catch (e) { nl = buf.indexOf('\n'); continue; }
        if (resp.ok && typeof resp.data === 'string' && resp.data.indexOf(match) >= 0) {
          if (timer) clearTimeout(timer);
          try { sock.destroy(); } catch (e) {}
          resolve({ ok: true, data: 'matched' });
          return;
        }
        nl = buf.indexOf('\n');
      }
      if (Date.now() >= deadline) { fail('timeout'); }
    });
    const poll = () => {
      if (Date.now() >= deadline) { fail('timeout'); return; }
      try {
        sock.write(JSON.stringify({ id: Math.floor(Math.random() * 1e6), cmd: 'capture', args: { paneId: paneId, lines: 80 } }) + '\n');
      } catch (e) { fail('send failed'); return; }
      timer = setTimeout(poll, intervalMs);
    };
    // first poll after token handshake settles
    setTimeout(poll, 150);
  });
}
if (cmd === 'wait') {
  const paneId = args.paneId || '';
  const match = args.match || '';
  const timeoutMs = args.timeoutMs || 10000;
  const intervalMs = args.intervalMs || 300;
  if (!paneId || !match) { console.error('error: wait requires paneId and match'); process.exit(1); }
  waitClient(paneId, match, timeoutMs, intervalMs).then((r) => {
    if (r.ok) { console.log('matched'); process.exit(0); }
    console.error('error: ' + r.error); process.exit(1);
  });
  return;
}

if (cmd === 'wait') {
  if (args.timeout !== undefined) { args.timeoutMs = args.timeout; delete args.timeout; }
  if (args.interval !== undefined) { args.intervalMs = args.interval; delete args.interval; }
}

const req = { id: 1, cmd: cmd, args: args };
let settled = false;

// wait 等异步响应:socket 超时 = max(8s, timeoutMs+3s) 兜底
let TIMEOUT_MS = 8000;
if (cmd === 'wait' && Number.isFinite(args.timeoutMs) && args.timeoutMs > 0) {
  TIMEOUT_MS = Math.max(8000, args.timeoutMs + 3000);
}

const sock = net.connect({ host: HOST, port: PORT }, () => {
  // 握手:token 行;然后命令行
  sock.write(token + '\n');
  sock.write(JSON.stringify(req) + '\n');
});

let buf = '';
const timer = setTimeout(() => {
  fail(2, 'timeout: no response from bridge (' + TIMEOUT_MS + 'ms)');
}, TIMEOUT_MS);

function fail(code, msg) {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  try { sock.destroy(); } catch (e) {}
  console.error(msg);
  process.exit(code);
}

sock.on('data', (chunk) => {
  buf += chunk.toString('utf8');
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).replace(/\r$/, '');
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let resp = null;
    try {
      resp = JSON.parse(line);
    } catch (e) {
      return fail(1, 'bad response line: ' + line.slice(0, 200));
    }
    if (!resp || resp.id !== req.id) continue; // 不匹配的行丢弃(wait 期间别请求的响应)
    settled = true;
    clearTimeout(timer);
    if (resp.ok) {
      // doctor/list 系列 data 是 JSON 字符串:parse 后 pretty;capture 原样
      let printed = false;
      if (cmd !== 'capture' && typeof resp.data === 'string') {
        try {
          console.log(JSON.stringify(JSON.parse(resp.data), null, 2));
          printed = true;
        } catch (e) {
          // 非 JSON:走原样
        }
      }
      if (!printed) {
        console.log(resp.data);
      }
      sock.end();
      process.exit(0);
    } else {
      console.error('error: ' + (resp.error || 'unknown'));
      sock.end();
      process.exit(1);
    }
  }
});

sock.on('error', (e) => {
  fail(2, 'connect failed: ' + e.message);
});
sock.on('close', () => {
  fail(2, 'connection closed before response');
});
