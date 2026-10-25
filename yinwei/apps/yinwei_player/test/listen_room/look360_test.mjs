// Room look-around turns all the way round; focus rings are keyboard-only (owner, 2026-10-25).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const dir = new URL('../../assets/listen_room/', import.meta.url);
const room = fs.readFileSync(new URL('room.js', dir), 'utf8');
const css = fs.readFileSync(new URL('ui.css', dir), 'utf8');
const ui = fs.readFileSync(new URL('ui.js', dir), 'utf8');
const fn = (name) => {
  const start = room.indexOf(`function ${name}(`);
  assert.ok(start >= 0, name);
  let depth = 0, i = room.indexOf('{', start);
  for (; i < room.length; i++) { if (room[i] === '{') depth++; else if (room[i] === '}' && --depth === 0) break; }
  return room.slice(start, i + 1);
};

function context(mode, cam) {
  const ctx = vm.createContext({
    browseMode: mode, cam, DEG: Math.PI / 180,
    YAW_LIM: [-0.8, 0.8], LIFT_LIM: [8 * Math.PI / 180, 28 * Math.PI / 180],
    BROWSE_LOOK: { on: true, yaw: 0.5, lift: 9 * Math.PI / 180, back: 0 },
    browsePose: () => ({ yaw: -0.5, lift: 14 * Math.PI / 180, zoom: 0.6 }),
  });
  vm.runInContext(`${fn('lookLimits')}\n${fn('nearYaw')}`, ctx);
  return ctx;
}

test('room view has no turn limit; the quick menu keeps its bounded look', () => {
  const room3d = vm.runInContext('lookLimits()', context('album', { yaw: 0, tYaw: 0 }));
  assert.equal(room3d.y[0], -Infinity);
  assert.equal(room3d.y[1], Infinity);
  const compact = vm.runInContext('lookLimits()', context('compact', { yaw: 0, tYaw: 0 }));
  assert.ok(Number.isFinite(compact.y[0]) && Number.isFinite(compact.y[1]));
  assert.ok(compact.y[1] - compact.y[0] <= 1.0 + 1e-9);
});

test('a fixed view is reached the short way round, even after many turns', () => {
  for (const [yaw, target] of [[6.0, -0.14], [-9.5, -0.5], [3.3, -0.17], [0.3, -0.14]]) {
    const cam = { yaw, tYaw: target };
    vm.runInContext('nearYaw()', context('album', cam));
    assert.ok(Math.abs(cam.yaw - cam.tYaw) <= Math.PI + 1e-9, `${yaw} -> ${target}: ${cam.yaw}`);
    // The same heading (whole turns only)
    const turns = (yaw - cam.yaw) / (Math.PI * 2);
    assert.ok(Math.abs(turns - Math.round(turns)) < 1e-9);
  }
});

test('focus rings and the window list pill show only after keyboard use', () => {
  assert.match(css, /:focus, :focus-visible \{ outline: none; \}/);
  for (const rule of css.match(/[^}]*:focus-visible[^{]*\{[^}]*outline: 2px[^}]*\}/g) || []) {
    assert.match(rule, /html\.kbd/, rule.trim());
  }
  for (const rule of css.match(/[^}\n]*\.win-list:focus-within[^{]*\{/g) || []) {
    assert.match(rule, /html\.kbd/, rule.trim());
  }
  assert.match(ui, /classList\.add\("kbd"\)/);
  assert.match(ui, /addEventListener\("pointerdown", \(\) => document\.documentElement\.classList\.remove\("kbd"\)/);
});
