export declare function rdpConnect(host: string, port: number, user: string, password: string, w: number, h: number,
  onFrame: (x: number, y: number, w: number, h: number, ab: ArrayBuffer) => void): void;
export declare function rdpDisconnect(): void;
export declare function rdpIsRunning(): boolean;
