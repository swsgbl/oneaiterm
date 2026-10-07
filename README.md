# 一站AI终端 · One AI Term

面向 KaihongOS 桌面环境的**一站式 AI 终端管理软件**——远程连接、文件传输、数据库、远程桌面与**可操作终端的 AI 智能体**集于一体。

## 核心能力(V2.0.0,Agent Adapter 可插拔架构)

| 类别 | 能力 |
|---|---|
| 远程终端 | SSH(密码/密钥/身份库)· Telnet · 本地终端(PTY)|
| 文件传输 | SFTP 浏览/上传/下载 · Zmodem(rz/sz)|
| 数据库 | PostgreSQL(wire v3)· Redis(RESP)· MySQL |
| 远程桌面 | VNC(RFB 3.8)· RDP(原生桥)|
| 监控 | CPU/内存/进程实时面板 |
| **AI 引擎** | **三引擎可插拔**:本地引擎(12轮回路)· HMH 适配器(hmharness SSE)· ACP 适配器(JSON-RPC 2.0);自然语言→工具调用→五档安全分级→审批状态机→审计脱敏 |
| **安全管控** | 五档分级(read_only/terminal/workspace_write/remote/destructive)· 审批卡(档位徽标+超时倒计时)· 脱敏审计日志 |
| **能力探测** | 13种工具环境探测(node/git/python/docker/...)· 缓存+AI注入· 禁止模型猜测 |
| 管理 | 分组/收藏/最近 · 配置加密(PBKDF2+AES-256-GCM)· .utm/connections.json 兼容导入导出 |
| 外观 | 命令栏(Ctrl+K 命令面板)· 可折叠导航坞 · 状态栏 · 深浅双主题 · 中英双语 · 首启引导 |

## 能力与实证状态(V2.1.0,M8 真机化里程碑)

以下按"是否在 KaihongOS 5.0 VM 真机端到端实证"分栏;判据均为可复核的金标读数(证据存 `.verify/m8r*/`)。

### 已实证(VM 真机金判据)

| 能力 | 判据 |
|---|---|
| SSH 终端 | 金标 marker 屏显双命中(命令回显+输出行,uterm@10.0.2.2:2222) |
| SFTP(承继) | 承继实证(V2.0.0 谱系),两轮全量回归随包装载无回归 |
| 本地终端(PTY) | PTY 125x20 连接成功,Agent 工具经 PTY 执行屏显 |
| SSH 隧道 -L | nc 9432 回传 `SSH-2.0-OpenSSH` banner;footer 转发计数 0→1 |
| MySQL 客户端 | mysql:8.4(native_password)查询,屏显 `MYSQL-PARITY-OK` |
| Zmodem 双向 | 1MiB(1048576B)双向传输,双侧 md5 完全一致(rz/sz) |
| Agent 本地引擎回路 | 审批卡→允许→终端屏显 3.7s;审计 jsonl 落盘(approval/term_write/run);拒绝路径实证(destructive 拦截) |
| **HMH 远端引擎** | 设备→WSL socat→Windows daemon(7791)→GLM-5.3 真链路;dock 流式渲染(hello/line/delta/final/tool 卡+档位徽标);审计 prompt+final 落档;零回落零崩溃(`.verify/m8r13`) |
| **ACP 引擎(mock)** | ACP v1 JSON-RPC 握手(initialize 1.0/session-new/prompt)+SSE 订阅一次点火;双 delta 流式+tool 卡渲染;会话 engine=acp finished、审计 final 落档(`.verify/m8r14`) |
| AI Dock UX | 自然语言→审批卡(档位徽标+超时倒计时)→执行→`task completed` 终态 |
| want 直驱开发通道 | `--ps agentPrompt/--ps agentEngine` 绕过 UI 输入直接驱动任意引擎(并发使用/自动化场景) |
| **本地终端工具箱** | 应用沙箱内自带工具链(jitless node+hmh+libc++),`install-board-tools.cmd` 一键供应,终端开箱即跑板端工具,零配置;系统命令(/bin,/system/bin)装完即用(`.verify/m8r13` 沙箱审计) |
| 加密配置(承继) | 承继实证(V2.0.0 谱系,PBKDF2+AES-256-GCM) |

### 后续路线

| 项 | 说明 |
|---|---|
| arm64 运行时 | 编译面已实证(relay12:符号集/SONAME/NEEDED 与 x86_64 完全对齐);arm64 真机运行时待铺 |
| ACP 真实服务联调 | 引擎协议面已对 mock 实证;接真实 ACP Agent 服务待排期 |
| termWrite 屏幕指纹优化 | 3.7s 已达标,等待策略可进一步收紧 |
| 多会话隧道选择 UI | 当前隧道绑定单一 SSH 会话 |

## 系统要求

KaihongOS 5.0+(x86_64/arm64),API 14+。

## 构建

```bat
cd app
scripts\build.cmd          # 构建 HAP(双 ABI)
scripts\build-store.cmd    # API14 兼容包
```
原生模块(libssh/openssl/localpty/rdpproxy)预编译产物已含于 `app/thirdparty/`;重编需 WSL 交叉编译链(见 `app/thirdparty/build-napi-*.sh`)。

## 许可

Apache License 2.0。本软件含第三方组件,归属与许可详见 [NOTICE](NOTICE)。

## 链接

- GitHub: https://github.com/swsgbl/oneaiterm
- AtomGit: https://atomgit.com/hongfu/oneaiterm
- 隐私政策: [PRIVACY.md](PRIVACY.md)
