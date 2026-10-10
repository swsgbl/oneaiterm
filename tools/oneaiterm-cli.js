#!/usr/bin/env node
/**
 * oneaiterm-cli(任务 tty7-M8a):驱动 app 内 tty7 CommandBridge 的 VM 侧
 * node 工具。协议:TCP 127.0.0.1:18971,首行 token('dev-local',TODO-M9),
 * 之后每行一个 JSON 请求 {id,cmd,args},响应 {id,ok,data|error}。
 *
 * 用法(node 在 app files/tools/ 下,--jitless):
 *   node --jitless oneaiterm-cli.js <cmd> [args...] [--token dev-local]
 *   node --jitless oneaiterm-cli.js doctor
 *   node --jitless oneaiterm-cli.js workspace.list
 *   node --jitless oneaiterm-cli.js tab.list
 *   node --jitless oneaiterm-cli.js pane.list
 *   node --jitless oneaiterm-cli.js send --paneId p1 --text 'echo CLI-OK\r'
 *   node --jitless oneaiterm-cli.js capture --paneId p1 [--lines 40]
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
  process.exit(1);
}

// lines 数字化(bridge 侧 intArg 也要 number)
if (args.lines !== undefined) {
  const n = parseInt(args.lines, 10);
  args.lines = Number.isFinite(n) ? n : undefined;
}

const req = { id: 1, cmd: cmd, args: args };
let settled = false;

const sock = net.connect({ host: HOST, port: PORT }, () => {
  // 握手:token 行;然后命令行
  sock.write(token + '\n');
  sock.write(JSON.stringify(req) + '\n');
});

let buf = '';
const TIMEOUT_MS = 8000;
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
    if (!resp || resp.id !== req.id) continue; // 不匹配的行丢弃
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
