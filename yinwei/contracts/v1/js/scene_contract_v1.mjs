//! SceneContractV1 — authoritative scene document validation.

const SCENE_SCHEMA_VERSION_V1 = 1;
const MAX_SOURCES_V1 = 32;
const MAX_EMITTERS_V1 = 8;
const MAX_ID_LENGTH_V1 = 64;
const QUAT_DEGENERATE_NORM_V1 = 1e-12;

export const FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1 = [
  'camera',
  'selection',
  'hover',
  'drag',
  'telemetry',
  'audio',
  'spatialParams',
  'arrayLayout',
];

const ID_PATTERN = /^[A-Za-z0-9_\-:.]+$/;

export function decideRevisionV1(appliedRevision, incomingRevision) {
  if (incomingRevision <= appliedRevision) {
    return { apply: false, reason: 'stale_revision', discontinuity: false };
  }
  return {
    apply: true,
    discontinuity: incomingRevision > appliedRevision + 1,
  };
}

function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

function validId(id) {
  return typeof id === 'string' && id.length > 0 && id.length <= MAX_ID_LENGTH_V1 && ID_PATTERN.test(id);
}

function validateObject(obj, expectedType) {
  if (!obj || typeof obj !== 'object') return 'invalid_object';
  if (!validId(obj.id)) return 'invalid_id';
  if (obj.type !== expectedType) return 'wrong_type';
  const pos = obj.worldPosition;
  if (!pos || typeof pos !== 'object') return 'non_finite_position';
  if (!isFiniteNumber(pos.x) || !isFiniteNumber(pos.y) || !isFiniteNumber(pos.z)) {
    return 'non_finite_position';
  }
  if (typeof obj.enabled !== 'boolean' || typeof obj.active !== 'boolean') {
    return 'invalid_flags';
  }
  if (Object.prototype.hasOwnProperty.call(obj, 'orientation')) {
    const q = obj.orientation;
    if (!q || typeof q !== 'object') return 'invalid_orientation';
    if (!isFiniteNumber(q.w) || !isFiniteNumber(q.x) || !isFiniteNumber(q.y) || !isFiniteNumber(q.z)) {
      return 'invalid_orientation';
    }
    const n2 = q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z;
    if (n2 < QUAT_DEGENERATE_NORM_V1 * QUAT_DEGENERATE_NORM_V1) {
      return 'invalid_orientation';
    }
  }
  return null;
}

export function validateSceneV1(scene) {
  if (!scene || typeof scene !== 'object') {
    return { valid: false, reason: 'invalid_document' };
  }
  for (const key of FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1) {
    if (Object.prototype.hasOwnProperty.call(scene, key)) {
      return { valid: false, reason: 'forbidden_key' };
    }
  }
  if (scene.schemaVersion !== SCENE_SCHEMA_VERSION_V1) {
    return { valid: false, reason: 'schema_version' };
  }
  if (!Number.isInteger(scene.revision) || scene.revision < 0) {
    return { valid: false, reason: 'invalid_revision' };
  }
  const listenerErr = validateObject(scene.listener, 'listener');
  if (listenerErr) return { valid: false, reason: listenerErr };
  if (!Array.isArray(scene.sources) || !Array.isArray(scene.emitters)) {
    return { valid: false, reason: 'invalid_collections' };
  }
  if (scene.sources.length > MAX_SOURCES_V1) {
    return { valid: false, reason: 'too_many_sources' };
  }
  if (scene.emitters.length > MAX_EMITTERS_V1) {
    return { valid: false, reason: 'too_many_emitters' };
  }
  const ids = new Set();
  ids.add(scene.listener.id);
  for (const item of scene.sources) {
    const err = validateObject(item, 'source');
    if (err) return { valid: false, reason: err };
    if (ids.has(item.id)) return { valid: false, reason: 'duplicate_id' };
    ids.add(item.id);
  }
  for (const item of scene.emitters) {
    const err = validateObject(item, 'emitter');
    if (err) return { valid: false, reason: err };
    if (ids.has(item.id)) return { valid: false, reason: 'duplicate_id' };
    ids.add(item.id);
  }
  return { valid: true, reason: null };
}
