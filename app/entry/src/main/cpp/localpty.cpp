// localpty.c — forkpty + /bin/sh 本地终端 NAPI 模块
// 导出: ptyOpen(cols,rows,onData) / ptyWrite(str) / ptyClose() / ptyResize(cols,rows)
//        ptyPoll() — M5 relay4: 同步非阻塞读(master->JS),绕过 tsfn 在该环境不交付的问题
// 输出经 napi_threadsafe_function 异步回调 JS(onPtyData)
#include <napi/native_api.h>
#include <hilog/log.h>
#include <pty.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>

// r5 插桩:OH_LOG_Print 可视化 pty 三环节(open/write/poll),0xFF 域;%{public} 防打码
#define LPLOG(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF, "LPDBG", __VA_ARGS__))

static int g_master = -1;
static pid_t g_child = -1;
static pthread_t g_thr;
static volatile int g_running = 0;
static napi_threadsafe_function g_tsfn = NULL;
static napi_value PtyClose(napi_env env, napi_callback_info info); // r6: EOF 自愈前向声明

// r6e: 环形缓冲——native 读线程持续收 master 输出,ptyPoll 一次排空。
// 该环境 ACE 渲染异常会冻结 JS timer 队列(10Hz poll 停摆但输入事件仍活),
// 轮询间隔不可依赖;缓冲解耦后,解冻后的第一次 poll 即拿全量。
#define RB_CAP (256 * 1024)
static char g_rb[RB_CAP];
static volatile int g_rbHead = 0; // 写者推进
static volatile int g_rbTail = 0; // 读者(ptyPoll)推进
static volatile int g_rbOverflow = 0;
static volatile int g_ptyDead = 0; // 读线程退出原因:1=EOF/EIO

static int rbUsed(void) {
  int h = g_rbHead;
  int t = g_rbTail;
  return h >= t ? h - t : RB_CAP - (t - h);
}

// 读线程:阻塞读 master,写入环形缓冲(覆盖旧数据时置 overflow 标记)
static void* ptyReader(void* arg) {
  (void)arg;
  char buf[4096];
  while (g_running) {
    ssize_t n = read(g_master, buf, sizeof(buf));
    if (n == 0 || (n < 0 && errno == EIO)) {
      g_ptyDead = 1;
      LPLOG("reader EOF n=%{public}d errno=%{public}d child=%{public}d", (int)n, errno, (int)g_child);
      return NULL;
    }
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) { usleep(20000); continue; } // O_NONBLOCK 下小睡
      g_ptyDead = 1;
      LPLOG("reader err errno=%{public}d -> dead", errno);
      return NULL;
    }
    for (ssize_t i = 0; i < n; i++) {
      int next = (g_rbHead + 1) % RB_CAP;
      if (next == g_rbTail) {
        g_rbOverflow = 1; // 满:丢最旧
        g_rbTail = (g_rbTail + 1) % RB_CAP;
      }
      g_rb[g_rbHead] = buf[i];
      g_rbHead = next;
    }
  }
  return NULL;
}

static void call_js(napi_env env, napi_value js_cb, void* context, void* data) {
  if (data == NULL) return;
  char* text = (char*)data;  napi_value str;
  napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &str);
  napi_value undef;
  napi_get_undefined(env, &undef);
  napi_call_function(env, undef, js_cb, 1, &str, &undef);
  free(text);
}

static void* read_loop(void* arg) {
  char buf[4096];
  while (g_running) {
    ssize_t n = read(g_master, buf, sizeof(buf) - 1);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR)) continue;
      break;
    }
    buf[n] = '\0';
    char* copy = (char*)malloc(n + 1);
    memcpy(copy, buf, n + 1);
    napi_call_threadsafe_function(g_tsfn, copy, napi_tsfn_blocking);
  }
  return NULL;
}

