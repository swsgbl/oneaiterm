# DEPENDENCY_MATRIX — 模块依赖矩阵（tty7-M0）

读法：行依赖列（→）。`●` 直接 import；`○` 经 AppStorage/静态单例间接耦合；空=无。
路径缩写：TM=components/TermModel，TP=pages/TerminalPage，SS=service/SessionService，LS=libssh HAR，LT=service/LocalTerminalService，TEL=service/TelnetService，ZM=service/ZmodemService，IDX=pages/Index，AD=agent/AgentAdapter，AP=agent/AgentProvider，LA/HM/AC=engine 三引擎，PE/AM/AW=security 三件，HC=service/HarnessClient，TI=service/ToolsInstaller，CS=store/ConnStore，WP=common/WantParams。

| ↓依赖\被依赖 | TM | SS | LS | LT | TEL | ZM | AD | AP | PE/AM/AW | HC | CS | WP | TI |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| TP 终端页 | ● | ● |  | ● | ● | ● |  |  |  |  | ○ |  | ●(via IDX) |
| IDX 外壳 |  |  |  |  |  |  | ○(via AIDock) |  |  |  | ● | ● | ● |
| SS 会话服务 | ○(type) | — | ● | ○(attachLocalPty) | ○(feedExternal 被调) | ● |  |  |  |  | ● |  |  |
| LT 本地终端 |  | ○ |  | — |  |  |  |  |  |  |  |  |  |
| LA 本地引擎 | ○(screenText via SS) | ● |  |  |  |  |  | ● | ● |  |  |  |  |
| HM HMH引擎 |  | ●(write/screenText) |  |  |  |  |  | ● | ● | ● |  |  |  |
| AC ACP引擎 |  | ● |  |  |  |  |  | ● | ● |  |  |  |  |
| AD 适配器 |  |  |  |  |  |  | — | ● |  | ○(testHmh) |  | ○(filesDir) |  |
| AIDock UI |  |  |  |  |  |  | ● | ○(事件类型) | ○(审批卡) |  |  | ○(autoPrompt) |  |
| PE 策略 |  |  |  |  |  |  |  | ●(仅类型) | — |  |  |  |  |
| TI 工具箱 |  |  |  | ○(PATH) |  |  |  |  |  |  |  |  | — |

native 依赖：LT → liblocalpty.so（ptyOpen/ptyWrite/ptyPoll/ptyResize/toolsChmod*，`cpp/types/localpty/Index.d.ts`）；SS/SftpPanel → libssh HAR（NAPI so）；RdpTab → librdpproxy.so（FreeRDP）。

## 关键耦合事实（对 tty7 施工的约束）

1. **单会话假设贯穿**：SS 全静态（`SessionService.ets:58-74`），TP 每次挂载 attach 单 view；SFTP 靠 sshHandle() 复用同会话。tty7 多 pane 并发 = 必须先做会话多实例化（M2 核心），且不能破坏 screenText/hasSession 契约。
2. **首连 tsfn 单例**：native 事件回调进程级唯一（SS 头部注释），多会话需 native 侧同步改造，是 M3 的 hidden dependency。
3. **AppStorage key 即总线**：ut.term.status/reason、ut.openSftp、ut.closeTab、ut.theme、ut.filesDir、ut.session.id —— 新 Shell 不得换 key 名，只能增。
4. **渲染热路径单线程**：TM.feed 在 tsfn 回调（主线程）执行，TP 的 ForEach span 粒度重绘靠 tick 计数。XComponent+NativeWindow 方案（01 文档）落地时 TM 的 model 语义保留、渲染面替换。
5. **agent 依赖收敛**：三引擎只依赖 SS 的三个查询口（hasSession/write/screenText），这是 M5 替换渲染层时的安全边界。
6. **凭据安全链**：CS→CredentialManager→EncCrypto→IdentityStore，SS.connect 物化。任何新模块读连接必须走 getSharedStore()，禁止 new ConnectionStore 后 load() 磁盘密文（TP aboutToAppear 注释红线）。
