//! Realtime output via cpal — **streaming DSP**, not full-song offline renders.
//!
//! Pose / mode changes only update live parameters. A DSP worker processes
//! [`STREAM_CHUNK`] frames at a time into a small ring; the audio callback
//! drains that ring. This avoids the multi-second mute caused by cloning and
//! HRTF-rendering the entire track on every Spatial tweak.
//!
//! WASAPI: the device stream always opens at the **device default** rate.
//! Content → device conversion uses cubic resampling per produced chunk.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, Stream, StreamConfig};

use crate::decode::StereoFrame;
use crate::error::SpatialError;
use crate::hrtf_render::{HrtfStreamer, STREAM_CHUNK};
use crate::params::{PlaybackMode, SpatialParams};
use crate::resample::resample_cubic;

/// cpal::Stream is !Send on some hosts; we only move it between mutex guards.
struct SendStream(#[allow(dead_code)] Stream);
unsafe impl Send for SendStream {}

const RING_TARGET_FRAMES: usize = STREAM_CHUNK * 10; // ~100–200 ms cushion so pose/UI spikes don't underrun
const RING_MAX_FRAMES: usize = STREAM_CHUNK * 20;

struct DspShared {
    source: Mutex<Vec<StereoFrame>>,
    content_rate: AtomicU64,
    output_rate: AtomicU64,
    /// Read cursor into `source` (content-rate frames).
    read_cursor: AtomicU64,
    /// Device playhead for UI (output-rate frames consumed by callback).
    play_cursor: AtomicU64,
    /// Total output frames produced for current source (for duration).
    output_len: AtomicU64,
    playing: AtomicBool,
    /// 0 = Original, 1 = Spatial
    mode: AtomicU8,
    params: Mutex<SpatialParams>,
    eq_db: Mutex<[f32; crate::eq::EQ_BANDS]>,
    ring: Mutex<VecDeque<StereoFrame>>,
    stop: AtomicBool,
    seek_gen: AtomicU64,
    /// Live smoothed mid azimuth / elevation (f32 bits) for the visualizer.
    live_az_bits: AtomicU32,
    live_el_bits: AtomicU32,
    /// 1 once the DSP worker has published a Spatial pose this session.
    live_pose_valid: AtomicBool,
}

/// Holds dry source PCM and streams Spatial/Original DSP in a worker thread.
pub struct RealtimePlayer {
    shared: Arc<DspShared>,
    stream: Mutex<Option<SendStream>>,
    dsp: Mutex<Option<JoinHandle<()>>>,
}

impl RealtimePlayer {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(DspShared {
                source: Mutex::new(Vec::new()),
                content_rate: AtomicU64::new(44_100),
                output_rate: AtomicU64::new(44_100),
                read_cursor: AtomicU64::new(0),
                play_cursor: AtomicU64::new(0),
                output_len: AtomicU64::new(0),
                playing: AtomicBool::new(false),
                mode: AtomicU8::new(1),
                params: Mutex::new(SpatialParams::default()),
                eq_db: Mutex::new([0.0; crate::eq::EQ_BANDS]),
                ring: Mutex::new(VecDeque::with_capacity(RING_MAX_FRAMES)),
                stop: AtomicBool::new(false),
                seek_gen: AtomicU64::new(0),
                live_az_bits: AtomicU32::new(90.0f32.to_bits()),
                live_el_bits: AtomicU32::new(0.0f32.to_bits()),
                live_pose_valid: AtomicBool::new(false),
            }),
            stream: Mutex::new(None),
            dsp: Mutex::new(None),
        }
    }

    /// Announce content sample rate (kept for API compat with session).
    pub fn set_sample_rate(&self, sr: u32) {
        self.shared
            .content_rate
            .store(sr as u64, Ordering::Relaxed);
    }

    /// Load dry decoded PCM once. Does **not** HRTF the whole song.
    pub fn load_source(&self, frames: Vec<StereoFrame>, sample_rate: u32) -> Result<(), SpatialError> {
        self.stop_dsp();
        {
            let mut g = self.shared.source.lock().map_err(|_| SpatialError::LockPoisoned)?;
            *g = frames;
        }
        self.shared
            .content_rate
            .store(sample_rate.max(1) as u64, Ordering::Relaxed);
        self.shared.read_cursor.store(0, Ordering::Relaxed);
        self.shared.play_cursor.store(0, Ordering::Relaxed);
        self.shared.output_len.store(0, Ordering::Relaxed);
        self.shared.seek_gen.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut ring) = self.shared.ring.lock() {
            ring.clear();
        }
        // Drop device stream so next play re-probes device rate.
        if let Ok(mut s) = self.stream.lock() {
            *s = None;
        }
        Ok(())
    }

    /// Legacy API: treat incoming frames as dry source (Original path / tests).
    pub fn load_frames(&self, frames: Vec<StereoFrame>) -> Result<(), SpatialError> {
        let sr = self.shared.content_rate.load(Ordering::Relaxed).max(1) as u32;
        self.load_source(frames, sr)
    }

    /// Legacy hot-swap — used only if something still pushes offline renders.
    /// Prefer [`set_live_params`] for Spatial pose changes.
    pub fn swap_frames_keep_ms(
        &self,
        frames: Vec<StereoFrame>,
        keep_ms: u64,
    ) -> Result<(), SpatialError> {
        let sr = self.shared.content_rate.load(Ordering::Relaxed).max(1);
        let frame = keep_ms.saturating_mul(sr) / 1000;
        {
            let mut g = self.shared.source.lock().map_err(|_| SpatialError::LockPoisoned)?;
            *g = frames;
        }
        self.shared.read_cursor.store(frame, Ordering::Relaxed);
        self.shared.seek_gen.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut ring) = self.shared.ring.lock() {
            ring.clear();
        }
        // Approximate output playhead; DSP will resync.
        let out_sr = self.shared.output_rate.load(Ordering::Relaxed).max(1);
        let out_frame = keep_ms.saturating_mul(out_sr) / 1000;
        self.shared.play_cursor.store(out_frame, Ordering::Relaxed);
        Ok(())
    }

    pub fn set_live_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        params.validate()?;
        let mut g = self
            .shared
            .params
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        *g = params.clone();
        // While Spatial DSP is running, live_* is owned by the streamer (slew).
        // When idle / not yet valid, seed so the visualizer matches the target.
        let dsp_owns_pose = self.shared.playing.load(Ordering::Relaxed)
            && self.shared.live_pose_valid.load(Ordering::Relaxed)
            && self.shared.mode.load(Ordering::Relaxed) == 1;
        if !dsp_owns_pose {
            self.shared
                .live_az_bits
                .store(params.azimuth_deg.to_bits(), Ordering::Relaxed);
            self.shared
                .live_el_bits
                .store(params.elevation_deg.to_bits(), Ordering::Relaxed);
        }
        // Never touch the ring here. Clearing/trimming caused device underruns
        // (the "卡一下" on every preset / drag). Pose changes are applied by the
        // DSP worker on the next chunk; HrtfStreamer slews large jumps.
        Ok(())
    }

    pub fn set_eq(&self, gains: [f32; crate::eq::EQ_BANDS]) -> Result<(), SpatialError> {
        let mut g = self
            .shared
            .eq_db
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        *g = crate::eq::clamp_eq_gains(gains);
        Ok(())
    }

    /// Effective mid azimuth from the live streamer (includes orbit). `None` if
    /// Spatial DSP has not published yet / mode is Original.
    pub fn live_azimuth_deg(&self) -> Option<f32> {
        if self.shared.mode.load(Ordering::Relaxed) != 1 {
            return None;
        }
        if !self.shared.live_pose_valid.load(Ordering::Relaxed) {
            return None;
        }
        Some(f32::from_bits(
            self.shared.live_az_bits.load(Ordering::Relaxed),
        ))
    }

    pub fn live_elevation_deg(&self) -> Option<f32> {
        if self.shared.mode.load(Ordering::Relaxed) != 1 {
            return None;
        }
        if !self.shared.live_pose_valid.load(Ordering::Relaxed) {
            return None;
        }
        Some(f32::from_bits(
            self.shared.live_el_bits.load(Ordering::Relaxed),
        ))
    }

    pub fn set_live_mode(&self, mode: PlaybackMode) {
        let v = match mode {
            PlaybackMode::Original => 0u8,
            PlaybackMode::Spatial => 1u8,
        };
        let prev = self.shared.mode.swap(v, Ordering::Relaxed);
        if prev != v {
            // Soft switch: do NOT clear the ring (that underruns and "卡一下").
            // DSP picks up the new mode on the next chunk; at most one block of
            // dry/wet blend is far less audible than a stall.
            self.shared.seek_gen.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn frame_count(&self) -> Result<usize, SpatialError> {
        let g = self.shared.source.lock().map_err(|_| SpatialError::LockPoisoned)?;
        Ok(g.len())
    }

    pub fn seek_ms(&self, ms: u64) -> Result<(), SpatialError> {
        let sr = self.shared.content_rate.load(Ordering::Relaxed).max(1);
        let frame = ms.saturating_mul(sr) / 1000;
        let len = self.frame_count()? as u64;
        self.shared.read_cursor.store(frame.min(len), Ordering::Relaxed);
        let out_sr = self.shared.output_rate.load(Ordering::Relaxed).max(1);
        self.shared
            .play_cursor
            .store(ms.saturating_mul(out_sr) / 1000, Ordering::Relaxed);
        self.shared.seek_gen.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut ring) = self.shared.ring.lock() {
            ring.clear();
        }
        Ok(())
    }

    pub fn position_ms(&self) -> u64 {
        let sr = self.shared.output_rate.load(Ordering::Relaxed).max(1);
        self.shared.play_cursor.load(Ordering::Relaxed).saturating_mul(1000) / sr
    }

    pub fn is_playing(&self) -> bool {
        self.shared.playing.load(Ordering::Relaxed)
    }

    pub fn pause(&self) {
        self.shared.playing.store(false, Ordering::Relaxed);
    }

    pub fn play(&self) -> Result<(), SpatialError> {
        self.ensure_stream()?;
        self.ensure_dsp()?;
        self.shared.playing.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn stop(&self) -> Result<(), SpatialError> {
        self.shared.playing.store(false, Ordering::Relaxed);
        self.stop_dsp();
        let mut g = self.stream.lock().map_err(|_| SpatialError::LockPoisoned)?;
        *g = None;
        Ok(())
    }

    pub fn has_output_device() -> bool {
        cpal::default_host().default_output_device().is_some()
    }

    fn probe_device_rate(&self) -> u32 {
        let content = self.shared.content_rate.load(Ordering::Relaxed).max(1) as u32;
        let host = cpal::default_host();
        let Some(device) = host.default_output_device() else {
            return content;
        };
        match device.default_output_config() {
            Ok(cfg) => cfg.sample_rate().0.max(1),
            Err(_) => content,
        }
    }

    fn stop_dsp(&self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Ok(mut slot) = self.dsp.lock() {
            if let Some(h) = slot.take() {
                let _ = h.join();
            }
        }
        self.shared.stop.store(false, Ordering::Relaxed);
        self.shared.live_pose_valid.store(false, Ordering::Relaxed);
    }

    fn ensure_dsp(&self) -> Result<(), SpatialError> {
        let mut slot = self.dsp.lock().map_err(|_| SpatialError::LockPoisoned)?;
        if slot.is_some() {
            return Ok(());
        }
        let shared = Arc::clone(&self.shared);
        let content_sr = shared.content_rate.load(Ordering::Relaxed).max(1) as u32;
        let mut streamer = HrtfStreamer::new(content_sr)?;
        // Snap to current target so the first play does not slew from defaults.
        if let Ok(p) = shared.params.lock() {
            streamer.snap_to_params(&p);
            shared
                .live_az_bits
                .store(streamer.effective_mid_azimuth_deg(&p).to_bits(), Ordering::Relaxed);
            shared
                .live_el_bits
                .store(streamer.smooth_elevation_deg().to_bits(), Ordering::Relaxed);
            shared.live_pose_valid.store(true, Ordering::Relaxed);
        }
        let handle = thread::Builder::new()
            .name("yinwei-dsp".into())
            .spawn(move || dsp_loop(shared, &mut streamer))
            .map_err(|e| SpatialError::AudioDevice(format!("dsp thread: {e}")))?;
        *slot = Some(handle);
        Ok(())
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
        let config: StreamConfig = supported.clone().into();
        let device_sr = config.sample_rate.0.max(1);
        self.shared
            .output_rate
            .store(device_sr as u64, Ordering::Relaxed);

        // Estimate total output length from source for EOF.
        if let Ok(src) = self.shared.source.lock() {
            let content_sr = self.shared.content_rate.load(Ordering::Relaxed).max(1) as u32;
            let out_len = if content_sr == device_sr {
                src.len() as u64
            } else {
                ((src.len() as u64) * device_sr as u64) / content_sr as u64
            };
            self.shared.output_len.store(out_len, Ordering::Relaxed);
        }

        let shared = Arc::clone(&self.shared);
        let channels = config.channels as usize;

        let stream = match sample_format {
            SampleFormat::F32 => build_stream::<f32>(&device, &config, shared, channels)?,
            SampleFormat::I16 => build_stream::<i16>(&device, &config, shared, channels)?,
            SampleFormat::U16 => build_stream::<u16>(&device, &config, shared, channels)?,
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

impl Drop for RealtimePlayer {
    fn drop(&mut self) {
        self.shared.playing.store(false, Ordering::Relaxed);
        self.stop_dsp();
    }
}

fn dsp_loop(shared: Arc<DspShared>, streamer: &mut HrtfStreamer) {
    let mut eq = crate::eq::GraphicEq::new(48_000);
    let mut last_seek = shared.seek_gen.load(Ordering::Relaxed);
    loop {
        if shared.stop.load(Ordering::Relaxed) {
            break;
        }

        let seek = shared.seek_gen.load(Ordering::Relaxed);
        if seek != last_seek {
            streamer.reset();
            last_seek = seek;
        }

        // Back-pressure: don't over-fill the ring.
        let ring_len = shared.ring.lock().map(|r| r.len()).unwrap_or(0);
        if ring_len >= RING_TARGET_FRAMES {
            thread::sleep(Duration::from_millis(2));
            continue;
        }
        if !shared.playing.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        let content_sr = shared.content_rate.load(Ordering::Relaxed).max(1) as u32;
        let device_sr = shared.output_rate.load(Ordering::Relaxed).max(1) as u32;
        let mode = shared.mode.load(Ordering::Relaxed);
        let params = shared
            .params
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();

        // Pull one STREAM_CHUNK from source.
        let mut chunk = [(0.0f32, 0.0f32); STREAM_CHUNK];
        let mut got = 0usize;
        {
            let src = match shared.source.lock() {
                Ok(g) => g,
                Err(_) => break,
            };
            if src.is_empty() {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            let mut cursor = shared.read_cursor.load(Ordering::Relaxed) as usize;
            if cursor >= src.len() {
                // EOF — leave playing flag; callback will drain ring then stop.
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            while got < STREAM_CHUNK && cursor < src.len() {
                chunk[got] = src[cursor];
                cursor += 1;
                got += 1;
            }
            shared
                .read_cursor
                .store(cursor as u64, Ordering::Relaxed);
        }

        if got == 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        let wet: Vec<StereoFrame> = if mode == 0 {
            chunk[..got].to_vec()
        } else {
            match streamer.process_chunk(&chunk[..got], &params) {
                Ok(block) => {
                    shared.live_az_bits.store(
                        streamer.effective_mid_azimuth_deg(&params).to_bits(),
                        Ordering::Relaxed,
                    );
                    shared.live_el_bits.store(
                        streamer.smooth_elevation_deg().to_bits(),
                        Ordering::Relaxed,
                    );
                    shared.live_pose_valid.store(true, Ordering::Relaxed);
                    block[..got].to_vec()
                }
                Err(e) => {
                    eprintln!("yinwei dsp: {e}");
                    chunk[..got].to_vec()
                }
            }
        };

        let eq_db = shared
            .eq_db
            .lock()
            .map(|g| *g)
            .unwrap_or([0.0; crate::eq::EQ_BANDS]);
        eq.set_gains(content_sr, eq_db);
        let mut wet = wet;
        eq.process_frames(&mut wet);

        let out = if content_sr == device_sr {
            wet
        } else {
            resample_cubic(&wet, content_sr, device_sr)
        };

        if let Ok(mut ring) = shared.ring.lock() {
            for f in out {
                if ring.len() >= RING_MAX_FRAMES {
                    break;
                }
                ring.push_back(f);
            }
        }
    }
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    shared: Arc<DspShared>,
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

                if !shared.playing.load(Ordering::Relaxed) {
                    fill_silence(data);
                    return;
                }

                let mut ring = match shared.ring.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        fill_silence(data);
                        return;
                    }
                };

                let mut out_i = 0usize;
                let mut frames_needed = data.len() / channels;

                while frames_needed > 0 && out_i + channels <= data.len() {
                    let Some((l, r)) = ring.pop_front() else {
                        // Underrun: brief silence (far better than full-song rebuild stall).
                        fill_silence(&mut data[out_i..]);
                        return;
                    };
                    shared.play_cursor.fetch_add(1, Ordering::Relaxed);
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

                // EOF when source exhausted and ring empty.
                let read = shared.read_cursor.load(Ordering::Relaxed) as usize;
                let src_len = shared
                    .source
                    .lock()
                    .map(|g| g.len())
                    .unwrap_or(0);
                if read >= src_len && ring.is_empty() {
                    shared.playing.store(false, Ordering::Relaxed);
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
        player.load_source(frames, 44_100).unwrap();
        assert_eq!(player.frame_count().unwrap(), 44_100);
        player.seek_ms(500).unwrap();
        // play_cursor approx at 500 ms
        assert!((player.position_ms() as i64 - 500).abs() <= 2);
        player.pause();
        assert!(!player.is_playing());
    }

    #[test]
    fn live_params_do_not_require_full_buffer_swap() {
        let player = RealtimePlayer::new();
        player.load_source(vec![(0.2, 0.2); 8_000], 48_000).unwrap();
        let mut p = SpatialParams::default();
        p.azimuth_deg = -45.0;
        player.set_live_params(p).unwrap();
        player.set_live_mode(PlaybackMode::Spatial);
        // No panic / no whole-song render — just param store.
        assert_eq!(player.frame_count().unwrap(), 8_000);
    }
}
