import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
const data=new Map();globalThis.__scopeEnv={fs:{accessSync:path=>data.has(path)},readPrivate:path=>data.get(path),writePrivate:(path,value)=>data.set(path,value)};
const source=fs.readFileSync(new URL('../entry/src/main/ets/common/VpnScope.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const api=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {fs,readPrivate,writePrivate}=globalThis.__scopeEnv;\n'+source,{mode:'strip'})).toString('base64'));
try {
 assert.equal(api.loadVpnScope('/test').mode,'all');
 const include=api.saveVpnScope('/test','include','com.example.app\ncom.example.app\ncom.example.other');assert.equal(include.applications.length,2);
 const config={isIPv6Accepted:true,routes:[{dualStack:true}],blockedApplications:['old.app']};api.applyVpnScope(config,include);assert.equal(config.blockedApplications,undefined);assert.deepEqual(config.trustedApplications,include.applications);assert(config.isIPv6Accepted);assert.equal(config.routes.length,1);
 api.applyVpnScope(config,api.validateVpnScope('exclude',['com.example.other']));assert.equal(config.trustedApplications,undefined);assert.deepEqual(config.blockedApplications,['com.example.other']);
 assert.throws(()=>api.saveVpnScope('/test','include',''));assert.equal(api.loadVpnScope('/test').mode,'include','invalid edits must not replace a saved scope');
 assert.throws(()=>api.validateVpnScope('include',Array.from({length:257},(_,i)=>'com.example.app'+i)));assert.throws(()=>api.validateVpnScope('include',['../../escape']));
 data.set('/test/vpn-scope.json','{invalid');assert.throws(()=>api.loadVpnScope('/test'),'corrupt scope cannot silently enable all-app routing');
 // APP_SCOPE_PRESETS validation
 assert.equal(api.APP_SCOPE_PRESETS.length,3);
 assert.deepEqual(api.APP_SCOPE_PRESETS.map(c=>c.title),['金融支付','国内社交与出行','国内影音与购物']);
 const allPresetBundles=api.APP_SCOPE_PRESETS.flatMap(c=>c.items.map(i=>i.bundleName));
 assert.equal(allPresetBundles.length,12);
 assert(allPresetBundles.includes('com.alipay.mobile.client'));
 assert(allPresetBundles.includes('com.tencent.wechat'));
 assert(allPresetBundles.includes('yylx.danmaku.bili'));
 const validatedPresets=api.validateVpnScope('exclude',allPresetBundles);
 assert.equal(validatedPresets.applications.length,12);
 // toggleScopePackage immutability and add/remove behavior
 const baseScope={mode:'exclude',applications:['com.tencent.wechat']};
 const added=api.toggleScopePackage(baseScope,'com.alipay.mobile.client');
 assert.deepEqual(baseScope.applications,['com.tencent.wechat'],'input scope must not be mutated');
 assert.deepEqual(added,{mode:'exclude',applications:['com.tencent.wechat','com.alipay.mobile.client']});
 const removed=api.toggleScopePackage(added,'com.tencent.wechat');
 assert.deepEqual(added.applications,['com.tencent.wechat','com.alipay.mobile.client'],'previous scope must not be mutated');
 assert.deepEqual(removed,{mode:'exclude',applications:['com.alipay.mobile.client']});
 const unchanged=api.toggleScopePackage(removed,'   ');
 assert.deepEqual(unchanged,{mode:'exclude',applications:['com.alipay.mobile.client']});
 assert.notEqual(unchanged,removed);
 console.log('PASS: default all-app capture, exclusive include/exclude lists, deduplication, limits, invalid rollback, corrupt-scope preservation, APP_SCOPE_PRESETS, and toggleScopePackage.');
} finally {delete globalThis.__scopeEnv}
