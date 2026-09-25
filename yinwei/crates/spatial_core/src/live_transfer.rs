//! Live system-audio transfer: WASAPI process loopback → HRTF → cpal out.
//!
//! Prefer process-loopback (`pid > 0`) so our own render is not re-captured.
//! Device loopback (`pid == 0`) is rejected (feedback risk).
//!
//! Do **not** mute the source app session (`ISimpleAudioVolume` / volume 0):
//! 汽水 / Spotify auto-pause. Overlay on one device is preview-grade.
//! Dart `setSourceMuted` is a no-op.
//!
//! Wet output: empty device name follows Windows **default** render endpoint
//! (Bluetooth swaps, Nahimic Sound Sharing APOs). Named devices are explicit
//! picks only — never auto-lock to a Sony `WH-` headset.
//! Dart mutes a **separate** speaker device so dry+wet do not overlay; it
//! does not mute speakers when they *are* the wet/default endpoint.

#![cfg(all(feature = "realtime", windows))]

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    BufferSize, FromSample, Sample, SampleFormat, Stream, StreamConfig, SupportedBufferSize,
};
use wasapi::{
    AudioClient, Direction, SampleType, StreamMode, WaveFormat, initialize_mta,
};

use crate::decode::StereoFrame;
use crate::error::SpatialError;
use crate::hrtf_render::{HrtfStreamer, STREAM_CHUNK};
use crate::params::{PlaybackMode, SpatialParams};
use crate::resample::resample_cubic;

