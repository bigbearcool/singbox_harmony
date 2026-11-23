import { formBindingData, formProvider } from '@kit.FormKit';
import { readPrivate, writePrivate, VpnStatus } from './Store';

export interface CardState {
 phase: string;
 phaseLabel: string;
 networkType: string;
 active: boolean;
 mode: string;
 trafficLabel: string;
 isWide: boolean;
}

function sanitizeCardMode(raw: string): string {
 const trimmed: string = raw.trim();
 if (!trimmed || trimmed.length > 16 || trimmed.includes('://') || trimmed.includes('@') || trimmed.includes('/')) {
  return '';
 }
 return trimmed;
}

function formatCompactBytes(bytes: number): string {
 if (!Number.isFinite(bytes) || bytes <= 0) {
  return '0B';
 }
 if (bytes < 1024) {
  return `${Math.round(bytes)}B`;
 }
 if (bytes < 1024 * 1024) {
  return `${Math.round(bytes / 1024)}KB`;
 }
 if (bytes < 1024 * 1024 * 1024) {
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
 }
 return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)}GB`;
}

export function cardStateFromStatus(status: VpnStatus, mode: string = '', isWide: boolean = false): CardState {
 const phase: string = status.phase || 'stopped';
 const active: boolean = phase === 'running' || phase === 'starting' || phase === 'reconnecting' || phase === 'paused';
 let label: string = '未连接';
 if (phase === 'running') { label = '已保护'; }
 else if (phase === 'starting') { label = '连接中'; }
 else if (phase === 'reconnecting') { label = '重连中'; }
 else if (phase === 'paused') { label = '已暂停'; }
 else if (phase === 'checking') { label = '待确认'; }
 const up: number = Number.isFinite(status.uplink) ? Math.max(0, status.uplink || 0) : 0;
 const down: number = Number.isFinite(status.downlink) ? Math.max(0, status.downlink || 0) : 0;
 const trafficLabel: string = phase === 'running' && (up > 0 || down > 0)
  ? `↑${formatCompactBytes(up)} ↓${formatCompactBytes(down)}`
  : '';
 return {
  phase: phase,
  phaseLabel: label,
  networkType: phase === 'running' ? (status.networkType || '双栈隧道') : '点击一键操作',
  active: active,
  mode: sanitizeCardMode(mode),
  trafficLabel: trafficLabel,
  isWide: isWide
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

export function readCurrentCardState(dir: string, isWide: boolean = false, mode: string = ''): CardState {
 try {
  const status: VpnStatus = JSON.parse(readPrivate(`${dir}/vpn-status.json`)) as VpnStatus;
  return cardStateFromStatus(status, mode, isWide);
 } catch (_error) {
  return {
   phase: 'stopped',
   phaseLabel: '未连接',
   networkType: '点击一键操作',
   active: false,
   mode: sanitizeCardMode(mode),
   trafficLabel: '',
   isWide: isWide
  };
 }
}

export function pushFormStatus(dir: string, status: VpnStatus, mode: string = ''): void {
 const ids: string[] = readFormIds(dir);
 if (ids.length === 0) { return; }
 const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(cardStateFromStatus(status, mode));
 for (const id of ids) {
  try {
   formProvider.updateForm(id, data).catch(() => {});
  } catch (_error) {}
 }
}
