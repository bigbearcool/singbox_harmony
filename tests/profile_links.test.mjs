import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import assert from 'node:assert/strict';
const source=await readFile(new URL('../entry/src/main/ets/common/ProfileLinks.ets',import.meta.url),'utf8');
const code=stripTypeScriptTypes(source,{mode:'strip'});
const api=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const remote='https://example.invalid/config?token=a%2Bb&name=x=y';
const name='回家 · 手机 #1';
const link=api.profileImportLink(name,remote);
assert.deepEqual(api.parseProfileImportLink(link),{name,url:remote});
assert(link.startsWith('sing-box://import-remote-profile?url='));
assert(link.endsWith('#'+encodeURIComponent(name)));
assert.deepEqual(api.parseProfileImportLink(remote),{name:'远程配置',url:remote});
for(const input of ['file:///etc/passwd','sing-box://other?url=https%3A%2F%2Fexample.invalid','sing-box://import-remote-profile?url=bad','sing-box://import-remote-profile?url=https%3A%2F%2Fa&url=https%3A%2F%2Fb','sing-box://import-remote-profile?url=%ZZ','sing-box://import-remote-profile?url=javascript%3Aalert(1)','https://example.invalid/a\nInjected','sing-box://import-remote-profile?url=']){
 assert.throws(()=>api.parseProfileImportLink(input));
}
console.log('PASS: SFM link/fragment interoperability, encoded tokens, duplicate/invalid input rejection.');
