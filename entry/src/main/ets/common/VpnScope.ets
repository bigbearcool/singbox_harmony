import { fileIo as fs } from '@kit.CoreFileKit';
import { vpnExtension } from '@kit.NetworkKit';
import { readPrivate, writePrivate } from './Store';

export interface VpnScope {mode: string; applications: string[];}
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
