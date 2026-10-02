/**
 * hypium 单测注册入口（升级 Phase 1 / 任务 2.2）。
 * 存量 BackspaceKey.test.ets + 新架构等价测试。
 */
import policyEngineTest from './PolicyEngine.test.ets';
import auditRedactTest from './AuditRedact.test.ets';
import agentSessionStateTest from './AgentSessionMeta.test.ets';
import acpClientTest from './AcpClient.test.ets';
import capabilityDiscoveryTest from './CapabilityDiscovery.test.ets';
import approvalCardTest from './ApprovalCard.test.ets';
import agentAdapterTest from './AgentAdapter.test.ets';
import approvalManagerTest from './ApprovalManager.test.ets';

export default function testsuite() {
  policyEngineTest();
  auditRedactTest();
  agentSessionStateTest();
  acpClientTest();
  capabilityDiscoveryTest();
  approvalCardTest();
  agentAdapterTest();
  approvalManagerTest();
}