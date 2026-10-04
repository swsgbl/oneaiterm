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

#ifndef NAPI_TERMINAL_NAPI_H
#define NAPI_TERMINAL_NAPI_H

#include <napi/native_api.h>

class TerminalNapi {
public:
    /* args: (host, port, user, password, cols, rows) -> Promise<number sessionId | Error{message}> */
    static napi_value SessionOpenWithPassword(napi_env env, napi_callback_info info);
    /* args: (host, port, user, password, privateKeyPem, passphrase, cols, rows)
     *       -> Promise<number sessionId | Error{message}>; emits an event
     *       {type:"auth", authMethod} before resolving. */
    static napi_value SessionOpenWithKey(napi_env env, napi_callback_info info);
    /* M3 credential crypto (OpenSSL): KDF + AES-GCM seal/open + rand */
    static napi_value KdfDerive(napi_env env, napi_callback_info info);
    static napi_value EncSeal(napi_env env, napi_callback_info info);
    static napi_value EncOpen(napi_env env, napi_callback_info info);
    static napi_value RandBytes(napi_env env, napi_callback_info info);
    /* args: (sessionId, text) -> number (bytes written, -1 fail) */
    static napi_value WriteStdin(napi_env env, napi_callback_info info);
    /* args: (sessionId, cols, rows) -> number (0 ok, -1 fail) */
    static napi_value ResizePty(napi_env env, napi_callback_info info);
    /* args: (sessionId) -> number (0 ok) */
    static napi_value CloseSession(napi_env env, napi_callback_info info);
    /* M3 relay-3b SFTP: operate on the LIVE terminal ssh session.
     * SftpOpen/List are async promises; progress events type=4 payload
     * "dl <bytes>" / "ul <bytes>"; SftpClose is synchronous. */
    static napi_value SftpOpen(napi_env env, napi_callback_info info);
    static napi_value SftpList(napi_env env, napi_callback_info info);
    static napi_value SftpDownload(napi_env env, napi_callback_info info);
    static napi_value SftpUpload(napi_env env, napi_callback_info info);
    static napi_value SftpClose(napi_env env, napi_callback_info info);
    /* M8 relay-3 -L tunnels on the LIVE terminal session. Data crosses the
     * boundary as base64 (UTF-8 string boundary); tunnelOpen is an async
     * promise, tunnelWrite/tunnelClose are synchronous, tunnelPoll is an
     * async promise returning "n:<b64>" / "n:" (none) / "closed". */
    static napi_value TunnelOpenBinding(napi_env env, napi_callback_info info);
    static napi_value TunnelWriteBinding(napi_env env, napi_callback_info info);
    static napi_value TunnelPollBinding(napi_env env, napi_callback_info info);
    static napi_value TunnelCloseBinding(napi_env env, napi_callback_info info);
    /* M8 relay-5 Zmodem: raw (base64) data path over the live terminal. */
    static napi_value ZmSetRaw(napi_env env, napi_callback_info info);
    static napi_value ZmWriteBinary(napi_env env, napi_callback_info info);
};

#endif // NAPI_TERMINAL_NAPI_H