struct SendStream(#[allow(dead_code)] Stream);
unsafe impl Send for SendStream {}

/// MAIN include-tree: return as soon as energy is seen; ~220ms worst case.
const MAIN_ENERGY_WAIT: Duration = Duration::from_millis(220);
/// Exclude-self fallback only (no per-child PID walk).
const EXCLUDE_SELF_ENERGY_WAIT: Duration = Duration::from_millis(180);
const ENERGY_POLL: Duration = Duration::from_millis(5);

/// Live queue depth in STREAM_CHUNK units (512 frames ≈ 10.7 ms @ 48 kHz).
/// 4 chunks ≈ 43 ms — keep end-to-end well under 300 ms without a 1s wet pad.
pub const LIVE_DRY_Q_CHUNKS: usize = 4;
pub const LIVE_WET_Q_CHUNKS: usize = 4;
const DRY_Q_MAX: usize = STREAM_CHUNK * LIVE_DRY_Q_CHUNKS;
const WET_Q_MAX: usize = STREAM_CHUNK * LIVE_WET_Q_CHUNKS;
/// Target cpal callback (~10 ms). WASAPI clamps to the device range.
const OUT_BUFFER_MS: u32 = 10;
/// WASAPI process-loopback packet size (100 ns units). 10 ms.
const CAPTURE_BUFFER_HNS: i64 = 10_0000;

fn trim_front(q: &mut VecDeque<StereoFrame>, max: usize) {
    while q.len() > max {
        q.pop_front();
    }
}

fn target_output_frames(sample_rate: u32) -> u32 {
    ((u64::from(sample_rate.max(1)) * u64::from(OUT_BUFFER_MS)) / 1000).max(256) as u32
}

fn small_output_config(supported: &cpal::SupportedStreamConfig) -> StreamConfig {
    let mut config: StreamConfig = supported.clone().into();
    let target = target_output_frames(config.sample_rate.0);
    config.buffer_size = match supported.buffer_size() {
        SupportedBufferSize::Range { min, max } => BufferSize::Fixed(target.clamp(*min, *max)),
        SupportedBufferSize::Unknown => BufferSize::Fixed(target),
    };
    config
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

struct Shared {
    stop: AtomicBool,
    running: AtomicBool,
    capture_ok: AtomicBool,
    frames_captured: AtomicU64,
    frames_with_energy: AtomicU64,
    last_energy_ms: AtomicU64,
    /// cpal output stream died (volume / BT renegotiate). Watchdog reopens it.
    out_needs_restart: AtomicBool,
    mode: AtomicU8Mode,
    params: Mutex<SpatialParams>,
    eq_db: Mutex<[f32; crate::eq::EQ_BANDS]>,
    array: Mutex<crate::layout::ArrayLayout>,
    dry_q: Mutex<VecDeque<StereoFrame>>,
    wet_q: Mutex<VecDeque<StereoFrame>>,
    live_az_bits: AtomicU32,
    live_el_bits: AtomicU32,
    /// WASAPI capture / HRTF content rate (RealtimePlayer `content_rate`).
    capture_rate: AtomicU32,
    /// cpal device callback rate (RealtimePlayer `output_rate`).
    device_rate: AtomicU32,
    /// Bumped to drop a capture worker without stopping DSP / output.
    capture_gen: AtomicU32,
    /// Dart holds wet silent until the source tree is pinned to muted speakers.
    out_hold: AtomicBool,
}

/// AtomicU8 wrapper for PlaybackMode.
struct AtomicU8Mode(AtomicU32);
impl AtomicU8Mode {
    fn new(v: u8) -> Self {
        Self(AtomicU32::new(v as u32))
    }
    fn store(&self, v: u8) {
        self.0.store(v as u32, Ordering::Relaxed);
    }
    fn load(&self) -> u8 {
        self.0.load(Ordering::Relaxed) as u8
    }
}

/// Process-wide live transfer engine (separate from file RealtimePlayer).
pub struct LiveTransferEngine {
    shared: Arc<Shared>,
    workers: Mutex<Vec<JoinHandle<()>>>,
    out_stream: Arc<Mutex<Option<SendStream>>>,
    output_device_name: Arc<Mutex<String>>,
    /// Serializes start/stop so FFI start does not hold the process-wide LIVE lock.
    start_gate: Mutex<()>,
}

impl LiveTransferEngine {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Shared {
                stop: AtomicBool::new(true),
                running: AtomicBool::new(false),
                capture_ok: AtomicBool::new(false),
                frames_captured: AtomicU64::new(0),
                frames_with_energy: AtomicU64::new(0),
                last_energy_ms: AtomicU64::new(0),
                out_needs_restart: AtomicBool::new(false),
                mode: AtomicU8Mode::new(1),
                params: Mutex::new(SpatialParams::default()),
                eq_db: Mutex::new([0.0; crate::eq::EQ_BANDS]),
                array: Mutex::new(crate::layout::ArrayLayout::default()),
                dry_q: Mutex::new(VecDeque::with_capacity(DRY_Q_MAX * 2)),
                wet_q: Mutex::new(VecDeque::with_capacity(WET_Q_MAX * 2)),
                live_az_bits: AtomicU32::new(90.0f32.to_bits()),
                live_el_bits: AtomicU32::new((-10.0f32).to_bits()),
                capture_rate: AtomicU32::new(0),
                device_rate: AtomicU32::new(0),
                capture_gen: AtomicU32::new(0),
                out_hold: AtomicBool::new(false),
            }),
            workers: Mutex::new(Vec::new()),
            out_stream: Arc::new(Mutex::new(None)),
            output_device_name: Arc::new(Mutex::new(String::new())),
            start_gate: Mutex::new(()),
        }
    }

    pub fn is_running(&self) -> bool {
        self.shared.running.load(Ordering::Relaxed)
    }

    pub fn set_params(&self, params: SpatialParams) -> Result<(), SpatialError> {
        params.validate()?;
        if let Ok(mut g) = self.shared.params.lock() {
            *g = params;
        }
        Ok(())
    }

    pub fn set_eq(&self, gains: [f32; crate::eq::EQ_BANDS]) -> Result<(), SpatialError> {
        if let Ok(mut g) = self.shared.eq_db.lock() {
            *g = crate::eq::clamp_eq_gains(gains);
        }
        Ok(())
    }

    pub fn set_array(&self, mode: i32) -> Result<(), SpatialError> {
        let mut g = self
            .shared
            .array
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        g.set_mode(mode)
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
        let mut g = self
            .shared
            .array
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        g.set_speaker(index, az_deg, el_deg, dist_m, gain_db, mute, feed)
    }

    pub fn set_speaker_count(&self, n: i32) -> Result<(), SpatialError> {
        let mut g = self
            .shared
            .array
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?;
        g.set_speaker_count(n)
    }

    pub fn set_mode(&self, mode: PlaybackMode) {
        self.shared.mode.store(match mode {
            PlaybackMode::Original => 0,
            PlaybackMode::Spatial => 1,
        });
    }

    pub fn current_azimuth_deg(&self) -> f32 {
        f32::from_bits(self.shared.live_az_bits.load(Ordering::Relaxed))
    }

    pub fn current_elevation_deg(&self) -> f32 {
        f32::from_bits(self.shared.live_el_bits.load(Ordering::Relaxed))
    }

    pub fn frames_captured(&self) -> u64 {
        self.shared.frames_captured.load(Ordering::Relaxed)
    }

    pub fn frames_with_energy(&self) -> u64 {
        self.shared.frames_with_energy.load(Ordering::Relaxed)
    }

    pub fn last_energy_ms(&self) -> u64 {
        self.shared.last_energy_ms.load(Ordering::Relaxed)
    }

    #[allow(dead_code)]
    pub fn capture_ok(&self) -> bool {
        self.shared.capture_ok.load(Ordering::Relaxed)
    }

    pub fn set_output_device_name(&self, name: &str) {
        let next = name.trim().to_string();
        let changed = if let Ok(mut g) = self.output_device_name.lock() {
            if *g == next {
                false
            } else {
                *g = next;
                true
            }
        } else {
            false
        };
        // Split routing often learns the headphone name after capture already
        // started — hop the cpal stream without a full live restart.
        if changed && self.shared.running.load(Ordering::Relaxed) {
            self.shared.out_needs_restart.store(true, Ordering::Relaxed);
        }
    }

    pub fn output_device_name(&self) -> String {
        self.output_device_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    /// Silence cpal wet (keep capture/DSP) until Dart pins the source to muted speakers.
    /// Flush queues so ungating does not dump a second of delayed audio.
    pub fn set_output_hold(&self, hold: bool) {
        self.shared.out_hold.store(hold, Ordering::Relaxed);
        self.clear_pcm_queues();
    }

    fn clear_pcm_queues(&self) {
        if let Ok(mut d) = self.shared.dry_q.lock() {
            d.clear();
        }
        if let Ok(mut w) = self.shared.wet_q.lock() {
            w.clear();
        }
    }

    pub fn start(&self, process_id: u32) -> Result<(), SpatialError> {
        let _gate = self.start_gate.lock().unwrap_or_else(|e| e.into_inner());
        // Preserve Dart's pin-before-wet hold across the inner stop/restart.
        let keep_hold = self.shared.out_hold.load(Ordering::Relaxed);
        self.stop_inner();
        self.shared.out_hold.store(keep_hold, Ordering::Relaxed);

        if process_id == 0 {
            return Err(SpatialError::AudioDevice(
                "device loopback disabled (feedback risk); need process pid".into(),
            ));
        }

        // MAIN include-tree first. Per-child PID probes used to add 400ms each
        // after a 1.2s MAIN wait. Exclude-self covers silent MAIN trees
        // (Electron child render) without walking every descendant.
        let attempts = start_capture_attempts(process_id, std::process::id());

        self.prepare_session();

        let mut last = format!("no WASAPI energy on pid={process_id}");
        let mut capt_ok: Option<JoinHandle<()>> = None;

        for (i, (pid, include_tree, budget)) in attempts.into_iter().enumerate() {
            self.reset_capture_counters();
            let handle = self.spawn_capture(pid, include_tree, process_id)?;
            // Open cpal + DSP on the first attempt so wet audio can flow as
            // soon as loopback has energy (do not wait, then init output).
            if i == 0 {
                if let Err(e) = self.open_output() {
                    self.abort_capture(handle);
                    self.stop_inner();
                    return Err(e);
                }
                if let Err(e) = self.spawn_dsp_and_watchdog() {
                    self.abort_capture(handle);
                    self.stop_inner();
                    return Err(e);
                }
            }
            if self.wait_for_energy(budget) {
                capt_ok = Some(handle);
                if !include_tree {
                    eprintln!(
                        "yinwei live: pid={process_id} tree silent; exclude-self loopback ok"
                    );
                }
                break;
            }
            let frames = self.shared.frames_captured.load(Ordering::Relaxed);
            let energy = self.shared.frames_with_energy.load(Ordering::Relaxed);
            last = format!(
                "pid={pid} include_tree={include_tree} frames={frames} energy={energy}"
            );
            self.abort_capture(handle);
        }
        let Some(capt) = capt_ok else {
            self.stop_inner();
            return Err(SpatialError::AudioDevice(format!(
                "process loopback silent (pid={process_id}). {last}. Wrong PID or app blocked capture."
            )));
        };

        if let Ok(mut w) = self.workers.lock() {
            w.push(capt);
        }
        Ok(())
    }

    fn prepare_session(&self) {
        self.shared.stop.store(false, Ordering::Relaxed);
        self.shared.running.store(true, Ordering::Relaxed);
        self.shared.out_needs_restart.store(false, Ordering::Relaxed);
        if let Ok(mut d) = self.shared.dry_q.lock() {
            d.clear();
        }
        if let Ok(mut w) = self.shared.wet_q.lock() {
            w.clear();
        }
        self.reset_capture_counters();
    }

    fn reset_capture_counters(&self) {
        self.shared.capture_ok.store(false, Ordering::Relaxed);
        self.shared.frames_captured.store(0, Ordering::Relaxed);
        self.shared.frames_with_energy.store(0, Ordering::Relaxed);
        self.shared.last_energy_ms.store(0, Ordering::Relaxed);
        self.shared.capture_rate.store(0, Ordering::Relaxed);
        if let Ok(mut d) = self.shared.dry_q.lock() {
            d.clear();
        }
    }

    fn spawn_dsp_and_watchdog(&self) -> Result<(), SpatialError> {
        let shared_d = Arc::clone(&self.shared);
        let dsp = thread::Builder::new()
            .name("yinwei-live-dsp".into())
            .spawn(move || {
                while !shared_d.stop.load(Ordering::Relaxed) {
                    match dsp_loop(Arc::clone(&shared_d)) {
                        Ok(()) => break,
                        Err(e) => {
                            eprintln!("yinwei live dsp retry: {e}");
                            if shared_d.stop.load(Ordering::Relaxed) {
                                break;
                            }
                            thread::sleep(Duration::from_millis(50));
                        }
                    }
                }
            })
            .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;

        let shared_w = Arc::clone(&self.shared);
        let out_w = Arc::clone(&self.out_stream);
        let name_w = Arc::clone(&self.output_device_name);
        let out_wd = thread::Builder::new()
            .name("yinwei-live-outwd".into())
            .spawn(move || output_watchdog(shared_w, out_w, name_w))
            .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;

        if let Ok(mut w) = self.workers.lock() {
            w.push(dsp);
            w.push(out_wd);
        }
        Ok(())
    }

    fn spawn_capture(
        &self,
        process_id: u32,
        include_tree: bool,
        root_pid: u32,
    ) -> Result<JoinHandle<()>, SpatialError> {
        let shared_c = Arc::clone(&self.shared);
        let targets = capture_failover_targets(process_id, include_tree, root_pid);
        let gen = self.shared.capture_gen.load(Ordering::Relaxed);
        thread::Builder::new()
            .name("yinwei-live-capt".into())
            .spawn(move || {
                // WASAPI process loopback dies when Electron recycles a child,
                // the session is invalidated, or BT hops. Keep Transfer up by
                // rotating back to the root tree instead of stopping.
                let mut i = 0usize;
                while !shared_c.stop.load(Ordering::Relaxed)
                    && shared_c.capture_gen.load(Ordering::Relaxed) == gen
                {
                    let (pid, tree) = targets[i % targets.len()];
                    match capture_loop(shared_c.clone(), pid, tree, gen) {
                        Ok(()) => break,
                        Err(e) => {
                            eprintln!(
                                "yinwei live capture pid={pid} include_tree={tree} retry: {e}"
                            );
                            shared_c.capture_ok.store(false, Ordering::Relaxed);
                            i = i.saturating_add(1);
                            if shared_c.stop.load(Ordering::Relaxed)
                                || shared_c.capture_gen.load(Ordering::Relaxed) != gen
                            {
                                break;
                            }
                            for _ in 0..50 {
                                if shared_c.stop.load(Ordering::Relaxed)
                                    || shared_c.capture_gen.load(Ordering::Relaxed) != gen
                                {
                                    break;
                                }
                                thread::sleep(Duration::from_millis(5));
                            }
                        }
                    }
                }
            })
            .map_err(|e| SpatialError::AudioDevice(e.to_string()))
    }

    fn wait_for_energy(&self, budget: Duration) -> bool {
        let start = Instant::now();
        loop {
            if self.shared.frames_with_energy.load(Ordering::Relaxed) > 0 {
                return true;
            }
            if self.shared.stop.load(Ordering::Relaxed)
                && !self.shared.running.load(Ordering::Relaxed)
            {
                return false;
            }
            if start.elapsed() >= budget {
                return false;
            }
            thread::sleep(ENERGY_POLL);
        }
    }

    fn abort_capture(&self, capt: JoinHandle<()>) {
        self.shared.capture_gen.fetch_add(1, Ordering::Relaxed);
        let _ = capt.join();
    }

    pub fn stop(&self) {
        let _gate = self.start_gate.lock().unwrap_or_else(|e| e.into_inner());
        self.shared.out_hold.store(false, Ordering::Relaxed);
        self.stop_inner();
    }

    fn stop_inner(&self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.shared.running.store(false, Ordering::Relaxed);
        self.shared.out_needs_restart.store(false, Ordering::Relaxed);
        self.shared.capture_gen.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut w) = self.workers.lock() {
            for h in w.drain(..) {
                let _ = h.join();
            }
        }
        if let Ok(mut s) = self.out_stream.lock() {
            *s = None;
        }
        if let Ok(mut d) = self.shared.dry_q.lock() {
            d.clear();
        }
        if let Ok(mut q) = self.shared.wet_q.lock() {
            q.clear();
        }
    }

    fn open_output(&self) -> Result<(), SpatialError> {
        open_output_stream(
            &self.shared,
            &self.out_stream,
            &self.output_device_name(),
        )
    }
}

