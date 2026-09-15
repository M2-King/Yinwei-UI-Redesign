//! SceneContractV1 — authoritative scene document validation.

use serde_json::Value;

pub const SCENE_SCHEMA_VERSION_V1: u64 = 1;
pub const MAX_SOURCES_V1: usize = 32;
pub const MAX_EMITTERS_V1: usize = 8;
pub const MAX_ID_LENGTH_V1: usize = 64;
pub const QUAT_DEGENERATE_NORM_V1: f64 = 1e-12;

pub const FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1: &[&str] = &[
    "camera",
    "selection",
    "hover",
    "drag",
    "telemetry",
    "audio",
    "spatialParams",
    "arrayLayout",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneValidationV1 {
    pub valid: bool,
    pub reason: Option<String>,
}

impl SceneValidationV1 {
    pub fn ok() -> Self {
        Self {
            valid: true,
            reason: None,
        }
    }

    pub fn invalid(reason: &str) -> Self {
        Self {
            valid: false,
            reason: Some(reason.to_string()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RevisionDecisionV1 {
    Apply,
    RejectStale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RevisionVerdictV1 {
    pub decision: RevisionDecisionV1,
    pub discontinuity: bool,
}

impl RevisionVerdictV1 {
    pub fn apply(self) -> bool {
        self.decision == RevisionDecisionV1::Apply
    }
}

pub fn decide_revision_v1(applied_revision: u64, incoming_revision: u64) -> RevisionVerdictV1 {
    if incoming_revision <= applied_revision {
        return RevisionVerdictV1 {
            decision: RevisionDecisionV1::RejectStale,
            discontinuity: false,
        };
    }
    RevisionVerdictV1 {
        decision: RevisionDecisionV1::Apply,
        discontinuity: incoming_revision > applied_revision + 1,
    }
}

fn is_finite_number(v: &Value) -> bool {
    v.as_f64().map(|n| n.is_finite()).unwrap_or(false)
}

fn valid_id(v: &Value) -> bool {
    let Some(s) = v.as_str() else {
        return false;
    };
    if s.is_empty() || s.len() > MAX_ID_LENGTH_V1 {
        return false;
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))
}

fn finite_field(map: &serde_json::Map<String, Value>, key: &str) -> bool {
    map.get(key).map(is_finite_number).unwrap_or(false)
}

fn validate_object(obj: &Value, expected_type: &str) -> Option<&'static str> {
    let map = obj.as_object()?;
    let Some(id) = map.get("id") else {
        return Some("invalid_id");
    };
    if !valid_id(id) {
        return Some("invalid_id");
    }
    if map.get("type").and_then(|t| t.as_str()) != Some(expected_type) {
        return Some("wrong_type");
    }
    let Some(pos) = map.get("worldPosition").and_then(|p| p.as_object()) else {
        return Some("non_finite_position");
    };
    if !finite_field(pos, "x") || !finite_field(pos, "y") || !finite_field(pos, "z") {
        return Some("non_finite_position");
    }
    if map.get("enabled").and_then(|v| v.as_bool()).is_none()
        || map.get("active").and_then(|v| v.as_bool()).is_none()
    {
        return Some("invalid_flags");
    }
    if let Some(q) = map.get("orientation") {
        let Some(qm) = q.as_object() else {
            return Some("invalid_orientation");
        };
        if !finite_field(qm, "w")
            || !finite_field(qm, "x")
            || !finite_field(qm, "y")
            || !finite_field(qm, "z")
        {
            return Some("invalid_orientation");
        }
        let w = qm.get("w").and_then(Value::as_f64).unwrap();
        let x = qm.get("x").and_then(Value::as_f64).unwrap();
        let y = qm.get("y").and_then(Value::as_f64).unwrap();
        let z = qm.get("z").and_then(Value::as_f64).unwrap();
        let n2 = w * w + x * x + y * y + z * z;
        if n2 < QUAT_DEGENERATE_NORM_V1 * QUAT_DEGENERATE_NORM_V1 {
            return Some("invalid_orientation");
        }
    }
    None
}

/// Validate a SceneContractV1 JSON object. `serde_json` is only used from tests
/// via this function; the crate stays free of audio engine types.
pub fn validate_scene_v1(scene: &Value) -> SceneValidationV1 {
    let Some(map) = scene.as_object() else {
        return SceneValidationV1::invalid("invalid_document");
    };
    for key in FORBIDDEN_SCENE_TOP_LEVEL_KEYS_V1 {
        if map.contains_key(*key) {
            return SceneValidationV1::invalid("forbidden_key");
        }
    }
    if map.get("schemaVersion").and_then(|v| v.as_u64()) != Some(SCENE_SCHEMA_VERSION_V1) {
        return SceneValidationV1::invalid("schema_version");
    }
    if map.get("revision").and_then(|v| v.as_u64()).is_none() {
        return SceneValidationV1::invalid("invalid_revision");
    }

    let Some(listener) = map.get("listener") else {
        return SceneValidationV1::invalid("missing_listener");
    };
    if let Some(err) = validate_object(listener, "listener") {
        return SceneValidationV1::invalid(err);
    }

    let Some(sources) = map.get("sources").and_then(|v| v.as_array()) else {
        return SceneValidationV1::invalid("invalid_collections");
    };
    let Some(emitters) = map.get("emitters").and_then(|v| v.as_array()) else {
        return SceneValidationV1::invalid("invalid_collections");
    };
    if sources.len() > MAX_SOURCES_V1 {
        return SceneValidationV1::invalid("too_many_sources");
    }
    if emitters.len() > MAX_EMITTERS_V1 {
        return SceneValidationV1::invalid("too_many_emitters");
    }

    let mut ids = std::collections::BTreeSet::new();
    let Some(listener_id) = listener.get("id").and_then(Value::as_str) else {
        return SceneValidationV1::invalid("invalid_id");
    };
    ids.insert(listener_id.to_string());

    for item in sources {
        if let Some(err) = validate_object(item, "source") {
            return SceneValidationV1::invalid(err);
        }
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return SceneValidationV1::invalid("invalid_id");
        };
        if !ids.insert(id.to_string()) {
            return SceneValidationV1::invalid("duplicate_id");
        }
    }
    for item in emitters {
        if let Some(err) = validate_object(item, "emitter") {
            return SceneValidationV1::invalid(err);
        }
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return SceneValidationV1::invalid("invalid_id");
        };
        if !ids.insert(id.to_string()) {
            return SceneValidationV1::invalid("duplicate_id");
        }
    }
    SceneValidationV1::ok()
}
