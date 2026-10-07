// ToolsInstaller — 本地终端工具箱首启自动装配(M8 工具箱设计, 2026-10-07)。
//
// 为什么存在: 三方应用沙箱挂载命名空间不含 /data/local(板端 hmh/node 所在区),
// 系统级"继承"不可能;应用自有沙箱 files/ 内 exec 已实证可行。发行包把工具链
// 打成 rawfile/tools.zip(package-tools.cmd 生成),首次打开本地终端时解压到
// files/tools(localpty PATH 首位即 files/tools/bin),此后 hmh 等零配置可用。
//
// 适配:
//   - zip 可能不保留 exec 位 → toolsChmod(native chmod 0755)兜底
//   - hmh-home 配置随包携带(HMH_HOME=tools/home/hmh-home)
// hilog tag: oat.tools(域 0x0110)
import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { toolsChmod, toolsChmodTree } from 'liblocalpty.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'oat.tools';
const DOMAIN: number = 0x0110;

export class ToolsInstaller {
  private static running: boolean = false

  /** files/tools/bin/hmh 就绪即视为已装配(与 install-board-tools.cmd 产物同构)。 */
  static ready(filesDir: string): boolean {
    try {
      return fs.accessSync(filesDir + '/tools/bin/hmh')
    } catch (e) {
      return false
    }
  }

  /**
   * 首启自动装配: rawfile/tools.zip → cache/tools.zip → zlib 解压到 filesDir
   * → 补执行位。幂等(已就绪直接返回);并发调用合并;失败返回错误串(不抛)。
   * 38MB 级解压需数十秒,调用方勿阻塞 UI——fire-and-forget 即可。
   */
  static async ensure(ctx: common.UIAbilityContext): Promise<string> {
    const filesDir = ctx.filesDir
    if (ToolsInstaller.ready(filesDir)) {
      return ''
    }
    if (ToolsInstaller.running) {
      return 'busy'
    }
    ToolsInstaller.running = true
    const t0 = Date.now()
    try {
      const zipPath = ctx.cacheDir + '/tools.zip'
      // rawfile 整读进内存再落盘(38MB,PC 级内存可承受)
      const buf = await ctx.resourceManager.getRawFileContent('tools.zip')
      const f = fs.openSync(zipPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(f.fd, buf.buffer)
      fs.closeSync(f)
      hilog.info(DOMAIN, TAG, 'zip staged %{public}d bytes', buf.byteLength)
      const errStr: string = await new Promise<string>((resolve) => {
        zlib.decompressFile(zipPath, filesDir, {} as zlib.Options,
          (err: BusinessError<void>) => {
            resolve(err ? ('解压失败 code=' + String(err.code)) : '')
          })
      })
      if (errStr !== '') {
        hilog.error(DOMAIN, TAG, '%{public}s', errStr)
        return errStr
      }
      // 权限兜底: zip 解压的目录可能无 x 位(PATH 遍历会直接跳过整个目录);
      // 递归统一 0755(沙箱私有树,安全)
      const r1 = toolsChmod(filesDir + '/tools/bin/node')
      const r2 = toolsChmod(filesDir + '/tools/bin/hmh')
      const treeCount = toolsChmodTree(filesDir + '/tools')
      hilog.info(DOMAIN, TAG, 'chmod node=%{public}d hmh=%{public}d tree=%{public}d', r1, r2, treeCount)
      const ok = ToolsInstaller.ready(filesDir)
      hilog.info(DOMAIN, TAG, 'extract done %{public}dms ready=%{public}s', Date.now() - t0, ok ? 'true' : 'false')
      return ok ? '' : '解压完成但 bin/hmh 未出现'
    } catch (e) {
      const msg = '装配失败: ' + (e instanceof Error ? e.message : String(e)).substring(0, 100)
      hilog.error(DOMAIN, TAG, '%{public}s', msg)
      return msg
    } finally {
      ToolsInstaller.running = false
    }
  }
}
