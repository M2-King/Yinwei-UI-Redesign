//! Yinwei spatial audio engine — public API for Flutter / CLI.

mod crossover;
mod decode;
mod error;
mod hrtf_render;
mod mid_side;
mod params;
mod presets;
mod reverb;

#[cfg(feature = "realtime")]
mod playback;

pub use decode::{save_wav, write_test_sine_wav, DecodedAudio, StereoFrame};
pub use error::SpatialError;
pub use hrtf_render::{spherical_to_vec, HrtfRenderer};
pub use params::{
    MotionMode, PlaybackMode, SpatialParams, TrackInfo, DEFAULT_PARAMS,
};
#[cfg(feature = "realtime")]
pub use playback::RealtimePlayer;
pub use presets::{apply_preset, PositionPreset, PRESET_TABLE};

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use decode::load_audio;

struct EngineInner {
    path: Option<PathBuf>,
    decoded: Option<DecodedAudio>,
    meta: Option<TrackInfo>,
    params: SpatialParams,
    mode: PlaybackMode,
    orbit_phase: f32,
    renderer: Option<HrtfRenderer>,
}

pub struct Engine {
    inner: Mutex<EngineInner>,
    playing: AtomicBool,
    position_ms: AtomicU64,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(EngineInner {
                path: None,
                decoded: None,
                meta: None,
                params: SpatialParams::default(),
                mode: PlaybackMode::Spatial,
                orbit_phase: 0.0,
                renderer: None,
            }),
            playing: AtomicBool::new(false),
            position_ms: AtomicU64::new(0),
        }
    }

    pub fn open(&self, path: impl AsRef<Path>) -> Result<TrackInfo, SpatialError> {
        let path = path.as_ref();
        if !path.exists() {
            return Err(SpatialError::FileNotFound(path.display().to_string()));
        }

        let decoded = load_audio(path)?;
        let duration_ms =
            (decoded.frames.len() as u64 * 1000) / decoded.sample_rate.max(1) as u64;

        let meta = TrackInfo {
            title: decoded.title.clone(),
            artist: decoded.artist.clone(),
            album: decoded.album.clone(),
            duration_ms,
            sample_rate: decoded.sample_rate,
            channels: 2,
            path: path.display().to_string(),
        };

        let renderer = HrtfRenderer::new(decoded.sample_rate)?;

        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        g.path = Some(path.to_path_buf());
        g.decoded = Some(decoded);
        g.meta = Some(meta.clone());
        g.renderer = Some(renderer);
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
        if g.decoded.is_none() {
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
        let clamped = if max == 0 {
            position_ms
        } else {
            position_ms.min(max)
        };
        self.position_ms.store(clamped, Ordering::Relaxed);
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        self.position_ms.load(Ordering::Relaxed)
    }

    pub fn current_azimuth_deg(&self) -> Result<f32, SpatialError> {
        let g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(match g.params.motion {
            MotionMode::Fixed => g.params.azimuth_deg,
            MotionMode::Orbit => {
                let turns = g.orbit_phase / std::f32::consts::TAU;
                normalize_azimuth(g.params.azimuth_deg + turns * 360.0)
            }
        })
    }

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

    /// Render current track with current mode/params into memory (P1 preview buffer).
    pub fn render_frames(
        &self,
        mut on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(u32, Vec<StereoFrame>), SpatialError> {
        let mut g = self.inner.lock().map_err(|_| SpatialError::LockPoisoned)?;
        let decoded = g.decoded.as_ref().ok_or(SpatialError::NoTrackLoaded)?;
        let params = g.params.clone();
        let mode = g.mode;
        let sample_rate = decoded.sample_rate;
        let source_frames = decoded.frames.clone();
        params.validate()?;

        let frames = match mode {
            PlaybackMode::Original => {
                if let Some(cb) = on_progress.as_mut() {
                    cb(1.0);
                }
                source_frames
            }
            PlaybackMode::Spatial => {
                let renderer = g
                    .renderer
                    .as_mut()
                    .ok_or(SpatialError::NoTrackLoaded)?;
                renderer.render(&source_frames, &params, on_progress)?
            }
        };
        Ok((sample_rate, frames))
    }

    /// Offline render entire track to WAV using current params/mode.
    pub fn export_wav(
        &self,
        out_path: impl AsRef<Path>,
        on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(), SpatialError> {
        let (sample_rate, frames) = self.render_frames(on_progress)?;
        save_wav(out_path.as_ref(), &frames, sample_rate)
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

pub type SharedEngine = Arc<Engine>;

pub fn create_shared_engine() -> SharedEngine {
    Arc::new(Engine::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_right_matches_mockup_direction() {
        let e = Engine::new();
        let p = e.apply_position_preset(PositionPreset::Right).unwrap();
        assert!((p.azimuth_deg - 90.0).abs() < f32::EPSILON);
    }

    #[test]
    fn open_missing_file_errors() {
        let e = Engine::new();
        assert!(matches!(
            e.open("/tmp/yinwei-does-not-exist.wav"),
            Err(SpatialError::FileNotFound(_))
        ));
    }

    #[test]
    fn export_spatial_sine_wav() {
        let dir = std::env::temp_dir().join(format!("yinwei_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = dir.join("in.wav");
        let output = dir.join("out.wav");
        write_test_sine_wav(&input, 0.5, 440.0).unwrap();

        let e = Engine::new();
        let meta = e.open(&input).unwrap();
        assert!(meta.duration_ms >= 400);
        e.apply_position_preset(PositionPreset::LeftRear).unwrap();
        e.set_playback_mode(PlaybackMode::Spatial).unwrap();
        e.export_wav(&output, None).unwrap();
        assert!(output.metadata().unwrap().len() > 1000);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_frames_spatial_differs_from_original() {
        let dir = std::env::temp_dir().join(format!("yinwei_render_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = dir.join("in.wav");
        write_test_sine_wav(&input, 0.4, 440.0).unwrap();

        let e = Engine::new();
        e.open(&input).unwrap();
        e.apply_position_preset(PositionPreset::LeftRear).unwrap();

        e.set_playback_mode(PlaybackMode::Original).unwrap();
        let (_, orig) = e.render_frames(None).unwrap();

        e.set_playback_mode(PlaybackMode::Spatial).unwrap();
        let (_, spat) = e.render_frames(None).unwrap();

        assert_eq!(orig.len(), spat.len());
        let mut diff = 0.0f32;
        for i in (0..orig.len()).step_by(64) {
            diff += (orig[i].0 - spat[i].0).abs() + (orig[i].1 - spat[i].1).abs();
        }
        assert!(diff > 0.01, "spatial should alter the signal, diff={diff}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
