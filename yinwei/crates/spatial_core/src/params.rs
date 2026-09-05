use serde::{Deserialize, Serialize};

use crate::error::SpatialError;
use crate::presets::PositionPreset;

/// Original (bypass) vs Spatial (HRTF) — maps to center segmented control.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PlaybackMode {
    Original,
    Spatial,
}

/// Fixed pin vs continuous orbit — maps to sidebar segmented control.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MotionMode {
    Fixed,
    Orbit,
}

/// Full spatial control state — mirror of Flutter `SpatialParams`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpatialParams {
    pub azimuth_deg: f32,
    pub elevation_deg: f32,
    pub distance_m: f32,
    pub motion: MotionMode,
    /// Orbit rate in Hz (mockup: 0.40 Hz). RPM = hz * 60.
    pub orbit_hz: f32,
    /// Surround wrap 0…1 (mockup: 60%). Side + Mid bleed into offset HRTFs.
    pub envelopment: f32,
    /// Reverb wet mix 0…1 (mockup: 20%).
    pub reverb_mix: f32,
    pub selected_preset: Option<PositionPreset>,
}

pub const DEFAULT_PARAMS: SpatialParams = SpatialParams {
    azimuth_deg: 90.0,
    elevation_deg: -10.0,
    distance_m: 2.1,
    motion: MotionMode::Fixed,
    orbit_hz: 0.4,
    envelopment: 0.6,
    reverb_mix: 0.2,
    selected_preset: Some(PositionPreset::Right),
};

impl Default for SpatialParams {
    fn default() -> Self {
        DEFAULT_PARAMS
    }
}

impl SpatialParams {
    pub fn validate(&self) -> Result<(), SpatialError> {
        if !(-180.0..=180.0).contains(&self.azimuth_deg) {
            return Err(SpatialError::InvalidParam(format!(
                "azimuth {} out of [-180, 180]",
                self.azimuth_deg
            )));
        }
        if !(-90.0..=90.0).contains(&self.elevation_deg) {
            return Err(SpatialError::InvalidParam(format!(
                "elevation {} out of [-90, 90]",
                self.elevation_deg
            )));
        }
        if !(0.5..=10.0).contains(&self.distance_m) {
            return Err(SpatialError::InvalidParam(format!(
                "distance {} out of [0.5, 10]",
                self.distance_m
            )));
        }
        if !(0.0..=2.0).contains(&self.orbit_hz) {
            return Err(SpatialError::InvalidParam(format!(
                "orbit_hz {} out of [0, 2]",
                self.orbit_hz
            )));
        }
        if !(0.0..=1.0).contains(&self.envelopment) {
            return Err(SpatialError::InvalidParam("envelopment out of [0, 1]".into()));
        }
        if !(0.0..=1.0).contains(&self.reverb_mix) {
            return Err(SpatialError::InvalidParam("reverb_mix out of [0, 1]".into()));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackInfo {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
    pub path: String,
}
