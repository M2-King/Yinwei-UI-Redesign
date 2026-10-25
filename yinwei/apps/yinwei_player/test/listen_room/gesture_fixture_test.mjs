import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

const root=new URL('../../',import.meta.url);
const files=['assets/listen_room/gesture-core.js','test/listen_room/gesture_core_test.mjs',
  'test/native_gestures/export_fixtures.mjs','test/native_gestures/fixtures/oracle.json'];
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
