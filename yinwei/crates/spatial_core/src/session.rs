//! P2.1 — Unified session for Flutter / FRB (Engine + RealtimePlayer).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::error::SpatialError;
use crate::params::{PlaybackMode, SpatialParams, TrackInfo};
use crate::playback::RealtimePlayer;
use crate::presets::PositionPreset;
use crate::Engine;

/// Process-wide session handle for FFI / FRB.
pub struct PlayerSession {
    engine: Engine,
    player: RealtimePlayer,
    preview_dirty: AtomicBool,
    has_preview: AtomicBool,
}

impl PlayerSession {
    pub fn new() -> Self {
        Self {
            engine: Engine::new(),
            player: RealtimePlayer::new(),
            preview_dirty: AtomicBool::new(true),
            has_preview: AtomicBool::new(false),
        }
    }

    pub fn open(&self, path: &str) -> Result<TrackInfo, SpatialError> {
        let _ = self.player.stop();
        let meta = self.engine.open(path)?;
        self.player.set_sample_rate(meta.sample_rate);
        self.preview_dirty.store(true, Ordering::Relaxed);
        self.has_preview.store(false, Ordering::Relaxed);
        Ok(meta)
    }

    pub fn set_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        self.engine.set_params(params)?;
        self.preview_dirty.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn params(&self) -> Result<SpatialParams, SpatialError> {
        self.engine.params()
    }

    pub fn apply_preset(&self, preset: PositionPreset) -> Result<SpatialParams, SpatialError> {
        let p = self.engine.apply_position_preset(preset)?;
        self.preview_dirty.store(true, Ordering::Relaxed);
        Ok(p)
    }

    pub fn set_mode(&self, mode: PlaybackMode) -> Result<(), SpatialError> {
        self.engine.set_playback_mode(mode)?;
        self.preview_dirty.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn mode(&self) -> Result<PlaybackMode, SpatialError> {
        self.engine.playback_mode()
    }

    pub fn rebuild_preview(
        &self,
        on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(), SpatialError> {
        let (sr, frames) = self.engine.render_frames(on_progress)?;
        self.player.set_sample_rate(sr);
        let pos = self.player.position_ms();
        self.player.load_frames(frames)?;
        let _ = self.player.seek_ms(pos);
        self.preview_dirty.store(false, Ordering::Relaxed);
        self.has_preview.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn play(&self) -> Result<(), SpatialError> {
        if self.preview_dirty.load(Ordering::Relaxed) || !self.has_preview.load(Ordering::Relaxed)
        {
            self.rebuild_preview(None)?;
        }
        match self.player.play() {
            Ok(()) => {
                let _ = self.engine.play();
                Ok(())
            }
            Err(SpatialError::AudioDevice(msg)) => {
                // Preview buffer is ready; surface device error to UI.
                Err(SpatialError::AudioDevice(msg))
            }
            Err(e) => Err(e),
        }
    }

    pub fn pause(&self) {
        self.player.pause();
        self.engine.pause();
    }

    pub fn seek_ms(&self, ms: u64) -> Result<(), SpatialError> {
        self.engine.seek(ms)?;
        self.player.seek_ms(ms)?;
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        // Prefer realtime cursor when preview loaded.
        if self.has_preview.load(Ordering::Relaxed) {
            self.player.position_ms()
        } else {
            self.engine.position_ms()
        }
    }

    pub fn is_playing(&self) -> bool {
        self.player.is_playing() || self.engine.is_playing()
    }

    pub fn current_azimuth_deg(&self) -> Result<f32, SpatialError> {
        self.engine.current_azimuth_deg()
    }

    pub fn export_wav(
        &self,
        path: &str,
        on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(), SpatialError> {
        self.engine.export_wav(path, on_progress)
    }

    pub fn dispose(&self) -> Result<(), SpatialError> {
        self.pause();
        self.player.stop()?;
        self.has_preview.store(false, Ordering::Relaxed);
        self.preview_dirty.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn is_preview_dirty(&self) -> bool {
        self.preview_dirty.load(Ordering::Relaxed)
    }
}

impl Default for PlayerSession {
    fn default() -> Self {
        Self::new()
    }
}

/// Process singleton for FFI.
static GLOBAL: Mutex<Option<Arc<PlayerSession>>> = Mutex::new(None);

pub fn global_session() -> Result<Arc<PlayerSession>, SpatialError> {
    let mut g = GLOBAL.lock().map_err(|_| SpatialError::LockPoisoned)?;
    if g.is_none() {
        *g = Some(Arc::new(PlayerSession::new()));
    }
    Ok(Arc::clone(g.as_ref().unwrap()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{write_test_sine_wav, PlaybackMode, PositionPreset};

    #[test]
    fn session_open_rebuild_export() {
        let dir = std::env::temp_dir().join(format!("yinwei_sess_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = dir.join("in.wav");
        let output = dir.join("out.wav");
        write_test_sine_wav(&input, 0.35, 440.0).unwrap();

        let s = PlayerSession::new();
        let meta = s.open(input.to_str().unwrap()).unwrap();
        assert!(meta.duration_ms >= 300);
        assert!(s.is_preview_dirty());

        s.apply_preset(PositionPreset::LeftRear).unwrap();
        s.set_mode(PlaybackMode::Spatial).unwrap();
        s.rebuild_preview(None).unwrap();
        assert!(!s.is_preview_dirty());

        s.seek_ms(50).unwrap();
        assert!(s.position_ms() >= 40);

        s.export_wav(output.to_str().unwrap(), None).unwrap();
        assert!(output.metadata().unwrap().len() > 500);

        let _ = s.dispose();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn global_session_singleton() {
        let a = global_session().unwrap();
        let b = global_session().unwrap();
        assert!(Arc::ptr_eq(&a, &b));
    }
}
