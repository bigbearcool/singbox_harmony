import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
let resolveRun;let calls=0;let stops=0;let activeToken;
globalThis.__workerEnv={loadLibrary:()=>({profiles:[]}),profileUpdateDue:()=>false,writePrivate:()=>{},WorkSchedulerExtensionAbility:class{context={filesDir:'/private-test'}},workScheduler:{stopWork:(work,cancel)=>{stops++;assert.equal(cancel,false)}},SUBSCRIPTION_WORK_ID:17001,SUBSCRIPTION_WORK_ABILITY:'SubscriptionWorkAbility',BUNDLE_NAME:'com.bigbear.singbox',ProfileFetchCancellation:class{cancelled=false;cancel(){this.cancelled=true}},runDueProfileUpdates:(dir,source,token,budget)=>{assert.equal(dir,'/private-test');assert.equal(source,'background');assert.equal(budget,100000);calls++;activeToken=token;return new Promise(resolve=>{resolveRun=resolve})}};
const source=fs.readFileSync(new URL('../entry/src/main/ets/work/SubscriptionWorkAbility.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {default:Worker}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {loadLibrary,profileUpdateDue,writePrivate,WorkSchedulerExtensionAbility,workScheduler,SUBSCRIPTION_WORK_ID,SUBSCRIPTION_WORK_ABILITY,BUNDLE_NAME,ProfileFetchCancellation,runDueProfileUpdates}=globalThis.__workerEnv;\n'+source,{mode:'strip'})).toString('base64'));
try {
 const worker=new Worker();const work={workId:17001,bundleName:'com.bigbear.singbox',abilityName:'SubscriptionWorkAbility'};
 worker.onWorkStart({...work,workId:2});assert.equal(calls,0);worker.onWorkStart(work);worker.onWorkStart(work);assert.equal(calls,1);
 worker.onWorkStop(work);assert(activeToken.cancelled);resolveRun();await Promise.resolve();await Promise.resolve();assert.equal(stops,1);
 worker.onWorkStart(work);assert.equal(calls,2);assert(!activeToken.cancelled);resolveRun();await Promise.resolve();await Promise.resolve();assert.equal(stops,2);
 console.log('PASS: WorkScheduler callback identity, duplicate-run guard, cancellation and completion without clearing repeated registration.');
} finally {delete globalThis.__workerEnv}
