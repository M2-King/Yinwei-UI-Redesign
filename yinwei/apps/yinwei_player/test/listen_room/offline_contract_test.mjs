// Listen Room contract: the shipped page never touches the network, every file
// it references is in the folder, and vendored files match their pinned SHA-256.
// The review stand-in (dev/) is not shipped and is excluded.
// Run: node --test test/listen_room/
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir, stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join, relative} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../../assets/listen_room/', import.meta.url));
async function shippedFiles(dir = root) {
  const out = [];
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) { if (entry.name !== 'dev') out.push(...await shippedFiles(path)); }
    else out.push(path);
  }
  return out;
}
const rel = (p) => relative(root, p).replaceAll('\\', '/');

test('no http(s) URL anywhere in the shipped page', async () => {
  for (const file of await shippedFiles()) {
    if (!/\.(html|css|js|md|txt|json)$/.test(file)) continue;
    const text = await readFile(file, 'utf8');
    // Vendored files may name sites in comments, and three.js passes the XHTML
    // namespace name to createElementNS; neither is a fetch. Nothing else may.
    const scan = rel(file).startsWith('vendor/')
      ? text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '$1').replaceAll('http://www.w3.org/1999/xhtml', '')
      : text;
    const hit = scan.match(/https?:\/\/[^\s"')]+/);
    assert.equal(hit, null, `${rel(file)} references ${hit && hit[0]}`);
  }
});

test('every script, stylesheet and font the page uses is in the folder', async () => {
  const html = await readFile(join(root, 'index.html'), 'utf8');
  const css = await readFile(join(root, 'ui.css'), 'utf8');
  const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1])
    .concat([...css.matchAll(/url\("((?!data:)[^"]+)"\)/g)].map((m) => m[1]));
  assert.ok(refs.includes('vendor/three.min.js') && refs.includes('room.js'), 'the expected files are referenced');
  const missing = [];
  for (const ref of refs) { try { await stat(join(root, ref)); } catch { missing.push(ref); } }
  assert.deepEqual(missing, [], `missing files: ${missing.join(', ')}`);
});

for (const [dir, count, what] of [['vendor', 11, 'three.min.js and its 10 add-ons'], ['fonts', 2, 'the two fonts']]) {
  test(`${dir}/ files match the SHA-256 pinned in ${dir}/README.md`, async () => {
    const readme = await readFile(join(root, dir, 'README.md'), 'utf8');
    const pins = [...readme.matchAll(/`([0-9a-f]{64})`\s+`([^`]+)`/g)].map((m) => ({sha: m[1], file: m[2]}));
    assert.equal(pins.length, count, `expected pins for ${what}`);
    for (const {sha, file} of pins) {
      const got = createHash('sha256').update(await readFile(join(root, dir, file))).digest('hex');
      assert.equal(got, sha, `${dir}/${file}`);
    }
  });
}

test('the page loads the review stand-in only on request', async () => {
  const html = await readFile(join(root, 'index.html'), 'utf8');
  assert.ok(!html.includes('dev/'), 'index.html never references dev/');
  const ui = await readFile(join(root, 'ui.js'), 'utf8');
  assert.ok(ui.includes('if (/[?&]dev(=|&|$)/.test(location.search))'), 'ui.js loads dev/dev-host.js only with ?dev');
});
