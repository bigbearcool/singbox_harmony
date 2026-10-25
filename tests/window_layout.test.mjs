import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
const values=new Map(),events=new Map(),writes=[];
globalThis.AppStorage={setOrCreate:(key,value)=>values.set(key,value)};
const area=(top=0,bottom=0,left=0,right=0)=>({topRect:{height:top},bottomRect:{height:bottom},leftRect:{width:left},rightRect:{width:right}});
let system=area(96),indicator=area(0,80),cutout=area();let rect={width:1008,height:2232};
const main={on:(name,callback)=>events.set(name,callback),off:(name,callback)=>{assert.equal(events.get(name),callback);events.delete(name)},getUIContext:()=>({px2vp:n=>n/3}),getWindowAvoidArea:type=>[system,indicator,cutout][type],getWindowProperties:()=>({windowRect:rect})};
globalThis.__layoutEnv={window:{AvoidAreaType:{TYPE_SYSTEM:0,TYPE_NAVIGATION_INDICATOR:1,TYPE_CUTOUT:2}},writePrivate:(path,value)=>writes.push(JSON.parse(value))};
const source=fs.readFileSync(new URL('../entry/src/main/ets/common/WindowLayout.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {WindowLayout}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes('const {window,writePrivate}=globalThis.__layoutEnv;\n'+source,{mode:'strip'})).toString('base64'));
try {
 const layout=new WindowLayout();layout.bind(main,'/test');assert.equal(values.get('windowSafeTop'),32);assert.equal(values.get('windowSafeBottom'),80/3);assert(values.get('windowLayoutReady'));assert.equal(events.size,2);
 rect={width:2232,height:2000};system=area(120,90);cutout=area(0,0,42,12);events.get('windowSizeChange')(rect);assert.equal(values.get('windowSafeTop'),40);assert.equal(values.get('windowSafeBottom'),30);assert.equal(values.get('windowSafeLeft'),14);assert.equal(values.get('windowSafeRight'),4);assert.equal(writes.at(-1).width,2232);
 indicator=area(0,120);events.get('avoidAreaChange')({});assert.equal(values.get('windowSafeBottom'),40);layout.stop();assert.equal(events.size,0);
 console.log('PASS: system/status/gesture/cutout insets, density conversion, fold/resize changes, callback-scoped cleanup.');
} finally {delete globalThis.AppStorage;delete globalThis.__layoutEnv}
