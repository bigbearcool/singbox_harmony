import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
const load=source=>import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source,{mode:'strip'})).toString('base64'));
const actions=await load(fs.readFileSync(new URL('../entry/src/main/ets/common/ShortcutActions.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,''));
const storage=new Map();let sequence=0;
globalThis.AppStorage={setOrCreate:(key,value)=>storage.set(key,value)};
globalThis.__shortcutEnv={...actions,util:{generateRandomUUID:()=>String(++sequence)},UIAbility:class{context={applicationInfo:{debug:false}}},parseProfileImportLink:()=>({url:'test',name:'test'})};
let source=fs.readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {default:Entry}=await load('const {UIAbility,shortcutActionFromWant,util,parseProfileImportLink}=globalThis.__shortcutEnv;\n'+source);
try {
 const entry=new Entry();entry.onCreate({parameters:{shortcutAction:'connect'}});assert.equal(JSON.parse(storage.get('pendingShortcut')).action,'connect');const first=storage.get('pendingShortcut');entry.onNewWant({parameters:{params:'{"shortcutAction":"disconnect"}'}});assert.equal(JSON.parse(storage.get('pendingShortcut')).action,'disconnect');assert.notEqual(storage.get('pendingShortcut'),first);entry.onNewWant({parameters:{shortcutAction:'invalid'}});assert.equal(JSON.parse(storage.get('pendingShortcut')).action,'disconnect');
 const page=fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8');
 // Execute the actual inbox method without ArkUI's rendering/decorator runtime.
 const start=page.indexOf(' private async consumeShortcut():');const end=page.indexOf(' private async disconnectVpn():',start);assert(start>0 && end>start);
 const {Consumer}=await load('const {validShortcutAction,runShortcutAction}=globalThis.__shortcutEnv; export class Consumer {\n'+page.slice(start,end)+'\n}');
 const consumer=new Consumer();const events=[];Object.assign(consumer,{pageVisible:true,appForeground:true,busy:false,controlBusy:false,shortcutHandling:false,status:{phase:'stopped'},ownVpnExists:async()=>false,toggle:async()=>{events.push('start');consumer.status.phase='starting'},disconnectVpn:async()=>{events.push('stop');consumer.status.phase='stopped'},control:async()=>events.push('reconnect')});
 const pending=action=>JSON.stringify({action,id:String(++sequence),createdAt:Date.now()});
 consumer.pendingShortcut=pending('connect');consumer.appForeground=false;await consumer.consumeShortcut();assert(consumer.pendingShortcut);assert.equal(events.length,0);consumer.appForeground=true;await consumer.consumeShortcut();assert.equal(consumer.pendingShortcut,'');assert.deepEqual(events,['start']);assert.equal(consumer.allowAutomaticConnect,false);
 consumer.pendingShortcut=pending('connect');await consumer.consumeShortcut();assert.deepEqual(events,['start']);consumer.pendingShortcut=pending('disconnect');consumer.busy=true;await consumer.consumeShortcut();assert(consumer.pendingShortcut);consumer.busy=false;await consumer.consumeShortcut();assert.deepEqual(events,['start','stop']);await consumer.consumeShortcut();assert.equal(events.length,2);
 consumer.pendingShortcut=JSON.stringify({action:'connect',createdAt:Date.now()-31000});await consumer.consumeShortcut();assert.equal(events.length,2);consumer.pendingShortcut='{';await consumer.consumeShortcut();assert.equal(consumer.pendingShortcut,'');assert(!consumer.busy);
 let release;consumer.ownVpnExists=()=>new Promise(resolve=>{release=resolve});consumer.pendingShortcut=pending('connect');const task=consumer.consumeShortcut();consumer.appForeground=false;release(false);await task;assert.equal(events.length,2);assert(!consumer.busy && !consumer.shortcutHandling);
 console.log('PASS: actual UIAbility cold/warm Want delivery and page inbox foreground gating, one-shot consumption, busy deferral, expiry and background cancellation.');
} finally {delete globalThis.AppStorage;delete globalThis.__shortcutEnv}
