/*
 * Copyright (C) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

export declare class SSH2Napi {
  createShell: () => number;
  keygen: (privateKeyPath: string, publicKeyPath: string, type: string) => number;
  setUser: (username: string, userpass: string) => number;
  startSFTPServer: (privateKeyPath: string, publicKeyPath: string, port: string, callback: Function) => void;
  startSSHClient: (ip: string, port: string, privateKeyPath: string, callback: Function) => Promise<number>;
  executeSSHCommand: (command: string, time_ms?: number) => Promise<string>;
  stopSSHClient: () => number;
  stopSFTPServer: () => number;
  setSFTPKeyexChangeCer: (cer: string) => number;
  setSFTPServerCer: (cer: string) => number;
  setSFTPMessageCer: (cer: string) => number;
  sftpRequestRead: (ip: string, port: string, privateKeyPath: string, fileDir: string) => Promise<string>;
  getPublicKeyFingerprint: (publicKeyPath: string) => Promise<string>;
  getServerBanner: (ip: string, port: string) => Promise<string>;
  sessionOpenWithPassword: (
    host: string, port: number, user: string, password: string, cols: number, rows: number,
    eventCallback?: (ev: { type: string, id: number, chunk?: string, reason?: string, message?: string }) => void,

    encoding?: string, keepaliveSec?: number
  ) => Promise<number>;
  sessionOpenWithKey: (
    host: string, port: number, user: string, password: string, privateKeyPem: string,
    passphrase: string, cols: number, rows: number,
    eventCallback?: (ev: { type: string, id: number, chunk?: string, reason?: string, message?: string, authMethod?: string }) => void,

    encoding?: string, keepaliveSec?: number
  ) => Promise<number>;
  kdfDerive: (password: string, saltHex: string, iterations: number, keyLen: number) => Promise<string>;
  encSeal: (plain: string, keyHex: string) => Promise<string>;
  encOpen: (value: string, keyHex: string) => Promise<string>;
  randBytes: (len: number) => string;
  writeStdin: (sessionId: number, text: string) => number;
  resizePty: (sessionId: number, cols: number, rows: number) => number;
  closeSession: (sessionId: number) => number;
  sftpOpen: (sessionId: number) => Promise<number>;
  sftpList: (sessionId: number, path: string) => Promise<string>;
  sftpDownload: (sessionId: number, remotePath: string, localPath: string) => Promise<number>;
  sftpUpload: (sessionId: number, localPath: string, remotePath: string) => Promise<number>;
  sftpClose: (sessionId: number) => number;
}