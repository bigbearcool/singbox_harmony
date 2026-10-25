import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import bridge from 'libsingboxbridge.so';
import { readPrivate, writePrivate, CoreResponse, DIRECT_PROFILE, BLOCK_IPV6_PROFILE } from './Store';

export interface SavedProfile {
 id: string;
 name: string;
 url: string;
 updatedAt: number;
 autoUpdateHours: number;
}
export interface ProfileLibrary {selected: string; profiles: SavedProfile[];}
export interface AppSettings {autoReconnect: boolean; autoConnect: boolean; logLevel: string; onDemand: boolean; bypassWifi: string[];}
export function defaultSettings(): AppSettings {return {autoReconnect:true,autoConnect:false,logLevel:'warn',onDemand:false,bypassWifi:[]};}
export function loadSettings(dir: string): AppSettings {
 try {
  const stored: AppSettings=JSON.parse(readPrivate(`${dir}/settings.json`)) as AppSettings;
  return {autoReconnect:stored.autoReconnect!==false,autoConnect:stored.autoConnect===true,logLevel:stored.logLevel || 'warn',onDemand:stored.onDemand===true,bypassWifi:stored.bypassWifi || []};
 } catch(_error) {return defaultSettings();}
}
export function saveSettings(dir: string,value: AppSettings): void {writePrivate(`${dir}/settings.json`,JSON.stringify(value));}
function profilePath(dir: string,id: string): string {
 if(!/^[a-zA-Z0-9-]+$/.test(id)){throw new Error('配置标识无效');}
 return `${dir}/saved-profile-${id}.json`;
}
export function saveLibrary(dir: string,library: ProfileLibrary): void {writePrivate(`${dir}/profiles.json`,JSON.stringify(library));}
export function loadLibrary(dir: string): ProfileLibrary {
 try {return JSON.parse(readPrivate(`${dir}/profiles.json`)) as ProfileLibrary;} catch(_error) {}
 const library: ProfileLibrary={selected:'',profiles:[]};
 try {
  const content: string=readPrivate(`${dir}/profile.json`);
  const id: string=util.generateRandomUUID();
  writePrivate(profilePath(dir,id),content);
  library.selected=id;
  library.profiles.push({id:id,name:'我的配置',url:'',updatedAt:Date.now(),autoUpdateHours:0});
 } catch(_error) {}
 saveLibrary(dir,library);return library;
}
export function readProfile(dir: string,id: string): string {return readPrivate(profilePath(dir,id));}
export function setDiagnosticProfile(dir: string,content: string): void {
 if(content!==DIRECT_PROFILE && content!==BLOCK_IPV6_PROFILE){throw new Error('未知诊断配置');}
 const library: ProfileLibrary=loadLibrary(dir);
 if(library.selected){
  const existing: string=readProfile(dir,library.selected);
  if(existing!==DIRECT_PROFILE && existing!==BLOCK_IPV6_PROFILE){throw new Error('真实配置不能被诊断预设替换');}
  writePrivate(profilePath(dir,library.selected),content);
 }
 writePrivate(`${dir}/profile.json`,content);
}
export async function validateProfile(content: string): Promise<void> {
 if(new util.TextEncoder().encodeInto(content).length>1048576){throw new Error('配置不能超过 1 MiB');}
 const checked: CoreResponse=JSON.parse(await bridge.check(content)) as CoreResponse;
 if(!checked.ok){throw new Error('内核未接受该配置；请检查 JSON、协议和字段版本');}
}
export async function addProfile(dir: string,library: ProfileLibrary,name: string,content: string,url: string=''): Promise<ProfileLibrary> {
 await validateProfile(content);
 const id: string=util.generateRandomUUID();
 writePrivate(profilePath(dir,id),content);
 const record: SavedProfile={id:id,name:name.trim().slice(0,80) || '新配置',url:url,updatedAt:Date.now(),autoUpdateHours:url?24:0};
 const next: ProfileLibrary={selected:id,profiles:[...library.profiles,record]};
 writePrivate(`${dir}/profile.json`,content);saveLibrary(dir,next);return next;
}
export function selectProfile(dir: string,library: ProfileLibrary,id: string): ProfileLibrary {
 writePrivate(`${dir}/profile.json`,readProfile(dir,id));
 const next: ProfileLibrary={selected:id,profiles:library.profiles};saveLibrary(dir,next);return next;
}
export function removeProfile(dir: string,library: ProfileLibrary,id: string): ProfileLibrary {
 if(id===library.selected){throw new Error('请先切换到其他配置');}
 const next: ProfileLibrary={selected:library.selected,profiles:library.profiles.filter((p: SavedProfile): boolean => p.id!==id)};
 saveLibrary(dir,next);try {fs.unlinkSync(profilePath(dir,id));} catch(_error) {}return next;
}
export async function editProfile(dir: string,library: ProfileLibrary,id: string,name: string,content: string): Promise<ProfileLibrary> {
 await validateProfile(content);
 const record: SavedProfile | undefined=library.profiles.find((p: SavedProfile): boolean => p.id===id);
 if(!record){throw new Error('配置不存在');}
 writePrivate(profilePath(dir,id),content);
 if(library.selected===id){writePrivate(`${dir}/profile.json`,content);}
 record.name=name.trim().slice(0,80) || '我的配置';record.updatedAt=Date.now();
 const next: ProfileLibrary={selected:library.selected,profiles:[...library.profiles]};saveLibrary(dir,next);return next;
}
export async function fetchProfile(url: string): Promise<string> {
 if(!/^https?:\/\//i.test(url)){throw new Error('请输入 HTTP 或 HTTPS 配置链接');}
 const client: http.HttpRequest=http.createHttp();
 try {
  const response: http.HttpResponse=await client.request(url,{method:http.RequestMethod.GET,expectDataType:http.HttpDataType.STRING,connectTimeout:15000,readTimeout:20000,maxLimit:1048576,usingCache:false});
  if(response.responseCode!==200){throw new Error('配置服务器未返回成功响应');}
  if(typeof response.result!=='string'){throw new Error('服务器未返回文本配置');}
  await validateProfile(response.result);return response.result;
 } catch(_error) {throw new Error('下载或校验失败，已保留原配置。请检查链接、网络及 sing-box JSON 格式');}
 finally {client.destroy();}
}
export async function refreshProfile(dir: string,library: ProfileLibrary,id: string): Promise<ProfileLibrary> {
 const record: SavedProfile | undefined=library.profiles.find((p: SavedProfile): boolean => p.id===id);
 if(!record || !record.url){throw new Error('该配置没有远程链接');}
 const content: string=await fetchProfile(record.url);
 writePrivate(profilePath(dir,id),content);
 if(library.selected===id){writePrivate(`${dir}/profile.json`,content);}
 record.updatedAt=Date.now();saveLibrary(dir,library);return library;
}
