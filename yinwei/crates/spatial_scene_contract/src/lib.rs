//! Spatial Scene Domain contracts — CoordinateFrameV1, SceneContractV1,
//! SpeakerSemanticsV1.
//!
//! This crate is **not** `spatial_core`. It contains pure contract math and
//! validation for Phase 1A tests. It has no HRTF, DSP, playback, or FFI.

pub mod coordinate;
pub mod scene;
pub mod speaker;

pub use coordinate::{
    geometric_distance_m, hrtf_unit_from_local, lerp_azimuth_deg, listener_local_to_world,
    local_to_spherical, rotate_vec3, shortest_azimuth_delta_deg, spherical_to_local,
    world_to_listener_local, wrap_azimuth_deg, ListenerPoseV1, QuatV1, SphericalV1, Vec3V1,
};
pub use scene::{
    decide_revision_v1, validate_scene_v1, RevisionDecisionV1, RevisionVerdictV1, SceneValidationV1,
};
pub use speaker::SpeakerSemanticsV1;
