import { common } from '@kit.AbilityKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { RemoteProfileDraft, profileImportLink, parseProfileImportLink } from '../common/ProfileLinks';
import { runNetworkProbes } from '../common/NetworkProbe';
import { backgroundSession } from '../common/BackgroundSession';
import { ScheduleStatus, readScheduleStatus, syncSubscriptionSchedule } from '../common/SubscriptionSchedule';
import { UpdateReport, readUpdateReport, runDueProfileUpdates } from '../common/SubscriptionUpdates';
import { vpnStatusExpired, assessExpiredVpnStatus } from '../common/VpnHealth';
import { VpnScope, defaultVpnScope, loadVpnScope, saveVpnScope } from '../common/VpnScope';
import { parseWifiNames } from '../common/WifiConditions';
import { validShortcutAction, runShortcutAction } from '../common/ShortcutActions';
import bridge from 'libsingboxbridge.so';
import { BUNDLE_NAME, VPN_ABILITY, DIRECT_PROFILE, VpnStatus, CoreResponse, initialStatus, writePrivate, readPrivate } from '../common/Store';
import { SavedProfile, ProfileLibrary, AppSettings, ProfileFetchCancellation, defaultSettings, loadSettings, saveSettings, loadLibrary, setAutoUpdate, addProfile, readProfile, selectProfile, removeProfile, editProfile, fetchProfile, refreshProfile } from '../common/ProfileStore';
import { OutboundGroup, GroupItem, ConnectionInfo, DashboardData, WireGuardInfo, WireGuardPeer, emptyDashboard, readDashboard, sendControl } from '../common/Control';

