import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile(new URL('../../assets/listen_room/room.js',import.meta.url),'utf8');
function setup(reduced=false,tall=false){
 const ctx=vm.createContext({DEG:Math.PI/180,reduced,innerWidth:tall?820:1180,innerHeight:tall?1180:820,finishOpening(){},browseMode:'album',entrance:null,camMoving:false});
 vm.runInContext(source.slice(0,source.indexOf('// One render of everything')),ctx);
 vm.runInContext(source.match(/const YAW_LIM[^;]+;/)[0],ctx); const run=c=>vm.runInContext(c,ctx);return {run,targets:()=>JSON.parse(run('JSON.stringify([cam.tYaw,cam.tLift,cam.tZoom,cam.tK])'))};
}
test('compact/window camera saves and restores every target including top view',()=>{
 const h=setup();h.run('Object.assign(cam,{tYaw:.5,tLift:.3,tZoom:.86,tK:1});browseCamera("compact");browseCamera("window");browseCamera("album")');
 assert.deepEqual(h.targets(),[.5,.3,.86,1]);
});
test('browse look has its own portrait pose and clears fling',()=>{
 const h=setup(false,true);h.run('fling={yaw:1};browseMode="compact";browseCamera("compact")');
 assert.deepEqual(h.targets(),[.1,24*(Math.PI/180),.6,0]);assert.equal(h.run('fling'),null);assert.equal(h.run('camLocked()'),true);
 assert.ok(h.run('lookLimits().y[1]-lookLimits().y[0] <= BROWSE_LOOK.yaw*2+.00001'));
});
test('reduced motion snaps entry and restored pose without interrupting playback',()=>{
 const h=setup(true);h.run('Object.assign(cam,{tYaw:.6,tLift:.2,tZoom:1.2,tK:1});browseCamera("compact")');
 assert.equal(h.run('cam.yaw===cam.tYaw && cam.zoom===.6 && cam.k===0'),true);
 h.run('browseCamera("album")');assert.deepEqual(h.targets(),[.6,.2,1.2,1]);assert.equal(h.run('cam.k===1 && cam.yaw===.6'),true);
});
