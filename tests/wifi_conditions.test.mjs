import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
let wifi='Home';let failed=false;let calls=0;
globalThis.__wifiEnv={util:{TextEncoder:class{encodeInto(value){return new TextEncoder().encode(value)}}},wifiManager:{getLinkedInfo:async()=>{calls++;if(failed)throw Error('201');return {ssid:wifi,get bssid(){throw Error('must not read randomized BSSID')}}}}};
const source=fs.readFileSync(new URL('../entry/src/main/ets/common/WifiConditions.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const api=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {util,wifiManager}=globalThis.__wifiEnv;\n'+source,{mode:'strip'})).toString('base64'));
try {
 let seen=await api.observeWifi('wifi');assert.equal(seen.state.ssid,'Home');assert(api.wifiPauseDecision(true,['Home'],seen,false,false));assert(!api.wifiPauseDecision(true,['home'],seen,false,false));
 wifi='Other';seen=await api.observeWifi('wifi');assert(!api.wifiPauseDecision(true,['Home'],seen,true,true));
 failed=true;seen=await api.observeWifi('wifi');assert.equal(seen.state.ssid,'');assert(!seen.known);assert(api.wifiPauseDecision(true,['Home'],seen,true,true));assert(!api.wifiPauseDecision(true,['Home'],seen,true,false));assert(!api.wifiPauseDecision(false,['Home'],seen,true,true));
 const before=calls;seen=await api.observeWifi('cellular');assert.equal(calls,before);assert.equal(seen.state.ssid,'');assert(!api.wifiPauseDecision(true,['Home'],seen,true,true));
 failed=false;for(wifi of ['', '<unknown ssid>','x'.repeat(33),'中'.repeat(11),'bad\0name']){assert(!(await api.observeWifi('wifi')).known);}
 wifi=' Home ';assert.equal((await api.observeWifi('wifi')).state.ssid,' Home ');assert.deepEqual(api.parseWifiNames(' Home \r\nHome\nHome\n'),[' Home ','Home']);assert.throws(()=>api.parseWifiNames('中'.repeat(11)));assert.throws(()=>api.parseWifiNames(Array.from({length:129},(_,i)=>'test'+i).join('\n')));
 console.log('PASS: physical Wi-Fi observations, exact SSID and UTF-8 limits, no BSSID access, unknown same-network pause preservation, cellular clearing and invalid settings.');
} finally {delete globalThis.__wifiEnv}
