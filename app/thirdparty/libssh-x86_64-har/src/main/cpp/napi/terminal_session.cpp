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

#include "napi/terminal_session.h"

#include <chrono>
#include <cstring>

#include "utils/log/ohos_log.h"

namespace upstream {

/* App sandbox has no passwd entry for the app uid and no $HOME; without an
 * explicit SSH_OPTIONS_SSH_DIR ssh_options_apply() fails at connect time
 * (proven in M1a FetchServerBanner). Must be inside the app sandbox. */
static const char *kSshDir = "/data/storage/el2/base/temp";
static const int kConnectTimeoutSec = 10;

TerminalSession *TerminalOpen(const std::string &host, int port, const std::string &user,
                              const std::string &pass, const std::string &privateKeyPem,
                              const std::string &passphrase, int cols, int rows, std::string &err,
                              std::string &authMethod) {
    err.clear();
    authMethod.clear();
    if (host.empty() || user.empty()) {
        err = "invalid args: host/user must not be empty";
        return nullptr;
    }
    bool wantKey = !privateKeyPem.empty();
    if (!wantKey && pass.empty()) {
        err = "invalid args: host/user/pass must not be empty";
        return nullptr;
    }
    if (cols < 1 || rows < 1) {
        err = "invalid args: cols/rows must be >= 1";
        return nullptr;
    }

    TerminalSession *s = new (std::nothrow) TerminalSession();
    if (s == nullptr) {
        err = "oom: alloc TerminalSession failed";
        return nullptr;
    }
    s->host = host;
    s->port = port;
    s->user = user;

    s->session = ssh_new();
    if (s->session == nullptr) {
        err = "ssh_new failed";
        delete s;
        return nullptr;
    }
    ssh_options_set(s->session, SSH_OPTIONS_HOST, host.c_str());
    ssh_options_set(s->session, SSH_OPTIONS_PORT, &port);
    ssh_options_set(s->session, SSH_OPTIONS_USER, user.c_str());
    ssh_options_set(s->session, SSH_OPTIONS_SSH_DIR, kSshDir);
    long timeout = kConnectTimeoutSec;
    ssh_options_set(s->session, SSH_OPTIONS_TIMEOUT, &timeout);

    if (ssh_connect(s->session) != SSH_OK) {
        err = ssh_get_error(s->session);
        ssh_free(s->session);
        delete s;
        return nullptr;
    }

    int rc = SSH_AUTH_ERROR;
    if (wantKey) {
        /* M3 keyText: import the PEM text in memory only - the private key is
         * never written to disk (red line). passphrase may be empty. */
        ssh_key key = nullptr;
        int krc = ssh_pki_import_privkey_base64(privateKeyPem.c_str(),
                                                passphrase.empty() ? nullptr : passphrase.c_str(),
                                                nullptr, nullptr, &key);
        if (krc != SSH_OK || key == nullptr) {
            ssh_key_free(key);
            key = nullptr;
            if (pass.empty()) {
                /* no password fallback possible - surface the key import
                 * failure verbatim (bad PEM / wrong passphrase) */
                err = "ssh_pki_import_privkey_base64 failed: key parse error";
                if (ssh_get_error(s->session) != nullptr && strlen(ssh_get_error(s->session)) > 0) {
                    err = std::string("key import: ") + ssh_get_error(s->session);
                }
                ssh_disconnect(s->session);
                ssh_free(s->session);
                delete s;
                return nullptr;
            }
            /* upstream semantics: fall back to password auth */
            rc = ssh_userauth_password(s->session, nullptr, pass.c_str());
            if (rc == SSH_AUTH_SUCCESS) {
                authMethod = "password";
            }
        } else {
            rc = ssh_userauth_publickey(s->session, nullptr, key);
            ssh_key_free(key);
            if (rc == SSH_AUTH_SUCCESS) {
                authMethod = "publickey";
            } else if (!pass.empty()) {
                /* upstream Start() fallback: publickey failed -> password */
                rc = ssh_userauth_password(s->session, nullptr, pass.c_str());
                if (rc == SSH_AUTH_SUCCESS) {
                    authMethod = "password";
                }
            }
        }
    } else {
        rc = ssh_userauth_password(s->session, nullptr, pass.c_str());
        if (rc == SSH_AUTH_SUCCESS) {
            authMethod = "password";
        }
    }
    if (rc != SSH_AUTH_SUCCESS) {
        err = ssh_get_error(s->session);
        ssh_disconnect(s->session);
        ssh_free(s->session);
        delete s;
        return nullptr;
    }
    LOGI("TerminalOpen auth=%s host=%s user=%s (keyText=%d)", authMethod.c_str(), host.c_str(),
         user.c_str(), wantKey ? 1 : 0);

    s->channel = ssh_channel_new(s->session);
    if (s->channel == nullptr) {
        err = ssh_get_error(s->session);
        ssh_disconnect(s->session);
        ssh_free(s->session);
        delete s;
        return nullptr;
    }
    if (ssh_channel_open_session(s->channel) != SSH_OK) {
        err = ssh_get_error(s->session);
        goto channel_fail;
    }
    if (ssh_channel_request_pty_size(s->channel, "xterm", cols, rows) != SSH_OK) {
        err = ssh_get_error(s->session);
        goto channel_fail;
    }
    if (ssh_channel_request_shell(s->channel) != SSH_OK) {
        err = ssh_get_error(s->session);
        goto channel_fail;
    }
    return s;

channel_fail:
    ssh_channel_free(s->channel);
    ssh_disconnect(s->session);
    ssh_free(s->session);
    delete s;
    return nullptr;
}

TerminalSession *TerminalOpenEx(const std::string &host, int port, const std::string &user,
                                const std::string &pass, const std::string &privateKeyPem,
                                const std::string &passphrase, int cols, int rows,
                                const std::string &encoding, int keepaliveSec, std::string &err,
                                std::string &authMethod) {
    TerminalSession *s = TerminalOpen(host, port, user, pass, privateKeyPem, passphrase, cols, rows,
                                      err, authMethod);
    if (s == nullptr) {
        return nullptr;
    }
    if (encoding == "gbk") {
        s->encoding = "gbk";
    } else {
        s->encoding = "utf-8";
    }
    s->keepaliveSec = keepaliveSec;
    if (s->keepaliveSec < 0 || s->keepaliveSec > 600) {
        s->keepaliveSec = 30; // sane default / cap (task spec: 30s default)
    }
    // keepaliveSec == 0 explicitly disables keepalive
    LOGI("TerminalOpenEx encoding=%s keepalive=%ds", s->encoding.c_str(), s->keepaliveSec);
    return s;
}

int TerminalWrite(TerminalSession *s, const void *data, size_t len, std::string &err) {
    err.clear();
    if (s == nullptr || s->channel == nullptr) {
        err = "session or channel is null";
        return -1;
    }
    std::lock_guard<std::mutex> lock(s->chanMutex);
    if (s->closing.load()) {
        err = "session is closing";
        return -1;
    }
    int n = ssh_channel_write(s->channel, data, len);
    if (n < 0) {
        err = ssh_get_error(s->session);
        return -1;
    }
    return n;
}

int TerminalResize(TerminalSession *s, int cols, int rows, std::string &err) {
    err.clear();
    if (s == nullptr || s->channel == nullptr) {
        err = "session or channel is null";
        return -1;
    }
    if (cols < 1 || rows < 1) {
        err = "invalid args: cols/rows must be >= 1";
        return -1;
    }
    std::lock_guard<std::mutex> lock(s->chanMutex);
    if (s->closing.load()) {
        err = "session is closing";
        return -1;
    }
    if (ssh_channel_change_pty_size(s->channel, cols, rows) != SSH_OK) {
        err = ssh_get_error(s->session);
        return -1;
    }
    return 0;
}

void TerminalClose(TerminalSession *s, const std::string &reason, bool fromReader) {
    if (s == nullptr) {
        return;
    }
    // Mark closing first so write/resize bail out instead of racing teardown.
    s->closing.store(true);

    if (!fromReader && s->reader.joinable()) {
        s->joined = true;
        s->reader.join();
    }

    {
        std::lock_guard<std::mutex> lock(s->chanMutex);
        if (s->channel != nullptr) {
            ssh_channel_close(s->channel);
            ssh_channel_free(s->channel);
            s->channel = nullptr;
        }
        if (s->session != nullptr) {
            ssh_disconnect(s->session);
            ssh_free(s->session);
            s->session = nullptr;
        }
    }
    delete s;
    LOGI("TerminalClose done, reason=%s", reason.c_str());
}

TunnelCtx *TunnelOpen(TerminalSession *s, const std::string &remoteHost, int remotePort,
                      std::string &err) {
    err.clear();
    if (s == nullptr || s->session == nullptr) {
        err = "session or ssh_session is null";
        return nullptr;
    }
    if (remoteHost.empty() || remotePort < 1 || remotePort > 65535) {
        err = "invalid args: host/port out of range";
        return nullptr;
    }
    if (s->closing.load()) {
        err = "session is closing";
        return nullptr;
    }
    ssh_channel chan = ssh_channel_new(s->session);
    if (chan == nullptr) {
        err = ssh_get_error(s->session);
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(s->chanMutex);
        // vendored libssh exports ONLY the new name (remote args first)
        if (ssh_channel_open_forward(chan, remoteHost.c_str(), remotePort, "127.0.0.1", 0) !=
            SSH_OK) {
            err = ssh_get_error(s->session);
            ssh_channel_free(chan);
            return nullptr;
        }
    }
    TunnelCtx *t = new (std::nothrow) TunnelCtx();
    if (t == nullptr) {
        err = "oom: alloc TunnelCtx failed";
        ssh_channel_free(chan);
        return nullptr;
    }
    t->chan = chan;
    t->session = s;
    t->sessionId = s->id;
    LOGI("TunnelOpen chan=%p remote=%s:%d on session id=%d", (void *)chan, remoteHost.c_str(),
         remotePort, s->id);
    return t;
}

int TunnelWrite(TunnelCtx *t, const void *data, size_t len, std::string &err) {
    err.clear();
    if (t == nullptr || t->chan == nullptr || t->session == nullptr) {
        err = "tunnel is null";
        return -1;
    }
    TerminalSession *s = t->session;
    std::lock_guard<std::mutex> lock(s->chanMutex);
    if (t->chan == nullptr) { // closed under us
        err = "tunnel channel is closed";
        return -1;
    }
    int n = ssh_channel_write(t->chan, data, len);
    if (n < 0) {
        err = ssh_get_error(s->session);
        return -1;
    }
    return n;
}

int TunnelPoll(TunnelCtx *t, void *buf, size_t len, std::string &err) {
    err.clear();
    if (t == nullptr || t->chan == nullptr || t->session == nullptr) {
        err = "tunnel is null";
        return -1;
    }
    TerminalSession *s = t->session;
    std::lock_guard<std::mutex> lock(s->chanMutex);
    if (t->chan == nullptr) { // closed under us
        err = "tunnel channel is closed";
        return -1;
    }
    /* Read FIRST so buffered data still flows after a remote EOF; only
     * when nothing is buffered do we distinguish idle (0) from dead
     * channel (mapped to SSH_ERROR so the JS pump drops the conn). */
    int n = ssh_channel_read_nonblocking(t->chan, buf, len, 0);
    if (n > 0) {
        return n;
    }
    if (n == SSH_ERROR) {
        err = ssh_get_error(s->session);
        return SSH_ERROR;
    }
    if (ssh_channel_is_open(t->chan) == 0 || ssh_channel_is_eof(t->chan) != 0) {
        err = "tunnel channel closed or eof";
        return SSH_ERROR;
    }
    return 0; // no data right now (NOT eof - proven M8 fact)
}

void TunnelClose(TunnelCtx *t) {
    if (t == nullptr) {
        return;
    }
    TerminalSession *s = t->session;
    if (s != nullptr && t->chan != nullptr) {
        std::lock_guard<std::mutex> lock(s->chanMutex);
        if (t->chan != nullptr) {
            ssh_channel_close(t->chan);
            ssh_channel_free(t->chan);
            t->chan = nullptr;
        }
    }
    delete t;
    LOGI("TunnelClose done");
}

} // namespace upstream
