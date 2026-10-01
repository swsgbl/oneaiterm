// rdpproxy.cpp — FreerDP 3.9 NAPI 桥(RDP → ArkTS 帧回调)
#include <napi/native_api.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <winpr/ssl.h>
#include <thread>
#include <cstring>

static napi_threadsafe_function g_tsfn = NULL;
static freerdp *g_rdp = NULL;
static volatile bool g_running = false;
static std::thread *g_th = NULL;

struct FrameMsg { int x, y, w, h; uint8_t *rgba; };

static void call_js(napi_env env, napi_value js_cb, void *, void *data) {
  FrameMsg *f = (FrameMsg *)data;
  if (!f) return;
  napi_value ab;
  napi_create_external_arraybuffer(env, f->rgba, (size_t)f->w * f->h * 4,
      [](napi_env, void *d, void *) { free(d); }, nullptr, &ab);
  napi_value argv[5];
  napi_create_int32(env, f->x, &argv[0]);
  napi_create_int32(env, f->y, &argv[1]);
  napi_create_int32(env, f->w, &argv[2]);
  napi_create_int32(env, f->h, &argv[3]);
  argv[4] = ab;
  napi_value undef;
  napi_get_undefined(env, &undef);
  napi_call_function(env, undef, js_cb, 5, argv, &undef);
  delete f;
}

static BOOL rdp_begin_paint(rdpContext *ctx) {
  (void)ctx;
  return TRUE;
}

static BOOL rdp_end_paint(rdpContext *ctx) {
  if (!ctx || !ctx->gdi) return TRUE;
  // 脏区
  HGDI_RGN region = ctx->gdi->primary->hdc->hwnd->invalid;
  if (!region || region->null) return TRUE;
  int x = region->x, y = region->y, w = region->w, h = region->h;
  if (w <= 0 || h <= 0) return TRUE;
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  if (x + w > (int)ctx->gdi->width) w = ctx->gdi->width - x;
  if (y + h > (int)ctx->gdi->height) h = ctx->gdi->height - y;
  if (w <= 0 || h <= 0) return TRUE;

  FrameMsg *f = new FrameMsg();
  f->x = x; f->y = y; f->w = w; f->h = h;
  f->rgba = (uint8_t *)malloc((size_t)w * h * 4);
  const uint8_t *src = ctx->gdi->primary_buffer;
  if (!src) { free(f->rgba); delete f; return TRUE; }
  size_t stride = (size_t)ctx->gdi->width * 4;
  for (int r = 0; r < h; r++) {
    const uint8_t *s = src + (size_t)(y + r) * stride + (size_t)x * 4;
    uint8_t *d = f->rgba + (size_t)r * w * 4;
    for (int c = 0; c < w; c++) {
      d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = 255;
      s += 4; d += 4;
    }
  }
  if (g_tsfn) napi_call_threadsafe_function(g_tsfn, f, napi_tsfn_nonblocking);
  else { free(f->rgba); delete f; }
  return TRUE;
}

static BOOL rdp_pre_connect(freerdp *inst) {
  (void)inst;
  return TRUE;
}

static BOOL rdp_post_connect(freerdp *inst) {
  return gdi_init(inst, PIXEL_FORMAT_BGRA32) ? TRUE : FALSE;
}

static void rdp_thread(std::string host, int port, std::string user, std::string pw, int w, int h) {
  freerdp *inst = freerdp_new();
  if (!inst) { g_running = false; return; }
  inst->PreConnect = rdp_pre_connect;
  inst->PostConnect = rdp_post_connect;
  inst->ContextSize = sizeof(rdpContext);
  freerdp_context_new(inst);
  g_rdp = inst;

  rdpSettings *s = inst->context->settings;
  freerdp_settings_set_string(s, FreeRDP_ServerHostname, host.c_str());
  freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port);
  freerdp_settings_set_string(s, FreeRDP_Username, user.c_str());
  freerdp_settings_set_string(s, FreeRDP_Password, pw.c_str());
  freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)w);
  freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)h);
  freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
  freerdp_settings_set_bool(s, FreeRDP_Authentication, FALSE);
  freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE);

  // Update 回调(gdi_init 会重设,post_connect 后再挂)
  if (freerdp_connect(inst)) {
    if (inst->context && inst->context->update) {
      inst->context->update->BeginPaint = rdp_begin_paint;
      inst->context->update->EndPaint = rdp_end_paint;
    }
    while (g_running && freerdp_shall_disconnect(inst) == 0) {
      HANDLE events[64];
      DWORD nev = freerdp_get_event_handles(inst->context, events, 64);
      if (nev == 0) break;
      DWORD rc = WaitForMultipleObjects(nev, events, FALSE, 100);
      if (rc == WAIT_FAILED) break;
      if (!freerdp_check_event_handles(inst->context)) break;
    }
    freerdp_disconnect(inst);
  }
  freerdp_context_free(inst);
  freerdp_free(inst);
  g_rdp = NULL;
  g_running = false;
}

static napi_value RdpConnect(napi_env env, napi_callback_info info) {
  size_t argc = 7;
  napi_value args[7];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  char host[256] = {0}, user[128] = {0}, pw[256] = {0};
  int32_t port = 3389, w = 1024, h = 768;
  napi_get_value_string_utf8(env, args[0], host, sizeof(host), NULL);
  napi_get_value_int32(env, args[1], &port);
  napi_get_value_string_utf8(env, args[2], user, sizeof(user), NULL);
  napi_get_value_string_utf8(env, args[3], pw, sizeof(pw), NULL);
  napi_value js_cb = args[6];
  if (g_running) {
    napi_throw_error(env, NULL, "already running");
    return NULL;
  }
  winpr_InitializeSSL(0);
  napi_value res_name;
  napi_create_string_utf8(env, "rdpFrame", NAPI_AUTO_LENGTH, &res_name);
  napi_create_threadsafe_function(env, js_cb, NULL, res_name, 0, 1, NULL, NULL, NULL, call_js, &g_tsfn);
  g_running = true;
  g_th = new std::thread(rdp_thread, std::string(host), (int)port, std::string(user), std::string(pw), (int)w, (int)h);
  napi_value undef;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value RdpDisconnect(napi_env env, napi_callback_info info) {
  (void)info;
  g_running = false;
  if (g_rdp) freerdp_abort_connect(g_rdp);
  if (g_th) { g_th->join(); delete g_th; g_th = NULL; }
  if (g_tsfn) { napi_release_threadsafe_function(g_tsfn, napi_tsfn_release); g_tsfn = NULL; }
  napi_value undef;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value RdpIsRunning(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value v;
  napi_get_boolean(env, g_running, &v);
  return v;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    { "rdpConnect", NULL, RdpConnect, NULL, NULL, NULL, napi_default, NULL },
    { "rdpDisconnect", NULL, RdpDisconnect, NULL, NULL, NULL, napi_default, NULL },
    { "rdpIsRunning", NULL, RdpIsRunning, NULL, NULL, NULL, napi_default, NULL },
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module rdpproxyModule = {
  .nm_version = 1, .nm_flags = 0, .nm_filename = NULL,
  .nm_register_func = Init, .nm_modname = "rdpproxy",
  .nm_priv = NULL, .reserved = { 0 },
};
extern "C" __attribute__((constructor)) void RegisterRdpProxyModule(void) {
  napi_module_register(&rdpproxyModule);
}
