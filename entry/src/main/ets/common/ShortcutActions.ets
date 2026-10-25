import { Want } from '@kit.AbilityKit';

export function validShortcutAction(value: string): boolean {return ['connect','disconnect','overview'].includes(value);}
export function shortcutActionFromWant(want: Want): string {
 if(want.uri){return '';}
 const direct=want.parameters?.shortcutAction;
 if(typeof direct==='string'){return validShortcutAction(direct)?direct:'';}
 const nested=want.parameters?.params;
 if(typeof nested!=='string' || nested.length>1024){return '';}
 try {const data=JSON.parse(nested) as Record<string,string>;return typeof data.shortcutAction==='string' && validShortcutAction(data.shortcutAction)?data.shortcutAction:'';} catch(_error) {return '';}
}

export interface ShortcutPort {
 phase: () => string;
 hasVpn: () => Promise<boolean>;
 start: () => Promise<void>;
 stop: () => Promise<void>;
 reconnect: () => Promise<void>;
 notify: (message: string) => void;
}
// Explicit desired states make repeated taps safe; a stale desktop card must
// never turn a repeated connect into disconnect (or vice versa).
export async function runShortcutAction(action: string,port: ShortcutPort): Promise<void> {
 if(!validShortcutAction(action) || action==='overview'){return;}
 const present: boolean=await port.hasVpn();
 const phase: string=port.phase();
 if(action==='disconnect'){
  if(present || ['starting','running','checking','reconnecting','paused'].includes(phase)){await port.stop();}
  else {port.notify('VPN 已断开');}
 } else {
  if(present){port.notify('系统 VPN 已存在，可在总览检查连接');}
  else if(['starting','reconnecting','paused'].includes(phase)){port.notify('已有 VPN 会话，正在连接或按 Wi-Fi 条件暂停');}
  else if(['running','checking'].includes(phase)){await port.reconnect();}
  else {await port.start();}
 }
}
