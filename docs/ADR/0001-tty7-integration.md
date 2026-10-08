# ADR-0001：tty7 集成总体路线与分支策略

- 状态：已采纳（tty7-M0 冻结）
- 日期：2026-10-08
- 决策人：指挥官 + AI 总控（依据 01/02/03/04 文档与本次仓库侦察）

## 背景

oneAIterm（ArkTS/OpenHarmony，ArkUI 壳 + libssh/localpty native 底座 + 三引擎 Agent 体系）要与 tty7 terminal workbench 体验体系集成。两条候选路线：A) 把 tty7 的 gpui GUI 直接嵌入；B) 在 ArkUI 上同构重建 tty7 shell，复用 oneAIterm 全部既有能力件。

## 决策一：总体路线 = ArkUI 同构壳 + Native 终端核心 + HMH 一等 Provider

采纳路线 B，分三层：

1. **ArkUI 同构壳**：以 tty7 的 shell 信息架构（Sidebar / Tabs / PaneGrid / RightPanel / StatusBar / CommandPalette）为蓝本，在 ArkUI 上全新搭建。不复用、不移植 gpui 代码（03 文档红线「复制 gpui 到 ArkUI」）。现有 Index.ets 的 tab 分发、命令面板、AI Dock 作为素材小步吸收。
2. **Native 终端核心**：终端热路径沿 XComponent + NativeWindow 方向演进（01 文档候选），Rust NAPI VT core 为增量项；TermModel 的 feed/lines/screenText 语义作为稳定契约保留，渲染面替换不破坏 agent 读屏。
3. **HMH 一等 Provider**：HmhAdapter 保持 AgentProvider 六方法契约，agent 面板（状态/审批/attention）进 tty7 RightPanel；不重造第二套 Agent loop（03 文档红线），回落编排仍由 AgentAdapter 独占。

理由：gpui 与 ArkUI 运行时不可互通（R1）；oneAIterm 的 SSH/SFTP/DB/VNC/RDP/安全审批体系是成熟资产（capability matrix 中 keep 14 项），路线 B 资产保留率最高、风险最可控。

## 决策二（计划偏离记录）：分支策略

**02 文档原计划**：feature/tty7-shell 等多分支并行推进。

**本仓库现实**：main 上小步提交 + 每步可构建 + 指挥官逐 commit 验收的节奏（M0-M8 全部 relay 里程碑如此，见各文件头部 relay 注释惯例）；单人参战、无并行长命分支需求；gate 家族（unit/integration/e2e/license/sbom/security）以 main 为基准。

**决定**：不采用 feature/* 多分支。改为 **main 小步提交 + commit 标记 [tty7-Mx]**：

- 每个里程碑 M1-M9 的每一步施工都直接进 main，commit message 前缀 `[tty7-Mx]`（如 `[tty7-M1] shell: pane grid skeleton`）。
- 每步提交前必须：gate-unit 全绿（新增功能先补用例）、业务构建通过、不触碰 RISK_REGISTER 红线。
- 里程碑收尾打 tag `tty7-Mx-done`，作为回滚锚点。

**偏离理由**：多分支在单人+逐 commit 验收流程下只增加合并负担与「长命分支漂移」风险；main 小步与既有验收节奏同构，且任何一步坏了都能用 tag 精确回退。

**回滚策略**：
- 单步回滚：revert 对应 [tty7-Mx] commit（小步保证冲突面最小）。
- 里程碑回滚：reset 到上一个 `tty7-Mx-done` tag。
- 红线级事故（审批 fail-open、凭据泄漏）：立即停线，回滚到最近 tag，修复并补测试后方可继续。

## 后果

- 正面：资产保留最大化；验收粒度与既有节奏一致；回滚路径明确。
- 负面：main 上短期会有大量小 commit（指挥官验收成本）；ArkUI 壳重建工作量前置在 M1（已在 WBS 排期）。
- 后续 ADR 触发点：若 M3 证实 XComponent 路径不可行，或 HMH Provider 需要协议级变更，另立 ADR。
