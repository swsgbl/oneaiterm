/**
 * upstream M8 relay-3 - SSH local port-forwarding (-L) service.
 *
 * Listens on a VM-local port (default 9432) and bridges every accepted
 * connection to a direct-tcpip channel (ssh_channel_open_forward) on the
 * LIVE terminal session owned by SessionService. Binary data crosses the
 * napi boundary base64-encoded (the boundary is UTF-8 strings only).
 *
 * Known API14 limits (recorded honestly, see REPORT):
 *  - TCPSocketServer has no close(): stop() only closes connections and
 *    tunnels; listening again on the SAME port needs an app restart.
 *  - One tunnel channel per accepted connection (no mux pool, first version).
 *
 * UI state (AppStorage):
 *   ut.tunnel.status  off|running|error
 *   ut.tunnel.reason  last error / info text
 *   ut.tunnel.active  live tunnel count
 *   ut.tunnel.conns   cumulative forwarded connections (M8 relay7: footer
 *                     shows listener state + forwarded count separately)
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { libssh } from '@ohos/libssh';
import { SessionService } from './SessionService';

const TAG: string = 'oat.tunnel';
const DOMAIN: number = 0x0110;
const POLL_MS: number = 200;

/** Per-accepted-connection state: local conn + its own tunnel channel. */
class TunnelConn {
  conn: socket.TCPSocketConnection;
  tid: number = -1;
  timer: number = -1;
  constructor(c: socket.TCPSocketConnection) {
    this.conn = c;
  }
}

/**
 * Static singleton -L forwarder. At most one listener per app run (API14:
 * the server socket cannot be closed), tunnels are per connection.
 */
export class TunnelService {
  private static server: socket.TCPSocketServer | null = null;
  private static conns: Map<number, TunnelConn> = new Map();
  private static nextKey: number = 1;
  private static b64: util.Base64Helper = new util.Base64Helper();
  private static listenPort: number = -1;
  /** M8 relay7: cumulative forwarded connections since first start. */
  private static totalConns: number = 0;

