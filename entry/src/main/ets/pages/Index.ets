import { common } from '@kit.AbilityKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { RemoteProfileDraft, profileImportLink, parseProfileImportLink } from '../common/ProfileLinks';
import { runNetworkProbes } from '../common/NetworkProbe';
import { backgroundSession } from '../common/BackgroundSession';
import { pushFormStatus } from '../common/FormSync';
import { ScheduleStatus, readScheduleStatus, syncSubscriptionSchedule } from '../common/SubscriptionSchedule';
import { UpdateReport, readUpdateReport, runDueProfileUpdates } from '../common/SubscriptionUpdates';
import { vpnStatusExpired, assessExpiredVpnStatus } from '../common/VpnHealth';
import { VpnScope, AppPresetCategory, AppPresetItem, APP_SCOPE_PRESETS, toggleScopePackage, defaultVpnScope, loadVpnScope, saveVpnScope } from '../common/VpnScope';
import { usableSsid, SsidPolicyRule, parseWifiNames, parseSsidPolicyLines, formatSsidPolicyLines } from '../common/WifiConditions';
import { DesiredVpnState, DesiredVpnMode, defaultDesiredState, loadDesiredState, saveDesiredState } from '../common/AlwaysOn';
import { HostOverride, LocalOverrides, defaultLocalOverrides, loadLocalOverrides, saveLocalOverrides, parseDomainList, parseCidrList, parseHostLines, formatHostLines } from '../common/LocalOverrides';
import { validShortcutAction, runShortcutAction } from '../common/ShortcutActions';
import { BRAND, BEAR_THEME } from '../common/BrandTheme';
import bridge from 'libsingboxbridge.so';
import { BUNDLE_NAME, VPN_ABILITY, DIRECT_PROFILE, VpnStatus, CoreResponse, initialStatus, writePrivate, readPrivate } from '../common/Store';
import { SavedProfile, ProfileLibrary, AppSettings, ProfileFetchCancellation, FetchedProfile, defaultSettings, loadSettings, saveSettings, loadLibrary, setAutoUpdate, addProfile, readProfile, selectProfile, removeProfile, editProfile, renameProfile, fetchProfileWithMeta, refreshProfile } from '../common/ProfileStore';
import { OutboundGroup, GroupItem, ConnectionInfo, DashboardData, WireGuardInfo, WireGuardPeer, HostDiagnosis, DeepProbeResult, TunnelView, emptyDashboard, readDashboard, sendControl, diagnoseHost, runDeepProbe, convertProfileText } from '../common/Control';
import { TrafficSparkline } from '../components/TrafficSparkline';

function bytesLabel(value: number): string {
 if(value>=1073741824){return `${(value/1073741824).toFixed(2)} GB`;}
 if(value>=1048576){return `${(value/1048576).toFixed(1)} MB`;}
 return `${(value/1024).toFixed(1)} KB`;
}
function durationLabel(ms: number): string {
 if(ms<=0){return '0ms';}
 if(ms<1000){return `${Math.round(ms)}ms`;}
 if(ms<60000){return `${(ms/1000).toFixed(1)}s`;}
 const mins: number=Math.floor(ms/60000);
 const secs: number=Math.floor((ms%60000)/1000);
 return `${mins}m${secs}s`;
}
function emptyDiagnosis(): HostDiagnosis {
 return {host:'',ipv4:[],ipv6:[],latencyMs:0,summary:''};
}
function emptyDeepProbe(): DeepProbeResult {
 return {natType:'unknown',summary:''};
}
function chunkPairs(items: GroupItem[]): GroupItem[][] {
 const rows: GroupItem[][]=[];
 for(let i: number=0;i<items.length;i+=2){
  if(i+1<items.length){rows.push([items[i],items[i+1]]);}
  else {rows.push([items[i]]);}
 }
 return rows;
}

@Entry
@Component
struct Index {
 @State private status: VpnStatus=initialStatus();
 @State private library: ProfileLibrary={selected:'',profiles:[]};
 @State private settings: AppSettings=defaultSettings();
 @State private dashboard: DashboardData=emptyDashboard();
 @State private coreVersion: string='正在检查内核…';
 @State private message: string='';
 @State private busy: boolean=false;
 @State private controlBusy: boolean=false;
 @State private probing: boolean=false;
 @State private probeResult: string='';
 @State private deepProbing: boolean=false;
 @State private hasDeepProbe: boolean=false;
 @State private deepProbeResult: DeepProbeResult=emptyDeepProbe();
 @State private refreshingPolicy: boolean=false;
 @State private renamingProfileId: string='';
 @State private renameDraft: string='';
 // 4-tab IA: 0=总览, 1=策略, 2=活动, 3=管理
 @State private activeTab: number=0;
 @State private activitySubTab: string='recent';
 @State private manageSubTab: string='profiles';
 @State private importDrawerOpen: boolean=false;
 @State private diagnoseDrawerOpen: boolean=false;
 @State private ssidPolicyExpanded: boolean=false;
 @State private wifiPauseExpanded: boolean=false;
 @State private collapsedGroups: string[]=[];
 @State private nodeFilter: string='';
 @State private editorVisible: boolean=false;
 @State private editorName: string='';
 @State private editorContent: string='';
 @State private editingId: string='';
 @State private remoteURL: string='';
 @State private connectionFilter: string='';
 @State private logFilter: string='';
 @State private expandedConnection: string='';
 @State private uploadRate: number=0;
 @State private downloadRate: number=0;
 @State private upHistory: number[]=[];
 @State private downHistory: number[]=[];
 @State private wifiRulesText: string='';
 @State private ssidPoliciesText: string='';
 @State private desiredState: DesiredVpnState=defaultDesiredState();
 @State private sortNodesByDelay: boolean=false;
 @State private diagnoseInput: string='';
 @State private diagnosing: boolean=false;
 @State private hasDiagnosis: boolean=false;
 @State private diagnosisResult: HostDiagnosis=emptyDiagnosis();
 @State private diagnosisError: string='';
 @State private localOverrides: LocalOverrides=defaultLocalOverrides();
 @State private overrideDirectText: string='';
 @State private overrideProxyText: string='';
 @State private overrideRejectText: string='';
 @State private overrideDirectCidrText: string='';
 @State private overrideProxyCidrText: string='';
 @State private overrideRejectCidrText: string='';
 @State private overrideHostsText: string='';
 @State private overridesExpanded: boolean=false;
 @State private overrideRuleType: string='domain';
 @State private overrideAction: string='direct';
 @State private overrideTargetInput: string='';
 @State private overrideHostDomainInput: string='';
 @State private overrideHostIpInput: string='';
 @State private overrideBatchExpanded: boolean=false;
 @State private ssidInput: string='';
 @State private ssidAction: string='mode';
 @State private ssidModeInput: string='direct';
 @State private ssidGroupInput: string='';
 @State private ssidOutboundInput: string='';
 @State private ssidBatchExpanded: boolean=false;
 @State private sharedCode: string='';
 @StorageLink('pendingRemoteProfile') @Watch('consumePendingLink') private pendingRemoteProfile: string='';
 @StorageLink('pendingShortcut') @Watch('consumeShortcut') private pendingShortcut: string='';
 private shortcutHandling: boolean=false;
 @StorageLink('windowSafeTop') private windowSafeTop: number=0;
 @StorageLink('windowSafeBottom') private windowSafeBottom: number=0;
 @StorageLink('windowSafeLeft') private windowSafeLeft: number=0;
 @StorageLink('windowSafeRight') private windowSafeRight: number=0;
 @StorageLink('windowIsWide') private windowIsWide: boolean=false;
 @StorageLink('windowLayoutReady') private windowLayoutReady: boolean=false;
 @StorageLink('backgroundSessionStatus') private backgroundSessionStatus: string='后台保障未运行';
 @State private locationChanging: boolean=false;
 @StorageLink('appForeground') @Watch('updateForeground') private appForeground: boolean=false;
 @StorageLink('diagnosticsPauseForegroundUpdates') private diagnosticsPauseForegroundUpdates: boolean=false;
 @State private scheduleStatus: ScheduleStatus={updatedAt:0,registered:false,intervalHours:0,message:'正在核对后台更新'};
 @State private updateReport: UpdateReport={updatedAt:0,source:'',phase:'idle',updated:0,failed:0,skipped:0,attempts:[]};
 private pageVisible: boolean=false;
 private automaticUpdate?: ProfileFetchCancellation;
 private lastDemandWrite: number=0;
 private lastLibraryRead: number=0;
 private healthChecking: boolean=false;
 private lastHealthCheck: number=0;
 private lastVerifiedExpiredAt: number=0;
 private lastVerifiedExists: boolean | undefined=undefined;
 private lastAutoRecoverAt: number=0;
 private foregroundSince: number=0;
 private lastPingWrite: number=0;
 @State private applicationScope: VpnScope=defaultVpnScope();
 @State private applicationScopeText: string='';
 @State private applicationScopeExpanded: boolean=false;
 private allowAutomaticConnect: boolean=true;
 private waitingSince: number=0;
 private probeGeneration: number=0;
 private lastAutoUpdate: number=0;
 private lastTrafficTime: number=0;
 private lastUpload: number=0;
 private lastDownload: number=0;
 private lastFormMode: string='';
 private lastFormPushAt: number=0;
 private observer?: vpnExtension.VpnObserver;
 private timer: number=-1;
 private toastTimer: number=-1;
 private context: common.UIAbilityContext=this.getUIContext().getHostContext() as common.UIAbilityContext;

 private showToast(text: string): void {
  this.message=text;
  if(this.toastTimer!==-1){clearTimeout(this.toastTimer);this.toastTimer=-1;}
  if(text){
   this.toastTimer=setTimeout(() => {this.message='';this.toastTimer=-1;},4000);
  }
 }

