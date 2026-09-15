//! AudioProjectionV1 — pure Scene V1 → current-engine spatial values.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::coordinate::{
    geometric_distance_m, hrtf_unit_from_local, local_to_spherical, world_to_listener_local,
    ListenerPoseV1, QuatV1, SphericalV1, Vec3V1,
};
use crate::scene::validate_scene_v1;
use crate::speaker::SpeakerSemanticsV1;

pub const DSP_DISTANCE_MIN_M: f64 = 0.5;
pub const DSP_DISTANCE_MAX_M: f64 = 10.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcousticFeedV1 {
    Left,
    Right,
    Mid,
}

impl AcousticFeedV1 {
    pub fn parse(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "mid" => Some(Self::Mid),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Mid => "mid",
        }
    }
}

pub fn clamp_dsp_distance_m(geometric_distance_m: f64) -> f64 {
    geometric_distance_m.clamp(DSP_DISTANCE_MIN_M, DSP_DISTANCE_MAX_M)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioProjectionConfigV1 {
    pub point_source_id: String,
    /// emitter id → feed name. Only `left` / `right` / `mid` are valid.
    pub emitter_bindings: BTreeMap<String, String>,
}

impl AudioProjectionConfigV1 {
    pub fn point_source(id: impl Into<String>) -> Self {
        Self {
            point_source_id: id.into(),
            emitter_bindings: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointSourceStatusV1 {
    Projected,
    SourceMissing,
    SourceDisabled,
    SourceInactive,
    InvalidScene,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EmitterSlotStatusV1 {
    Projected,
    SkippedDisabled,
    SkippedInactive,
    FailedUnknownEmitter,
    FailedInvalidFeed,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PointSourceProjectionV1 {
    pub source_id: String,
    pub listener_local: Vec3V1,
    pub hrtf_unit: Vec3V1,
    pub azimuth_deg: f64,
    pub elevation_deg: f64,
    pub geometric_distance_m: f64,
    pub dsp_distance_m: f64,
    pub quaternion_storage_order: [&'static str; 4],
}

#[derive(Clone, Debug, PartialEq)]
pub struct EmitterSlotProjectionV1 {
    pub emitter_id: String,
    pub status: EmitterSlotStatusV1,
    pub feed: Option<AcousticFeedV1>,
    pub listener_local: Option<Vec3V1>,
    pub hrtf_unit: Option<Vec3V1>,
    pub azimuth_deg: Option<f64>,
    pub elevation_deg: Option<f64>,
    pub geometric_distance_m: Option<f64>,
    pub dsp_distance_m: Option<f64>,
    pub visual_role: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AudioProjectionResultV1 {
    pub point_source_status: PointSourceStatusV1,
    pub point_source: Option<PointSourceProjectionV1>,
    pub reason: Option<String>,
    pub emitter_slots: Vec<EmitterSlotProjectionV1>,
}

impl AudioProjectionResultV1 {
    pub fn is_success(&self) -> bool {
        self.point_source_status == PointSourceStatusV1::Projected
    }
}

fn vec3(m: &Value) -> Option<Vec3V1> {
    Some(Vec3V1::new(
        m.get("x")?.as_f64()?,
        m.get("y")?.as_f64()?,
        m.get("z")?.as_f64()?,
    ))
}

fn quat(m: Option<&Value>) -> QuatV1 {
    let Some(q) = m.and_then(Value::as_object) else {
        return QuatV1::IDENTITY;
    };
    QuatV1::new(
        q.get("w").and_then(Value::as_f64).unwrap_or(1.0),
        q.get("x").and_then(Value::as_f64).unwrap_or(0.0),
        q.get("y").and_then(Value::as_f64).unwrap_or(0.0),
        q.get("z").and_then(Value::as_f64).unwrap_or(0.0),
    )
    .normalized()
}

fn listener_pose(listener: &Value) -> Option<ListenerPoseV1> {
    Some(ListenerPoseV1 {
        world_position: vec3(listener.get("worldPosition")?)?,
        orientation: quat(listener.get("orientation")),
    })
}

fn object_by_id<'a>(items: &'a Value, id: &str) -> Option<&'a Value> {
    items.as_array()?.iter().find(|item| item.get("id").and_then(Value::as_str) == Some(id))
}

struct Posed {
    listener_local: Vec3V1,
    hrtf_unit: Vec3V1,
    spherical: SphericalV1,
    geometric_distance_m: f64,
    dsp_distance_m: f64,
}

fn project_world(world: Vec3V1, listener: ListenerPoseV1) -> Posed {
    let local = world_to_listener_local(world, listener);
    let spherical = local_to_spherical(local);
    let geometric = geometric_distance_m(local);
    Posed {
        listener_local: local,
        hrtf_unit: hrtf_unit_from_local(local),
        spherical,
        geometric_distance_m: geometric,
        dsp_distance_m: clamp_dsp_distance_m(geometric),
    }
}

fn project_emitters(
    scene: &Value,
    config: &AudioProjectionConfigV1,
    listener: Option<ListenerPoseV1>,
) -> Vec<EmitterSlotProjectionV1> {
    let emitters = scene.get("emitters").cloned().unwrap_or(Value::Array(vec![]));
    let mut slots = Vec::new();
    for (emitter_id, feed_name) in &config.emitter_bindings {
        let feed = AcousticFeedV1::parse(feed_name)
            .filter(|_| SpeakerSemanticsV1::is_acoustic_feed(feed_name));
        if feed.is_none() {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::FailedInvalidFeed,
                feed: None,
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role: None,
            });
            continue;
        }
        let feed = feed.unwrap();
        let Some(obj) = object_by_id(&emitters, emitter_id) else {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::FailedUnknownEmitter,
                feed: Some(feed),
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role: None,
            });
            continue;
        };
        let visual_role = obj
            .get("visualRole")
            .and_then(Value::as_str)
            .map(str::to_string);
        if obj.get("enabled").and_then(Value::as_bool) != Some(true) {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::SkippedDisabled,
                feed: Some(feed),
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role,
            });
            continue;
        }
        if obj.get("active").and_then(Value::as_bool) != Some(true) {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::SkippedInactive,
                feed: Some(feed),
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role,
            });
            continue;
        }
        let Some(listener) = listener else {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::FailedUnknownEmitter,
                feed: Some(feed),
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role,
            });
            continue;
        };
        let Some(world) = obj.get("worldPosition").and_then(vec3) else {
            slots.push(EmitterSlotProjectionV1 {
                emitter_id: emitter_id.clone(),
                status: EmitterSlotStatusV1::FailedUnknownEmitter,
                feed: Some(feed),
                listener_local: None,
                hrtf_unit: None,
                azimuth_deg: None,
                elevation_deg: None,
                geometric_distance_m: None,
                dsp_distance_m: None,
                visual_role,
            });
            continue;
        };
        let posed = project_world(world, listener);
        slots.push(EmitterSlotProjectionV1 {
            emitter_id: emitter_id.clone(),
            status: EmitterSlotStatusV1::Projected,
            feed: Some(feed),
            listener_local: Some(posed.listener_local),
            hrtf_unit: Some(posed.hrtf_unit),
            azimuth_deg: Some(posed.spherical.azimuth_deg),
            elevation_deg: Some(posed.spherical.elevation_deg),
            geometric_distance_m: Some(posed.geometric_distance_m),
            dsp_distance_m: Some(posed.dsp_distance_m),
            visual_role,
        });
    }
    slots.sort_by(|a, b| a.emitter_id.cmp(&b.emitter_id));
    slots
}

