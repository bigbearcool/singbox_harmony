import { abilityAccessCtrl, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { geoLocationManager } from '@kit.LocationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { loadSettings } from './ProfileStore';
import { BUNDLE_NAME, readPrivate, writePrivate, VpnStatus } from './Store';

interface BackgroundDiagnostic {updatedAt: number; mode: string; taskId: number; notificationId: number; slotType: number; contentType: number; errorCode: number; notificationUpdatedAt: number;}

// Owned by EntryAbility's UI runtime. Never pass the VPN extension Context to
// startBackgroundRunning. This is an opt-in experiment, not a residency guarantee.
export class BackgroundSession {
 private context?: common.UIAbilityContext;
 private generation: number=0;
 private queue: Promise<void>=Promise.resolve();
 private taskId: number=-1;
 private subscribed: boolean=false;
 private observingCancel: boolean=false;
 private observingSuspend: boolean=false;
 private observingActive: boolean=false;
 private timer: number=-1;
 private checking: boolean=false;
 private blocked: boolean=false;
 private foreground: boolean=false;
 private startedAt: number=0;
 private missingSince: number=0;
 private mode: string='dataTransfer';
 private notification?: backgroundTaskManager.ContinuousTaskNotification;
 private lastNotificationAt: number=0;
 private lastTransferBytes: number=-1;
 private notificationUpdatedAt: number=0;
 private locationTicks: number=0;
 private onVpnMissing?: () => Promise<boolean>;
 private lastReviveAt: number=0;
 private reviveAttempts: number=0;
 private netConnection?: connection.NetConnection;
 // Deliberately do not inspect, retain, serialize or log the Location object.
 private locationCallback=(_location: geoLocationManager.Location): void => {
  this.locationTicks++;
  if(this.taskId>=0 && this.mode==='location'){
   this.publish(`定位辅助运行中（任务 #${this.taskId} · 保活回调 ${this.locationTicks} 次）`);
  }
 };
 private cancelCallback=(info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
  if(info.id!==this.taskId){return;}
  hilog.warn(0x1700,'SingboxHarmony','bgTask cancelled id=%{public}d reason=%{public}d',info.id,info.reason);
  this.taskId=-1;this.blocked=true;this.stop(`后台任务已取消（${info.reason}），可重新连接或切换模式重试`);
 };
 private suspendCallback=(info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
  if(info.continuousTaskId===this.taskId){
   hilog.warn(0x1700,'SingboxHarmony','bgTask suspended id=%{public}d reason=%{public}d',info.continuousTaskId,info.suspendReason);
   this.publish(`后台任务被系统挂起（${info.suspendReason}），驻留未获保障`);
  }
 };
 private activeCallback=(info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
  if(info.id===this.taskId){
   hilog.info(0x1700,'SingboxHarmony','bgTask active id=%{public}d',info.id);
   this.publish(this.mode==='location'?`定位辅助已恢复（任务 #${this.taskId} · 保活回调 ${this.locationTicks} 次）`:'后台任务已恢复，驻留效果仍需实测');
  }
 };
 initialize(context: common.UIAbilityContext): void {this.context=context;if(this.taskId<0){this.publish('后台保障未运行');}this.diagnostics();}
 setVpnMissingHandler(handler?: () => Promise<boolean>): void {this.onVpnMissing=handler;}
 private publish(message: string): void {AppStorage.setOrCreate('backgroundSessionStatus',message);}
 private diagnostics(errorCode: number=0): void {
  if(!this.context){return;}
  const status: BackgroundDiagnostic={updatedAt:Date.now(),mode:this.mode,taskId:this.taskId,notificationId:this.notification?.notificationId || 0,slotType:this.notification?.slotType || 0,contentType:this.notification?.contentType || 0,errorCode:errorCode,notificationUpdatedAt:this.notificationUpdatedAt};
  try {writePrivate(`${this.context.filesDir}/background-session-debug.json`,JSON.stringify(status));} catch(_error) {}
 }
 private permissionGranted(): boolean {
  if(!this.context){return false;}
  return abilityAccessCtrl.createAtManager().checkAccessTokenSync(this.context.applicationInfo.accessTokenId,'ohos.permission.APPROXIMATELY_LOCATION')===abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
 }
 async requestPermission(): Promise<boolean> {
  if(!this.context){return false;}
  try {
   if(!this.permissionGranted()){
    const response=await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context,['ohos.permission.APPROXIMATELY_LOCATION']);
    if(response.authResults.length!==1 || response.authResults[0]!==0){this.publish('未获得模糊定位权限，辅助驻留未启用');return false;}
   }
   this.blocked=false;return true;
  } catch(_error) {this.publish('未能申请定位权限，辅助驻留未启用');return false;}
 }
 async onForeground(): Promise<void> {
  this.foreground=true;
  await this.resumeIfRunning();
 }
 async resumeIfRunning(): Promise<void> {
  if(!this.context || this.blocked){return;}
  try {if(await this.hasVpn()){await this.start();}} catch(_error) {this.publish('未确认系统 VPN，定位辅助未启动');}
 }
 onBackground(): void {this.foreground=false;}
 async beginSession(): Promise<void> {this.blocked=false;await this.start();}
 async reconfigure(assumeForeground: boolean=false): Promise<void> {
  await this.stop();
  this.blocked=false;
  if(assumeForeground){this.foreground=true;}
  await this.resumeIfRunning();
  if(this.taskId<0 && this.context && loadSettings(this.context.filesDir).locationAssist && this.permissionGranted()){
   this.publish('定位辅助已就绪，连接 VPN 后自动启用');
  }
 }
 private async hasVpn(): Promise<boolean> {
  for(const net of await connection.getAllNets()){
   const caps=await connection.getNetCapabilities(net);
   if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
   const properties=await connection.getConnectionProperties(net);
   if(properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1') && properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='fdfe:dcba:9876::1')){return true;}
  }
  return false;
 }
 private start(): Promise<void> {
  const generation: number=this.generation;
  this.queue=this.queue.then(async () => {
   if(!this.context || generation!==this.generation || this.blocked || this.taskId>=0){return;}
   if(!this.foreground){this.publish('请在前台连接 VPN，以申请后台任务');return;}
   try {
    this.mode=loadSettings(this.context.filesDir).locationAssist?'location':'dataTransfer';
    if(this.subscribed || this.observingCancel || this.observingSuspend || this.observingActive){await this.release();}
    if(this.mode==='location' && !this.permissionGranted()){this.publish('模糊定位权限未授权，请重新开启开关');return;}
    if(this.mode==='location' && !geoLocationManager.isLocationEnabled()){this.publish('系统定位已关闭，定位辅助未运行');return;}
    // Interval in seconds; low-power approximate fixes keep MODE_LOCATION active
    // through standby without GPS accuracy or reading any coordinates.
    if(this.mode==='location'){
     this.locationTicks=0;
     geoLocationManager.onLocationChange({priority:geoLocationManager.LocationRequestPriority.LOW_POWER,timeInterval:15,distanceInterval:0,maxAccuracy:0},this.locationCallback);
     this.subscribed=true;
    }
    backgroundTaskManager.on('continuousTaskCancel',this.cancelCallback);
    this.observingCancel=true;
    backgroundTaskManager.on('continuousTaskSuspend',this.suspendCallback);
    this.observingSuspend=true;
    backgroundTaskManager.on('continuousTaskActive',this.activeCallback);
    this.observingActive=true;
    const agent=await wantAgent.getWantAgent({wants:[{bundleName:BUNDLE_NAME,abilityName:'EntryAbility'}],operationType:wantAgent.OperationType.START_ABILITY,requestCode:731, wantAgentFlags:[wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]});
    if(generation!==this.generation || !this.foreground){await this.release();return;}
    const request: backgroundTaskManager.ContinuousTaskRequest=new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes=[this.mode==='location'?backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION:backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
    request.backgroundTaskSubmodes=[this.mode==='location'?backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION:backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];request.wantAgent=agent;
    const task=await backgroundTaskManager.startBackgroundRunning(this.context,request);
    this.notification=task;this.lastNotificationAt=0;this.lastTransferBytes=-1;this.notificationUpdatedAt=0;
    this.taskId=task.continuousTaskId===undefined?-1:task.continuousTaskId;
    this.diagnostics();
    if(this.taskId<0){await backgroundTaskManager.stopBackgroundRunning(this.context);throw new Error('missing task ID');}
    // Disabling or disconnecting while the OS request is pending invalidates it.
    if(generation!==this.generation){await this.release();return;}
    this.startedAt=Date.now();this.missingSince=this.startedAt;
    this.timer=setInterval(() => {this.inspect();},5000);
    this.registerNetWatcher();
    hilog.info(0x1700,'SingboxHarmony','bgTask started mode=%{public}s taskId=%{public}d',this.mode,this.taskId);
    this.publish(this.mode==='location'?`定位辅助运行中（任务 #${this.taskId} · 等待首次保活回调）`:`数据传输后台任务运行中（任务 #${this.taskId}）`);
   } catch(error) {
    await this.release();
    const code: number=(error as BusinessError).code || 0;
    hilog.warn(0x1700,'SingboxHarmony','bgTask start failed mode=%{public}s code=%{public}d',this.mode,code);
    this.diagnostics(code);
    this.publish(`后台任务未启动（${code}），VPN 可继续使用`);
   }
  }).catch(() => {this.publish('后台保障操作未完成');});
  return this.queue;
 }
 private registerNetWatcher(): void {
  if(this.netConnection){return;}
  try {
   if(typeof connection.createNetConnection!=='function'){return;}
   const netCon: connection.NetConnection=connection.createNetConnection();
   this.netConnection=netCon;
   netCon.on('netAvailable',(): void => {this.inspect(true);});
   netCon.on('netLost',(): void => {this.inspect(true);});
   netCon.register((_err: BusinessError): void => {});
  } catch(_error) {this.netConnection=undefined;}
 }
 private unregisterNetWatcher(): void {
  if(!this.netConnection){return;}
  const netCon: connection.NetConnection=this.netConnection;
  this.netConnection=undefined;
  try {netCon.unregister((_err: BusinessError): void => {});} catch(_error) {}
 }
 private async hasWifiPhysicalNet(): Promise<boolean> {
  try {
   for(const net of await connection.getAllNets()){
    const caps=await connection.getNetCapabilities(net);
    if(caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)){return true;}
   }
  } catch(_error) {}
  return false;
 }
 private async inspect(fromNetworkEvent: boolean=false): Promise<void> {
  if(this.checking || !this.context || this.taskId<0){return;}this.checking=true;
  const generation: number=this.generation;
  try {
   if(this.mode==='location' && (!this.permissionGranted() || !geoLocationManager.isLocationEnabled())){this.blocked=true;this.stop('定位权限或系统定位已关闭，辅助已停止');return;}
   let status: VpnStatus | undefined;
   try {status=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;} catch(_error) {}
   if(status && status.updatedAt>=this.startedAt && ['stopped','error'].includes(status.phase)){this.stop('VPN 已停止，后台保障已释放');return;}
   // Use the system VPN, rather than an aged JS heartbeat, to confirm presence.
   const exists: boolean=await this.hasVpn();
   if(generation!==this.generation){return;}
   if(exists){this.missingSince=0;this.reviveAttempts=0;}
   else if(status && status.phase==='paused' && await this.hasWifiPhysicalNet()){
    // Stay resident while paused on a bypass Wi-Fi so we can revive VPN when leaving Wi-Fi.
    this.missingSince=0;
    this.reviveAttempts=0;
   }
   else {
    if(this.missingSince===0){this.missingSince=Date.now();}
    const delayMs: number=fromNetworkEvent && status && status.phase==='paused'?0:(status && status.phase==='paused'?3000:10000);
    if(this.onVpnMissing && Date.now()-this.missingSince>=delayMs && Date.now()-this.lastReviveAt>=30000 && this.reviveAttempts<5){
     this.lastReviveAt=Date.now();this.reviveAttempts++;
     hilog.warn(0x1700,'SingboxHarmony','bgTask watchdog attempting vpn revive attempt=%{public}d fromPhase=%{public}s netEvent=%{public}s',this.reviveAttempts,status?.phase || 'unknown',String(fromNetworkEvent));
     try {
      const revived: boolean=await this.onVpnMissing();
      if(revived && generation===this.generation){
       this.missingSince=Date.now();
       hilog.info(0x1700,'SingboxHarmony','bgTask watchdog revive triggered');
       return;
      }
     } catch(_err) {}
    }
    if(Date.now()-this.missingSince>=90000){this.stop('未发现系统 VPN，定位辅助已释放');}
   }
   if(exists && status && status.phase==='running' && this.mode==='dataTransfer'){await this.updateTransferNotification(status,generation);}
  } catch(_error) {
   if(generation===this.generation){
    if(this.missingSince===0){this.missingSince=Date.now();}
    if(Date.now()-this.missingSince>=90000){this.stop('持续无法确认 VPN 状态，定位辅助已释放');}
    else {this.publish('暂未确认定位辅助状态，请回前台检查');}
   }
  }
  finally {this.checking=false;}
 }
 private async updateTransferNotification(status: VpnStatus,generation: number): Promise<void> {
  if(!this.notification || generation!==this.generation || this.taskId<0){return;}
  const up: number=Number.isFinite(status.uplink)?Math.max(0,status.uplink || 0):0;
  const down: number=Number.isFinite(status.downlink)?Math.max(0,status.downlink || 0):0;
  const transferred: number=up+down;
  if(transferred===this.lastTransferBytes || Date.now()-this.lastNotificationAt<30000){return;}
  this.lastNotificationAt=Date.now();
  try {
   // The system creates this live-view ID. Publish actual byte counts only;
   // an indefinite tunnel has no honest total size or completion percentage.
   // Publish with the documented public enums, rather than copying the native
   // task metadata (HarmonyOS 7 returned contentType 8 on this device).
   const text: string=`上行 ${Math.round(up/1024)} KB · 下行 ${Math.round(down/1024)} KB`;
   const networkType: string=typeof status.networkType==='string'?status.networkType.trim():'';
   const liveText: string=networkType?`已连接 · ${networkType} · ${text}`:`已连接 · ${text}`;
   // Owner updates require a template even when no completion percentage is
   // meaningful. Omit progressValue; present the measured bytes as text.
   const template: notificationManager.NotificationTemplate={name:'downloadTemplate',data:{title:networkType?`VPN 已连接 · ${networkType}`:'VPN 已连接',fileName:text}};
   await notificationManager.publish({id:this.notification.notificationId,notificationSlotType:notificationManager.SlotType.LIVE_VIEW,updateOnly:true,tapDismissed:false,template:template,content:{notificationContentType:notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,systemLiveView:{typeCode:8,title:'熊盒 VPN',text:liveText}}});
   if(generation===this.generation){this.lastTransferBytes=transferred;this.notificationUpdatedAt=Date.now();this.diagnostics();}
  } catch(error) {if(generation===this.generation){const code: number=(error as BusinessError).code || 0;this.diagnostics(code);this.publish(`数据传输通知更新未完成（${code}），后台保障待系统确认`);}}
 }
 stop(message: string='后台保障未运行'): Promise<void> {
  this.generation++;
  this.queue=this.queue.then(async () => {await this.release();this.publish(message);}).catch(() => {this.publish('后台任务清理未完成，请关闭应用后检查系统指示');});
  return this.queue;
 }
 private async release(): Promise<void> {
  if(this.timer!==-1){clearInterval(this.timer);this.timer=-1;}
  this.unregisterNetWatcher();
  let failed: boolean=false;
  if(this.subscribed){try {geoLocationManager.offLocationChange(this.locationCallback);this.subscribed=false;}catch(_error){failed=true;}}
  // off is scoped to our callbacks; never remove another consumer's listeners.
  if(this.observingCancel){try {backgroundTaskManager.off('continuousTaskCancel',this.cancelCallback);this.observingCancel=false;}catch(_error){failed=true;}}
  if(this.observingSuspend){try {backgroundTaskManager.off('continuousTaskSuspend',this.suspendCallback);this.observingSuspend=false;}catch(_error){failed=true;}}
  if(this.observingActive){try {backgroundTaskManager.off('continuousTaskActive',this.activeCallback);this.observingActive=false;}catch(_error){failed=true;}}
  if(this.context && this.taskId>=0){try {const id: number=this.taskId;await backgroundTaskManager.stopBackgroundRunning(this.context,id);this.taskId=-1;}catch(_error){failed=true;}}
  if(this.taskId<0){this.notification=undefined;}
  if(failed){throw new Error('Location assist cleanup incomplete');}
 }
}
export const backgroundSession: BackgroundSession=new BackgroundSession();
