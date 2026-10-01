# 一站AI终端 · One AI Term

面向 KaihongOS 桌面环境的**一站式 AI 终端管理软件**——远程连接、文件传输、数据库、远程桌面与**可操作终端的 AI 智能体**集于一体。

## 核心能力(V1.1.0,均经真机验证)

| 类别 | 能力 |
|---|---|
| 远程终端 | SSH(密码/密钥/身份库)· Telnet · 本地终端(PTY)|
| 文件传输 | SFTP 浏览/上传/下载 · Zmodem(rz/sz)|
| 数据库 | PostgreSQL(wire v3)· Redis(RESP)· MySQL |
| 远程桌面 | VNC(RFB 3.8)· RDP(原生桥)|
| 监控 | CPU/内存/进程实时面板 |
| **AI 智能体** | **内置智能体内核**:自然语言下达任务→工具调用(读写终端/SFTP)→分级审批→会话审计;**增强模式**:可连接自建 [hmharness](https://github.com/swsgbl/hmharness) 服务获得多智能体/MCP 生态 |
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
