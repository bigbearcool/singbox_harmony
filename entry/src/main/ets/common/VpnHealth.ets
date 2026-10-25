import { VpnStatus } from './Store';

export function vpnStatusExpired(status: VpnStatus,now: number=Date.now()): boolean {
 if(!['running','starting','paused','reconnecting'].includes(status.phase)){return false;}
 return !Number.isFinite(status.updatedAt) || now-status.updatedAt>(status.phase==='starting'?90000:15000);
}
export function assessExpiredVpnStatus(status: VpnStatus,present: boolean | undefined,now: number=Date.now()): VpnStatus {
 if(!vpnStatusExpired(status,now)){return status;}
 const result: VpnStatus=JSON.parse(JSON.stringify(status)) as VpnStatus;
 // An interface confirms a VPN network exists, not that its native core is
 // responsive. Conversely a late JS heartbeat alone cannot prove disconnection.
 if(present===false && status.phase==='running'){
  result.phase='error';result.message='未发现系统 VPN 网络，请重新连接';
 } else {
  result.phase='checking';result.message=present===true?'系统 VPN 仍存在，内核响应待确认；可检查连接或断开重连':'服务状态更新延迟，请回到前台核对或断开重连';
 }
 return result;
}
