export declare function ptyOpen(cols: number, rows: number, onData: (text: string) => void): number;
export declare function ptyWrite(text: string): number;
export declare function ptyClose(): void;
export declare function ptyResize(cols: number, rows: number): void;
/** M5 relay4: 同步非阻塞读(每 tick 调一次),绕过 tsfn 不交付的环境问题 */
export declare function ptyPoll(): string;
