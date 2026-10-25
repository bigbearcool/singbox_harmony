import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

// Run the real ETS controller with SDK substitutes. No location hardware,
// network requests, coordinates or device permissions are used by this test.
let env;
const appStorage=new Map();
globalThis.AppStorage={setOrCreate:(key,value)=>appStorage.set(key,value)};
const originalInterval=globalThis.setInterval,originalClear=globalThis.clearInterval;
globalThis.setInterval=callback=>{env.timers.add(callback);return callback};
globalThis.clearInterval=callback=>env.timers.delete(callback);
const events=new Map();
const geoLocationManager={LocationRequestPriority:{LOW_POWER:514},isLocationEnabled:()=>env.locationOn,
 onLocationChange(request,callback){assert.equal(request.priority,514);assert.equal(request.timeInterval,60);env.locationCallback=callback;env.subscriptions++},
 offLocationChange(callback){assert.equal(callback,env.locationCallback);if(env.offFails)throw Error('off failed');env.subscriptions--;env.locationCallback=null}};
const backgroundTaskManager={
 on:(event,callback)=>{if(event===env.failListener)throw Error('event registration failed');events.set(event,callback)},
 off:(event,callback)=>{assert.equal(events.get(event),callback);events.delete(event)},
 startBackgroundRunning:async(context,modes,agent)=>{env.starts++;assert.deepEqual(modes,['location']);if(env.startFails)throw {code:9800005};if(env.pendingStart)await env.pendingStart;env.tasks.add(42);return {continuousTaskId:42,notificationId:92}},
 stopBackgroundRunning:async(context,id)=>{assert.equal(id,42);env.tasks.delete(id);env.stops++}
};
const abilityAccessCtrl={GrantStatus:{PERMISSION_GRANTED:0},createAtManager:()=>({checkAccessTokenSync:()=>env.granted?0:-1,
 requestPermissionsFromUser:async(context,permissions)=>{env.permissionRequests++;assert.deepEqual(permissions,['ohos.permission.APPROXIMATELY_LOCATION']);return {authResults:[env.granted?0:-1]}}})};
