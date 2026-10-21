/**
 * hypium 单测注册入口（升级 Phase 1 / 任务 2.2）。
 * 存量 BackspaceKey.test.ets + 新架构等价测试。
 */
import { describe, it, expect } from '@ohos/hypium';
import policyEngineTest from './PolicyEngine.test.ets';
import auditRedactTest from './AuditRedact.test.ets';
import agentSessionStateTest from './AgentSessionMeta.test.ets';
import acpClientTest from './AcpClient.test.ets';
import capabilityDiscoveryTest from './CapabilityDiscovery.test.ets';
import approvalCardTest from './ApprovalCard.test.ets';
import agentAdapterTest from './AgentAdapter.test.ets';
import approvalManagerTest from './ApprovalManager.test.ets';
import backspaceKeyTest from './BackspaceKey.test.ets'; // +M1a: layoutTreeTest (ListTest runner 静态引用本文件，不注册则新套件不执行)
import layoutTreeTest from './LayoutTree.test.ets';
import workbenchVmTest from './WorkbenchVm.test.ets'; // +M1c: Vm 布局集成
import appI18nTest from './AppI18n.test.ets'; // +GUI-i18n: 国际化纯函数
import uiFontTest from './UiFont.test.ets'; // +GUI-R3: 界面字号纯函数
import updateCheckerTest from './UpdateChecker.test.ets'; // +GUI-R3: 更新检查纯函数
import paletteCommandsTest from './PaletteCommands.test.ets'; // +M1d: 命令面板注册表
import workbenchStoreTest from './WorkbenchStore.test.ets'; // +M2a: 存档序列化/恢复 + 多 Tab 布局独立
import workbenchVmSessionsTest from './WorkbenchVmSessions.test.ets'; // +M2b: 会话挂接 + 多工作区 + 存档 v2
import termHostTest from './TermHost.test.ets'; // +M3a: TermHost 桥接 + 终端会话生命周期
import inputControllerTest from './InputController.test.ets'; // +M4a: 输入历史 + ghost + Tab 补全
import agentEventBusTest from './AgentEventBus.test.ets'; // +M5a: AgentEvent v1 总线 + Hmh 事件桥映射
import agentApprovalTest from './AgentApproval.test.ets'; // +M5b: pane 绑定 + 审批卡 + checkpoint 文案
import remoteWorkspaceTest from './RemoteWorkspace.test.ets'; // +M6a: 远程 provider + SSH pane 挂接
import sftpDrawerTest from './SftpDrawer.test.ets'; // +M6b: RightPanel 抽屉页签 + SFTP 路径/排序纯函数
import gitServiceTest from './GitService.test.ets'; // +M7a: git 解析纯函数 + runner 行缓冲/回显剔除/标记检测
import gitWriteTest from './GitWrite.test.ets'; // +M7b: 写命令构造/quoteMsg 双闸/XY 分类/pushDry 解析
import commandBridgeTest from './CommandBridge.test.ets'; // +M8a/M8b/M9: CLI 桥纯函数(parse/format/doctor/token 恒时比较) +PA: 管理动词(ws/tab/pane/tree/status/keys)
import termScrollbackTest from './TermScrollback.test.ets'; // +M3c: scrollback 尾截 + 终端搜索纯函数
import parityUiTest from './ParityUi.test.ets'; // +PB: palette 最近命令区 + 命令完成通知纯函数
import termReachTest from './TermReach.test.ets'; // +RD-1: ttyd 可达探测缓存/退避/
import connManageTest from './ConnManage.test.ets'; // +LEG-1: 连接档案表单校验
import telnetSessionTest from './TelnetSession.test.ets'; // +LEG-2: telnet 会话宿主
import agentPanelTest from './AgentPanel.test.ets'; // +LEG-2: 引擎/prompt 守卫
import ttydSessionTest from './TtydSession.test.ets';
import tunnelCmdTest from './TunnelCmd.test.ets'; // +RD-2: ttyd 输出流镜像纯函数
// +M1e: LayoutOps.swapPane 用例并入 LayoutTree.test.ets(任务书允许可并入,layoutTreeTest 注册即执行)

export default function testsuite() {
  policyEngineTest();
  auditRedactTest();
  agentSessionStateTest();
  acpClientTest();
  capabilityDiscoveryTest();
  approvalCardTest();
  agentAdapterTest();
  approvalManagerTest();
  backspaceKeyTest(); // +M1a
  layoutTreeTest();
  workbenchVmTest(); // +M1c
  appI18nTest(); // +GUI-i18n
  uiFontTest(); // +GUI-R3
  updateCheckerTest(); // +GUI-R3
  paletteCommandsTest(); // +M1d
  workbenchStoreTest(); // +M2a
  workbenchVmSessionsTest(); // +M2b
  termHostTest(); // +M3a
  inputControllerTest(); // +M4a
  agentEventBusTest(); // +M5a
  agentApprovalTest(); // +M5b
  remoteWorkspaceTest(); // +M6a
  sftpDrawerTest(); // +M6b
  gitServiceTest(); // +M7a
  gitWriteTest(); // +M7b
  commandBridgeTest(); // +M8a +M8b +M9 +PA
  termScrollbackTest(); // +M3c
  parityUiTest(); // +PB
  termReachTest(); // +RD-1
  connManageTest(); // +LEG-1
  telnetSessionTest(); // +LEG-2
  agentPanelTest(); // +LEG-2
  ttydSessionTest(); // +RD-2
  tunnelCmdTest(); // +LEG-3b
  agentPanelTest(); // +LEG-2
  // +M1e: swap 用例并入 layoutTreeTest(上面已调用,不重复注册)
}