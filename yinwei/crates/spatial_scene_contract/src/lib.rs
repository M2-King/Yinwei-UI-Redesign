//! Spatial Scene Domain — CoordinateFrameV1, SceneContractV1, store, projection.
//!
//! This crate is **not** `spatial_core`. Pure scene-domain math, store, and
//! audio projection. No HRTF, DSP, playback, or FFI.

pub mod coordinate;
pub mod projection;
pub mod scene;
pub mod speaker;
pub mod store;

pub use coordinate::{
    geometric_distance_m, hrtf_unit_from_local, lerp_azimuth_deg, listener_local_to_world,
    local_to_spherical, rotate_vec3, shortest_azimuth_delta_deg, spherical_to_local,
    world_to_listener_local, wrap_azimuth_deg, ListenerPoseV1, QuatV1, SphericalV1, Vec3V1,
};
pub use projection::{
    clamp_dsp_distance_m, project_audio_v1, AcousticFeedV1, AudioProjectionConfigV1,
    AudioProjectionResultV1, EmitterSlotStatusV1, PointSourceStatusV1, DSP_DISTANCE_MAX_M,
    DSP_DISTANCE_MIN_M,
};
pub use scene::{
    decide_revision_v1, validate_scene_v1, RevisionDecisionV1, RevisionVerdictV1, SceneValidationV1,
};
pub use speaker::SpeakerSemanticsV1;
pub use store::{SceneApplyStatusV1, SpatialSceneStore};
