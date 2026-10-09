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
import backspaceKeyTest from './BackspaceKey.test.ets'; // +tty7-M1a: layoutTreeTest (ListTest runner 静态引用本文件，不注册则新套件不执行)
import layoutTreeTest from './LayoutTree.test.ets';
import workbenchVmTest from './WorkbenchVm.test.ets'; // +tty7-M1c: Vm 布局集成
import paletteCommandsTest from './PaletteCommands.test.ets'; // +tty7-M1d: 命令面板注册表
import workbenchStoreTest from './WorkbenchStore.test.ets'; // +tty7-M2a: 存档序列化/恢复 + 多 Tab 布局独立
import workbenchVmSessionsTest from './WorkbenchVmSessions.test.ets'; // +tty7-M2b: 会话挂接 + 多工作区 + 存档 v2
import termHostTest from './TermHost.test.ets'; // +tty7-M3a: TermHost 桥接 + 终端会话生命周期
import inputControllerTest from './InputController.test.ets'; // +tty7-M4a: 输入历史 + ghost + Tab 补全

export default function testsuite() {
  policyEngineTest();
  auditRedactTest();
  agentSessionStateTest();
  acpClientTest();
  capabilityDiscoveryTest();
  approvalCardTest();
  agentAdapterTest();
  approvalManagerTest();
  backspaceKeyTest(); // +tty7-M1a
  layoutTreeTest();
  workbenchVmTest(); // +tty7-M1c
  paletteCommandsTest(); // +tty7-M1d
  workbenchStoreTest(); // +tty7-M2a
  workbenchVmSessionsTest(); // +tty7-M2b
  termHostTest(); // +tty7-M3a
  inputControllerTest(); // +tty7-M4a
}