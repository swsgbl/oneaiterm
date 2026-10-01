// uniterm KaihongOS 验收靶机链路(编排者建设):
// guest 10.0.2.2:2222 --SLIRP--> 宿主 127.0.0.1:2222 (本relay) --> WSL Ubuntu sshd :22
// 特性:启动时动态解析 WSL IP;目标连不上时先唤醒 WSL(wsl -- true)再重试一次。
const net = require('net');
const { execSync } = require('child_process');

function wslIp() {
  const out = execSync('wsl -d Ubuntu -- hostname -I', { encoding: 'utf8', timeout: 15000 });
  return out.trim().split(/\s+/)[0];
}
function wakeWsl() {
  try { execSync('wsl -d Ubuntu -- true', { timeout: 30000 }); } catch (e) { /* already up */ }
}

const LISTEN = Number(process.env.RELAY_PORT || 2222);
let target = process.env.RELAY_TARGET || wslIp();
console.log(`[target-relay] 127.0.0.1:${LISTEN} -> ${target}:22 (WSL Ubuntu sshd, uterm/dev123)`);

const server = net.createServer(client => {
  function attempt(ip) {
    const up = net.connect({ host: ip, port: 22 }, () => {
      console.log(`[relay] pipe ${client.remoteAddress} -> ${ip}:22`);
      up.pipe(client); client.pipe(up);
    });
    up.on('error', err => {
      console.log(`[relay] target ${ip}:22 failed: ${err.code}; wake WSL + retry`);
      wakeWsl();
      const fresh = wslIp();
      if (fresh && fresh !== ip) { target = fresh; }
      setTimeout(() => attempt(target), 800);
    });
    client.on('error', () => up.destroy());
    client.on('close', () => up.destroy());
  }
  attempt(target);
});

server.on('error', err => { console.error('[relay] listen failed:', err.message); process.exit(1); });
server.listen(LISTEN, '127.0.0.1', () => console.log(`[relay] listening on 127.0.0.1:${LISTEN}`));
