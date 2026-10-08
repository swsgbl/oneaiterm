# MODULE_OWNERSHIP — 模块归属 / 职责 / 不可回退清单（tty7-M0）

> 「不可回退」= tty7 集成施工中不得删除、不得语义变更、不得绕过的行为。改动必须走等价迁移（如 PolicyEngine 头注「存量 AgentKernel.riskOf 等价迁移」范式）。

## 1. 终端域

| 模块 | 职责 | 不可回退 |
|---|---|---|
| `components/TermModel.ets` (761 行) | VT100/xterm 子集、256 色、scrollback 5000、MAX_COLS 300、dirty 重绘 | feed/resize/lines/screenTop 语义；lineToSpans 的 fg/bg/bold 输出契约（TerminalPage 与 SessionService.screenText 都消费） |
| `pages/TerminalPage.ets` (842 行) | 渲染窗口快照、键映射、捕获层差分直写、poll 链+看门狗 | 自链式 setTimeout + watchdog 自愈（环境 interval 停摆实证）；透明 TextInput 捕获层范式（硬件键/IME 唯一可靠通路）；回车 onSubmit 独占（防双 \r） |
| `service/LocalTerminalService.ets` | localpty 薄包装 | `__PTY_EOF__` 哨兵→disconnected 保历史输出 |
| `cpp/localpty.cpp` | forkpty/sh、ptyPoll 同步读、toolsChmod | ptyPoll 的存在本身（tsfn 不交付环境的绕道，M5 relay4 实勘） |

## 2. 连接与会话域

| 模块 | 职责 | 不可回退 |
|---|---|---|
| `service/SessionService.ets` (416 行) | SSH 单会话生命周期、事件分发、backspaceKey、stats、screenText、attachLocalPty、feedExternal | 全静态单会话假设被 tty7 多会话打破是**已知计划内重构**，但 screenText/hasSession/feedExternal 契约必须保留（agent 工具依赖）；首连 tsfn 单例分发范式（头部注释） |
| `thirdparty/libssh-x86_64-har` | libssh NAPI + ArkTS 包装 | sessionOpenWithPassword/Key/writeStdin/sftpOpen 签名（libssh.ets:81-135）；HAR 预编译 arm64/x86_64 双架构 |
| `service/TelnetService.ets` | telnet/raw TCP | feedExternal 注入路径 |
| `service/ZmodemService.ets` (736 行) | rz/sz 双向、ZRQINIT/ZRINIT 嗅探、rawfile 目标目录 | 嗅探在 data 事件内的位置（SessionService.onEvent 'data' 分支） |
| `service/TunnelService.ets` | SSH -L 端口转发 | — |
| `store/ConnStore.ets` + `CredentialManager` + `EncCrypto` + `IdentityStore` | 连接/凭据(enc:v1)/身份持久化 | 共享 store 范式（getSharedStore 解密态，磁盘密文不得覆盖内存明文——TerminalPage aboutToAppear 注释红线） |

## 3. AI Agent 域（红线最密集）

| 模块 | 职责 | 不可回退 |
|---|---|---|
| `agent/AgentProvider.ets` | 六方法接口 + AgentEvent 统一事件 + 异常码 | 六方法签名与 AgentEventKind 枚举是 UI 唯一契约（design 2.2.2.1），只增不改 |
| `agent/AgentAdapter.ets` | 引擎注册/路由/回落编排 | HMH 不可达不得静默降级（fallbackNote 明确标注）；resumeSession 引擎类型匹配校验；createSession 前必须 ensureLocal（M8 relay13 惰性注册 bug 实勘） |
| `agent/engine/*` | LocalAssistant/HmhAdapter/AcpClient 三引擎 | 引擎间互不感知；回落编排只在 AgentAdapter |
| `agent/security/PolicyEngine.ets` | 五档判定纯函数 | 注入/穿越前置 deny 顺序；destructive 黑名单；terminal/remote/destructive 必审批——**fail-open 即红线违规** |
| `agent/security/ApprovalManager.ets` | 审批状态机 | request→policy→approval→execute→audit 不可跳步；三出口皆审计；超时=timeout_denied；open 档禁止默认（须显式选择） |
| `agent/security/AuditWriter.ets` | 审计落盘+脱敏 | digest 脱敏（凭据不进日志）；写失败发 audit_write_failed 不静默 |
| `agent/discovery/CapabilityDiscovery.ets` | 环境探测+缓存 | — |
| `agent/AgentSessionStore.ets` | 会话元数据持久化（四态流转） | 状态每次流转持久化 |
| `components/AIDock.ets` (600 行) + `ApprovalCard.ets` | AI 底部 Dock、审批卡 UI | UI 不 import 引擎层（经 AgentAdapter）；UI 不解析引擎协议 |
| `service/HarnessClient.ets` | HMH HTTP 底座 | test() 复用点（AgentAdapter.testHmh） |
| `service/ToolsInstaller.ets` | 工具箱首启装配 | 幂等+并发合并+失败不抛；files/tools/bin/hmh 就绪判据 |

## 4. 外壳与面板域

| 模块 | 职责 | 不可回退 |
|---|---|---|
| `pages/Index.ets` (1214 行) | 命令栏/Tabs/左坞/分屏/AI Dock/状态栏/命令面板 | tab/conn/sftp/DB 组件原样复用红线（头部注释）；WantParams 开发通道消费点 |
| `pages/ConnList.ets` (1352 行) | 连接列表+身份管理入口 | 共享 store 初始化责任（SessionService.setIdentities 调用点） |
| `components/SidePanels.ets` 等 | 快捷命令/历史/个性化/隧道 | — |
| `pages/SftpPanel.ets` | SFTP 双栏 | sshHandle() 复用（同会话免重连） |
| DB/远程桌面 Tab（Redis/K8s/Pg/MySql/Vnc/Rdp/Spice） | 各自协议客户端 | — |
| `common/*` | 主题/令牌/常量/图标/WantParams | AppStorage key 约定（ut.*）是跨页通信契约 |

## 5. 构建与质量域

| 资产 | 职责 | 不可回退 |
|---|---|---|
| `app/scripts/gate*.cmd` + `gate_*_run.cjs` | 单元/集成/e2e/许可/SBOM/安全/打包门禁 | 每步可构建验收依赖 gate 家族；M1 起新增 UI 必须先补 gate 用例 |
| `app/thirdparty/*` 构建脚本 | libssh HAR 双架构构建 | arm64/x86_64 双产物 |
| `ohosTest/ets/test/*` | 12 个既有测试 | 既有测试不得删改语义，只能增 |
