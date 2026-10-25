import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {compareFixtures} from '../native_gestures/fixture_comparison.mjs';

const root=new URL('../../',import.meta.url);
const files=['assets/listen_room/gesture-core.js','test/listen_room/gesture_core_test.mjs',
  'test/native_gestures/export_fixtures.mjs','test/native_gestures/fixture_comparison.mjs',
  'test/native_gestures/fixtures/oracle.json'];
for(const [name,eol] of [['LF','\n'],['CRLF','\r\n']]) {
  test(`gesture fixture freshness survives a ${name} checkout`,()=>{
    const scratch=mkdtempSync(join(tmpdir(),'yinwei-gesture-fixture-'));
    try {
      for(const file of files) {
        const target=join(scratch,file);
        mkdirSync(dirname(target),{recursive:true});
        writeFileSync(target,readFileSync(new URL(file,root),'utf8').replace(/\r\n/g,'\n').replace(/\n/g,eol));
      }
      const result=spawnSync(process.execPath,[join(scratch,'test/native_gestures/export_fixtures.mjs'),'--check'],{encoding:'utf8'});
      assert.equal(result.status,0,result.stdout+result.stderr);
      assert.match(result.stdout,/Verified 65 frame sequences/);
    } finally {
      assert.equal(dirname(resolve(scratch)),resolve(tmpdir()));
      rmSync(scratch,{recursive:true,force:true});
    }
  });
}

test('fixture comparison permits only last-bit coordinate math variation',()=>{
  const expected={sourceSha256:'same',fixtures:[{frames:[{t:33,x:0.5,y:0.2,s:0.12,score:0.9}],oldEvents:[{event:'swipeLeft',t:66}]}]};
  const change=(fn)=>{const copy=structuredClone(expected);fn(copy);return copy;};
  assert.ok(compareFixtures(change(o=>{o.fixtures[0].frames[0].x+=5e-14;}),expected)>0);
  for(const alter of [
    o=>{o.sourceSha256='changed';},
    o=>{o.fixtures[0].frames[0].x+=2e-12;},
    o=>{o.fixtures[0].frames[0].score+=5e-14;},
    o=>{o.fixtures[0].frames[0].t+=5e-14;},
    o=>{o.fixtures[0].oldEvents[0].t+=5e-14;},
    o=>{o.fixtures[0].oldEvents[0].event='swipeRight';},
    o=>{delete o.fixtures[0].frames[0].y;},
    o=>{o.fixtures[0].frames[0].x=NaN;},
    o=>{o.fixtures[0].frames.push({...o.fixtures[0].frames[0]});}
  ]) assert.throws(()=>compareFixtures(change(alter),expected));
});
