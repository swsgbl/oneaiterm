# oneaiterm · 工作台交付集成文档(任务 M9)

> 适用:M0-M9 交付形态。本文档面向集成方/后续维护者,给出架构总览、
> 各里程碑交付清单、已知限制与 M9 后路线。命令参考见 `tools/README.md`。
>
> **借鉴说明**:工作台 shell 信息架构(Sidebar/Tabs/PaneGrid/RightPanel/
> StatusBar/CommandPalette)与命令面板交互设计,借鉴自开源项目
> tty7(github.com/l0ng-ai/tty7,MIT 协议);实现为本仓 ArkUI 全新自研,
> 未复制其任何代码(架构性差异见 §4 末「与官方 tty7 的对比」)。

## 1. 架构总览

```
┌────────────────────────── AppShell(壳,aboutToAppear 起 CLI 桥)──────────────────────────┐
│ Sidebar(工作区)  TabBar(页签)  PaneGrid(窗格栅格)  RightPanel(Agent|SFTP)  StatusBar    │
│        └── Palette(⌘K 命令面板:布局/会话/主题/Git/CLI 状态)                               │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ 布局树 LayoutTree/LayoutOps(纯函数:split/close/focus/panes;持久化经 WorkbenchStore)     │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ 会话宿主(Provider 模式)                                                                  │
│   TermHost     本地单例 PTY(远程 provider 需先 close 释放)                                │
│   RemoteTermHost  SSH 单例(SessionService 复用 + RemoteWorkspaceProvider accept→dataSink) │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ AgentEvent v1 总线(AgentEventBus 环形 200 条)← HmhEventBridge(零改动桥,Hmh 事件映射)    │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ GitService(远程系统 git 经 SSH 标记法 RemoteCommandRunner;读 status/log/diffStat,        │
│            写 stage/unstage/commit/pushDry——写操作经 AuditWriter 落 agent-audit.jsonl)  │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ CommandBridge(CLI 桥:TCP JSON-RPC,仅 listen 127.0.0.1:18971;首行 token 握手——           │
│   filesDir/cli_token 真文件 64 hex 双 UUID,恒时比较;10 命令,send/capture 驱动 UI)      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **壳层**:AppShell 组装;布局是纯数据树,一切变更经 LayoutOps 纯函数
  产生新树(可测、可回放);WorkbenchStore 序列化布局+会话名到
  preferences(无秘密——凭据在 ConnStore/CredentialManager 加密面)。
- **会话宿主**:本地/远程互斥单例;远程 provider 把 SessionService 的
  accept 数据流引到 pane 的 TermModel(渲染/输入链全复用)。
- **AgentEvent 总线**:引擎侧(HmhAdapter)与 UI 侧解耦的标准事件流;
  审批卡/checkpoint 文案/pane 绑定均消费此总线。
- **CLI 桥**:VM 侧 node 工具(oneaiterm-cli.js)驱动真机工作台,
  E2E 验收的主力通道。

## 2. 里程碑交付清单(M0→退役终态,git log --oneline 核对)

| 里程碑 | hash | 交付 |
|---|---|---|
| M0 | `6ab035e` | 骨架:AppShell/Sidebar/TabBar/PaneGrid/StatusBar/Palette 壳 + 布局树 |
| M1a | `a590a76` | LayoutTree 纯函数(split/close/focus)+ BackspaceKey 等价测试 |
| M1b | `b99e507` | PaneSurface 渲染 + 键盘路由 |
| M1c | `806078f` | WorkbenchVm 布局集成(多 tab/多 pane 状态机) |
| M1d | `be3e43d` | Palette 命令注册表 |
| M2a | `6040727` | WorkbenchStore 布局持久化(preferences) |
| M2b | `1ad8858` | 会话挂接 + 多工作区 + 存档 v2 |
| M3a | `aaf66e0` | TermHost 本地 PTY 桥接 + 终端会话生命周期 |
| M4a | `58462c8` | InputController:输入历史/ghost/Tab 补全 |
| M4b | `c525e03` | 终端渲染细化(滚动/选型) |
| M5a | `12a99fa` | AgentEvent v1 总线 + HmhEventBridge 映射 |
| M5b | `cfa7fa1` | 审批卡 + pane 绑定 + checkpoint 文案 |
| M6a | `27c51e1`+`aad96a3` | RemoteWorkspaceProvider + RemoteTermHost(SSH pane) |
| M6b | `5c76646` | RightPanel 页签化 + SFTP 浏览(只读) |
| M7a | `d199fd3` | GitService 只读态(status/log/diffStat,标记法远程命令) |
| M7b | `df880de` | git 写操作(stage/unstage/commit/pushDry)+ 转义双闸 |
| M8a | `6df563f` | CommandBridge CLI 桥首发六命令 |
| M8b | `1c56c1e` | 桥扩 agents/events/wait/git + M8b 热修(wait/git 桥侧崩点移 CLI) |
| M9 | `3b081da` | 真 token + git 写审计 + 安全自查收口 + 本文档 |
| 收官 | `917d0ba`+`a9cb958` | Release Gate 九环节全绿 + Device Smoke 6/6 + 默认 GUI=工作台 |
| parity | `0d70cd8`+`a7d7eb5` | 官方仓库对照审计 + PA 棒(CLI 19 命令) + PB 棒(palette 最近区+完成通知+trimBlankTail 热修) |
| 输入热修 | `dcc9731` | 终端输入链五坑修复(双 \r/IME 让路/提交后焦点/显示残留/pane id 唯一化) |
| RD(重设计) | `dd1c28d`..`dda0ac9` | **ADR-0002 系统终端栈**:Web 组件加载系统 ttyd(xterm.js,渲染/输入/PTY/环境全归系统)——PoC go 门(五项)→运行时探测分流(RD-1)→CLI 桥同会话注入(RD-2)→**RD-2b 终修(dda0ac9):term 层接管 send/探针/活性(triggerDataEvent,pageEnd 直装+重试梯),弃用 ws wrap 与 one-shot refresh;VM 实证 B1/B3 双过** |
| LEG(退役) | `02a1fb0`..`faa5dfe` | **旧界面退役四棒**:连接档案管理(RightPanel 第4页签+Dialog 表单)→Telnet+AI 三引擎 pill→收藏置顶+隧道 palette 命令+Zmodem 差异注记→**Index 壳化 108 行+删旧四文件 3362 行+E2E 门禁迁工作台** |
| FR(冷启健壮) | 本轮 | **冷启即用+可见性门控+崩溃复活**:全新基线 p1 直接绑本地会话(首启跳过引导即见活终端,原双水印占位);ArkWeb 隐藏窗口创建的 Web 永不 attach 且无重试→PaneSurface web 分支门控 vm.shellVisibleTick(Index.onPageShow 驱动);存档 local 槽复活 TermHost(原仅标题恢复=「崩溃恢复占位陷阱」);firstLocalSlotPaneId 纯函数+3 单测。VM 实证:V1a 冷启即用 F1-F4 全过(date 干净进 capture),V1b kill-9 复活 R1-R3 全过(REVIVED×2) |

> 终态(2026-10-20):工作台是唯一界面;RD-2 闭环+FR 冷启健壮;全量 Release Gate
> 9/9 ALL PASSED(typecheck/unit 295/integration/E2E 金链/security/
> license/SBOM/双 product build/package)——发布就绪。

## 3. 安全要点(M9 收口)

- CLI 桥仅 listen `127.0.0.1`;token 握手失败即断,token 不进 hilog、
  不全量回显(palette 只显前 4 字)。
- token:app 冷启读/生成 `filesDir/cli_token`(双 UUID 拼接 64 hex =
  32 字节熵);恒时比较(逐字节异或累积)。
- git 写操作(stage/unstage/commit/pushDry)经 AuditWriter 落
  `filesDir/agent-audit.jsonl`(argsDigest 脱敏+截断;agent/ 目录零改动)。
- CLI send 的 text 不进 hilog;git 子命令白名单(status/log),写操作
  不经 CLI。
- git 命令注入面:quoteCwd/quotePath/quoteMsg 三重转义闸(引号/
  反斜杠/元字符拒绝或包裹)。

## 4. 已知限制与官方仓库 parity 架构差异

产品内限制:
- **PTY 多实例**:TermHost 单例(一本地 pane);多本地终端需 PTY
  多实例化(路线项)。
- **无 XComponent native 渲染**:当前文本渲染链;native GPU 渲染留路线。
- **procs/ports 沙箱不可达**:应用沙箱无 /proc 权限(README 已述)。
- **IME/VM 环境历史问题**:KaihongOS VM 输入法损坏历史,UI 驱动走
  CLI send 注入;输入链(keyEvent→受控字段→提交→历史)本身健常。
- **exec/run**:CLI 侧可用 send+wait+capture 组合编排;run(PTY 执行+
  退出码透传)受沙箱单 PTY 限制未单列。

与官方 tty7(github.com/l0ng-ai/tty7)的**架构性差异**(同构近似,
不实现——.verify/workbench/PARITY-AUDIT.md 逐项对照):
- **machine/server 组**:官方有桌面 daemon 多机拓扑;我们为单 app+
  本机桥(127.0.0.1:18971),status 已把 server 概念映射为 bridge+vm
  快照。
- **run**:官方 PTY 执行+退出码透传;我们 exec 语义由 CLI 组合编排
  (send+wait+capture),单 PTY 沙箱限制。
- **tab 休眠**:官方休眠 tab 释放内存;我们 app 生命周期内 tab 常驻
  (ArkUI 组件树生命周期差异)。
- **持久会话/保活**:官方 server 拥有会话跨 UI 重启;我们布局/槽持久
  化(WorkbenchStore)+PTY 冷启不保活(app 沙箱无后台常驻保证)。
- **文件树面板**:官方 side panel 有文件树/find in files;我们
  SFTP 浏览器覆盖远程侧,本地侧沙箱文件访问受限(棒 C 候选)。
- **Zmodem(rz/sz)**:协议级依赖 app 侧 PTY 数据流检测(B00/B01 seed
  滑窗)——web 终端(ttyd)架构下数据流归系统栈,app 无从检测;Zmodem
  服务层(ZmodemService)随库保留,UI 挂接随旧界面一并退役(检测器在旧
  TerminalPage 数据流);web 分支协议级不支持——完整功能归档于 M8-relay5
  时代(git 历史)。

**M9 后路线**:PTY 多实例 → XComponent native 渲染 → scrollback
选区(M3c 搜索已交付)→ 文件树面板(棒 C)→ issues/PR 集成(远期)。

## 5. 命令参考

CLI 工具用法与命令全集见 `tools/README.md`(token 获取/握手/19 命令:
doctor/status/events/agents/workspace.list/ws.tree/ws.new/ws.close/
tab.list/tab.new/tab.close/tab.rename/pane.list/pane.split/pane.close/
send[--text/--keys]/capture/wait/git 组;send+wait+capture 编排示例)。