static napi_value PtyOpen(napi_env env, napi_callback_info info) {
  size_t argc = 3;  // M5 relay4 fix: 原先 args[2] 只装 2 个元素却读 args[2](回调)→ 越界
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 3) {
    napi_throw_error(env, NULL, "need (cols, rows, onData)");
    return NULL;
  }
  int cols = 80, rows = 24;
  napi_get_value_int32(env, args[0], &cols);
  napi_get_value_int32(env, args[1], &rows);
  napi_value js_cb = args[2];
  if (g_running) {
    napi_throw_error(env, NULL, "pty already open");
    return NULL;
  }
  struct winsize ws;
  ws.ws_col = cols; ws.ws_row = rows;
  ws.ws_xpixel = 0; ws.ws_ypixel = 0;
  pid_t pid = forkpty(&g_master, NULL, NULL, &ws);
  if (pid < 0) {
    napi_throw_error(env, NULL, "forkpty failed");
    return NULL;
  }
  if (pid == 0) {
    // child: 零配置继承终端能力(profile 显式引导,不依赖登录 shell 语义)
    setenv("TERM", "xterm-256color", 1);
    // r6f 基线 + 应用内工具箱优先(2026-10-07 设计定稿):
    // 三方应用沙箱命名空间不含 /data/local(板端 hmh/node 所在区,挂载表实勘),
    // 系统级"继承"不可能;应用自有沙箱内 exec 已实证可行 → 工具箱路线:
    // ToolsInstaller 首开自动解压 rawfile/tools.zip 到 ctx.filesDir——注意
    // filesDir=/data/storage/el2/base/haps/entry/files(含 haps/entry 段,
    // 漏写此段=死路径,PATH 解析跳过→/bin/hmh 抢跑,实测踩过)。
    setenv("PATH",
      "/data/storage/el2/base/haps/entry/files/tools/bin"
      ":/bin:/system/bin:/data/local/home/.local/bin", 1);
    // HOME 起始目录:沙箱工具箱 home 优先(应用沙箱内唯一稳定可写),板端路径兜底
    // (仅在可见该路径的非沙箱上下文生效;沙箱内 /data/local 不存在,静默跳过)
    if (access("/data/storage/el2/base/haps/entry/files/tools/home", F_OK) == 0) {
      setenv("HOME", "/data/storage/el2/base/haps/entry/files/tools/home", 1);
      chdir("/data/storage/el2/base/haps/entry/files/tools/home");
    } else {
      setenv("HOME", "/data/local/home", 1);
      chdir("/data/local/home");
    }
    setenv("PS1", "$ ", 1);
    // 2026-10-07 实勘: 板端 /bin/sh 对 argv[0]="-sh" 与 "-l" 两种登录模式
    // 均不加载 .profile;且应用沙箱命名空间根本不含 /data/local。显式 source
    // (子 shell 包裹,防 profile 在应用上下文 exit 自杀)只在路径可见时有实效:
    //   /etc/profile(若在) + 板端 .profile(node/NDK/hvigor/ohpm/LD_LIBRARY_PATH)
    execl("/bin/sh", "sh", "-c",
      "( . /etc/profile ) 2>/dev/null; ( . /data/local/home/.profile ) 2>/dev/null; "
      "exec /bin/sh -i", NULL);
    _exit(127);
  }
  g_child = pid;
  LPLOG("ptyOpen ok pid=%{public}d master=%{public}d", (int)pid, g_master);
  // r6e: tsfn 不交付 + JS timer 会被 ACE 冻结,全部改走环形缓冲:
  // 读线程收数,ptyPoll 排空。tsfn 仅为兼容保留创建(不 call)。
  napi_value res_name;
  napi_create_string_utf8(env, "ptyData", NAPI_AUTO_LENGTH, &res_name);
  napi_create_threadsafe_function(env, js_cb, NULL, res_name, 0, 1, NULL, NULL, NULL, call_js, &g_tsfn);
  g_rbHead = 0;
  g_rbTail = 0;
  g_rbOverflow = 0;
  g_ptyDead = 0;
  g_running = 1;
  int fl = fcntl(g_master, F_GETFL);
  fcntl(g_master, F_SETFL, fl & ~O_NONBLOCK); // r6e: 读线程阻塞读
  if (pthread_create(&g_thr, NULL, ptyReader, NULL) != 0) {
    LPLOG("pthread_create failed");
  }
  napi_value pid_val;
  napi_create_int32(env, pid, &pid_val);
  return pid_val;
}

// r6e: 排空环形缓冲。返回积压全部文本(可能很大);EOF 时返回哨兵。
// 心跳:缓冲空时每 50 次(约 5s)打一条 idle 证明 JS 链活着。
static napi_value PtyPoll(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  if (g_ptyDead) {
    LPLOG("ptyPoll dead -> autoclose+sentinel");
    PtyClose(env, info);
    napi_create_string_utf8(env, "__PTY_EOF__", NAPI_AUTO_LENGTH, &out);
    return out;
  }
  int used = rbUsed();
  if (used <= 0) {
    static int idle = 0;
    if ((idle++ % 50) == 0) {
      LPLOG("ptyPoll idle dead=%{public}d child=%{public}d alive=%{public}d",
            g_ptyDead, (int)g_child, (int)g_child > 0 ? kill(g_child, 0) : -99);
    }
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &out);
    return out;
  }
  if (g_rbOverflow) {
    LPLOG("ptyPoll OVERFLOW warn (oldest lost)");
    g_rbOverflow = 0;
  }
  static char drain[RB_CAP];
  int n = 0;
  while (g_rbTail != g_rbHead && n < RB_CAP - 1) {
    drain[n++] = g_rb[g_rbTail];
    g_rbTail = (g_rbTail + 1) % RB_CAP;
  }
  LPLOG("ptyPoll drain n=%{public}d first=%{public}02x %{public}02x", n,
        (unsigned char)drain[0], (unsigned char)drain[1]);
  napi_create_string_utf8(env, drain, n, &out);
  return out;
}

