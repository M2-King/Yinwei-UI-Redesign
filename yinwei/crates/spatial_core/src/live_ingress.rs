//! Portable live PCM ingress: bounded queue + DSP worker.
//!
//! Push is for the capture thread: convert + try-enqueue + return immediately.
//! HRTF runs on a dedicated worker. Android JNI is a thin wrapper around this
//! (`android_live_ingress.rs`). Tests run on Linux/macOS CI.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::decode::StereoFrame;
use crate::eq::EQ_BANDS;
use crate::error::SpatialError;
use crate::hrtf_render::STREAM_CHUNK;
use crate::layout::ArrayLayout;
use crate::live_dsp::{linear_to_db, stereo_rms_peak, LiveDspProcessor};
use crate::live_pcm::{frames_from_interleaved_f32, frames_from_interleaved_i16};
use crate::live_queue::BoundedFrameQueue;
use crate::params::{PlaybackMode, SpatialParams};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspBridgeState {
    Disconnected,
    Starting,
    Processing,
    Error,
}

impl DspBridgeState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disconnected => "Disconnected",
            Self::Starting => "Starting",
            Self::Processing => "Processing",
            Self::Error => "Error",
        }
    }
}

#[derive(Debug, Clone)]
pub struct IngressSnapshot {
    pub sample_rate: u32,
    pub channels: u32,
    pub state: DspBridgeState,
    pub input_frames: u64,
    pub consumed_frames: u64,
    pub dsp_chunks: u64,
    pub wet_frames: u64,
    pub dropped_frames: u64,
    pub overruns: u64,
    pub queue_depth_frames: u64,
    pub queue_high_water_frames: u64,
    pub wet_rms_db: f32,
    pub wet_peak_db: f32,
    pub effective_azimuth_deg: f32,
    pub effective_elevation_deg: f32,
    pub last_error: Option<String>,
    pub channels_gt2_downmix: bool,
}

impl IngressSnapshot {
    pub fn disconnected() -> Self {
        Self {
            sample_rate: 0,
            channels: 0,
            state: DspBridgeState::Disconnected,
            input_frames: 0,
            consumed_frames: 0,
            dsp_chunks: 0,
            wet_frames: 0,
            dropped_frames: 0,
            overruns: 0,
            queue_depth_frames: 0,
            queue_high_water_frames: 0,
            wet_rms_db: 0.0,
            wet_peak_db: 0.0,
            effective_azimuth_deg: 0.0,
            effective_elevation_deg: 0.0,
            last_error: None,
            channels_gt2_downmix: false,
        }
    }

    pub fn error(msg: String) -> Self {
        let mut snap = Self::disconnected();
        snap.state = DspBridgeState::Error;
        snap.last_error = Some(msg);
        snap
    }
}

struct Shared {
    stop: AtomicBool,
    sample_rate: u32,
    channels: u32,
    channels_gt2: AtomicBool,
    input_frames: AtomicU64,
    consumed_frames: AtomicU64,
    dsp_chunks: AtomicU64,
    wet_frames: AtomicU64,
    dropped_frames: AtomicU64,
    overruns: AtomicU64,
    queue_depth: AtomicU64,
    high_water: AtomicU64,
    wet_rms_bits: AtomicU32,
    wet_peak_bits: AtomicU32,
    az_bits: AtomicU32,
    el_bits: AtomicU32,
    queue: Mutex<BoundedFrameQueue>,
    params: Mutex<SpatialParams>,
    mode: Mutex<PlaybackMode>,
    eq_db: Mutex<[f32; EQ_BANDS]>,
    array: Mutex<ArrayLayout>,
    last_error: Mutex<Option<String>>,
}

impl Shared {
    fn new(sample_rate: u32, channels: u32) -> Self {
        Self {
            stop: AtomicBool::new(false),
            sample_rate,
            channels,
            channels_gt2: AtomicBool::new(channels > 2),
            input_frames: AtomicU64::new(0),
            consumed_frames: AtomicU64::new(0),
            dsp_chunks: AtomicU64::new(0),
            wet_frames: AtomicU64::new(0),
            dropped_frames: AtomicU64::new(0),
            overruns: AtomicU64::new(0),
            queue_depth: AtomicU64::new(0),
            high_water: AtomicU64::new(0),
            wet_rms_bits: AtomicU32::new(0.0f32.to_bits()),
            wet_peak_bits: AtomicU32::new(0.0f32.to_bits()),
            az_bits: AtomicU32::new(SpatialParams::default().azimuth_deg.to_bits()),
            el_bits: AtomicU32::new(SpatialParams::default().elevation_deg.to_bits()),
            queue: Mutex::new(BoundedFrameQueue::with_default_capacity()),
            params: Mutex::new(SpatialParams::default()),
            mode: Mutex::new(PlaybackMode::Spatial),
            eq_db: Mutex::new([0.0; EQ_BANDS]),
            array: Mutex::new(ArrayLayout::default()),
            last_error: Mutex::new(None),
        }
    }

