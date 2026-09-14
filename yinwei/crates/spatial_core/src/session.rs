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
        let (sr, dry) = self.engine.dry_frames()?;
        self.player.set_sample_rate(sr);
        self.player.load_source(dry, sr)?;
        self.player.set_live_params(self.engine.params()?)?;
        self.player.set_live_mode(self.engine.playback_mode()?);
        let _ = self.player.replace_array(self.engine.array_layout()?);
        // Streaming path: source is loaded; no offline full-song preview needed to play.
        self.preview_dirty.store(false, Ordering::Relaxed);
        self.has_preview.store(true, Ordering::Relaxed);
        Ok(meta)
    }

    pub fn set_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        self.engine.set_params(params.clone())?;
        // Live streaming: push params to the DSP worker — do NOT mark preview dirty
        // (that would force a full-song HRTF re-render on next play).
        self.player.set_live_params(params)?;
        Ok(())
    }

    pub fn set_eq(&self, gains: [f32; crate::eq::EQ_BANDS]) -> Result<(), SpatialError> {
        self.engine.set_eq(gains)?;
        self.player.set_eq(gains)?;
        Ok(())
    }

    pub fn set_array(&self, mode: i32) -> Result<(), SpatialError> {
        self.engine.set_array(mode)?;
        self.player.set_array(mode)?;
        Ok(())
    }

    pub fn set_speaker(
        &self,
        index: i32,
        az_deg: f32,
        el_deg: f32,
        dist_m: f32,
        gain_db: f32,
        mute: i32,
        feed: i32,
    ) -> Result<(), SpatialError> {
        self.engine
            .set_speaker(index, az_deg, el_deg, dist_m, gain_db, mute, feed)?;
        self.player
            .set_speaker(index, az_deg, el_deg, dist_m, gain_db, mute, feed)?;
        Ok(())
    }

    pub fn params(&self) -> Result<SpatialParams, SpatialError> {
        self.engine.params()
    }

    pub fn apply_preset(&self, preset: PositionPreset) -> Result<SpatialParams, SpatialError> {
        let p = self.engine.apply_position_preset(preset)?;
        self.player.set_live_params(p.clone())?;
        Ok(p)
    }

    pub fn set_mode(&self, mode: PlaybackMode) -> Result<(), SpatialError> {
        self.engine.set_playback_mode(mode)?;
        self.player.set_live_mode(mode);
        Ok(())
    }

    pub fn mode(&self) -> Result<PlaybackMode, SpatialError> {
        self.engine.playback_mode()
    }

    pub fn rebuild_preview(
        &self,
        on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<(), SpatialError> {
        let was_playing = self.player.is_playing();
        let (sr, frames) = self.engine.render_frames(on_progress)?;
        self.player.set_sample_rate(sr);
        let pos = self.player.position_ms();
        // Keep playhead across live rebuilds so Spatial params apply mid-song.
        self.player.swap_frames_keep_ms(frames, pos)?;
        self.preview_dirty.store(false, Ordering::Relaxed);
        self.has_preview.store(true, Ordering::Relaxed);
        if was_playing {
            // Resume flag after buffer swap (stream may already be open).
            let _ = self.player.play();
        }
        Ok(())
    }

    /// Apply params for live listening. Streaming DSP picks them up on the next
    /// block — no full-song rebuild.
    pub fn set_params_live(&self, params: SpatialParams) -> Result<(), SpatialError> {
        self.set_params(params)
    }

    pub fn play(&self) -> Result<(), SpatialError> {
        // Streaming: source was loaded in open(); skip full-song preview render.
        if !self.has_preview.load(Ordering::Relaxed) {
            let (sr, dry) = self.engine.dry_frames()?;
            self.player.load_source(dry, sr)?;
            self.player.set_live_params(self.engine.params()?)?;
            self.player.set_live_mode(self.engine.playback_mode()?);
            let _ = self.player.set_eq(self.engine.eq_gains()?);
            let layout = self.engine.array_layout()?;
            let _ = self.player.replace_array(layout);
            self.has_preview.store(true, Ordering::Relaxed);
            self.preview_dirty.store(false, Ordering::Relaxed);
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
        if let Some(az) = self.player.live_azimuth_deg() {
            return Ok(az);
        }
        self.engine.current_azimuth_deg()
    }

    pub fn current_elevation_deg(&self) -> Result<f32, SpatialError> {
        if let Some(el) = self.player.live_elevation_deg() {
            return Ok(el);
        }
        Ok(self.engine.params()?.elevation_deg)
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
        // Streaming open loads dry source — no dirty offline preview.
        assert!(!s.is_preview_dirty());

        s.apply_preset(PositionPreset::LeftRear).unwrap();
        s.set_mode(PlaybackMode::Spatial).unwrap();
        // Live params/mode must not require a full-song rebuild.
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
