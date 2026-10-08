# ARCHITECTURE_MAP — oneAIterm 模块地图（tty7-M0 基线，以当前 checkout 为准）

> 佐证格式：`file:line`。所有路径相对 `app/entry/src/main/`（除标注 thirdparty/scripts/ohosTest）。

## 顶层结构

| 区 | 内容 | 佐证 |
|---|---|---|
| entryability | EntryAbility（UIAbility，27 行，持 Want→WantParams） | `ets/entryability/EntryAbility.ets:1` |
| pages | Index（外壳）、ConnList、TerminalPage、SftpPanel | `ets/pages/` 目录 |
| components | TermModel、AIDock、ApprovalCard、各 DB/远程桌面 Tab、SidePanels 等 30 文件 | `ets/components/` 目录 |
| service | SessionService、Telnet、LocalTerminal、Zmodem、Tunnel、VNC/RDP/Spice、DB(Pg/MySql/Redis/K8s)、HarnessClient、ToolsInstaller | `ets/service/` 目录 |
| agent | AgentAdapter/AgentProvider/AgentSessionStore + engine{LocalAssistant,HmhAdapter,AcpClient} + security{PolicyEngine,ApprovalManager,AuditWriter} + discovery/CapabilityDiscovery | `ets/agent/` 目录 |
| store | ConnStore、IdentityStore、CredentialManager、EncCrypto、ConnImporter、UtmExport | `ets/store/` 目录 |
| common | AppTheme、DesignTokens、LayoutConstants、TimingConstants、AppIcons、WantParams | `ets/common/` 目录 |
| cpp | localpty.cpp（340 行，forkpty+chmod 工具）、rdpproxy.cpp（169 行，FreeRDP） | `cpp/localpty.cpp:1` |
| thirdparty | libssh-x86_64-har（HAR：libssh ArkTS 包装 + 预编译 so） | `thirdparty/libssh-x86_64-har/Index.ets:15` |
| scripts | gate 全家桶（unit/integration/e2e/license/sbom/security/package/sign）、VM 构建链 | `app/scripts/` 目录 |
| ohosTest | 12 个测试文件（PolicyEngine/ApprovalManager/AgentAdapter/AcpClient/AuditRedact/CapabilityDiscovery 等） | `src/ohosTest/ets/test/` |

## 真实入口（渲染/通道/引擎）

### 1. Terminal renderer
- `TermModel`：VT100/xterm 子集模拟器，行网格 CharCell + 光标；`MAX_COLS=300`、`MAX_SCROLLBACK=5000` — `ets/components/TermModel.ets:24-25`；类定义 `:100`；span 拆分 `lineToSpans` `:762` 起。
- `TerminalPage`：`@Component`（约 `ets/pages/TerminalPage.ets:67`）；渲染路径 `Scroll{ForEach(winRows→TermLineView)}`；仅绑定可见窗口 + overscan（`WIN_OVERSCAN`）；`refreshWindow()` 快照 `winTop/winSize`。
- 轮询：自链式 setTimeout（`startPoll`，POLL_MS 来自 `ets/common/TimingConstants.ets`）+ 独立看门狗（链死 >5s 自愈）+ `kickPoll()` 交互驱动排空。
- 输入：全幅透明 TextInput 捕获层（`id('termCaptureInput')`）差分直写 PTY；特殊键 `mapKey()`；回车由 `onSubmit` 独占。
- 桥接：`TermBufferView implements TermView`（文件尾），`accept→model.feed` 置 dirty，`drain()` 供 tick 消费。

### 2. localpty
- native：`forkpty` — `cpp/localpty.cpp:121`；同步轮询 `ptyPoll()`（tsfn 不交付环境的绕道）— `cpp/types/localpty/Index.d.ts:6`；工具箱 chmod — `cpp/localpty.cpp:286,296`。
- ArkTS：`LocalTerminalService`（60 行薄包装）— `ets/service/LocalTerminalService.ets`；经 `SessionService.attachLocalPty` 注册 writer 使 agent 工具可用 — `ets/service/SessionService.ets:79`。

