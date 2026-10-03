# VM 构建链一键部署（vm-deploy.cmd）

> M8-relay1 交付：把 M8-relay0 人工拼装的 40 分钟 VM 构建链，固化为仓库内**一条命令**。
> 适用：KaihongOS VM（hdc 目标 `127.0.0.1:15566`，API14 工具链，x86_64）。

## 链路图

```
D:\oneaiterm\app（仓内源码，不改一行）
   │
   │ ① SYNC   sync_vm.py --push --prune        113 文件（ets=63）→ VM /data/local/home/tmp/app
   │          单 tar.gz 一次 hdc file send → VM 侧清树解包（tar 自建父目录）
   │          → find 剥根前缀集合对账（0 missing 0 orphan）→ 嵌套污染路径硬 FAIL
   ▼
VM 副本（适配只落在 VM，不动仓库）
   │ ② ADAPT  vm-adapt.sh                        runtimeOS→OpenHarmony；版本串→数字 14；
   │          （确定性 sed，幂等）                 补插 default product 的 compileSdkVersion；
   ▼                                          deviceTypes→["default"]
   │ ③ BUILD  vm-build-store.sh                  从现行原版 pack_hap.sh 现场 sed 生成
   │          timeout 280                        pack_hap_store.sh（product/module/路径→store，
   │                                          libentry.so→liblocalpty.so 标志物）→ 构建
   ▼                                          → out_release.hap
宿主机
   │ ④ REPACK hdc file recv → repack_vm.py      注入 HAR 五个权威 so（含版本化 so）→ 推回
   │                                          /data/local/tmp/m7r1-unsigned.hap
   ▼
   │ ⑤ INSTALL sh vm-sign-install.sh             设备侧签名 + bm uninstall/install
   │                                          判据：successfully + DONE_M7R1_SIGN_INSTALL
   ▼
   │ ⑥ /smoke smoke_vm.py                        aa start → dump 判"一站AI终端" → 点"跳过"
   │      （可选开关）                            → 二次 dump 判可见文本节点 >50 → 截图
   ▼
  装机完成，证据落 .verify\m8r1\
```

## 用法

```cmd
cd /d D:\oneaiterm
app\scripts\vm-deploy.cmd          REM 全链（同步→适配→构建→repack→安装）
app\scripts\vm-deploy.cmd /smoke   REM 同上 + 启动冒烟（判据见下）
```

阶段日志与产物：`.verify\m8r1\stage{0..6}-*.log`、`vm-raw.hap`、`vm-repacked.hap`、`smoke-launch.json`、`smoke-main.json`、`vmchain-smoke.jpeg`。

## 判据（脚本自动判定，任一不过即 FAIL 退出）

| 阶段 | 判据 |
|---|---|
| SYNC | VM find 剥根对账 == 本地清单（当前 113，ets=63）；missing/orphan 双向为零；嵌套污染路径（段落重复）硬 FAIL |
| ADAPT | VM 副本 build-profile/module.json 应用三处适配；输出 DONE_VM_ADAPT |
| BUILD | timeout 280 内 out_release.hap 出现（VM 日志 /data/local/tmp/vmchain-build.log） |
| REPACK | 5/5 so 注入（libc++_shared / libcrypto.so.3 / libssh.so.4 / libssh_ohos_napi / libssl.so.3），保留 VM 构建的 liblocalpty/librdpproxy |
| INSTALL | 输出含 successfully 且含 DONE_M7R1_SIGN_INSTALL |
| SMOKE | 首次 dump 可见"一站AI终端"；点"跳过"后二次 dump 可见文本节点 >50 |

## 坑清单（每条都付过学费，动脚本前先读）

