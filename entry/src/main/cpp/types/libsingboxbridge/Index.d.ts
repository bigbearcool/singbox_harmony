export const version: () => Promise<string>;
export const check: (config: string) => Promise<string>;
export const start: (config: string, fd: number, path: string, physicalInterface: string) => Promise<string>;
export const stop: () => Promise<string>;
export const tunName: (fd: number) => string;
export const interfaces: () => string;
export const secureFile: (fd: number) => void;
