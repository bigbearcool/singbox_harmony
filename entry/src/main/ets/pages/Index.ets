import { common } from '@kit.AbilityKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { runNetworkProbes } from '../common/NetworkProbe';
import bridge from 'libsingboxbridge.so';
import { BUNDLE_NAME, VPN_ABILITY, DIRECT_PROFILE, VpnStatus, CoreResponse, initialStatus, writePrivate, readPrivate } from '../common/Store';
import { SavedProfile, ProfileLibrary, AppSettings, defaultSettings, loadSettings, saveSettings, loadLibrary, saveLibrary, addProfile, readProfile, selectProfile, removeProfile, editProfile, fetchProfile, refreshProfile } from '../common/ProfileStore';
import { OutboundGroup, GroupItem, ConnectionInfo, DashboardData, emptyDashboard, readDashboard, sendControl } from '../common/Control';

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
  this.settings=loadSettings(this.context.filesDir);
  this.wifiRulesText=this.settings.bypassWifi.join('\n');
  this.allowAutomaticConnect=true;
  this.library=loadLibrary(this.context.filesDir);
  this.dashboard=readDashboard(this.context.filesDir);
  try {
   this.observer=vpnExtension.createVpnObserver();
   this.observer.onAuthorizationResult((allowed: boolean) => {
    if(!allowed){this.waitingSince=0;this.status=initialStatus();this.message='已取消系统 VPN 授权';}
   });
  } catch(_error) {}
  bridge.version().then((value: string) => {this.coreVersion=value;}).catch(() => {this.coreVersion='内核加载失败';});
  this.readStatus();
  this.timer=setInterval(() => {this.readStatus();this.autoUpdateProfiles();},1000);
  this.reconcileInitialStatus();
 }
 aboutToDisappear(): void {
  if(this.timer!==-1){clearInterval(this.timer);this.timer=-1;}
  this.probeGeneration++;
  this.allowAutomaticConnect=false;
  try {this.observer?.offAuthorizationResult();} catch(_error) {}
 }
 private readStatus(): void {
  try {
   const latest: VpnStatus=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;
   const age: number=Date.now()-latest.updatedAt;
   if(((latest.phase==='running' || latest.phase==='reconnecting' || latest.phase==='paused') && age>15000) || (latest.phase==='starting' && age>60000)){
    latest.phase='error';latest.message='上次连接状态已过期，请重新连接';
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
  if(this.status.phase==='running' && this.activeTab>=2 && this.activeTab<=5){
   writePrivate(`${this.context.filesDir}/dashboard-demand.json`,JSON.stringify({updatedAt:Date.now()}));
   this.dashboard=readDashboard(this.context.filesDir);
  }
 }
 private active(): boolean {return this.status.phase==='running' || this.status.phase==='starting' || this.status.phase==='reconnecting' || this.status.phase==='paused';}
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
    if(!exists && this.status.phase==='running' && this.status.updatedAt===timestamp){this.status=initialStatus();writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));}
   } catch(_error) {}
  }
  if(this.allowAutomaticConnect && this.settings.autoConnect && !this.busy && !this.active() && this.library.selected){await this.toggle(true);}
  this.autoUpdateProfiles();
 }
 private selectedName(): string {return this.library.profiles.find((p: SavedProfile): boolean => p.id===this.library.selected)?.name || '尚未选择配置';}
 private async toggle(automatic: boolean=false): Promise<void> {
  if(!automatic){this.allowAutomaticConnect=false;}
  this.probeGeneration++;this.probeResult='';this.probing=false;this.busy=true;
  try {
   if(this.active()){
    await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
    this.waitingSince=0;this.status=initialStatus();this.status.message='VPN 已停止';
    writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));this.message='已断开';
   } else {
    if(!this.library.selected){this.activeTab=1;this.message='请先导入配置';return;}
    const content: string=readProfile(this.context.filesDir,this.library.selected);
    const check: CoreResponse=JSON.parse(await bridge.check(content)) as CoreResponse;
    if(!check.ok){this.message='配置未通过内核校验，请编辑配置后重试';return;}
    writePrivate(`${this.context.filesDir}/profile.json`,content);
    this.status={phase:'starting',message:'等待系统 VPN 授权',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};
    this.waitingSince=this.status.updatedAt;
    await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});this.message='正在连接';
   }
  } catch(_error) {this.message='操作未完成，请检查系统 VPN 授权';this.waitingSince=0;this.status=initialStatus();writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(this.status));}
  finally {this.busy=false;}
 }
 private async control(action: string,group: string='',outbound: string='',id: string='',mode: string=''): Promise<void> {
  if(this.controlBusy){return;}this.controlBusy=true;
  try {this.message=await sendControl(this.context.filesDir,action,group,outbound,id,mode);}
  catch(_error) {this.message='操作未完成，请确认 VPN 处于连接状态';}
  finally {this.controlBusy=false;}
 }
 private async probe(): Promise<void> {
  const generation: number=++this.probeGeneration;
  const profileId: string=this.library.selected;
  let timeout: number=-1;
  this.probing=true;this.probeResult='正在检查连接…';
  try {
   const content: string=readProfile(this.context.filesDir,profileId);
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
   this.editorContent=data.getPrimaryText();this.editorName='剪贴板配置';this.editingId='';this.editorVisible=true;
  } catch(_error) {this.message='未能读取剪贴板，请允许访问或手动粘贴';}
 }
 private async importRemote(): Promise<void> {
  this.busy=true;
  try {
   const content: string=await fetchProfile(this.remoteURL.trim());
   this.library=await addProfile(this.context.filesDir,this.library,this.editorName || '远程配置',content,this.remoteURL.trim());
   this.remoteURL='';this.message='远程配置已导入';
  } catch(_error) {this.message='下载或校验失败，原配置已保留';}
  finally {this.busy=false;}
 }
 private async saveEditor(): Promise<void> {
  this.busy=true;
  try {
   if(this.editingId){this.library=await editProfile(this.context.filesDir,this.library,this.editingId,this.editorName,this.editorContent);}
   else {this.library=await addProfile(this.context.filesDir,this.library,this.editorName,this.editorContent);}
   this.editorVisible=false;this.editorContent='';this.message='配置已保存并通过内核校验';
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
  AlertDialog.show({title:'删除配置',message:`删除“${record.name}”？`,primaryButton:{value:'取消',action:() => {}},secondaryButton:{value:'删除',action:() => {try {this.library=removeProfile(this.context.filesDir,this.library,record.id);this.message='已删除配置';} catch(_error) {this.message='请先切换到其他配置';}}}});
 }
 private async refresh(record: SavedProfile): Promise<void> {
  this.busy=true;
  try {await refreshProfile(this.context.filesDir,this.library,record.id);this.library=loadLibrary(this.context.filesDir);this.message=this.active()?'配置已更新，重连后应用':'配置已更新';}
  catch(_error) {this.message='更新失败，已保留原配置';}
  finally {this.busy=false;}
 }
 private async autoUpdateProfiles(): Promise<void> {
  if(this.busy || Date.now()-this.lastAutoUpdate<60000){return;}this.lastAutoUpdate=Date.now();
  for(const record of this.library.profiles){
   if(record.url && record.autoUpdateHours>0 && Date.now()-record.updatedAt>=record.autoUpdateHours*3600000){await this.refresh(record);}
  }
 }
 private toggleAutoUpdate(record: SavedProfile,value: boolean): void {
  record.autoUpdateHours=value?24:0;saveLibrary(this.context.filesDir,this.library);
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
    Text(this.status.phase==='running'?'已连接':this.status.phase==='paused'?'已暂停':this.status.phase==='reconnecting'?'等待重连':this.status.phase==='starting'?'连接中':'未连接').fontSize(28).fontWeight(FontWeight.Medium)
    Text(this.status.message).fontSize(14).fontColor('#657687')
    Text(this.selectedName()).fontSize(16).fontWeight(FontWeight.Medium)
    if(this.status.phase==='running'){
     this.note({value:`${this.status.networkType || ''} · ${this.status.physicalIPv6Available?'基础网络支持 IPv6':'基础网络未报告 IPv6'}`})
     this.note({value:`IPv4 + IPv6 · MTU 1280 · ${this.status.tunName}`})
     Text(`↑ ${bytesLabel(this.uploadRate)}/s     ↓ ${bytesLabel(this.downloadRate)}/s`).fontSize(18).fontWeight(FontWeight.Medium)
     this.note({value:`累计上行 ${bytesLabel(this.status.uplink || 0)} · 下行 ${bytesLabel(this.status.downlink || 0)}`})
    }
    Button(this.active()?'断开连接':'连接 VPN').width('100%').height(52).backgroundColor('#17324D').enabled(!this.busy).onClick(() => {this.toggle();})
    if(this.status.phase==='running'){
     Row({space:12}) {
      Button('重新连接').layoutWeight(1).enabled(!this.controlBusy && !this.busy).onClick(() => {this.control('reconnect');})
      Button(this.probing?'检查中…':'检查连接').layoutWeight(1).enabled(!this.probing).onClick(() => {this.probe();})
     }.width('100%')
    }
    if(this.probeResult){this.note({value:this.probeResult})}
   }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(22)
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
      Row(){Text('自动更新（打开 App 时，每 24 小时）').fontSize(12).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:record.autoUpdateHours>0}).onChange((value: boolean) => {this.toggleAutoUpdate(record,value);})}.width('100%')
     }
    }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(20)
   },(record: SavedProfile): string => `${record.id}-${record.name}-${record.updatedAt}-${this.library.selected}`)
   Column({space:12}) {
    TextInput({text:this.editorName,placeholder:'配置名称'}).onChange((value: string) => {this.editorName=value;}).enabled(!this.busy && !this.active())
    Row({space:8}) {
     Button('本地文件').layoutWeight(1).enabled(!this.busy && !this.active()).onClick(() => {this.importFile();})
     Button('剪贴板').layoutWeight(1).enabled(!this.busy && !this.active()).onClick(() => {this.pasteProfile();})
    }.width('100%')
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
    Row(){Text('网络切换或掉线后自动重连').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.autoReconnect}).onChange((value: boolean) => {this.settings.autoReconnect=value;this.saveOptions();})}.width('100%')
    Row(){Text('打开 App 时自动连接').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.autoConnect}).onChange((value: boolean) => {this.settings.autoConnect=value;this.saveOptions();})}.width('100%')
    Row(){Text('指定 Wi-Fi 暂停 VPN').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.settings.onDemand}).onChange((value: boolean) => {this.settings.onDemand=value;this.saveOptions();})}.width('100%')
    if(this.settings.onDemand){
     TextArea({text:this.wifiRulesText,placeholder:'每行一个 Wi-Fi 名称，精确匹配'}).height(100).onChange((value: string) => {this.wifiRulesText=value;})
     Button('保存 Wi-Fi 规则').width('100%').onClick(() => {this.settings.bypassWifi=this.wifiRulesText.split(/\r?\n/).filter((name: string): boolean => name.length>0);this.saveOptions();})
     this.note({value:'服务运行时进入这些 Wi-Fi 会暂停隧道，离开后恢复；系统结束服务后，需要重新打开 App。'})
    }
    this.note({value:'自动连接需要已获得系统 VPN 授权。自动更新会在 App 打开时检查；系统结束应用后不保证后台定时运行。'})
    Row(){Text('日志级别').layoutWeight(1);Select([{value:'warn'},{value:'info'},{value:'debug'},{value:'error'}]).value(this.settings.logLevel).onSelect((_index: number,value?: string) => {this.settings.logLevel=value || 'warn';this.saveOptions();})}.width('100%')
    this.note({value:'日志级别在下次连接时应用。'})
    Button('重置网络连接与 DNS 缓存').width('100%').enabled(this.status.phase==='running' && !this.controlBusy).onClick(() => {this.control('reset-network');})
    if(this.dashboard.modes.length>0){
     this.note({value:`路由模式：${this.dashboard.mode}`})
     ForEach(this.dashboard.modes,(mode: string) => {Button(mode).width('100%').enabled(this.status.phase==='running' && !this.controlBusy && mode!==this.dashboard.mode).onClick(() => {this.control('mode','','','',mode);})},(mode: string): string => mode)
    }
   }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(20)
   this.note({value:`熊盒 VPN 0.2 · ${this.coreVersion}`})
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