function bytesLabel(value: number): string {
 if(value>=1073741824){return `${(value/1073741824).toFixed(2)} GB`;}
 if(value>=1048576){return `${(value/1048576).toFixed(1)} MB`;}
 return `${(value/1024).toFixed(1)} KB`;
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
 @State private activeTab: number=0;
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
 @State private wifiRulesText: string='';
 @State private sharedCode: string='';
 @StorageLink('pendingRemoteProfile') @Watch('consumePendingLink') private pendingRemoteProfile: string='';
 @StorageLink('pendingShortcut') @Watch('consumeShortcut') private pendingShortcut: string='';
 private shortcutHandling: boolean=false;
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
 private observer?: vpnExtension.VpnObserver;
 private timer: number=-1;
 private context: common.UIAbilityContext=this.getUIContext().getHostContext() as common.UIAbilityContext;

 aboutToAppear(): void {
  this.pageVisible=true;
  backgroundSession.initialize(this.context);
  this.scheduleStatus=readScheduleStatus(this.context.filesDir);
  this.settings=loadSettings(this.context.filesDir);
  try {this.applicationScope=loadVpnScope(this.context.filesDir);this.applicationScopeText=this.applicationScope.applications.join('\n');} catch(_error) {this.message='应用范围设置无法读取，请重新保存';}
  this.wifiRulesText=this.settings.bypassWifi.join('\n');
  this.allowAutomaticConnect=!this.pendingShortcut;
  this.consumePendingLink();
  try {this.library=loadLibrary(this.context.filesDir);} catch(_error) {this.message='配置索引读取失败，原文件已保留';}
  this.dashboard=readDashboard(this.context.filesDir);
  try {
   this.observer=vpnExtension.createVpnObserver();
   this.observer.onAuthorizationResult((allowed: boolean) => {
    if(!allowed){this.waitingSince=0;this.status=initialStatus();this.message='已取消系统 VPN 授权';}
    if(!allowed){backgroundSession.stop('VPN 授权被取消，定位辅助已释放');}
   });
  } catch(_error) {}
  bridge.version().then((value: string) => {this.coreVersion=value;}).catch(() => {this.coreVersion='内核加载失败';});
  this.readStatus();
  this.updateForeground();this.syncUpdates();
  this.reconcileInitialStatus();
 }
 aboutToDisappear(): void {
  this.pageVisible=false;
  backgroundSession.stop();
  if(this.timer!==-1){clearInterval(this.timer);this.timer=-1;}
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
    this.status=assessExpiredVpnStatus(latest,undefined);
    if(!this.healthChecking && Date.now()-this.lastHealthCheck>=5000){this.verifyExpiredStatus(latest);}
    return;
   }
   if(latest.updatedAt>=this.waitingSince){
    if(latest.updatedAt>this.lastTrafficTime){
     const seconds: number=(latest.updatedAt-this.lastTrafficTime)/1000;
     this.uploadRate=this.lastTrafficTime>0?Math.max(0,((latest.uplink || 0)-this.lastUpload)/seconds):0;
     this.downloadRate=this.lastTrafficTime>0?Math.max(0,((latest.downlink || 0)-this.lastDownload)/seconds):0;
     this.lastTrafficTime=latest.updatedAt;this.lastUpload=latest.uplink || 0;this.lastDownload=latest.downlink || 0;
    }
    if(latest.phase!=='running'){this.uploadRate=0;this.downloadRate=0;}
    this.status=latest;
   }
  } catch(_error) {}
  if(this.waitingSince>0 && this.status.phase==='starting' && Date.now()-this.waitingSince>60000){
   this.status=initialStatus();this.status.message='等待授权超时，可重新连接';this.waitingSince=0;
  }
  if(this.status.phase==='running' && this.activeTab!==1){
   writePrivate(`${this.context.filesDir}/dashboard-demand.json`,JSON.stringify({updatedAt:Date.now()}));
   this.dashboard=readDashboard(this.context.filesDir);
  }
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
   if(current.updatedAt===snapshot.updatedAt && this.waitingSince<=snapshot.updatedAt){this.status=assessExpiredVpnStatus(current,exists);}
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
 private async disconnectVpn(): Promise<void> {
  this.allowAutomaticConnect=false;
  await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
  await backgroundSession.stop();
  this.waitingSince=0;this.status=initialStatus();this.status.message='VPN 已停止';
  writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));this.message='已断开';
 }
 private async toggle(automatic: boolean=false): Promise<void> {
  if(!automatic){this.allowAutomaticConnect=false;}
  this.probeGeneration++;this.probeResult='';this.probing=false;this.busy=true;
  try {
   if(this.active()){
    await this.disconnectVpn();
   } else {
    if(!this.library.selected){this.activeTab=1;this.message='请先导入配置';return;}
    const content: string=readProfile(this.context.filesDir,this.library.selected);
    const check: CoreResponse=JSON.parse(await bridge.check(content)) as CoreResponse;
    if(!check.ok){this.message='配置未通过内核校验，请编辑配置后重试';return;}
    writePrivate(`${this.context.filesDir}/profile.json`,content);
    this.status={phase:'starting',message:'等待系统 VPN 授权',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};
    this.waitingSince=this.status.updatedAt;
    await backgroundSession.beginSession();
    await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});this.message='正在连接';
   }
  } catch(_error) {await backgroundSession.stop();this.message='操作未完成，请检查系统 VPN 授权';this.waitingSince=0;this.status=initialStatus();writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));}
  finally {this.busy=false;}
 }
 private async control(action: string,group: string='',outbound: string='',id: string='',mode: string=''): Promise<void> {
  if(this.controlBusy){return;}this.controlBusy=true;
  if(action==='reconnect'){this.busy=true;}
  if(action==='wg-probe'){this.message='正在检查回家通道与家庭 DNS…';}
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
    await backgroundSession.beginSession();await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});this.message='正在重新连接';
   }else {this.message=await sendControl(this.context.filesDir,action,group,outbound,id,mode);}
  }
  catch(_error) {this.message='操作未完成，请确认 VPN 处于连接状态';}
  finally {this.controlBusy=false;if(action==='reconnect'){this.busy=false;}}
 }
 private async probe(): Promise<void> {
  const generation: number=++this.probeGeneration;
  const profileId: string=this.library.selected;
  let timeout: number=-1;
  this.probing=true;this.probeResult='正在检查连接…';
  try {
   let content: string='';try {content=readPrivate(`${this.context.filesDir}/running-profile.json`);} catch(_error) {content=readProfile(this.context.filesDir,profileId);}
   const result: string=await Promise.race([runNetworkProbes(content),new Promise<string>((resolve) => {timeout=setTimeout(() => {resolve('连接检查超时，请检查当前配置的 DNS 与出站');},8000);})]);
   writePrivate(`${this.context.filesDir}/network-probe.json`,JSON.stringify({updatedAt:Date.now(),profileId:profileId,result:result,cancelled:generation!==this.probeGeneration}));
   if(generation===this.probeGeneration){this.probeResult=result;}
  }
  catch(_error) {if(generation===this.probeGeneration){this.probeResult='连接检查未完成';}}
  finally {if(timeout!==-1){clearTimeout(timeout);}if(generation===this.probeGeneration){this.probing=false;}}
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
   this.message='配置已导入并通过内核校验';
  } catch(_error) {this.message='导入未完成，请检查文件格式和大小（不超过 1 MiB）';}
  finally {this.busy=false;}
 }
 private async pasteProfile(): Promise<void> {
  try {
   const data: pasteboard.PasteData=await pasteboard.getSystemPasteboard().getData();
   this.acceptImportText(data.getPrimaryText());
  } catch(_error) {this.message='未能读取剪贴板，请允许访问或手动粘贴';}
 }
 private consumePendingLink(): void {
  if(!this.pendingRemoteProfile){return;}
  try {
   const draft: RemoteProfileDraft=JSON.parse(this.pendingRemoteProfile) as RemoteProfileDraft;
   this.acceptImportText(profileImportLink(draft.name,draft.url));
  } catch(_error) {this.message='导入链接无效';}
  this.pendingRemoteProfile='';
 }
 private acceptImportText(text: string): void {
  this.allowAutomaticConnect=false;this.activeTab=1;
  if(text.trim().startsWith('{')){
   if(new util.TextEncoder().encodeInto(text).length>1048576){throw new Error('配置过大');}
   this.editingId='';this.editorContent=text;this.editorName='导入配置';this.editorVisible=true;
  } else {
   const draft: RemoteProfileDraft=parseProfileImportLink(text);
   this.remoteURL=draft.url;this.editorName=draft.name;this.editorVisible=false;
  }
  this.message=this.active()?'已填入导入草稿，请断开 VPN 后确认导入':'已填入导入草稿，请校验保存或下载后导入';
 }
 private async scanProfile(): Promise<void> {
  this.busy=true;
  try {const result: scanBarcode.ScanResult=await scanBarcode.startScanForResult(this.context,{scanTypes:[scanCore.ScanType.QR_CODE],enableMultiMode:false,enableAlbum:true});this.acceptImportText(result.originalValue);}
  catch(_error) {this.message='未完成扫码，现有配置未改变';}
  finally {this.busy=false;}
 }
 private showProfileCode(record: SavedProfile): void {
  try {
   const code: string=profileImportLink(record.name,record.url);
   if(new util.TextEncoder().encodeInto(code).length>1800){this.message='链接较长，请使用文件导出';return;}
   this.sharedCode=code;
  } catch(_error) {this.message='只有远程配置可以生成导入链接二维码';}
 }
 private async importRemote(): Promise<void> {
  this.busy=true;
  try {
   const content: string=await fetchProfile(this.remoteURL.trim());
   this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '远程配置',content,this.remoteURL.trim());
   this.remoteURL='';this.message='远程配置已导入';this.syncUpdates();
  } catch(_error) {this.message='下载或校验失败，原配置已保留';}
  finally {this.busy=false;}
 }
 private async saveEditor(): Promise<void> {
  this.busy=true;
  try {
   if(this.editingId){this.library=await editProfile(this.context.filesDir,this.library,this.editingId,this.editorName,this.editorContent);}
   else {this.library=await addProfile(this.context.filesDir,this.library,this.editorName,this.editorContent);}
   this.editorVisible=false;this.editorContent='';this.message='配置已保存并通过内核校验';this.syncUpdates();
  } catch(_error) {this.message='保存未完成，请检查 JSON 和协议字段；原配置已保留';}
  finally {this.busy=false;}
 }
 private edit(record: SavedProfile): void {
  this.editingId=record.id;this.editorName=record.name;this.editorContent=readProfile(this.context.filesDir,record.id);this.editorVisible=true;
 }
 private choose(record: SavedProfile): void {
  try {this.library=selectProfile(this.context.filesDir,this.library,record.id);this.probeResult='';this.dashboard=emptyDashboard();this.message='已选择配置';}
  catch(_error) {this.message='切换未完成，原配置已保留';}
 }
 private deleteProfile(record: SavedProfile): void {
  AlertDialog.show({title:'删除配置',message:`删除“${record.name}”？`,primaryButton:{value:'取消',action:() => {}},secondaryButton:{value:'删除',action:() => {try {this.library=removeProfile(this.context.filesDir,this.library,record.id);this.message='已删除配置';this.syncUpdates();} catch(_error) {this.message='请先切换到其他配置';}}}});
 }
 private async refresh(record: SavedProfile): Promise<void> {
  this.busy=true;
  try {await refreshProfile(this.context.filesDir,this.library,record.id);this.library=loadLibrary(this.context.filesDir);this.message=this.active()?'配置已更新，手动重连后应用':'配置已更新';}
  catch(_error) {this.message='更新失败，已保留原配置';}
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
  backgroundSession.onForeground();
  this.readStatus();
  if(this.timer===-1){this.timer=setInterval(() => {this.readStatus();this.autoUpdateProfiles();},1000);}
  this.syncUpdates();
 }
 private async syncUpdates(): Promise<void> {this.scheduleStatus=await syncSubscriptionSchedule(this.context.filesDir);this.updateReport=readUpdateReport(this.context.filesDir);}
 private setUpdateHours(record: SavedProfile,hours: number): void {
  try {this.library=setAutoUpdate(this.context.filesDir,record.id,hours);this.syncUpdates();} catch(_error) {this.message='未能保存自动更新设置';}
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
   this.message='已导出到所选位置';
  } catch(_error) {this.message='导出未完成';}
  finally {this.busy=false;}
 }
 private saveOptions(): void {saveSettings(this.context.filesDir,this.settings);this.message='设置已保存';}
 private saveApplicationScope(): void {
  try {this.applicationScope=saveVpnScope(this.context.filesDir,this.applicationScope.mode,this.applicationScopeText);this.applicationScopeText=this.applicationScope.applications.join('\n');this.message='应用范围已保存，下次连接时应用';}
  catch(_error) {this.message='保存未完成，请填写 1 至 256 个有效包名，每行一个';}
 }
 private locationOptions(value: boolean): AppSettings {
  return {autoReconnect:this.settings.autoReconnect,autoConnect:this.settings.autoConnect,logLevel:this.settings.logLevel,onDemand:this.settings.onDemand,bypassWifi:this.settings.bypassWifi,locationAssist:value,backgroundUpdates:this.settings.backgroundUpdates};
 }
 private async toggleLocationAssist(value: boolean): Promise<void> {
  if(this.locationChanging){return;}this.locationChanging=true;
  try {
   if(value && !await backgroundSession.requestPermission()){this.settings=this.locationOptions(false);saveSettings(this.context.filesDir,this.settings);await backgroundSession.reconfigure();this.message='定位未授权，已保留普通后台运行方式';return;}
   this.settings=this.locationOptions(value);this.saveOptions();
   await backgroundSession.reconfigure();
  } catch(_error) {this.message='定位辅助设置未完成，请检查系统权限';}
  finally {this.locationChanging=false;}
 }
 private visibleConnections(): ConnectionInfo[] {
  const query: string=this.connectionFilter.toLowerCase();
  return this.dashboard.connections.filter((c: ConnectionInfo): boolean => `${c.domain} ${c.destination} ${c.outbound}`.toLowerCase().includes(query));
 }

 @Builder private title(text: string) {Text(text).fontSize(26).fontWeight(FontWeight.Bold).fontColor('#17324D').width('100%')}
 // Object-literal argument keeps dynamic text bound by reference in ArkUI.
 @Builder private note(params: NoteText) {Text(params.value).fontSize(13).fontColor('#657687').width('100%')}
 @Builder private overview() {
  Column({space:18}) {
   this.title('熊盒 VPN')
   this.note({value:this.coreVersion})
   Column({space:14}) {
    Text(this.status.phase==='running'?'已连接':this.status.phase==='checking'?'状态待确认':this.status.phase==='paused'?'已暂停':this.status.phase==='reconnecting'?'等待重连':this.status.phase==='starting'?'连接中':'未连接').fontSize(28).fontWeight(FontWeight.Medium)
    Text(this.status.message).fontSize(14).fontColor('#657687')
    Text(this.selectedName()).fontSize(16).fontWeight(FontWeight.Medium)
    if(this.status.phase==='running'){
     this.note({value:`${this.status.networkType || ''} · ${this.status.physicalIPv6Available?'基础网络支持 IPv6':'基础网络未报告 IPv6'}`})
     this.note({value:`IPv4 + IPv6 · MTU 1280 · ${this.status.tunName}`})
     Text(`↑ ${bytesLabel(this.uploadRate)}/s     ↓ ${bytesLabel(this.downloadRate)}/s`).fontSize(18).fontWeight(FontWeight.Medium)
     this.note({value:`累计上行 ${bytesLabel(this.status.uplink || 0)} · 下行 ${bytesLabel(this.status.downlink || 0)}`})
    }
    Button(this.active()?'断开连接':'连接 VPN').width('100%').height(52).backgroundColor('#17324D').enabled(!this.busy).onClick(() => {this.toggle();})
    if(this.status.phase==='running' || this.status.phase==='checking'){
     Row({space:12}) {
      Button('重新连接').layoutWeight(1).enabled(!this.controlBusy && !this.busy).onClick(() => {this.control('reconnect');})
      Button(this.probing?'检查中…':'检查连接').layoutWeight(1).enabled(!this.probing).onClick(() => {this.probe();})
     }.width('100%')
    }
    if(this.probeResult){this.note({value:this.probeResult})}
   }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(22)
   if(this.status.phase==='running'){
    ForEach(this.dashboard.wireGuard,(wg: WireGuardInfo) => {
     Column({space:12}) {
      Text(`回家通道 · ${wg.tag}`).fontSize(20).fontWeight(FontWeight.Medium).width('100%')
      this.note({value:wg.active?'WireGuard 内核已启动':'WireGuard 尚未启动'})
      this.note({value:`家庭目标地址族：${wg.ipv4?'IPv4 ':''}${wg.ipv6?'IPv6':''}`})
      ForEach(wg.peers,(peer: WireGuardPeer) => {
       Text(peer.lastHandshake>0?`Peer ${peer.index} · 最近握手 ${new Date(peer.lastHandshake*1000).toLocaleString()}`:`Peer ${peer.index} · 尚无握手记录`).fontSize(13).width('100%')
       Text(`加密发送 ${bytesLabel(peer.txBytes)} · 接收 ${bytesLabel(peer.rxBytes)}`).fontSize(13).fontColor('#657687').width('100%')
      },(peer: WireGuardPeer): string => `${peer.index}-${peer.lastHandshake}-${peer.txBytes}-${peer.rxBytes}`)
      if(this.status.bindFailure){this.note({value:`底层网络绑定失败次数：${this.status.bindFailure}`})}
      if(wg.dnsConfigured && !wg.dnsCovered){this.note({value:'家庭 DNS 不在 peer 的 AllowedIPs 中，请检查配置。'})}
      Button(this.controlBusy?'检查中…':'检查家庭 DNS').width('100%').enabled(!this.controlBusy && wg.active && wg.dnsConfigured && wg.dnsCovered).onClick(() => {this.control('wg-probe','',wg.tag);})
      if(!wg.dnsConfigured){this.note({value:'该通道未配置可供检查的 UDP DNS，可先查看握手和加密收发计数。'})}
      if(wg.lastProbe){this.note({value:`上次检查：${wg.lastProbe.summary}\n${new Date(wg.lastProbe.updatedAt).toLocaleString()}`})}
     }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(22)
    },(wg: WireGuardInfo): string => `${wg.tag}-${wg.peers.map((peer: WireGuardPeer): string => `${peer.lastHandshake}:${peer.txBytes}:${peer.rxBytes}`).join('|')}-${wg.lastProbe?.updatedAt || 0}`)
   }
   this.note({value:'连接使用所选配置的分流规则；网络切换时按设置自动重连。'})
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 @Builder private profilesPage() {
  Column({space:16}) {
   this.title('配置')
   ForEach(this.library.profiles,(record: SavedProfile) => {
    Column({space:10}) {
     Text(`${record.id===this.library.selected?'● ':''}${record.name}`).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
     this.note({value:`${record.url?'远程配置':'本地配置'} · ${new Date(record.updatedAt).toLocaleString()}`})
     Row({space:8}) {
      Button(record.id===this.library.selected?'当前配置':'选用').fontSize(13).enabled(!this.busy && !this.active() && record.id!==this.library.selected).onClick(() => {this.choose(record);})
      Button('编辑').fontSize(13).enabled(!this.busy && !this.active()).onClick(() => {this.edit(record);})
      Button('导出').fontSize(13).enabled(!this.busy).onClick(() => {this.exportDocument(`${record.name}.json`,readProfile(this.context.filesDir,record.id));})
      if(record.id!==this.library.selected){Button('删除').fontSize(13).enabled(!this.busy && !this.active()).onClick(() => {this.deleteProfile(record);})}
     }.width('100%')
     if(record.url){
      Button('更新配置').width('100%').enabled(!this.busy).onClick(() => {this.refresh(record);})
      Button('显示导入二维码').width('100%').enabled(!this.busy).onClick(() => {this.showProfileCode(record);})
       Row(){Text('自动更新').fontSize(12).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:record.autoUpdateHours>0}).onChange((value: boolean) => {if(value!==(record.autoUpdateHours>0)){this.toggleAutoUpdate(record,value);}})}.width('100%')
       if(record.autoUpdateHours>0){Select([{value:'1 小时'},{value:'6 小时'},{value:'12 小时'},{value:'24 小时'},{value:'7 天'}]).value(record.autoUpdateHours===168?'7 天':`${record.autoUpdateHours} 小时`).onSelect((index: number) => {this.setUpdateHours(record,[1,6,12,24,168][index]);})}
     }
    }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(20)
   },(record: SavedProfile): string => `${record.id}-${record.name}-${record.updatedAt}-${record.autoUpdateHours}-${this.library.selected}`)
   Column({space:12}) {
    TextInput({text:this.editorName,placeholder:'配置名称'}).onChange((value: string) => {this.editorName=value;}).enabled(!this.busy && !this.active())
    Row({space:8}) {
     Button('本地文件').layoutWeight(1).enabled(!this.busy && !this.active()).onClick(() => {this.importFile();})
     Button('剪贴板').layoutWeight(1).enabled(!this.busy && !this.active()).onClick(() => {this.pasteProfile();})
    }.width('100%')
    Button('扫码导入').width('100%').enabled(!this.busy && !this.active()).onClick(() => {this.scanProfile();})
    if(this.sharedCode){
     QRCode(this.sharedCode).width(220).height(220).color('#17324D').backgroundColor(Color.White)
     this.note({value:'二维码包含配置访问链接，请只展示给可信设备。'})
     Button('关闭二维码').width('100%').onClick(() => {this.sharedCode='';})
    }
    TextInput({text:this.remoteURL,placeholder:'远程 sing-box JSON 链接'}).type(InputType.Password).onChange((value: string) => {this.remoteURL=value;}).enabled(!this.busy && !this.active())
    Button('下载并导入').width('100%').enabled(!this.busy && !this.active() && this.remoteURL.length>0).onClick(() => {this.importRemote();})
    Button('新建 JSON 配置').width('100%').enabled(!this.busy && !this.active()).onClick(() => {this.editingId='';this.editorContent='';this.editorVisible=true;})
    Button('添加直连诊断配置').width('100%').enabled(!this.busy && !this.active()).onClick(() => {this.editingId='';this.editorName='直连诊断';this.editorContent=DIRECT_PROFILE;this.editorVisible=true;})
    if(this.editorVisible){
     TextArea({text:this.editorContent,placeholder:'粘贴完整 sing-box JSON'}).height(260).fontFamily('monospace').fontSize(12).maxLength(1048576).enabled(!this.busy && !this.active()).onChange((value: string) => {this.editorContent=value;})
     Button('校验并保存').width('100%').enabled(!this.busy && !this.active()).onClick(() => {this.saveEditor();})
     Button('关闭编辑').width('100%').enabled(!this.busy).onClick(() => {this.editorVisible=false;this.editorContent='';})
    }
    this.note({value:'支持 sing-box JSON，保留节点、WireGuard 和分流规则。导出文件包含节点凭据，请妥善保存。'})
   }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(20)
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 @Builder private groupsPage() {
  Column({space:16}) {
   this.title('节点分组')
   if(this.status.phase!=='running'){this.note({value:'连接 VPN 后查看分组、切换节点和测试延迟。'})}
   else {
    if(this.dashboard.groups.length===0){this.note({value:'正在读取分组；当前配置也可能没有 selector 或 urltest。'})}
    ForEach(this.dashboard.groups,(group: OutboundGroup) => {
     Column({space:10}) {
      Text(group.tag).fontSize(20).fontWeight(FontWeight.Medium).width('100%')
      this.note({value:`${group.type} · 当前：${group.selected}`})
      Button('测试本组延迟').width('100%').enabled(!this.controlBusy).onClick(() => {this.control('urltest','',group.tag);})
      ForEach(group.items,(item: GroupItem) => {
       Row({space:8}) {
        Column({space:4}) {
         Text(`${group.selected===item.tag?'● ':''}${item.tag}`).fontSize(15).width('100%')
         Text(`${item.type} · ${item.urlTestDelay?`${item.urlTestDelay} ms`:'尚无有效延迟'}`).fontSize(12).fontColor('#657687').width('100%')
        }.layoutWeight(1)
        Button('测速').fontSize(12).enabled(!this.controlBusy).onClick(() => {this.control('urltest','',item.tag);})
        if(group.selectable){Button('选择').fontSize(12).enabled(!this.controlBusy && group.selected!==item.tag).onClick(() => {this.control('select',group.tag,item.tag);})}
       }.width('100%').padding({top:8,bottom:8})
      },(item: GroupItem): string => item.tag)
     }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(20)
    },(group: OutboundGroup): string => `${group.tag}-${group.selected}-${group.items.map((item: GroupItem): string => `${item.tag}:${item.urlTestTime || 0}:${item.urlTestDelay || 0}`).join('|')}`)
   }
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 @Builder private connectionsPage() {
  Column({space:14}) {
   this.title('连接')
   if(this.status.phase!=='running'){this.note({value:'连接 VPN 后查看活动连接。'})}
   else {
    TextInput({text:this.connectionFilter,placeholder:'搜索域名、地址或出站'}).onChange((value: string) => {this.connectionFilter=value;})
    this.note({value:`活动连接 ${this.dashboard.connections.length}（最多显示最新 200 条）`})
    Button('关闭全部连接').width('100%').enabled(!this.controlBusy).onClick(() => {this.control('close-all');})
    ForEach(this.visibleConnections(),(item: ConnectionInfo) => {
     Column({space:8}) {
      Text(item.domain || item.destination).fontSize(16).fontWeight(FontWeight.Medium).width('100%').onClick(() => {this.expandedConnection=this.expandedConnection===item.id?'':item.id;})
      this.note({value:`${item.network} · ${item.outbound} · ↑ ${bytesLabel(item.upload)} ↓ ${bytesLabel(item.download)}`})
      if(this.expandedConnection===item.id){this.note({value:`源：${item.source}\n目标：${item.destination}\n规则：${item.rule || '默认路由'}\n建立：${new Date(item.createdAt).toLocaleString()}`})}
      Button('关闭此连接').fontSize(12).enabled(!this.controlBusy).onClick(() => {this.control('close','','',item.id);})
     }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(18)
    },(item: ConnectionInfo): string => `${item.id}-${item.upload}-${item.download}`)
   }
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 @Builder private logsPage() {
  Column({space:14}) {
   this.title('日志')
   this.note({value:this.status.phase==='running'?'内核日志，仅保留本机最近 100 条':'上次运行的日志快照'})
   TextInput({text:this.logFilter,placeholder:'筛选日志内容'}).onChange((value: string) => {this.logFilter=value;})
   Row({space:10}) {
    Button('清空').layoutWeight(1).enabled(this.status.phase==='running' && !this.controlBusy).onClick(() => {this.control('clear-logs');})
    Button('导出日志').layoutWeight(1).enabled(!this.busy).onClick(() => {this.exportDocument('bearbox-logs.txt',this.dashboard.logs.join('\n'));})
   }.width('100%')
   ForEach(this.dashboard.logs.filter((line: string): boolean => line.toLowerCase().includes(this.logFilter.toLowerCase())),(line: string) => {Text(line).fontSize(12).fontFamily('monospace').fontColor('#314456').width('100%').copyOption(CopyOptions.InApp)},(line: string,index: number): string => `${index}-${line}`)
   if(this.dashboard.logs.length===0){this.note({value:'暂无日志。可在设置中调整日志级别后重新连接。'})}
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 @Builder private settingsPage() {
  Column({space:18}) {
   this.title('设置与工具')
   Column({space:16}) {
    Row(){Text('定位辅助驻留（实验）').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.locationAssist}).enabled(!this.locationChanging && !this.busy).onChange((value: boolean) => {if(value!==this.settings.locationAssist){this.toggleLocationAssist(value);}})}.width('100%')
    this.note({value:'默认使用数据传输后台任务。此开关默认关闭，开启后改用低功耗模糊定位；坐标即时丢弃，不保存或上传。两种模式均显示系统通知，仅 VPN 连接期间运行，驻留效果及耗电待实测。'})
    this.note({value:this.backgroundSessionStatus})
    Button(this.applicationScopeExpanded?'收起应用范围':'设置哪些应用使用 VPN').width('100%').onClick(() => {this.applicationScopeExpanded=!this.applicationScopeExpanded;})
    if(this.applicationScopeExpanded){
     Select([{value:'所有应用'},{value:'仅指定应用'},{value:'排除指定应用'}]).value(this.applicationScope.mode==='include'?'仅指定应用':this.applicationScope.mode==='exclude'?'排除指定应用':'所有应用').onSelect((index: number) => {this.applicationScope={mode:['all','include','exclude'][index],applications:this.applicationScope.applications};})
     if(this.applicationScope.mode!=='all'){TextArea({text:this.applicationScopeText,placeholder:'每行一个应用包名，例如 com.example.app'}).height(110).onChange((value: string) => {this.applicationScopeText=value;})}
     Button('保存应用范围').width('100%').onClick(() => {this.saveApplicationScope();})
     this.note({value:'默认接管所有应用。仅指定或排除模式会改变系统引流范围，下次连接生效；应用内分流继续遵循原配置。'})
    }
    Row(){Text('网络切换或掉线后自动重连').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.autoReconnect}).onChange((value: boolean) => {this.settings.autoReconnect=value;this.saveOptions();})}.width('100%')
    Row(){Text('打开 App 时自动连接').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.autoConnect}).onChange((value: boolean) => {this.settings.autoConnect=value;this.saveOptions();})}.width('100%')
    Row(){Text('指定 Wi-Fi 暂停 VPN').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.onDemand}).onChange((value: boolean) => {this.settings.onDemand=value;this.saveOptions();})}.width('100%')
    if(this.settings.onDemand){
     TextArea({text:this.wifiRulesText,placeholder:'每行一个 Wi-Fi 名称，精确匹配'}).height(100).onChange((value: string) => {this.wifiRulesText=value;})
     Button('保存 Wi-Fi 规则').width('100%').onClick(() => {try {this.settings.bypassWifi=parseWifiNames(this.wifiRulesText);this.wifiRulesText=this.settings.bypassWifi.join('\n');this.saveOptions();} catch(_error) {this.message='未保存，请填写有效 Wi-Fi 名称（每行一个，最多 128 个，名称最多 32 字节）';}})
     this.note({value:'服务运行时进入这些 Wi-Fi 会暂停隧道，离开后恢复；系统结束服务后，需要重新打开 App。'})
    }
    this.note({value:this.status.wifiConditionStatus || '连接时读取底层网络的 Wi-Fi 条件。'})
    this.note({value:'导入配置的 wifi_ssid 和网络类型条件参与内核分流及 DNS 规则；暂停列表优先停止整个隧道。Wi-Fi 名称不可读时不沿用旧名称；暂不支持真实 BSSID 条件。'})
    this.note({value:'桌面入口：长按 App 图标使用连接、断开或总览；添加“VPN 快捷入口”服务卡片可直接打开并执行。首次连接仍需系统授权。'})
    Row(){Text('系统后台订阅更新').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.backgroundUpdates}).onChange((value: boolean) => {this.settings.backgroundUpdates=value;this.saveOptions();this.syncUpdates();})}.width('100%')
    this.note({value:this.scheduleStatus.message})
    this.note({value:'后台由系统在有网络时择机更新，可使用蜂窝网络；更新通过校验后保存，手动重连后应用。后台检查间隔至少 2 小时，实际执行可能延后。'})
    if(this.updateReport.updatedAt>0){this.note({value:`上次自动检查：${new Date(this.updateReport.updatedAt).toLocaleString()} · ${this.updateReport.source==='background'?'系统后台':'前台'} · ${this.updateReport.phase==='completed'?`已更新 ${this.updateReport.updated}，失败 ${this.updateReport.failed}`:this.updateReport.phase==='running'?'本轮检查已开始，完成结果待确认':this.updateReport.phase==='cancelled'?'已停止本轮更新':this.updateReport.phase==='busy'?'本轮未取得更新锁':'本轮未完成'}`})}
    Row(){Text('日志级别').layoutWeight(1);Select([{value:'warn'},{value:'info'},{value:'debug'},{value:'error'}]).value(this.settings.logLevel).onSelect((_index: number,value?: string) => {this.settings.logLevel=value || 'warn';this.saveOptions();})}.width('100%')
    this.note({value:'日志级别在下次连接时应用。'})
    Button('重置网络连接与 DNS 缓存').width('100%').enabled(this.status.phase==='running' && !this.controlBusy).onClick(() => {this.control('reset-network');})
    if(this.dashboard.modes.length>0){
     this.note({value:`路由模式：${this.dashboard.mode}`})
     ForEach(this.dashboard.modes,(mode: string) => {Button(mode).width('100%').enabled(this.status.phase==='running' && !this.controlBusy && mode!==this.dashboard.mode).onClick(() => {this.control('mode','','','',mode);})},(mode: string): string => mode)
    }
   }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(20)
   this.note({value:`熊盒 VPN 0.6 · ${this.coreVersion}`})
   this.note({value:'配置和日志仅保存在本机。'})
  }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
 }
 build() {
  Column() {
   Tabs({index:this.activeTab,barPosition:BarPosition.End}) {
    TabContent(){Scroll(){this.overview()}.width('100%').height('100%')}.tabBar('总览')
    TabContent(){Scroll(){this.profilesPage()}.width('100%').height('100%')}.tabBar('配置')
    TabContent(){Scroll(){this.groupsPage()}.width('100%').height('100%')}.tabBar('节点')
    TabContent(){Scroll(){this.connectionsPage()}.width('100%').height('100%')}.tabBar('连接')
    TabContent(){Scroll(){this.logsPage()}.width('100%').height('100%')}.tabBar('日志')
    TabContent(){Scroll(){this.settingsPage()}.width('100%').height('100%')}.tabBar('设置')
   }.barMode(BarMode.Scrollable).scrollable(false).onChange((index: number) => {this.activeTab=index;this.readStatus();}).layoutWeight(1)
   if(this.message){Text(this.message).fontSize(13).fontColor('#314456').padding(12).width('100%').backgroundColor('#E7EEF4')}
  }.width('100%').height('100%').backgroundColor('#F3F6F9')
 }
}

interface NoteText {value: string;}
