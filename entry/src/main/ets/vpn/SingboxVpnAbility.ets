import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import bridge from 'libsingboxbridge.so';
import { wifiManager } from '@kit.ConnectivityKit';
import { loadSettings } from '../common/ProfileStore';
import { ControlRequest, ControlReply, ControlResult } from '../common/Control';
import { BUNDLE_NAME, VPN_ABILITY, readPrivate, writePrivate, initialStatus, VpnStatus, InterfaceAddress, CoreResponse, CoreStats } from '../common/Store';

export default class SingboxVpnAbility extends VpnExtensionAbility {
 private conn?: vpnExtension.VpnConnection;
 private destroyed: boolean = false;
 private status: VpnStatus = initialStatus();
 private task: Promise<void> = Promise.resolve();
 private networkTimer: number = -1;
 private checkingNetwork: boolean = false;
 private physicalNetId: number = 0;
 private lastControlId: string = '';
 private lastSnapshotAt: number = 0;
 private bypassCurrentWifi: boolean = false;

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
  hilog.info(0x1700,'SingboxHarmony','phase=%{public}s tun=%{public}s ipv6Address=%{public}s physical=%{public}s network=%{public}s physicalIPv6=%{public}s',phase,this.status.tunName,String(this.status.ipv6AddressPresent),this.status.physicalInterface,this.status.networkType || '',String(this.status.physicalIPv6Available || false));
  if(phase==='running'){hilog.info(0x1700,'SingboxHarmony','traffic up=%{public}d down=%{public}d v4=%{public}d v6=%{public}d',this.status.uplink || 0,this.status.downlink || 0,this.status.ipv4Flows || 0,this.status.ipv6Flows || 0);}
  if(phase==='running'){hilog.info(0x1700,'SingboxHarmony','socketBind ok=%{public}d fail=%{public}d error=%{public}s',this.status.bindSuccess || 0,this.status.bindFailure || 0,this.status.lastBindError || '');}
  if(this.status.dnsError){hilog.warn(0x1700,'SingboxHarmony','dnsStatus=%{public}s',this.status.dnsError);}
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
   if(props.interfaceName.length>0) {
    this.bypassCurrentWifi=false;
    const settings=loadSettings(this.context.filesDir);
    if(settings.onDemand && settings.bypassWifi.length>0 && caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)){
     try {const wifi: wifiManager.WifiLinkedInfo=await wifiManager.getLinkedInfo();this.bypassCurrentWifi=settings.bypassWifi.includes(wifi.ssid);} catch(_error) {}
    }
    this.physicalNetId=handle.netId;
    this.status.networkType=caps.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)?'蜂窝网络':caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)?'Wi-Fi':'其他网络';
    this.status.physicalIPv6Available=props.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.family===2 && !it.address.address.startsWith('fe80:'));
    return props.interfaceName;
   }
  }
  throw new Error('没有可用的物理网络');
 }
 private makeConfig(): vpnExtension.VpnConfig {
  return {
   addresses:[{address:{address:'172.19.0.1',family:1},prefixLength:30},{address:{address:'fdfe:dcba:9876::1',family:2},prefixLength:126}],
   // Empty interface requests system GetInterfaceName(). An empty gateway is
   // essential: the route service passes this string even if hasGateway=false.
   routes:[
    {interface:'',destination:{address:{address:'0.0.0.0',family:1},prefixLength:0},gateway:{address:'',family:1},hasGateway:false,isDefaultRoute:true},
    {interface:'',destination:{address:{address:'::',family:2},prefixLength:0},gateway:{address:'',family:2},hasGateway:false,isDefaultRoute:true}
   ],dnsAddresses:['172.19.0.2','fdfe:dcba:9876::2'],mtu:1280,
   isIPv4Accepted:true,isIPv6Accepted:true,isBlocking:false
  };
 }
 private async confirmRoutes(): Promise<void> {
  for(let attempt: number=0;attempt<20;attempt++){
   for(const net of await connection.getAllNets()){
    const caps: connection.NetCapabilities=await connection.getNetCapabilities(net);
    if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
    const props: connection.ConnectionProperties=await connection.getConnectionProperties(net);
    if(props.interfaceName!==this.status.tunName){continue;}
    const ipv4: boolean=props.routes.some((r: connection.RouteInfo): boolean => r.destination.address.address==='0.0.0.0' && r.destination.prefixLength===0);
    const ipv6: boolean=props.routes.some((r: connection.RouteInfo): boolean => r.destination.address.address==='::' && r.destination.prefixLength===0);
    if(ipv4 && ipv6){return;}
   }
   this.requireAlive();
   await new Promise<void>((resolve) => {setTimeout(resolve,100);});
  }
  throw new Error('系统尚未建立 IPv4/IPv6 两条默认路由，已中止连接');
 }
 private async startVpn(): Promise<void> {
  let retryable: boolean=false;
  let startupHint: string='';
  if(this.networkTimer!==-1){clearInterval(this.networkTimer);this.networkTimer=-1;}
  try {
   this.status.uplink=0;this.status.downlink=0;this.status.bindSuccess=0;this.status.bindFailure=0;this.status.dnsError='';
   this.publish('starting','检查配置与物理网络');
   const config: string = readPrivate(`${this.context.filesDir}/profile.json`);
   const check: CoreResponse = JSON.parse(await bridge.check(config)) as CoreResponse;
   if(!check.ok){throw new Error(check.message);}
   retryable=true;
   this.requireAlive();
   this.status.physicalInterface = await this.physicalNetwork();
   this.requireAlive();
   if(this.bypassCurrentWifi){this.publish('paused','已进入指定 Wi-Fi，VPN 已暂停；离开后恢复');this.networkTimer=setInterval(() => {this.inspectNetwork();},3000);return;}
   this.conn=vpnExtension.createVpnConnection(this.context);
   const fd: number=await this.conn.create(this.makeConfig());
   this.requireAlive();
   this.status.tunName=bridge.tunName(fd);
   await this.confirmRoutes();
   this.requireAlive();
   // API 22+. Never start the core when loop protection fails.
   await this.conn.protectProcessNet();
   this.requireAlive();
   const addresses: InterfaceAddress[] = JSON.parse(bridge.interfaces()) as InterfaceAddress[];
   this.status.ipv6AddressPresent=addresses.some((it: InterfaceAddress): boolean => it.name===this.status.tunName && it.family===6 && it.address==='fdfe:dcba:9876::1');
   if(!this.status.ipv6AddressPresent){throw new Error('系统未给 TUN 分配预期 IPv6 地址');}
   const result: CoreResponse=JSON.parse(await bridge.start(config,fd,this.context.filesDir,this.status.physicalInterface,this.status.tunName,this.physicalNetId)) as CoreResponse;
   if(!result.ok){if(result.errorCode?.startsWith('wg-')){startupHint=result.message;}throw new Error('内核启动未完成');}
   writePrivate(`${this.context.filesDir}/running-profile.json`,config);
   this.requireAlive();
   this.publish('running','内核运行中；IPv4 / IPv6 默认路由已确认');
   this.networkTimer=setInterval(() => { this.inspectNetwork(); },1000);
  } catch(error) {
   await this.cleanup();
   if(this.destroyed){return;}
   if(retryable && loadSettings(this.context.filesDir).autoReconnect){
    this.publish('reconnecting',startupHint?`${startupHint}，正在重试`:'连接暂不可用，正在等待网络恢复');
    this.networkTimer=setInterval(() => {this.inspectNetwork();},3000);
   } else {this.publish('error','VPN 启动失败，请检查配置和当前网络');await this.stopSelf();}
  }
 }
 private async inspectNetwork(): Promise<void> {
  if(this.checkingNetwork || this.destroyed){return;}
  this.checkingNetwork=true;
  try {
   if(this.status.phase==='reconnecting'){await this.startVpn();return;}
   if(this.status.phase==='paused'){
    await this.physicalNetwork();if(this.destroyed){return;}
    if(this.bypassCurrentWifi){this.publish('paused',this.status.message);} else {await this.startVpn();}
    return;
   }
   if(await this.processControl()){return;}
   const previousNetId: number=this.physicalNetId;
   const name: string=await this.physicalNetwork();
   if(this.destroyed){return;}
   if(this.bypassCurrentWifi){await this.cleanup();if(this.destroyed){return;}this.publish('paused','已进入指定 Wi-Fi，VPN 已暂停；离开后恢复');this.networkTimer=setInterval(() => {this.inspectNetwork();},3000);return;}
   if(name!==this.status.physicalInterface || previousNetId!==this.physicalNetId){
    await this.cleanup();
    if(this.destroyed){return;}
    await this.recoverNetwork('网络已切换');
   } else {
    const stats: CoreStats=JSON.parse(await bridge.stats()) as CoreStats;
    if(this.destroyed){return;}
    this.status.uplink=stats.uplink;this.status.downlink=stats.downlink;this.status.ipv4Flows=stats.ipv4Flows;this.status.ipv6Flows=stats.ipv6Flows;
    this.status.bindSuccess=stats.bindSuccess;this.status.bindFailure=stats.bindFailure;this.status.lastBindError=stats.lastBindError;
    this.status.dnsError=stats.dnsError;
    this.publish('running',this.status.message);
    await this.snapshotDashboard();
   }
  } catch(_error) {
   if(this.destroyed){return;}
   await this.cleanup();
   if(this.destroyed){return;}
   await this.recoverNetwork('物理网络不可用');
  } finally {this.checkingNetwork=false;}
 }
 private async recoverNetwork(message: string): Promise<void> {
  if(loadSettings(this.context.filesDir).autoReconnect){
   this.publish('reconnecting',`${message}，正在重新连接`);
   this.networkTimer=setInterval(() => {this.inspectNetwork();},3000);
  } else {this.publish('error',`${message}，请重新连接 VPN`);await this.stopSelf();}
 }
 private async processControl(): Promise<boolean> {
  let request: ControlRequest;
  try {request=JSON.parse(readPrivate(`${this.context.filesDir}/control-request.json`)) as ControlRequest;} catch(_error) {return false;}
  if(!request.id || request.id===this.lastControlId){return false;}
  this.lastControlId=request.id;
  if(Date.now()-request.createdAt>6000 || request.createdAt>Date.now()+1000){return false;}
  let reply: ControlReply;
  if(request.action==='reconnect'){
   await this.cleanup();if(this.destroyed){return true;}
   await this.startVpn();
   reply={ok:this.status.phase==='running',message:this.status.phase==='running'?'已重新连接':'正在等待网络恢复'};
  } else {
   const nativeRequest: NativeControlRequest={action:request.action,group:request.group || '',outbound:request.outbound || '',id:request.connectionId || '',mode:request.mode || ''};
   reply=JSON.parse(await bridge.control(JSON.stringify(nativeRequest))) as ControlReply;
  }
  if(this.destroyed){return true;}
  const result: ControlResult={id:request.id,ok:reply.ok,message:reply.message};
  writePrivate(`${this.context.filesDir}/control-result.json`,JSON.stringify(result));
  this.lastSnapshotAt=0;
  return request.action==='reconnect';
 }
 private async snapshotDashboard(): Promise<void> {
  if(Date.now()-this.lastSnapshotAt<2000){return;}
  try {
   const demand: DashboardDemand=JSON.parse(readPrivate(`${this.context.filesDir}/dashboard-demand.json`)) as DashboardDemand;
   if(Date.now()-demand.updatedAt>10000){return;}
  } catch(_error) {return;}
  const reply: ControlReply=JSON.parse(await bridge.control('{"action":"snapshot"}')) as ControlReply;
  if(this.destroyed){return;}
  if(reply.ok && reply.data){writePrivate(`${this.context.filesDir}/dashboard.json`,JSON.stringify(reply.data));}
  this.lastSnapshotAt=Date.now();
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

interface NativeControlRequest {action: string; group: string; outbound: string; id: string; mode: string;}
interface DashboardDemand {updatedAt: number;}
