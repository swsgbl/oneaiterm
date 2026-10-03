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

#ifndef NAPI_TERMINAL_SESSION_H
#define NAPI_TERMINAL_SESSION_H

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <libssh/libssh.h>

namespace upstream {

/** One interactive SSH terminal session (connect + pty + shell + read loop). */
struct TerminalSession {
    ssh_session session = nullptr;
    ssh_channel channel = nullptr;
    int id = 0;
    std::string host;
    int port = 22;
    std::string user;
    std::string lastError;
    std::atomic<bool> running{false};
    std::atomic<bool> closing{false};
    std::thread reader;
    // write() vs read-loop/resize can race on the same ssh_channel; serialize
    // all ssh_channel_* calls with one mutex per session.
    std::mutex chanMutex;
    // total stdout bytes pushed to JS (hilog counters)
    std::atomic<uint64_t> dataCount{0};
    // true while the reader thread is joining (reader thread checks this flag
    // before emitting 'closed'; CloseSession emits it instead)
    bool joined = false;
    // M3-3a: host encoding ("utf-8" default, "gbk" triggers native conversion)
    std::string encoding = "utf-8";
    // M3-3a: keepalive interval seconds; <=0 disables. Default set at open.
    int keepaliveSec = 30;
    // M3-3a: keepalive packets sent (hilog acceptance counter)
    std::atomic<int> keepaliveSent{0};
    // M3 relay-3b: in-flight SFTP ops holding raw pointers into this
    // session; CloseSession drains it to 0 before freeing (UAF guard).
    std::atomic<int> sftpOps{0};
};

/**
 * Connect + auth + pty(cols,rows) + shell. Fully blocking, run on a worker
 * thread. Returns nullptr on failure and fills `err` with the exact libssh
 * error string (red line: only real libssh errors are surfaced).
 *
 * M3 keyText: privateKeyPem non-empty => import the key in memory
 * (ssh_pki_import_privkey_base64, NEVER written to disk) and try
 * ssh_userauth_publickey first; on failure fall back to password exactly like
 * upstream Start() semantics. passphrase (may be empty) decrypts an encrypted
 * PEM. authMethod reports what actually succeeded ("publickey"/"password").
 */
TerminalSession *TerminalOpen(const std::string &host, int port, const std::string &user,
                              const std::string &pass, const std::string &privateKeyPem,
                              const std::string &passphrase, int cols, int rows, std::string &err,
                              std::string &authMethod);

/** M3-3a: open with per-host encoding + keepalive seconds. encoding is
 * "utf-8" (pass-through) or "gbk" (native table conversion both ways).
 * keepaliveSec < 0 or > 600 clamps to the 30s default; 0 disables. */
TerminalSession *TerminalOpenEx(const std::string &host, int port, const std::string &user,
                                const std::string &pass, const std::string &privateKeyPem,
                                const std::string &passphrase, int cols, int rows,
                                const std::string &encoding, int keepaliveSec, std::string &err,
                                std::string &authMethod);

/** Blocking write of raw bytes to the channel stdin. Returns bytes written, -1 on error (err filled). */
int TerminalWrite(TerminalSession *s, const void *data, size_t len, std::string &err);

/** Non-blocking-ish pty resize. Returns 0 on success, -1 on error (err filled). */
int TerminalResize(TerminalSession *s, int cols, int rows, std::string &err);

/** Close + join reader. Fires onClosed(reason) when not called from the reader itself. */
void TerminalClose(TerminalSession *s, const std::string &reason, bool fromReader);

/* ===================================================================== */
/* M8 relay-3: local port forwarding (-L) on a LIVE terminal session.    */
/* A tunnel is one ssh_channel opened with ssh_channel_open_forward     */
/* (direct-tcpip). The tunnel table lives in terminal_napi.cpp; these    */
/* helpers do the actual libssh calls under the session chanMutex.      */
/* ===================================================================== */
struct TunnelCtx {
    ssh_channel chan = nullptr;
    TerminalSession *session = nullptr; // owner, for chanMutex + error strings
    int id = 0;
    int sessionId = 0;
};

/** Open a direct-tcpip channel to remoteHost:remotePort on session s.
 * Returns a new TunnelCtx (caller owns the table entry) or nullptr with
 * err filled. Blocking network call - run on a worker thread. */
TunnelCtx *TunnelOpen(TerminalSession *s, const std::string &remoteHost, int remotePort,
                      std::string &err);

/** Write raw bytes to the tunnel channel. Returns bytes written, -1 on error. */
int TunnelWrite(TunnelCtx *t, const void *data, size_t len, std::string &err);

/** Non-blocking read from the tunnel. Returns bytes read (0 = no data
 * right now), SSH_EOF (-127) on remote EOF/closed, SSH_ERROR on error. */
int TunnelPoll(TunnelCtx *t, void *buf, size_t len, std::string &err);

/** Close + free the tunnel channel (takes the owner session chanMutex).
 * Safe on nullptr. Does NOT remove the table entry. */
void TunnelClose(TunnelCtx *t);

} // namespace upstream

#endif // NAPI_TERMINAL_SESSION_H
