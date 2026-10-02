# SOURCE-PROVENANCE 来源溯源记录

生成日期：2026-10-01
冻结基线：tag `oneaiterm-softcopyright-baseline` → commit `df6f159`
维护约定：每个升级任务完成后同步追加/更新本文件（另见 PATCH-LEDGER.md）。

> 本文件按五类来源分开记录，不混记。开源代码（Apache-2.0/MIT/LGPL 上游）标注为
> upstream/third-party 而非原创。

## 1. uniTerm upstream

| 项目 | 内容 |
|---|---|
| 来源仓库 | https://github.com/ys-ll/uniterm |
| 许可证 | Apache-2.0 |
| upstream commit | 待确认（初始导入为一次性快照，未记录上游具体 commit 哈希） |
| 引入方式 | 一次性导入后本地改造（见 PATCH-LEDGER.md） |
| 记录状态 | **来源待确认**：upstream commit 哈希无法验证，不声明原创 |

涉及范围：应用脚手架骨架、部分终端/连接管理基础结构（经大量本地改造，
差异清单见 PATCH-LEDGER.md）。

## 2. hmharness upstream

| 项目 | 内容 |
|---|---|
| 来源仓库 | https://github.com/swsgbl/hmharness |
| 许可证 | 待确认（未分发其代码） |
| 引入方式 | **非代码依赖**：仅作为增强模式可连接的外部 Agent Runtime 服务；`app/oh-package.json5`（name "upstream"，description "scaffolded by hmharness"）表明工程脚手架由 hmharness 工具链生成 |
| 记录状态 | 代码零复制；不构成运行时依赖 |

## 3. third-party（第三方组件）

| 组件 | 版本 | 许可证 | 链接方式 | 来源 | 修改 |
|---|---|---|---|---|---|
| libssh | 0.11.1 | LGPL-2.1 | 动态链接（@ohos/libssh 1.0.4 HAR 封装） | https://www.libssh.org；上游源码快照 `app/thirdparty/ohos_ssh-src`（LGPL-2.1，版本 1.0.4）与原始压缩包 `app/thirdparty/downloads/libssh-0.11.1.tar.xz` | 未修改 |
| OpenSSL | 3.5.4 | Apache-2.0 | 动态链接（随 @ohos/libssh HAR 分发） | https://www.openssl.org；`app/thirdparty/downloads/openssl-3.5.4.tar.gz` | 未修改（交叉编译适配见 app/thirdparty/build-*.sh） |

## 4. own code（自研代码）

版权所有：2026 The One AI Term Authors（Apache-2.0）

| 范围 | 位置 |
|---|---|
| ArkTS/ArkUI 应用壳与页面 | app/entry/src/main/ets/pages/、entryability/、common/ |
| 协议客户端实现 | PostgreSQL v3 wire（PgService/PgTab）、Redis RESP（RedisService/RedisTab）、VNC RFB（VncClient/VncService/VncTab）、Telnet IAC（TelnetService）、MySQL（MySqlService/MySqlTab）、RDP/SPICE 桥接（RdpTab/SpiceTab/SpiceClient） |
| 终端与服务层 | TerminalPage、SessionService、LocalTerminalService、SftpPanel、K8sTab/K8sService、MonitorPanel、FileSidebar |
| 连接与凭据管理 | store/（ConnStore、ConnImporter、UtmExport、IdentityStore、CredentialManager、EncCrypto PBKDF2+AES-256-GCM 加密配置） |
| AI 智能体（存量，Phase 1 起改造为 Adapter 架构） | service/AgentKernel、service/Llm、service/HarnessClient、service/LlmConfigStore、service/AgentSettingsStore、components/AIDock、components/SettingsTab |
| UI 组件 | components/（其余组件） |
| agent/ 新增模块（升级期产生，逐任务追加） | app/entry/src/main/ets/agent/（Phase 1 起新增） |

## 5. integration code（集成/适配代码）

| 范围 | 位置 | 说明 |
|---|---|---|
| NAPI 原生模块 localpty | app/entry/src/main/cpp/localpty.cpp、types/localpty/、libs/{arm64-v8a,x86_64}/liblocalpty.so | 本地 PTY 适配层，预编译产物双 ABI，源码自研 |
| NAPI 原生模块 rdpproxy | app/entry/src/main/cpp/rdpproxy.cpp、types/rdpproxy/、libs/{arm64-v8a,x86_64}/librdpproxy.so | RDP 代理适配层，预编译产物双 ABI，源码自研 |
| libssh/openssl 交叉编译适配 | app/thirdparty/build-*.sh、probe-*.sh | 构建适配脚本，自研 |
| OpenHarmony 三方库 HAR 封装 | app/thirdparty/libssh-x86_64-har/ | @ohos/libssh 1.0.4 HAR 包（封装 libssh 0.11.1 + OpenSSL 3.5.4），内部未修改 |

## 溯源验证方法

- 初始导入：commit `676e489`（One AI Term V1.1.0 — initial release，2026-10-01，作者 wu）
- 本地补丁：见 PATCH-LEDGER.md
- 许可证矩阵：见 LICENSE-MATRIX.csv
- SBOM：见 SBOM.json