const connection={NetBearType:{BEARER_VPN:4},getAllNets:async()=>{if(env.netFails)throw Error('network service unavailable');return env.vpn?[{netId:100}]:[]},getNetCapabilities:async()=>({bearerTypes:[4]}),getConnectionProperties:async()=>({linkAddresses:['172.19.0.1','fdfe:dcba:9876::1'].map(address=>({address:{address}}))})};
globalThis.__locationEnv={abilityAccessCtrl,backgroundTaskManager,geoLocationManager,connection,wantAgent:{OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:4},getWantAgent:async()=>({})},loadSettings:()=>({locationAssist:env.enabled}),BUNDLE_NAME:'com.bigbear.singbox',readPrivate:()=>JSON.stringify(env.status)};
let source=fs.readFileSync(new URL('../entry/src/main/ets/common/LocationAssist.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
source='const {abilityAccessCtrl,backgroundTaskManager,geoLocationManager,connection,wantAgent,loadSettings,BUNDLE_NAME,readPrivate}=globalThis.__locationEnv;\n'+source;
const {LocationAssist}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source,{mode:'strip'})).toString('base64'));
function fresh(overrides={}){
 assert.equal(events.size,0);appStorage.clear();
 env={enabled:false,granted:true,locationOn:true,vpn:false,starts:0,stops:0,permissionRequests:0,subscriptions:0,tasks:new Set(),timers:new Set(),status:{phase:'starting',updatedAt:Date.now()},...overrides};
 const manager=new LocationAssist();manager.initialize({applicationInfo:{accessTokenId:1},filesDir:'/test'});return manager;
}
const note=()=>appStorage.get('locationAssistStatus');
const drained=async manager=>{await manager.queue};
try {
 let manager=fresh();await manager.onForeground();await manager.beginSession();assert.equal(env.starts,0);assert.equal(env.subscriptions,0);assert.equal(env.permissionRequests,0);
 manager=fresh({granted:false});assert.equal(await manager.requestPermission(),false);assert.equal(env.permissionRequests,1);assert.equal(env.subscriptions,0);
 manager=fresh({enabled:true});await manager.onForeground();assert.equal(env.starts,0);await manager.beginSession();assert.equal(env.starts,1);assert.equal(env.subscriptions,1);
 // A Location object whose properties must never be inspected.
 const coordinates=new Proxy({},{get(){throw Error('coordinates were accessed')}});env.locationCallback(coordinates);
 assert(!JSON.stringify([...appStorage]).includes('latitude'));await manager.stop();assert.equal(env.subscriptions,0);assert.equal(env.tasks.size,0);assert.equal(env.timers.size,0);
 manager=fresh({enabled:true,startFails:true});await manager.onForeground();await manager.beginSession();assert.equal(env.subscriptions,0);assert.equal(events.size,0);assert.match(note(),/9800005/);
 manager=fresh({enabled:true,failListener:'continuousTaskSuspend'});await manager.onForeground();await manager.beginSession();assert.equal(env.subscriptions,0);assert.equal(events.size,0);
 let resolveStart;manager=fresh({enabled:true,pendingStart:new Promise(resolve=>{resolveStart=resolve})});await manager.onForeground();const starting=manager.beginSession();
 while(env.starts===0)await Promise.resolve();const stopping=manager.stop();resolveStart();await Promise.all([starting,stopping]);assert.equal(env.subscriptions,0);assert.equal(env.tasks.size,0);assert.equal(env.timers.size,0);
 manager=fresh({enabled:true,vpn:true});await manager.onForeground();events.get('continuousTaskSuspend')({continuousTaskId:42,suspendReason:9});assert.match(note(),/挂起/);
 events.get('continuousTaskActive')({id:42});assert.match(note(),/恢复/);env.tasks.delete(42);events.get('continuousTaskCancel')({id:42,reason:3});await drained(manager);assert.equal(env.subscriptions,0);
 await manager.onForeground();assert.equal(env.starts,1,'a cancelled task must not be silently recreated');
 manager=fresh({enabled:true,vpn:true});await manager.onForeground();env.granted=false;await manager.inspect();await drained(manager);assert.equal(env.tasks.size,0);assert.equal(env.subscriptions,0);
 manager=fresh({enabled:true,vpn:true});await manager.onForeground();env.status={phase:'stopped',updatedAt:Date.now()+1};await manager.inspect();await drained(manager);assert.equal(env.tasks.size,0);assert.equal(env.subscriptions,0);
 manager=fresh({enabled:true,vpn:true});await manager.onForeground();env.netFails=true;manager.missingSince=Date.now()-90001;await manager.inspect();await drained(manager);assert.equal(env.subscriptions,0);assert.equal(env.tasks.size,0,'unknown VPN state must not leave location running forever');
 manager=fresh({enabled:true,vpn:true});await manager.onForeground();env.offFails=true;await manager.stop();assert.equal(env.tasks.size,0,'task must still be released when location cancellation fails');assert.equal(env.subscriptions,1);assert.match(note(),/清理未完成/);env.offFails=false;await manager.stop();assert.equal(env.subscriptions,0);
 manager=fresh({enabled:true,locationOn:false});await manager.onForeground();await manager.beginSession();assert.equal(env.starts,0);assert.equal(env.subscriptions,0);assert.match(note(),/系统定位已关闭/);
 manager=fresh({enabled:true});await manager.onForeground();manager.onBackground();await manager.beginSession();assert.equal(env.starts,0,'background code cannot request a UI-owned task');
 console.log('PASS: default off, coarse permission, VPN gating, coordinate discard, cancel/suspend, late-start cancellation, rollback, resource cleanup and background guards.');
} finally {globalThis.setInterval=originalInterval;globalThis.clearInterval=originalClear;delete globalThis.__locationEnv;delete globalThis.AppStorage}