    fn set_error(&self, msg: String) {
        if let Ok(mut g) = self.last_error.lock() {
            *g = Some(msg);
        }
    }

    fn snapshot(&self) -> IngressSnapshot {
        let last_error = self.last_error.lock().ok().and_then(|g| g.clone());
        let chunks = self.dsp_chunks.load(Ordering::Relaxed);
        let running = !self.stop.load(Ordering::Relaxed);
        let state = if last_error.is_some() && running {
            DspBridgeState::Error
        } else if running && chunks > 0 {
            DspBridgeState::Processing
        } else if running {
            DspBridgeState::Starting
        } else {
            DspBridgeState::Disconnected
        };
        IngressSnapshot {
            sample_rate: self.sample_rate,
            channels: self.channels,
            state,
            input_frames: self.input_frames.load(Ordering::Relaxed),
            consumed_frames: self.consumed_frames.load(Ordering::Relaxed),
            dsp_chunks: chunks,
            wet_frames: self.wet_frames.load(Ordering::Relaxed),
            dropped_frames: self.dropped_frames.load(Ordering::Relaxed),
            overruns: self.overruns.load(Ordering::Relaxed),
            queue_depth_frames: self.queue_depth.load(Ordering::Relaxed),
            queue_high_water_frames: self.high_water.load(Ordering::Relaxed),
            wet_rms_db: f32::from_bits(self.wet_rms_bits.load(Ordering::Relaxed)),
            wet_peak_db: f32::from_bits(self.wet_peak_bits.load(Ordering::Relaxed)),
            effective_azimuth_deg: f32::from_bits(self.az_bits.load(Ordering::Relaxed)),
            effective_elevation_deg: f32::from_bits(self.el_bits.load(Ordering::Relaxed)),
            last_error,
            channels_gt2_downmix: self.channels_gt2.load(Ordering::Relaxed),
        }
    }
}

