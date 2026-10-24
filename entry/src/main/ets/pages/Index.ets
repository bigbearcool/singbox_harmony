import { common } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import bridge from 'libsingboxbridge.so';
import { BUNDLE_NAME, VPN_ABILITY, DIRECT_PROFILE, VpnStatus, CoreResponse, initialStatus, writePrivate, readPrivate } from '../common/Store';

@Entry
@Component
struct Index {
 @State private status: VpnStatus = initialStatus();
 @State private profile: string = '';
 @State private message: string = '导入 sing-box JSON 配置后连接';
 @State private coreVersion: string = '正在检查内核…';
 @State private busy: boolean = false;
 private waitingSince: number = 0;
 private observer?: vpnExtension.VpnObserver;
 private timer: number = -1;
 private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

 aboutToAppear(): void {
  try {this.profile=readPrivate(`${this.context.filesDir}/profile.json`);} catch(_error) {}
  try {
   this.observer=vpnExtension.createVpnObserver();
   this.observer.onAuthorizationResult((allowed: boolean) => {
    if(!allowed){this.waitingSince=0;this.status=initialStatus();this.message='已取消系统 VPN 授权';}
   });
  } catch(_error) {}
  bridge.version().then((value: string) => {this.coreVersion=value;hilog.info(0xD001700,'SingboxHarmony','native-core=%{public}s',value);}).catch(() => {this.coreVersion='内核加载失败';});
  this.readStatus();this.timer=setInterval(() => {this.readStatus();},1000);
 }
 aboutToDisappear(): void {
  if(this.timer!==-1){clearInterval(this.timer);}
  try {this.observer?.offAuthorizationResult();} catch(_error) {}
 }
 private readStatus(): void {
  try {
   const latest: VpnStatus=JSON.parse(readPrivate(`${this.context.filesDir}/vpn-status.json`)) as VpnStatus;
   if(latest.updatedAt>=this.waitingSince){this.status=latest;}
  } catch(_error) {}
  if(this.waitingSince>0 && this.status.phase==='starting' && Date.now()-this.waitingSince>60000){
   this.status={phase:'error',message:'等待授权超时；可重新连接',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};
   this.waitingSince=0;
  }
 }
 private active(): boolean {return this.status.phase==='running' || this.status.phase==='starting';}
 private async saveProfile(): Promise<boolean> {
  const check: CoreResponse = JSON.parse(await bridge.check(this.profile)) as CoreResponse;
  this.message=check.message;
  if(check.ok){writePrivate(`${this.context.filesDir}/profile.json`,this.profile);}
  return check.ok;
 }
 private async importProfile(): Promise<void> {
  this.busy=true;
  try {
   const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
   options.maxSelectNumber=1;
   const uris: string[]=await new picker.DocumentViewPicker(this.context).select(options);
   if(uris.length===0){return;}
   const file: fs.File=fs.openSync(uris[0],fs.OpenMode.READ_ONLY);
   try {
    const length: number=fs.statSync(file.fd).size;
    if(length>1024*1024){throw new Error('配置文件不能超过 1 MiB');}
    const buffer: ArrayBuffer=new ArrayBuffer(length);
    const read: number=fs.readSync(file.fd,buffer);
    this.profile=util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(new Uint8Array(buffer,0,read));
   } finally {fs.closeSync(file);}
   await this.saveProfile();
  } catch(error) {this.message=(error as BusinessError).message || '导入失败';}
  finally {this.busy=false;}
 }
 private async toggle(): Promise<void> {
  this.busy=true;
  try {
   if(this.active()) {
    await vpnExtension.stopVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
    this.message='已请求停止 VPN';
   } else {
    if(!await this.saveProfile()){return;}
    this.status={phase:'starting',message:'等待系统 VPN 授权',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()};
    this.waitingSince=this.status.updatedAt;
    await vpnExtension.startVpnExtensionAbility({bundleName:BUNDLE_NAME,abilityName:VPN_ABILITY});
    this.message='请确认手机上的系统 VPN 授权';
   }
  } catch(error) {this.message=(error as BusinessError).message || '操作失败';this.status=initialStatus();}
  finally {this.busy=false;}
 }
 build() {
  Scroll() {
   Column({space:20}) {
    Column({space:8}) {
     Text('熊盒 VPN').fontSize(32).fontWeight(FontWeight.Bold).fontColor('#17324D')
     Text(this.coreVersion).fontSize(13).fontColor('#657687')
    }.width('100%').alignItems(HorizontalAlign.Start)
    Column({space:12}) {
     Text(this.status.phase==='running'?'已连接':this.status.phase==='starting'?'连接中':'未连接').fontSize(24).fontWeight(FontWeight.Medium)
     Text(this.status.message).fontSize(14).fontColor('#657687')
     Text(`IPv4 + IPv6 · MTU 1280${this.status.tunName ? ` · ${this.status.tunName}` : ''}`).fontSize(12).fontColor('#657687')
     Button(this.active()?'断开连接':'连接 VPN').width('100%').height(52).backgroundColor('#17324D').enabled(!this.busy && (this.active() || this.profile.length>0)).onClick(() => {this.toggle();})
    }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(24)
    Column({space:12}) {
     Text('连接配置').fontSize(20).fontWeight(FontWeight.Medium)
     Text('支持 sing-box JSON。客户端统一管理双栈 TUN、DNS 接管及系统路由。').fontSize(13).fontColor('#657687')
     Button('从文件导入配置').width('100%').enabled(!this.busy && !this.active()).onClick(() => {this.importProfile();})
     TextArea({text:this.profile,placeholder:'也可在这里粘贴完整 sing-box JSON 配置'}).height(210).fontFamily('monospace').fontSize(12).maxLength(1048576).enabled(!this.active() && !this.busy).onChange((value: string) => {this.profile=value;})
     Button('使用直连诊断配置').type(ButtonType.Normal).fontSize(13).backgroundColor('#E7EEF4').fontColor('#17324D').enabled(!this.active() && !this.busy).onClick(() => {this.profile=DIRECT_PROFILE;this.message='直连诊断仅验证内核与 TUN，不提供代理出口';})
     Text(this.message).fontSize(13).fontColor('#657687').width('100%')
    }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(24).alignItems(HorizontalAlign.Start)
    Text('自用测试版 · IPv6 全接管以真机路由与通网测试为准。切换网络后请重新连接。').fontSize(12).fontColor('#657687')
   }.padding(24).width('100%')
  }.width('100%').height('100%').backgroundColor('#F3F6F9')
 }
}