impl Default for LiveTransferEngine {
    fn default() -> Self {
        Self::new()
    }
}

pub fn list_output_device_names() -> Vec<String> {
    let host = cpal::default_host();
    let mut names = Vec::new();
    if let Ok(devs) = host.output_devices() {
        for d in devs {
            if let Ok(n) = d.name() {
                names.push(n);
            }
        }
    }
    names
}

/// Empty `preferred` follows the Windows default render device. A named
/// device stays pinned (user pick). Sony/WH- must not be written here by Dart.
pub fn should_follow_default_device_change(
    preferred: &str,
    last_default_name: &str,
    now_default_name: &str,
) -> bool {
    if !preferred.trim().is_empty() {
        return false;
    }
    let last = last_default_name.trim();
    let now = now_default_name.trim();
    !last.is_empty() && !now.is_empty() && last != now
}

pub fn default_output_device_name() -> String {
    cpal::default_host()
        .default_output_device()
        .and_then(|d| d.name().ok())
        .unwrap_or_default()
}

fn current_default_output_name() -> String {
    default_output_device_name()
}

fn resolve_output_device(preferred: &str) -> Result<cpal::Device, SpatialError> {
    let host = cpal::default_host();
    let needle = preferred.trim();
    if !needle.is_empty() {
        if let Ok(devs) = host.output_devices() {
            let lower = needle.to_lowercase();
            let mut substring: Option<cpal::Device> = None;
            for d in devs {
                let Ok(n) = d.name() else { continue };
                if n == needle {
                    return Ok(d);
                }
                if substring.is_none() && n.to_lowercase().contains(&lower) {
                    substring = Some(d);
                }
            }
            if let Some(d) = substring {
                return Ok(d);
            }
        }
        return Err(SpatialError::AudioDevice(format!(
            "output device not found: {needle}"
        )));
    }
    host.default_output_device()
        .ok_or_else(|| SpatialError::AudioDevice("no output device".into()))
}

