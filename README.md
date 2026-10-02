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
