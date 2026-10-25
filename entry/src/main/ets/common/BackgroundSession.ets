import { abilityAccessCtrl, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { geoLocationManager } from '@kit.LocationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
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
 // Deliberately do not inspect, retain, serialize or log the Location object.
 private locationCallback=(_location: geoLocationManager.Location): void => {};
 private cancelCallback=(info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
  if(info.id!==this.taskId){return;}
  this.taskId=-1;this.blocked=true;this.stop(`后台任务已取消（${info.reason}），可重新连接或切换模式重试`);
 };
 private suspendCallback=(info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
  if(info.continuousTaskId===this.taskId){this.publish(`后台任务被系统挂起（${info.suspendReason}），驻留未获保障`);}
 };
 private activeCallback=(info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
  if(info.id===this.taskId){this.publish('后台任务已恢复，驻留效果仍需实测');}
 };
 initialize(context: common.UIAbilityContext): void {this.context=context;if(this.taskId<0){this.publish('后台保障未运行');}this.diagnostics();}
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
 async reconfigure(): Promise<void> {await this.stop();this.blocked=false;await this.resumeIfRunning();}
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
    // Interval in seconds; low-power approximate fixes suffice. No GPS accuracy
    // request, navigation scenario, coordinates in AppStorage, or persistence.
    if(this.mode==='location'){
     geoLocationManager.onLocationChange({priority:geoLocationManager.LocationRequestPriority.LOW_POWER,timeInterval:60,distanceInterval:0,maxAccuracy:0},this.locationCallback);
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
    this.publish(this.mode==='location'?'定位订阅与后台任务已申请，锁屏驻留效果待实测':'数据传输后台任务已申请，空闲时仍可能被系统挂起');
   } catch(error) {
    await this.release();
    const code: number=(error as BusinessError).code || 0;
    this.diagnostics(code);
    this.publish(`后台任务未启动（${code}），VPN 可继续使用`);
   }
  }).catch(() => {this.publish('后台保障操作未完成');});
  return this.queue;
 }
 private async inspect(): Promise<void> {
  if(this.checking || !this.context || this.taskId<0){return;}this.checking=true;
  const generation: number=this.generation;
  try {
   if(this.mode==='location' && (!this.permissionGranted() || !geoLocationManager.isLocationEnabled())){this.blocked=true;this.stop('定位权限或系统定位已关闭，辅助已停止');return;}
   let status: VpnStatus | undefined;
   try {status=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;} catch(_error) {}
   if(status && status.updatedAt>=this.startedAt && ['stopped','error','paused'].includes(status.phase)){this.stop('VPN 已停止或暂停，定位辅助已释放');return;}
   // Use the system VPN, rather than an aged JS heartbeat, to confirm presence.
   const exists: boolean=await this.hasVpn();
   if(generation!==this.generation){return;}
   if(exists){this.missingSince=0;}
   else {if(this.missingSince===0){this.missingSince=Date.now();}if(Date.now()-this.missingSince>=90000){this.stop('未发现系统 VPN，定位辅助已释放');}}
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
   // Owner updates require a template even when no completion percentage is
   // meaningful. Omit progressValue; present the measured bytes as text.
   const template: notificationManager.NotificationTemplate={name:'downloadTemplate',data:{title:'VPN 已连接',fileName:text}};
   await notificationManager.publish({id:this.notification.notificationId,notificationSlotType:notificationManager.SlotType.LIVE_VIEW,updateOnly:true,tapDismissed:false,template:template,content:{notificationContentType:notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,systemLiveView:{typeCode:8,title:'熊盒 VPN',text:`已连接 · ${text}`}}});
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
