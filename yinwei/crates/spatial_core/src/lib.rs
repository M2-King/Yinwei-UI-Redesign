//! Yinwei spatial audio engine — public API.
//!
//! Flutter talks to this crate through `flutter_rust_bridge`.
//! DSP body (Artezon HRTF + Mid/Side) lands in follow-up commits;
//! this module locks the types and control surface to the UI mockup.

mod params;
mod presets;
mod error;

pub use error::SpatialError;
pub use params::{
    MotionMode, PlaybackMode, SpatialParams, TrackInfo, DEFAULT_PARAMS,
};
pub use presets::{apply_preset, PositionPreset, PRESET_TABLE};

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// In-process engine controlling preview + export.
pub struct Engine {
    inner: Mutex<EngineInner>,
    playing: AtomicBool,
    position_ms: AtomicU64,
}

struct EngineInner {
    path: Option<PathBuf>,
    meta: Option<TrackInfo>,
    params: SpatialParams,
    mode: PlaybackMode,
    /// Accumulated orbit phase in radians (for visualizer / export).
    orbit_phase: f32,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(EngineInner {
                path: None,
                meta: None,
                params: SpatialParams::default(),
                mode: PlaybackMode::Spatial,
                orbit_phase: 0.0,
            }),
            playing: AtomicBool::new(false),
            position_ms: AtomicU64::new(0),
        }
    }

    /// Open a local audio file. Decoding hooks in later; MVP stores path + stub meta.
    pub fn open(&self, path: impl AsRef<Path>) -> Result<TrackInfo, SpatialError> {
        let path = path.as_ref();
        if !path.exists() {
            return Err(SpatialError::FileNotFound(path.display().to_string()));
        }

        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown")
            .to_string();

        let meta = TrackInfo {
            title: name.clone(),
            artist: String::new(),
            album: String::new(),
            duration_ms: 0,
            sample_rate: 44_100,
            channels: 2,
            path: path.display().to_string(),
        };

        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        g.path = Some(path.to_path_buf());
        g.meta = Some(meta.clone());
        g.orbit_phase = 0.0;
        self.position_ms.store(0, Ordering::Relaxed);
        self.playing.store(false, Ordering::Relaxed);
        Ok(meta)
    }

    pub fn set_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        params.validate()?;
        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        g.params = params;
        Ok(())
    }

    pub fn params(&self) -> Result<SpatialParams, SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(g.params.clone())
    }

    pub fn set_playback_mode(&self, mode: PlaybackMode) -> Result<(), SpatialError> {
        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        g.mode = mode;
        Ok(())
    }

    pub fn playback_mode(&self) -> Result<PlaybackMode, SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(g.mode)
    }

    pub fn apply_position_preset(&self, preset: PositionPreset) -> Result<SpatialParams, SpatialError> {
        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        apply_preset(&mut g.params, preset);
        Ok(g.params.clone())
    }

    pub fn play(&self) -> Result<(), SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if g.path.is_none() {
            return Err(SpatialError::NoTrackLoaded);
        }
        self.playing.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn pause(&self) {
        self.playing.store(false, Ordering::Relaxed);
    }

    pub fn is_playing(&self) -> bool {
        self.playing.load(Ordering::Relaxed)
    }

    pub fn seek(&self, position_ms: u64) -> Result<(), SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        let max = g.meta.as_ref().map(|m| m.duration_ms).unwrap_or(0);
        let clamped = if max == 0 { position_ms } else { position_ms.min(max) };
        self.position_ms.store(clamped, Ordering::Relaxed);
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        self.position_ms.load(Ordering::Relaxed)
    }

    /// Effective azimuth for the orbit visualizer (degrees).
    pub fn current_azimuth_deg(&self) -> Result<f32, SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(match g.params.motion {
            MotionMode::Fixed => g.params.azimuth_deg,
            MotionMode::Orbit => {
                let turns = g.orbit_phase / std::f32::consts::TAU;
                let az = g.params.azimuth_deg + turns * 360.0;
                normalize_azimuth(az)
            }
        })
    }

    /// Advance orbit clock by `dt_secs` while playing in Orbit mode.
    pub fn tick(&self, dt_secs: f32) -> Result<(), SpatialError> {
        if !self.is_playing() {
            return Ok(());
        }
        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if g.params.motion == MotionMode::Orbit && g.mode == PlaybackMode::Spatial {
            g.orbit_phase += dt_secs * g.params.orbit_hz * std::f32::consts::TAU;
        }
        Ok(())
    }

    /// Offline export stub — writes nothing until DSP is wired; validates paths/params.
    pub fn export_wav(
        &self,
        out_path: impl AsRef<Path>,
        mut on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(), SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if g.path.is_none() {
            return Err(SpatialError::NoTrackLoaded);
        }
        g.params.validate()?;
        let _out = out_path.as_ref();
        if let Some(cb) = on_progress.as_mut() {
            cb(0.0);
            cb(1.0);
        }
        Err(SpatialError::NotImplemented(
            "HRTF export pipeline not wired yet — API locked to UI".into(),
        ))
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

fn normalize_azimuth(deg: f32) -> f32 {
    let mut a = deg % 360.0;
    if a > 180.0 {
        a -= 360.0;
    }
    if a <= -180.0 {
        a += 360.0;
    }
    a
}

/// Shared handle suitable for FRB / UI isolate.
pub type SharedEngine = Arc<Engine>;

pub fn create_shared_engine() -> SharedEngine {
    Arc::new(Engine::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn preset_right_matches_mockup_direction() {
        let e = Engine::new();
        let p = e.apply_position_preset(PositionPreset::Right).unwrap();
        assert!((p.azimuth_deg - 90.0).abs() < f32::EPSILON);
        assert_eq!(p.selected_preset, Some(PositionPreset::Right));
    }

    #[test]
    fn open_missing_file_errors() {
        let e = Engine::new();
        let err = e.open("/tmp/yinwei-does-not-exist.wav");
        assert!(matches!(err, Err(SpatialError::FileNotFound(_))));
    }

    #[test]
    fn open_existing_file_sets_meta() {
        let dir = std::env::temp_dir();
        let path = dir.join("yinwei_test_stub.wav");
        {
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(b"RIFF").unwrap();
        }
        let e = Engine::new();
        let meta = e.open(&path).unwrap();
        assert_eq!(meta.title, "yinwei_test_stub");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn orbit_tick_moves_azimuth() {
        let e = Engine::new();
        let dir = std::env::temp_dir().join("yinwei_orbit.wav");
        std::fs::write(&dir, b"RIFF").unwrap();
        e.open(&dir).unwrap();
        let mut p = SpatialParams::default();
        p.motion = MotionMode::Orbit;
        p.orbit_hz = 1.0;
        p.azimuth_deg = 0.0;
        e.set_params(p).unwrap();
        e.play().unwrap();
        e.tick(0.25).unwrap(); // quarter turn → +90°
        let az = e.current_azimuth_deg().unwrap();
        assert!((az - 90.0).abs() < 1.0, "got {az}");
        let _ = std::fs::remove_file(dir);
    }
}