### 3. SSH/SFTP
- `SessionService`：全静态单会话；`connect()` `ets/service/SessionService.ets:182`（identity 物化→sessionOpenWithKey/WithPassword）；`write():258`（含 backspaceKey 映射）；`screenText():348`（agent 读屏）；`sshHandle():329`（SFTP 复用）。
- libssh HAR：`sessionOpenWithPassword/Key` — `thirdparty/libssh-x86_64-har/src/main/ets/libssh.ets:81,93`；`writeStdin:122`；`sftpOpen:134`。
- Telnet/Raw：`TelnetService`（@ohos.net.socket），`SessionService.feedExternal():334` 注入视图。
- Zmodem：`ZmodemService`（736 行）双向嗅探 ZRQINIT/ZRINIT — `ets/service/ZmodemService.ets`。

### 4. Agent 三引擎
- 契约：`AgentProvider` 六方法 + `AgentEvent` 统一事件 — `ets/agent/AgentProvider.ets:97-109`。
- 路由：`AgentAdapter`（单例）`ensureLocal()` 注册 local/hmh/acp 三引擎 — `ets/agent/AgentAdapter.ets:66-76`；HMH 不可达回落编排（不静默降级）— `:119-127`；resumeSession 引擎匹配校验 — `:141`。
- 引擎：`LocalAssistant`（596 行，本地规则式）、`HmhAdapter`（550 行，implements AgentProvider `ets/agent/engine/HmhAdapter.ets:59`）、`AcpClient`（775 行）。HMH HTTP 底座 `HarnessClient` — `ets/service/HarnessClient.ets`。

### 5. 安全审批审计
- `PolicyEngine.evaluate()` 五档纯函数判定（注入/穿越前置 deny；destructive 黑名单；terminal/remote/destructive 必审批）— `ets/agent/security/PolicyEngine.ets:106-168`。
- `ApprovalManager` 三档策略（open 直批/standard 仅危险/strict 全弹卡）+ 5 分钟超时 timeout_denied — `ets/agent/security/ApprovalManager.ets:50-75`；`dispose()` 未决清空。
- `AuditWriter.append` 落盘审计；失败发 `audit_write_failed` 事件（不静默丢弃）— `ets/agent/security/AuditWriter.ets`。
- UI 审批卡：`components/ApprovalCard.ets`（179 行）。

### 6. 能力探测
- `CapabilityDiscovery` 单例，`discover(ProbeTarget)→CapabilityReport`，带缓存 — `ets/agent/discovery/CapabilityDiscovery.ets:43-91`。

### 7. WantParams 开发通道
- `WantParams` 静态持 Want，getter：credSetup/credUnlock/importText/importEncText+Pass/exportPass/identityParams/connectNow/agentPrompt/termCmd/agentEngine — `ets/common/WantParams.ets:16-141`。
- 消费：Index.ets `aboutToAppear`（agentPrompt 开 AI Dock、termCmd 延迟注入本地 PTY）— `ets/pages/Index.ets:88-104`。

### 8. ToolsInstaller 工具箱
- rawfile/tools.zip → cache → zlib 解压到 filesDir/tools → `toolsChmod/toolsChmodTree` 兜底执行位；`ready()` 以 `files/tools/bin/hmh` 存在为准 — `ets/service/ToolsInstaller.ets:26-76`。首开本地终端触发（Index.openLocalTerminal）。

## 外壳（现状 GUI）
`Index.ets`（1214 行）：命令栏 44px（品牌+搜索命令面板+AI/齿轮/分屏）+ TabsList pill 条 + 左坞双态（56/200）+ 主体（单 content + 可选分屏右栏）+ AI Dock + 状态栏 24px — `ets/pages/Index.ets:1-4`（头部注释）及 build()。
