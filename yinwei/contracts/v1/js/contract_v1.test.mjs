import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  geometricDistanceM,
  hrtfUnitFromLocal,
  lerpAzimuthDeg,
  localToSpherical,
  shortestAzimuthDeltaDeg,
  sphericalToLocal,
  vecLength,
  worldToListenerLocal,
  wrapAzimuthDeg,
} from './coordinate_frame_v1.mjs';
import { decideRevisionV1, FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1, validateSceneV1 } from './scene_contract_v1.mjs';
import { SpeakerSemanticsV1 } from './speaker_semantics_v1.mjs';

const here = dirname(fileURLToPath(import.meta.url));

function loadFixture(name) {
  const path = join(here, '..', 'fixtures', name);
  return JSON.parse(readFileSync(path, 'utf8'));
}

function near(got, want, eps, label) {
  assert.ok(Math.abs(got - want) <= eps, `${label}: got ${got} want ${want} eps ${eps}`);
}

function nearVec(got, want, eps, label) {
  near(got.x, want.x, eps, `${label}.x`);
  near(got.y, want.y, eps, `${label}.y`);
  near(got.z, want.z, eps, `${label}.z`);
}

test('CoordinateFrameV1 fixtures', () => {
  const fixture = loadFixture('coordinate_fixtures_v1.json');
  assert.equal(fixture.schemaId, 'CoordinateFrameV1');
  assert.deepEqual(fixture.quaternionStorageOrder, ['w', 'x', 'y', 'z']);
  const tight = fixture.tolerance;
  const trig = fixture.trigTolerance;
  for (const c of fixture.cases) {
    const eps = String(c.id).includes('elevation_near') ? trig : tight;
    if (c.kind === 'pose_roundtrip') {
      const local = sphericalToLocal(c.input);
      nearVec(local, c.expect.world, eps, c.id);
      nearVec(local, c.expect.listenerLocal, eps, c.id);
      nearVec(hrtfUnitFromLocal(local), c.expect.hrtfUnit, eps, `${c.id} unit`);
      const back = localToSpherical(local);
      near(back.azimuthDeg, c.expect.azimuthDeg, trig, `${c.id} az`);
      near(back.elevationDeg, c.expect.elevationDeg, trig, `${c.id} el`);
      near(back.distanceM, c.expect.distanceM, eps, `${c.id} dist`);
      near(geometricDistanceM(local), c.expect.dspDistanceM, eps, `${c.id} dsp`);
      near(vecLength(hrtfUnitFromLocal(local)), 1, tight, `${c.id} unitlen`);
    } else if (c.kind === 'world_to_listener') {
      const local = worldToListenerLocal(c.world, {
        worldPosition: c.listener.worldPosition,
        orientation: c.listener.orientation,
      });
      nearVec(local, c.expect.listenerLocal, trig, c.id);
      nearVec(hrtfUnitFromLocal(local), c.expect.hrtfUnit, trig, `${c.id} unit`);
      const sph = localToSpherical(local);
      near(sph.azimuthDeg, c.expect.azimuthDeg, trig, `${c.id} az`);
      near(sph.elevationDeg, c.expect.elevationDeg, trig, `${c.id} el`);
      near(sph.distanceM, c.expect.distanceM, trig, `${c.id} dist`);
      near(geometricDistanceM(local), c.expect.dspDistanceM, trig, `${c.id} dsp`);
    } else if (c.kind === 'wrap_azimuth') {
      near(wrapAzimuthDeg(c.inputDeg), c.expectDeg, tight, c.id);
    } else if (c.kind === 'shortest_arc') {
      near(shortestAzimuthDeltaDeg(c.fromDeg, c.toDeg), c.expectDeltaDeg, tight, c.id);
      near(lerpAzimuthDeg(c.fromDeg, c.toDeg, c.t), c.expectInterpDeg, tight, `${c.id} lerp`);
    } else if (c.kind === 'cartesian_to_spherical') {
      const sph = localToSpherical(c.listenerLocal);
      near(sph.azimuthDeg, c.expect.azimuthDeg, trig, c.id);
      near(sph.elevationDeg, c.expect.elevationDeg, trig, c.id);
      near(sph.distanceM, c.expect.distanceM, tight, c.id);
      nearVec(hrtfUnitFromLocal(c.listenerLocal), c.expect.hrtfUnit, tight, c.id);
    } else if (c.kind === 'zero_distance') {
      const local = worldToListenerLocal(c.world, {
        worldPosition: c.listener.worldPosition,
        orientation: c.listener.orientation,
      });
      nearVec(local, c.expect.listenerLocal, tight, c.id);
      nearVec(hrtfUnitFromLocal(local), c.expect.hrtfUnit, tight, `${c.id} unit`);
      const sph = localToSpherical(local);
      near(sph.azimuthDeg, c.expect.azimuthDeg, tight, c.id);
      near(sph.elevationDeg, c.expect.elevationDeg, tight, c.id);
      near(sph.distanceM, c.expect.distanceM, tight, c.id);
      assert.equal(c.expect.dspDistanceIndependent, true);
      near(vecLength(hrtfUnitFromLocal(local)), 1, tight, `${c.id} unitlen`);
      near(geometricDistanceM(local), 0, tight, `${c.id} geom`);
    } else {
      throw new Error(`unknown kind ${c.kind}`);
    }
  }
});

test('SceneContractV1 fixtures', () => {
  const fixture = loadFixture('scene_fixtures_v1.json');
  assert.equal(fixture.schemaId, 'SceneContractV1');
  assert.deepEqual(fixture.forbiddenTopLevelKeys, FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1);
  for (const c of fixture.cases) {
    if (c.kind === 'validate') {
      const result = validateSceneV1(c.scene);
      assert.equal(result.valid, c.expect.valid, c.id);
      if (!c.expect.valid) {
        assert.equal(result.reason, c.expect.reason, c.id);
      }
    } else if (c.kind === 'revision') {
      const verdict = decideRevisionV1(c.appliedRevision, c.incomingRevision);
      assert.equal(verdict.apply, c.expect.apply, c.id);
      if (c.expect.discontinuity === true) {
        assert.equal(verdict.discontinuity, true, c.id);
      }
    } else {
      throw new Error(`unknown kind ${c.kind}`);
    }
  }
});

test('SpeakerSemanticsV1 fixtures', () => {
  const fixture = loadFixture('speaker_semantics_v1.json');
  assert.equal(fixture.schemaId, 'SpeakerSemanticsV1');
  const engine = fixture.currentEngine;
  assert.equal(SpeakerSemanticsV1.input, engine.input);
  assert.equal(SpeakerSemanticsV1.inputChannelCount, engine.inputChannelCount);
  assert.deepEqual(SpeakerSemanticsV1.acousticFeeds, engine.acousticFeeds);
  assert.equal(SpeakerSemanticsV1.isDiscrete71, false);
  assert.equal(SpeakerSemanticsV1.trueMultichannelRoutingInScope, false);
  assert.equal(SpeakerSemanticsV1.maxVisualEmitters, 8);
  for (const name of fixture.cases.find((c) => c.id === 'center_lfe_rear_side_have_no_feed').expect.unknownFeeds) {
    assert.equal(SpeakerSemanticsV1.isAcousticFeed(name), false, name);
  }
});
