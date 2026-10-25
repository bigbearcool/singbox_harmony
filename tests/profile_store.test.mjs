import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'bearbox-profile-test-'));
const locks=new Set();const files=new Map();
let network=async()=>({responseCode:200,result:config('downloaded')});
const config=tag=>JSON.stringify({outbounds:[{type:'direct',tag}],route:{final:tag}});
const nativeFs={OpenMode:{CREATE:fs.constants.O_CREAT,READ_WRITE:fs.constants.O_RDWR},accessSync:fs.existsSync,listFileSync:fs.readdirSync,unlinkSync:fs.unlinkSync,
 openSync(name,flags){const fd=fs.openSync(name,flags,0o600);const file={fd,name,locked:false,tryLock(){if(locks.has(name))throw Error('busy');locks.add(name);this.locked=true},unlock(){if(this.locked){locks.delete(name);this.locked=false}}};files.set(fd,file);return file},
 closeSync(file){file.unlock();files.delete(file.fd);fs.closeSync(file.fd)}};
const writePrivate=(name,value)=>{const tmp=name+'.'+crypto.randomUUID()+'.tmp';fs.writeFileSync(tmp,value,{mode:0o600});fs.renameSync(tmp,name)};
globalThis.__profileEnv={fs:nativeFs,util:{generateRandomUUID:crypto.randomUUID,TextEncoder:class{encodeInto(value){return new TextEncoder().encode(value)}}},http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'STRING'},createHttp:()=>({request:()=>network(),destroy(){}})},bridge:{secureFile:fd=>fs.fchmodSync(fd,0o600),check:async text=>{let ok=false;try{ok=JSON.parse(text).outbounds?.length>0}catch{}return JSON.stringify({ok})}},readPrivate:name=>fs.readFileSync(name,'utf8'),writePrivate,DIRECT_PROFILE:config('direct'),BLOCK_IPV6_PROFILE:'test-negative-preset'};
try {
 let source=fs.readFileSync(new URL('../entry/src/main/ets/common/ProfileStore.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
 source='const {fs,util,http,bridge,readPrivate,writePrivate,DIRECT_PROFILE,BLOCK_IPV6_PROFILE}=globalThis.__profileEnv;\n'+source;
 const api=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source,{mode:'strip'})).toString('base64'));
 assert.equal(api.defaultSettings().locationAssist,false);
 writePrivate(path.join(root,'settings.json'),JSON.stringify({autoReconnect:true}));assert.equal(api.loadSettings(root).locationAssist,false,'legacy settings must not silently enable location');
 writePrivate(path.join(root,'profile.json'),config('original'));
 let lib=api.loadLibrary(root);const first=lib.selected;
 assert.equal(api.readProfile(root,first),config('original'));
 lib=await api.addProfile(root,lib,'remote',config('remote'),'https://example.invalid/config');const second=lib.selected;
 let release;network=()=>new Promise(resolve=>{release=value=>resolve({responseCode:200,result:value})});
 const pending=api.refreshProfile(root,lib,second);
 api.selectProfile(root,lib,first);release(config('updated'));await pending;
 assert.equal(api.loadLibrary(root).selected,first);
 assert.equal(api.readProfile(root,second),config('updated'));
 assert.equal(fs.readFileSync(path.join(root,'profile.json'),'utf8'),config('original'));
 network=async()=>({responseCode:200,result:'{"outbounds":[]}'});
 await assert.rejects(api.refreshProfile(root,api.loadLibrary(root),second));
 assert.equal(api.readProfile(root,second),config('updated'));
 network=()=>new Promise(resolve=>{release=value=>resolve({responseCode:200,result:value})});
 const removedPending=api.refreshProfile(root,api.loadLibrary(root),second);
 api.removeProfile(root,api.loadLibrary(root),second);release(config('must-not-resurrect'));
 await assert.rejects(removedPending);assert.equal(api.loadLibrary(root).profiles.length,1);
 assert(!fs.readdirSync(root).some(name=>name.startsWith('saved-profile-'+second)));
 lib=await api.addProfile(root,api.loadLibrary(root),'remote-2',config('initial-2'),'https://example.invalid/config');const third=lib.selected;
 const editedPending=api.refreshProfile(root,lib,third);
 await api.editProfile(root,lib,third,'manual',config('manual-edit'));release(config('stale-download'));
 await assert.rejects(editedPending);assert.equal(api.readProfile(root,third),config('manual-edit'));
 const current=api.loadLibrary(root);locks.add(path.join(root,'profiles.lock'));
 assert.throws(()=>api.selectProfile(root,current,first));locks.delete(path.join(root,'profiles.lock'));
 assert.equal(api.loadLibrary(root).selected,third);
 fs.writeFileSync(path.join(root,'profiles.json'),'{broken');assert.throws(()=>api.loadLibrary(root));assert.equal(fs.readFileSync(path.join(root,'profiles.json'),'utf8'),'{broken');
 console.log('PASS: legacy migration, immutable revisions, invalid update rollback, selection preservation, delete/edit during download, lock contention, corrupt index preservation.');
} finally {fs.rmSync(root,{recursive:true,force:true});delete globalThis.__profileEnv}
