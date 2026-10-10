# oneaiterm-cli(工具集)

VM/宿主侧 node 工具,驱动 app 内 tty7 CommandBridge(TCP JSON-RPC,
仅 listen `127.0.0.1:18971`)。协议:首行 token(dev 阶段常量
`dev-local`,M9 换 filesDir 下 cli_token 真文件),之后每行一个 JSON
请求 `{id,cmd,args}`,响应 `{id,ok,data|error}` 单行 JSON(按 id 匹配;
`wait`/`git` 响应异步到,同连接并发安全)。

## 用法

```
node --jitless oneaiterm-cli.js <cmd> [args...] [--token dev-local]
```

## 命令全集(M8a 六命令 + M8b 四命令)

| 命令 | 参数 | 说明 |
|---|---|---|
| `doctor` | - | 桥/vm/工作台快照(bridge/vm/wsCount/tabCount/paneCount/termLocal/termRemote) |
| `workspace.list` | - | 工作区列表 `[{wsId,name,glyph,tabs,active}]` |
| `tab.list` | - | 当前工作区 tab 列表 `[{tabId,title,panes}]` |
| `pane.list` | - | 当前 tab pane 列表 `[{paneId,focused,slotKind,title}]` |
| `send` | `--paneId p1 --text 'echo HI\r'` | 向 pane 宿主(本地/远程)写字符串;**字面 `\r`/`\n`/`\t` 两字符序列由桥侧转成真控制符**(单引号 shell 传参友好,不用键真 CR) |
| `capture` | `--paneId p1 [--lines 40]` | pane 尾部可视行文本(纯文本原样输出) |
| `agents` | - | AgentEvent 总线环形 200 条按 agentId 聚合 `[{agentId,events,state,lastType,ts}]`;空 → `[]` |
| `events` | `[--n 20]`(1..200 钳制) | 总线最近 n 条事件 `[{seq,ts,type,agentId,paneId,text(截 120)}]` |
| `wait` | `--paneId p1 --match CLI-OK [--timeout 8000] [--interval 300]` | 桥内轮询 capture(默认超时 10000ms 上限 60000;间隔默认 300ms 下限 100),命中回 `matched`,超时 error `timeout`;pane 未绑立即 error |
| `git` | `--sub status\|log [--cwd .]` | 只读 git 快捷(经 SSH 远程会话 RemoteCommandRunner;cwd 走 SFTP 路径转义闸);`sub` 白名单 status/log,写操作不经 CLI;未连接远程 → error `remote not connected` |

退出码:ok=0,命令 error=1,连接失败/超时=2。doctor/list 系列 data
为 JSON 字符串,CLI pretty-print;capture 原样文本。

## 编排示例

```
# 起本地 shell 后:键入命令并等待输出标记
node --jitless oneaiterm-cli.js send --paneId p1 --text 'echo CLI-OK\r'
node --jitless oneaiterm-cli.js wait --paneId p1 --match CLI-OK --timeout 8000
# → matched

# 观察 agent 事件流
node --jitless oneaiterm-cli.js agents
node --jitless oneaiterm-cli.js events --n 50
```

## 沙箱限制:procs / ports 为何缺席

02 文档 CLI 目标集含 `procs`/`ports`,但三方沙箱(KaihongOS VM 的
非 root app 环境)实测不可达:

- **procs**:`/proc` 对 app 进程不可读(挂载点存在但权限拒绝),
  无 ps 等级枚举通道;
- **ports**:系统 netstat/ss 工具不在 app 可执行路径,且 /proc/net/tcp
  同因 /proc 拒绝不可读。

**等价替代**:`send` 一条 shell 命令 + `wait`/`capture` 收集——在
本地 shell pane(或 SSH 远程 pane)里 `send --text 'ps aux | grep xxx\r'`
后 `capture`,语义等同;远程 pane 上 `/proc` 与 netstat 按 SSH 目标
机器权限正常可用(git 命令即此通道)。M9 文档化收口。

## 红线

- 桥只 listen 127.0.0.1;token 校验失败即断,token 值与 send 文本
  绝不进 hilog;
- `wait` 用 setTimeout 链轮询,不阻塞 UI 线程;
- `git` 只读(status/log 白名单;stage/commit/push 走 UI 审批链,
  不经 CLI)。