fn open_output_stream(
    shared: &Arc<Shared>,
    out_stream: &Arc<Mutex<Option<SendStream>>>,
    preferred: &str,
) -> Result<(), SpatialError> {
    let device = resolve_output_device(preferred)?;
    let supported = device
        .default_output_config()
        .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;
    let sample_rate = supported.sample_rate().0.max(1);
    shared.device_rate.store(sample_rate, Ordering::Relaxed);
    let config = small_output_config(&supported);
    let cloned = Arc::clone(shared);
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build_out::<f32>(&device, &config, cloned)?,
        SampleFormat::I16 => build_out::<i16>(&device, &config, cloned)?,
        SampleFormat::U16 => build_out::<u16>(&device, &config, cloned)?,
        _ => {
            return Err(SpatialError::AudioDevice(
                "unsupported output sample format".into(),
            ))
        }
    };
    stream
        .play()
        .map_err(|e| SpatialError::AudioDevice(e.to_string()))?;
    if shared.stop.load(Ordering::Relaxed) {
        return Ok(());
    }
    if let Ok(mut g) = out_stream.lock() {
        if !shared.stop.load(Ordering::Relaxed) {
            *g = Some(SendStream(stream));
        }
    }
    Ok(())
}

fn output_watchdog(
    shared: Arc<Shared>,
    out_stream: Arc<Mutex<Option<SendStream>>>,
    output_device_name: Arc<Mutex<String>>,
) {
    let mut last_default = current_default_output_name();
    let mut ticks: u32 = 0;
    while !shared.stop.load(Ordering::Relaxed) {
        if shared.out_needs_restart.swap(false, Ordering::Relaxed) {
            eprintln!("yinwei live: restarting output after device error");
            if let Ok(mut s) = out_stream.lock() {
                *s = None;
            }
            if shared.stop.load(Ordering::Relaxed) {
                break;
            }
            let preferred = output_device_name
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();
            if let Err(e) = open_output_stream(&shared, &out_stream, &preferred) {
                eprintln!("yinwei live out restart failed: {e}");
                shared.out_needs_restart.store(true, Ordering::Relaxed);
            } else if preferred.trim().is_empty() {
                last_default = current_default_output_name();
            }
        } else {
            ticks = ticks.wrapping_add(1);
            if ticks % 5 == 0 {
                let preferred = output_device_name
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                if preferred.trim().is_empty() {
                    let now = current_default_output_name();
                    if should_follow_default_device_change(&preferred, &last_default, &now)
                    {
                        eprintln!(
                            "yinwei live: default output changed {last_default} -> {now}"
                        );
                        last_default = now;
                        shared.out_needs_restart.store(true, Ordering::Relaxed);
                    } else if last_default.is_empty() {
                        last_default = now;
                    }
                }
            }
        }
        thread::sleep(Duration::from_millis(80));
    }
}

