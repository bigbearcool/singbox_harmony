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

export interface SsidPolicyRule {
 ssid: string;
 action: 'pause' | 'mode' | 'group';
 mode?: string;
 group?: string;
 outbound?: string;
}

export interface SsidPolicyMatch {
 matched: boolean;
 rule?: SsidPolicyRule;
}

export function evaluateSsidPolicy(rules: SsidPolicyRule[], observation: WifiObservation): SsidPolicyMatch {
 if (!observation.known || observation.state.type !== 'wifi' || !usableSsid(observation.state.ssid)) {
  return { matched: false };
 }
 for (const rule of rules) {
  if (rule.ssid === observation.state.ssid) {
   return { matched: true, rule: rule };
  }
 }
 return { matched: false };
}

export function parseSsidPolicyLines(text: string): SsidPolicyRule[] {
 const rules: SsidPolicyRule[] = [];
 const seen: Set<string> = new Set<string>();
 for (const rawLine of text.split(/\r?\n/)) {
  const line: string = rawLine.trim();
  if (line.length === 0) {
   continue;
  }
  const eqIndex: number = line.indexOf('=');
  if (eqIndex <= 0) {
   throw new Error('SSID 策略格式应为 "Wi-Fi名称 = pause|mode:模式|group:策略组:节点"');
  }
  const ssid: string = line.slice(0, eqIndex).trim();
  const rhs: string = line.slice(eqIndex + 1).trim();
  if (!usableSsid(ssid)) {
   throw new Error('Wi-Fi 名称应为 1 至 32 字节，按原名称精确匹配');
  }
  const lowerRhs: string = rhs.toLowerCase();
  let parsed: SsidPolicyRule;
  if (lowerRhs === 'pause') {
   parsed = { ssid: ssid, action: 'pause' };
  } else if (lowerRhs.startsWith('mode:')) {
   const mode: string = rhs.slice(5).trim();
   if (mode.length === 0) {
    throw new Error('mode 策略缺少模式名称');
   }
   parsed = { ssid: ssid, action: 'mode', mode: mode };
  } else if (lowerRhs.startsWith('group:')) {
   const rest: string = rhs.slice(6);
   const colonIndex: number = rest.indexOf(':');
   if (colonIndex <= 0) {
    throw new Error('group 策略格式应为 group:策略组:节点');
   }
   const group: string = rest.slice(0, colonIndex).trim();
   const outbound: string = rest.slice(colonIndex + 1).trim();
   if (group.length === 0 || outbound.length === 0) {
    throw new Error('group 策略缺少策略组或节点名称');
   }
   parsed = { ssid: ssid, action: 'group', group: group, outbound: outbound };
  } else {
   throw new Error(`不支持的 SSID 策略动作: ${rhs}`);
  }
  if (!seen.has(ssid)) {
   seen.add(ssid);
   rules.push(parsed);
   if (rules.length > 128) {
    throw new Error('最多保存 128 条 SSID 策略');
   }
  }
 }
 return rules;
}

export function formatSsidPolicyLines(rules: SsidPolicyRule[]): string {
 return rules.map((rule: SsidPolicyRule): string => {
  if (rule.action === 'pause') {
   return `${rule.ssid} = pause`;
  }
  if (rule.action === 'mode') {
   return `${rule.ssid} = mode:${rule.mode || ''}`;
  }
  return `${rule.ssid} = group:${rule.group || ''}:${rule.outbound || ''}`;
 }).join('\n');
}
