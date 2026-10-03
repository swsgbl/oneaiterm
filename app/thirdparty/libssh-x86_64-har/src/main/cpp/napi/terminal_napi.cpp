/*
 * Copyright (C) 2025 upstream
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and limitations under the
 * License.
 */

#include "napi/terminal_napi.h"

#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>
#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <vector>

#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

#include <libssh/libssh.h>
#include <libssh/sftp.h> // M3 relay-3b: SFTP browser on the live session

#include <fcntl.h> // M3 relay-3b: O_RDONLY/O_WRONLY/O_CREAT for sftp_open + local open
#include <sys/stat.h>

#include "napi/terminal_session.h"
#include "napi/gbk_table.h"
#include "utils/log/ohos_log.h"

namespace {

constexpr char kTag[] = "upstream.napi";

/* ---- session table (id -> session), created lazily on module init ---- */
struct SessionTable {
    std::mutex mutex;
    int nextId = 1;
    std::map<int, upstream::TerminalSession *> map;
};
SessionTable &Table() {
    static SessionTable *t = new SessionTable();
    return *t;
}

/* ---- helper: read a JS string arg (UTF-16 -> UTF-8) ---- */
bool JsToString(napi_env env, napi_value v, std::string &out) {
    size_t len16 = 0;
    if (napi_get_value_string_utf16(env, v, nullptr, 0, &len16) != napi_ok) {
        return false;
    }
    std::u16string w(len16, u'\0');
    size_t copied = 0;
    if (napi_get_value_string_utf16(env, v, reinterpret_cast<char16_t *>(&w[0]), len16 + 1, &copied) != napi_ok) {
        return false;
    }
    w.resize(copied);
    // utf16 -> utf8 (BMP + surrogate pairs)
    out.clear();
    out.reserve(copied);
    for (size_t i = 0; i < w.size(); i++) {
        char32_t cp = w[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < w.size() && w[i + 1] >= 0xDC00 && w[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (w[i + 1] - 0xDC00);
            i++;
        }
        if (cp < 0x80) {
            out.push_back((char)cp);
        } else if (cp < 0x800) {
            out.push_back((char)(0xC0 | (cp >> 6)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back((char)(0xE0 | (cp >> 12)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            out.push_back((char)(0xF0 | (cp >> 18)));
            out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }
    return true;
}

/* ---- event model pushed to JS: { type, id, chunk?, reason?, message? } ---- */
struct EventMsg {
    int type; // 0=data 1=closed 2=error
    int id;
    std::string payload; // chunk / reason / message
};

/* One threadsafe function shared by ALL sessions: every event for every
 * session flows through it, tagged with the session id. */
napi_threadsafe_function g_tsfn = nullptr;

void FreeTsfnMsg(napi_env env, void *data, void *hint) {
    delete static_cast<EventMsg *>(data);
}

void CallJs(napi_env env, napi_value jsCallback, void *context, void *data) {
    EventMsg *msg = static_cast<EventMsg *>(data);
    if (env != nullptr && jsCallback != nullptr) {
        napi_handle_scope scope;
        napi_open_handle_scope(env, &scope);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_value cb;
        if (napi_get_reference_value(env, (napi_ref)context, &cb) == napi_ok && cb != nullptr) {
            // prefer stored callback ref (context), fall back to jsCallback param
            jsCallback = cb;
        }
        napi_value obj;
        napi_create_object(env, &obj);
        const char *typeStr = msg->type == 0 ? "data" : (msg->type == 1 ? "closed" : "error");
        napi_value t;
        napi_create_string_utf8(env, typeStr, NAPI_AUTO_LENGTH, &t);
        napi_set_named_property(env, obj, "type", t);
        napi_value idV;
        napi_create_int32(env, msg->id, &idV);
        napi_set_named_property(env, obj, "id", idV);
        if (msg->type == 0) {
            napi_value c;
            napi_create_string_utf8(env, msg->payload.c_str(), msg->payload.size(), &c);
            napi_set_named_property(env, obj, "chunk", c);
        } else if (msg->type == 1) {
            napi_value r;
            napi_create_string_utf8(env, msg->payload.c_str(), NAPI_AUTO_LENGTH, &r);
            napi_set_named_property(env, obj, "reason", r);
        } else {
            napi_value m;
            napi_create_string_utf8(env, msg->payload.c_str(), NAPI_AUTO_LENGTH, &m);
            napi_set_named_property(env, obj, "message", m);
        }
        if (msg->type == 3) { // auth info
            napi_value a;
            napi_create_string_utf8(env, msg->payload.c_str(), NAPI_AUTO_LENGTH, &a);
            napi_set_named_property(env, obj, "authMethod", a);
        }
        napi_call_function(env, undefined, jsCallback, 1, &obj, nullptr);
        napi_close_handle_scope(env, scope);
    }
    delete msg;
}

void InitGlobalTsfn(napi_env env, napi_value jsEventCallback) {
    if (g_tsfn != nullptr) {
        return; // already initialized (first SessionOpen call wins)
    }
    napi_value resourceName;
    napi_create_string_utf8(env, "upstreamSessionEvents", NAPI_AUTO_LENGTH, &resourceName);
    napi_ref cbRef = nullptr;
    napi_create_reference(env, jsEventCallback, 1, &cbRef);
    napi_create_threadsafe_function(env, jsEventCallback, nullptr /* async_resource */, resourceName,
                                    0 /* unlimited queue */, 1 /* initial threads */,
                                    nullptr /* thread_finalize cb */, nullptr /* thread_finalize data */,
                                    cbRef /* context */, CallJs, &g_tsfn);
}

bool EmitEvent(int type, int id, const std::string &payload) {
    if (g_tsfn == nullptr) {
        return false;
    }
    EventMsg *msg = new EventMsg{type, id, payload};
    napi_status st = napi_call_threadsafe_function(g_tsfn, msg, napi_tsfn_nonblocking);
    if (st != napi_ok) {
        delete msg;
        return false;
    }
    return true;
}

/* ---- UTF-8 boundary handling for data chunks ---- */
/* Returns the length of the longest prefix of buf that is complete UTF-8
 * (a multi-byte char truncated at the end is held back to the next chunk). */
size_t Utf8CompletePrefix(const char *buf, size_t len) {
    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)buf[i];
        size_t seqLen = 0;
        if (c < 0x80) {
            seqLen = 1;
        } else if ((c & 0xE0) == 0xC0) {
            seqLen = 2;
        } else if ((c & 0xF0) == 0xE0) {
            seqLen = 3;
        } else if ((c & 0xF8) == 0xF0) {
            seqLen = 4;
        } else {
            return i; // invalid byte: emit everything up to here
        }
        if (i + seqLen > len) {
            return i; // truncated multi-byte char: hold back
        }
        for (size_t k = 1; k < seqLen; k++) {
            if (((unsigned char)buf[i + k] & 0xC0) != 0x80) {
                return i; // malformed: emit prefix, resync at next byte
            }
        }
        i += seqLen;
    }
    return i;
}

/* ---- reader thread: non-blocking poll + push chunks ---- */
/* M3-3a: when session encoding is "gbk", the raw channel bytes are GBK and
 * must be converted to UTF-8 BEFORE EmitEvent (JS strings are UTF-8 here).
 * Pending tail semantics change: for GBK we hold back a trailing lead byte
 * (>=0x81) because the trail byte may arrive in the next read. */
void ReaderLoop(upstream::TerminalSession *s) {
    std::string pending; // carries incomplete UTF-8 / GBK lead byte across reads
    char buf[8192];
    const bool gbk = (s->encoding == "gbk");
    // M3-3a keepalive: send an SSH_MSG_IGNORE every keepaliveSec of idle
    // polling. ssh_send_ignore is transport-level (no reply expected) which
    // matches upstream's send-only keepalive@openssh.com semantics.
    int keepaliveSec = s->keepaliveSec;
    auto lastKeepalive = std::chrono::steady_clock::now();
    while (s->running.load()) {
        int n;
        {
            std::lock_guard<std::mutex> lock(s->chanMutex);
            if (s->channel == nullptr) {
                break;
            }
            n = ssh_channel_read_nonblocking(s->channel, buf, sizeof(buf), 0);
        }
        if (n == SSH_AGAIN) {
            // no data right now: sleep 10ms and retry (non-blocking poll loop)
            usleep(10 * 1000);
            continue;
        }
        if (n == 0) {
            /* read_nonblocking returns 0 both for "no data buffered right
             * now" and sometimes for closed channels - only treat as EOF
             * when the channel itself confirms it. This idle branch is also
             * where the keepalive timer runs (the SSH_AGAIN branch above is
             * rarely taken: libssh returns 0, not SSH_AGAIN, when idle). */
            {
                std::lock_guard<std::mutex> lock(s->chanMutex);
                if (s->channel == nullptr) {
                    break;
                }
                if (ssh_channel_is_eof(s->channel) != 0 || ssh_channel_is_open(s->channel) == 0) {
                    std::string reason = "eof";
                    if (!pending.empty()) {
                        EmitEvent(0, s->id, pending); // flush tail on close
                        pending.clear();
                    }
                    EmitEvent(1, s->id, reason);
                    break;
                }
            }
            usleep(10 * 1000);
            if (keepaliveSec > 0) {
                auto now = std::chrono::steady_clock::now();
                auto idleSec =
                    std::chrono::duration_cast<std::chrono::seconds>(now - lastKeepalive).count();
                if (idleSec >= keepaliveSec) {
                    std::lock_guard<std::mutex> lock(s->chanMutex);
                    if (s->session != nullptr && s->channel != nullptr &&
                        ssh_send_ignore(s->session, "upstream-keepalive") == SSH_OK) {
                        s->keepaliveSent.fetch_add(1);
                        LOGI("%s keepalive sent id=%d seq=%d", kTag, s->id,
                             s->keepaliveSent.load());
                    }
                    lastKeepalive = now;
                }
            }
            continue;
        }
        if (n > 0) {
            s->dataCount.fetch_add((uint64_t)n);
            lastKeepalive = std::chrono::steady_clock::now();
            if (gbk) {
                // decode GBK -> UTF-8; trailing lead byte held back via pending
                std::string piece = pending + std::string(buf, (size_t)n);
                pending.clear();
                std::string utf8;
                size_t consumed = upstream::GbkDecode(piece.data(), piece.size(), utf8);
                if (consumed < piece.size()) {
                    pending = piece.substr(consumed);
                }
                if (!utf8.empty()) {
                    // split into <=4096-char chunks like the utf-8 path
                    size_t off = 0;
                    while (off < utf8.size()) {
                        size_t take = (utf8.size() - off > 4096) ? 4096 : utf8.size() - off;
                        EmitEvent(0, s->id, utf8.substr(off, take));
                        off += take;
                    }
                }
                continue;
            }
            size_t start = 0;
            while (start < (size_t)n) {
                size_t chunkLen = ((size_t)n - start > 4096) ? 4096 : ((size_t)n - start);
                std::string piece = pending + std::string(buf + start, chunkLen);
                pending.clear();
                size_t complete = Utf8CompletePrefix(piece.data(), piece.size());
                if (complete == 0 && !piece.empty()) {
                    // pathological: whole piece incomplete/invalid; hold back a bounded tail
                    if (piece.size() >= 8) {
                        // invalid utf8 byte: drop it to avoid stalling
                        complete = 1;
                    } else {
                        pending = piece;
                        break;
                    }
                }
                if (complete > 0) {
                    EmitEvent(0, s->id, piece.substr(0, complete));
                    if (complete < piece.size()) {
                        pending = piece.substr(complete);
                    }
                }
                start += chunkLen;
            }
            continue;
        }
        if (n == SSH_EOF) {
            /* read returns SSH_EOF(-127) on remote EOF. (n == 0 idle is
             * handled above with the keepalive timer.) */
            bool eof = true;
            {
                std::lock_guard<std::mutex> lock(s->chanMutex);
                if (s->channel == nullptr) {
                    break;
                }
                eof = eof || (ssh_channel_is_eof(s->channel) != 0) || (ssh_channel_is_open(s->channel) == 0);
            }
            if (!eof) {
                usleep(10 * 1000);
                continue;
            }
            std::string reason = "eof";
            if (!pending.empty()) {
                EmitEvent(0, s->id, pending); // flush tail on close
                pending.clear();
            }
            EmitEvent(1, s->id, reason);
            break;
        }
        if (n == SSH_ERROR) {
            std::string err;
            {
                std::lock_guard<std::mutex> lock(s->chanMutex);
                err = (s->session != nullptr) ? ssh_get_error(s->session) : "ssh channel read error";
            }
            LOGE("%s read error: %s", kTag, err.c_str());
            EmitEvent(2, s->id, err);
            EmitEvent(1, s->id, "error");
            break;
        }
    }
    LOGI("%s reader exit id=%d bytes=%llu keepalive=%d", kTag, s->id,
         (unsigned long long)s->dataCount.load(), s->keepaliveSent.load());
}

/* ---- helper: run fn(session) with the session found by id, under the table
 * lock so a concurrent CloseSession cannot free it under us. Returns false if
 * the id is unknown. ---- */
bool WithSession(int id, const std::function<void(upstream::TerminalSession *)> &fn) {
    std::lock_guard<std::mutex> lock(Table().mutex);
    auto it = Table().map.find(id);
    if (it == Table().map.end()) {
        return false;
    }
    fn(it->second);
    return true;
}

void EraseSession(int id) {
    std::lock_guard<std::mutex> lock(Table().mutex);
    Table().map.erase(id);
}

} // namespace

/* ===================================================================== */
/* M3 relay-3b: SFTP browser on the LIVE terminal session                */
/* Upstream semantics (backend/session/sftp_session.go): ListRemote dir  */
/* entries + single-file Get/Put with 32KB loop + progress + bytes/ms.   */
/* libssh session is NOT thread safe: ReaderLoop takes chanMutex on every*/
/* poll, so EVERY sftp_* call below also takes chanMutex as a SHORT      */
/* critical section (per call, never across the whole transfer).         */
/* Lifetime: CloseSession (edited above) drains s->sftpOps to 0 before   */
/* freeing the ssh session, so in-flight ops can never UAF.              */
/* ===================================================================== */

namespace {

struct SftpTable {
    std::mutex mutex;
    std::map<int, sftp_session> map; // terminal session id -> sftp channel
};
SftpTable &SftpTab() {
    static SftpTable *t = new SftpTable();
    return *t;
}

/* ---- M8 relay-3: -L tunnel table. Lock order is ALWAYS
 * Table -> TunnelTab -> chanMutex (leaf). TunnelAcquire validates the
 * owner session under the Table lock (like SftpAcquire) so a concurrent
 * CloseSession can never free the session under an in-flight tunnel op. ---- */
constexpr size_t kTunnelPollMax = 32768; // single tunnelPoll chunk cap (32KB)

struct TunnelTable {
    std::mutex mutex;
    int nextId = 1;
    std::map<int, upstream::TunnelCtx *> map;
};
TunnelTable &TunnelTab() {
    static TunnelTable *t = new TunnelTable();
    return *t;
}

struct TunnelRef {
    upstream::TunnelCtx *t;
    bool ok;
    std::string err;
};

/* Bumps s->sftpOps (the generic in-flight op counter CloseSession drains)
 * under the Table lock, so it cannot race with session teardown. MUST be
 * paired with TunnelRelease. */
TunnelRef TunnelAcquire(int id) {
    TunnelRef r;
    r.t = nullptr;
    r.ok = false;
    std::lock_guard<std::mutex> lock(Table().mutex);
    std::lock_guard<std::mutex> lock2(TunnelTab().mutex);
    auto it = TunnelTab().map.find(id);
    if (it == TunnelTab().map.end()) {
        r.err = "tunnel not found: " + std::to_string(id);
        return r;
    }
    upstream::TunnelCtx *t = it->second;
    auto sit = Table().map.find(t->sessionId);
    if (sit == Table().map.end() || sit->second != t->session) {
        r.err = "tunnel owner session gone";
        return r;
    }
    r.t = t;
    r.ok = true;
    t->session->sftpOps.fetch_add(1);
    return r;
}

void TunnelRelease(TunnelRef &r) {
    if (r.t != nullptr && r.t->session != nullptr) {
        r.t->session->sftpOps.fetch_sub(1);
    }
}

/* Remove + close a tunnel by id (idempotent). Returns 0 when the entry
 * existed, -1 when not found. */
int TunnelCloseById(int id) {
    upstream::TunnelCtx *t = nullptr;
    {
        std::lock_guard<std::mutex> lock(TunnelTab().mutex);
        auto it = TunnelTab().map.find(id);
        if (it == TunnelTab().map.end()) {
            return -1;
        }
        t = it->second;
        TunnelTab().map.erase(it);
    }
    upstream::TunnelClose(t);
    return 0;
}

/* Raw-pointer acquire: bumps s->sftpOps so CloseSession waits for us.
 * MUST be paired with SftpRelease. Table/SftpTab lock order is leaf-safe
 * (Table -> chanMutex -> SftpTab everywhere; SftpTab is always last). */
struct SftpRef {
    upstream::TerminalSession *s;
    sftp_session sf;
    bool ok;
    std::string err;
};

SftpRef SftpAcquire(int id) {
    SftpRef r;
    r.s = nullptr;
    r.sf = nullptr;
    r.ok = false;
    std::lock_guard<std::mutex> lock(Table().mutex);
    auto it = Table().map.find(id);
    if (it == Table().map.end()) {
        r.err = "session not found: " + std::to_string(id);
        return r;
    }
    r.s = it->second;
    std::lock_guard<std::mutex> lock2(SftpTab().mutex);
    auto jt = SftpTab().map.find(id);
    if (jt == SftpTab().map.end()) {
        r.err = "sftp not open for session " + std::to_string(id);
        r.s = nullptr;
        return r;
    }
    r.sf = jt->second;
    r.ok = true;
    r.s->sftpOps.fetch_add(1);
    return r;
}

void SftpRelease(SftpRef &r) {
    if (r.s != nullptr) {
        r.s->sftpOps.fetch_sub(1);
    }
}

std::string JsonEscape(const std::string &in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (size_t i = 0; i < in.size(); i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') {
            out.push_back('\\');
            out.push_back((char)c);
        } else if (c < 0x20) {
            char tmp[8];
            snprintf(tmp, sizeof(tmp), "\\u%04x", (int)c);
            out += tmp;
        } else {
            out.push_back((char)c);
        }
    }
    return out;
}

uint64_t SteadyMs() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

constexpr size_t kSftpXferBuf = 32768; // 32KB loop (upstream uses 64KB reads; 32KB keeps each chanMutex section short)

} // namespace
/* ===================================================================== */
/* SessionOpenWithPassword(host, port, user, password, cols, rows)        */
/* ===================================================================== */
napi_value TerminalNapi::SessionOpenWithPassword(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 6) {
        napi_throw_type_error(env, nullptr, "expected (host, port, user, password, cols, rows[, encoding, keepaliveSec, eventCb])");
        return nullptr;
    }
    std::string host, user, pass;
    JsToString(env, args[0], host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    JsToString(env, args[2], user);
    JsToString(env, args[3], pass);
    int32_t cols = 80;
    napi_get_value_int32(env, args[4], &cols);
    int32_t rows = 24;
    napi_get_value_int32(env, args[5], &rows);
    // M3-3a optional: eventCb (arg7), encoding (arg8), keepaliveSec (arg9)
    // (order matches Index.d.ts: (..., cols, rows, eventCallback, encoding, keepaliveSec))
    napi_value eventCb = (argc >= 7) ? args[6] : nullptr;
    std::string encoding = "utf-8";
    if (argc >= 8 && args[7] != nullptr) {
        JsToString(env, args[7], encoding);
    }
    int32_t keepaliveSec = 30;
    if (argc >= 9 && args[8] != nullptr) {
        napi_get_value_int32(env, args[8], &keepaliveSec);
    }
    if (eventCb != nullptr && g_tsfn == nullptr) {
        InitGlobalTsfn(env, eventCb);
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    struct OpenCtx {
        napi_env env;
        napi_deferred deferred;
        napi_async_work work;
        std::string host;
        int port;
        std::string user;
        std::string pass;
        int cols;
        int rows;
        std::string encoding;
        int keepaliveSec;
        upstream::TerminalSession *session;
        std::string err;
        std::string authMethod;
        int sessionId;
    };
    OpenCtx *ctx =
        new OpenCtx{env, deferred, nullptr, host, port, user, pass, cols, rows, encoding,
                    keepaliveSec, nullptr, "", "", 0};

    napi_value resourceName;
    napi_create_string_utf8(env, "SessionOpenWithPassword", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env env, void *data) {
            OpenCtx *ctx = static_cast<OpenCtx *>(data);
            ctx->session = upstream::TerminalOpenEx(ctx->host, ctx->port, ctx->user, ctx->pass,
                                                   "" /* privateKeyPem */, "" /* passphrase */,
                                                   ctx->cols, ctx->rows, ctx->encoding,
                                                   ctx->keepaliveSec, ctx->err, ctx->authMethod);
        },
        [](napi_env env, napi_status status, void *data) {
            OpenCtx *ctx = static_cast<OpenCtx *>(data);
            if (ctx->session == nullptr) {
                // reject with the real libssh error string
                napi_value msg;
                napi_create_string_utf8(env, ctx->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(ctx->env, ctx->deferred, errObj);
                napi_delete_async_work(env, ctx->work);
                delete ctx;
                return;
            }
            int id;
            {
                std::lock_guard<std::mutex> lock(Table().mutex);
                id = Table().nextId++;
                Table().map[id] = ctx->session; // M2 relay-3b fix: without this
                // every later WriteStdin/ResizePty/CloseSession hit
                // "session not found" (proven: write bytes=-1, no LOGE).
            }
            ctx->session->id = id;
            ctx->session->running.store(true);
            ctx->session->reader = std::thread(ReaderLoop, ctx->session);
            napi_value idV;
            napi_create_int32(env, id, &idV);
            napi_resolve_deferred(ctx->env, ctx->deferred, idV);
            napi_delete_async_work(env, ctx->work);
            delete ctx;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* ===================================================================== */
/* SessionOpenWithKey(host, port, user, password, privateKeyPem,          */
/*                    passphrase, cols, rows)                             */
/* ===================================================================== */
napi_value TerminalNapi::SessionOpenWithKey(napi_env env, napi_callback_info info) {
    size_t argc = 11;
    napi_value args[11] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 8) {
        napi_throw_type_error(env, nullptr,
                              "expected (host, port, user, password, privateKeyPem, passphrase, cols, rows[, encoding, keepaliveSec, eventCb])");
        return nullptr;
    }
    std::string host, user, pass, keyPem, passphrase;
    JsToString(env, args[0], host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    JsToString(env, args[2], user);
    JsToString(env, args[3], pass);
    JsToString(env, args[4], keyPem);
    JsToString(env, args[5], passphrase);
    int32_t cols = 80;
    napi_get_value_int32(env, args[6], &cols);
    int32_t rows = 24;
    napi_get_value_int32(env, args[7], &rows);
    // M3-3a optional: eventCb (arg9), encoding (arg10), keepaliveSec (arg11)
    // (order matches Index.d.ts: (..., cols, rows, eventCallback, encoding, keepaliveSec))
    napi_value eventCb = (argc >= 9) ? args[8] : nullptr;
    std::string encoding = "utf-8";
    if (argc >= 10 && args[9] != nullptr) {
        JsToString(env, args[9], encoding);
    }
    int32_t keepaliveSec = 30;
    if (argc >= 11 && args[10] != nullptr) {
        napi_get_value_int32(env, args[10], &keepaliveSec);
    }
    if (eventCb != nullptr && g_tsfn == nullptr) {
        InitGlobalTsfn(env, eventCb);
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    struct OpenCtx {
        napi_env env;
        napi_deferred deferred;
        napi_async_work work;
        std::string host;
        int port;
        std::string user;
        std::string pass;
        std::string keyPem;
        std::string passphrase;
        int cols;
        int rows;
        std::string encoding;
        int keepaliveSec;
        upstream::TerminalSession *session;
        std::string err;
        std::string authMethod;
        int sessionId;
    };
    OpenCtx *ctx =
        new OpenCtx{env, deferred, nullptr, host, port, user, pass, keyPem, passphrase, cols, rows,
                    encoding, keepaliveSec, nullptr, "", "", 0};

    napi_value resourceName;
    napi_create_string_utf8(env, "SessionOpenWithKey", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env env, void *data) {
            OpenCtx *ctx = static_cast<OpenCtx *>(data);
            ctx->session = upstream::TerminalOpenEx(ctx->host, ctx->port, ctx->user, ctx->pass,
                                                   ctx->keyPem, ctx->passphrase, ctx->cols,
                                                   ctx->rows, ctx->encoding, ctx->keepaliveSec,
                                                   ctx->err, ctx->authMethod);
        },
        [](napi_env env, napi_status status, void *data) {
            OpenCtx *ctx = static_cast<OpenCtx *>(data);
            if (ctx->session == nullptr) {
                napi_value msg;
                napi_create_string_utf8(env, ctx->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(ctx->env, ctx->deferred, errObj);
                napi_delete_async_work(env, ctx->work);
                delete ctx;
                return;
            }
            int id;
            {
                std::lock_guard<std::mutex> lock(Table().mutex);
                id = Table().nextId++;
                Table().map[id] = ctx->session;
            }
            ctx->session->id = id;
            ctx->session->running.store(true);
            // tell ArkTS which auth method actually succeeded (M3 acceptance)
            EmitEvent(3, -1, ctx->authMethod);
            ctx->session->reader = std::thread(ReaderLoop, ctx->session);
            napi_value idV;
            napi_create_int32(env, id, &idV);
            napi_resolve_deferred(ctx->env, ctx->deferred, idV);
            napi_delete_async_work(env, ctx->work);
            delete ctx;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* ===================================================================== */
/* M3 credential crypto (OpenSSL, libcrypto.so.3 already linked)          */
/* ===================================================================== */
static bool HexDecode(const std::string &hex, std::vector<uint8_t> &out) {
    if (hex.size() % 2 != 0) return false;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2) {
        int hi = -1, lo = -1;
        char a = hex[i], b = hex[i + 1];
        hi = (a >= '0' && a <= '9') ? a - '0' : (a >= 'a' && a <= 'f') ? a - 'a' + 10
             : (a >= 'A' && a <= 'F') ? a - 'A' + 10 : -1;
        lo = (b >= '0' && b <= '9') ? b - '0' : (b >= 'a' && b <= 'f') ? b - 'a' + 10
             : (b >= 'A' && b <= 'F') ? b - 'A' + 10 : -1;
        if (hi < 0 || lo < 0) return false;
        out.push_back(static_cast<uint8_t>((hi << 4) | lo));
    }
    return true;
}

static std::string B64Encode(const uint8_t *data, size_t len) {
    BIO *b64 = BIO_new(BIO_f_base64());
    BIO *mem = BIO_new(BIO_s_mem());
    b64 = BIO_push(b64, mem);
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    BIO_write(b64, data, static_cast<int>(len));
    BIO_flush(b64);
    BUF_MEM *ptr = nullptr;
    BIO_get_mem_ptr(b64, &ptr);
    std::string out(ptr->data, ptr->length);
    BIO_free_all(b64);
    return out;
}

static bool B64Decode(const std::string &in, std::vector<uint8_t> &out) {
    BIO *b64 = BIO_new(BIO_f_base64());
    BIO *mem = BIO_new_mem_buf(in.data(), static_cast<int>(in.size()));
    b64 = BIO_push(b64, mem);
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    out.resize(in.size());
    int n = BIO_read(b64, out.data(), static_cast<int>(out.size()));
    BIO_free_all(b64);
    if (n < 0) return false;
    out.resize(static_cast<size_t>(n));
    return true;
}

static std::string ToHex(const uint8_t *data, size_t len) {
    static const char *kHex = "0123456789abcdef";
    std::string out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; i++) {
        out.push_back(kHex[data[i] >> 4]);
        out.push_back(kHex[data[i] & 0xF]);
    }
    return out;
}

/* kdfDerive(password, saltHex, iterations, keyLen) -> Promise<hexKey> */
napi_value TerminalNapi::KdfDerive(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "expected (password, saltHex, iterations, keyLen)");
        return nullptr;
    }
    std::string password, saltHex;
    JsToString(env, args[0], password);
    JsToString(env, args[1], saltHex);
    int32_t iterations = 600000, keyLen = 32;
    napi_get_value_int32(env, args[2], &iterations);
    napi_get_value_int32(env, args[3], &keyLen);
    std::vector<uint8_t> salt;
    if (!HexDecode(saltHex, salt)) {
        napi_throw_type_error(env, nullptr, "bad saltHex");
        return nullptr;
    }
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        std::string password;
        std::vector<uint8_t> salt;
        int iterations, keyLen;
        std::string outHex;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, password, salt, iterations, keyLen, "", ""};
    napi_value rn;
    napi_create_string_utf8(env, "KdfDerive", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            std::vector<uint8_t> key(static_cast<size_t>(c->keyLen));
            if (PKCS5_PBKDF2_HMAC(c->password.c_str(), static_cast<int>(c->password.size()), c->salt.data(),
                                  static_cast<int>(c->salt.size()), c->iterations, EVP_sha256(),
                                  c->keyLen, key.data()) != 1) {
                c->err = "PKCS5_PBKDF2_HMAC failed";
                return;
            }
            c->outHex = ToHex(key.data(), key.size());
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value hv;
                napi_create_string_utf8(env, c->outHex.c_str(), NAPI_AUTO_LENGTH, &hv);
                napi_resolve_deferred(env, c->deferred, hv);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* encSeal(plain, keyHex) -> Promise<"b64nonce:b64(ct||tag)"> */
napi_value TerminalNapi::EncSeal(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "expected (plain, keyHex)");
        return nullptr;
    }
    std::string plain, keyHex;
    JsToString(env, args[0], plain);
    JsToString(env, args[1], keyHex);
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        std::string plain, keyHex, out, err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, plain, keyHex, "", ""};
    napi_value rn;
    napi_create_string_utf8(env, "EncSeal", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            std::vector<uint8_t> key;
            if (!HexDecode(c->keyHex, key) || key.size() != 32) {
                c->err = "bad keyHex (want 32 bytes)";
                return;
            }
            uint8_t nonce[12];
            if (RAND_bytes(nonce, sizeof(nonce)) != 1) {
                c->err = "RAND_bytes failed";
                return;
            }
            EVP_CIPHER_CTX *evp = EVP_CIPHER_CTX_new();
            if (evp == nullptr) {
                c->err = "EVP_CIPHER_CTX_new failed";
                return;
            }
            std::vector<uint8_t> ct(c->plain.size() + 16);
            int len = 0, total = 0;
            do {
                if (EVP_EncryptInit_ex(evp, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
                    EVP_CIPHER_CTX_ctrl(evp, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) != 1 ||
                    EVP_EncryptInit_ex(evp, nullptr, nullptr, key.data(), nonce) != 1) {
                    c->err = "gcm init failed";
                    break;
                }
                if (!c->plain.empty() &&
                    EVP_EncryptUpdate(evp, ct.data(), &len,
                                      reinterpret_cast<const uint8_t *>(c->plain.data()),
                                      static_cast<int>(c->plain.size())) != 1) {
                    c->err = "gcm update failed";
                    break;
                }
                total = len;
                if (EVP_EncryptFinal_ex(evp, ct.data() + total, &len) != 1) {
                    c->err = "gcm final failed";
                    break;
                }
                total += len;
                uint8_t tag[16];
                if (EVP_CIPHER_CTX_ctrl(evp, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1) {
                    c->err = "gcm get tag failed";
                    break;
                }
                memcpy(ct.data() + total, tag, 16);
                total += 16;
                ct.resize(static_cast<size_t>(total));
                c->out = B64Encode(nonce, 12) + ":" + B64Encode(ct.data(), ct.size());
            } while (false);
            EVP_CIPHER_CTX_free(evp);
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value hv;
                napi_create_string_utf8(env, c->out.c_str(), NAPI_AUTO_LENGTH, &hv);
                napi_resolve_deferred(env, c->deferred, hv);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* encOpen("b64nonce:b64(ct||tag)", keyHex) -> Promise<plain> */
napi_value TerminalNapi::EncOpen(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "expected (value, keyHex)");
        return nullptr;
    }
    std::string value, keyHex;
    JsToString(env, args[0], value);
    JsToString(env, args[1], keyHex);
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        std::string value, keyHex, out, err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, value, keyHex, "", ""};
    napi_value rn;
    napi_create_string_utf8(env, "EncOpen", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            std::vector<uint8_t> key;
            if (!HexDecode(c->keyHex, key) || key.size() != 32) {
                c->err = "bad keyHex (want 32 bytes)";
                return;
            }
            size_t sep = c->value.find(':');
            if (sep == std::string::npos) {
                c->err = "malformed value";
                return;
            }
            std::vector<uint8_t> nonce, ctAll;
            if (!B64Decode(c->value.substr(0, sep), nonce) || nonce.size() != 12 ||
                !B64Decode(c->value.substr(sep + 1), ctAll) || ctAll.size() < 16) {
                c->err = "malformed base64";
                return;
            }
            size_t ctLen = ctAll.size() - 16;
            EVP_CIPHER_CTX *evp = EVP_CIPHER_CTX_new();
            if (evp == nullptr) {
                c->err = "EVP_CIPHER_CTX_new failed";
                return;
            }
            std::vector<uint8_t> pt(ctLen + 1);
            int len = 0, total = 0;
            do {
                if (EVP_DecryptInit_ex(evp, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
                    EVP_CIPHER_CTX_ctrl(evp, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) != 1 ||
                    EVP_DecryptInit_ex(evp, nullptr, nullptr, key.data(), nonce.data()) != 1) {
                    c->err = "gcm init failed";
                    break;
                }
                if (ctLen > 0 &&
                    EVP_DecryptUpdate(evp, pt.data(), &len, ctAll.data(), static_cast<int>(ctLen)) != 1) {
                    c->err = "gcm update failed";
                    break;
                }
                total = len;
                if (EVP_CIPHER_CTX_ctrl(evp, EVP_CTRL_GCM_SET_TAG, 16, ctAll.data() + ctLen) != 1) {
                    c->err = "gcm set tag failed";
                    break;
                }
                if (EVP_DecryptFinal_ex(evp, pt.data() + total, &len) != 1) {
                    c->err = "auth failed (wrong key / corrupted)";
                    break;
                }
                total += len;
                c->out.assign(reinterpret_cast<char *>(pt.data()), static_cast<size_t>(total));
            } while (false);
            EVP_CIPHER_CTX_free(evp);
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value hv;
                napi_create_string_utf8(env, c->out.c_str(), NAPI_AUTO_LENGTH, &hv);
                napi_resolve_deferred(env, c->deferred, hv);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* randBytes(len) -> Promise<hex> */
napi_value TerminalNapi::RandBytes(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t len = 16;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &len);
    }
    std::vector<uint8_t> buf(static_cast<size_t>(len));
    if (RAND_bytes(buf.data(), len) != 1) {
        napi_throw_error(env, nullptr, "RAND_bytes failed");
        return nullptr;
    }
    napi_value hv;
    napi_create_string_utf8(env, ToHex(buf.data(), buf.size()).c_str(), NAPI_AUTO_LENGTH, &hv);
    return hv;
}

napi_value TerminalNapi::WriteStdin(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string text;
    JsToString(env, args[1], text);

    std::string err;
    int written = -1;
    if (WithSession(id, [&](upstream::TerminalSession *s) {
        std::string wire;
        if (s->encoding == "gbk") {
            // M3-3a: JS sends UTF-8; the host expects GBK on stdin
            if (!upstream::Utf8ToGbk(text, wire)) {
                LOGW("%s write id=%d: utf8->gbk partial (unmappable chars as '?')", kTag, id);
            }
        } else {
            wire = text;
        }
        written = upstream::TerminalWrite(s, wire.data(), wire.size(), err); })) {
        if (written < 0) {
            LOGE("%s write id=%d failed: %s", kTag, id, err.c_str());
            EmitEvent(2, id, err);
        }
    } else {
        err = "session not found: " + std::to_string(id);
    }
    LOGI("%s write id=%d bytes=%d", kTag, id, written);
    napi_value result;
    napi_create_int32(env, written, &result);
    return result;
}

/* ===================================================================== */
/* ResizePty(id, cols, rows)                                              */
/* ===================================================================== */
napi_value TerminalNapi::ResizePty(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0, cols = 0, rows = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int32(env, args[1], &cols);
    napi_get_value_int32(env, args[2], &rows);

    std::string err;
    int rc = -1;
    if (WithSession(id, [&](upstream::TerminalSession *s) {
        rc = upstream::TerminalResize(s, cols, rows, err); })) {
        if (rc != 0) {
            LOGE("%s resize id=%d failed: %s", kTag, id, err.c_str());
            EmitEvent(2, id, err);
        }
    } else {
        err = "session not found: " + std::to_string(id);
    }
    LOGI("%s resize id=%d %dx%d rc=%d", kTag, id, cols, rows, rc);
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

/* ===================================================================== */
/* CloseSession(id)                                                       */
/* ===================================================================== */
napi_value TerminalNapi::CloseSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);

    upstream::TerminalSession *s = nullptr;
    {
        std::lock_guard<std::mutex> lock(Table().mutex);
        auto it = Table().map.find(id);
        if (it != Table().map.end()) {
            s = it->second;
            Table().map.erase(it);
        }
    }
    if (s == nullptr) {
        LOGW("%s close id=%d: not found", kTag, id);
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }
    s->running.store(false);
    // M3 relay-3b: wait for in-flight SFTP/tunnel ops (they hold raw
    // pointers into this session via the sftpOps counter), then free the
    // sftp channel under chanMutex.
    for (int i = 0; i < 10000 && s->sftpOps.load() > 0; i++) {
        usleep(1000);
    }
    // M8 relay-3: now that no tunnel op can be in flight (new acquires
    // fail: the session is gone from the table), close every -L tunnel
    // owned by this session. TunnelCloseById takes TunnelTab + chanMutex.
    {
        std::vector<int> tids;
        {
            std::lock_guard<std::mutex> tl(TunnelTab().mutex);
            for (auto &kv : TunnelTab().map) {
                if (kv.second->sessionId == id) {
                    tids.push_back(kv.first);
                }
            }
        }
        for (int tid : tids) {
            TunnelCloseById(tid);
        }
        if (!tids.empty()) {
            LOGI("%s closed %d tunnel(s) on session close id=%d", kTag, (int)tids.size(), id);
        }
    }
    {
        std::lock_guard<std::mutex> sftpLock(SftpTab().mutex);
        auto sj = SftpTab().map.find(id);
        if (sj != SftpTab().map.end()) {
            std::lock_guard<std::mutex> lock(s->chanMutex);
            sftp_free(sj->second);
            SftpTab().map.erase(sj);
            LOGI("%s sftp freed on session close id=%d", kTag, id);
        }
    }
    // close channel so the reader loop exits promptly
    {
        std::lock_guard<std::mutex> lock(s->chanMutex);
        if (s->channel != nullptr) {
            ssh_channel_send_eof(s->channel);
            ssh_channel_close(s->channel);
        }
    }
    EmitEvent(1, id, "closed locally");
    upstream::TerminalClose(s, "local close", false);
    LOGI("%s close id=%d done", kTag, id);
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}




/* SftpOpen(sessionId) -> Promise<number> (0 ok, -1 fail) */
napi_value TerminalNapi::SftpOpen(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int id;
        int rc;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, id, -1, ""};
    napi_value rn;
    napi_create_string_utf8(env, "SftpOpen", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            // already open? reuse
            {
                std::lock_guard<std::mutex> l(SftpTab().mutex);
                if (SftpTab().map.count(c->id) > 0) {
                    c->rc = 0;
                    return;
                }
            }
            upstream::TerminalSession *s = nullptr;
            {
                std::lock_guard<std::mutex> lock(Table().mutex);
                auto it = Table().map.find(c->id);
                if (it == Table().map.end()) {
                    c->err = "session not found: " + std::to_string(c->id);
                    return;
                }
                s = it->second;
            }
            if (s->session == nullptr) {
                c->err = "no ssh session";
                return;
            }
            // sftp_new/sftp_init touch the ssh session: chanMutex short section
            sftp_session sf = nullptr;
            {
                std::lock_guard<std::mutex> l(s->chanMutex);
                sf = sftp_new(s->session);
                if (sf == nullptr) {
                    c->err = ssh_get_error(s->session);
                } else if (sftp_init(sf) != SSH_OK) {
                    c->err = ssh_get_error(s->session);
                    sftp_free(sf);
                    sf = nullptr;
                }
            }
            if (sf != nullptr) {
                std::lock_guard<std::mutex> l(SftpTab().mutex);
                SftpTab().map[c->id] = sf;
                c->rc = 0;
                LOGI("%s sftp open id=%d ok", kTag, c->id);
            }
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (c->rc != 0) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value v;
                napi_create_int32(env, 0, &v);
                napi_resolve_deferred(env, c->deferred, v);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* SftpList(sessionId, path) -> Promise<string JSON
 * {"dir":...,"files":[{"name","size","isDir","mtime","permissions"},...]} */
napi_value TerminalNapi::SftpList(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string path;
    JsToString(env, args[1], path);
    if (path.empty()) {
        path = ".";
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int id;
        std::string path;
        std::string json;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, id, path, "", ""};
    napi_value rn;
    napi_create_string_utf8(env, "SftpList", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            SftpRef r = SftpAcquire(c->id);
            if (!r.ok) {
                c->err = r.err;
                return;
            }
            sftp_dir dir = nullptr;
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                dir = sftp_opendir(r.sf, c->path.c_str());
            }
            if (dir == nullptr) {
                c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "opendir failed";
                SftpRelease(r);
                return;
            }
            std::string out = "{\"dir\":\"" + JsonEscape(c->path) + "\",\"files\":[";
            bool first = true;
            while (true) {
                sftp_attributes a = nullptr;
                {
                    std::lock_guard<std::mutex> l(r.s->chanMutex);
                    a = sftp_readdir(r.sf, dir);
                }
                if (a == nullptr) {
                    break;
                }
                bool isDir = (a->permissions & SSH_S_IFMT) == SSH_S_IFDIR;
                if (!first) {
                    out += ",";
                }
                first = false;
                out += "{\"name\":\"";
                out += JsonEscape(a->name != nullptr ? a->name : "");
                out += "\",\"size\":";
                out += std::to_string((unsigned long long)a->size);
                out += ",\"isDir\":";
                out += isDir ? "true" : "false";
                out += ",\"mtime\":";
                out += std::to_string((unsigned long long)a->mtime);
                out += ",\"permissions\":";
                out += std::to_string((unsigned long long)a->permissions);
                out += "}";
                sftp_attributes_free(a);
            }
            out += "]}";
            int crc = 0;
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                crc = sftp_closedir(dir);
            }
            if (crc != 0) {
                c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "closedir failed";
                SftpRelease(r);
                return;
            }
            c->json = out;
            SftpRelease(r);
            LOGI("%s sftp list id=%d path=%s len=%zu", kTag, c->id, c->path.c_str(), out.size());
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value v;
                napi_create_string_utf8(env, c->json.c_str(), c->json.size(), &v);
                napi_resolve_deferred(env, c->deferred, v);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* SftpDownload(sessionId, remotePath, localPath) -> Promise<number bytes> */
napi_value TerminalNapi::SftpDownload(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string remote, local;
    JsToString(env, args[1], remote);
    JsToString(env, args[2], local);

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int id;
        std::string remote, local;
        uint64_t total;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, id, remote, local, 0, ""};
    napi_value rn;
    napi_create_string_utf8(env, "SftpDownload", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            SftpRef r = SftpAcquire(c->id);
            if (!r.ok) {
                c->err = r.err;
                return;
            }
            uint64_t t0 = SteadyMs();
            sftp_file rf = nullptr;
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                rf = sftp_open(r.sf, c->remote.c_str(), O_RDONLY, 0);
            }
            if (rf == nullptr) {
                c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "sftp_open failed";
                SftpRelease(r);
                return;
            }
            int fd = open(c->local.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) {
                c->err = "open local failed: " + c->local;
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                sftp_close(rf);
                SftpRelease(r);
                return;
            }
            std::string buf(kSftpXferBuf, '\0');
            uint64_t done = 0;
            bool fail = false;
            while (true) {
                ssize_t n = 0;
                {
                    std::lock_guard<std::mutex> l(r.s->chanMutex);
                    n = sftp_read(rf, &buf[0], kSftpXferBuf);
                }
                if (n < 0) {
                    c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "sftp_read failed";
                    fail = true;
                    break;
                }
                if (n == 0) {
                    break; // EOF
                }
                size_t off = 0;
                while (off < (size_t)n) {
                    ssize_t w = write(fd, buf.data() + off, (size_t)n - off);
                    if (w <= 0) {
                        c->err = "local write failed";
                        fail = true;
                        break;
                    }
                    off += (size_t)w;
                }
                if (fail) {
                    break;
                }
                done += (uint64_t)n;
                if (done % 262144 < kSftpXferBuf) { // ~every 256KB
                    EmitEvent(4, c->id, "dl " + std::to_string(done));
                }
            }
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                sftp_close(rf);
            }
            close(fd);
            uint64_t ms = SteadyMs() - t0;
            LOGI("%s sftp dl id=%d bytes=%llu ms=%llu fail=%d", kTag, c->id,
                 (unsigned long long)done, (unsigned long long)ms, fail ? 1 : 0);
            if (fail) {
                c->total = 0;
            } else {
                c->total = done;
                EmitEvent(4, c->id, "dl " + std::to_string(done));
            }
            SftpRelease(r);
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value v;
                napi_create_int64(env, (int64_t)c->total, &v);
                napi_resolve_deferred(env, c->deferred, v);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* SftpUpload(sessionId, localPath, remotePath) -> Promise<number bytes> */
napi_value TerminalNapi::SftpUpload(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string local, remote;
    JsToString(env, args[1], local);
    JsToString(env, args[2], remote);

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int id;
        std::string local, remote;
        uint64_t total;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, id, local, remote, 0, ""};
    napi_value rn;
    napi_create_string_utf8(env, "SftpUpload", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            SftpRef r = SftpAcquire(c->id);
            if (!r.ok) {
                c->err = r.err;
                return;
            }
            uint64_t t0 = SteadyMs();
            int fd = open(c->local.c_str(), O_RDONLY);
            if (fd < 0) {
                c->err = "open local failed: " + c->local;
                SftpRelease(r);
                return;
            }
            sftp_file wf = nullptr;
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                wf = sftp_open(r.sf, c->remote.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
            }
            if (wf == nullptr) {
                c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "sftp_open failed";
                close(fd);
                SftpRelease(r);
                return;
            }
            std::string buf(kSftpXferBuf, '\0');
            uint64_t done = 0;
            bool fail = false;
            while (true) {
                ssize_t n = read(fd, &buf[0], kSftpXferBuf);
                if (n < 0) {
                    c->err = "local read failed";
                    fail = true;
                    break;
                }
                if (n == 0) {
                    break;
                }
                size_t off = 0;
                while (off < (size_t)n) {
                    ssize_t w = 0;
                    {
                        std::lock_guard<std::mutex> l(r.s->chanMutex);
                        w = sftp_write(wf, buf.data() + off, (size_t)n - off);
                    }
                    if (w <= 0) {
                        c->err = r.s->session != nullptr ? ssh_get_error(r.s->session) : "sftp_write failed";
                        fail = true;
                        break;
                    }
                    off += (size_t)w;
                }
                if (fail) {
                    break;
                }
                done += (uint64_t)n;
                if (done % 262144 < kSftpXferBuf) {
                    EmitEvent(4, c->id, "ul " + std::to_string(done));
                }
            }
            {
                std::lock_guard<std::mutex> l(r.s->chanMutex);
                sftp_close(wf);
            }
            close(fd);
            uint64_t ms = SteadyMs() - t0;
            LOGI("%s sftp ul id=%d bytes=%llu ms=%llu fail=%d", kTag, c->id,
                 (unsigned long long)done, (unsigned long long)ms, fail ? 1 : 0);
            if (fail) {
                c->total = 0;
            } else {
                c->total = done;
                EmitEvent(4, c->id, "ul " + std::to_string(done));
            }
            SftpRelease(r);
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (!c->err.empty()) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value v;
                napi_create_int64(env, (int64_t)c->total, &v);
                napi_resolve_deferred(env, c->deferred, v);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* SftpClose(sessionId) -> number (0 ok, -1 not open) - synchronous */
napi_value TerminalNapi::SftpClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    int rc = -1;
    // drain in-flight ops on this sftp channel, then free under chanMutex
    upstream::TerminalSession *s = nullptr;
    {
        std::lock_guard<std::mutex> lock(Table().mutex);
        auto it = Table().map.find(id);
        if (it != Table().map.end()) {
            s = it->second;
        }
    }
    if (s != nullptr) {
        for (int i = 0; i < 10000 && s->sftpOps.load() > 0; i++) {
            usleep(1000);
        }
        std::lock_guard<std::mutex> l(s->chanMutex);
        std::lock_guard<std::mutex> l2(SftpTab().mutex);
        auto jt = SftpTab().map.find(id);
        if (jt != SftpTab().map.end()) {
            sftp_free(jt->second);
            SftpTab().map.erase(jt);
            rc = 0;
            LOGI("%s sftp close id=%d ok", kTag, id);
        }
    } else {
        // session gone: just drop the entry if any
        std::lock_guard<std::mutex> l2(SftpTab().mutex);
        auto jt = SftpTab().map.find(id);
        if (jt != SftpTab().map.end()) {
            SftpTab().map.erase(jt);
            rc = 0;
        }
    }
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

/* ===================================================================== */
/* M8 relay-3: -L bindings. Data crosses the napi boundary as base64    */
/* (the boundary is UTF-8 strings; raw binary is not opaque-safe).      */
/* ===================================================================== */

/* tunnelOpen(sessionId, remoteHost, remotePort) -> Promise<number tunnelId> */
napi_value TerminalNapi::TunnelOpenBinding(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "expected (sessionId, remoteHost, remotePort)");
        return nullptr;
    }
    int32_t sessionId = 0, remotePort = 0;
    napi_get_value_int32(env, args[0], &sessionId);
    std::string remoteHost;
    JsToString(env, args[1], remoteHost);
    napi_get_value_int32(env, args[2], &remotePort);

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int sessionId;
        std::string remoteHost;
        int remotePort;
        int tunnelId;
        std::string err;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, sessionId, remoteHost, remotePort, -1, ""};
    napi_value rn;
    napi_create_string_utf8(env, "TunnelOpenBinding", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            upstream::TerminalSession *s = nullptr;
            {
                std::lock_guard<std::mutex> lock(Table().mutex);
                auto it = Table().map.find(c->sessionId);
                if (it == Table().map.end()) {
                    c->err = "session not found: " + std::to_string(c->sessionId);
                    return;
                }
                s = it->second;
            }
            upstream::TunnelCtx *t = upstream::TunnelOpen(s, c->remoteHost, c->remotePort, c->err);
            if (t == nullptr) {
                return;
            }
            int id;
            {
                std::lock_guard<std::mutex> lock(TunnelTab().mutex);
                id = TunnelTab().nextId++;
                TunnelTab().map[id] = t;
            }
            t->id = id;
            c->tunnelId = id;
            LOGI("%s tunnel open id=%d session=%d remote=%s:%d", kTag, id, c->sessionId,
                 c->remoteHost.c_str(), c->remotePort);
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            if (c->tunnelId < 0) {
                napi_value msg;
                napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &msg);
                napi_value errObj;
                napi_create_error(env, nullptr, msg, &errObj);
                napi_reject_deferred(env, c->deferred, errObj);
            } else {
                napi_value v;
                napi_create_int32(env, c->tunnelId, &v);
                napi_resolve_deferred(env, c->deferred, v);
            }
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* tunnelWrite(tunnelId, base64) -> number (bytes written, -1 fail; a fail
 * also closes + removes the tunnel on the native side) */
napi_value TerminalNapi::TunnelWriteBinding(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "expected (tunnelId, base64)");
        return nullptr;
    }
    int32_t tid = 0;
    napi_get_value_int32(env, args[0], &tid);
    std::string b64;
    JsToString(env, args[1], b64);
    std::vector<uint8_t> bin;
    if (!b64.empty() && !B64Decode(b64, bin)) {
        napi_throw_type_error(env, nullptr, "bad base64");
        return nullptr;
    }
    int written = -1;
    std::string err;
    TunnelRef r = TunnelAcquire(tid);
    if (!r.ok) {
        LOGW("%s tunnel write id=%d: %s", kTag, tid, r.err.c_str());
    } else {
        written = upstream::TunnelWrite(r.t, bin.data(), bin.size(), err);
        TunnelRelease(r);
        if (written < 0) {
            LOGE("%s tunnel write id=%d failed: %s", kTag, tid, err.c_str());
            TunnelCloseById(tid);
        }
    }
    napi_value result;
    napi_create_int32(env, written, &result);
    return result;
}

/* tunnelPoll(tunnelId) -> Promise<string>: "n:<b64>" data chunk ("n:" =
 * none this tick), or "closed" when the tunnel is gone/eof/errored (the
 * tunnel is closed + removed on the native side before resolving). */
napi_value TerminalNapi::TunnelPollBinding(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "expected (tunnelId)");
        return nullptr;
    }
    int32_t tid = 0;
    napi_get_value_int32(env, args[0], &tid);

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    struct Ctx {
        napi_deferred deferred;
        napi_async_work work;
        int tid;
        std::string result;
    };
    Ctx *ctx = new Ctx{deferred, nullptr, tid, ""};
    napi_value rn;
    napi_create_string_utf8(env, "TunnelPollBinding", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(
        env, nullptr, rn,
        [](napi_env, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            TunnelRef r = TunnelAcquire(c->tid);
            if (!r.ok) {
                c->result = "closed";
                return;
            }
            char buf[kTunnelPollMax];
            std::string err;
            int n = upstream::TunnelPoll(r.t, buf, sizeof(buf), err);
            if (n > 0) {
                c->result = "n:" + B64Encode(reinterpret_cast<const uint8_t *>(buf), (size_t)n);
                TunnelRelease(r);
            } else if (n == 0) {
                c->result = "n:"; // no data right now (NOT eof - proven M8 fact)
                TunnelRelease(r);
            } else {
                LOGI("%s tunnel poll id=%d closed: %s", kTag, c->tid, err.c_str());
                TunnelRelease(r);
                TunnelCloseById(c->tid);
                c->result = "closed";
            }
        },
        [](napi_env env, napi_status, void *data) {
            Ctx *c = static_cast<Ctx *>(data);
            napi_value v;
            napi_create_string_utf8(env, c->result.c_str(), c->result.size(), &v);
            napi_resolve_deferred(env, c->deferred, v);
            napi_delete_async_work(env, c->work);
            delete c;
        },
        ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/* tunnelClose(tunnelId) -> number (0 ok, -1 not found) */
napi_value TerminalNapi::TunnelCloseBinding(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "expected (tunnelId)");
        return nullptr;
    }
    int32_t tid = 0;
    napi_get_value_int32(env, args[0], &tid);
    int rc = TunnelCloseById(tid);
    LOGI("%s tunnel close id=%d rc=%d", kTag, tid, rc);
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}
