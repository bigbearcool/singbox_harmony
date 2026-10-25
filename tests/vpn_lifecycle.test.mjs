import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
let env;const files=new Map();const intervals=new Set();
const originalInterval=globalThis.setInterval,originalClear=globalThis.clearInterval;
globalThis.setInterval=callback=>{intervals.add(callback);return callback};globalThis.clearInterval=callback=>intervals.delete(callback);
const initialStatus=()=>({phase:'stopped',message:'stopped',tunName:'',physicalInterface:'',ipv6AddressPresent:false,updatedAt:Date.now()});
const connection={NetBearType:{BEARER_VPN:4,BEARER_CELLULAR:0,BEARER_WIFI:1},NetCap:{NET_CAPABILITY_INTERNET:12},
 getDefaultNet:async()=>{if(env.networkPending)await env.networkPending;return {netId:1}},getAllNets:async()=>env.vpn?[{netId:1},{netId:2}]:[{netId:1}],
 getNetCapabilities:async net=>({bearerTypes:[net.netId===2?4:0],networkCap:[12]}),
 getConnectionProperties:async net=>net.netId===2?{interfaceName:'vpn-tun',linkAddresses:[{address:{address:'172.19.0.1'}},{address:{address:'fdfe:dcba:9876::1'}}],routes:[{destination:{address:{address:'0.0.0.0'},prefixLength:0}},{destination:{address:{address:'::'},prefixLength:0}}]}:{interfaceName:'rmnet0',linkAddresses:[{address:{family:2,address:'2001:db8::1'}}]}};
const bridge={check:async()=>'{"ok":true}',tunName:()=>'vpn-tun',interfaces:()=>JSON.stringify([{name:'vpn-tun',family:6,address:'fdfe:dcba:9876::1'}]),
 start:async()=>{env.startCalls++;if(env.startPending)await env.startPending;env.core=true;return '{"ok":true}'},stop:async()=>{env.stopCalls++;env.core=false},stats:async()=>JSON.stringify({uplink:0,downlink:0})};
globalThis.__vpnEnv={applyVpnScope:config=>config,loadVpnScope:()=>({mode:'all',applications:[]}),VpnExtensionAbility:class{context={filesDir:'/test'}},connection,bridge,vpnExtension:{createVpnConnection:()=>({create:async()=>{env.vpn=true;return 42},protectProcessNet:async()=>{},destroy:async()=>{env.destroyCalls++;env.vpn=false}}),stopVpnExtensionAbility:async()=>{}},wifiManager:{},loadSettings:()=>({autoReconnect:false,onDemand:false,bypassWifi:[]}),BUNDLE_NAME:'com.bigbear.singbox',VPN_ABILITY:'SingboxVpnAbility',readPrivate:path=>{if(files.has(path))return files.get(path);if(path.endsWith('profile.json'))return '{}';throw Error('absent')},writePrivate:(path,value)=>{files.set(path,value);if(path.endsWith('vpn-status.json'))env.phases.push(JSON.parse(value).phase)},initialStatus,hilog:{info(){},warn(){}}};
const source=fs.readFileSync(new URL('../entry/src/main/ets/vpn/SingboxVpnAbility.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {default:Ability}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {applyVpnScope,loadVpnScope,VpnExtensionAbility,connection,bridge,vpnExtension,wifiManager,loadSettings,BUNDLE_NAME,VPN_ABILITY,readPrivate,writePrivate,initialStatus,hilog}=globalThis.__vpnEnv;\n'+source,{mode:'strip'})).toString('base64'));
const reset=()=>{env={vpn:false,core:false,startCalls:0,stopCalls:0,destroyCalls:0,phases:[]};files.clear();intervals.clear()};
try {
 reset();let release;env.startPending=new Promise(resolve=>{release=resolve});let ability=new Ability();ability.onCreate({});while(env.startCalls===0)await Promise.resolve();ability.onDestroy();assert.equal(env.stopCalls,0,'destroy waits for startup rather than closing while native start is pending');release();await ability.task;assert(!env.core);assert(!env.vpn);assert.equal(env.destroyCalls,1);assert(!env.phases.includes('running'));
 reset();ability=new Ability();ability.onCreate({});await ability.task;assert(env.core && env.vpn);env.networkPending=new Promise(resolve=>{release=resolve});ability.tick();const tick=ability.task;ability.onDestroy();assert.equal(env.stopCalls,0,'destroy also waits for an in-flight network tick');release();await tick;await ability.task;assert(!env.core);assert(!env.vpn);assert.equal(env.destroyCalls,1);assert.equal(intervals.size,0);
 reset();ability=new Ability();ability.onCreate({});await ability.task;const before=env.phases.length;ability.publish('running',ability.status.message);assert.equal(env.phases.length,before,'unchanged background state does not write every second');ability.onDestroy();await ability.task;
 console.log('PASS: destruction during native startup/network tick, no late running state, idempotent resource release and background write throttling.');
} finally {globalThis.setInterval=originalInterval;globalThis.clearInterval=originalClear;delete globalThis.__vpnEnv}
