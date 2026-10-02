# CHANGELOG

## V2.0.0 — Agent Adapter 可插拔架构升级

### 架构变更
- **Agent Adapter 层**：新增 `agent/` 模块，AgentProvider 六方法接口（createSession/prompt/subscribe/approve/cancel/resumeSession），AgentAdapter 引擎路由 + 回落编排
- **三引擎可插拔**：本地引擎（LocalAssistant 12轮回路）· HMH 适配器（HmhAdapter，hmharness SSE 12事件映射）· ACP 适配器（AcpClient，JSON-RPC 2.0 over HTTP+SSE）
- **安全管控基座**：PolicyEngine 五档判定（read_only/terminal/workspace_write/remote/destructive）· AuditWriter 脱敏审计 · ApprovalManager 审批状态机
- **删除 AgentKernel.ets**：等价回路迁入 LocalAssistant

### AI UX 升级
- **AIDock 改造**：三引擎选择 · 四类入口模式（会话/解释/生成/执行）· 展开高度 220px（不遮挡终端下半区）
- **ApprovalCard**：独立审批卡组件（档位徽标颜色分级 + 命令摘要脱敏 + 超时倒计时）
- **CapabilityDiscovery**：13种工具环境探测 · 缓存+AI注入 · 禁止模型猜测

### 协议适配
- **HMH 协议**：12种SSE事件→AgentEvent映射 · 审批桥接（approvalReq→need_approval→approve→approvalDone）· 会话恢复（Last-Event-ID）
- **ACP v1 协议**：JSON-RPC 2.0 transport（HttpSseTransport + AcpTransport接口预留stdio）· 七类方法映射 · permission→审批卡 · ACP v2 feature flag预留
- **握手失败处理**：服务不可达→engine_state_changed+回落LocalAssistant

### 基础设施
- **HarnessClient UTF-8 修复**：buf2str 从逐字节解码改为正确的多字节UTF-8解码（含代理对）
- **HarnessClient.send() 扩展**：4参数（task, mode, sessionId, fresh）
- **AgentSettingsStore 三段配置**：engines.local/engines.hmh/engines.acp + featureFlags

### 合规与门禁
- **软著合规资产**：SOURCE-PROVENANCE.md · PATCH-LEDGER.md · LICENSE-MATRIX.csv · SBOM.json
- **Release 门禁流水线**：gate.cmd 九环节（typecheck→unit→integration→E2E→security→license→SBOM→build→package）

### 构建验证
- default product（API24）：BUILD SUCCESSFUL ✅
- store product（API14）：BUILD SUCCESSFUL ✅

---

## V1.1.0 — 初始发布

- 一次性导入并改造为 KaihongOS/OpenHarmony ArkTS/ArkUI 应用壳
- 远程终端（SSH/Telnet/PTY）· 文件传输（SFTP/Zmodem）· 数据库 · 远程桌面 · 监控
- 内置 AI 智能体内核 · hmharness 增强模式
- 配置加密 · 双主题 · 中英双语 · 命令栏