pub struct LiveIngress {
    shared: Arc<Shared>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl LiveIngress {
    pub fn start(sample_rate: u32, channels: u32) -> Result<Self, SpatialError> {
        if sample_rate == 0 {
            return Err(SpatialError::InvalidParam("sampleRate must be > 0".into()));
        }
        if channels == 0 {
            return Err(SpatialError::InvalidParam(
                "channelCount must be >= 1".into(),
            ));
        }
        let shared = Arc::new(Shared::new(sample_rate, channels));
        // channels > 2: first L/R pair, flagged on the snapshot (not last_error).
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("yinwei-live-dsp".into())
            .spawn(move || dsp_worker(worker_shared))
            .map_err(|e| SpatialError::AudioDevice(format!("dsp worker: {e}")))?;
        Ok(Self {
            shared,
            worker: Mutex::new(Some(worker)),
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.shared.sample_rate
    }

    pub fn channels(&self) -> u32 {
        self.shared.channels
    }

    /// Capture-thread push. Converts, try-enqueues, returns immediately.
    /// Never runs HRTF. On mutex contention the batch is dropped (newest).
    pub fn push_f32(&self, samples: &[f32]) -> Result<u64, SpatialError> {
        if self.shared.stop.load(Ordering::Relaxed) {
            return Err(SpatialError::NotImplemented("ingress stopped".into()));
        }
        let frames = frames_from_interleaved_f32(samples, self.shared.channels)?;
        self.enqueue(&frames);
        Ok(frames.len() as u64)
    }

    pub fn push_i16(&self, samples: &[i16]) -> Result<u64, SpatialError> {
        if self.shared.stop.load(Ordering::Relaxed) {
            return Err(SpatialError::NotImplemented("ingress stopped".into()));
        }
        let frames = frames_from_interleaved_i16(samples, self.shared.channels)?;
        self.enqueue(&frames);
        Ok(frames.len() as u64)
    }

    pub fn set_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        params.validate()?;
        let mut g = self
            .shared
            .params
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        *g = params;
        Ok(())
    }

    pub fn set_mode(&self, mode: PlaybackMode) {
        if let Ok(mut g) = self.shared.mode.lock() {
            *g = mode;
        }
    }

    pub fn set_eq(&self, gains: [f32; EQ_BANDS]) {
        if let Ok(mut g) = self.shared.eq_db.lock() {
            *g = crate::eq::clamp_eq_gains(gains);
        }
    }

    pub fn set_array(&self, array: ArrayLayout) {
        if let Ok(mut g) = self.shared.array.lock() {
            *g = array;
        }
    }

    pub fn snapshot(&self) -> IngressSnapshot {
        self.shared.snapshot()
    }

    /// Stop the worker, join it, and clear the bounded queue.
    /// Counters from this session remain readable until the next [`Self::start`].
    pub fn stop(&self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Ok(mut w) = self.worker.lock() {
            if let Some(h) = w.take() {
                let _ = h.join();
            }
        }
        if let Ok(mut q) = self.shared.queue.lock() {
            q.clear();
        }
        self.shared.queue_depth.store(0, Ordering::Relaxed);
    }

    fn enqueue(&self, frames: &[StereoFrame]) {
        if frames.is_empty() {
            return;
        }
        match self.shared.queue.try_lock() {
            Ok(mut q) => {
                let out = q.push_frames(frames);
                self.shared
                    .input_frames
                    .fetch_add(out.accepted_frames, Ordering::Relaxed);
                if out.dropped_frames > 0 {
                    self.shared
                        .dropped_frames
                        .fetch_add(out.dropped_frames, Ordering::Relaxed);
                }
                if out.overrun {
                    self.shared.overruns.fetch_add(1, Ordering::Relaxed);
                }
                let depth = q.len() as u64;
                self.shared.queue_depth.store(depth, Ordering::Relaxed);
                let hw = q.high_water_frames() as u64;
                let prev = self.shared.high_water.load(Ordering::Relaxed);
                if hw > prev {
                    self.shared.high_water.store(hw, Ordering::Relaxed);
                }
            }
            Err(_) => {
                // Capture must not block. Drop this newest batch.
                let n = frames.len() as u64;
                self.shared.dropped_frames.fetch_add(n, Ordering::Relaxed);
                self.shared.overruns.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

impl Drop for LiveIngress {
    fn drop(&mut self) {
        self.stop();
    }
}

static GLOBAL: Mutex<Option<Arc<LiveIngress>>> = Mutex::new(None);

fn global_slot() -> Result<std::sync::MutexGuard<'static, Option<Arc<LiveIngress>>>, SpatialError> {
    GLOBAL.lock().map_err(|_| SpatialError::LockPoisoned)
}

fn session_arc() -> Result<Option<Arc<LiveIngress>>, SpatialError> {
    Ok(global_slot()?.clone())
}

/// Process-wide session used by JNI. A new start stops the previous worker.
/// GLOBAL is not held while joining a worker or running DSP.
pub fn session_start(sample_rate: u32, channels: u32) -> Result<(), SpatialError> {
    let old = {
        let mut g = global_slot()?;
        g.take()
    };
    if let Some(old) = old {
        old.stop();
    }
    let ing = Arc::new(LiveIngress::start(sample_rate, channels)?);
    *global_slot()? = Some(ing);
    Ok(())
}

pub fn session_stop() -> Result<(), SpatialError> {
    if let Some(ing) = session_arc()? {
        ing.stop();
    }
    Ok(())
}

pub fn session_push_f32(samples: &[f32]) -> Result<u64, SpatialError> {
    let ing = session_arc()?
        .ok_or_else(|| SpatialError::NotImplemented("native ingress not started".into()))?;
    ing.push_f32(samples)
}

pub fn session_push_i16(samples: &[i16]) -> Result<u64, SpatialError> {
    let ing = session_arc()?
        .ok_or_else(|| SpatialError::NotImplemented("native ingress not started".into()))?;
    ing.push_i16(samples)
}

pub fn session_set_params(params: SpatialParams) -> Result<(), SpatialError> {
    let ing = session_arc()?
        .ok_or_else(|| SpatialError::NotImplemented("native ingress not started".into()))?;
    ing.set_params(params)
}

pub fn session_set_mode(mode: PlaybackMode) -> Result<(), SpatialError> {
    let ing = session_arc()?
        .ok_or_else(|| SpatialError::NotImplemented("native ingress not started".into()))?;
    ing.set_mode(mode);
    Ok(())
}

pub fn session_snapshot() -> IngressSnapshot {
    match session_arc() {
        Ok(Some(ing)) => ing.snapshot(),
        Ok(None) => IngressSnapshot::disconnected(),
        Err(e) => IngressSnapshot::error(format!("{e}")),
    }
}

fn dsp_worker(shared: Arc<Shared>) {
    let mut processor = match LiveDspProcessor::new(shared.sample_rate) {
        Ok(p) => p,
        Err(e) => {
            shared.set_error(format!("{e}"));
            return;
        }
    };
    if let Ok(p) = shared.params.lock() {
        let _ = processor.set_params(p.clone());
    }

    let mut acc: Vec<StereoFrame> = Vec::with_capacity(STREAM_CHUNK);

    while !shared.stop.load(Ordering::Relaxed) {
        if let Ok(mut q) = shared.queue.lock() {
            q.pop_n(STREAM_CHUNK - acc.len(), &mut acc);
            shared.queue_depth.store(q.len() as u64, Ordering::Relaxed);
        }

        if acc.len() < STREAM_CHUNK {
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        let chunk: Vec<StereoFrame> = acc.drain(..STREAM_CHUNK).collect();
        if let Ok(p) = shared.params.lock() {
            if processor.set_params(p.clone()).is_err() {
                continue;
            }
        }
        if let Ok(m) = shared.mode.lock() {
            processor.set_mode(*m);
        }
        if let Ok(eq) = shared.eq_db.lock() {
            processor.set_eq(*eq);
        }
        if let Ok(arr) = shared.array.lock() {
            processor.set_array(arr.clone());
        }

        let wet = match processor.process_chunk(&chunk) {
            Ok(w) => w,
            Err(e) => {
                shared.set_error(format!("{e}"));
                continue;
            }
        };

        let (rms, peak) = stereo_rms_peak(&wet);
        shared
            .wet_rms_bits
            .store(linear_to_db(rms).to_bits(), Ordering::Relaxed);
        shared
            .wet_peak_bits
            .store(linear_to_db(peak).to_bits(), Ordering::Relaxed);
        shared.az_bits.store(
            processor.effective_azimuth_deg().to_bits(),
            Ordering::Relaxed,
        );
        shared.el_bits.store(
            processor.effective_elevation_deg().to_bits(),
            Ordering::Relaxed,
        );
        shared
            .consumed_frames
            .fetch_add(STREAM_CHUNK as u64, Ordering::Relaxed);
        shared.dsp_chunks.fetch_add(1, Ordering::Relaxed);
        shared
            .wet_frames
            .fetch_add(STREAM_CHUNK as u64, Ordering::Relaxed);
        // A2: wet is measured and discarded. A3 will enqueue wet for output.
        let _ = wet;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live_queue::LIVE_INPUT_Q_FRAMES;
    use std::time::{Duration, Instant};

    fn sine_interleaved(frames: usize, sr: u32, amp: f32) -> Vec<f32> {
        let mut out = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            let t = i as f32 / sr as f32;
            let s = (t * 440.0 * std::f32::consts::TAU).sin() * amp;
            out.push(s);
            out.push(s * 0.8);
        }
        out
    }

    fn wait_chunks(ing: &LiveIngress, min_chunks: u64, timeout: Duration) -> IngressSnapshot {
        let start = Instant::now();
        loop {
            let snap = ing.snapshot();
            if snap.dsp_chunks >= min_chunks {
                return snap;
            }
            if start.elapsed() > timeout {
                return snap;
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn worker_processes_non_silent_float_stereo() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        let pcm = sine_interleaved(STREAM_CHUNK * 4, 48_000, 0.4);
        ing.push_f32(&pcm).unwrap();
        let snap = wait_chunks(&ing, 2, Duration::from_secs(3));
        assert!(snap.input_frames >= STREAM_CHUNK as u64 * 2);
        assert!(snap.consumed_frames >= STREAM_CHUNK as u64);
        assert!(snap.dsp_chunks >= 1, "dsp_chunks={}", snap.dsp_chunks);
        assert!(snap.wet_frames >= STREAM_CHUNK as u64);
        assert!(
            snap.wet_rms_db.is_finite(),
            "wet rms dB={}",
            snap.wet_rms_db
        );
        assert!(
            snap.wet_peak_db.is_finite(),
            "wet peak dB={}",
            snap.wet_peak_db
        );
        assert!(snap.last_error.is_none(), "{:?}", snap.last_error);
        assert_eq!(snap.state, DspBridgeState::Processing);
        assert!(snap.queue_high_water_frames as usize <= LIVE_INPUT_Q_FRAMES);
        ing.stop();
    }

    #[test]
    fn pcm16_path_reaches_dsp() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        let mut pcm = vec![0i16; STREAM_CHUNK * 2 * 3];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = ((i as f32).sin() * 8000.0) as i16;
        }
        ing.push_i16(&pcm).unwrap();
        let snap = wait_chunks(&ing, 1, Duration::from_secs(3));
        assert!(snap.dsp_chunks >= 1);
        assert!(snap.wet_rms_db.is_finite());
        ing.stop();
    }

    #[test]
    fn stop_clears_queue() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        let pcm = sine_interleaved(STREAM_CHUNK * 6, 48_000, 0.3);
        ing.push_f32(&pcm).unwrap();
        let _ = wait_chunks(&ing, 1, Duration::from_secs(3));
        ing.stop();
        let snap = ing.snapshot();
        assert_eq!(snap.queue_depth_frames, 0);
        // After stop the worker is gone; counters remain for diagnostics.
        assert!(ing.snapshot().dsp_chunks >= 1);
    }

    #[test]
    fn repeated_start_stop_does_not_leak_worker() {
        for _ in 0..3 {
            let ing = LiveIngress::start(48_000, 2).unwrap();
            ing.push_f32(&sine_interleaved(STREAM_CHUNK * 2, 48_000, 0.25))
                .unwrap();
            let _ = wait_chunks(&ing, 1, Duration::from_secs(2));
            ing.stop();
            assert_eq!(ing.snapshot().queue_depth_frames, 0);
        }
    }

    #[test]
    fn overflow_stays_bounded() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        let pcm = sine_interleaved(STREAM_CHUNK * 32, 48_000, 0.2);
        ing.push_f32(&pcm).unwrap();
        let snap = ing.snapshot();
        assert!(snap.queue_depth_frames as usize <= LIVE_INPUT_Q_FRAMES);
        assert!(snap.queue_high_water_frames as usize <= LIVE_INPUT_Q_FRAMES);
        assert!(snap.dropped_frames > 0 || snap.overruns > 0);
        ing.stop();
        assert_eq!(ing.snapshot().queue_depth_frames, 0);
    }

    #[test]
    fn params_remain_valid_across_updates() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        let mut p = SpatialParams::default();
        p.azimuth_deg = -45.0;
        ing.set_params(p).unwrap();
        ing.push_f32(&sine_interleaved(STREAM_CHUNK * 3, 48_000, 0.3))
            .unwrap();
        let snap = wait_chunks(&ing, 1, Duration::from_secs(3));
        assert!(snap.last_error.is_none());
        assert!(snap.effective_azimuth_deg.is_finite());
        assert!(snap.effective_elevation_deg.is_finite());
        ing.stop();
    }

    #[test]
    fn reject_zero_rate_or_channels() {
        assert!(LiveIngress::start(0, 2).is_err());
        assert!(LiveIngress::start(48_000, 0).is_err());
    }

    #[test]
    fn stream_chunk_accumulation_counts_whole_chunks() {
        let ing = LiveIngress::start(48_000, 2).unwrap();
        // One incomplete chunk must not produce wet output yet.
        ing.push_f32(&sine_interleaved(STREAM_CHUNK - 1, 48_000, 0.4))
            .unwrap();
        thread::sleep(Duration::from_millis(40));
        let before = ing.snapshot();
        assert_eq!(before.dsp_chunks, 0);
        assert_eq!(before.wet_frames, 0);
        // Completing the chunk should release exactly one DSP block.
        ing.push_f32(&sine_interleaved(1, 48_000, 0.4)).unwrap();
        let snap = wait_chunks(&ing, 1, Duration::from_secs(2));
        assert!(snap.dsp_chunks >= 1);
        assert_eq!(snap.consumed_frames % STREAM_CHUNK as u64, 0);
        ing.stop();
    }

    fn wait_session_chunks(min_chunks: u64, timeout: Duration) -> IngressSnapshot {
        let start = Instant::now();
        loop {
            let snap = session_snapshot();
            if snap.dsp_chunks >= min_chunks {
                return snap;
            }
            if start.elapsed() > timeout {
                return snap;
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn session_start_stop_replaces_previous_worker() {
        session_start(48_000, 2).unwrap();
        session_push_f32(&sine_interleaved(STREAM_CHUNK * 3, 48_000, 0.3)).unwrap();
        let first = wait_session_chunks(1, Duration::from_secs(3));
        assert!(first.dsp_chunks >= 1);
        session_stop().unwrap();
        assert_eq!(session_snapshot().queue_depth_frames, 0);
        session_start(48_000, 2).unwrap();
        let second = session_snapshot();
        assert_eq!(second.input_frames, 0);
        assert_eq!(second.dsp_chunks, 0);
        session_push_f32(&sine_interleaved(STREAM_CHUNK * 3, 48_000, 0.3)).unwrap();
        let third = wait_session_chunks(1, Duration::from_secs(3));
        assert!(third.dsp_chunks >= 1);
        session_stop().unwrap();
    }
}
