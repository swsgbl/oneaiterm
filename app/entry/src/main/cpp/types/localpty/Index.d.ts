export declare function ptyOpen(cols: number, rows: number, onData: (text: string) => void): number;
export declare function ptyWrite(text: string): number;
export declare function ptyClose(): void;
export declare function ptyResize(cols: number, rows: number): void;
/** M5 relay4: 同步非阻塞读(每 tick 调一次),绕过 tsfn 不交付的环境问题 */
export declare function ptyPoll(): string;

/** M8 toolbox: chmod 0755 (ohos fs lacks chmod; zip extraction may drop exec bit). 0=ok */
export declare function toolsChmod(path: string): number;

/** M8 toolbox: recursive chmod 0755 (dirs+files; zip dirs may lack x-bit). returns entry count */
export declare function toolsChmodTree(path: string): number;
