// 官方 MonitorTabContent 复刻(本地设备版):CPU/内存/磁盘/网络 实时监控卡片
// 数据源:/proc/stat /proc/meminfo /proc/net/dev /proc/loadavg + statfs(/data)
import fs from '@ohos.file.fs';
import statfs from '@ohos.statfs';
import { AppTheme, themeByName } from '../common/AppTheme';
import { DesignTokens } from '../common/DesignTokens';
import { TimingConstants } from '../common/TimingConstants';

interface NetIo {
  rxKB: number
  txKB: number
}

@Component
export struct MonitorPanel {
  // M6 relay1 P0-4: 主题接入(父 Index 经 AppStorage('ut.theme') 广播)
  @StorageProp('ut.theme') themeName: string = 'dark'
  private th(): AppTheme { return themeByName(this.themeName) }
  @State cpuPercent: number = 0
  @State memPercent: number = 0
  @State memText: string = '-'
  @State diskPercent: number = 0
  @State diskText: string = '-'
  @State rxRate: number = 0
  @State txRate: number = 0
  @State loadText: string = '-'
  // M5 relay4: /proc 读取失败标记(UI 显式提示,不再静默全 0)
  @State procDeny: string = ''
  private timer: number = -1
  private prevCpu: number[] = [0, 0, 0, 0, 0, 0, 0, 0]
  private prevNet: NetIo = { rxKB: 0, txKB: 0 }
  private prevTs: number = 0

