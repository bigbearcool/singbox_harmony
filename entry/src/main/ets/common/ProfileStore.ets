import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import bridge from 'libsingboxbridge.so';
import { readPrivate, writePrivate, CoreResponse, DIRECT_PROFILE, BLOCK_IPV6_PROFILE } from './Store';

export interface SavedProfile {id: string; name: string; url: string; updatedAt: number; autoUpdateHours: number; revision?: string;}
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
function safeId(id: string): void {if(!/^[a-zA-Z0-9-]{1,96}$/.test(id)){throw new Error('配置标识无效');}}
function profilePath(dir: string,record: SavedProfile): string {
 safeId(record.id);if(record.revision){safeId(record.revision);}
 return `${dir}/saved-profile-${record.id}${record.revision?`-${record.revision}`:''}.json`;
}
function withStoreLock<T>(dir: string,action: () => T): T {
 const file: fs.File=fs.openSync(`${dir}/profiles.lock`,fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
 let locked: boolean=false;
 try {bridge.secureFile(file.fd);file.tryLock(true);locked=true;return action();}
 finally {if(locked){try {file.unlock();} catch(_error) {}}fs.closeSync(file);}
}
function writeIndex(dir: string,library: ProfileLibrary): void {writePrivate(`${dir}/profiles.json`,JSON.stringify(library));}
function readIndex(dir: string): ProfileLibrary | undefined {
 if(!fs.accessSync(`${dir}/profiles.json`)){return undefined;}
 let library: ProfileLibrary;
 try {library=JSON.parse(readPrivate(`${dir}/profiles.json`)) as ProfileLibrary;} catch(_error) {throw new Error('配置索引读取失败，原文件已保留');}
 if(!library || typeof library.selected!=='string' || !Array.isArray(library.profiles)){throw new Error('配置索引格式无效，原文件已保留');}
 for(const record of library.profiles){safeId(record.id);if(record.revision){safeId(record.revision);}if(typeof record.name!=='string' || typeof record.url!=='string'){throw new Error('配置记录格式无效');}}
 if(library.selected && !library.profiles.some((record: SavedProfile): boolean => record.id===library.selected)){throw new Error('选中的配置不存在，索引已保留');}
 return library;
}
export function loadLibrary(dir: string): ProfileLibrary {
 const existing: ProfileLibrary | undefined=readIndex(dir);if(existing){return existing;}
 return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  const current: ProfileLibrary | undefined=readIndex(dir);if(current){return current;}
  const library: ProfileLibrary={selected:'',profiles:[]};
  if(fs.accessSync(`${dir}/profile.json`)){
   const content: string=readPrivate(`${dir}/profile.json`);
   const record: SavedProfile={id:util.generateRandomUUID(),name:'我的配置',url:'',updatedAt:Date.now(),autoUpdateHours:0};
   writePrivate(profilePath(dir,record),content);library.selected=record.id;library.profiles.push(record);
  }
  writeIndex(dir,library);return library;
 });
}
function currentIndex(dir: string): ProfileLibrary {
 const current: ProfileLibrary | undefined=readIndex(dir);if(!current){throw new Error('配置索引不存在');}return current;
}
function recordFor(library: ProfileLibrary,id: string): SavedProfile {
 const record: SavedProfile | undefined=library.profiles.find((p: SavedProfile): boolean => p.id===id);
 if(!record){throw new Error('配置不存在或已被删除');}return record;
}
function readContent(dir: string,library: ProfileLibrary,id: string): string {return readPrivate(profilePath(dir,recordFor(library,id)));}
export function readProfile(dir: string,id: string): string {
 loadLibrary(dir);return withStoreLock<string>(dir,(): string => readContent(dir,currentIndex(dir),id));
}
function aliasSelected(dir: string,library: ProfileLibrary,content: string): void {
 // This compatibility alias is regenerated before every explicit connection.
 // The immutable blob and atomic index are the source of truth.
 try {if(library.selected){writePrivate(`${dir}/profile.json`,content);}} catch(_error) {}
}
function cleanupBlobs(dir: string,id: string,keep: string=''): void {
 try {for(const name of fs.listFileSync(dir)){
  if(name===keep){continue;}
  if(name===`saved-profile-${id}.json` || (name.startsWith(`saved-profile-${id}-`) && name.endsWith('.json'))){try {fs.unlinkSync(`${dir}/${name}`);} catch(_error) {}}
 }} catch(_error) {}
}
function commitContent(dir: string,library: ProfileLibrary,record: SavedProfile,name: string,content: string): ProfileLibrary {
 const updated: SavedProfile={id:record.id,name:name.trim().slice(0,80) || '我的配置',url:record.url,updatedAt:Date.now(),autoUpdateHours:record.autoUpdateHours,revision:util.generateRandomUUID()};
 const path: string=profilePath(dir,updated);writePrivate(path,content);
 const next: ProfileLibrary={selected:library.selected,profiles:library.profiles.map((p: SavedProfile): SavedProfile => p.id===record.id?updated:p)};
 try {writeIndex(dir,next);} catch(error) {try {fs.unlinkSync(path);} catch(_error) {}throw new Error('未能提交配置更新，旧版本已保留');}
 cleanupBlobs(dir,record.id,path.slice(dir.length+1));return next;
}
export function setDiagnosticProfile(dir: string,content: string): void {
 if(content!==DIRECT_PROFILE && content!==BLOCK_IPV6_PROFILE){throw new Error('未知诊断配置');}
 loadLibrary(dir);withStoreLock<void>(dir,(): void => {
  const library: ProfileLibrary=currentIndex(dir);
  if(library.selected){
   const existing: string=readContent(dir,library,library.selected);
   if(existing!==DIRECT_PROFILE && existing!==BLOCK_IPV6_PROFILE){throw new Error('真实配置不能被诊断预设替换');}
   commitContent(dir,library,recordFor(library,library.selected),'诊断配置',content);
  }
  writePrivate(`${dir}/profile.json`,content);
 });
}
export async function validateProfile(content: string): Promise<void> {
 if(new util.TextEncoder().encodeInto(content).length>1048576){throw new Error('配置不能超过 1 MiB');}
 const checked: CoreResponse=JSON.parse(await bridge.check(content)) as CoreResponse;
 if(!checked.ok){throw new Error('内核未接受该配置；请检查 JSON、协议和字段版本');}
}
export async function addProfile(dir: string,_library: ProfileLibrary,name: string,content: string,url: string=''): Promise<ProfileLibrary> {
 await validateProfile(content);loadLibrary(dir);
 return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  const library: ProfileLibrary=currentIndex(dir);
  const record: SavedProfile={id:util.generateRandomUUID(),name:name.trim().slice(0,80) || '新配置',url:url,updatedAt:Date.now(),autoUpdateHours:url?24:0,revision:util.generateRandomUUID()};
  const path: string=profilePath(dir,record);writePrivate(path,content);
  const next: ProfileLibrary={selected:record.id,profiles:[...library.profiles,record]};
  try {writeIndex(dir,next);} catch(_error) {try {fs.unlinkSync(path);} catch(_error) {}throw new Error('保存未完成，旧配置已保留');}
  aliasSelected(dir,next,content);return next;
 });
}
export function selectProfile(dir: string,_library: ProfileLibrary,id: string): ProfileLibrary {
 loadLibrary(dir);return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  const library: ProfileLibrary=currentIndex(dir);const content: string=readContent(dir,library,id);
  const next: ProfileLibrary={selected:id,profiles:library.profiles};writeIndex(dir,next);aliasSelected(dir,next,content);return next;
 });
}
export function removeProfile(dir: string,_library: ProfileLibrary,id: string): ProfileLibrary {
 loadLibrary(dir);return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  const library: ProfileLibrary=currentIndex(dir);if(id===library.selected){throw new Error('请先切换到其他配置');}
  recordFor(library,id);const next: ProfileLibrary={selected:library.selected,profiles:library.profiles.filter((p: SavedProfile): boolean => p.id!==id)};
  writeIndex(dir,next);cleanupBlobs(dir,id);return next;
 });
}
export async function editProfile(dir: string,_library: ProfileLibrary,id: string,name: string,content: string): Promise<ProfileLibrary> {
 await validateProfile(content);loadLibrary(dir);
 return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {const library: ProfileLibrary=currentIndex(dir);return commitContent(dir,library,recordFor(library,id),name,content);});
}
export function setAutoUpdate(dir: string,id: string,hours: number): ProfileLibrary {
 loadLibrary(dir);return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  const library: ProfileLibrary=currentIndex(dir);const record: SavedProfile=recordFor(library,id);
  if(!record.url){throw new Error('本地配置不能自动更新');}
  record.autoUpdateHours=Math.max(0,hours);
  writeIndex(dir,library);return library;
 });
}
export async function fetchProfile(url: string): Promise<string> {
 if(!/^https?:\/\//i.test(url)){throw new Error('请输入 HTTP 或 HTTPS 配置链接');}
 const client: http.HttpRequest=http.createHttp();
 try {
  const response: http.HttpResponse=await client.request(url,{method:http.RequestMethod.GET,expectDataType:http.HttpDataType.STRING,connectTimeout:15000,readTimeout:20000,maxLimit:1048576,usingCache:false});
  if(response.responseCode!==200 || typeof response.result!=='string'){throw new Error('配置服务器未返回成功文本响应');}
  await validateProfile(response.result);return response.result;
 } catch(_error) {throw new Error('下载或校验失败，已保留原配置。请检查链接、网络及 sing-box JSON 格式');}
 finally {client.destroy();}
}
export async function refreshProfile(dir: string,_library: ProfileLibrary,id: string,canCommit: () => boolean=(): boolean => true): Promise<ProfileLibrary> {
 const initial: SavedProfile=recordFor(loadLibrary(dir),id);
 if(!initial.url){throw new Error('该配置没有远程链接');}
 const content: string=await fetchProfile(initial.url);
 if(!canCommit()){throw new Error('更新任务已取消');}
 return withStoreLock<ProfileLibrary>(dir,(): ProfileLibrary => {
  if(!canCommit()){throw new Error('更新任务已取消');}
  const current: ProfileLibrary=currentIndex(dir);const record: SavedProfile=recordFor(current,id);
  if(record.url!==initial.url || record.name!==initial.name || record.updatedAt!==initial.updatedAt || record.revision!==initial.revision || record.autoUpdateHours!==initial.autoUpdateHours){throw new Error('配置在下载期间发生变化，已保留最新版本');}
  return commitContent(dir,current,record,record.name,content);
 });
}
