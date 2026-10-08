# TTY7_INTEGRATION_BASELINE — 主基线（tty7-M0，冻结于本 checkout）

模块地图详见 `ARCHITECTURE_MAP.md`，归属与不可回退详见 `MODULE_OWNERSHIP.md`，依赖详见 `DEPENDENCY_MATRIX.md`。本文件给模块映射总表 + tty7 capability matrix。

## 1. current module → responsibility → dependencies → safe extension point

| current module | responsibility | dependencies | safe extension point |
|---|---|---|---|
| `components/TermModel.ets` | ANSI 模拟器（761 行，`TermModel.ets:100`） | 纯 ArkTS 无外部依赖 | feed/lines 语义稳定：XComponent 渲染器可并行挂接；新增 alternate-screenbuffer 在 model 内部扩展不动 span 契约 |
| `pages/TerminalPage.ets` | 渲染+输入+轮询（842 行） | TM/SS/LT/TEL/ZM | 页面已按 connId 参数化（`TerminalPage.ets:74` connIdIn）——多 tab 复用入口；poll 链可换事件驱动而不动 view 契约 |
| `service/SessionService.ets` | SSH 会话生命周期（416 行，`:58` 全静态） | libssh HAR/CS/IdentityStore | `TermView` 接口（`:39` accept/modelOf）是多视图挂接点；feedExternal 已示范外部通道注入；多实例化时把静态态搬进 Session 对象、保留静态门面方法转发 |
| `cpp/localpty.cpp` | 本地 PTY NAPI（340 行） | forkpty | d.ts 接口可增（toolsChmod 先例）；多 PTY 实例需模块级句柄表 |
| `agent/AgentProvider.ets` | 六方法契约（`:97`） | 无 | 只增不改：新引擎（A2A）implements 即插（`AgentAdapter.ets:81` registerEngine） |
| `agent/AgentAdapter.ets` | 引擎路由+回落（219 行） | 三引擎/HC | registerEngine 预留扩展点（注释明示 A2A） |
| `agent/security/*` | 策略/审批/审计 | AP | PolicyEngine 纯函数可独立加规则；AuditWriter 文件名/格式不动 |
| `pages/Index.ets` | 外壳（1214 行） | 全家 | tab kind 字符串分发（`Index.ets` build() activeTabKind 链）——新 pane 类型=新 kind + 新组件 |
| `service/ToolsInstaller.ets` | 工具箱装配 | zlib/localpty chmod | ensure() 幂等可重复调用 |
| `common/WantParams.ets` | 开发通道（141 行） | AbilityKit | 新 getter 即新通道（agentPrompt/termCmd 先例） |

## 2. tty7 capability matrix（对照 04 文档功能清单）

处置四档：keep=原样复用 / adapt=存在但要改造 / new=从零建 / defer=延后。

### P0（不可回归）
| 功能 | 处置 | 理由 |
|---|---|---|
| Workspace/Session | adapt | SessionService 单会话静态态（`:58-74`）需多实例化，TermView/screenText 契约保留 |
| Tabs | keep | Index.ets TabsList pill + TabInfo 分发已可用，M1 重新皮肤即可 |
| Split 分屏 | adapt | splitTabId 右栏已存在（Index build()），但仅钉一个标签且 terminal 被排除（toggleSplit），tty7 PaneGrid 需泛化 |
| GUI shell | new | ArkUI 同构壳（01 文档路线）：Sidebar/Tabs/PaneGrid/RightPanel/StatusBar/CommandPalette 全新搭建，现有 Index 元素作素材 |
| HMH Agent 状态 | keep | AgentAdapter 事件流 + AIDock 已达 spec，M5 仅需面板化（agent status 进 RightPanel） |
| IME/CJK | keep | 透明 TextInput 捕获层差分直写已实勘可用，M4 补多行编辑 |
| SSH/SFTP | keep | libssh HAR + SftpPanel 成熟，多会话化时复用 |
| Telnet/Raw | keep | TelnetService + feedExternal 通畅 |
| DB(VNC/RDP/Spice/Pg/MySql/Redis/K8s) | keep | 各 Tab 独立成件，新壳按 kind 挂载 |
| Zmodem | keep | ZmodemService 736 行双向完备 |
| 安全审批审计 | keep | PolicyEngine/ApprovalManager/AuditWriter 红线件，原样复用 |

### P1
| 功能 | 处置 | 理由 |
|---|---|---|
| Drag reorder（tabs） | new | ArkUI 无内建 pill 拖拽，需 onDrag 手写 |
| Scrollback search | adapt | TM.lines 已有 5000 行历史，加检索 UI 即可 |
| History 命令历史 | keep | HistoryPanel（SidePanels.ets）已在左坞 |
| Multi-line 输入 | adapt | 捕获层是单行 TextInput，多行编辑器需 M4 专项 |
| Agent attention/resume/context | keep | AgentEventKind 已含 state_changed/session_resumed，四态持久化在 AgentSessionStore |
| 凭据/身份 | keep | CredentialManager enc:v1 + IdentityStore 物化链完好 |
| 隧道 | keep | TunnelPanel + TunnelService(-L) 已在 |
| 命令面板 | adapt | Index 搜索面板已具雏形（paletteItems），M1 泛化为 Cmd+K 全局件 |

### P2 及其他
| 功能 | 处置 | 理由 |
|---|---|---|
| 编辑器输入体验（M4） | new | 硬件键 mapKey 已有，编辑器级输入法是新件 |
| XComponent+NativeWindow 渲染 | new | 01 文档候选路线，Rust NAPI VT core 为增量项 |
| Git/Dev Panel（M7） | new | 仓库无 git 面板 |
| CLI（M8：doctor/workspace/tab/pane/send/capture/wait/agents/procs/ports/events/git） | new | 仓库无 CLI；WantParams termCmd 通道可作 CLI→GUI 桥雏形 |
| Remote Workspace（M6） | adapt | SSH 底座在，workspace 语义新 |
| Hardening（M9） | adapt | gate 家族已有（unit/integration/e2e/license/sbom/security），按新功能补用例 |
| 工具箱 | keep | ToolsInstaller+localpty chmod 已闭环 |
| 能力探测 | keep | CapabilityDiscovery 已实现带缓存 |

覆盖率：04 文档清单 27 项全部在列（keep 14 / adapt 7 / new 6 / defer 0），100%。

## 3. 风险基线摘录（详见 RISK_REGISTER.md）
单会话静态态、tsfn 进程级单例、Interval 停摆环境怪癖、AppStorage key 总线、凭据解密态覆盖——五项为施工前必须知晓的仓库现实。