  /** Start listening localPort -> remoteHost:remotePort over the live session. */
  public static async start(localPort: number, remoteHost: string, remotePort: number): Promise<void> {
    const ssh = SessionService.sshHandle();
    const sid = SessionService.getSessionId();
    if (ssh === null || sid < 0) {
      TunnelService.fail('无活动 SSH 会话,先连接主机再开隧道');
      return;
    }
    if (TunnelService.server !== null) {
      TunnelService.fail('隧道已在运行(端口 ' + TunnelService.listenPort.toString() + ')');
      return;
    }
    if (localPort < 1 || localPort > 65535 || remotePort < 1 || remotePort > 65535 || remoteHost.length === 0) {
      TunnelService.fail('参数无效: 端口 1-65535,主机非空');
      return;
    }
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    try {
      await server.listen({ address: '127.0.0.1', port: localPort });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      TunnelService.fail('监听 127.0.0.1:' + localPort.toString() + ' 失败: ' + msg +
        ' (API14 无 server.close,同端口重试需重启应用)');
      return;
    }
    TunnelService.server = server;
    TunnelService.listenPort = localPort;
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      TunnelService.onAccept(ssh, sid, remoteHost, remotePort, conn);
    });
    server.on('error', (err: Error): void => {
      TunnelService.fail('监听错误: ' + (err instanceof Error ? err.message : String(err)));
    });
    AppStorage.setOrCreate('ut.tunnel.status', 'running');
    AppStorage.setOrCreate('ut.tunnel.conns', TunnelService.totalConns);
    AppStorage.setOrCreate('ut.tunnel.reason',
      '127.0.0.1:' + localPort.toString() + ' → ' + remoteHost + ':' + remotePort.toString());
    hilog.info(DOMAIN, TAG, 'listen ok 127.0.0.1:%{public}d -> %{public}s:%{public}d sid=%{public}d',
      localPort, remoteHost, remotePort, sid);
  }

  /** Accept loop: open one tunnel channel per local connection. */
  private static onAccept(ssh: libssh, sid: number, remoteHost: string, remotePort: number,
    conn: socket.TCPSocketConnection): void {
    const key = TunnelService.nextKey++;
    const tc = new TunnelConn(conn);
    TunnelService.conns.set(key, tc);
    TunnelService.totalConns++;
    AppStorage.setOrCreate('ut.tunnel.conns', TunnelService.totalConns);
    ssh.tunnelOpen(sid, remoteHost, remotePort).then((tid: number) => {
      tc.tid = tid;
      hilog.info(DOMAIN, TAG, 'tunnel open key=%{public}d tid=%{public}d active=%{public}d',
        key, tid, TunnelService.conns.size);
      AppStorage.setOrCreate('ut.tunnel.active', TunnelService.conns.size);
      tc.timer = setInterval((): void => {
        TunnelService.pump(ssh, key);
      }, POLL_MS);
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'tunnel open fail key=%{public}d: %{public}s', key, String(e));
      TunnelService.dropConn(ssh, key);
    });
    conn.on('message', (info: socket.SocketMessageInfo): void => {
      if (tc.tid < 0) {
        return; // tunnel not ready yet - drop early traffic (banner-free protocols)
      }
      const b64s = TunnelService.b64.encodeToStringSync(new Uint8Array(info.message));
      const n = ssh.tunnelWrite(tc.tid, b64s);
      if (n < 0) {
        hilog.warn(DOMAIN, TAG, 'tunnel write fail key=%{public}d tid=%{public}d', key, tc.tid);
        TunnelService.dropConn(ssh, key);
      }
    });
    conn.on('close', (): void => {
      hilog.info(DOMAIN, TAG, 'conn close key=%{public}d', key);
      TunnelService.dropConn(ssh, key);
    });
    conn.on('error', (err: Error): void => {
      hilog.warn(DOMAIN, TAG, 'conn error key=%{public}d: %{public}s', key,
        err instanceof Error ? err.message : String(err));
      TunnelService.dropConn(ssh, key);
    });
  }

  /** Poll the tunnel once: data -> conn.send; closed -> drop. */
  private static pump(ssh: libssh, key: number): void {
    const tc = TunnelService.conns.get(key);
    if (tc === undefined || tc.tid < 0) {
      return;
    }
    ssh.tunnelPoll(tc.tid).then((res: string) => {
      if (res === 'closed') {
        hilog.info(DOMAIN, TAG, 'tunnel closed key=%{public}d tid=%{public}d', key, tc.tid);
        TunnelService.dropConn(ssh, key);
        return;
      }
      if (res.length > 2) { // "n:<b64>"
        const bin = TunnelService.b64.decodeSync(res.substring(2));
        tc.conn.send({ data: bytesToArrayBuffer(bin) }).catch((e: Object): void => {
          hilog.warn(DOMAIN, TAG, 'conn send fail key=%{public}d: %{public}s', key, String(e));
          TunnelService.dropConn(ssh, key);
        });
      }
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'poll fail key=%{public}d: %{public}s', key, String(e));
      TunnelService.dropConn(ssh, key);
    });
  }

  /** Remove one connection + its tunnel (idempotent). */
  private static dropConn(ssh: libssh, key: number): void {
    const tc = TunnelService.conns.get(key);
    if (tc === undefined) {
      return;
    }
    TunnelService.conns.delete(key);
    if (tc.timer >= 0) {
      clearInterval(tc.timer);
      tc.timer = -1;
    }
    if (tc.tid >= 0) {
      ssh.tunnelClose(tc.tid);
      tc.tid = -1;
    }
    try {
      tc.conn.close();
    } catch (e) {
      // already gone - ignore
    }
    AppStorage.setOrCreate('ut.tunnel.active', TunnelService.conns.size);
    hilog.info(DOMAIN, TAG, 'drop key=%{public}d active=%{public}d', key, TunnelService.conns.size);
  }

  /** Stop the forwarder: close conns + tunnels. The listen socket itself
   * cannot be closed on API14 - see class header. */
  public static stop(): void {
    const ssh = SessionService.sshHandle();
    if (ssh !== null) {
      const keys: number[] = [];
      TunnelService.conns.forEach((tc: TunnelConn, k: number): void => {
        keys.push(k);
      });
      for (const k of keys) {
        TunnelService.dropConn(ssh, k);
      }
    } else {
      TunnelService.conns.clear();
    }
    TunnelService.server = null; // drop the reference; socket dies with the app
    TunnelService.listenPort = -1;
    AppStorage.setOrCreate('ut.tunnel.status', 'off');
    AppStorage.setOrCreate('ut.tunnel.active', 0);
    AppStorage.setOrCreate('ut.tunnel.reason', '已停止 (监听端口随应用退出释放)');    hilog.info(DOMAIN, TAG, 'stopped');
  }

  private static fail(msg: string): void {
    AppStorage.setOrCreate('ut.tunnel.status', 'error');
    AppStorage.setOrCreate('ut.tunnel.reason', msg);
    hilog.error(DOMAIN, TAG, 'FAIL %{public}s', msg);
  }
}

/** Uint8Array -> fresh ArrayBuffer (type-safe copy for TCPSendOptions). */
function bytesToArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const ab = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(ab).set(bytes);
  return ab;
}
