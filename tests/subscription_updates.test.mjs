import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'bearbox-subscription-'));
const locks=new Set();let requests=0;let releaseDownload;let destroyed=0;
let now=1800000000000;const dateNow=Date.now;Date.now=()=>now;
const config=tag=>JSON.stringify({outbounds:[{type:'direct',tag}],route:{final:tag}});
let network=async()=>({responseCode:200,result:config('download')});
const nativeFs={OpenMode:{CREATE:fs.constants.O_CREAT,READ_WRITE:fs.constants.O_RDWR},accessSync:fs.existsSync,listFileSync:fs.readdirSync,unlinkSync:fs.unlinkSync,
 openSync(name,flags){const fd=fs.openSync(name,flags,0o600);return {fd,name,locked:false,tryLock(){if(locks.has(name))throw Error('busy');locks.add(name);this.locked=true},unlock(){if(this.locked){locks.delete(name);this.locked=false}}}},closeSync(file){file.unlock();fs.closeSync(file.fd)}};
const writePrivate=(name,value)=>{const tmp=name+'.'+crypto.randomUUID()+'.tmp';fs.writeFileSync(tmp,value,{mode:0o600});fs.renameSync(tmp,name)};
const sdk={fs:nativeFs,util:{generateRandomUUID:crypto.randomUUID,TextEncoder:class{encodeInto(value){return new TextEncoder().encode(value)}}},http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'STRING'},createHttp:()=>{
 let rejectRequest;return {request:()=>{requests++;return new Promise((resolve,reject)=>{rejectRequest=reject;Promise.resolve(network()).then(resolve,reject)})},destroy(){destroyed++;rejectRequest?.(Error('aborted'))}}}},bridge:{secureFile:fd=>fs.fchmodSync(fd,0o600),check:async text=>{let ok=false;try{ok=JSON.parse(text).outbounds?.length>0}catch{}return JSON.stringify({ok})}},readPrivate:name=>fs.readFileSync(name,'utf8'),writePrivate,DIRECT_PROFILE:config('direct'),BLOCK_IPV6_PROFILE:'negative'};
globalThis.__subscriptionEnv=sdk;
async function load(relative,names){
 const source=fs.readFileSync(new URL(relative,import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
 return import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(`const {${names}}=globalThis.__subscriptionEnv;\n${source}`,{mode:'strip'})).toString('base64'));
}
try {
 const store=await load('../entry/src/main/ets/common/ProfileStore.ets','fs,util,http,bridge,readPrivate,writePrivate,DIRECT_PROFILE,BLOCK_IPV6_PROFILE');Object.assign(sdk,store);
 const updates=await load('../entry/src/main/ets/common/SubscriptionUpdates.ets','fs,bridge,loadLibrary,loadSettings,refreshProfile,ProfileFetchCancellation,readPrivate,writePrivate');
 let library=store.loadLibrary(root);library=await store.addProfile(root,library,'active',config('original'));const active=library.selected;
 library=await store.addProfile(root,library,'remote',config('remote'),'https://example.invalid/profile?token=DO_NOT_PERSIST');const remote=library.selected;store.selectProfile(root,library,active);
 const run=(token=new store.ProfileFetchCancellation(),source='background',budget=100000)=>updates.runDueProfileUpdates(root,source,token,budget);
 await run();assert.equal(requests,0,'new subscriptions must not be fetched before due');now+=86400001;
 let result=await run();assert.equal(result.updated,1);assert.equal(store.readProfile(root,remote),config('download'));assert.equal(fs.readFileSync(path.join(root,'profile.json'),'utf8'),config('original'),'active runtime alias is not hot-reloaded');
 assert.equal(store.loadLibrary(root).selected,active);assert.equal(fs.statSync(path.join(root,'subscription-updates.json')).mode&0o777,0o600);
 assert(!fs.readFileSync(path.join(root,'subscription-updates.json'),'utf8').includes('DO_NOT_PERSIST'));
 now+=86400001;network=async()=>({responseCode:200,result:'bad json'});const before=store.readProfile(root,remote);
 result=await run();assert.equal(result.failed,1);assert.equal(store.readProfile(root,remote),before);
 const previousRequests=requests;await run();assert.equal(requests,previousRequests,'failed subscriptions back off rather than retry every UI tick');now+=900001;result=await run();assert.equal(result.attempts.find(a=>a.id===remote).failures,2);
 network=async()=>({responseCode:200,result:config('recovered')});now+=1800001;await run();assert.equal(store.readProfile(root,remote),config('recovered'));
 // A foreground and a background worker share a download lease.
 now+=86400001;network=()=>new Promise(resolve=>{releaseDownload=value=>resolve({responseCode:200,result:value})});
 const running=run();while(!releaseDownload)await Promise.resolve();const count=requests;
 result=await run(new store.ProfileFetchCancellation(),'foreground');assert.equal(result.phase,'busy');assert.equal(requests,count);releaseDownload(config('one-download'));await running;
 // Cancel destroys the active SDK request and cannot publish its contents.
 now+=86400001;releaseDownload=undefined;const cancellation=new store.ProfileFetchCancellation();const cancelledRun=run(cancellation);while(!releaseDownload)await Promise.resolve();const saved=store.readProfile(root,remote);cancellation.cancel();result=await cancelledRun;assert.equal(result.phase,'cancelled');assert.equal(store.readProfile(root,remote),saved);assert.equal(locks.size,0);
 releaseDownload=undefined;const disabling=run();while(!releaseDownload)await Promise.resolve();store.setAutoUpdate(root,remote,0);releaseDownload(config('disabled-during-download'));result=await disabling;assert.equal(result.skipped,1);assert.equal(store.readProfile(root,remote),saved);
 store.setAutoUpdate(root,remote,24);releaseDownload=undefined;const editing=run();while(!releaseDownload)await Promise.resolve();await store.editProfile(root,store.loadLibrary(root),remote,'manual',config('manual-wins'));releaseDownload(config('old-download'));result=await editing;assert.equal(result.skipped,1);assert.equal(store.readProfile(root,remote),config('manual-wins'));
 now+=86400001;releaseDownload=undefined;const deleting=run();while(!releaseDownload)await Promise.resolve();store.removeProfile(root,store.loadLibrary(root),remote);releaseDownload(config('must-not-resurrect'));result=await deleting;assert.equal(result.skipped,1);assert(!store.loadLibrary(root).profiles.some(p=>p.id===remote));
 // Global background opt-out still permits foreground checks.
 library=await store.addProfile(root,store.loadLibrary(root),'another',config('another'),'https://example.invalid/another');const another=library.selected;now+=86400001;
 const settings=store.defaultSettings();settings.backgroundUpdates=false;store.saveSettings(root,settings);network=async()=>({responseCode:200,result:config('foreground-only')});
 const noBackground=requests;result=await run();assert.equal(result.phase,'disabled');assert.equal(requests,noBackground);result=await run(new store.ProfileFetchCancellation(),'foreground');assert.equal(result.updated,1);
 assert.throws(()=>store.setAutoUpdate(root,another,NaN));assert.throws(()=>store.setAutoUpdate(root,another,0.5));assert.throws(()=>store.setAutoUpdate(root,another,169));assert.equal(locks.size,0);assert(destroyed>0);
 console.log('PASS: due scheduling, shared lease, private history, retry backoff, abort, rollback, edit/delete/disable conflicts, active-profile preservation and background opt-out.');
} finally {Date.now=dateNow;fs.rmSync(root,{recursive:true,force:true});delete globalThis.__subscriptionEnv}
