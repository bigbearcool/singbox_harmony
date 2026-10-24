import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import bridge from 'libsingboxbridge.so';
import { BUNDLE_NAME, VPN_ABILITY, readPrivate, writePrivate, initialStatus, VpnStatus, InterfaceAddress, CoreResponse } from '../common/Store';

export default class SingboxVpnAbility extends VpnExtensionAbility {
 private conn?: vpnExtension.VpnConnection;
 private destroyed: boolean = false;
 private status: VpnStatus = initialStatus();
 private task: Promise<void> = Promise.resolve();
 private networkTimer: number = -1;
 private checkingNetwork: boolean = false;

 onCreate(_want: Want): void {
  this.destroyed = false;
  this.task = this.startVpn();
 }
 onDestroy(): void {
  this.destroyed = true;
  if (this.networkTimer !== -1) { clearInterval(this.networkTimer); }
  // Queue shutdown after any startup in flight, so a late start cannot resurrect the VPN.
  this.task = this.task.then(async () => { await this.cleanup(); if(this.status.phase!=='error'){this.publish('stopped','VPN 已停止');} });
 }
 private publish(phase: string, message: string): void {
  this.status.phase=phase;this.status.message=message;this.status.updatedAt=Date.now();
  writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));
  hilog.info(0xD001700,'SingboxHarmony','phase=%{public}s tun=%{public}s ipv6Address=%{public}s',phase,this.status.tunName,String(this.status.ipv6AddressPresent));
 }
 private requireAlive(): void { if(this.destroyed){ throw new Error('启动已取消'); } }
 private async physicalNetwork(): Promise<string> {
  const preferred: connection.NetHandle = await connection.getDefaultNet();
  const candidates: connection.NetHandle[] = [preferred, ...await connection.getAllNets()];
  for (const handle of candidates) {
   const caps: connection.NetCapabilities = await connection.getNetCapabilities(handle);
   if(caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) { continue; }
   if(!caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_INTERNET)) { continue; }
   const props: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
   if(props.interfaceName.length>0) { return props.interfaceName; }
  }
  throw new Error('没有可用的物理网络');
 }
 private makeConfig(tunName: string): vpnExtension.VpnConfig {
  const routes: vpnExtension.RouteInfo[] = [];
  if(tunName.length>0) {
   routes.push({interface:tunName,destination:{address:{address:'0.0.0.0',family:1},prefixLength:0},gateway:{address:'0.0.0.0',family:1},hasGateway:false,isDefaultRoute:true});
   routes.push({interface:tunName,destination:{address:{address:'::',family:2},prefixLength:0},gateway:{address:'::',family:2},hasGateway:false,isDefaultRoute:true});
  }
  return {
   addresses:[{address:{address:'172.19.0.1',family:1},prefixLength:30},{address:{address:'fdfe:dcba:9876::1',family:2},prefixLength:126}],
   routes:routes,dnsAddresses:['172.19.0.2','fdfe:dcba:9876::2'],mtu:1280,
   isIPv4Accepted:true,isIPv6Accepted:true,isBlocking:false
  };
 }
 private async startVpn(): Promise<void> {
  try {
   this.publish('starting','检查配置与物理网络');
   const config: string = readPrivate(`${this.context.filesDir}/profile.json`);
   const check: CoreResponse = JSON.parse(await bridge.check(config)) as CoreResponse;
   if(!check.ok){throw new Error(check.message);}
   this.requireAlive();
   this.status.physicalInterface = await this.physicalNetwork();
   this.conn=vpnExtension.createVpnConnection(this.context);
   // Discover the real name through TUNGETIFF; no guessed interface name enters a route.
   let fd: number=await this.conn.create(this.makeConfig(''));
   this.requireAlive();
   this.status.tunName=bridge.tunName(fd);
   await this.conn.destroy();
   this.requireAlive();
   fd=await this.conn.create(this.makeConfig(this.status.tunName));
   if(bridge.tunName(fd)!==this.status.tunName){throw new Error('系统重新分配了 TUN 名称，已中止连接');}
   this.requireAlive();
   // API 22+. Never start the core when loop protection fails.
   await this.conn.protectProcessNet();
   this.requireAlive();
   const addresses: InterfaceAddress[] = JSON.parse(bridge.interfaces()) as InterfaceAddress[];
   this.status.ipv6AddressPresent=addresses.some((it: InterfaceAddress): boolean => it.name===this.status.tunName && it.family===6 && it.address==='fdfe:dcba:9876::1');
   if(!this.status.ipv6AddressPresent){throw new Error('系统未给 TUN 分配预期 IPv6 地址');}
   const result: CoreResponse=JSON.parse(await bridge.start(config,fd,this.context.filesDir,this.status.physicalInterface)) as CoreResponse;
   if(!result.ok){throw new Error(result.message);}
   this.requireAlive();
   this.publish('running','内核运行中；双栈地址已确认，IPv6 全流量仍需实测验收');
   this.networkTimer=setInterval(() => { this.inspectNetwork(); },3000);
  } catch(error) {
   await this.cleanup();
   if(this.destroyed){return;}
   const err=error as BusinessError;
   this.publish('error',err.message || 'VPN 启动失败');
   await this.stopSelf();
  }
 }
 private async inspectNetwork(): Promise<void> {
  if(this.checkingNetwork || this.destroyed){return;}
  this.checkingNetwork=true;
  try {
   const name: string=await this.physicalNetwork();
   if(name!==this.status.physicalInterface){
    await this.cleanup();
    this.publish('error','网络已切换，请重新连接 VPN');
    await this.stopSelf();
   } else { this.publish('running',this.status.message); }
  } catch(_error) {
   await this.cleanup();this.publish('error','物理网络不可用，请重新连接 VPN');await this.stopSelf();
  } finally {this.checkingNetwork=false;}
 }
 private async stopSelf(): Promise<void> {
  try {await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});} catch(_error) {}
 }
 private async cleanup(): Promise<void> {
  if(this.networkTimer!==-1){clearInterval(this.networkTimer);this.networkTimer=-1;}
  try {await bridge.stop();} catch(_error) {}
  if(this.conn){try {await this.conn.destroy();} catch(_error) {} this.conn=undefined;}
 }
}