fn build_out<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    shared: Arc<Shared>,
) -> Result<Stream, SpatialError>
where
    T: Sample + FromSample<f32> + cpal::SizedSample,
{
    let shared_err = Arc::clone(&shared);
    let channels = config.channels as usize;
    let make = |cfg: &StreamConfig| {
        let shared = Arc::clone(&shared);
        let shared_err = Arc::clone(&shared_err);
        let err_fn = move |e| {
            eprintln!("yinwei live out: {e}");
            shared_err.out_needs_restart.store(true, Ordering::Relaxed);
        };
        device.build_output_stream(
            cfg,
            move |data: &mut [T], _| {
                if shared.stop.load(Ordering::Relaxed)
                    || shared.out_hold.load(Ordering::Relaxed)
                {
                    for s in data.iter_mut() {
                        *s = T::EQUILIBRIUM;
                    }
                    return;
                }
                let mut wet = match shared.wet_q.lock() {
                    Ok(g) => g,
                    Err(_) => return,
                };
                let mut i = 0;
                // No makeup gain — silent-packet garbage + gain became an "engine roar".
                while i + channels <= data.len() {
                    let (l, r) = wet.pop_front().unwrap_or((0.0, 0.0));
                    data[i] = T::from_sample(l.clamp(-1.0, 1.0));
                    if channels > 1 {
                        data[i + 1] = T::from_sample(r.clamp(-1.0, 1.0));
                    }
                    for c in 2..channels {
                        data[i + c] = T::EQUILIBRIUM;
                    }
                    i += channels;
                }
            },
            err_fn,
            None,
        )
    };
    match make(config) {
        Ok(s) => Ok(s),
        Err(e) => {
            if matches!(config.buffer_size, BufferSize::Default) {
                return Err(SpatialError::AudioDevice(e.to_string()));
            }
            eprintln!("yinwei live: small cpal buffer rejected ({e}); default");
            let mut fallback = config.clone();
            fallback.buffer_size = BufferSize::Default;
            make(&fallback).map_err(|e2| SpatialError::AudioDevice(e2.to_string()))
        }
    }
}

