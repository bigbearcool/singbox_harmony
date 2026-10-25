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
 console.log('PASS: default all-app capture, exclusive include/exclude lists, deduplication, limits, invalid rollback and corrupt-scope preservation.');
} finally {delete globalThis.__scopeEnv}
