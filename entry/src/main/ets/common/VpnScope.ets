import { fileIo as fs } from '@kit.CoreFileKit';
import { vpnExtension } from '@kit.NetworkKit';
import { readPrivate, writePrivate } from './Store';

export interface VpnScope {mode: string; applications: string[];}
export interface AppPresetItem {label: string; bundleName: string;}
export interface AppPresetCategory {title: string; items: AppPresetItem[];}
export const APP_SCOPE_PRESETS: AppPresetCategory[]=[
 {
  title:'金融支付',
  items:[
   {label:'支付宝',bundleName:'com.alipay.mobile.client'},
   {label:'云闪付',bundleName:'com.unionpay.hmos.wallet'},
   {label:'招商银行',bundleName:'com.cmbchina.harmony'},
   {label:'工商银行',bundleName:'com.icbc.harmonyclient'}
  ]
 },
 {
  title:'国内社交与出行',
  items:[
   {label:'微信',bundleName:'com.tencent.wechat'},
   {label:'高德地图',bundleName:'com.amap.hmapp'},
   {label:'美团',bundleName:'com.sankuai.hmeituan'},
   {label:'滴滴出行',bundleName:'com.sdu.didi.hmos.psnger'}
  ]
 },
 {
  title:'国内影音与购物',
  items:[
   {label:'哔哩哔哩',bundleName:'yylx.danmaku.bili'},
   {label:'抖音',bundleName:'com.ss.hm.ugc.aweme'},
   {label:'淘宝',bundleName:'com.taobao.taobao4hmos'},
   {label:'京东',bundleName:'com.jd.hm.mall'}
  ]
 }
];
export function toggleScopePackage(scope: VpnScope,bundleName: string): VpnScope {
 const trimmed: string=bundleName.trim();
 if(!trimmed){return {mode:scope.mode,applications:[...scope.applications]};}
 if(scope.applications.includes(trimmed)){
  return {mode:scope.mode,applications:scope.applications.filter((item: string): boolean => item!==trimmed)};
 }
 return {mode:scope.mode,applications:[...scope.applications,trimmed]};
}
export function defaultVpnScope(): VpnScope {return {mode:'all',applications:[]};}
export function validateVpnScope(mode: string,applications: string[]): VpnScope {
 if(!['all','include','exclude'].includes(mode)){throw new Error('未知应用范围');}
 if(mode==='all'){return defaultVpnScope();}
 const unique: string[]=[];
 for(const value of applications){
  const name: string=value.trim();if(!name){continue;}
  if(name.length>127 || !/^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/.test(name)){throw new Error('请输入有效的应用包名');}
  if(!unique.includes(name)){unique.push(name);}
 }
 if(unique.length===0 || unique.length>256){throw new Error('请填写 1 至 256 个应用包名');}
 return {mode:mode,applications:unique};
}
export function loadVpnScope(dir: string): VpnScope {
 const path: string=`${dir}/vpn-scope.json`;if(!fs.accessSync(path)){return defaultVpnScope();}
 try {const value=JSON.parse(readPrivate(path)) as VpnScope;if(!Array.isArray(value.applications)){throw new Error('invalid list');}return validateVpnScope(value.mode,value.applications);}
 catch(_error) {throw new Error('应用范围设置无法读取，请在设置中重新保存');}
}
export function saveVpnScope(dir: string,mode: string,text: string): VpnScope {
 const scope: VpnScope=validateVpnScope(mode,text.split(/\r?\n/));writePrivate(`${dir}/vpn-scope.json`,JSON.stringify(scope));return scope;
}
export function applyVpnScope(config: vpnExtension.VpnConfig,scope: VpnScope): vpnExtension.VpnConfig {
 const accepted: VpnScope=validateVpnScope(scope.mode,scope.applications);
 config.trustedApplications=undefined;config.blockedApplications=undefined;
 if(accepted.mode==='include'){config.trustedApplications=accepted.applications;}
 if(accepted.mode==='exclude'){config.blockedApplications=accepted.applications;}
 return config;
}
