# CHANGELOG

## V2.1.0 — M8 真机化里程碑

> 基线：V2.0.0（a024cf0 谱系）；本版覆盖 M8 真机化接力 commit 区间 1695d1f..d210e49。以下能力均在 KaihongOS 5.0 VM 真机端到端实证。

### 新能力
- **SSH 本地隧道 -L**：原生 direct-tcpip 通道 + 隧道面板启停；默认 127.0.0.1:9432→远端 22，footer 实时显示监听状态与已转发连接数（实证：nc 9432 回传 `SSH-2.0-OpenSSH` banner）
- **MySQL 客户端真机可用**：对 mysql:8.4（native_password）握手/认证/查询全链实证，SQL 结果屏显（实证：屏显 `MYSQL-PARITY-OK`）
- **Zmodem 双向文件传输（rz/sz）**：协议核心经离线 wire 验证（对真实 lrzsz），二进制安全三层通道；1MiB（1048576B）文件双向传输 md5 精确一致（sz→app 接收 + app→rz 发送）
- **AI Dock 本地引擎真回路**：自然语言→审批卡→终端执行→审计落盘全链真机闭环（实证：审批点击→终端屏显 3.7s）

### 修复
- **本地终端 so 从未进包**：VM 打包链回落 C++ packer 丢失自有 native 库，liblocalpty/librdpproxy 历次装机均缺席——repack 注入预编译产物，7/7 so 齐全
- **Agent 工具在本地终端死路**：SessionService 新增 attachLocalPty 桥，本地 PTY 会话注册进 Agent 可写通道
- **Agent 屏幕指纹等待过慢**：termWrite waitScreen 轮询 400ms→150ms + shell 提示符提前接受，审批→屏显从 ~17 分钟降至秒级（实测 3.7s）
- **MySQL wire 协议五连修**：seq 跟随服务端帧并按查询重置 · 最小 caps 握手 · AuthSwitch 盐尾 NUL 剥离 · 列定义后 EOF 消费 · lenenc 切片偏移（均为真机 E2E 现场发现并修复）
- **Zmodem fs 签名与统计**：fs.fd 签名修复；tx-done 记真实字节数（1048576B，此前恒 0）

### 工程化
- **vm-deploy.cmd 一键装机链**：sync/adapt/build/repack/sign/install/smoke 全链单命令，附 VM-BUILD.md 运行手册
- **ohosTest 测试模块 + 真机执行**：10 套件迁入官方 TestAbility 接线，hypium 真机跑 130 用例 130 通过 0 失败
- **九环节门禁全真接线**：unit/security/e2e/integration 改为设备真实执行 + 诚实 fail-closed（拔设备模拟 exit 1 实证）；license/sbom/package 标注为静态 tripwire
- **两轮全量回归 RELEASE-READY**：R1-R8 8/8（部署/SSH 金标/Agent 回路/隧道/MySQL/Zmodem 双向/host 门禁），两轮分别 @ M8 中段与 a024cf0

---

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