  aboutToAppear(): void {
    this.sample()
    this.timer = setInterval(() => this.sample(), TimingConstants.MONITOR_SAMPLE_MS)
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer)
    }
  }

  // M5 relay4 fix: /proc 伪文件 stat 尺寸为 0,readTextSync 返回空/抛错;
  // 改为 open + 定长 read(读伪文件的正路)。任何一步失败返回 ''。
  private readProc(path: string): string {
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(8192)
      let out = ''
      const u8 = new Uint8Array(buf)
      for (;;) {
        const n = fs.readSync(file.fd, buf)
        if (n <= 0) {
          break
        }
        let chunk = ''
        for (let i = 0; i < n; i++) {
          chunk += String.fromCharCode(u8[i])
        }
        out += chunk
        if (out.length > 65536) {
          break
        }
      }
      return out
    } catch (e) {
      return ''
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file)
        } catch (e2) {
        }
      }
    }
  }

  private sample(): void {
    // M5 relay4: 先探源可达性,失败显式提示(app 沙箱 DAC 拒读 /proc 的场景)
    const probe = this.readProc('/proc/loadavg')
    this.procDeny = probe === '' ? '⚠ /proc 不可读(应用沙箱限制),CPU/内存/网络/负载显示为 0' : ''
    // CPU: /proc/stat 首行 cpu  user nice system idle iowait irq softirq steal
    const stat = this.readProc('/proc/stat')
    if (stat !== '') {
      const line = stat.split('\n')[0].trim().split(/\s+/)
      const cur: number[] = []
      for (let i = 1; i < line.length && i <= 8; i++) {
        cur.push(parseInt(line[i]) || 0)
      }
      let total = 0
      let idle = 0
      const prevTotal = this.prevCpu[0] + this.prevCpu[1] + this.prevCpu[2] + this.prevCpu[3] +
        this.prevCpu[4] + this.prevCpu[5] + this.prevCpu[6] + this.prevCpu[7]
      const prevIdle = this.prevCpu[3] + this.prevCpu[4]
      for (let i = 0; i < cur.length; i++) {
        total += cur[i]
        if (i === 3 || i === 4) {
          idle += cur[i]
        }
      }
      const dTotal = total - prevTotal
      const dIdle = idle - prevIdle
      if (dTotal > 0) {
        this.cpuPercent = Math.round((1 - dIdle / dTotal) * 100)
      }
      this.prevCpu = cur
    }
    // 内存: /proc/meminfo
    const mi = this.readProc('/proc/meminfo')
    if (mi !== '') {
      let total = 0
      let avail = 0
      const lines = mi.split('\n')
      for (const l of lines) {
        const digits: string = l.replace(/[^0-9]/g, '')
        if (l.startsWith('MemTotal:')) {
          total = parseInt(digits) || 0
        } else if (l.startsWith('MemAvailable:')) {
          avail = parseInt(digits) || 0
        }
      }
      if (total > 0) {
        const used = total - avail
        this.memPercent = Math.round(used / total * 100)
        this.memText = (used / 1048576).toFixed(1) + 'G / ' + (total / 1048576).toFixed(1) + 'G'
      }
    }
    // 网络: /proc/net/dev 累计字节 → 速率
    const nd = this.readProc('/proc/net/dev')
    if (nd !== '') {
      let rx = 0
      let tx = 0
      const lines = nd.split('\n')
      for (const l of lines) {
        const idx = l.indexOf(':')
        if (idx > 0) {
          const name = l.substring(0, idx).trim()
          if (name === 'lo') {
            continue
          }
          const cols = l.substring(idx + 1).trim().split(/\s+/)
          if (cols.length >= 9) {
            rx += parseInt(cols[0]) || 0
            tx += parseInt(cols[8]) || 0
          }
        }
      }
      const now = Date.now()
      if (this.prevTs > 0) {
        const dt = (now - this.prevTs) / 1000
        if (dt > 0.5) {
          this.rxRate = Math.max(0, Math.round((rx - this.prevNet.rxKB) / dt / 1024))
          this.txRate = Math.max(0, Math.round((tx - this.prevNet.txKB) / dt / 1024))
        }
      }
      this.prevNet = { rxKB: rx, txKB: tx }
      this.prevTs = now
    }
    // 负载: /proc/loadavg
    const la = this.readProc('/proc/loadavg')
    if (la !== '') {
      const p = la.trim().split(/\s+/)
      if (p.length >= 3) {
        this.loadText = p[0] + ' ' + p[1] + ' ' + p[2]
      }
    }
    // 磁盘: statfs getFreeBytes/getTotalBytes(Promise)
    statfs.getTotalBytes('/data').then((totalB: number) => {
      statfs.getFreeBytes('/data').then((freeB: number) => {
        if (totalB > 0) {
          this.diskPercent = Math.round((1 - freeB / totalB) * 100)
          this.diskText = ((totalB - freeB) / 1073741824).toFixed(1) + 'G / ' + (totalB / 1073741824).toFixed(1) + 'G'
        }
      })
    }).catch(() => {
    })
  }

  @Builder
  Card(title: string, pct: number, text: string, color: number) {
    Column({ space: 6 }) {
      Row() {
        Text(title)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor(this.th().inkSubtle)
        Blank()
        Text(pct.toString() + '%')
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(color)
      }
      .width('100%')
      Progress({ value: pct, total: 100, type: ProgressType.Linear })
        .color(color)
        .backgroundColor(this.th().inputBg)
        .width('100%')
      Text(text)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
    }
    .width('100%')
    .padding(DesignTokens.SPACE_MD)
    .borderRadius(DesignTokens.RADIUS_MD)
    .backgroundColor(this.th().panel)
  }

  build() {
    Column({ space: 10 }) {
      Text('服务器监控')
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().ink)
        .padding({ top: 10, bottom: 2 })
      if (this.procDeny !== '') {
        Text(this.procDeny)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor(this.th().warn)
          .padding({ left: 4, right: 4 })
      }
      this.Card('CPU', this.cpuPercent, '负载 ' + this.loadText, this.th().brand)
      this.Card('内存', this.memPercent, this.memText, this.th().success)
      this.Card('磁盘 /data', this.diskPercent, this.diskText, this.th().warn)
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('↓ ' + this.rxRate.toString() + ' KB/s')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(0x4c9df0)
          Text('下行')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
        }
        .layoutWeight(1)
        .padding(DesignTokens.SPACE_MD)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().panel)
        Column({ space: 4 }) {
          Text('↑ ' + this.txRate.toString() + ' KB/s')
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(0xa78bfa)
          Text('上行')
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor(this.th().inkSubtle)
        }
        .layoutWeight(1)
        .padding(DesignTokens.SPACE_MD)
        .borderRadius(DesignTokens.RADIUS_MD)
        .backgroundColor(this.th().panel)
      }
      .width('100%')
      Blank()
      Text('3s 刷新 · 远程主机监控(经 SSH)按官方路线接入')
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor(this.th().inkSubtle)
        .padding(DesignTokens.SPACE_SM)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.th().surface)
    .alignItems(HorizontalAlign.Start)
  }
}