 aboutToAppear(): void {
  this.pageVisible=true;
  backgroundSession.initialize(this.context);
  backgroundSession.setVpnMissingHandler(async (): Promise<boolean> => {
   const desired: DesiredVpnState=loadDesiredState(this.context.filesDir);
   const cfg: AppSettings=loadSettings(this.context.filesDir);
   if(desired.desired!=='connected' || !cfg.autoReconnect || !this.library.selected){return false;}
   try {
    await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
    return true;
   } catch(_err) {return false;}
  });
  this.scheduleStatus=readScheduleStatus(this.context.filesDir);
  this.settings=loadSettings(this.context.filesDir);
  try {this.applicationScope=loadVpnScope(this.context.filesDir);this.applicationScopeText=this.applicationScope.applications.join('\n');} catch(_error) {this.showToast('应用范围设置无法读取，请重新保存');}
  this.wifiRulesText=this.settings.bypassWifi.join('\n');
  this.ssidPoliciesText=formatSsidPolicyLines(this.settings.ssidPolicies);
  this.desiredState=loadDesiredState(this.context.filesDir);
  this.localOverrides=loadLocalOverrides(this.context.filesDir);
  this.syncOverrideTexts(this.localOverrides);
  this.allowAutomaticConnect=!this.pendingShortcut;
  this.consumePendingLink();
  try {this.library=loadLibrary(this.context.filesDir);} catch(_error) {this.showToast('配置索引读取失败，原文件已保留');}
  this.dashboard=readDashboard(this.context.filesDir);
  try {
   this.observer=vpnExtension.createVpnObserver();
   this.observer.onAuthorizationResult((allowed: boolean) => {
    if(!allowed){
     this.waitingSince=0;
     this.status=initialStatus();
     this.persistDesiredState('stopped');
     this.showToast('系统 VPN 授权被拒绝，请重新授权后再连接');
     backgroundSession.stop('VPN 授权被取消，定位辅助已释放');
    }
   });
  } catch(_error) {}
  bridge.version().then((value: string) => {this.coreVersion=value;}).catch(() => {this.coreVersion='内核加载失败';});
  this.readStatus();
  this.updateForeground();this.syncUpdates();
  this.reconcileInitialStatus();
 }
 aboutToDisappear(): void {
  this.pageVisible=false;
  backgroundSession.setVpnMissingHandler(undefined);
  backgroundSession.stop();
  if(this.timer!==-1){clearInterval(this.timer);this.timer=-1;}
  if(this.toastTimer!==-1){clearTimeout(this.toastTimer);this.toastTimer=-1;}
  this.probeGeneration++;
  this.allowAutomaticConnect=false;
  this.automaticUpdate?.cancel();
  try {this.observer?.offAuthorizationResult();} catch(_error) {}
 }
 private readStatus(): void {
  if(!this.appForeground || !this.pageVisible){return;}
  this.consumeShortcut();
  if(Date.now()-this.lastDemandWrite>=3000){try {writePrivate(`${this.context.filesDir}/ui-demand.json`,JSON.stringify({updatedAt:Date.now()}));this.lastDemandWrite=Date.now();} catch(_error) {}}
  if(Date.now()-this.lastLibraryRead>=5000){this.lastLibraryRead=Date.now();try {this.library=loadLibrary(this.context.filesDir);} catch(_error) {}this.updateReport=readUpdateReport(this.context.filesDir);}
  try {
   const latest: VpnStatus=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;
   if(vpnStatusExpired(latest)){
    // Actively wake the VPN extension via UDS (fallback to file IPC) before declaring it stale.
    try {writePrivate(`${this.context.filesDir}/ui-demand.json`,JSON.stringify({updatedAt:Date.now()}));this.lastDemandWrite=Date.now();} catch(_error) {}
    if(Date.now()-this.lastPingWrite>=2500){
     this.lastPingWrite=Date.now();
     const pingPayload: string=JSON.stringify({id:util.generateRandomUUID(),createdAt:Date.now(),action:'ping'});
     try {
      bridge.udsRequest(`${this.context.filesDir}/control.sock`,pingPayload,1200).catch(() => {
       try {writePrivate(`${this.context.filesDir}/control-request.json`,pingPayload);} catch(_e) {}
      });
     } catch(_error) {
      try {writePrivate(`${this.context.filesDir}/control-request.json`,pingPayload);} catch(_e) {}
     }
    }
    if(Date.now()-this.foregroundSince<4000){
     if(this.status.phase==='stopped'){this.status=latest;}
     return;
    }
    const knownPresent: boolean | undefined=this.lastVerifiedExpiredAt===latest.updatedAt?this.lastVerifiedExists:undefined;
    this.status=assessExpiredVpnStatus(latest,knownPresent);
    if(!this.healthChecking && Date.now()-this.lastHealthCheck>=5000){this.verifyExpiredStatus(latest);}
    return;
   }
   this.lastVerifiedExpiredAt=0;this.lastVerifiedExists=undefined;
   if(latest.updatedAt>=this.waitingSince){
    if(latest.updatedAt>this.lastTrafficTime){
     const seconds: number=(latest.updatedAt-this.lastTrafficTime)/1000;
     this.uploadRate=this.lastTrafficTime>0?Math.max(0,((latest.uplink || 0)-this.lastUpload)/seconds):0;
     this.downloadRate=this.lastTrafficTime>0?Math.max(0,((latest.downlink || 0)-this.lastDownload)/seconds):0;
     this.lastTrafficTime=latest.updatedAt;this.lastUpload=latest.uplink || 0;this.lastDownload=latest.downlink || 0;
     if(latest.phase==='running'){
      const nextUp: number[]=this.upHistory.slice(-59);
      nextUp.push(this.uploadRate);
      this.upHistory=nextUp;
      const nextDown: number[]=this.downHistory.slice(-59);
      nextDown.push(this.downloadRate);
      this.downHistory=nextDown;
     }
    }
    if(latest.phase!=='running'){
     this.uploadRate=0;this.downloadRate=0;
     if(this.upHistory.length>0 || this.downHistory.length>0){this.upHistory=[];this.downHistory=[];}
    }
    const cardChanged: boolean=latest.phase!==this.status.phase || (latest.networkType || '')!==(this.status.networkType || '');
    this.status=latest;
    if(latest.phase==='running'){
     writePrivate(`${this.context.filesDir}/dashboard-demand.json`,JSON.stringify({updatedAt:Date.now()}));
     this.dashboard=readDashboard(this.context.filesDir);
    }
    const modeChanged: boolean=latest.phase==='running' && this.dashboard.mode!==this.lastFormMode;
    const periodicCardSync: boolean=latest.phase==='running' && Date.now()-this.lastFormPushAt>=10000;
    if(cardChanged || modeChanged || periodicCardSync){
     pushFormStatus(this.context.filesDir,latest,this.dashboard.mode);
     this.lastFormMode=this.dashboard.mode;
     this.lastFormPushAt=Date.now();
    }
    if(latest.phase==='running' && ['正在连接','正在重新连接'].includes(this.message)){this.showToast('');}
   }
  } catch(_error) {}
  if(this.waitingSince>0 && this.status.phase==='starting' && Date.now()-this.waitingSince>60000){
   this.status=initialStatus();this.status.message='等待授权超时，可重新连接';this.waitingSince=0;
  }
  if(this.status.phase==='running' && this.dashboard.groups.length===0 && this.dashboard.modes.length===0){
   writePrivate(`${this.context.filesDir}/dashboard-demand.json`,JSON.stringify({updatedAt:Date.now()}));
   this.dashboard=readDashboard(this.context.filesDir);
  }
  this.desiredState=loadDesiredState(this.context.filesDir);
 }
 private active(): boolean {return this.status.phase==='running' || this.status.phase==='starting' || this.status.phase==='reconnecting' || this.status.phase==='paused' || this.status.phase==='checking';}
 private async verifyExpiredStatus(snapshot: VpnStatus): Promise<void> {
  this.healthChecking=true;this.lastHealthCheck=Date.now();
  try {
   let exists: boolean=false;
   for(const net of await connection.getAllNets()){
    const caps=await connection.getNetCapabilities(net);if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
    const properties=await connection.getConnectionProperties(net);
    if(properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1') && properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='fdfe:dcba:9876::1')){exists=true;break;}
   }
   const current=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;
   if(current.updatedAt===snapshot.updatedAt && this.waitingSince<=snapshot.updatedAt){
    this.lastVerifiedExpiredAt=snapshot.updatedAt;
    this.lastVerifiedExists=exists;
    this.status=assessExpiredVpnStatus(current,exists);
    const desired: DesiredVpnState=loadDesiredState(this.context.filesDir);
    if(!exists && this.appForeground && this.pageVisible && !this.busy && this.library.selected && desired.desired==='connected' && this.settings.autoReconnect && Date.now()-this.lastAutoRecoverAt>=15000){
     this.lastAutoRecoverAt=Date.now();
     this.showToast('检测到后台 VPN 已停止，正在自动恢复连接…');
     this.toggle(true);
    }
   }
  } catch(_error) {} finally {this.healthChecking=false;}
 }
 private async reconcileInitialStatus(): Promise<void> {
  const timestamp: number=this.status.updatedAt;
  if(this.status.phase==='running'){
   try {
    let exists: boolean=false;
    for(const net of await connection.getAllNets()){
     const caps: connection.NetCapabilities=await connection.getNetCapabilities(net);
     if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
     const props: connection.ConnectionProperties=await connection.getConnectionProperties(net);
     if(props.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1') && props.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='fdfe:dcba:9876::1')){exists=true;break;}
    }
    if(!exists && this.status.phase==='running' && this.status.updatedAt===timestamp){this.status=initialStatus();}
   } catch(_error) {}
  }
  if(this.appForeground && this.pageVisible && this.allowAutomaticConnect && this.settings.autoConnect && !this.busy && !this.active() && this.library.selected){await this.toggle(true);}
  this.autoUpdateProfiles();
 }
 private selectedName(): string {return this.library.profiles.find((p: SavedProfile): boolean => p.id===this.library.selected)?.name || '尚未选择配置';}
 private async ownVpnExists(): Promise<boolean> {
  for(const net of await connection.getAllNets()){
   const caps=await connection.getNetCapabilities(net);if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
   const properties=await connection.getConnectionProperties(net);
   if(properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1') && properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='fdfe:dcba:9876::1')){return true;}
  }
  return false;
 }
 private async consumeShortcut(): Promise<void> {
  if(!this.pendingShortcut){return;}this.allowAutomaticConnect=false;
  if(!this.pageVisible || !this.appForeground || this.busy || this.controlBusy || this.shortcutHandling){return;}
  const input: string=this.pendingShortcut;this.pendingShortcut='';
  let action: string='';
  try {
   const request=JSON.parse(input) as Record<string,string | number>;
   const at: number=request.createdAt as number;
   if(typeof request.action!=='string' || !validShortcutAction(request.action) || !Number.isFinite(at) || Date.now()-at>30000 || at>Date.now()+1000){return;}
   action=request.action;
  } catch(_error) {return;}
  this.shortcutHandling=true;this.busy=true;this.activeTab=0;
  try {
   await runShortcutAction(action,{
    phase:(): string => this.status.phase,
    hasVpn:async (): Promise<boolean> => {const exists: boolean=await this.ownVpnExists();if(!this.pageVisible || !this.appForeground){throw new Error('界面已退出前台');}return exists;},
    start:async (): Promise<void> => {await this.toggle();},
    stop:async (): Promise<void> => {await this.disconnectVpn();},
    reconnect:async (): Promise<void> => {await this.control('reconnect');},
    notify:(message: string): void => {this.message=message;}
   });
  } catch(_error) {this.message='快捷操作未完成，请在总览中重试';}
  finally {this.busy=false;this.shortcutHandling=false;}
 }
 private persistDesiredState(desired: DesiredVpnMode): void {
  const current: DesiredVpnState=loadDesiredState(this.context.filesDir);
  const next: DesiredVpnState={
   desired:desired,
   updatedAt:Date.now(),
   lastInterruptionAt:desired==='stopped'?undefined:current.lastInterruptionAt,
   lastInterruptionReason:desired==='stopped'?undefined:current.lastInterruptionReason,
   lastHandoverAt:current.lastHandoverAt,
   handoverCount:current.handoverCount || 0,
   selfHealCount:current.selfHealCount || 0
  };
  saveDesiredState(this.context.filesDir,next);
  this.desiredState=next;
 }
 private async disconnectVpn(): Promise<void> {
  this.allowAutomaticConnect=false;
  this.persistDesiredState('stopped');
  await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
  await backgroundSession.stop();
  this.waitingSince=0;this.status=initialStatus();this.status.message='VPN 已停止';
  this.upHistory=[];this.downHistory=[];this.hasDeepProbe=false;this.lastFormMode='';
  writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));pushFormStatus(this.context.filesDir,this.status,'');this.showToast('已断开');
 }
 private async toggle(automatic: boolean=false): Promise<void> {
  if(!automatic){this.allowAutomaticConnect=false;}
  this.probeGeneration++;this.probeResult='';this.probing=false;this.hasDeepProbe=false;this.deepProbing=false;this.busy=true;
  try {
   if(this.active()){
    await this.disconnectVpn();
   } else {
    if(!this.library.selected){this.activeTab=3;this.manageSubTab='profiles';this.showToast('请先导入配置');return;}
    const content: string=readProfile(this.context.filesDir,this.library.selected);
    const check: CoreResponse=JSON.parse(await bridge.check(content)) as CoreResponse;
    if(!check.ok){this.showToast('配置未通过内核校验，请编辑配置后重试');return;}
    writePrivate(`${this.context.filesDir}/profile.json`,content);
    this.persistDesiredState('connected');
    this.status={phase:'starting',message:'等待系统 VPN 授权',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};
    this.waitingSince=this.status.updatedAt;
    await backgroundSession.beginSession();
    await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});this.showToast('正在连接');
   }
  } catch(_error) {await backgroundSession.stop();this.showToast('操作未完成，请检查系统 VPN 授权');this.waitingSince=0;this.status=initialStatus();writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));}
  finally {this.busy=false;}
 }
 private async control(action: string,group: string='',outbound: string='',id: string='',mode: string=''): Promise<void> {
  if(this.controlBusy){return;}this.controlBusy=true;
  if(action==='reconnect'){this.busy=true;}
  if(action==='wg-probe'){this.showToast('正在检查回家通道与家庭 DNS…');}
  try {
   if(action==='reconnect'){
    const content: string=readProfile(this.context.filesDir,this.library.selected);
    const checked=JSON.parse(await bridge.check(content)) as CoreResponse;if(!checked.ok){throw new Error('配置校验失败');}
    writePrivate(`${this.context.filesDir}/profile.json`,content);
    await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});await backgroundSession.stop();
    const deadline: number=Date.now()+8000;let present: boolean=true;
    while(present && Date.now()<deadline){
     present=false;
     for(const net of await connection.getAllNets()){
      const caps=await connection.getNetCapabilities(net);if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
      const properties=await connection.getConnectionProperties(net);
      if(properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1') || (this.status.tunName && properties.interfaceName===this.status.tunName)){present=true;break;}
     }
     if(present){await new Promise<void>((resolve) => {setTimeout(resolve,100);});}
    }
    if(present){throw new Error('旧系统 VPN 尚未释放');}
    this.status={phase:'starting',message:'正在重新连接',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};this.waitingSince=this.status.updatedAt;
    await backgroundSession.beginSession();await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});this.showToast('正在重新连接');
   }else {this.showToast(await sendControl(this.context.filesDir,action,group,outbound,id,mode));}
  }
  catch(_error) {this.showToast('操作未完成，请确认 VPN 处于连接状态');}
  finally {this.controlBusy=false;if(action==='reconnect'){this.busy=false;}}
 }
 private async probe(): Promise<void> {
  const generation: number=++this.probeGeneration;
  const profileId: string=this.library.selected;
  let timeout: number=-1;
  this.probing=true;this.probeResult='正在检查双栈与 DNS 连通性…';
  try {
   let content: string='';try {content=readPrivate(`${this.context.filesDir}/running-profile.json`);} catch(_error) {content=readProfile(this.context.filesDir,profileId);}
   const result: string=await Promise.race([runNetworkProbes(content),new Promise<string>((resolve) => {timeout=setTimeout(() => {resolve('连接检查超时，请检查当前配置的 DNS 与出站');},8000);})]);
   writePrivate(`${this.context.filesDir}/network-probe.json`,JSON.stringify({updatedAt:Date.now(),profileId:profileId,result:result,cancelled:generation!==this.probeGeneration}));
   if(generation===this.probeGeneration){this.probeResult=result;}
  }
  catch(_error) {if(generation===this.probeGeneration){this.probeResult='连接检查未完成';}}
  finally {if(timeout!==-1){clearTimeout(timeout);}if(generation===this.probeGeneration){this.probing=false;}}
 }
 private async deepProbe(): Promise<void> {
  if(this.deepProbing || this.status.phase!=='running'){return;}
  this.deepProbing=true;
  try {
   this.deepProbeResult=await runDeepProbe(this.context.filesDir);
   this.hasDeepProbe=true;
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'深度体检未完成，请确认 VPN 处于连接状态');
  } finally {
   this.deepProbing=false;
  }
 }
 private async importFile(): Promise<void> {
  this.busy=true;
  try {
   const options: picker.DocumentSelectOptions=new picker.DocumentSelectOptions();options.maxSelectNumber=1;
   const uris: string[]=await new picker.DocumentViewPicker(this.context).select(options);
   if(uris.length===0){return;}
   const file: fs.File=fs.openSync(uris[0],fs.OpenMode.READ_ONLY);
   let content: string='';
   try {
    const length: number=fs.statSync(file.fd).size;if(length>1048576){throw new Error('配置过大');}
    const buffer: ArrayBuffer=new ArrayBuffer(length);const read: number=fs.readSync(file.fd,buffer);
    if(read!==length){throw new Error('文件读取不完整');}
    content=util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(new Uint8Array(buffer));
   } finally {fs.closeSync(file);}
   this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '导入配置',content);
   this.showToast('配置已导入并通过内核校验');
  } catch(_error) {this.showToast('导入未完成，请检查文件格式和大小（不超过 1 MiB）');}
  finally {this.busy=false;}
 }
 private async pasteProfile(): Promise<void> {
  try {
   const data: pasteboard.PasteData=await pasteboard.getSystemPasteboard().getData();
   this.acceptImportText(data.getPrimaryText());
  } catch(_error) {this.showToast('未能读取剪贴板，请允许访问或手动粘贴');}
 }
 private consumePendingLink(): void {
  if(!this.pendingRemoteProfile){return;}
  try {
   const draft: RemoteProfileDraft=JSON.parse(this.pendingRemoteProfile) as RemoteProfileDraft;
   this.acceptImportText(profileImportLink(draft.name,draft.url));
  } catch(_error) {this.showToast('导入链接无效');}
  this.pendingRemoteProfile='';
 }
 private isRemoteLinkText(trimmed: string): boolean {
  return /^https?:\/\//i.test(trimmed) || /^sing-box:\/\//i.test(trimmed);
 }
 private async convertAndImportText(raw: string): Promise<void> {
  if(this.busy){return;}
  this.busy=true;
  try {
   const converted: string=await convertProfileText(raw);
   this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '转换配置',converted);
   this.editorVisible=false;this.importDrawerOpen=false;this.editorContent='';
   this.showToast('节点链接 / Base64 已转换并导入');
   this.syncUpdates();
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'节点转换失败，请检查链接或 Base64 格式');
  } finally {
   this.busy=false;
  }
 }
 private acceptImportText(text: string): void {
  this.allowAutomaticConnect=false;this.activeTab=3;this.manageSubTab='profiles';this.importDrawerOpen=true;
  const trimmed: string=text.trim();
  if(trimmed.startsWith('{')){
   if(new util.TextEncoder().encodeInto(text).length>1048576){throw new Error('配置过大');}
   this.editingId='';this.editorContent=text;this.editorName='导入配置';this.editorVisible=true;
   this.showToast(this.active()?'已填入导入草稿，请断开 VPN 后确认导入':'已填入导入草稿，请校验保存或下载后导入');
  } else if(this.isRemoteLinkText(trimmed)){
   const draft: RemoteProfileDraft=parseProfileImportLink(trimmed);
   this.remoteURL=draft.url;this.editorName=draft.name;this.editorVisible=false;
   this.showToast(this.active()?'已填入导入草稿，请断开 VPN 后确认导入':'已填入导入草稿，请校验保存或下载后导入');
  } else if(trimmed.length>0){
   this.editingId='';this.editorContent=trimmed;this.editorName=this.editorName || '转换配置';this.editorVisible=true;
   if(this.active()){
    this.showToast('已识别节点链接 / Base64，请断开 VPN 后点击校验并保存');
   } else {
    this.convertAndImportText(trimmed);
   }
  }
 }
 private async scanProfile(): Promise<void> {
  this.busy=true;
  try {const result: scanBarcode.ScanResult=await scanBarcode.startScanForResult(this.context,{scanTypes:[scanCore.ScanType.QR_CODE],enableMultiMode:false,enableAlbum:true});this.acceptImportText(result.originalValue);}
  catch(_error) {this.showToast('未完成扫码，现有配置未改变');}
  finally {this.busy=false;}
 }
 private showProfileCode(record: SavedProfile): void {
  try {
   const code: string=profileImportLink(record.name,record.url);
   if(new util.TextEncoder().encodeInto(code).length>1800){this.showToast('链接较长，请使用文件导出');return;}
   this.sharedCode=code;
  } catch(_error) {this.showToast('只有远程配置可以生成导入链接二维码');}
 }
 private async importRemote(): Promise<void> {
  this.busy=true;
  try {
   const url: string=this.remoteURL.trim();
   const fetched: FetchedProfile=await fetchProfileWithMeta(url);
   this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '远程配置',fetched.content,url,fetched.userinfo);
   this.remoteURL='';this.importDrawerOpen=false;this.showToast('远程配置已导入');this.syncUpdates();
  } catch(_error) {this.showToast('下载或校验失败，原配置已保留');}
  finally {this.busy=false;}
 }
 private async saveEditor(): Promise<void> {
  this.busy=true;
  try {
   let content: string=this.editorContent;
   const trimmed: string=content.trim();
   if(trimmed.length>0 && !trimmed.startsWith('{') && !this.isRemoteLinkText(trimmed)){
    content=await convertProfileText(trimmed);
   }
   if(this.editingId){this.library=await editProfile(this.context.filesDir,this.library,this.editingId,this.editorName,content);}
   else {this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '导入配置',content);}
   this.editorVisible=false;this.importDrawerOpen=false;this.editorContent='';this.showToast('配置已保存并通过内核校验');this.syncUpdates();
  } catch(_error) {this.showToast('保存未完成，请检查 JSON 或节点链接格式；原配置已保留');}
  finally {this.busy=false;}
 }
 private confirmRenameProfile(id: string): void {
  try {
   this.library=renameProfile(this.context.filesDir,this.library,id,this.renameDraft);
   this.renamingProfileId='';
   this.renameDraft='';
   this.showToast('配置名称已更新');
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'改名失败，名称应为 1 至 80 个字符');
  }
 }
 private expiryLabel(expire: number): string {
  if(!Number.isFinite(expire) || expire<=0){return '';}
  const remainDays: number=Math.ceil((expire*1000-Date.now())/86400000);
  if(remainDays<=0){return '已到期';}
  return `剩余 ${remainDays} 天`;
 }
 private isExpired(expire: number): boolean {
  return Number.isFinite(expire) && expire>0 && expire*1000<=Date.now();
 }
 private edit(record: SavedProfile): void {
  this.editingId=record.id;this.editorName=record.name;this.editorContent=readProfile(this.context.filesDir,record.id);this.editorVisible=true;this.importDrawerOpen=true;
 }
 private choose(record: SavedProfile): void {
  try {this.library=selectProfile(this.context.filesDir,this.library,record.id);this.probeResult='';this.dashboard=emptyDashboard();this.showToast(`已切换至「${record.name}」`);}
  catch(_error) {this.showToast('切换未完成，原配置已保留');}
 }
 private deleteProfile(record: SavedProfile): void {
  AlertDialog.show({title:'删除配置',message:`删除“${record.name}”？`,primaryButton:{value:'取消',action:() => {}},secondaryButton:{value:'删除',action:() => {try {this.library=removeProfile(this.context.filesDir,this.library,record.id);this.showToast('已删除配置');this.syncUpdates();} catch(_error) {this.showToast('请先切换到其他配置');}}}});
 }
 private async refresh(record: SavedProfile): Promise<void> {
  this.busy=true;
  try {await refreshProfile(this.context.filesDir,this.library,record.id);this.library=loadLibrary(this.context.filesDir);this.showToast(this.active()?'配置已更新，手动重连后应用':'配置已更新');}
  catch(_error) {this.showToast('更新失败，已保留原配置');}
  finally {this.busy=false;}
 }
 private async autoUpdateProfiles(): Promise<void> {
  if(this.busy || !this.appForeground || !this.pageVisible || (this.context.applicationInfo.debug && this.diagnosticsPauseForegroundUpdates) || this.automaticUpdate || Date.now()-this.lastAutoUpdate<60000){return;}this.lastAutoUpdate=Date.now();
  const cancellation: ProfileFetchCancellation=new ProfileFetchCancellation();this.automaticUpdate=cancellation;
  try {this.updateReport=await runDueProfileUpdates(this.context.filesDir,'foreground',cancellation,60000);this.library=loadLibrary(this.context.filesDir);} catch(_error) {}
  finally {if(this.automaticUpdate===cancellation){this.automaticUpdate=undefined;}}
 }
 private updateForeground(): void {
  if(!this.appForeground || !this.pageVisible){backgroundSession.onBackground();if(this.timer!==-1){clearInterval(this.timer);this.timer=-1;}this.automaticUpdate?.cancel();return;}
  this.foregroundSince=Date.now();
  backgroundSession.onForeground();
  this.readStatus();
  if(this.timer===-1){this.timer=setInterval(() => {this.readStatus();this.autoUpdateProfiles();},1000);}
  this.syncUpdates();
 }
 private async syncUpdates(): Promise<void> {this.scheduleStatus=await syncSubscriptionSchedule(this.context.filesDir);this.updateReport=readUpdateReport(this.context.filesDir);}
 private setUpdateHours(record: SavedProfile,hours: number): void {
  try {this.library=setAutoUpdate(this.context.filesDir,record.id,hours);this.syncUpdates();} catch(_error) {this.showToast('未能保存自动更新设置');}
 }
 private toggleAutoUpdate(record: SavedProfile,value: boolean): void {
  this.setUpdateHours(record,value?24:0);
 }
 private async exportDocument(name: string,content: string): Promise<void> {
  this.busy=true;
  try {
   const options: picker.DocumentSaveOptions=new picker.DocumentSaveOptions();options.newFileNames=[name.replace(/[\/\\]/g,'_')];
   const uris: string[]=await new picker.DocumentViewPicker(this.context).save(options);if(uris.length===0){return;}
   const file: fs.File=fs.openSync(uris[0],fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
   try {if(fs.writeSync(file.fd,content)!==new util.TextEncoder().encodeInto(content).length){throw new Error('写入不完整');}}
   finally {fs.closeSync(file);}
   this.showToast('已导出到所选位置');
  } catch(_error) {this.showToast('导出未完成');}
  finally {this.busy=false;}
 }
 private saveOptions(): void {saveSettings(this.context.filesDir,this.settings);this.showToast('设置已保存');}
 private saveApplicationScope(): void {
  try {this.applicationScope=saveVpnScope(this.context.filesDir,this.applicationScope.mode,this.applicationScopeText);this.applicationScopeText=this.applicationScope.applications.join('\n');this.showToast('应用范围已保存，下次连接生效');}
  catch(_error) {this.showToast('保存未完成，请填写 1 至 256 个有效包名，每行一个');}
 }
 private currentScopePackages(): string[] {
  const result: string[]=[];
  for(const raw of this.applicationScopeText.split(/\r?\n/)){
   const name: string=raw.trim();
   if(name.length>0 && !result.includes(name)){result.push(name);}
  }
  return result;
 }
 private togglePresetApp(bundleName: string): void {
  const current: VpnScope={mode:this.applicationScope.mode,applications:this.currentScopePackages()};
  const next: VpnScope=toggleScopePackage(current,bundleName);
  this.applicationScope=next;
  this.applicationScopeText=next.applications.join('\n');
 }
 private locationOptions(value: boolean): AppSettings {
  return {autoReconnect:this.settings.autoReconnect,autoConnect:this.settings.autoConnect,logLevel:this.settings.logLevel,onDemand:this.settings.onDemand,bypassWifi:this.settings.bypassWifi,locationAssist:value,backgroundUpdates:this.settings.backgroundUpdates,blackholeOnSwitch:this.settings.blackholeOnSwitch,ssidPolicies:this.settings.ssidPolicies};
 }
 private async toggleLocationAssist(value: boolean): Promise<void> {
  if(this.locationChanging){return;}this.locationChanging=true;
  try {
   if(value && !await backgroundSession.requestPermission()){this.settings=this.locationOptions(false);saveSettings(this.context.filesDir,this.settings);await backgroundSession.reconfigure(this.pageVisible);this.showToast('定位未授权，已保留普通后台运行方式');return;}
   this.settings=this.locationOptions(value);this.saveOptions();
   await backgroundSession.reconfigure(this.pageVisible);
  } catch(_error) {this.showToast('定位辅助设置未完成，请检查系统权限');}
  finally {this.locationChanging=false;}
 }
 private updateSsidPolicies(rules: SsidPolicyRule[],toastText: string): void {
  this.settings={
   autoReconnect:this.settings.autoReconnect,
   autoConnect:this.settings.autoConnect,
   logLevel:this.settings.logLevel,
   onDemand:this.settings.onDemand,
   bypassWifi:this.settings.bypassWifi,
   locationAssist:this.settings.locationAssist,
   backgroundUpdates:this.settings.backgroundUpdates,
   blackholeOnSwitch:this.settings.blackholeOnSwitch,
   ssidPolicies:rules
  };
  this.ssidPoliciesText=formatSsidPolicyLines(rules);
  saveSettings(this.context.filesDir,this.settings);
  this.showToast(toastText);
 }
 private saveSsidPolicies(): void {
  try {
   const parsed: SsidPolicyRule[]=parseSsidPolicyLines(this.ssidPoliciesText);
   this.updateSsidPolicies(parsed,'SSID 策略已保存');
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'SSID 策略格式无效，请检查后重试');
  }
 }
 private availableModes(): string[] {
  return this.dashboard.modes.length>0?this.dashboard.modes:['rule','global','direct'];
 }
 private selectedSsidGroup(): OutboundGroup | undefined {
  return this.dashboard.groups.find((g: OutboundGroup): boolean => g.tag===this.ssidGroupInput);
 }
 private selectedSsidGroupItems(): GroupItem[] {
  const group: OutboundGroup | undefined=this.selectedSsidGroup();
  return group?group.items:[];
 }
 private ssidPolicyBadgeLabel(rule: SsidPolicyRule): string {
  if(rule.action==='pause'){return '暂停隧道';}
  if(rule.action==='mode'){return `模式: ${rule.mode || ''}`;}
  return `${rule.group || ''} → ${rule.outbound || ''}`;
 }
 private ssidPolicyBadgeColor(rule: SsidPolicyRule): string {
  if(rule.action==='pause'){return BRAND.coral;}
  if(rule.action==='mode'){return BRAND.cyan;}
  return BRAND.green;
 }
 private addSsidPolicyRule(): void {
  const ssid: string=this.ssidInput.trim();
  if(!usableSsid(ssid)){
   this.showToast('Wi-Fi 名称应为 1 至 32 字节，按原名称精确匹配');
   return;
  }
  let rule: SsidPolicyRule;
  if(this.ssidAction==='pause'){
   rule={ssid:ssid,action:'pause'};
  } else if(this.ssidAction==='mode'){
   const mode: string=this.ssidModeInput.trim();
   if(mode.length===0){
    this.showToast('请选择或输入目标模式');
    return;
   }
   rule={ssid:ssid,action:'mode',mode:mode};
  } else {
   const group: string=this.ssidGroupInput.trim();
   const outbound: string=this.ssidOutboundInput.trim();
   if(group.length===0 || outbound.length===0){
    this.showToast('请选择或输入策略组与目标节点');
    return;
   }
   rule={ssid:ssid,action:'group',group:group,outbound:outbound};
  }
  const existingIndex: number=this.settings.ssidPolicies.findIndex((r: SsidPolicyRule): boolean => r.ssid===ssid);
  const nextRules: SsidPolicyRule[]=this.settings.ssidPolicies.slice();
  if(existingIndex>=0){
   nextRules[existingIndex]=rule;
  } else {
   if(nextRules.length>=128){
    this.showToast('最多保存 128 条 SSID 策略');
    return;
   }
   nextRules.push(rule);
  }
  this.ssidInput='';
  this.updateSsidPolicies(nextRules,existingIndex>=0?'已更新 SSID 策略':'已添加 SSID 策略');
 }
 private removeSsidPolicyRule(ssid: string): void {
  const nextRules: SsidPolicyRule[]=this.settings.ssidPolicies.filter((r: SsidPolicyRule): boolean => r.ssid!==ssid);
  this.updateSsidPolicies(nextRules,'已删除 SSID 策略');
 }
 private syncOverrideTexts(overrides: LocalOverrides): void {
  this.overrideDirectText=overrides.directDomains.join('\n');
  this.overrideProxyText=overrides.proxyDomains.join('\n');
  this.overrideRejectText=overrides.rejectDomains.join('\n');
  this.overrideDirectCidrText=overrides.directCidrs.join('\n');
  this.overrideProxyCidrText=overrides.proxyCidrs.join('\n');
  this.overrideRejectCidrText=overrides.rejectCidrs.join('\n');
  this.overrideHostsText=formatHostLines(overrides.hosts);
 }
 private cloneLocalOverrides(src: LocalOverrides): LocalOverrides {
  return {
   enabled:src.enabled,
   hosts:src.hosts.map((h: HostOverride): HostOverride => ({domain:h.domain,ips:h.ips.slice()})),
   directDomains:src.directDomains.slice(),
   proxyDomains:src.proxyDomains.slice(),
   rejectDomains:src.rejectDomains.slice(),
   directCidrs:src.directCidrs.slice(),
   proxyCidrs:src.proxyCidrs.slice(),
   rejectCidrs:src.rejectCidrs.slice()
  };
 }
 private toggleLocalOverridesEnabled(value: boolean): void {
  const next: LocalOverrides=this.cloneLocalOverrides(this.localOverrides);
  next.enabled=value;
  try {
   saveLocalOverrides(this.context.filesDir,next);
   this.localOverrides=next;
   if(value){this.overridesExpanded=true;}
   this.showToast(value?'已启用本地覆写（重连生效）':'已关闭本地覆写（重连生效）');
  } catch(_error) {
   this.showToast('本地覆写开关保存失败');
  }
 }
 private addLocalOverrideRule(): void {
  try {
   const next: LocalOverrides=this.cloneLocalOverrides(this.localOverrides);
   if(this.overrideRuleType==='domain'){
    const parsed: string[]=parseDomainList(this.overrideTargetInput);
    if(parsed.length===0){this.showToast('请输入有效域名，例如 example.com');return;}
    for(const domain of parsed){
     next.directDomains=next.directDomains.filter((d: string): boolean => d!==domain);
     next.proxyDomains=next.proxyDomains.filter((d: string): boolean => d!==domain);
     next.rejectDomains=next.rejectDomains.filter((d: string): boolean => d!==domain);
     if(this.overrideAction==='direct'){next.directDomains.push(domain);}
     else if(this.overrideAction==='proxy'){next.proxyDomains.push(domain);}
     else {next.rejectDomains.push(domain);}
    }
    saveLocalOverrides(this.context.filesDir,next);
    this.localOverrides=next;
    this.syncOverrideTexts(next);
    this.overrideTargetInput='';
    this.showToast('已添加规则，重连后生效');
   } else if(this.overrideRuleType==='cidr'){
    const parsed: string[]=parseCidrList(this.overrideTargetInput);
    if(parsed.length===0){this.showToast('请输入有效网段，例如 192.168.1.0/24');return;}
    for(const cidr of parsed){
     next.directCidrs=next.directCidrs.filter((c: string): boolean => c!==cidr);
     next.proxyCidrs=next.proxyCidrs.filter((c: string): boolean => c!==cidr);
     next.rejectCidrs=next.rejectCidrs.filter((c: string): boolean => c!==cidr);
     if(this.overrideAction==='direct'){next.directCidrs.push(cidr);}
     else if(this.overrideAction==='proxy'){next.proxyCidrs.push(cidr);}
     else {next.rejectCidrs.push(cidr);}
    }
    saveLocalOverrides(this.context.filesDir,next);
    this.localOverrides=next;
    this.syncOverrideTexts(next);
    this.overrideTargetInput='';
    this.showToast('已添加规则，重连后生效');
   } else {
    const domain: string=this.overrideHostDomainInput.trim();
    const ip: string=this.overrideHostIpInput.trim();
    if(domain.length===0 || ip.length===0){this.showToast('请输入域名与目标 IP');return;}
    const parsed: HostOverride[]=parseHostLines(`${domain} = ${ip}`);
    if(parsed.length===0){this.showToast('请输入有效的 Host 映射');return;}
    for(const entry of parsed){
     const existing: HostOverride | undefined=next.hosts.find((h: HostOverride): boolean => h.domain===entry.domain);
     if(existing){
      for(const addr of entry.ips){
       if(!existing.ips.includes(addr)){existing.ips.push(addr);}
      }
     } else {
      next.hosts.push({domain:entry.domain,ips:entry.ips.slice()});
     }
    }
    saveLocalOverrides(this.context.filesDir,next);
    this.localOverrides=next;
    this.syncOverrideTexts(next);
    this.overrideHostDomainInput='';
    this.overrideHostIpInput='';
    this.showToast('已添加规则，重连后生效');
   }
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'规则格式无效，请检查后重试');
  }
 }
 private removeLocalOverrideRule(item: OverrideRuleItem): void {
  try {
   const next: LocalOverrides=this.cloneLocalOverrides(this.localOverrides);
   if(item.category==='rejectDomain'){next.rejectDomains=next.rejectDomains.filter((d: string): boolean => d!==item.rawKey);}
   else if(item.category==='directDomain'){next.directDomains=next.directDomains.filter((d: string): boolean => d!==item.rawKey);}
   else if(item.category==='proxyDomain'){next.proxyDomains=next.proxyDomains.filter((d: string): boolean => d!==item.rawKey);}
   else if(item.category==='rejectCidr'){next.rejectCidrs=next.rejectCidrs.filter((c: string): boolean => c!==item.rawKey);}
   else if(item.category==='directCidr'){next.directCidrs=next.directCidrs.filter((c: string): boolean => c!==item.rawKey);}
   else if(item.category==='proxyCidr'){next.proxyCidrs=next.proxyCidrs.filter((c: string): boolean => c!==item.rawKey);}
   else if(item.category==='host'){next.hosts=next.hosts.filter((h: HostOverride): boolean => h.domain!==item.rawKey);}
   saveLocalOverrides(this.context.filesDir,next);
   this.localOverrides=next;
   this.syncOverrideTexts(next);
   this.showToast('已删除规则，重连后生效');
  } catch(_error) {
   this.showToast('删除规则失败');
  }
 }
 private overrideRuleItems(): OverrideRuleItem[] {
  const items: OverrideRuleItem[]=[];
  for(const d of this.localOverrides.rejectDomains){
   items.push({key:`reject-domain-${d}`,badge:'REJECT',badgeColor:BRAND.coral,typeTag:'DOMAIN',target:d,rawKey:d,category:'rejectDomain'});
  }
  for(const c of this.localOverrides.rejectCidrs){
   items.push({key:`reject-cidr-${c}`,badge:'REJECT',badgeColor:BRAND.coral,typeTag:'CIDR',target:c,rawKey:c,category:'rejectCidr'});
  }
  for(const d of this.localOverrides.directDomains){
   items.push({key:`direct-domain-${d}`,badge:'DIRECT',badgeColor:BRAND.green,typeTag:'DOMAIN',target:d,rawKey:d,category:'directDomain'});
  }
  for(const c of this.localOverrides.directCidrs){
   items.push({key:`direct-cidr-${c}`,badge:'DIRECT',badgeColor:BRAND.green,typeTag:'CIDR',target:c,rawKey:c,category:'directCidr'});
  }
  for(const d of this.localOverrides.proxyDomains){
   items.push({key:`proxy-domain-${d}`,badge:'PROXY',badgeColor:BRAND.cyan,typeTag:'DOMAIN',target:d,rawKey:d,category:'proxyDomain'});
  }
  for(const c of this.localOverrides.proxyCidrs){
   items.push({key:`proxy-cidr-${c}`,badge:'PROXY',badgeColor:BRAND.cyan,typeTag:'CIDR',target:c,rawKey:c,category:'proxyCidr'});
  }
  for(const h of this.localOverrides.hosts){
   items.push({key:`host-${h.domain}-${h.ips.join(',')}`,badge:'HOST',badgeColor:BRAND.amber,typeTag:'',target:`${h.domain} → ${h.ips.join(', ')}`,rawKey:h.domain,category:'host'});
  }
  return items;
 }
 private quickAddDomainOverride(rawDomain: string,action: string): void {
  try {
   const parsed: string[]=parseDomainList(rawDomain);
   if(parsed.length===0){this.showToast('域名格式不支持置顶覆写');return;}
   const domain: string=parsed[0];
   const next: LocalOverrides=this.cloneLocalOverrides(this.localOverrides);
   next.enabled=true;
   next.directDomains=next.directDomains.filter((d: string): boolean => d!==domain);
   next.proxyDomains=next.proxyDomains.filter((d: string): boolean => d!==domain);
   next.rejectDomains=next.rejectDomains.filter((d: string): boolean => d!==domain);
   let label: string='拒绝';
   if(action==='direct'){next.directDomains.push(domain);label='直连';}
   else if(action==='proxy'){next.proxyDomains.push(domain);label='代理';}
   else {next.rejectDomains.push(domain);label='拒绝';}
   saveLocalOverrides(this.context.filesDir,next);
   this.localOverrides=next;
   this.syncOverrideTexts(next);
   this.showToast(`已加入置顶[${label}]：${domain}（重连生效）`);
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'加入置顶规则失败');
  }
 }
 private saveLocalOverridesForm(): void {
  try {
   const next: LocalOverrides={
    enabled:this.localOverrides.enabled,
    hosts:parseHostLines(this.overrideHostsText),
    directDomains:parseDomainList(this.overrideDirectText),
    proxyDomains:parseDomainList(this.overrideProxyText),
    rejectDomains:parseDomainList(this.overrideRejectText),
    directCidrs:parseCidrList(this.overrideDirectCidrText),
    proxyCidrs:parseCidrList(this.overrideProxyCidrText),
    rejectCidrs:parseCidrList(this.overrideRejectCidrText)
   };
   saveLocalOverrides(this.context.filesDir,next);
   this.localOverrides=next;
   this.syncOverrideTexts(next);
   this.showToast('本地覆写已保存，重连后生效');
  } catch(error) {
   this.showToast(error instanceof Error?error.message:'本地覆写格式无效，请检查域名、网段与 Host 映射');
  }
 }
 private phaseLabel(): string {
  if(this.status.phase==='running'){return '已保护';}
  if(this.status.phase==='checking'){return '状态待确认';}
  if(this.status.phase==='paused'){return '已暂停';}
  if(this.status.phase==='reconnecting'){return '韧性重连中';}
  if(this.status.phase==='starting'){return '正在连接';}
  return '未连接';
 }
 private phaseAccent(): string {
  if(this.status.phase==='running'){return BRAND.green;}
  if(this.status.phase==='paused' || this.status.phase==='reconnecting' || this.status.phase==='checking'){return BRAND.amber;}
  if(this.status.phase==='starting'){return BRAND.cyan;}
  return BRAND.muted;
 }
 private delayColor(delay?: number): string {
  if(!delay || delay<=0){return BRAND.muted;}
  if(delay<150){return BRAND.green;}
  if(delay<400){return BRAND.amber;}
  return BRAND.coral;
 }
 private primaryOutboundName(): string {
  if(this.dashboard.groups.length===0){return '';}
  return this.dashboard.groups[0].selected || '';
 }
 private primaryOutboundDelay(): number {
  if(this.dashboard.groups.length===0){return 0;}
  const group: OutboundGroup=this.dashboard.groups[0];
  const found: GroupItem | undefined=group.items.find((it: GroupItem): boolean => it.tag===group.selected);
  return found && found.urlTestDelay && found.urlTestDelay>0?found.urlTestDelay:0;
 }
 private async refreshPolicyDelays(): Promise<void> {
  if(this.status.phase!=='running' || this.dashboard.groups.length===0){
   this.refreshingPolicy=false;
   return;
  }
  try {
   await this.control('urltest','',this.dashboard.groups[0].tag);
  } finally {
   this.refreshingPolicy=false;
  }
 }
 private isGroupCollapsed(tag: string): boolean {
  return this.collapsedGroups.includes(tag);
 }
 private toggleGroupCollapse(tag: string): void {
  animateTo({duration:200},() => {
   if(this.collapsedGroups.includes(tag)){
    this.collapsedGroups=this.collapsedGroups.filter((t: string): boolean => t!==tag);
   } else {
    this.collapsedGroups=[...this.collapsedGroups,tag];
   }
  });
 }
 private filteredGroupItems(items: GroupItem[]): GroupItem[] {
  const q: string=this.nodeFilter.trim().toLowerCase();
  const base: GroupItem[]=q?items.filter((it: GroupItem): boolean => it.tag.toLowerCase().includes(q) || it.type.toLowerCase().includes(q)):items.slice();
  if(!this.sortNodesByDelay){return base;}
  base.sort((a: GroupItem,b: GroupItem): number => {
   const da: number=a.urlTestDelay && a.urlTestDelay>0?a.urlTestDelay:Number.MAX_SAFE_INTEGER;
   const db: number=b.urlTestDelay && b.urlTestDelay>0?b.urlTestDelay:Number.MAX_SAFE_INTEGER;
   if(da!==db){return da-db;}
   return a.tag.localeCompare(b.tag);
  });
  return base;
 }
 private connectionDurationMs(item: ConnectionInfo): number {
  if(item.durationMs && item.durationMs>0){return item.durationMs;}
  if(item.closedAt && item.closedAt>item.createdAt){return item.closedAt-item.createdAt;}
  if(item.createdAt>0){return Math.max(0,Date.now()-item.createdAt);}
  return 0;
 }
 private async runHostDiagnosis(): Promise<void> {
  if(this.diagnosing){return;}
  const host: string=this.diagnoseInput.trim();
  if(host.length===0){this.diagnosisError='请输入要诊断的域名或 IP';return;}
  this.diagnosing=true;
  this.diagnosisError='';
  try {
   this.diagnosisResult=await diagnoseHost(this.context.filesDir,host);
   this.hasDiagnosis=true;
  } catch(error) {
   this.diagnosisError=error instanceof Error?error.message:'诊断未完成，请确认 VPN 处于连接状态';
  } finally {
   this.diagnosing=false;
  }
 }
 private visibleConnections(): ConnectionInfo[] {
  const query: string=this.connectionFilter.toLowerCase();
  const source: ConnectionInfo[]=this.activitySubTab==='recent'?(this.dashboard.recentRequests || []):this.dashboard.connections;
  return source.filter((c: ConnectionInfo): boolean => `${c.domain} ${c.destination} ${c.outbound} ${c.rule || ''}`.toLowerCase().includes(query));
 }
 private overridesSummary(): string {
  const domainCount: number=this.localOverrides.directDomains.length+this.localOverrides.proxyDomains.length+this.localOverrides.rejectDomains.length;
  const cidrCount: number=this.localOverrides.directCidrs.length+this.localOverrides.proxyCidrs.length+this.localOverrides.rejectCidrs.length;
  const hostCount: number=this.localOverrides.hosts.length;
  const total: number=domainCount+cidrCount+hostCount;
  if(!this.localOverrides.enabled){return `已关闭 · ${total} 条规则`;}
  return `已启用 · 域名 ${domainCount} · 网段 ${cidrCount} · Host ${hostCount}`;
 }
 private scopeSummary(): string {
  if(this.applicationScope.mode==='include'){return `仅指定 ${this.applicationScope.applications.length} 个应用`;}
  if(this.applicationScope.mode==='exclude'){return `排除 ${this.applicationScope.applications.length} 个应用`;}
  return '所有应用';
 }

 @Builder private sectionHeader(text: string) {
  Text(text).fontSize(12).fontWeight(FontWeight.Bold).letterSpacing(0.8).fontColor(BRAND.muted).width('100%').padding({left:4,top:4})
 }
 @Builder private note(params: NoteText) {Text(params.value).fontSize(12).fontColor(BRAND.muted).width('100%')}

 // ================= TAB 0: 总览 =================
 @Builder private overview() {
  Column({space:14}) {
   // Compact Brand Header + Quick Profile Switcher Chip
   Row({space:10}) {
    Image($r('app.media.app_icon')).width(40).height(40).borderRadius(12).objectFit(ImageFit.Contain)
    Column({space:2}) {
     Row({space:6}) {
      Text('熊盒 VPN').fontSize(19).fontWeight(FontWeight.Bold).fontColor(BRAND.text)
      Text('1.0').fontSize(10).fontWeight(FontWeight.Bold).fontColor(BRAND.cyan).backgroundColor(BRAND.soft).borderRadius(6).padding({left:6,right:6,top:2,bottom:2})
     }
     Text(this.coreVersion).fontSize(10).fontColor(BRAND.muted).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    Row({space:4}) {
     Text(this.selectedName()).fontSize(12).fontWeight(FontWeight.Medium).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).constraintSize({maxWidth:118})
     SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([BRAND.muted])
    }.padding({left:10,right:8,top:7,bottom:7}).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line}).onClick(() => {this.activeTab=3;this.manageSubTab='profiles';})
   }.width('100%')

   // Hero Connection Console Card
   Column({space:14}) {
    Row({space:10}) {
     Row({space:8}) {
      Circle().width(10).height(10).fill(this.phaseAccent())
      Text(this.phaseLabel()).fontSize(24).fontWeight(FontWeight.Bold).fontColor(BRAND.text)
     }.layoutWeight(1)
     if(this.status.phase==='running'){
      Text(`${this.status.networkType || '网络'} · ${this.status.physicalIPv6Available?'双栈':'IPv4'}`).fontSize(11).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan).backgroundColor(BRAND.soft).borderRadius(10).padding({left:10,right:10,top:4,bottom:4})
     }
    }.width('100%')

    Text(this.status.phase==='running'?`${this.status.tunName || 'vpn-tun'} · MTU 1280 · ${this.status.message}`:this.status.message).fontSize(12).fontColor(BRAND.muted).width('100%').maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})

    // Primary Active Outbound Node & Latency Pill
    if(this.status.phase==='running' && this.primaryOutboundName().length>0){
     Row({space:8}) {
      Circle().width(7).height(7).fill(BRAND.cyan)
      Text(this.dashboard.groups[0].tag).fontSize(11).fontColor(BRAND.muted)
      Text(this.primaryOutboundName()).fontSize(13).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
      Text(this.primaryOutboundDelay()>0?`${this.primaryOutboundDelay()}ms`:'--')
       .fontSize(11)
       .fontWeight(FontWeight.Bold)
       .fontColor(this.delayColor(this.primaryOutboundDelay()))
       .padding({left:7,right:7,top:2,bottom:2})
       .backgroundColor(BRAND.background)
       .borderRadius(7)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([BRAND.muted])
     }
     .width('100%')
     .padding({left:12,right:10,top:9,bottom:9})
     .backgroundColor(BRAND.elevated)
     .borderRadius(13)
     .border({width:1,color:BRAND.line})
     .onClick(() => {this.activeTab=1;})
    }

    // Surge-style Embedded Outbound Mode Segmented Bar
    if(this.status.phase==='running' && this.dashboard.modes.length>0){
     Row({space:4}) {
      ForEach(this.dashboard.modes,(mode: string) => {
       Button(mode)
        .layoutWeight(1)
        .height(34)
        .fontSize(13)
        .fontWeight(mode===this.dashboard.mode?FontWeight.Bold:FontWeight.Medium)
        .backgroundColor(mode===this.dashboard.mode?BRAND.cyan:Color.Transparent)
        .fontColor(mode===this.dashboard.mode?BRAND.onAccent:BRAND.muted)
        .borderRadius(12)
        .padding(0)
        .enabled(!this.controlBusy && mode!==this.dashboard.mode)
        .onClick(() => {this.control('mode','','','',mode);})
      },(mode: string): string => `${mode}-${this.dashboard.mode}`)
     }.width('100%').padding(4).backgroundColor(BRAND.background).borderRadius(15).border({width:1,color:BRAND.line})
    }

    // 2x2 Live Telemetry Grid
    if(this.status.phase==='running'){
     Column({space:8}) {
      Row({space:8}) {
       Column({space:4}) {
        Text('↑ 实时上行').fontSize(11).fontColor(BRAND.muted).width('100%')
        Text(`${bytesLabel(this.uploadRate)}/s`).fontSize(19).fontWeight(FontWeight.Bold).fontColor(BRAND.cyan).width('100%')
        Text(`累计 ${bytesLabel(this.status.uplink || 0)}`).fontSize(11).fontColor(BRAND.muted).width('100%')
       }.padding(12).layoutWeight(1).backgroundColor(BRAND.elevated).borderRadius(14)
       Column({space:4}) {
        Text('↓ 实时下行').fontSize(11).fontColor(BRAND.muted).width('100%')
        Text(`${bytesLabel(this.downloadRate)}/s`).fontSize(19).fontWeight(FontWeight.Bold).fontColor(BRAND.green).width('100%')
        Text(`累计 ${bytesLabel(this.status.downlink || 0)}`).fontSize(11).fontColor(BRAND.muted).width('100%')
       }.padding(12).layoutWeight(1).backgroundColor(BRAND.elevated).borderRadius(14)
      }.width('100%')
      Row({space:8}) {
       Column({space:3}) {
        Text('Always-On 韧性').fontSize(11).fontColor(BRAND.muted).width('100%')
        Text(`热切 ${this.desiredState.handoverCount || 0} · 自愈 ${this.desiredState.selfHealCount || 0}`).fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.text).width('100%')
       }.padding(11).layoutWeight(1).backgroundColor(BRAND.elevated).borderRadius(14)
       Column({space:3}) {
        Text('实时活动 ›').fontSize(11).fontColor(BRAND.cyan).width('100%')
        Text(`活跃 ${this.dashboard.connections.length} · 最近 ${(this.dashboard.recentRequests || []).length}`).fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.text).width('100%')
       }.padding(11).layoutWeight(1).backgroundColor(BRAND.elevated).borderRadius(14).onClick(() => {this.activeTab=2;})
      }.width('100%')
      TrafficSparkline({upSamples:this.upHistory,downSamples:this.downHistory})
     }.width('100%')
    }

    // Primary CTA Button
    Button(this.active()?'断开连接':'连接 VPN')
     .width('100%')
     .height(50)
     .fontSize(16)
     .fontWeight(FontWeight.Bold)
     .borderRadius(16)
     .backgroundColor(this.active()?BRAND.dangerSurface:BRAND.cyan)
     .fontColor(this.active()?BRAND.coral:BRAND.onAccent)
     .border({width:1,color:this.active()?BRAND.dangerLine:BRAND.cyan})
     .enabled(!this.busy)
     .onClick(() => {this.toggle();})

    // Secondary 3-Action Bar
    if(this.status.phase==='running' || this.status.phase==='checking'){
     Row({space:8}) {
      Button() {
       Row({space:5}) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(14).fontColor([BRAND.cyan])
        Text('重连').fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan)
       }
      }.layoutWeight(1).height(38).borderRadius(12).backgroundColor(BRAND.soft).enabled(!this.controlBusy && !this.busy).onClick(() => {this.control('reconnect');})
      Button() {
       Row({space:5}) {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(14).fontColor([BRAND.cyan])
        Text(this.probing?'检查中':'体检').fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan)
       }
      }.layoutWeight(1).height(38).borderRadius(12).backgroundColor(BRAND.soft).enabled(!this.probing).onClick(() => {this.probe();})
      Button() {
       Row({space:5}) {
        SymbolGlyph($r('sys.symbol.waveform')).fontSize(14).fontColor([BRAND.cyan])
        Text('清缓存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan)
       }
      }.layoutWeight(1).height(38).borderRadius(12).backgroundColor(BRAND.soft).enabled(this.status.phase==='running' && !this.controlBusy).onClick(() => {this.control('reset-network');})
     }.width('100%')
     if(this.status.phase==='running'){
      Button() {
       Row({space:6}) {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(13).fontColor([BRAND.cyan])
        Text(this.deepProbing?'深度体检中…':'深度体检 · 直连/代理出口 IP & STUN NAT').fontSize(12).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan)
       }
      }.width('100%').height(34).borderRadius(11).backgroundColor(BRAND.elevated).border({width:1,color:BRAND.line}).enabled(!this.deepProbing && !this.controlBusy).onClick(() => {this.deepProbe();})
     }
    }

    if(this.probeResult){
     Row({space:8}) {
      Text(this.probeResult).fontSize(12).fontColor(BRAND.text).layoutWeight(1)
      Text('×').fontSize(16).fontColor(BRAND.muted).padding({left:6,right:4}).onClick(() => {this.probeResult='';})
     }.padding(12).width('100%').backgroundColor(BRAND.background).borderRadius(12).border({width:1,color:BRAND.line})
    }

    if(this.hasDeepProbe){
     Column({space:6}) {
      Row({space:8}) {
       Text('深度体检结果').fontSize(12).fontWeight(FontWeight.Bold).fontColor(BRAND.cyan).layoutWeight(1)
       Text('×').fontSize(16).fontColor(BRAND.muted).padding({left:6,right:4}).onClick(() => {this.hasDeepProbe=false;})
      }.width('100%')
      Text(`直连出口：${this.deepProbeResult.directIp || '--'}${this.deepProbeResult.directLatencyMs?` (${this.deepProbeResult.directLatencyMs}ms)`:''}`).fontSize(12).fontColor(BRAND.text).width('100%')
      Text(`代理出口：${this.deepProbeResult.proxyIp || '--'}${this.deepProbeResult.proxyLatencyMs?` (${this.deepProbeResult.proxyLatencyMs}ms)`:''}`).fontSize(12).fontColor(BRAND.green).width('100%')
      Text(`STUN NAT：${this.deepProbeResult.natType}${this.deepProbeResult.stunMapped?` · ${this.deepProbeResult.stunMapped}`:''}`).fontSize(12).fontColor(BRAND.amber).width('100%')
      if(this.deepProbeResult.summary){
       Text(this.deepProbeResult.summary).fontSize(11).fontColor(BRAND.muted).width('100%')
      }
     }.padding(12).width('100%').backgroundColor(BRAND.background).borderRadius(12).border({width:1,color:BRAND.cyan})
    }
   }.padding(18).width('100%').backgroundColor(BRAND.surface).borderRadius(22).border({width:1,color:this.status.phase==='running'?BRAND.cyan:BRAND.line})

   // Interruption Alert Card (only when Always-On desired connected but stopped)
   if(this.desiredState.desired==='connected' && !this.active()){
    Column({space:10}) {
     Row({space:8}) {
      Circle().width(8).height(8).fill(BRAND.coral)
      Text('上次连接被异常中断').fontSize(14).fontWeight(FontWeight.Bold).fontColor(BRAND.coral).layoutWeight(1)
     }.width('100%')
     Text(`${this.desiredState.lastInterruptionReason || '系统回收或网络异常'}${this.desiredState.lastInterruptionAt?` · ${new Date(this.desiredState.lastInterruptionAt).toLocaleString()}`:''}`).fontSize(12).fontColor(BRAND.muted).width('100%')
     Button('立即恢复连接').width('100%').height(40).borderRadius(12).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).enabled(!this.busy).onClick(() => {this.toggle();})
    }.padding(16).width('100%').backgroundColor(BRAND.dangerSurface).borderRadius(18).border({width:1,color:BRAND.dangerLine})
   }

   // WireGuard Home Tunnel Card(s)
   if(this.status.phase==='running' && this.dashboard.wireGuard.length>0){
    this.sectionHeader('回家通道 · WIREGUARD')
    ForEach(this.dashboard.wireGuard,(wg: WireGuardInfo) => {
     Column({space:10}) {
      Row({space:8}) {
       Column({space:2}) {
        Row({space:6}) {
         Text(wg.tag).fontSize(16).fontWeight(FontWeight.Bold).fontColor(BRAND.text)
         Text(wg.active?'运行中':'未启动').fontSize(10).fontWeight(FontWeight.Medium).fontColor(wg.active?BRAND.green:BRAND.amber).backgroundColor(BRAND.elevated).borderRadius(8).padding({left:7,right:7,top:2,bottom:2})
        }
        Text(`地址族 ${wg.ipv4?'IPv4 ':''}${wg.ipv6?'IPv6':''}`).fontSize(11).fontColor(BRAND.muted)
       }.alignItems(HorizontalAlign.Start).layoutWeight(1)
       Button(this.controlBusy?'测速中':'测家庭 DNS').height(32).fontSize(12).borderRadius(10).padding({left:12,right:12}).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.controlBusy && wg.active && wg.dnsConfigured && wg.dnsCovered).onClick(() => {this.control('wg-probe','',wg.tag);})
      }.width('100%')
      ForEach(wg.peers,(peer: WireGuardPeer) => {
       Row({space:8}) {
        Text(peer.lastHandshake>0?`握手 ${new Date(peer.lastHandshake*1000).toLocaleTimeString()}`:'待握手').fontSize(12).fontColor(peer.lastHandshake>0?BRAND.text:BRAND.muted).layoutWeight(1)
        Text(`↑ ${bytesLabel(peer.txBytes)}  ↓ ${bytesLabel(peer.rxBytes)}`).fontSize(12).fontColor(BRAND.cyan)
       }.width('100%').padding({left:10,right:10,top:8,bottom:8}).backgroundColor(BRAND.elevated).borderRadius(10)
      },(peer: WireGuardPeer): string => `${peer.index}-${peer.lastHandshake}-${peer.txBytes}-${peer.rxBytes}`)
      if(this.status.bindFailure){Text(`底层绑定失败：${this.status.bindFailure} 次`).fontSize(11).fontColor(BRAND.coral).width('100%')}
      if(wg.dnsConfigured && !wg.dnsCovered){Text('家庭 DNS 不在 peer AllowedIPs 内').fontSize(11).fontColor(BRAND.amber).width('100%')}
      if(wg.lastProbe){Text(`家庭 DNS：${wg.lastProbe.summary}`).fontSize(12).fontColor(BRAND.muted).width('100%')}
     }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})
    },(wg: WireGuardInfo): string => `${wg.tag}-${wg.peers.map((peer: WireGuardPeer): string => `${peer.lastHandshake}:${peer.txBytes}:${peer.rxBytes}`).join('|')}-${wg.lastProbe?.updatedAt || 0}`)
   }

   // Multi-Tunnel Cards (Tailscale / OpenVPN / OpenConnect)
   if(this.status.phase==='running' && (this.dashboard.tunnels || []).length>0){
    this.sectionHeader('多协议隧道 · TUNNELS')
    ForEach(this.dashboard.tunnels || [],(tunnel: TunnelView) => {
     Column({space:8}) {
      Row({space:8}) {
       Row({space:6}) {
        Text(tunnel.tag).fontSize(15).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        Text(tunnel.type).fontSize(10).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan).backgroundColor(BRAND.soft).borderRadius(6).padding({left:6,right:6,top:2,bottom:2})
       }.layoutWeight(1)
       Text(tunnel.active?'运行中':'未启动').fontSize(10).fontWeight(FontWeight.Medium).fontColor(tunnel.active?BRAND.green:BRAND.amber).backgroundColor(BRAND.elevated).borderRadius(8).padding({left:7,right:7,top:2,bottom:2})
      }.width('100%')
      if(tunnel.summary){
       Text(tunnel.summary).fontSize(12).fontColor(BRAND.muted).width('100%')
      }
     }.padding(15).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})
    },(tunnel: TunnelView): string => `${tunnel.tag}-${tunnel.type}-${tunnel.active?1:0}-${tunnel.summary}`)
   }

   // Compact Status Footer when disconnected
   if(this.status.phase!=='running'){
    Row({space:8}) {
     Column({space:2}) {
      Text('Always-On 韧性保护').fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.text)
      Text(`黑洞保护 ${this.settings.blackholeOnSwitch?'已开启':'已关闭'} · 历史热切 ${this.desiredState.handoverCount || 0} 次 · 自愈 ${this.desiredState.selfHealCount || 0} 次`).fontSize(11).fontColor(BRAND.muted)
     }.alignItems(HorizontalAlign.Start).layoutWeight(1)
     SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([BRAND.muted])
    }.padding(14).width('100%').backgroundColor(BRAND.surface).borderRadius(16).border({width:1,color:BRAND.line}).onClick(() => {this.activeTab=3;this.manageSubTab='settings';})
   }
  }.padding({left:16,right:16,top:12,bottom:20}).width('100%').constraintSize({maxWidth:820}).alignItems(HorizontalAlign.Start)
 }

 // ================= TAB 1: 策略（Surge 节点网格） =================
 @Builder private groupsPage() {
  Column({space:12}) {
   Row({space:10}) {
    Text('策略组').fontSize(24).fontWeight(FontWeight.Bold).fontColor(BRAND.text).layoutWeight(1)
    if(this.status.phase==='running'){
     Button(this.sortNodesByDelay?'按延迟 ✓':'默认顺序')
      .height(32)
      .fontSize(12)
      .borderRadius(12)
      .padding({left:12,right:12})
      .backgroundColor(this.sortNodesByDelay?BRAND.cyan:BRAND.surface)
      .fontColor(this.sortNodesByDelay?BRAND.onAccent:BRAND.muted)
      .border({width:1,color:this.sortNodesByDelay?BRAND.cyan:BRAND.line})
      .onClick(() => {this.sortNodesByDelay=!this.sortNodesByDelay;})
    }
   }.width('100%')

   if(this.status.phase!=='running'){
    Column({space:10}) {
     Text('连接 VPN 后管理策略组与节点测速').fontSize(14).fontColor(BRAND.muted)
     Button('前往总览连接').height(38).borderRadius(12).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).onClick(() => {this.activeTab=0;})
    }.padding(24).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line}).alignItems(HorizontalAlign.Center)
   } else {
    TextInput({text:this.nodeFilter,placeholder:'筛选节点名称或协议…'}).height(40).borderRadius(12).backgroundColor(BRAND.surface).onChange((value: string) => {this.nodeFilter=value;})
    if(this.dashboard.groups.length===0){this.note({value:'正在读取策略组；当前配置也可能没有 selector / urltest。'})}

    ForEach(this.dashboard.groups,(group: OutboundGroup) => {
     Column({space:10}) {
      // Group Header Row (tap to fold/unfold)
      Row({space:8}) {
       Column({space:3}) {
        Row({space:6}) {
         Text(group.tag).fontSize(17).fontWeight(FontWeight.Bold).fontColor(BRAND.text)
         Text(group.type).fontSize(10).fontColor(BRAND.muted).backgroundColor(BRAND.elevated).borderRadius(6).padding({left:6,right:6,top:2,bottom:2})
        }
        Text(`当前：${group.selected}`).fontSize(12).fontWeight(FontWeight.Medium).fontColor(BRAND.cyan).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
       }.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => {this.toggleGroupCollapse(group.tag);})
       Button() {
        Row({space:4}) {
         SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(12).fontColor([BRAND.cyan])
         Text('测速').fontSize(12).fontColor(BRAND.cyan)
        }
       }.height(30).borderRadius(10).padding({left:10,right:10}).backgroundColor(BRAND.soft).enabled(!this.controlBusy).onClick(() => {this.control('urltest','',group.tag);})
       SymbolGlyph(this.isGroupCollapsed(group.tag)?$r('sys.symbol.chevron_right'):$r('sys.symbol.chevron_down')).fontSize(14).fontColor([BRAND.muted]).padding(4).onClick(() => {this.toggleGroupCollapse(group.tag);})
      }.width('100%')

      // Surge-style 2-Column Tappable Node Tile Grid
      if(!this.isGroupCollapsed(group.tag)){
       Column({space:8}) {
        ForEach(chunkPairs(this.filteredGroupItems(group.items)),(pair: GroupItem[]) => {
         Row({space:8}) {
          ForEach(pair,(item: GroupItem) => {
           Column({space:6}) {
            Row({space:5}) {
             Circle().width(6).height(6).fill(group.selected===item.tag?BRAND.cyan:Color.Transparent)
             Text(item.tag).fontSize(13).fontWeight(group.selected===item.tag?FontWeight.Bold:FontWeight.Medium).fontColor(group.selected===item.tag?BRAND.text:BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
            }.width('100%')
            Row({space:4}) {
             Text(item.type).fontSize(10).fontColor(BRAND.muted).maxLines(1).layoutWeight(1)
             Text(item.urlTestDelay && item.urlTestDelay>0?`${item.urlTestDelay}ms`:'--')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.delayColor(item.urlTestDelay))
              .padding({left:6,right:6,top:2,bottom:2})
              .backgroundColor(BRAND.background)
              .borderRadius(6)
              .onClick(() => {if(!this.controlBusy){this.control('urltest','',item.tag);}})
            }.width('100%')
           }
           .padding(11)
           .layoutWeight(1)
           .backgroundColor(group.selected===item.tag?BRAND.elevated:BRAND.background)
           .borderRadius(13)
           .border({width:group.selected===item.tag?1.5:1,color:group.selected===item.tag?BRAND.cyan:BRAND.line})
           .onClick(() => {
            if(group.selectable && !this.controlBusy && group.selected!==item.tag){
             this.control('select',group.tag,item.tag);
            }
           })
          },(item: GroupItem): string => `${item.tag}-${item.urlTestDelay || 0}-${group.selected===item.tag?1:0}`)
          if(pair.length===1){Blank().layoutWeight(1)}
         }.width('100%')
        },(pair: GroupItem[]): string => pair.map((it: GroupItem): string => `${it.tag}:${it.urlTestDelay || 0}:${group.selected===it.tag?1:0}`).join('|'))
       }.width('100%')
      }
     }.padding(15).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})
    },(group: OutboundGroup): string => `${group.tag}-${group.selected}-${this.sortNodesByDelay?1:0}-${this.nodeFilter}-${this.isGroupCollapsed(group.tag)?1:0}-${group.items.map((item: GroupItem): string => `${item.tag}:${item.urlTestTime || 0}:${item.urlTestDelay || 0}`).join('|')}`)
   }
  }.padding({left:16,right:16,top:12,bottom:20}).width('100%').constraintSize({maxWidth:820}).alignItems(HorizontalAlign.Start)
 }

 // ================= TAB 2: 活动（最近请求 / 活跃连接 / 日志 + 域名诊断） =================
 @Builder private activityPage() {
  Column({space:12}) {
   Row({space:8}) {
    Text('实时活动').fontSize(24).fontWeight(FontWeight.Bold).fontColor(BRAND.text).layoutWeight(1)
    if(this.status.phase==='running'){
     Button() {
      Row({space:4}) {
       SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(12).fontColor([this.diagnoseDrawerOpen?BRAND.onAccent:BRAND.cyan])
       Text('诊断').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.diagnoseDrawerOpen?BRAND.onAccent:BRAND.cyan)
      }
     }.height(32).borderRadius(12).padding({left:12,right:12}).backgroundColor(this.diagnoseDrawerOpen?BRAND.cyan:BRAND.surface).border({width:1,color:this.diagnoseDrawerOpen?BRAND.cyan:BRAND.line}).onClick(() => {this.diagnoseDrawerOpen=!this.diagnoseDrawerOpen;})
    }
   }.width('100%')

   // 3-Segment Control: 最近请求 | 活跃连接 | 日志
   Row({space:4}) {
    Button(`最近 (${(this.dashboard.recentRequests || []).length})`).layoutWeight(1).height(34).fontSize(12).fontWeight(this.activitySubTab==='recent'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.activitySubTab==='recent'?BRAND.cyan:Color.Transparent).fontColor(this.activitySubTab==='recent'?BRAND.onAccent:BRAND.muted).borderRadius(11).padding(0).onClick(() => {this.activitySubTab='recent';})
    Button(`活跃 (${this.dashboard.connections.length})`).layoutWeight(1).height(34).fontSize(12).fontWeight(this.activitySubTab==='active'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.activitySubTab==='active'?BRAND.cyan:Color.Transparent).fontColor(this.activitySubTab==='active'?BRAND.onAccent:BRAND.muted).borderRadius(11).padding(0).onClick(() => {this.activitySubTab='active';})
    Button(`日志 (${this.dashboard.logs.length})`).layoutWeight(1).height(34).fontSize(12).fontWeight(this.activitySubTab==='logs'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.activitySubTab==='logs'?BRAND.cyan:Color.Transparent).fontColor(this.activitySubTab==='logs'?BRAND.onAccent:BRAND.muted).borderRadius(11).padding(0).onClick(() => {this.activitySubTab='logs';})
   }.width('100%').padding(4).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line})

   // Collapsible Surge Host/DNS Diagnosis Drawer
   if(this.diagnoseDrawerOpen && this.status.phase==='running'){
    Column({space:8}) {
     Row({space:8}) {
      TextInput({text:this.diagnoseInput,placeholder:'域名或 IP，例如 example.com'}).height(38).layoutWeight(1).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.diagnoseInput=value;})
      Button(this.diagnosing?'诊断中':'执行').height(38).borderRadius(10).padding({left:14,right:14}).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).enabled(!this.diagnosing && this.diagnoseInput.trim().length>0).onClick(() => {this.runHostDiagnosis();})
     }.width('100%')
     if(this.diagnosisError){Text(this.diagnosisError).fontSize(12).fontColor(BRAND.coral).width('100%')}
     if(this.hasDiagnosis){
      Column({space:4}) {
       Text(this.diagnosisResult.summary).fontSize(12).fontWeight(FontWeight.Bold).fontColor(BRAND.text).width('100%')
       Text(`IPv4：${this.diagnosisResult.ipv4.length>0?this.diagnosisResult.ipv4.join(', '):'无'}  ·  IPv6：${this.diagnosisResult.ipv6.length>0?this.diagnosisResult.ipv6.join(', '):'无'}`).fontSize(11).fontColor(BRAND.muted).width('100%')
       Text(`耗时 ${this.diagnosisResult.latencyMs}ms · 模式 ${this.diagnosisResult.mode || this.dashboard.mode || '默认'}`).fontSize(11).fontColor(BRAND.cyan).width('100%')
       if(this.diagnosisResult.dnsError){Text(`DNS 异常：${this.diagnosisResult.dnsError}`).fontSize(11).fontColor(BRAND.coral).width('100%')}
      }.padding(10).width('100%').backgroundColor(BRAND.background).borderRadius(10)
     }
    }.padding(12).width('100%').backgroundColor(BRAND.surface).borderRadius(16).border({width:1,color:BRAND.cyan})
   }

   if(this.activitySubTab==='logs'){
    // Logs Sub-View
    Row({space:8}) {
     TextInput({text:this.logFilter,placeholder:'筛选内核日志…'}).height(38).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.logFilter=value;})
     Button('清空').height(38).fontSize(12).borderRadius(10).padding({left:12,right:12}).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(this.status.phase==='running' && !this.controlBusy).onClick(() => {this.control('clear-logs');})
     Button('导出').height(38).fontSize(12).borderRadius(10).padding({left:12,right:12}).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy).onClick(() => {this.exportDocument('bearbox-logs.txt',this.dashboard.logs.join('\n'));})
    }.width('100%')
    if(this.dashboard.logs.length===0){
     this.note({value:'暂无日志（仅保留最近 100 条，可在管理→设置中调整日志级别）。'})
    } else {
     Column({space:6}) {
      ForEach(this.dashboard.logs.filter((line: string): boolean => line.toLowerCase().includes(this.logFilter.toLowerCase())),(line: string) => {
       Text(line).fontSize(11).fontFamily('monospace').fontColor(BRAND.text).width('100%').copyOption(CopyOptions.InApp).padding({top:4,bottom:4})
      },(line: string,index: number): string => `${index}-${line}`)
     }.padding(12).width('100%').backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line})
    }
   } else {
    // Connections / Recent Requests Sub-View
    if(this.status.phase!=='running'){
     this.note({value:'连接 VPN 后查看实时连接与最近 500 条请求。'})
    } else {
     Row({space:8}) {
      TextInput({text:this.connectionFilter,placeholder:'搜索域名、出站、规则…'}).height(38).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.connectionFilter=value;})
      if(this.activitySubTab==='active'){
       Button('全关').height(38).fontSize(12).borderRadius(10).padding({left:12,right:12}).backgroundColor(BRAND.dangerSurface).fontColor(BRAND.coral).enabled(!this.controlBusy && this.dashboard.connections.length>0).onClick(() => {this.control('close-all');})
      }
     }.width('100%')
     ForEach(this.visibleConnections(),(item: ConnectionInfo) => {
      Column({space:6}) {
       Row({space:6}) {
        Circle().width(6).height(6).fill((item.status || 'active')==='closed'?BRAND.muted:BRAND.green)
        Text(item.domain || item.destination).fontSize(14).fontWeight(FontWeight.Medium).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
        Text(item.outbound).fontSize(10).fontWeight(FontWeight.Bold).fontColor(BRAND.cyan).backgroundColor(BRAND.elevated).borderRadius(7).padding({left:7,right:7,top:2,bottom:2})
       }.width('100%')
       Row({space:6}) {
        Text(`${item.network.toUpperCase()} · ${durationLabel(this.connectionDurationMs(item))}`).fontSize(11).fontColor(BRAND.muted)
        Text(`↑${bytesLabel(item.upload)} ↓${bytesLabel(item.download)}`).fontSize(11).fontColor(BRAND.muted).layoutWeight(1).textAlign(TextAlign.End)
       }.width('100%')
       if(this.expandedConnection===item.id){
        Column({space:6}) {
         Text(`目标：${item.destination}`).fontSize(11).fontColor(BRAND.muted).width('100%')
         Text(`规则：${item.rule || '默认路由'}`).fontSize(11).fontColor(BRAND.text).width('100%')
         Text(`建立：${new Date(item.createdAt).toLocaleTimeString()}${item.closedAt?`  结束：${new Date(item.closedAt).toLocaleTimeString()}`:''}`).fontSize(11).fontColor(BRAND.muted).width('100%')
         if(item.domain && item.domain.trim().length>0){
          Row({space:6}) {
           Button('直连').layoutWeight(1).height(30).fontSize(11).fontWeight(FontWeight.Bold).borderRadius(8).backgroundColor(BRAND.elevated).fontColor(BRAND.green).border({width:1,color:BRAND.green}).padding(0).onClick(() => {this.quickAddDomainOverride(item.domain,'direct');})
           Button('代理').layoutWeight(1).height(30).fontSize(11).fontWeight(FontWeight.Bold).borderRadius(8).backgroundColor(BRAND.elevated).fontColor(BRAND.cyan).border({width:1,color:BRAND.cyan}).padding(0).onClick(() => {this.quickAddDomainOverride(item.domain,'proxy');})
           Button('拒绝').layoutWeight(1).height(30).fontSize(11).fontWeight(FontWeight.Bold).borderRadius(8).backgroundColor(BRAND.dangerSurface).fontColor(BRAND.coral).border({width:1,color:BRAND.dangerLine}).padding(0).onClick(() => {this.quickAddDomainOverride(item.domain,'reject');})
           Button('查 DNS').layoutWeight(1).height(30).fontSize(11).fontWeight(FontWeight.Bold).borderRadius(8).backgroundColor(BRAND.soft).fontColor(BRAND.amber).border({width:1,color:BRAND.line}).padding(0).onClick(() => {this.diagnoseDrawerOpen=true;this.diagnoseInput=item.domain;this.runHostDiagnosis();})
          }.width('100%')
         }
         if((item.status || 'active')!=='closed'){
          Button('关闭此连接').height(30).fontSize(11).borderRadius(8).backgroundColor(BRAND.dangerSurface).fontColor(BRAND.coral).width('100%').enabled(!this.controlBusy).onClick(() => {this.control('close','','',item.id);})
         }
        }.padding(10).width('100%').backgroundColor(BRAND.background).borderRadius(10)
       }
      }.padding(12).width('100%').backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line}).onClick(() => {this.expandedConnection=this.expandedConnection===item.id?'':item.id;})
     },(item: ConnectionInfo): string => `${this.activitySubTab}-${item.id}-${item.status || 'active'}-${item.upload}-${item.download}-${item.durationMs || 0}-${this.expandedConnection===item.id?1:0}`)
     if(this.visibleConnections().length===0){
      this.note({value:'当前筛选条件下无匹配记录。'})
     }
    }
   }
  }.padding({left:16,right:16,top:12,bottom:20}).width('100%').constraintSize({maxWidth:820}).alignItems(HorizontalAlign.Start)
 }

 // ================= TAB 3: 管理（配置库 + 设置与覆写） =================
 @Builder private managePage() {
  Column({space:14}) {
   Text('管理').fontSize(24).fontWeight(FontWeight.Bold).fontColor(BRAND.text).width('100%')

   // 2-Segment Control: 配置库 | 设置与覆写
   Row({space:4}) {
    Button(`配置库 (${this.library.profiles.length})`).layoutWeight(1).height(36).fontSize(13).fontWeight(this.manageSubTab==='profiles'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.manageSubTab==='profiles'?BRAND.cyan:Color.Transparent).fontColor(this.manageSubTab==='profiles'?BRAND.onAccent:BRAND.muted).borderRadius(11).padding(0).onClick(() => {this.manageSubTab='profiles';})
    Button('设置与覆写').layoutWeight(1).height(36).fontSize(13).fontWeight(this.manageSubTab==='settings'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.manageSubTab==='settings'?BRAND.cyan:Color.Transparent).fontColor(this.manageSubTab==='settings'?BRAND.onAccent:BRAND.muted).borderRadius(11).padding(0).onClick(() => {this.manageSubTab='settings';})
   }.width('100%').padding(4).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line})

   if(this.manageSubTab==='profiles'){
    this.profilesSubView()
   } else {
    this.settingsSubView()
   }
  }.padding({left:16,right:16,top:12,bottom:20}).width('100%').constraintSize({maxWidth:820}).alignItems(HorizontalAlign.Start)
 }

 @Builder private profilesSubView() {
  Column({space:12}) {
   // 4-Action Quick Import Strip
   Row({space:8}) {
    Column({space:5}) {
     SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor([BRAND.cyan])
     Text('文件').fontSize(11).fontColor(BRAND.text)
    }.padding(10).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line}).opacity(!this.busy && !this.active()?1:0.45).onClick(() => {if(!this.busy && !this.active()){this.importFile();}})
    Column({space:5}) {
     SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(18).fontColor([BRAND.cyan])
     Text('剪贴板').fontSize(11).fontColor(BRAND.text)
    }.padding(10).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line}).opacity(!this.busy && !this.active()?1:0.45).onClick(() => {if(!this.busy && !this.active()){this.pasteProfile();}})
    Column({space:5}) {
     SymbolGlyph($r('sys.symbol.qrcode')).fontSize(18).fontColor([BRAND.cyan])
     Text('扫码').fontSize(11).fontColor(BRAND.text)
    }.padding(10).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(14).border({width:1,color:BRAND.line}).opacity(!this.busy && !this.active()?1:0.45).onClick(() => {if(!this.busy && !this.active()){this.scanProfile();}})
    Column({space:5}) {
     SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(18).fontColor([this.importDrawerOpen?BRAND.onAccent:BRAND.cyan])
     Text('链接/新建').fontSize(11).fontColor(this.importDrawerOpen?BRAND.onAccent:BRAND.text)
    }.padding(10).layoutWeight(1).backgroundColor(this.importDrawerOpen?BRAND.cyan:BRAND.surface).borderRadius(14).border({width:1,color:this.importDrawerOpen?BRAND.cyan:BRAND.line}).onClick(() => {this.importDrawerOpen=!this.importDrawerOpen;})
   }.width('100%')

   // Collapsible Import / Edit Drawer
   if(this.importDrawerOpen){
    Column({space:10}) {
     TextInput({text:this.editorName,placeholder:'配置名称（可选）'}).height(38).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.editorName=value;}).enabled(!this.busy && !this.active())
     Row({space:8}) {
      TextInput({text:this.remoteURL,placeholder:'远程 sing-box JSON 链接'}).type(InputType.Password).height(38).layoutWeight(1).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.remoteURL=value;}).enabled(!this.busy && !this.active())
      Button('下载').height(38).fontSize(12).borderRadius(10).padding({left:14,right:14}).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).enabled(!this.busy && !this.active() && this.remoteURL.length>0).onClick(() => {this.importRemote();})
     }.width('100%')
     Row({space:8}) {
      Button('新建 JSON').layoutWeight(1).height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy && !this.active()).onClick(() => {this.editingId='';this.editorContent='';this.editorVisible=true;})
      Button('节点链接/Base64').layoutWeight(1).height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy && !this.active()).onClick(() => {this.editingId='';this.editorName=this.editorName || '转换配置';this.editorContent='';this.editorVisible=true;})
      Button('直连预设').layoutWeight(1).height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy && !this.active()).onClick(() => {this.editingId='';this.editorName='直连诊断';this.editorContent=DIRECT_PROFILE;this.editorVisible=true;})
     }.width('100%')
     if(this.editorVisible){
      TextArea({text:this.editorContent,placeholder:'粘贴完整 sing-box JSON，或 vless:// / vmess:// / hy2:// / tuic:// / ss:// / trojan:// / Base64 节点文本'}).height(220).fontFamily('monospace').fontSize(11).maxLength(1048576).backgroundColor(BRAND.background).borderRadius(10).enabled(!this.busy && !this.active()).onChange((value: string) => {this.editorContent=value;})
      Row({space:8}) {
       Button('校验并保存').layoutWeight(1).height(38).borderRadius(10).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).enabled(!this.busy && !this.active()).onClick(() => {this.saveEditor();})
       Button('取消').height(38).borderRadius(10).padding({left:16,right:16}).backgroundColor(BRAND.soft).fontColor(BRAND.muted).enabled(!this.busy).onClick(() => {this.editorVisible=false;this.editorContent='';})
      }.width('100%')
     }
    }.padding(14).width('100%').backgroundColor(BRAND.surface).borderRadius(16).border({width:1,color:BRAND.cyan})
   }

   if(this.sharedCode){
    Column({space:10}) {
     QRCode(this.sharedCode).width(200).height(200).color(BRAND.background).backgroundColor(Color.White)
     this.note({value:'二维码含订阅链接，请仅展示给可信设备。'})
     Button('关闭二维码').height(34).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {this.sharedCode='';})
    }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(16).border({width:1,color:BRAND.line}).alignItems(HorizontalAlign.Center)
   }

   // Profile List
   ForEach(this.library.profiles,(record: SavedProfile) => {
    Column({space:10}) {
     Row({space:8}) {
      Column({space:3}) {
       Row({space:6}) {
        Text(record.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        if(record.id===this.library.selected){
         Text('使用中').fontSize(10).fontWeight(FontWeight.Bold).fontColor(BRAND.onAccent).backgroundColor(BRAND.cyan).borderRadius(7).padding({left:7,right:7,top:2,bottom:2})
        }
       }
       Text(`${record.url?'远程订阅':'本地配置'} · ${new Date(record.updatedAt).toLocaleString()}`).fontSize(11).fontColor(BRAND.muted)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if(record.id!==this.library.selected){
       Button('选用').height(30).fontSize(12).borderRadius(9).padding({left:12,right:12}).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).enabled(!this.busy && !this.active()).onClick(() => {this.choose(record);})
      }
     }.width('100%')
     if(this.renamingProfileId===record.id){
      Row({space:6}) {
       TextInput({text:this.renameDraft,placeholder:'输入新配置名称'}).height(34).fontSize(12).layoutWeight(1).backgroundColor(BRAND.background).borderRadius(9).onChange((value: string) => {this.renameDraft=value;})
       Button('确定').height(34).fontSize(12).borderRadius(9).padding({left:12,right:12}).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).onClick(() => {this.confirmRenameProfile(record.id);})
       Button('取消').height(34).fontSize(12).borderRadius(9).padding({left:10,right:10}).backgroundColor(BRAND.soft).fontColor(BRAND.muted).onClick(() => {this.renamingProfileId='';this.renameDraft='';})
      }.width('100%')
     }
     if(record.userinfo && record.userinfo.total>0){
      Column({space:5}) {
       Row({space:6}) {
        Text(`已用 ${bytesLabel((record.userinfo.upload || 0)+(record.userinfo.download || 0))} / ${bytesLabel(record.userinfo.total)} (${Math.min(100,Math.max(0,Math.round((((record.userinfo.upload || 0)+(record.userinfo.download || 0))/record.userinfo.total)*100)))}%)`)
         .fontSize(11)
         .fontColor(BRAND.text)
         .layoutWeight(1)
        if(this.expiryLabel(record.userinfo.expire)){
         Text(this.expiryLabel(record.userinfo.expire))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isExpired(record.userinfo.expire)?BRAND.coral:BRAND.muted)
        }
       }.width('100%')
       Progress({value:Math.min(100,Math.max(0,Math.round((((record.userinfo.upload || 0)+(record.userinfo.download || 0))/record.userinfo.total)*100))),total:100,type:ProgressType.Linear})
        .width('100%')
        .height(6)
        .color((((record.userinfo.upload || 0)+(record.userinfo.download || 0))/record.userinfo.total)>=0.9?BRAND.coral:BRAND.cyan)
        .backgroundColor(BRAND.background)
      }.width('100%').padding({left:10,right:10,top:8,bottom:8}).backgroundColor(BRAND.elevated).borderRadius(10)
     }
     Row({space:6}) {
      if(record.url){
       Button('更新').layoutWeight(1).height(32).fontSize(12).borderRadius(9).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy).onClick(() => {this.refresh(record);})
       Button('二维码').layoutWeight(1).height(32).fontSize(12).borderRadius(9).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy).onClick(() => {this.showProfileCode(record);})
      }
      Button('改名').layoutWeight(1).height(32).fontSize(12).borderRadius(9).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy).onClick(() => {this.renamingProfileId=this.renamingProfileId===record.id?'':record.id;this.renameDraft=record.name;})
      Button('编辑').layoutWeight(1).height(32).fontSize(12).borderRadius(9).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy && !this.active()).onClick(() => {this.edit(record);})
      Button('导出').layoutWeight(1).height(32).fontSize(12).borderRadius(9).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).enabled(!this.busy).onClick(() => {this.exportDocument(`${record.name}.json`,readProfile(this.context.filesDir,record.id));})
      if(record.id!==this.library.selected){
       Button('删').height(32).fontSize(12).borderRadius(9).padding({left:10,right:10}).backgroundColor(BRAND.dangerSurface).fontColor(BRAND.coral).enabled(!this.busy && !this.active()).onClick(() => {this.deleteProfile(record);})
      }
     }.width('100%')
     if(record.url){
      Row({space:8}) {
       Text('自动更新').fontSize(12).fontColor(BRAND.muted).layoutWeight(1)
       if(record.autoUpdateHours>0){
        Select([{value:'1 小时'},{value:'6 小时'},{value:'12 小时'},{value:'24 小时'},{value:'7 天'}]).value(record.autoUpdateHours===168?'7 天':`${record.autoUpdateHours} 小时`).onSelect((index: number) => {this.setUpdateHours(record,[1,6,12,24,168][index]);})
       }
       Toggle({type:ToggleType.Switch,isOn:record.autoUpdateHours>0}).onChange((value: boolean) => {if(value!==(record.autoUpdateHours>0)){this.toggleAutoUpdate(record,value);}})
      }.width('100%')
     }
    }.padding(15).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:record.id===this.library.selected?1.5:1,color:record.id===this.library.selected?BRAND.cyan:BRAND.line})
   },(record: SavedProfile): string => `${record.id}-${record.name}-${record.updatedAt}-${record.autoUpdateHours}-${this.library.selected}-${this.renamingProfileId===record.id?1:0}-${record.userinfo?`${record.userinfo.upload}:${record.userinfo.download}:${record.userinfo.total}:${record.userinfo.expire}`:''}`)
  }.width('100%')
 }

 @Builder private settingsSubView() {
  Column({space:12}) {
   // Group 1: Always-On & Resilience
   this.sectionHeader('ALWAYS-ON 与连接韧性')
   Column({space:12}) {
    Row(){
     Column({space:2}){Text('切网保留 TUN 防泄漏').fontSize(14).fontColor(BRAND.text);Text('切网或短暂断网时保持黑洞路由（最长 60s）并热切换').fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     Toggle({type:ToggleType.Switch,isOn:this.settings.blackholeOnSwitch}).onChange((value: boolean) => {this.settings.blackholeOnSwitch=value;this.saveOptions();})
    }.width('100%')
    Divider().color(BRAND.line)
    Row(){
     Column({space:2}){Text('掉线 / 切网自动重连').fontSize(14).fontColor(BRAND.text);Text('热切换失败或长期断网恢复后自动重建隧道').fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     Toggle({type:ToggleType.Switch,isOn:this.settings.autoReconnect}).onChange((value: boolean) => {this.settings.autoReconnect=value;this.saveOptions();})
    }.width('100%')
    Divider().color(BRAND.line)
    Row(){
     Column({space:2}){Text('打开 App 时自动连接').fontSize(14).fontColor(BRAND.text);Text('前台启动后自动拉起当前选中配置').fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     Toggle({type:ToggleType.Switch,isOn:this.settings.autoConnect}).onChange((value: boolean) => {this.settings.autoConnect=value;this.saveOptions();})
    }.width('100%')
    Divider().color(BRAND.line)
    Row(){
     Column({space:2}){Text('定位辅助驻留（实验）').fontSize(14).fontColor(BRAND.text);Text(this.backgroundSessionStatus).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     Toggle({type:ToggleType.Switch,isOn:this.settings.locationAssist}).enabled(!this.locationChanging && !this.busy).onChange((value: boolean) => {if(value!==this.settings.locationAssist){this.toggleLocationAssist(value);}})
    }.width('100%')
   }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})

   // Group 2: Wi-Fi & SSID Policy
   this.sectionHeader('WI-FI 条件与 SSID 策略')
   Column({space:12}) {
    Row(){
     Column({space:2}){Text('指定 Wi-Fi 暂停隧道').fontSize(14).fontColor(BRAND.text);Text(`已配置 ${this.settings.bypassWifi.length} 个 Wi-Fi · 离开自动恢复`).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => {this.wifiPauseExpanded=!this.wifiPauseExpanded;})
     Toggle({type:ToggleType.Switch,isOn:this.settings.onDemand}).onChange((value: boolean) => {this.settings.onDemand=value;if(value){this.wifiPauseExpanded=true;}this.saveOptions();})
    }.width('100%')
    if(this.settings.onDemand && this.wifiPauseExpanded){
     TextArea({text:this.wifiRulesText,placeholder:'每行一个精确 Wi-Fi 名称'}).height(84).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.wifiRulesText=value;})
     Button('保存暂停列表').height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {try {this.settings.bypassWifi=parseWifiNames(this.wifiRulesText);this.wifiRulesText=this.settings.bypassWifi.join('\n');this.saveOptions();} catch(_error) {this.showToast('Wi-Fi 名称无效（1–32 字节，最多 128 个）');}})
    }
    Divider().color(BRAND.line)
    Row(){
     Column({space:2}){Text('SSID 策略联动（Surge 式）').fontSize(14).fontColor(BRAND.text);Text(`已配置 ${this.settings.ssidPolicies.length} 条 · 按 Wi-Fi 切换模式、节点或暂停`).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     SymbolGlyph(this.ssidPolicyExpanded?$r('sys.symbol.chevron_down'):$r('sys.symbol.chevron_right')).fontSize(14).fontColor([BRAND.muted])
    }.width('100%').onClick(() => {this.ssidPolicyExpanded=!this.ssidPolicyExpanded;})
    if(this.ssidPolicyExpanded){
     // Graphical SSID Policy Builder
     Column({space:10}) {
      TextInput({text:this.ssidInput,placeholder:'精确 Wi-Fi 名称（SSID），例如 HomeWiFi'}).height(38).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.ssidInput=value;})
      // Action Selector (3 capsule pills)
      Row({space:6}) {
       Button('切模式').layoutWeight(1).height(32).fontSize(12).fontWeight(this.ssidAction==='mode'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.ssidAction==='mode'?BRAND.cyan:BRAND.surface).fontColor(this.ssidAction==='mode'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.ssidAction==='mode'?BRAND.cyan:BRAND.line}).padding(0).onClick(() => {this.ssidAction='mode';})
       Button('切节点').layoutWeight(1).height(32).fontSize(12).fontWeight(this.ssidAction==='group'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.ssidAction==='group'?BRAND.green:BRAND.surface).fontColor(this.ssidAction==='group'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.ssidAction==='group'?BRAND.green:BRAND.line}).padding(0).onClick(() => {this.ssidAction='group';if(!this.ssidGroupInput && this.dashboard.groups.length>0){this.ssidGroupInput=this.dashboard.groups[0].tag;this.ssidOutboundInput=this.dashboard.groups[0].selected || (this.dashboard.groups[0].items.length>0?this.dashboard.groups[0].items[0].tag:'');}})
       Button('暂停').layoutWeight(1).height(32).fontSize(12).fontWeight(this.ssidAction==='pause'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.ssidAction==='pause'?BRAND.coral:BRAND.surface).fontColor(this.ssidAction==='pause'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.ssidAction==='pause'?BRAND.coral:BRAND.line}).padding(0).onClick(() => {this.ssidAction='pause';})
      }.width('100%')

      // Dynamic Secondary Controls
      if(this.ssidAction==='mode'){
       Flex({wrap:FlexWrap.Wrap}) {
        ForEach(this.availableModes(),(mode: string) => {
         Text(mode)
          .fontSize(11)
          .fontWeight(this.ssidModeInput===mode?FontWeight.Bold:FontWeight.Medium)
          .fontColor(this.ssidModeInput===mode?BRAND.onAccent:BRAND.cyan)
          .backgroundColor(this.ssidModeInput===mode?BRAND.cyan:BRAND.elevated)
          .borderRadius(14)
          .border({width:1,color:this.ssidModeInput===mode?BRAND.cyan:BRAND.line})
          .padding({left:12,right:12,top:5,bottom:5})
          .margin({right:6,bottom:6})
          .onClick(() => {this.ssidModeInput=mode;})
        },(mode: string): string => `${mode}-${this.ssidModeInput===mode?1:0}`)
       }.width('100%')
       TextInput({text:this.ssidModeInput,placeholder:'或输入自定义模式名，如 direct'}).height(34).fontSize(12).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.ssidModeInput=value;})
      } else if(this.ssidAction==='group'){
       if(this.dashboard.groups.length>0){
        Text('选择策略组').fontSize(11).fontColor(BRAND.muted).width('100%')
        Flex({wrap:FlexWrap.Wrap}) {
         ForEach(this.dashboard.groups,(group: OutboundGroup) => {
          Text(group.tag)
           .fontSize(11)
           .fontWeight(this.ssidGroupInput===group.tag?FontWeight.Bold:FontWeight.Medium)
           .fontColor(this.ssidGroupInput===group.tag?BRAND.onAccent:BRAND.text)
           .backgroundColor(this.ssidGroupInput===group.tag?BRAND.green:BRAND.elevated)
           .borderRadius(14)
           .border({width:1,color:this.ssidGroupInput===group.tag?BRAND.green:BRAND.line})
           .padding({left:10,right:10,top:5,bottom:5})
           .margin({right:6,bottom:6})
           .onClick(() => {this.ssidGroupInput=group.tag;this.ssidOutboundInput=group.selected || (group.items.length>0?group.items[0].tag:'');})
         },(group: OutboundGroup): string => `${group.tag}-${this.ssidGroupInput===group.tag?1:0}`)
        }.width('100%')
        if(this.selectedSsidGroupItems().length>0){
         Text('选择目标节点').fontSize(11).fontColor(BRAND.muted).width('100%')
         Flex({wrap:FlexWrap.Wrap}) {
          ForEach(this.selectedSsidGroupItems(),(item: GroupItem) => {
           Text(item.tag)
            .fontSize(11)
            .fontWeight(this.ssidOutboundInput===item.tag?FontWeight.Bold:FontWeight.Medium)
            .fontColor(this.ssidOutboundInput===item.tag?BRAND.onAccent:BRAND.cyan)
            .backgroundColor(this.ssidOutboundInput===item.tag?BRAND.cyan:BRAND.elevated)
            .borderRadius(14)
            .border({width:1,color:this.ssidOutboundInput===item.tag?BRAND.cyan:BRAND.line})
            .padding({left:10,right:10,top:5,bottom:5})
            .margin({right:6,bottom:6})
            .onClick(() => {this.ssidOutboundInput=item.tag;})
          },(item: GroupItem): string => `${item.tag}-${this.ssidOutboundInput===item.tag?1:0}`)
         }.width('100%')
        }
       }
       Row({space:8}) {
        TextInput({text:this.ssidGroupInput,placeholder:'策略组（如 Proxy）'}).height(34).fontSize(12).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.ssidGroupInput=value;})
        TextInput({text:this.ssidOutboundInput,placeholder:'节点（如 DIRECT）'}).height(34).fontSize(12).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.ssidOutboundInput=value;})
       }.width('100%')
      } else {
       Text('连入该 Wi-Fi 时自动暂停 VPN 隧道，离开后自动恢复。').fontSize(11).fontColor(BRAND.muted).width('100%')
      }

      Button('+ 添加策略').height(36).fontSize(12).borderRadius(10).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).width('100%').onClick(() => {this.addSsidPolicyRule();})
     }.padding(12).width('100%').backgroundColor(BRAND.background).borderRadius(12).border({width:1,color:BRAND.line})

     // Visual SSID Policy Cards
     if(this.settings.ssidPolicies.length===0){
      this.note({value:'暂无 SSID 策略，使用上方构建器快速添加。'})
     } else {
      Column({space:6}) {
       ForEach(this.settings.ssidPolicies,(rule: SsidPolicyRule) => {
        Row({space:8}) {
         SymbolGlyph($r('sys.symbol.wifi')).fontSize(15).fontColor([BRAND.cyan])
         Text(rule.ssid).fontSize(13).fontWeight(FontWeight.Medium).fontColor(BRAND.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
         Text(this.ssidPolicyBadgeLabel(rule))
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ssidPolicyBadgeColor(rule))
          .backgroundColor(BRAND.elevated)
          .borderRadius(8)
          .border({width:1,color:this.ssidPolicyBadgeColor(rule)})
          .padding({left:7,right:7,top:3,bottom:3})
          .maxLines(1)
         Text('×').fontSize(16).fontWeight(FontWeight.Bold).fontColor(BRAND.coral).padding({left:6,right:2,top:2,bottom:2}).onClick(() => {this.removeSsidPolicyRule(rule.ssid);})
        }.width('100%').padding({left:10,right:10,top:9,bottom:9}).backgroundColor(BRAND.background).borderRadius(11).border({width:1,color:BRAND.line})
       },(rule: SsidPolicyRule): string => `${rule.ssid}-${rule.action}-${rule.mode || ''}-${rule.group || ''}-${rule.outbound || ''}`)
      }.width('100%')
     }

     // Secondary Collapsible Batch Text Editor
     Row({space:6}) {
      Text('高级文本编辑').fontSize(12).fontColor(BRAND.muted).layoutWeight(1)
      SymbolGlyph(this.ssidBatchExpanded?$r('sys.symbol.chevron_down'):$r('sys.symbol.chevron_right')).fontSize(12).fontColor([BRAND.muted])
     }.width('100%').padding({top:4,bottom:2}).onClick(() => {this.ssidBatchExpanded=!this.ssidBatchExpanded;})
     if(this.ssidBatchExpanded){
      TextArea({text:this.ssidPoliciesText,placeholder:'HomeWiFi = mode:direct\nHomeWiFi = group:Proxy:DIRECT\nOfficeWiFi = pause'}).height(96).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.ssidPoliciesText=value;})
      Button('保存文本策略').height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {this.saveSsidPolicies();})
     }
    }
   }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})

   // Group 3: Local Module Overrides
   this.sectionHeader('本地模块覆写（不改原始订阅）')
   Column({space:12}) {
    Row(){
     Column({space:2}){Text('启用本地覆写').fontSize(14).fontColor(BRAND.text);Text(this.overridesSummary()).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => {this.overridesExpanded=!this.overridesExpanded;})
     Toggle({type:ToggleType.Switch,isOn:this.localOverrides.enabled}).onChange((value: boolean) => {if(value!==this.localOverrides.enabled){this.toggleLocalOverridesEnabled(value);}})
    }.width('100%')
    Button(this.overridesExpanded?'收起规则与 Host 构建器':'管理置顶规则与 Host 映射').height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {this.overridesExpanded=!this.overridesExpanded;})
    if(this.overridesExpanded){
     // Graphical Quick-Add Rule Builder
     Column({space:10}) {
      // Rule Type Selector (3 capsule pills)
      Row({space:6}) {
       Button('域名 (DOMAIN)').layoutWeight(1).height(32).fontSize(11).fontWeight(this.overrideRuleType==='domain'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideRuleType==='domain'?BRAND.cyan:BRAND.surface).fontColor(this.overrideRuleType==='domain'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.overrideRuleType==='domain'?BRAND.cyan:BRAND.line}).padding(0).onClick(() => {this.overrideRuleType='domain';})
       Button('网段 (CIDR)').layoutWeight(1).height(32).fontSize(11).fontWeight(this.overrideRuleType==='cidr'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideRuleType==='cidr'?BRAND.cyan:BRAND.surface).fontColor(this.overrideRuleType==='cidr'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.overrideRuleType==='cidr'?BRAND.cyan:BRAND.line}).padding(0).onClick(() => {this.overrideRuleType='cidr';})
       Button('Host 映射').layoutWeight(1).height(32).fontSize(11).fontWeight(this.overrideRuleType==='host'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideRuleType==='host'?BRAND.amber:BRAND.surface).fontColor(this.overrideRuleType==='host'?BRAND.onAccent:BRAND.muted).borderRadius(16).border({width:1,color:this.overrideRuleType==='host'?BRAND.amber:BRAND.line}).padding(0).onClick(() => {this.overrideRuleType='host';})
      }.width('100%')

      if(this.overrideRuleType==='domain' || this.overrideRuleType==='cidr'){
       // Policy Action Selector (3 colored capsule pills)
       Row({space:6}) {
        Button('直连 DIRECT').layoutWeight(1).height(30).fontSize(11).fontWeight(this.overrideAction==='direct'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideAction==='direct'?BRAND.green:BRAND.surface).fontColor(this.overrideAction==='direct'?BRAND.onAccent:BRAND.green).borderRadius(15).border({width:1,color:this.overrideAction==='direct'?BRAND.green:BRAND.line}).padding(0).onClick(() => {this.overrideAction='direct';})
        Button('代理 PROXY').layoutWeight(1).height(30).fontSize(11).fontWeight(this.overrideAction==='proxy'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideAction==='proxy'?BRAND.cyan:BRAND.surface).fontColor(this.overrideAction==='proxy'?BRAND.onAccent:BRAND.cyan).borderRadius(15).border({width:1,color:this.overrideAction==='proxy'?BRAND.cyan:BRAND.line}).padding(0).onClick(() => {this.overrideAction='proxy';})
        Button('拒绝 REJECT').layoutWeight(1).height(30).fontSize(11).fontWeight(this.overrideAction==='reject'?FontWeight.Bold:FontWeight.Medium).backgroundColor(this.overrideAction==='reject'?BRAND.coral:BRAND.surface).fontColor(this.overrideAction==='reject'?BRAND.onAccent:BRAND.coral).borderRadius(15).border({width:1,color:this.overrideAction==='reject'?BRAND.coral:BRAND.line}).padding(0).onClick(() => {this.overrideAction='reject';})
       }.width('100%')
       Row({space:8}) {
        TextInput({text:this.overrideTargetInput,placeholder:this.overrideRuleType==='domain'?'example.com':'192.168.1.0/24'}).height(38).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.overrideTargetInput=value;})
        Button('+ 添加').height(38).fontSize(12).borderRadius(10).padding({left:14,right:14}).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).onClick(() => {this.addLocalOverrideRule();})
       }.width('100%')
      } else {
       Row({space:8}) {
        TextInput({text:this.overrideHostDomainInput,placeholder:'nas.home'}).height(38).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.overrideHostDomainInput=value;})
        TextInput({text:this.overrideHostIpInput,placeholder:'192.168.1.10'}).height(38).layoutWeight(1).backgroundColor(BRAND.surface).borderRadius(10).onChange((value: string) => {this.overrideHostIpInput=value;})
       }.width('100%')
       Button('+ 添加').height(36).fontSize(12).borderRadius(10).backgroundColor(BRAND.cyan).fontColor(BRAND.onAccent).fontWeight(FontWeight.Bold).width('100%').onClick(() => {this.addLocalOverrideRule();})
      }
     }.padding(12).width('100%').backgroundColor(BRAND.background).borderRadius(12).border({width:1,color:BRAND.line})

     // Visual Rule Cards
     if(this.overrideRuleItems().length===0){
      this.note({value:'暂无本地覆写规则，使用上方构建器快速添加。'})
     } else {
      Column({space:6}) {
       ForEach(this.overrideRuleItems(),(rule: OverrideRuleItem) => {
        Row({space:6}) {
         Text(rule.badge)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(rule.badgeColor)
          .backgroundColor(BRAND.elevated)
          .borderRadius(7)
          .border({width:1,color:rule.badgeColor})
          .padding({left:7,right:7,top:2,bottom:2})
         if(rule.typeTag){
          Text(rule.typeTag)
           .fontSize(9)
           .fontWeight(FontWeight.Medium)
           .fontColor(BRAND.muted)
           .backgroundColor(BRAND.soft)
           .borderRadius(6)
           .padding({left:5,right:5,top:2,bottom:2})
         }
         Text(rule.target)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(BRAND.text)
          .maxLines(1)
          .textOverflow({overflow:TextOverflow.Ellipsis})
          .layoutWeight(1)
         Text('×').fontSize(16).fontWeight(FontWeight.Bold).fontColor(BRAND.coral).padding({left:6,right:2,top:2,bottom:2}).onClick(() => {this.removeLocalOverrideRule(rule);})
        }.width('100%').padding({left:10,right:10,top:8,bottom:8}).backgroundColor(BRAND.background).borderRadius(11).border({width:1,color:BRAND.line})
       },(rule: OverrideRuleItem): string => rule.key)
      }.width('100%')
     }

     // Secondary Collapsible Batch Text Editor
     Row({space:6}) {
      Text('批量文本编辑').fontSize(12).fontColor(BRAND.muted).layoutWeight(1)
      SymbolGlyph(this.overrideBatchExpanded?$r('sys.symbol.chevron_down'):$r('sys.symbol.chevron_right')).fontSize(12).fontColor([BRAND.muted])
     }.width('100%').padding({top:4,bottom:2}).onClick(() => {this.overrideBatchExpanded=!this.overrideBatchExpanded;})
     if(this.overrideBatchExpanded){
      Text('置顶直连域名').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideDirectText,placeholder:'internal.company.com'}).height(60).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideDirectText=value;})
      Text('置顶代理域名').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideProxyText,placeholder:'api.example.com'}).height(60).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideProxyText=value;})
      Text('置顶拒绝域名').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideRejectText,placeholder:'ads.example.com'}).height(60).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideRejectText=value;})
      Text('置顶直连网段 (CIDR)').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideDirectCidrText,placeholder:'192.168.1.0/24'}).height(56).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideDirectCidrText=value;})
      Text('置顶代理网段 (CIDR)').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideProxyCidrText,placeholder:'10.20.0.0/16'}).height(56).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideProxyCidrText=value;})
      Text('置顶拒绝网段 (CIDR)').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideRejectCidrText,placeholder:'203.0.113.0/24'}).height(56).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideRejectCidrText=value;})
      Text('静态 Host 映射（domain = ip）').fontSize(11).fontColor(BRAND.muted).width('100%')
      TextArea({text:this.overrideHostsText,placeholder:'nas.home = 192.168.1.10'}).height(68).fontFamily('monospace').fontSize(11).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.overrideHostsText=value;})
      Button('保存批量编辑（重连生效）').height(36).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {this.saveLocalOverridesForm();})
     }
    }
   }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})

   // Group 4: Per-App Scope & Background Subscriptions
   this.sectionHeader('分应用范围与后台更新')
   Column({space:12}) {
    Row(){
     Column({space:2}){Text('分应用 VPN 范围').fontSize(14).fontColor(BRAND.text);Text(this.scopeSummary()).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     SymbolGlyph(this.applicationScopeExpanded?$r('sys.symbol.chevron_down'):$r('sys.symbol.chevron_right')).fontSize(14).fontColor([BRAND.muted])
    }.width('100%').onClick(() => {this.applicationScopeExpanded=!this.applicationScopeExpanded;})
    if(this.applicationScopeExpanded){
     Select([{value:'所有应用'},{value:'仅指定应用'},{value:'排除指定应用'}]).value(this.applicationScope.mode==='include'?'仅指定应用':this.applicationScope.mode==='exclude'?'排除指定应用':'所有应用').onSelect((index: number) => {this.applicationScope={mode:['all','include','exclude'][index],applications:this.applicationScope.applications};})
     if(this.applicationScope.mode!=='all'){
      Column({space:8}) {
       ForEach(APP_SCOPE_PRESETS,(category: AppPresetCategory) => {
        Column({space:5}) {
         Text(category.title).fontSize(11).fontWeight(FontWeight.Medium).fontColor(BRAND.muted).width('100%')
         Flex({wrap:FlexWrap.Wrap}) {
          ForEach(category.items,(item: AppPresetItem) => {
           Text(item.label)
            .fontSize(11)
            .fontWeight(this.currentScopePackages().includes(item.bundleName)?FontWeight.Bold:FontWeight.Medium)
            .fontColor(this.currentScopePackages().includes(item.bundleName)?BRAND.onAccent:BRAND.cyan)
            .backgroundColor(this.currentScopePackages().includes(item.bundleName)?BRAND.cyan:BRAND.elevated)
            .borderRadius(12)
            .border({width:1,color:this.currentScopePackages().includes(item.bundleName)?BRAND.cyan:BRAND.line})
            .padding({left:10,right:10,top:5,bottom:5})
            .margin({right:6,bottom:6})
            .onClick(() => {this.togglePresetApp(item.bundleName);})
          },(item: AppPresetItem): string => `${item.bundleName}-${this.currentScopePackages().includes(item.bundleName)?1:0}`)
         }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
       },(category: AppPresetCategory): string => `${category.title}-${this.applicationScopeText}`)
      }.padding(10).width('100%').backgroundColor(BRAND.background).borderRadius(10).border({width:1,color:BRAND.line})
      TextArea({text:this.applicationScopeText,placeholder:'每行一个应用包名，例如 com.example.app'}).height(96).backgroundColor(BRAND.background).borderRadius(10).onChange((value: string) => {this.applicationScopeText=value;})
     }
     Button('保存应用范围').height(34).fontSize(12).borderRadius(10).backgroundColor(BRAND.soft).fontColor(BRAND.cyan).width('100%').onClick(() => {this.saveApplicationScope();})
    }
    Divider().color(BRAND.line)
    Row(){
     Column({space:2}){Text('系统后台订阅更新').fontSize(14).fontColor(BRAND.text);Text(this.scheduleStatus.message).fontSize(11).fontColor(BRAND.muted)}.alignItems(HorizontalAlign.Start).layoutWeight(1)
     Toggle({type:ToggleType.Switch,isOn:this.settings.backgroundUpdates}).onChange((value: boolean) => {this.settings.backgroundUpdates=value;this.saveOptions();this.syncUpdates();})
    }.width('100%')
    if(this.updateReport.updatedAt>0){
     this.note({value:`上次检查：${new Date(this.updateReport.updatedAt).toLocaleString()} · ${this.updateReport.source==='background'?'系统后台':'前台'} · 更新 ${this.updateReport.updated} / 失败 ${this.updateReport.failed}`})
    }
   }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})

   // Group 5: Diagnostics & About
   this.sectionHeader('内核与关于')
   Column({space:12}) {
    Row(){
     Text('日志级别').fontSize(14).fontColor(BRAND.text).layoutWeight(1)
     Select([{value:'warn'},{value:'info'},{value:'debug'},{value:'error'}]).value(this.settings.logLevel).onSelect((_index: number,value?: string) => {this.settings.logLevel=value || 'warn';this.saveOptions();})
    }.width('100%')
    Divider().color(BRAND.line)
    Text(`熊盒 VPN 1.0.0 · ${this.coreVersion}`).fontSize(12).fontColor(BRAND.muted).width('100%')
    Text('配置、覆写与日志均采用 0600 私有存储，仅保存在本机。').fontSize(11).fontColor(BRAND.muted).width('100%')
   }.padding(16).width('100%').backgroundColor(BRAND.surface).borderRadius(18).border({width:1,color:BRAND.line})
  }.width('100%')
 }

 @Builder private policyScrollPane() {
  Refresh({refreshing:$$this.refreshingPolicy}) {
   Scroll() {
    this.groupsPage()
   }.width('100%').height('100%').align(Alignment.Top)
  }.width('100%').height('100%').onRefreshing(() => {this.refreshPolicyDelays();})
 }

 @Builder private railItem(index: number,label: string,icon: Resource,activeIcon: Resource) {
  Column({space:4}) {
   SymbolGlyph(this.activeTab===index?activeIcon:icon).fontSize(20).fontColor([this.activeTab===index?BRAND.cyan:BRAND.muted])
   Text(label).fontSize(11).fontWeight(this.activeTab===index?FontWeight.Bold:FontWeight.Medium).fontColor(this.activeTab===index?BRAND.cyan:BRAND.muted)
  }
  .width(56)
  .padding({top:10,bottom:10})
  .backgroundColor(this.activeTab===index?BRAND.elevated:Color.Transparent)
  .borderRadius(14)
  .justifyContent(FlexAlign.Center)
  .onClick(() => {this.activeTab=index;this.readStatus();})
 }

 @Builder private tabItem(index: number,label: string,icon: Resource,activeIcon: Resource) {
  Column({space:4}) {
   SymbolGlyph(this.activeTab===index?activeIcon:icon).fontSize(20).fontColor([this.activeTab===index?BRAND.cyan:BRAND.muted])
   Text(label).fontSize(11).fontWeight(this.activeTab===index?FontWeight.Bold:FontWeight.Medium).fontColor(this.activeTab===index?BRAND.cyan:BRAND.muted)
  }.padding({top:8,bottom:6}).justifyContent(FlexAlign.Center).width('100%')
 }

 build() {
  WithTheme({theme:BEAR_THEME,colorMode:ThemeColorMode.DARK}) {
   Stack({alignContent:Alignment.Top}) {
    if(this.windowIsWide){
     // Mate XTs Wide-Screen Master-Detail Layout: Rail (72vp) + Overview Console (380vp) + Flexible Workspace
     Row() {
      Column({space:10}) {
       this.railItem(0,'总览',$r('sys.symbol.house'),$r('sys.symbol.house_fill'))
       this.railItem(1,'策略',$r('sys.symbol.dot_grid_2x2'),$r('sys.symbol.dot_grid_2x2'))
       this.railItem(2,'活动',$r('sys.symbol.waveform'),$r('sys.symbol.waveform'))
       this.railItem(3,'管理',$r('sys.symbol.gearshape'),$r('sys.symbol.gearshape_fill'))
      }
      .width(72)
      .height('100%')
      .padding({top:16,bottom:16})
      .backgroundColor(BRAND.surface)
      .border({width:{right:1},color:BRAND.line})
      .alignItems(HorizontalAlign.Center)

      Column() {
       Scroll(){this.overview()}.width('100%').height('100%').align(Alignment.Top)
      }
      .width(380)
      .height('100%')
      .border({width:{right:1},color:BRAND.line})

      Column() {
       if(this.activeTab===2){
        Scroll(){this.activityPage()}.width('100%').height('100%').align(Alignment.Top)
       } else if(this.activeTab===3){
        Scroll(){this.managePage()}.width('100%').height('100%').align(Alignment.Top)
       } else {
        this.policyScrollPane()
       }
      }
      .layoutWeight(1)
      .height('100%')
     }.width('100%').height('100%')
    } else {
     Column() {
      Tabs({index:this.activeTab,barPosition:BarPosition.End}) {
       TabContent(){Scroll(){this.overview()}.width('100%').height('100%').align(Alignment.Top)}.tabBar(this.tabItem(0,'总览',$r('sys.symbol.house'),$r('sys.symbol.house_fill')))
       TabContent(){this.policyScrollPane()}.tabBar(this.tabItem(1,'策略',$r('sys.symbol.dot_grid_2x2'),$r('sys.symbol.dot_grid_2x2')))
       TabContent(){Scroll(){this.activityPage()}.width('100%').height('100%').align(Alignment.Top)}.tabBar(this.tabItem(2,'活动',$r('sys.symbol.waveform'),$r('sys.symbol.waveform')))
       TabContent(){Scroll(){this.managePage()}.width('100%').height('100%').align(Alignment.Top)}.tabBar(this.tabItem(3,'管理',$r('sys.symbol.gearshape'),$r('sys.symbol.gearshape_fill')))
      }.barMode(BarMode.Fixed).barHeight(56).barBackgroundColor(BRAND.surface).scrollable(false).onChange((index: number) => {this.activeTab=index;this.readStatus();}).layoutWeight(1)
     }.width('100%').height('100%')
    }

    // Non-shifting Floating Top Toast Pill
    if(this.message){
     Row({space:8}) {
      Circle().width(6).height(6).fill(BRAND.cyan)
      Text(this.message).fontSize(12).fontWeight(FontWeight.Medium).fontColor(BRAND.text).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
      Text('×').fontSize(15).fontColor(BRAND.muted).padding({left:4})
     }
     .padding({left:14,right:12,top:10,bottom:10})
     .margin({top:8,left:16,right:16})
     .constraintSize({maxWidth:760})
     .backgroundColor(BRAND.elevated)
     .borderRadius(14)
     .border({width:1,color:BRAND.cyan})
     .shadow({radius:16,color:'#88000000',offsetY:6})
     .onClick(() => {this.showToast('');})
    }
   }.width('100%').height('100%').padding({top:this.windowSafeTop,bottom:this.windowSafeBottom,left:this.windowSafeLeft,right:this.windowSafeRight}).backgroundColor(BRAND.background).opacity(this.windowLayoutReady?1:0)
  }
 }
}

interface NoteText {value: string;}
interface OverrideRuleItem {
 key: string;
 badge: string;
 badgeColor: string;
 typeTag: string;
 target: string;
 rawKey: string;
 category: string;
}