1. **hdc file send 不建父目录且 errorlevel 假 0**：报 OK 实际丢文件；且**连续逐文件 send 在本机会串包**——接收端把目标文件名建成目录、载荷嵌进里面（实测 98 send → 95 个错位，重推只会更糟）。SYNC 因此改用**单 tar.gz 一次 send**：VM 侧清树解包（tar 自建父目录），`wc -c` 校验字节数后才解压，find 剥根前缀做 POSIX 集合对账。另有污染检测：合法同步路径的各段不重复，`.../Index.ets/src/main/ets/pages/Index.ets` 这类段落重复即 send 竞态残留，硬 FAIL。
2. **pack_hap 硬编码 default**：VM 原版 pack_hap.sh 全链写死 `product=default`/`entry@default`/`default/` 中间目录。BUILD 阶段每次从原版重新 sed 生成 pack_hap_store.sh（自愈，不怕被污染），共 7 处替换。
3. **liblocalpty.so 标志物**：pack_hap.sh 用 `libentry.so` 判断"是否有 native 产物"——本工程 cmake 产物叫 liblocalpty.so，标志物不匹配时**静默打出 0 个 so 的 hap**。sed 替换为 liblocalpty.so。
4. **API14 不接受 "5.0.2(14)" 字符串**：OpenHarmony 工程的 compileSdkVersion/compatible/target 必须是数字 `14`；字符串版本串只在 HarmonyOS 工具链合法。ADAPT 同时给 default product **补插** compileSdkVersion（仓库里它没有该键，缺了 hvigor 报 SDK component missing）。
5. **syscap 交集**：module.json5 的 deviceTypes 含 phone/2in1 时，OH SDK 无对应 syscap 集 → rpcid 交集为空 → 打包失败。ADAPT 收敛为 `["default"]`。
6. **280s 超时**：VM 构建慢（冷缓存 4-5 分钟会超时被杀）。脚本 timeout 280 失败即 FAIL 并回显错误 tail；重跑第二次（缓存热）通常 2-3 分钟过。**不要**为省时间去掉 timeout——挂死比失败更难排查。
7. **store product 的原因**：仓库双 product——default=API 6.1.1(24)，store=API 5.0.2(14)。VM 只有 API14 工具链，只能构建 store。host 侧 gate 仍按 default（API24）typecheck，两套互不干扰。
8. **repack 的版本化 so**：HAR 里有 `libssh.so.4`/`libssl.so.3`/`libcrypto.so.3` 这类版本化命名——过滤判断必须是 `".so" in name`，`endswith(".so")` 会漏 3 个。
9. **新手引导浮层**：每轮重装后重新出现并遮挡全屏点击。SMOKE 先 dumpLayout 定位"跳过"按钮 origBounds 中心再点，不信任历史坐标。
10. **uitest 细节**：click 坐标=origBounds 中心（窗口即屏幕坐标）；inputText 只能追加不能清空；dump 后取 /data/local/tmp 最新 layout_*.json。

## 与 M8-relay0 的对应关系

| relay0 人工步骤 | 本链固化于 |
|---|---|
| sync-list.txt 逐文件推 + 手工补 mkdir | sync_vm.py（清单自动枚举 + 单 tar.gz 传输 + 字节数校验 + 集合对账 + 污染检测） |
| 手工 sed 改 VM 副本 build-profile/module.json | vm-adapt.sh |
| 手工复制 pack_hap.sh 改 7 处 | vm-build-store.sh（每次现场重新生成） |
| .verify/m8r0/repack_m8.py | app/scripts/repack_vm.py（同逻辑，仓库相对定位） |
| vm-sign-install.sh 手敲 | vm-deploy.cmd stage 5（判据自动校验） |
| 手工 dump/点跳过/数节点 | smoke_vm.py（/smoke 开关） |

## 已知限制

- hdc 目标与签名材料路径写死为当前 VM 环境（15566 / $OHOS_HOME/signature）；换目标需改 sync_vm.py / vm-deploy.cmd 顶部常量。
- BUILD 冷缓存可能超 280s（FAIL 退出）——重跑一次即可，缓存热后正常通过；这是有意的防挂死设计。
- SMOKE 仅覆盖启动 + 主界面渲染；SSH/AI Dock 深度冒烟仍按 relay0 的 S2/S3 手工流程。
- sync 的 HAR 树只同步 .ets/.json5（libs 的 .so 由 repack 阶段从宿主 HAR 注入，VM 不需要）。
