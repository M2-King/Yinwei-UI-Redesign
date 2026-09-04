//! Thin FRB-facing wrappers around [`PlayerSession`] (P2.4).
//!
//! Codegen on a Flutter host will re-export these; until then Dart calls
//! via `NativeEngine` stubs or a future FFI binding.

use crate::error::SpatialError;
use crate::params::{PlaybackMode, SpatialParams, TrackInfo};
use crate::presets::PositionPreset;
use crate::session::{global_session, PlayerSession};

pub fn api_open(path: String) -> Result<TrackInfo, SpatialError> {
    global_session()?.open(&path)
}

pub fn api_set_params(params: SpatialParams) -> Result<(), SpatialError> {
    global_session()?.set_params(params)
}

pub fn api_apply_preset(preset: PositionPreset) -> Result<SpatialParams, SpatialError> {
    global_session()?.apply_preset(preset)
}

pub fn api_set_mode(mode: PlaybackMode) -> Result<(), SpatialError> {
    global_session()?.set_mode(mode)
}

pub fn api_rebuild_preview() -> Result<(), SpatialError> {
    global_session()?.rebuild_preview(None)
}

pub fn api_play() -> Result<(), SpatialError> {
    global_session()?.play()
}

pub fn api_pause() -> Result<(), SpatialError> {
    global_session()?.pause();
    Ok(())
}

pub fn api_seek_ms(ms: u64) -> Result<(), SpatialError> {
    global_session()?.seek_ms(ms)
}

pub fn api_position_ms() -> Result<u64, SpatialError> {
    Ok(global_session()?.position_ms())
}

pub fn api_is_playing() -> Result<bool, SpatialError> {
    Ok(global_session()?.is_playing())
}

pub fn api_current_azimuth_deg() -> Result<f32, SpatialError> {
    global_session()?.current_azimuth_deg()
}

pub fn api_export_wav(path: String) -> Result<(), SpatialError> {
    global_session()?.export_wav(&path, None)
}

pub fn api_dispose() -> Result<(), SpatialError> {
    global_session()?.dispose()
}

pub fn api_is_preview_dirty() -> Result<bool, SpatialError> {
    Ok(global_session()?.is_preview_dirty())
}

/// Direct session for in-process tests (non-global).
pub fn new_session() -> PlayerSession {
    PlayerSession::new()
}
