import { fileIo as fs } from '@kit.CoreFileKit';
import bridge from 'libsingboxbridge.so';
import { util } from '@kit.ArkTS';

export const BUNDLE_NAME: string = 'com.bigbear.singbox';
export const VPN_ABILITY: string = 'SingboxVpnAbility';
export const DIRECT_PROFILE: string = '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}';
export const BLOCK_IPV6_PROFILE: string = '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","rules":[{"ip_cidr":["::/0"],"action":"reject"}]}}';

export interface VpnStatus {
 phase: string;
 message: string;
 tunName: string;
 physicalInterface: string;
 ipv6AddressPresent: boolean;
 updatedAt: number;
 uplink?: number;
 downlink?: number;
 ipv4Flows?: number;
 ipv6Flows?: number;
 networkType?: string;
 physicalIPv6Available?: boolean;
 bindSuccess?: number;
 bindFailure?: number;
 lastBindError?: string;
 dnsError?: string;
 wifiConditionStatus?: string;
}
export interface CoreStats { uplink: number; downlink: number; ipv4Flows: number; ipv6Flows: number; bindSuccess: number; bindFailure: number; lastBindError: string; dnsError: string; }
export interface InterfaceAddress { name: string; family: number; address: string; }
export interface CoreResponse { ok: boolean; message: string; errorCode?: string; }

export function readPrivate(path: string): string {
 return fs.readTextSync(path);
}
export function writePrivate(path: string, content: string): void {
 const tmp: string = `${path}.${util.generateRandomUUID()}.tmp`;
 const file: fs.File = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
 try {
  bridge.secureFile(file.fd);
  const expected: number=new util.TextEncoder().encodeInto(content).length;
  if(fs.writeSync(file.fd, content)!==expected){throw new Error('写入不完整，原配置已保留');}
  fs.fsyncSync(file.fd);
 } finally { fs.closeSync(file); }
 fs.renameSync(tmp, path);
}
export function initialStatus(): VpnStatus {
 return {phase:'stopped', message:'尚未连接', tunName:'', physicalInterface:'', ipv6AddressPresent:false, updatedAt:Date.now()};
}
