// Export the actual sequences evaluated by every oracle assertion, including both owner replays.
// Run from any directory: node test/native_gestures/export_fixtures.mjs [--check].
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const folder = new URL('./fixtures/', import.meta.url);
let name = '', n = 0;
const fixtures = [];
globalThis.__yinweiGestureFixtures = {
  begin(value) { name = value; n = 0; },
  record(frames, out) {
    fixtures.push({name: `${name} [${++n}]`,
      // Old fixtures have recognizer confidence but no joint geometry. A confident named
      // pose is replayed with clear geometry margin; real margin tests use joints in Swift.
      frames: frames.map(f => ({...f, margin: f.g ? 1 : 0})),
      oldEvents: out.flatMap((o, i) => o.event ? [{event: o.event, t: frames[i].t}] : [])});
  }
};
const check = process.argv.includes('--check'), argv = process.argv;
// The legacy test accepts argv[2] as an optional core path. Do not pass exporter
// options through to that independent test entry point.
try {
  process.argv = argv.slice(0,2);
  await import('../listen_room/gesture_core_test.mjs');
} finally {
  process.argv = argv;
  delete globalThis.__yinweiGestureFixtures;
}
// Git stores LF, while a Windows checkout may have CRLF. Hash canonical source
// text so this freshness guard compares the same content on Windows and macOS.
const sha = url => createHash('sha256').update(readFileSync(new URL(url,import.meta.url),'utf8').replace(/\r\n/g,'\n')).digest('hex');
const data = JSON.stringify({schema: 1, sourceSha256: sha('../listen_room/gesture_core_test.mjs'),
  oracleCoreSha256: sha('../../assets/listen_room/gesture-core.js'), fixtures}, null, 2) + '\n';
const target = new URL('oracle.json', folder);
if (check) {
  if (readFileSync(target, 'utf8').replace(/\r\n/g,'\n') !== data) throw new Error('Fixtures stale: rerun exporter');
} else { mkdirSync(folder, {recursive:true}); writeFileSync(target, data); }
console.log(`${check ? 'Verified' : 'Exported'} ${fixtures.length} frame sequences to ${fileURLToPath(target)}`);