static napi_value PtyWrite(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  size_t len = 0;
  napi_get_value_string_utf8(env, args[0], NULL, 0, &len);
  char* buf = (char*)malloc(len + 1);
  napi_get_value_string_utf8(env, args[0], buf, len + 1, &len);
  ssize_t n = write(g_master, buf, len);
  LPLOG("ptyWrite len=%{public}d n=%{public}d master=%{public}d [%{public}s]", (int)len, (int)n, g_master, buf);
  free(buf);
  napi_value out;
  napi_create_int32(env, (int)n, &out);
  return out;
}

static napi_value PtyClose(napi_env env, napi_callback_info info) {
  (void)info;
  if (g_running) {
    g_running = 0;
    close(g_master);
    if (g_child > 0) {
      kill(g_child, SIGKILL);
      waitpid(g_child, NULL, 0);
    }
    // r6e: 回收读线程。master 已 close → 读线程 read 返 EBADF/EIO 快速
    // 退出(其循环条件 g_running=0 也会退出);阻塞 join 上限风险=其 usleep
    // 分片,最坏 ~20ms 后返回,可安全 join。
    pthread_join(g_thr, NULL);
    if (g_tsfn) {
      napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
      g_tsfn = NULL;
    }
    g_master = -1;
    g_child = -1;
  }
  napi_value undef;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value PtyResize(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  int cols = 80, rows = 24;
  napi_get_value_int32(env, args[0], &cols);
  napi_get_value_int32(env, args[1], &rows);
  struct winsize ws;
  ws.ws_col = cols; ws.ws_row = rows;
  ws.ws_xpixel = 0; ws.ws_ypixel = 0;
  ioctl(g_master, TIOCSWINSZ, &ws);
  napi_value undef;
  napi_get_undefined(env, &undef);
  return undef;
}

// M8 工具箱: chmod 0755——ohos fs API 无 chmod,zip 解压若丢执行位由此兜底。
static napi_value ToolsChmod(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 1) {
    napi_throw_error(env, NULL, "need (path)");
    return NULL;
  }
  size_t len = 0;
  napi_get_value_string_utf8(env, args[0], NULL, 0, &len);
  char* p = (char*)malloc(len + 1);
  napi_get_value_string_utf8(env, args[0], p, len + 1, &len);
  int r = chmod(p, 0755);
  LPLOG("toolsChmod %s r=%d", p, r);
  free(p);
  napi_value out;
  napi_create_int32(env, r, &out);
  return out;
}

// M8 工具箱: 递归 chmod(目录+文件统一 0755)——zip 解压的目录可能无 x 位导致
// PATH 遍历失败(command -v 直接跳过该目录);沙箱内私有树,统一可执行无风险。
static void chmodTree(const char* path, int depth, int* count) {
  if (depth > 12 || *count > 5000) {
    return;
  }
  chmod(path, 0755);
  (*count)++;
  DIR* d = opendir(path);
  if (d == NULL) {
    return;
  }
  struct dirent* e;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
      continue;
    }
    char sub[4096];
    if (snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name) >= (int)sizeof(sub)) {
      continue;
    }
    if (e->d_type == DT_DIR) {
      chmodTree(sub, depth + 1, count);
    } else {
      chmod(sub, 0755);
      (*count)++;
    }
  }
  closedir(d);
}

static napi_value ToolsChmodTree(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 1) {
    napi_throw_error(env, NULL, "need (path)");
    return NULL;
  }
  size_t len = 0;
  napi_get_value_string_utf8(env, args[0], NULL, 0, &len);
  char* p = (char*)malloc(len + 1);
  napi_get_value_string_utf8(env, args[0], p, len + 1, &len);
  int count = 0;
  chmodTree(p, 0, &count);
  LPLOG("toolsChmodTree %s entries=%d", p, count);
  free(p);
  napi_value out;
  napi_create_int32(env, count, &out);
  return out;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    { "ptyOpen", NULL, PtyOpen, NULL, NULL, NULL, napi_default, NULL },
    { "ptyWrite", NULL, PtyWrite, NULL, NULL, NULL, napi_default, NULL },
    { "ptyClose", NULL, PtyClose, NULL, NULL, NULL, napi_default, NULL },
    { "ptyResize", NULL, PtyResize, NULL, NULL, NULL, napi_default, NULL },
    { "ptyPoll", NULL, PtyPoll, NULL, NULL, NULL, napi_default, NULL },
    { "toolsChmod", NULL, ToolsChmod, NULL, NULL, NULL, napi_default, NULL },
    { "toolsChmodTree", NULL, ToolsChmodTree, NULL, NULL, NULL, napi_default, NULL },
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module localptyModule = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = NULL,
  .nm_register_func = Init,
  .nm_modname = "localpty",
  .nm_priv = NULL,
  .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterLocalptyModule(void) {
  napi_module_register(&localptyModule);
}
