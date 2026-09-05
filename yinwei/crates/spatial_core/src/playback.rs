//! Realtime output via cpal (P1).
//!
//! Windows WASAPI shared mode often *ignores* a requested content sample rate and
//! still runs the callback at the device mix rate (commonly 48 kHz). Feeding
//! 44.1 kHz PCM into that callback makes playback ~9% fast and thin/"phone-like".
//!
//! Fix: always open the stream at the **device default** rate, and cubic-resample
//! content PCM to that rate before queuing frames.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, Stream, StreamConfig};

use crate::decode::StereoFrame;
use crate::error::SpatialError;
use crate::resample::resample_cubic;

/// cpal::Stream is !Send on some hosts; we only move it between mutex guards.
struct SendStream(#[allow(dead_code)] Stream);
unsafe impl Send for SendStream {}

/// Holds playable PCM and an optional live cpal stream.
pub struct RealtimePlayer {
    /// Source PCM at `content_rate` (pre-device resample).
    content_frames: Mutex<Vec<StereoFrame>>,
    /// PCM currently fed to the device (already at `output_rate`).
    frames: Arc<Mutex<Vec<StereoFrame>>>,
    cursor: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    /// Sample rate of `frames` / the open stream (device rate after prepare).
    output_rate: Arc<AtomicU64>,
    /// Native rate of the last content buffer before device resample.
    content_rate: Arc<AtomicU64>,
    stream: Mutex<Option<SendStream>>,
}

impl RealtimePlayer {
    pub fn new() -> Self {
        Self {
            content_frames: Mutex::new(Vec::new()),
            frames: Arc::new(Mutex::new(Vec::new())),
            cursor: Arc::new(AtomicU64::new(0)),
            playing: Arc::new(AtomicBool::new(false)),
            output_rate: Arc::new(AtomicU64::new(44_100)),
            content_rate: Arc::new(AtomicU64::new(44_100)),
            stream: Mutex::new(None),
        }
    }

    /// Announce the sample rate of upcoming content PCM (before load/swap).
    pub fn set_sample_rate(&self, sr: u32) {
        let prev = self.content_rate.swap(sr as u64, Ordering::Relaxed);
        if prev != sr as u64 {
            // Drop stream so the next play re-prepares at device rate.
            if let Ok(mut g) = self.stream.lock() {
                *g = None;
            }
        }
    }

    pub fn load_frames(&self, frames: Vec<StereoFrame>) -> Result<(), SpatialError> {
        {
            let mut src = self.content_frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
            *src = frames;
        }
        let prepared = self.render_to_device()?;
        let mut g = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        *g = prepared;
        self.cursor.store(0, Ordering::Relaxed);
        Ok(())
    }

    /// Hot-swap rendered PCM while keeping the playhead (live param updates).
    pub fn swap_frames_keep_ms(
        &self,
        frames: Vec<StereoFrame>,
        keep_ms: u64,
    ) -> Result<(), SpatialError> {
        {
            let mut src = self.content_frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
            *src = frames;
        }
        let prepared = self.render_to_device()?;
        let sr = self.output_rate.load(Ordering::Relaxed).max(1);
        let frame = keep_ms.saturating_mul(sr) / 1000;
        let mut g = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        let len = prepared.len() as u64;
        *g = prepared;
        self.cursor.store(frame.min(len), Ordering::Relaxed);
        Ok(())
    }

    pub fn frame_count(&self) -> Result<usize, SpatialError> {
        let g = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(g.len())
    }

    pub fn seek_ms(&self, ms: u64) -> Result<(), SpatialError> {
        let sr = self.output_rate.load(Ordering::Relaxed).max(1);
        let frame = ms.saturating_mul(sr) / 1000;
        let len = self.frame_count()? as u64;
        self.cursor.store(frame.min(len), Ordering::Relaxed);
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        let sr = self.output_rate.load(Ordering::Relaxed).max(1);
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

    /// Device mix rate when available; falls back to content rate offline/CI.
    fn probe_device_rate(&self) -> u32 {
        let content = self.content_rate.load(Ordering::Relaxed).max(1) as u32;
        let host = cpal::default_host();
        let Some(device) = host.default_output_device() else {
            return content;
        };
        match device.default_output_config() {
            Ok(cfg) => cfg.sample_rate().0.max(1),
            Err(_) => content,
        }
    }

    /// Convert content-rate PCM to the device mix rate and update `output_rate`.
    fn render_to_device(&self) -> Result<Vec<StereoFrame>, SpatialError> {
        let content_sr = self.content_rate.load(Ordering::Relaxed).max(1) as u32;
        let device_sr = self.probe_device_rate();
        self.output_rate
            .store(device_sr as u64, Ordering::Relaxed);
        let src = self.content_frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if content_sr == device_sr {
            Ok(src.clone())
        } else {
            eprintln!(
                "yinwei: resampling preview {content_sr} Hz → device {device_sr} Hz (WASAPI-safe)"
            );
            Ok(resample_cubic(&src, content_sr, device_sr))
        }
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
        // CRITICAL: use the device default rate as-is. Do not override with
        // content rate — WASAPI shared mode will still clock the callback at
        // the mix format, which desyncs pitch/speed if PCM doesn't match.
        let config: StreamConfig = supported.clone().into();
        let device_sr = config.sample_rate.0.max(1);
        self.output_rate
            .store(device_sr as u64, Ordering::Relaxed);

        // Refresh device PCM now that the real mix rate is known (probe may have
        // differed, or frames were loaded before a device was available).
        {
            let content_sr = self.content_rate.load(Ordering::Relaxed).max(1) as u32;
            let src = self.content_frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
            if !src.is_empty() {
                let rendered = if content_sr == device_sr {
                    src.clone()
                } else {
                    eprintln!(
                        "yinwei: stream open resample {content_sr} → {device_sr} Hz"
                    );
                    resample_cubic(&src, content_sr, device_sr)
                };
                drop(src);
                let mut out = self.frames.lock().map_err(|_| SpatialError::LockPoisoned)?;
                // Preserve playhead ratio across resample.
                let old_len = out.len().max(1) as f64;
                let pos = self.cursor.load(Ordering::Relaxed) as f64 / old_len;
                let new_len = rendered.len() as u64;
                *out = rendered;
                self.cursor.store(
                    ((pos * new_len as f64).round() as u64).min(new_len.saturating_sub(1)),
                    Ordering::Relaxed,
                );
            }
        }

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
        // Offline/CI: no device → prepare keeps content rate.
        assert_eq!(player.frame_count().unwrap(), 44_100);
        player.seek_ms(500).unwrap();
        assert!((player.position_ms() as i64 - 500).abs() <= 1);
        player.pause();
        assert!(!player.is_playing());
    }
}
