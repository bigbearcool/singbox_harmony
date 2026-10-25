import { util } from '@kit.ArkTS';
import { readPrivate, writePrivate } from './Store';

export interface GroupItem {tag: string; type: string; urlTestTime?: number; urlTestDelay?: number;}
export interface OutboundGroup {tag: string; type: string; selectable: boolean; selected: string; items: GroupItem[];}
export interface ConnectionInfo {id: string; network: string; source: string; destination: string; domain: string; outbound: string; rule: string; upload: number; download: number; createdAt: number;}
export interface WireGuardPeer {index: number; lastHandshake: number; txBytes: number; rxBytes: number; endpointFamily: number;}
export interface WireGuardProbe {updatedAt: number; ok: boolean; summary: string; category: string; dnsReply: boolean; rcode: number;}
export interface WireGuardInfo {tag: string; available: boolean; active: boolean; transport: string; peers: WireGuardPeer[]; dnsConfigured: boolean; dnsCovered: boolean; ipv4: boolean; ipv6: boolean; lastProbe?: WireGuardProbe;}
export interface DashboardData {groups: OutboundGroup[]; connections: ConnectionInfo[]; logs: string[]; modes: string[]; mode: string; wireGuard: WireGuardInfo[];}
export interface ControlReply {ok: boolean; message: string; data?: DashboardData;}
export interface ControlRequest {id: string; createdAt: number; action: string; group?: string; outbound?: string; connectionId?: string; mode?: string;}
export interface ControlResult {id: string; ok: boolean; message: string;}
export function emptyDashboard(): DashboardData {return {groups:[],connections:[],logs:[],modes:[],mode:'',wireGuard:[]};}
export function readDashboard(dir: string): DashboardData {
 try {const data: DashboardData=JSON.parse(readPrivate(`${dir}/dashboard.json`)) as DashboardData;data.wireGuard=data.wireGuard || [];return data;} catch(_error) {return emptyDashboard();}
}
// One outstanding request per UI; matching acknowledgements prevent replay and
// a request's lifetime is bounded. Both files stay in the app's private sandbox.
export async function sendControl(dir: string,action: string,group: string='',outbound: string='',connectionId: string='',mode: string=''): Promise<string> {
 const id: string=util.generateRandomUUID();
 const request: ControlRequest={id:id,createdAt:Date.now(),action:action,group:group,outbound:outbound,connectionId:connectionId,mode:mode};
 writePrivate(`${dir}/control-request.json`,JSON.stringify(request));
 for(let attempt: number=0;attempt<60;attempt++){
  await new Promise<void>((resolve) => {setTimeout(resolve,100);});
  let reply: ControlResult | undefined;
  try {reply=JSON.parse(readPrivate(`${dir}/control-result.json`)) as ControlResult;} catch(_error) {}
  if(reply && reply.id===id){if(!reply.ok){throw new Error('内核未完成该操作');}return reply.message;}
 }
 throw new Error('等待 VPN 响应超时，请确认仍处于连接状态');
}
