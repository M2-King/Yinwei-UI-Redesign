//! Realtime output via cpal (P1).
//!
//! Environments without an audio device (CI/cloud) get `SpatialError::AudioDevice`
//! from `play()` — unit tests still cover buffer load/seek without opening a stream.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, Stream, StreamConfig};

use crate::decode::StereoFrame;
use crate::error::SpatialError;

/// cpal::Stream is !Send on some hosts; we only move it between mutex guards.
struct SendStream(#[allow(dead_code)] Stream);
unsafe impl Send for SendStream {}

/// Holds playable PCM and an optional live cpal stream.
pub struct RealtimePlayer {
    frames: Arc<Mutex<Vec<StereoFrame>>>,
    cursor: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    sample_rate: Arc<AtomicU64>,
    stream: Mutex<Option<SendStream>>,
}

impl RealtimePlayer {
    pub fn new() -> Self {
        Self {
            frames: Arc::new(Mutex::new(Vec::new())),
            cursor: Arc::new(AtomicU64::new(0)),
            playing: Arc::new(AtomicBool::new(false)),
            sample_rate: Arc::new(AtomicU64::new(44_100)),
            stream: Mutex::new(None),
        }
    }

    pub fn set_sample_rate(&self, sr: u32) {
        self.sample_rate.store(sr as u64, Ordering::Relaxed);
    }

    pub fn load_frames(&self, frames: Vec<StereoFrame>) -> Result<(), SpatialError> {
        let mut g = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        *g = frames;
        self.cursor.store(0, Ordering::Relaxed);
        Ok(())
    }

    pub fn frame_count(&self) -> Result<usize, SpatialError> {
        let g = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(g.len())
    }

    pub fn seek_ms(&self, ms: u64) -> Result<(), SpatialError> {
        let sr = self.sample_rate.load(Ordering::Relaxed).max(1);
        let frame = ms.saturating_mul(sr) / 1000;
        let len = self.frame_count()? as u64;
        self.cursor.store(frame.min(len), Ordering::Relaxed);
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        let sr = self.sample_rate.load(Ordering::Relaxed).max(1);
        self.cursor.load(Ordering::Relaxed).saturating_mul(1000) / sr
    }

    pub fn is_playing(&self) -> bool {
        self.playing.load(Ordering::Relaxed)
    }

    pub fn pause(&self) {
        self.playing.store(false, Ordering::Relaxed);
    }

    pub fn play(&self) -> Result<(), SpatialError> {
        self.ensure_stream()?;
        self.playing.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn stop(&self) -> Result<(), SpatialError> {
        self.playing.store(false, Ordering::Relaxed);
        let mut g = self.stream.lock().map_err(|_| SpatialError::LockPoisoned)?;
        *g = None;
        Ok(())
    }

    /// Returns whether a default output device exists (no stream opened).
    pub fn has_output_device() -> bool {
        cpal::default_host().default_output_device().is_some()
    }

    fn ensure_stream(&self) -> Result<(), SpatialError> {
        let mut slot = self.stream.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if slot.is_some() {
            return Ok(());
        }

        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| SpatialError::AudioDevice("no default output device".into()))?;

        let supported = device
            .default_output_config()
            .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;

        let sample_format = supported.sample_format();
        let config: StreamConfig = supported.into();
        self.sample_rate
            .store(config.sample_rate.0 as u64, Ordering::Relaxed);

        let frames = Arc::clone(&self.frames);
        let cursor = Arc::clone(&self.cursor);
        let playing = Arc::clone(&self.playing);
        let channels = config.channels as usize;

        let stream = match sample_format {
            SampleFormat::F32 => {
                build_stream::<f32>(&device, &config, frames, cursor, playing, channels)?
            }
            SampleFormat::I16 => {
                build_stream::<i16>(&device, &config, frames, cursor, playing, channels)?
            }
            SampleFormat::U16 => {
                build_stream::<u16>(&device, &config, frames, cursor, playing, channels)?
            }
            other => {
                return Err(SpatialError::AudioDevice(format!(
                    "unsupported sample format: {other:?}"
                )))
            }
        };

        stream
            .play()
            .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;
        *slot = Some(SendStream(stream));
        Ok(())
    }
}

impl Default for RealtimePlayer {
    fn default() -> Self {
        Self::new()
    }
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    frames: Arc<Mutex<Vec<StereoFrame>>>,
    cursor: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    channels: usize,
) -> Result<Stream, SpatialError>
where
    T: Sample + FromSample<f32> + cpal::SizedSample,
{
    let err_fn = |e| eprintln!("cpal stream error: {e}");
    let channels = channels.max(1);

    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| {
                let fill_silence = |buf: &mut [T]| {
                    for s in buf.iter_mut() {
                        *s = T::EQUILIBRIUM;
                    }
                };

                if !playing.load(Ordering::Relaxed) {
                    fill_silence(data);
                    return;
                }

                let locked = match frames.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        fill_silence(data);
                        return;
                    }
                };

                if locked.is_empty() {
                    fill_silence(data);
                    return;
                }

                let mut frames_needed = data.len() / channels;
                let mut out_i = 0usize;

                while frames_needed > 0 && out_i + channels <= data.len() {
                    let idx = cursor.load(Ordering::Relaxed) as usize;
                    if idx >= locked.len() {
                        playing.store(false, Ordering::Relaxed);
                        fill_silence(&mut data[out_i..]);
                        return;
                    }

                    let (l, r) = locked[idx];
                    cursor.fetch_add(1, Ordering::Relaxed);

                    data[out_i] = T::from_sample(l);
                    if channels == 1 {
                        out_i += 1;
                    } else {
                        data[out_i + 1] = T::from_sample(r);
                        for c in 2..channels {
                            data[out_i + c] = T::EQUILIBRIUM;
                        }
                        out_i += channels;
                    }
                    frames_needed -= 1;
                }

                if out_i < data.len() {
                    fill_silence(&mut data[out_i..]);
                }
            },
            err_fn,
            None,
        )
        .map_err(|e| SpatialError::AudioDevice(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_and_seek_without_device() {
        let player = RealtimePlayer::new();
        player.set_sample_rate(44_100);
        let frames = vec![(0.1, -0.1); 44_100];
        player.load_frames(frames).unwrap();
        assert_eq!(player.frame_count().unwrap(), 44_100);
        player.seek_ms(500).unwrap();
        assert!((player.position_ms() as i64 - 500).abs() <= 1);
        player.pause();
        assert!(!player.is_playing());
    }
}
