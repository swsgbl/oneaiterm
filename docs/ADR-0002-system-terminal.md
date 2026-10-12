# ADR-0002: 终端核心切系统终端环境（ttyd + Web/xterm.js）

日期: 2026-10-12 · 状态: 已批准（用户指令「请重新设计」）· 前置: ADR-0001（路线 B 同构壳）

## 背景与动机

用户质询: 为什么「一站AI终端」不用系统终端环境和配置, 而自建终端环境? 并引用
「双 IME 环境互踩」为证。质询成立——自建输入层的补丁在失控（2026-10-12 一天
修了五坑: 双 \r / IME 活性让路 / 提交后焦点丢 / 显示残留差分对齐 / 多 pane
焦点 id 互抢）, 每一个都源于「ArkUI TextInput 自建受控输入通路」这一层。

当初自建的客观约束（存档, 非辩解）:
- 应用沙箱内无系统终端 UI 组件可嵌入（OpenHarmony 没有 TerminalComponent）;
- PTY 无系统服务可调（app 不能 exec 系统级托管 shell——沙箱铁墙实勘）;
- ADR-0001 红线: 不复制 gpui 到 ArkUI → 只能自研 VT 解析 + 文本渲染;
- ArkUI 里文本输入的唯一通路就是 TextInput+IME → 自建捕获层。

**被忽略的第三条路**（本 ADR 的核心）: 系统里本来就有完整的终端栈——
**ttyd**（VM 启动项, root, 0.0.0.0:27681, `-W -w / /bin/sh`, 自带 xterm.js
静态页面）+ **ArkUI Web 组件**（SDK 有, app 已有 INTERNET 权限）。
终端的渲染/输入/PTY/环境配置全部归系统, app 只做工作台壳。

## 决策

**终端核心从「自绘 VT + 自建输入」切换为「Web 组件加载系统 ttyd」**:

1. **PTY/shell 归系统**: ttyd 宿主 forkpty——TERM、winsize、环境变量、
   sh profile、stty 全部系统级标准行为, app 零维护。
2. **渲染+输入归 web 栈**: Web 组件加载 `http://127.0.0.1:27681`
   （ttyd 自带 xterm.js 页面, 零打包零 rawfile）。键盘输入走 web 引擎,
   **不经过 ArkUI TextInput/IME——「双 IME 互踩」问题类别整体消失**,
   五坑补丁全部失去存在必要。
3. **ArkUI 壳只做工作台**: 布局/pane/palette/Agent 面板/RightPanel/CLI 桥/
   存档——产品价值层全部保留（ADR-0001 不变的部分）。
4. **降级路径**: TermPaneView（自绘终端）保留——ttyd 不可达的环境
   （非本 VM 部署、ttyd 缺失）分流到旧渲染, 保底可用。

## 架构

```
┌─ ArkUI 工作台壳（不变）─────────────────────┐
│ PaneSurface ──► TermWebView（新, Web 组件） │
│    │              │ 加载 127.0.0.1:27681    │
│    │ ttyd 可达探测分流（不可达→TermPaneView │
│    │              │  旧自绘降级）            │
│ CommandBridge ──►│ ttyd 会话镜像（新）       │
└──────────────────┼──────────────────────────┘
                   ▼
        系统 ttyd（root, /bin/sh, xterm.js 页面）
```

- **TermWebView**: Web 组件封装。加载 ttyd 页; javaScriptOnDocumentStart 注入
  桥脚本（resize/标题/行计数 → arkTS 事件）; 深色主题注入。
- **ttyd 会话镜像**: app 侧以 WS 客户端旁路同一 ttyd 会话（ttyd 支持
  多客户端同 session）或独立镜像 session, 维护滚动缓冲 → CLI capture/
  wait/✓完成通知/PB 最近命令的 InputHistory 语义重接。
- **HMH term_write**: 经 ttyd WS stdin 帧写入（'0' 前缀协议）。

## 迁移范围

| 层 | 动作 |
|---|---|
| TermWebView（新） | Web 封装+注入桥+可达探测 |
| PaneSurface 本地分支 | 渲染 TermWebView（降级 TermPaneView） |
| CommandBridge send/capture/wait | 重映射到 ttyd 会话镜像 |
| TermHost/LocalTerminalService | 降级路径专用（不再主线） |
| TermPaneView/InputController | 降级路径保留（补丁已修, 不新增） |
| WorkbenchVm/palette/Agent/SFTP/Git/存档 | 不变 |

## 风险

- **R1 Web 组件在 KaihongOS VM 的运行实况**（渲染/键盘/WS）——RD-PoC 棒
  go/no-go 门, 实测不过则回滚本 ADR。
- **R2 ttyd 是外部服务**——不归 app 生命周期管; 缓解: 启动探测+降级路径+
  文档注明部署依赖。
- **R3 沙箱 loopback 出站到 root 服务**——先例充分（RemoteTermHost 连
  10.0.2.2; 桥自身 loopback listen）, PoC 实证。
- **R4 多客户端会话镜像语义**（capture 与 Web 视图一致性）——RD-2 实勘
  ttyd 多连接行为, 不一致则改「Web 内注入截取上报」方案。

## 分棒

- **RD-PoC**: 最小 TermWebView 连 ttyd——打字/回显/resize/标题全链实证
  （go/no-go 门, 不过即废弃本 ADR）。
- **RD-1**: PaneSurface 接入+可达探测分流+降级路径。
- **RD-2**: 桥重映射（send/capture/wait/✓通知/InputHistory）。
- **RD-3**: 清理+单测重定位+全 gate 回归。

## 红线复核

- 不复制 gpui 到 ArkUI ✓（xterm.js 是 ttyd 系统页面, 非我们移植 gpui）;
- 不重造第二套 Agent loop ✓（Agent 层不动）;
- 桥只 listen 127.0.0.1 ✓; 秘密不入日志 ✓; 沙箱内零越权 ✓。
