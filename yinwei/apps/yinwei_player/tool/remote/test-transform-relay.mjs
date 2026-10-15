// Manual transport test. Never reads production configuration or credentials,
// publishes a bookmark, stops a player, or modifies a Cloudflare account.
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {QuickBridge} from '../../../../tools/remote/quick-transport.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const player = resolve(here, '../..');
const root = resolve(player, '../../..');
const binary = resolve(root, '.tmp/yinwei-tools/cloudflared-2026.10.0.exe');
const expected = '86aee4017b26625cee8484c113558f48effa4cd47f7aa05fcf425604e5d2b23c';
if (createHash('sha256').update(await readFile(binary)).digest('hex') !== expected) {
  throw Error('test_connector_checksum_mismatch');
}
const port = 18477; // Isolated test gateway; bind fails if already in use.
const bridge = new QuickBridge();
let tunnel, tests, heartbeat;
const temp = resolve(root, '.tmp/r1-public-relay');
await mkdir(temp, {recursive: true});
const config = resolve(temp, 'empty-config.yml');
await writeFile(config, '{}\n');
try {
  const local = await bridge.start();
  let discover;
  const originReady = new Promise((res, rej) => {
    const deadline = setTimeout(() => rej(Error('test_tunnel_timeout')), 45000);
    discover = value => {clearTimeout(deadline); res(value);};
  });
  // Prevent implicit loading of any other project's tunnel configuration.
  tunnel = spawn(binary, ['tunnel', '--config', config, '--no-autoupdate',
    '--url', local, '--protocol', 'http2'], {windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe']});
  let output = '';
  const scan = chunk => {
    output = (output + chunk.toString()).slice(-8192);
    const match = output.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (match) discover(match[0]);
  };
  tunnel.stdout.on('data', scan);
  tunnel.stderr.on('data', scan);
  const origin = await originReady;
  bridge.setOrigin(origin);
  // QuickBridge uses the launcher's identity/heartbeat. No private host token
  // or production account/state file is required by the ephemeral adapter.
  const attach = () => bridge.attach({projectId: 'yinwei-remote',
    publicOrigin: origin, port, processId: process.pid, updatedAt: Date.now()});
  attach();
  heartbeat = setInterval(attach, 1000);
  console.log('R1 isolated test relay ready; generated PCM only.');
  const log = [];
  const testFile = process.env.YINWEI_R2_NATIVE_DLL ?
    'test/remote/remote_native_relay_test.dart' : 'test/remote/remote_transform_relay_test.dart';
  tests = spawn('cmd.exe', ['/d', '/c',
    `flutter test --no-pub ${testFile}`], {
    cwd: player, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    env: {...process.env, YINWEI_R1_RELAY_ORIGIN: origin,
      YINWEI_R1_RELAY_PORT: String(port)}});
  tests.stdout.on('data', chunk => log.push(chunk.toString()));
  tests.stderr.on('data', chunk => log.push(chunk.toString()));
  const exitCode = await new Promise((res, rej) => {
    tests.once('error', rej); tests.once('exit', res);
  });
  const text = log.join('');
  await writeFile(resolve(temp, 'test.log'), text);
  console.log(text.split(/\r?\n/).filter(line =>
    /R1_PUBLIC_TRANSPORT|R2_PUBLIC_NATIVE|All tests passed|Some tests failed|Exception|Error|Expected:|Actual:/.test(line)).join('\n'));
  process.exitCode = exitCode ?? 1;
} finally {
  clearInterval(heartbeat);
  if (tunnel) tunnel.kill();
  bridge.detach();
  bridge.upgrader.close();
  await new Promise(res => bridge.server.close(res));
}
