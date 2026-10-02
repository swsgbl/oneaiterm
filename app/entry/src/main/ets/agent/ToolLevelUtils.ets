import { CapabilityLevel } from './AgentProvider';

export class ToolLevelUtils {
  static level(name: string): CapabilityLevel {
    if (name === 'term_write' || name === 'shell' || name === 'bash' || name === 'execute') {
      return 'terminal'
    }
    if (name === 'sftp' || name === 'scp' || name === 'ssh' || name === 'remote') {
      return 'remote'
    }
    if (name === 'rm' || name === 'delete' || name === 'format' || name === 'destructive') {
      return 'destructive'
    }
    if (name === 'write' || name === 'edit' || name === 'create') {
      return 'workspace_write'
    }
    return 'read_only'
  }
}