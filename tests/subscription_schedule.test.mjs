import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
let enabled=true,profiles=[{id:'one',url:'https://example.invalid',autoUpdateHours:1}];let works=[];let starts=0,stops=0;let failStart=false;const writes=new Map();
const workScheduler={NetworkType:{NETWORK_TYPE_ANY:0},obtainAllWorks:async()=>works,
 startWork(work){starts++;if(failStart)throw {code:9700005};works.push(work)},
 stopWork(work,cancel){stops++;assert.equal(cancel,true);works=works.filter(w=>w!==work)}};
globalThis.__scheduleEnv={workScheduler,loadLibrary:()=>({profiles}),loadSettings:()=>({backgroundUpdates:enabled}),BUNDLE_NAME:'com.bigbear.singbox',readPrivate:path=>writes.get(path),writePrivate:(path,value)=>writes.set(path,value)};
const source=fs.readFileSync(new URL('../entry/src/main/ets/common/SubscriptionSchedule.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const api=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {workScheduler,loadLibrary,loadSettings,BUNDLE_NAME,readPrivate,writePrivate}=globalThis.__scheduleEnv;\n'+source,{mode:'strip'})).toString('base64'));
try {
 let status=await api.syncSubscriptionSchedule('/test');assert(status.registered);assert.equal(works[0].repeatCycleTime,7200000);assert(works[0].isPersisted);assert(works[0].isRepeat);assert(!works[0].parameters);
 await Promise.all([api.syncSubscriptionSchedule('/test'),api.syncSubscriptionSchedule('/test')]);assert.equal(starts,1,'foregrounding must not reset an unchanged registration');
 const unrelated={workId:99,bundleName:'com.bigbear.singbox',abilityName:'OtherWork'};works.push(unrelated);
 enabled=false;status=await api.syncSubscriptionSchedule('/test');assert(!status.registered);assert.deepEqual(works,[unrelated]);assert.equal(stops,1);
 enabled=true;profiles[0].autoUpdateHours=24;await api.syncSubscriptionSchedule('/test');assert.equal(works[1].repeatCycleTime,86400000);
 profiles=[];await api.syncSubscriptionSchedule('/test');assert.deepEqual(works,[unrelated]);
 profiles=[{url:'https://example.invalid',autoUpdateHours:6}];failStart=true;status=await api.syncSubscriptionSchedule('/test');assert(!status.registered);assert.match(status.message,/9700005/);
 console.log('PASS: persisted repeating job, conservative minimum interval, idempotent reconciliation, cancellation, unrelated-job preservation and registration failure.');
} finally {delete globalThis.__scheduleEnv}
