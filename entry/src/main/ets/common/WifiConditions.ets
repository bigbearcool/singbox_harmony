import { wifiManager } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';

export interface PhysicalNetworkState {type: string; ssid: string;}
export interface WifiObservation {state: PhysicalNetworkState; known: boolean;}

export function usableSsid(value: string): boolean {
 return typeof value==='string' && value.length>0 && !value.includes('\u0000') && !['<unknown ssid>','<unknown>','0x'].includes(value.toLowerCase()) && new util.TextEncoder().encodeInto(value).length<=32;
}
export async function observeWifi(type: string): Promise<WifiObservation> {
 if(type!=='wifi'){return {state:{type:type,ssid:''},known:true};}
 try {
  const info=await wifiManager.getLinkedInfo();
  if(usableSsid(info.ssid)){return {state:{type:'wifi',ssid:info.ssid},known:true};}
 } catch(_error) {}
 // Never use a cached SSID for imported routing rules after a failed read.
 return {state:{type:'wifi',ssid:''},known:false};
}
export function wifiPauseDecision(enabled: boolean,names: string[],observation: WifiObservation,previous: boolean,sameNetwork: boolean): boolean {
 if(!enabled || names.length===0 || observation.state.type!=='wifi'){return false;}
 if(!observation.known){return sameNetwork && previous;}
 return names.includes(observation.state.ssid);
}
export function parseWifiNames(text: string): string[] {
 const names: string[]=[];
 for(const name of text.split(/\r?\n/)){
  if(name===''){continue;}
  if(!usableSsid(name)){throw new Error('Wi-Fi 名称应为 1 至 32 字节，按原名称精确匹配');}
  if(!names.includes(name)){names.push(name);}
 }
 if(names.length>128){throw new Error('最多保存 128 个 Wi-Fi 名称');}
 return names;
}
