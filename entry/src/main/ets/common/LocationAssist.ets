import { abilityAccessCtrl, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { geoLocationManager } from '@kit.LocationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { loadSettings } from './ProfileStore';
import { BUNDLE_NAME, readPrivate, VpnStatus } from './Store';

// Owned by EntryAbility's UI runtime. Never pass the VPN extension Context to
// startBackgroundRunning. This is an opt-in experiment, not a residency guarantee.
export class LocationAssist {
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
 // Deliberately do not inspect, retain, serialize or log the Location object.
 private locationCallback=(_location: geoLocationManager.Location): void => {};
 private cancelCallback=(info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
  if(info.id!==this.taskId){return;}
  this.taskId=-1;this.blocked=true;this.stop(`定位后台任务已取消（${info.reason}），可重新连接或切换开关重试`);
 };
 private suspendCallback=(info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
  if(info.continuousTaskId===this.taskId){this.publish(`定位后台任务被系统挂起（${info.suspendReason}），驻留未获保障`);}
 };
 private activeCallback=(info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
  if(info.id===this.taskId){this.publish('定位后台任务已恢复，驻留效果仍需实测');}
 };
 initialize(context: common.UIAbilityContext): void {this.context=context;this.publish('定位辅助驻留未运行');}
 private publish(message: string): void {AppStorage.setOrCreate('locationAssistStatus',message);}
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
  if(!this.context || this.blocked || !loadSettings(this.context.filesDir).locationAssist){return;}
  try {if(await this.hasVpn()){await this.start();}} catch(_error) {this.publish('未确认系统 VPN，定位辅助未启动');}
 }
 onBackground(): void {this.foreground=false;}
 async beginSession(): Promise<void> {this.blocked=false;await this.start();}
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
   if(!this.context || generation!==this.generation || this.blocked || this.taskId>=0 || !loadSettings(this.context.filesDir).locationAssist){return;}
   if(!this.foreground){this.publish('请在前台连接 VPN，以申请定位后台任务');return;}
   try {
    if(this.subscribed || this.observingCancel || this.observingSuspend || this.observingActive){await this.release();}
    if(!this.permissionGranted()){this.publish('模糊定位权限未授权，请重新开启开关');return;}
    if(!geoLocationManager.isLocationEnabled()){this.publish('系统定位已关闭，定位辅助未运行');return;}
    // Interval in seconds; low-power approximate fixes suffice. No GPS accuracy
    // request, navigation scenario, coordinates in AppStorage, or persistence.
    geoLocationManager.onLocationChange({priority:geoLocationManager.LocationRequestPriority.LOW_POWER,timeInterval:60,distanceInterval:0,maxAccuracy:0},this.locationCallback);
    this.subscribed=true;
    backgroundTaskManager.on('continuousTaskCancel',this.cancelCallback);
    this.observingCancel=true;
    backgroundTaskManager.on('continuousTaskSuspend',this.suspendCallback);
    this.observingSuspend=true;
    backgroundTaskManager.on('continuousTaskActive',this.activeCallback);
    this.observingActive=true;
    const agent=await wantAgent.getWantAgent({wants:[{bundleName:BUNDLE_NAME,abilityName:'EntryAbility'}],operationType:wantAgent.OperationType.START_ABILITY,requestCode:731, wantAgentFlags:[wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]});
    if(generation!==this.generation || !this.foreground){await this.release();return;}
    const task=await backgroundTaskManager.startBackgroundRunning(this.context,['location'],agent);
    this.taskId=task.continuousTaskId===undefined?-1:task.continuousTaskId;
    if(this.taskId<0){await backgroundTaskManager.stopBackgroundRunning(this.context);throw new Error('missing task ID');}
    // Disabling or disconnecting while the OS request is pending invalidates it.
    if(generation!==this.generation){await this.release();return;}
    this.startedAt=Date.now();this.missingSince=this.startedAt;
    this.timer=setInterval(() => {this.inspect();},5000);
    this.publish('定位订阅与后台任务已申请，锁屏驻留效果待实测');
   } catch(error) {
    await this.release();
    const code: number=(error as BusinessError).code || 0;
    this.publish(`定位辅助未启动（${code}），VPN 可继续使用`);
   }
  }).catch(() => {this.publish('定位辅助操作未完成');});
  return this.queue;
 }
 private async inspect(): Promise<void> {
  if(this.checking || !this.context || this.taskId<0){return;}this.checking=true;
  const generation: number=this.generation;
  try {
   if(!loadSettings(this.context.filesDir).locationAssist){this.stop();return;}
   if(!this.permissionGranted() || !geoLocationManager.isLocationEnabled()){this.blocked=true;this.stop('定位权限或系统定位已关闭，辅助已停止');return;}
   let status: VpnStatus | undefined;
   try {status=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;} catch(_error) {}
   if(status && status.updatedAt>=this.startedAt && ['stopped','error','paused'].includes(status.phase)){this.stop('VPN 已停止或暂停，定位辅助已释放');return;}
   // Use the system VPN, rather than an aged JS heartbeat, to confirm presence.
   const exists: boolean=await this.hasVpn();
   if(generation!==this.generation){return;}
   if(exists){this.missingSince=0;}
   else {if(this.missingSince===0){this.missingSince=Date.now();}if(Date.now()-this.missingSince>=90000){this.stop('未发现系统 VPN，定位辅助已释放');}}
  } catch(_error) {
   if(generation===this.generation){
    if(this.missingSince===0){this.missingSince=Date.now();}
    if(Date.now()-this.missingSince>=90000){this.stop('持续无法确认 VPN 状态，定位辅助已释放');}
    else {this.publish('暂未确认定位辅助状态，请回前台检查');}
   }
  }
  finally {this.checking=false;}
 }
 stop(message: string='定位辅助驻留未运行'): Promise<void> {
  this.generation++;
  this.queue=this.queue.then(async () => {await this.release();this.publish(message);}).catch(() => {this.publish('定位辅助清理未完成，请关闭应用后检查系统定位指示');});
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
  if(failed){throw new Error('Location assist cleanup incomplete');}
 }
}
export const locationAssist: LocationAssist=new LocationAssist();
