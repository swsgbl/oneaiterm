# RISK_REGISTER — 风险登记（tty7-M0，承接 02 文档风险清单并按仓库现实增补）

状态：open / mitigated（有已知缓解）/ accepted。每条给仓库现实佐证。

## 承接 02 文档的基础风险

| # | 风险 | 状态 | 仓库现实佐证与增补 |
|---|---|---|---|
| R1 | gpui GUI 无法直接复用到 ArkUI | accepted | 决策见 ADR-0001；ArkUI 无 gpui 等价物，壳全量重建 |
| R2 | 多会话化破坏既有单会话假设 | open | `SessionService.ets:58-74` 全静态单会话；SFTP 依赖 `sshHandle():329` 复用；agent 依赖 hasSession/screenText 契约。M2 施工需先立会话对象化门面 |
| R3 | 审批链 fail-open | open（红线） | `ApprovalManager.ets:50` open 档直批是用户显式选择而非默认；任何新代码路径不得引入「审批失败→放行」分支 |
| R4 | 凭据泄漏进日志/审计 | open（红线） | AuditWriter digest 脱敏 + SessionService.connect 日志只打 pwlen/keylen（`:234`）；新模块照此纪律 |
| R5 | 环境定时器不可靠 | mitigated | setInterval ~20s 停摆实证（TerminalPage startPoll 注释）；自链式 setTimeout+watchdog 范式必须沿用到一切新轮询 |
| R6 | tsfn 回调不交付（部分环境） | mitigated | localpty 走同步 ptyPoll 绕道（`Index.d.ts:6` 注释）；SSH 通道仍依赖 tsfn——多会话 native 改造时优先验证 |

## 按仓库现实增补

| # | 风险 | 状态 | 说明 |
|---|---|---|---|
| R7 | 首连 tsfn 回调进程级单例限制多会话 | open | SessionService 头部注释明示「FIRST sessionOpen wins for the whole process」；M3 native 侧需句柄表化，否则多 SSH pane 事件串线 |
| R8 | AppStorage key 是隐式总线 | open | ut.term.status/reason、ut.openSftp、ut.closeTab、ut.filesDir 等散布多页；换名即断；新壳只能增 key，且需在基线中登记（本文件即登记处） |
| R9 | 共享 store 解密态被磁盘密文覆盖 | open（红线） | TerminalPage aboutToAppear 注释：getSharedStore() 已解密，重新 load() 会用 enc:v1 密文覆盖内存明文。任何新消费者必须走 getSharedStore |
| R10 | Index.ets 1214 行巨石外壳 | open | tab 分发、面板、命令面板、引导全在一个文件；M1 重构为 tty7 Shell 时是最大接触面，需小步拆出、每步可构建 |
| R11 | ConnList.ets 1352 行 | open | 同上，承担 store 初始化责任（setIdentities 调用点），拆动时不能丢初始化时序 |
| R12 | 渲染热路径在主线程 | open | TM.feed 在 tsfn 回调执行、ForEach span 重绘靠 tick；XComponent 方案迁移前，大流量场景（20000 行洪水）靠窗口快照撑着——M3 性能验收以此为基线 |
| R13 | display API 在 VM 量出虚假尺寸 | mitigated | measureDims 只信宽度、onAreaChange 700ms 开窗防抖（TerminalPage 实勘注释）；新 Shell 尺寸计算沿用此纪律 |
| R14 | thirdparty HAR 双架构漂移 | open | libssh-x86_64-har 需与 arm64 产物同步构建（scripts/build-arm64.sh 等）；引入 Rust NAPI（01 文档候选）时同样要双架构 |
| R15 | 工具箱 38MB 解压时长 | accepted | ToolsInstaller 后台 fire-and-forget；首启体验依赖 rawfile 打包体积 |
| R16 | ohosTest 既有 12 测试是回归底线 | open | M1 起每个里程碑必须保持全绿再加新用例；gate-unit.cmd 是执行入口 |

## 红线汇总（违反即中断）
1. 审批不得 fail-open（R3）。2. 凭据/密钥不得进日志或审计明文（R4）。3. 不得绕过 getSharedStore 直接 load 磁盘密文（R9）。4. AppStorage 既有 key 不得改名（R8）。5. 既有测试不得删改语义（R16）。6. 每步可构建，gate 全绿才提交（R16/02 文档）。
