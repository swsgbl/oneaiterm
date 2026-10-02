# PATCH-LEDGER 本地补丁台账

记录从 upstream uniTerm 到当前版本的全部本地补丁。
维护约定：**任务完成即追加**，每个升级任务的变更同步记录于此。

基线：upstream uniTerm（https://github.com/ys-ll/uniterm，Apache-2.0，upstream commit 待确认）

## 已有本地补丁（截至冻结基线 df6f159）

| # | 补丁主题 | 涉及文件 | 对应 commit |
|---|---|---|---|
| 1 | 一次性导入并改造为 KaihongOS/OpenHarmony ArkTS/ArkUI 应用壳（改名 One AI Term/一站AI终端） | 全仓（app/） | 676e489 |
| 2 | 清理 residual upstream 名称提及（scripts/LICENSE attribution line） | scripts 相关 | 1d5dcb3 |
| 3 | 终版名称清扫 + 删除中间构建产物（out/） | 全仓 | 7c95391 |
| 4 | ignore 本地端口工具（_port.cjs）与 token 文件（.ag-token.txt） | .gitignore 等 | df6f159 |

## 升级期补丁（本次全面升级，Phase 0~6）

| # | 补丁主题 | 涉及文件 | 对应任务/commit |
|---|---|---|---|
| P0-1 | 新增软著合规资产：SOURCE-PROVENANCE.md、PATCH-LEDGER.md、LICENSE-MATRIX.csv、SBOM.json | 根目录新增 4 文件 | Phase 0（1.3~1.6） |
| P1-1 | Agent Adapter 层与安全管控基座：新增 agent/ 模块 7 文件（AgentProvider 六方法接口/AgentSessionStore/AgentAdapter/PolicyEngine 五档判定/AuditWriter 脱敏审计/ApprovalManager 审批状态机/LocalAssistant 引擎）；AgentSettingsStore 三段配置 + 存量迁移；AIDock/SettingsTab 收口改造（仅依赖 AgentAdapter）；删除 AgentKernel.ets（回路迁入 LocalAssistant）；LlmConfig harnessUrl 移除 | agent/*、service/AgentSettingsStore.ets、service/Llm.ets、service/LlmConfigStore.ets、components/AIDock.ets、components/SettingsTab.ets、app/entry/src/test/*.test.ets | Phase 1（2.1~2.14） |

| P2-1 | HMH Adapter：新增 HmhAdapter.ets（348行，12种SSE事件→AgentEvent映射，审批桥接，会话恢复）；HarnessClient.ets UTF-8解码修复 + send()签名扩展（4参数）；AgentAdapter注册HmhAdapter | agent/engine/HmhAdapter.ets(新增)、service/HarnessClient.ets、agent/AgentAdapter.ets | Phase 2（3.1~3.7） |
| P3-1 | ACP v1 接入：新增 AcpClient.ets（~500行，JSON-RPC 2.0 over HTTP+SSE，七类方法映射，permission→审批卡，ACP v2 feature flag预留，握手失败处理）；AgentAdapter注册AcpClient（三引擎：local+hmh+acp） | agent/engine/AcpClient.ets(新增)、agent/AgentAdapter.ets | Phase 3（4.1~4.5） |
| P4-1 | AI UX与能力探测：新增 CapabilityDiscovery.ets（253行，13种工具探测+缓存+AI注入）；新增 ApprovalCard.ets（186行，档位徽标+超时倒计时+允许/拒绝）；改造 AIDock.ets（三引擎选择+四类入口模式+220px展开高度+档位徽标颜色分级） | agent/discovery/CapabilityDiscovery.ets(新增)、components/ApprovalCard.ets(新增)、components/AIDock.ets | Phase 4（5.1~5.6） |
| P5-1 | KaihongOS适配与加固：双product构建验证（default API24 + store API14 均 BUILD SUCCESSFUL）；离线降级提示已在HmhAdapter/AcpClient中实现（服务不可达→engine_state_changed+回落） | 验证性任务，无新增文件 | Phase 5（6.1~6.4） |
| P6-1 | Release测试门禁：新增 gate.cmd 九环节门禁流水线骨架（typecheck→unit→integration→E2E→security→license→SBOM→build→package） | app/scripts/gate.cmd(新增) | Phase 6（7.1~7.2） |