pub fn project_audio_v1(scene: &Value, config: &AudioProjectionConfigV1) -> AudioProjectionResultV1 {
    let validation = validate_scene_v1(scene);
    if !validation.valid {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::InvalidScene,
            point_source: None,
            reason: validation.reason,
            emitter_slots: vec![],
        };
    }
    let listener = listener_pose(&scene["listener"]);
    let emitter_slots = project_emitters(scene, config, listener);
    if config.point_source_id.is_empty() {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::SourceMissing,
            point_source: None,
            reason: Some("source_missing".into()),
            emitter_slots,
        };
    }
    let Some(source) = object_by_id(&scene["sources"], &config.point_source_id) else {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::SourceMissing,
            point_source: None,
            reason: Some("source_missing".into()),
            emitter_slots,
        };
    };
    if source.get("enabled").and_then(Value::as_bool) != Some(true) {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::SourceDisabled,
            point_source: None,
            reason: Some("source_disabled".into()),
            emitter_slots,
        };
    }
    if source.get("active").and_then(Value::as_bool) != Some(true) {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::SourceInactive,
            point_source: None,
            reason: Some("source_inactive".into()),
            emitter_slots,
        };
    }
    let Some(listener) = listener else {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::InvalidScene,
            point_source: None,
            reason: Some("missing_listener".into()),
            emitter_slots: vec![],
        };
    };
    let Some(world) = source.get("worldPosition").and_then(vec3) else {
        return AudioProjectionResultV1 {
            point_source_status: PointSourceStatusV1::InvalidScene,
            point_source: None,
            reason: Some("non_finite_position".into()),
            emitter_slots: vec![],
        };
    };
    let posed = project_world(world, listener);
    AudioProjectionResultV1 {
        point_source_status: PointSourceStatusV1::Projected,
        point_source: Some(PointSourceProjectionV1 {
            source_id: config.point_source_id.clone(),
            listener_local: posed.listener_local,
            hrtf_unit: posed.hrtf_unit,
            azimuth_deg: posed.spherical.azimuth_deg,
            elevation_deg: posed.spherical.elevation_deg,
            geometric_distance_m: posed.geometric_distance_m,
            dsp_distance_m: posed.dsp_distance_m,
            quaternion_storage_order: ["w", "x", "y", "z"],
        }),
        reason: None,
        emitter_slots,
    }
}