fn descendant_pids(root: u32) -> Vec<u32> {
    #[repr(C)]
    struct ProcessEntry32W {
        dw_size: u32,
        cnt_usage: u32,
        th32_process_id: u32,
        th32_default_heap_id: usize,
        th32_module_id: u32,
        cnt_threads: u32,
        th32_parent_process_id: u32,
        pc_pri_class_base: i32,
        dw_flags: u32,
        sz_exe_file: [u16; 260],
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> isize;
        fn Process32FirstW(snap: isize, pe: *mut ProcessEntry32W) -> i32;
        fn Process32NextW(snap: isize, pe: *mut ProcessEntry32W) -> i32;
        fn CloseHandle(h: isize) -> i32;
    }

    const TH32CS_SNAPPROCESS: u32 = 0x2;
    const INVALID_HANDLE: isize = -1;

    let snap = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snap == 0 || snap == INVALID_HANDLE {
        return Vec::new();
    }
    let mut pe = ProcessEntry32W {
        dw_size: std::mem::size_of::<ProcessEntry32W>() as u32,
        cnt_usage: 0,
        th32_process_id: 0,
        th32_default_heap_id: 0,
        th32_module_id: 0,
        cnt_threads: 0,
        th32_parent_process_id: 0,
        pc_pri_class_base: 0,
        dw_flags: 0,
        sz_exe_file: [0; 260],
    };
    let mut pairs: Vec<(u32, u32)> = Vec::new();
    unsafe {
        if Process32FirstW(snap, &mut pe) != 0 {
            loop {
                pairs.push((pe.th32_process_id, pe.th32_parent_process_id));
                if Process32NextW(snap, &mut pe) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    let mut out = Vec::new();
    let mut stack = vec![root];
    while let Some(cur) = stack.pop() {
        for (pid, parent) in &pairs {
            if *parent == cur && *pid != cur && !out.contains(pid) {
                out.push(*pid);
                stack.push(*pid);
            }
        }
    }
    out
}

fn capture_failover_targets(current_pid: u32, include_tree: bool, root_pid: u32) -> Vec<(u32, bool)> {
    let mut out = vec![(current_pid, include_tree)];
    let root = if root_pid != 0 { root_pid } else { current_pid };
    if root != current_pid || !include_tree {
        out.push((root, true));
    }
    for child in descendant_pids(root) {
        if !out.iter().any(|(p, _)| *p == child) {
            out.push((child, true));
        }
    }
    let self_pid = std::process::id();
    if self_pid != 0 && !out.iter().any(|(p, tree)| *p == self_pid && !*tree) {
        out.push((self_pid, false));
    }
    out
}

fn start_capture_attempts(process_id: u32, self_pid: u32) -> Vec<(u32, bool, Duration)> {
    let mut attempts = vec![(process_id, true, MAIN_ENERGY_WAIT)];
    if self_pid != 0 && self_pid != process_id {
        attempts.push((self_pid, false, EXCLUDE_SELF_ENERGY_WAIT));
    }
    attempts
}

fn capture_loop(
    shared: Arc<Shared>,
    process_id: u32,
    include_tree: bool,
    gen: u32,
) -> Result<(), SpatialError> {
    let hr = initialize_mta();
    if hr.is_err() {
        return Err(SpatialError::AudioDevice(format!("MTA init failed: {hr:?}")));
    }

    if process_id == 0 {
        return Err(SpatialError::AudioDevice(
            "device loopback disabled (feedback risk); need process pid".into(),
        ));
    }

    let desired = WaveFormat::new(32, 32, &SampleType::Float, 48000, 2, None);
    // Process loopback often does not signal WASAPI events; poll the packet queue.
    let mode = StreamMode::PollingShared {
        autoconvert: true,
        buffer_duration_hns: CAPTURE_BUFFER_HNS,
    };

    let mut audio_client =
        AudioClient::new_application_loopback_client(process_id, include_tree).map_err(|e| {
            SpatialError::AudioDevice(format!(
                "process loopback pid={process_id} include_tree={include_tree} failed: {e} (need Windows 10 2004+)"
            ))
        })?;

    audio_client
        .initialize_client(&desired, &Direction::Capture, &mode)
        .map_err(|e| SpatialError::AudioDevice(format!("init capture: {e}")))?;

    let capture_sr = desired.get_samplespersec().max(1);
    shared.capture_rate.store(capture_sr, Ordering::Relaxed);

    let capture = audio_client
        .get_audiocaptureclient()
        .map_err(|e| SpatialError::AudioDevice(format!("capture client: {e}")))?;
    let blockalign = desired.get_blockalign() as usize;

    audio_client
        .start_stream()
        .map_err(|e| SpatialError::AudioDevice(format!("start capture: {e}")))?;

    if shared.stop.load(Ordering::Relaxed)
        || shared.capture_gen.load(Ordering::Relaxed) != gen
    {
        let _ = audio_client.stop_stream();
        return Ok(());
    }

    let mut byte_q: VecDeque<u8> = VecDeque::with_capacity(blockalign * STREAM_CHUNK * 8);

    while !shared.stop.load(Ordering::Relaxed)
        && shared.capture_gen.load(Ordering::Relaxed) == gen
    {
        let nframes = capture
            .get_next_packet_size()
            .map_err(|e| SpatialError::AudioDevice(format!("packet size: {e}")))?
            .unwrap_or(0);
        if nframes > 0 {
            let nbytes = nframes as usize * blockalign;
            let mut buf = vec![0u8; nbytes];
            let (got, flags) = capture
                .read_from_device(&mut buf)
                .map_err(|e| SpatialError::AudioDevice(format!("read: {e}")))?;
            let got_bytes = got as usize * blockalign;
            // CRITICAL: AUDCLNT_BUFFERFLAGS_SILENT means buffer contents are UNDEFINED.
            // Treating them as float PCM produces loud "engine roar" that continues
            // after the music app has stopped.
            if flags.silent {
                for _ in 0..got_bytes {
                    byte_q.push_back(0);
                }
            } else {
                for b in buf.iter().take(got_bytes) {
                    byte_q.push_back(*b);
                }
            }
        } else {
            thread::sleep(Duration::from_millis(1));
        }

        while byte_q.len() >= blockalign * STREAM_CHUNK {
            let mut frames = Vec::with_capacity(STREAM_CHUNK);
            let mut energy = 0.0f32;
            for _ in 0..STREAM_CHUNK {
                let mut bytes = [0u8; 8];
                for b in &mut bytes {
                    *b = byte_q.pop_front().unwrap_or(0);
                }
                let mut l = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                let mut r = f32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
                if !l.is_finite() {
                    l = 0.0;
                }
                if !r.is_finite() {
                    r = 0.0;
                }
                l = l.clamp(-1.0, 1.0);
                r = r.clamp(-1.0, 1.0);
                energy += l * l + r * r;
                frames.push((l, r));
            }
            // Gate near-silence so HRTF/reverb cannot turn a noise floor into rumble.
            let n = frames.len() as u64;
            if energy < 1e-8 {
                frames.fill((0.0, 0.0));
            } else {
                shared.frames_with_energy.fetch_add(n, Ordering::Relaxed);
                shared.last_energy_ms.store(now_ms(), Ordering::Relaxed);
            }
            if let Ok(mut dry) = shared.dry_q.lock() {
                trim_front(&mut dry, DRY_Q_MAX);
                dry.extend(frames);
                trim_front(&mut dry, DRY_Q_MAX);
                shared.frames_captured.fetch_add(n, Ordering::Relaxed);
                shared.capture_ok.store(true, Ordering::Relaxed);
            }
        }
    }
    let _ = audio_client.stop_stream();
    Ok(())
}

fn dsp_loop(shared: Arc<Shared>) -> Result<(), SpatialError> {
    // Capture rate = HRTF / content rate. Device rate is independent (cpal).
    let mut capture_sr = 0u32;
    let mut device_sr = 0u32;
    for _ in 0..100 {
        capture_sr = shared.capture_rate.load(Ordering::Relaxed);
        device_sr = shared.device_rate.load(Ordering::Relaxed);
        if capture_sr > 0 && device_sr > 0 {
            break;
        }
        if shared.stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(10));
    }
    let capture_sr = capture_sr.max(1);
    let device_sr = device_sr.max(1);
    let mut streamer = HrtfStreamer::new(capture_sr)?;
    let mut eq = crate::eq::GraphicEq::new(capture_sr);
    {
        let p = shared.params.lock().map_err(|_| SpatialError::LockPoisoned)?;
        streamer.snap_to_params(&p);
    }

    let mut acc: Vec<StereoFrame> = Vec::with_capacity(STREAM_CHUNK);

    while !shared.stop.load(Ordering::Relaxed) {
        // Keep wet at a few chunks — sleeping on a ~200 ms pad was A/V desync.
        let wet_len = shared.wet_q.lock().map(|w| w.len()).unwrap_or(0);
        if wet_len >= WET_Q_MAX {
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        if let Ok(mut dry) = shared.dry_q.lock() {
            while acc.len() < STREAM_CHUNK {
                if let Some(f) = dry.pop_front() {
                    acc.push(f);
                } else {
                    break;
                }
            }
        }

        if acc.len() < STREAM_CHUNK {
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        let chunk: Vec<StereoFrame> = acc.drain(..STREAM_CHUNK).collect();
        let params = shared
            .params
            .lock()
            .map_err(|_| SpatialError::LockPoisoned)?
            .clone();
        let mode = shared.mode.load();
        let mut wet: Vec<StereoFrame> = if mode == 0 {
            chunk
        } else {
            let array = shared
                .array
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();
            if array.enabled() {
                streamer.process_chunk_array(&chunk, &params, &array)?.to_vec()
            } else {
                streamer.process_chunk(&chunk, &params)?.to_vec()
            }
        };
        let eq_db = shared
            .eq_db
            .lock()
            .map(|g| *g)
            .unwrap_or([0.0; crate::eq::EQ_BANDS]);
        eq.set_gains(capture_sr, eq_db);
        eq.process_frames(&mut wet);
        shared
            .live_az_bits
            .store(streamer.effective_mid_azimuth_deg(&params).to_bits(), Ordering::Relaxed);
        shared
            .live_el_bits
            .store(streamer.smooth_elevation_deg().to_bits(), Ordering::Relaxed);
        // Same contract as RealtimePlayer: HRTF at content/capture rate, cubic to device.
        let out = if capture_sr == device_sr {
            wet
        } else {
            resample_cubic(&wet, capture_sr, device_sr)
        };
        if let Ok(mut q) = shared.wet_q.lock() {
            q.extend(out);
            trim_front(&mut q, WET_Q_MAX);
        }
    }
    Ok(())
}

static LIVE: Mutex<Option<Arc<LiveTransferEngine>>> = Mutex::new(None);

pub fn global_live() -> Result<std::sync::MutexGuard<'static, Option<Arc<LiveTransferEngine>>>, SpatialError> {
    LIVE.lock().map_err(|_| SpatialError::LockPoisoned)
}

pub fn ensure_live() -> Result<(), SpatialError> {
    let mut g = global_live()?;
    if g.is_none() {
        *g = Some(Arc::new(LiveTransferEngine::new()));
    }
    Ok(())
}

/// Clone the engine Arc so blocking `start` / `stop` do not hold LIVE.
pub fn live_engine() -> Result<Arc<LiveTransferEngine>, SpatialError> {
    global_live()?
        .as_ref()
        .cloned()
        .ok_or_else(|| SpatialError::NotImplemented("live missing".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;
    use std::time::{Duration, Instant};

    #[test]
    fn start_attempts_are_main_then_exclude_self_without_children() {
        let attempts = start_capture_attempts(4242, 99);
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0].0, 4242);
        assert!(attempts[0].1);
        assert_eq!(attempts[0].2, MAIN_ENERGY_WAIT);
        assert_eq!(attempts[1].0, 99);
        assert!(!attempts[1].1);
        assert_eq!(attempts[1].2, EXCLUDE_SELF_ENERGY_WAIT);
        assert!(MAIN_ENERGY_WAIT <= Duration::from_millis(250));
        assert!(EXCLUDE_SELF_ENERGY_WAIT <= Duration::from_millis(200));
    }

    #[test]
    fn start_attempts_skip_exclude_self_when_pid_is_self() {
        let attempts = start_capture_attempts(7, 7);
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].0, 7);
        assert!(attempts[0].1);
    }

    #[test]
    fn wait_for_energy_returns_immediately_when_present() {
        let eng = LiveTransferEngine::new();
        eng.shared
            .frames_with_energy
            .store(512, Ordering::Relaxed);
        let t = Instant::now();
        assert!(eng.wait_for_energy(Duration::from_millis(200)));
        assert!(t.elapsed() < Duration::from_millis(40));
    }

    #[test]
    fn wait_for_energy_false_without_pcm() {
        let eng = LiveTransferEngine::new();
        let t = Instant::now();
        assert!(!eng.wait_for_energy(Duration::from_millis(12)));
        assert!(t.elapsed() < Duration::from_millis(80));
    }

    #[test]
    fn live_queue_caps_are_a_few_chunks() {
        assert!((2..=4).contains(&LIVE_DRY_Q_CHUNKS));
        assert!((2..=4).contains(&LIVE_WET_Q_CHUNKS));
        let sr = 48_000usize;
        let dry_ms = DRY_Q_MAX * 1000 / sr;
        let wet_ms = WET_Q_MAX * 1000 / sr;
        assert!(dry_ms <= 80, "dry cap {dry_ms} ms");
        assert!(wet_ms <= 80, "wet cap {wet_ms} ms");
        assert!(dry_ms + wet_ms < 300);
    }

    #[test]
    fn small_output_buffer_is_about_10ms() {
        assert_eq!(target_output_frames(48_000), 480);
        assert!(target_output_frames(44_100) >= 256);
    }

    #[test]
    fn trim_front_drops_oldest() {
        let mut q: VecDeque<StereoFrame> = (0..8).map(|i| (i as f32, 0.0)).collect();
        trim_front(&mut q, 3);
        assert_eq!(q.len(), 3);
        assert_eq!(q[0], (5.0, 0.0));
    }

    #[test]
    fn output_hold_survives_start_stop_inner_and_clears_queues() {
        let eng = LiveTransferEngine::new();
        if let Ok(mut d) = eng.shared.dry_q.lock() {
            d.push_back((0.2, 0.1));
        }
        eng.set_output_hold(true);
        assert!(eng.shared.out_hold.load(Ordering::Relaxed));
        assert!(eng.shared.dry_q.lock().map(|d| d.is_empty()).unwrap_or(false));
        // start() stop_inner must not drop Dart's pin-before-wet hold.
        let keep = eng.shared.out_hold.load(Ordering::Relaxed);
        eng.stop_inner();
        eng.shared.out_hold.store(keep, Ordering::Relaxed);
        assert!(eng.shared.out_hold.load(Ordering::Relaxed));
        eng.stop();
        assert!(!eng.shared.out_hold.load(Ordering::Relaxed));
    }

    #[test]
    fn resample_live_matches_file_player_duration() {
        let capture_sr = 48_000u32;
        let device_sr = 44_100u32;
        let chunk: Vec<StereoFrame> = (0..STREAM_CHUNK)
            .map(|i| {
                let s = (i as f32 * 0.01).sin() * 0.2;
                (s, s)
            })
            .collect();
        let out = resample_cubic(&chunk, capture_sr, device_sr);
        let in_secs = STREAM_CHUNK as f64 / capture_sr as f64;
        let out_secs = out.len() as f64 / device_sr as f64;
        assert!(
            (out_secs - in_secs).abs() < 0.002,
            "clock gap: in {in_secs:.4}s out {out_secs:.4}s"
        );
    }

    #[test]
    fn empty_preferred_follows_default_device_name_changes() {
        assert!(should_follow_default_device_change(
            "",
            "Speakers (Realtek)",
            "Headphones (WH-1000XM5)",
        ));
        assert!(should_follow_default_device_change(
            "  ",
            "Speakers (Nahimic Audio)",
            "Speakers (Realtek)",
        ));
    }

    #[test]
    fn named_preferred_does_not_chase_windows_default() {
        assert!(!should_follow_default_device_change(
            "Headphones (WH-1000XM5)",
            "Headphones (WH-1000XM5)",
            "Speakers (Realtek)",
        ));
    }

    #[test]
    fn default_follow_ignores_empty_or_identical_names() {
        assert!(!should_follow_default_device_change("", "", "Speakers"));
        assert!(!should_follow_default_device_change("", "Speakers", ""));
        assert!(!should_follow_default_device_change(
            "",
            "Speakers (Realtek)",
            "Speakers (Realtek)",
        ));
    }
}
