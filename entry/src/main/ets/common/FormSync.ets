import { formBindingData, formProvider } from '@kit.FormKit';
import { readPrivate, writePrivate, VpnStatus } from './Store';

export interface CardState {
 phase: string;
 phaseLabel: string;
 networkType: string;
 active: boolean;
}

export function cardStateFromStatus(status: VpnStatus): CardState {
 const phase: string=status.phase || 'stopped';
 const active: boolean=phase==='running' || phase==='starting' || phase==='reconnecting' || phase==='paused';
 let label: string='未连接';
 if(phase==='running'){label='已保护';}
 else if(phase==='starting'){label='连接中';}
 else if(phase==='reconnecting'){label='重连中';}
 else if(phase==='paused'){label='已暂停';}
 else if(phase==='checking'){label='待确认';}
 return {
  phase:phase,
  phaseLabel:label,
  networkType:phase==='running'?(status.networkType || '双栈隧道'):'点击一键操作',
  active:active
 };
}

export function readFormIds(dir: string): string[] {
 try {
  const parsed: Object=JSON.parse(readPrivate(`${dir}/form-ids.json`)) as Object;
  if(Array.isArray(parsed)){
   const ids: string[]=[];
   for(const item of parsed as string[]){
    if(typeof item==='string' && item.length>0 && !ids.includes(item)){ids.push(item);}
   }
   return ids;
  }
 } catch(_error) {}
 return [];
}

export function registerFormId(dir: string,formId: string): void {
 if(!formId){return;}
 const ids: string[]=readFormIds(dir);
 if(!ids.includes(formId)){
  ids.push(formId);
  try {writePrivate(`${dir}/form-ids.json`,JSON.stringify(ids.slice(-16)));} catch(_error) {}
 }
}

export function unregisterFormId(dir: string,formId: string): void {
 if(!formId){return;}
 const next: string[]=readFormIds(dir).filter((id: string): boolean => id!==formId);
 try {writePrivate(`${dir}/form-ids.json`,JSON.stringify(next));} catch(_error) {}
}

export function readCurrentCardState(dir: string): CardState {
 try {
  const status: VpnStatus=JSON.parse(readPrivate(`${dir}/vpn-status.json`)) as VpnStatus;
  return cardStateFromStatus(status);
 } catch(_error) {
  return {phase:'stopped',phaseLabel:'未连接',networkType:'点击一键操作',active:false};
 }
}

export function pushFormStatus(dir: string,status: VpnStatus): void {
 const ids: string[]=readFormIds(dir);
 if(ids.length===0){return;}
 const data: formBindingData.FormBindingData=formBindingData.createFormBindingData(cardStateFromStatus(status));
 for(const id of ids){
  try {
   formProvider.updateForm(id,data).catch(() => {});
  } catch(_error) {}
 }
}
