//! Stable C ABI for Flutter `dart:ffi` (P2.4).
//!
//! Mirrors `frb_api` / `PlayerSession` so Windows can link `spatial_core.dll`
//! without running `flutter_rust_bridge_codegen` in CI.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::sync::Mutex;

use crate::error::SpatialError;
use crate::params::{MotionMode, PlaybackMode, SpatialParams, TrackInfo};
use crate::presets::PositionPreset;
use crate::session::global_session;

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static LAST_TRACK: Mutex<Option<TrackInfo>> = Mutex::new(None);

const OK: i32 = 0;
const E_FILE: i32 = 1;
const E_NO_TRACK: i32 = 2;
const E_PARAM: i32 = 3;
const E_DECODE: i32 = 4;
const E_DEVICE: i32 = 5;
const E_IO: i32 = 6;
const E_OTHER: i32 = 7;

fn set_err(msg: impl Into<String>) {
    if let Ok(mut e) = LAST_ERROR.lock() {
        *e = msg.into();
    }
}

fn map_err(e: SpatialError) -> i32 {
    set_err(e.to_string());
    match e {
        SpatialError::FileNotFound(_) => E_FILE,
        SpatialError::NoTrackLoaded => E_NO_TRACK,
        SpatialError::InvalidParam(_) => E_PARAM,
        SpatialError::Decode(_) => E_DECODE,
        SpatialError::AudioDevice(_) => E_DEVICE,
        SpatialError::Io(_) => E_IO,
        _ => E_OTHER,
    }
}

fn cstr_to_str<'a>(p: *const c_char) -> Result<&'a str, i32> {
    if p.is_null() {
        set_err("null string");
        return Err(E_PARAM);
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| {
            set_err("invalid utf-8");
            E_PARAM
        })
}

fn write_cstr(src: &str, out: *mut c_char, cap: usize) -> i32 {
    if out.is_null() || cap == 0 {
        set_err("null out buffer");
        return E_PARAM;
    }
    let c = match CString::new(src.replace('\0', "")) {
        Ok(c) => c,
        Err(_) => {
            set_err("string contains NUL");
            return E_OTHER;
        }
    };
    let bytes = c.as_bytes_with_nul();
    if bytes.len() > cap {
        set_err("buffer too small");
        return E_PARAM;
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, bytes.len());
    }
    OK
}

fn preset_from_i32(v: i32) -> Option<PositionPreset> {
    Some(match v {
        0 => PositionPreset::Front,
        1 => PositionPreset::LeftFront,
        2 => PositionPreset::RightFront,
        3 => PositionPreset::Left,
        4 => PositionPreset::Right,
        5 => PositionPreset::LeftRear,
        6 => PositionPreset::RightRear,
        7 => PositionPreset::Back,
        8 => PositionPreset::Overhead,
        _ => return None,
    })
}

fn preset_to_i32(p: Option<PositionPreset>) -> i32 {
    match p {
        None => -1,
        Some(PositionPreset::Front) => 0,
        Some(PositionPreset::LeftFront) => 1,
        Some(PositionPreset::RightFront) => 2,
        Some(PositionPreset::Left) => 3,
        Some(PositionPreset::Right) => 4,
        Some(PositionPreset::LeftRear) => 5,
        Some(PositionPreset::RightRear) => 6,
        Some(PositionPreset::Back) => 7,
        Some(PositionPreset::Overhead) => 8,
    }
}

/// C layout for params in/out.
#[repr(C)]
pub struct YinweiParamsC {
    pub azimuth_deg: f32,
    pub elevation_deg: f32,
    pub distance_m: f32,
    /// 0 = fixed, 1 = orbit
    pub motion: i32,
    pub orbit_hz: f32,
    pub envelopment: f32,
    pub reverb_mix: f32,
    /// -1 = none, 0..8 = PositionPreset
    pub preset: i32,
}

fn params_from_c(p: &YinweiParamsC) -> Result<SpatialParams, i32> {
    let motion = match p.motion {
        0 => MotionMode::Fixed,
        1 => MotionMode::Orbit,
        _ => {
            set_err("bad motion");
            return Err(E_PARAM);
        }
    };
    Ok(SpatialParams {
        azimuth_deg: p.azimuth_deg,
        elevation_deg: p.elevation_deg,
        distance_m: p.distance_m,
        motion,
        orbit_hz: p.orbit_hz,
        envelopment: p.envelopment,
        reverb_mix: p.reverb_mix,
        selected_preset: preset_from_i32(p.preset),
    })
}

fn params_to_c(p: &SpatialParams) -> YinweiParamsC {
    YinweiParamsC {
        azimuth_deg: p.azimuth_deg,
        elevation_deg: p.elevation_deg,
        distance_m: p.distance_m,
        motion: match p.motion {
            MotionMode::Fixed => 0,
            MotionMode::Orbit => 1,
        },
        orbit_hz: p.orbit_hz,
        envelopment: p.envelopment,
        reverb_mix: p.reverb_mix,
        preset: preset_to_i32(p.selected_preset),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_last_error(out: *mut c_char, cap: usize) -> i32 {
    let msg = LAST_ERROR.lock().map(|e| e.clone()).unwrap_or_default();
    write_cstr(&msg, out, cap)
}

#[no_mangle]
pub extern "C" fn yinwei_open(path: *const c_char) -> i32 {
    let path = match cstr_to_str(path) {
        Ok(s) => s,
        Err(c) => return c,
    };
    match global_session().and_then(|s| s.open(path)) {
        Ok(meta) => {
            if let Ok(mut t) = LAST_TRACK.lock() {
                *t = Some(meta);
            }
            OK
        }
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_track_title(out: *mut c_char, cap: usize) -> i32 {
    match LAST_TRACK.lock() {
        Ok(t) => match &*t {
            Some(m) => write_cstr(&m.title, out, cap),
            None => {
                set_err("no track");
                E_NO_TRACK
            }
        },
        Err(_) => {
            set_err("lock");
            E_OTHER
        }
    }
}

#[no_mangle]
pub extern "C" fn yinwei_track_artist(out: *mut c_char, cap: usize) -> i32 {
    match LAST_TRACK.lock() {
        Ok(t) => match &*t {
            Some(m) => write_cstr(&m.artist, out, cap),
            None => {
                set_err("no track");
                E_NO_TRACK
            }
        },
        Err(_) => {
            set_err("lock");
            E_OTHER
        }
    }
}

#[no_mangle]
pub extern "C" fn yinwei_track_album(out: *mut c_char, cap: usize) -> i32 {
    match LAST_TRACK.lock() {
        Ok(t) => match &*t {
            Some(m) => write_cstr(&m.album, out, cap),
            None => {
                set_err("no track");
                E_NO_TRACK
            }
        },
        Err(_) => {
            set_err("lock");
            E_OTHER
        }
    }
}

#[no_mangle]
pub extern "C" fn yinwei_track_path(out: *mut c_char, cap: usize) -> i32 {
    match LAST_TRACK.lock() {
        Ok(t) => match &*t {
            Some(m) => write_cstr(&m.path, out, cap),
            None => {
                set_err("no track");
                E_NO_TRACK
            }
        },
        Err(_) => {
            set_err("lock");
            E_OTHER
        }
    }
}

#[no_mangle]
pub extern "C" fn yinwei_track_duration_ms() -> u64 {
    LAST_TRACK
        .lock()
        .ok()
        .and_then(|t| t.as_ref().map(|m| m.duration_ms))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn yinwei_track_sample_rate() -> u32 {
    LAST_TRACK
        .lock()
        .ok()
        .and_then(|t| t.as_ref().map(|m| m.sample_rate))
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn yinwei_set_params(p: *const YinweiParamsC) -> i32 {
    if p.is_null() {
        set_err("null params");
        return E_PARAM;
    }
    let params = match params_from_c(unsafe { &*p }) {
        Ok(v) => v,
        Err(c) => return c,
    };
    match global_session().and_then(|s| s.set_params(params)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_set_eq(
    bass: f32,
    f120: f32,
    f400: f32,
    f1k: f32,
    f35: f32,
    f10k: f32,
) -> i32 {
    let gains = [bass, f120, f400, f1k, f35, f10k];
    match global_session().and_then(|s| s.set_eq(gains)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_set_array(mode: i32) -> i32 {
    match global_session().and_then(|s| s.set_array(mode)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_set_speaker(
    index: i32,
    az_deg: f32,
    el_deg: f32,
    dist_m: f32,
    gain_db: f32,
    mute: i32,
    feed: i32,
) -> i32 {
    match global_session().and_then(|s| {
        s.set_speaker(index, az_deg, el_deg, dist_m, gain_db, mute, feed)
    }) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_set_speaker_count(n: i32) -> i32 {
    match global_session().and_then(|s| s.set_speaker_count(n)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn yinwei_get_params(out: *mut YinweiParamsC) -> i32 {
    if out.is_null() {
        set_err("null out");
        return E_PARAM;
    }
    match global_session().and_then(|s| s.params()) {
        Ok(p) => {
            unsafe { *out = params_to_c(&p) };
            OK
        }
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn yinwei_apply_preset(preset: i32, out: *mut YinweiParamsC) -> i32 {
    let Some(pr) = preset_from_i32(preset) else {
        set_err("bad preset");
        return E_PARAM;
    };
    match global_session().and_then(|s| s.apply_preset(pr)) {
        Ok(p) => {
            if !out.is_null() {
                unsafe { *out = params_to_c(&p) };
            }
            OK
        }
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_set_mode(mode: i32) -> i32 {
    let m = match mode {
        0 => PlaybackMode::Original,
        1 => PlaybackMode::Spatial,
        _ => {
            set_err("bad mode");
            return E_PARAM;
        }
    };
    match global_session().and_then(|s| s.set_mode(m)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_rebuild_preview() -> i32 {
    match global_session().and_then(|s| s.rebuild_preview(None)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_play() -> i32 {
    match global_session().and_then(|s| s.play()) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_pause() -> i32 {
    match global_session().and_then(|s| {
        s.pause();
        Ok(())
    }) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_seek_ms(ms: u64) -> i32 {
    match global_session().and_then(|s| s.seek_ms(ms)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_position_ms() -> u64 {
    global_session()
        .map(|s| s.position_ms())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn yinwei_is_playing() -> i32 {
    global_session()
        .map(|s| if s.is_playing() { 1 } else { 0 })
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn yinwei_current_azimuth_deg() -> f32 {
    global_session()
        .and_then(|s| s.current_azimuth_deg())
        .unwrap_or(0.0)
}

#[no_mangle]
pub extern "C" fn yinwei_current_elevation_deg() -> f32 {
    global_session()
        .and_then(|s| s.current_elevation_deg())
        .unwrap_or(0.0)
}

#[no_mangle]
pub extern "C" fn yinwei_export_wav(path: *const c_char) -> i32 {
    let path = match cstr_to_str(path) {
        Ok(s) => s,
        Err(c) => return c,
    };
    match global_session().and_then(|s| s.export_wav(path, None)) {
        Ok(()) => OK,
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_dispose() -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        if let Ok(g) = global_live() {
            let eng = g.clone();
            drop(g);
            if let Some(eng) = eng {
                eng.stop();
            }
        }
    }
    match global_session().and_then(|s| s.dispose()) {
        Ok(()) => {
            if let Ok(mut t) = LAST_TRACK.lock() {
                *t = None;
            }
            OK
        }
        Err(e) => map_err(e),
    }
}

#[no_mangle]
pub extern "C" fn yinwei_is_preview_dirty() -> i32 {
    global_session()
        .map(|s| if s.is_preview_dirty() { 1 } else { 0 })
        .unwrap_or(1)
}

/// Start WASAPI process-loopback → HRTF live transfer.
/// `process_id` must be >0. pid 0 (whole-device loopback) is rejected.
#[no_mangle]
pub extern "C" fn yinwei_live_start(process_id: u32) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, live_engine};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        let _ = global_session().map(|s| {
            s.pause();
        });
        // Clone the engine Arc so the process-wide LIVE mutex is not held
        // during the energy wait (UI isolate / routing FFI must stay free).
        match live_engine().and_then(|eng| {
            // Keep live Spatial defaults — do NOT copy file-session Original mode.
            eng.set_mode(PlaybackMode::Spatial);
            eng.start(process_id)
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = process_id;
        set_err("live transfer is Windows-only");
        E_OTHER
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_stop() -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        match global_live() {
            Ok(g) => {
                let eng = g.clone();
                drop(g);
                if let Some(eng) = eng {
                    eng.stop();
                }
                OK
            }
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_is_running() -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| if e.is_running() { 1 } else { 0 }))
            .unwrap_or(0)
    }
    #[cfg(not(windows))]
    {
        0
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_mode(mode: i32) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        let m = match mode {
            0 => PlaybackMode::Original,
            1 => PlaybackMode::Spatial,
            _ => {
                set_err("mode must be 0|1");
                return E_PARAM;
            }
        };
        match global_live() {
            Ok(mut g) => {
                if let Some(eng) = g.as_mut() {
                    eng.set_mode(m);
                }
                OK
            }
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = mode;
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_azimuth_deg() -> f32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.current_azimuth_deg()))
            .unwrap_or(0.0)
    }
    #[cfg(not(windows))]
    {
        0.0
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_elevation_deg() -> f32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.current_elevation_deg()))
            .unwrap_or(0.0)
    }
    #[cfg(not(windows))]
    {
        0.0
    }
}

/// Frames captured since last start (for health checks).
#[no_mangle]
pub extern "C" fn yinwei_live_captured_frames() -> u64 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.frames_captured()))
            .unwrap_or(0)
    }
    #[cfg(not(windows))]
    {
        0
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_params(
    azimuth_deg: f32,
    elevation_deg: f32,
    distance_m: f32,
    motion: i32,
    orbit_hz: f32,
    envelopment: f32,
    reverb_mix: f32,
    selected_preset: i32,
) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        let motion = match motion {
            0 => MotionMode::Fixed,
            1 => MotionMode::Orbit,
            _ => {
                set_err("motion must be 0|1");
                return E_PARAM;
            }
        };
        let params = SpatialParams {
            azimuth_deg,
            elevation_deg,
            distance_m,
            motion,
            orbit_hz,
            envelopment,
            reverb_mix,
            selected_preset: preset_from_i32(selected_preset),
        };
        match global_live().and_then(|mut g| {
            if let Some(eng) = g.as_mut() {
                eng.set_params(params)?;
            }
            Ok(())
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (
            azimuth_deg,
            elevation_deg,
            distance_m,
            motion,
            orbit_hz,
            envelopment,
            reverb_mix,
            selected_preset,
        );
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_eq(
    bass: f32,
    f120: f32,
    f400: f32,
    f1k: f32,
    f35: f32,
    f10k: f32,
) -> i32 {
    let gains = [bass, f120, f400, f1k, f35, f10k];
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match global_live().and_then(|mut g| {
            if let Some(eng) = g.as_mut() {
                eng.set_eq(gains)?;
            }
            Ok(())
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = gains;
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_array(mode: i32) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match global_live().and_then(|mut g| {
            if let Some(eng) = g.as_mut() {
                eng.set_array(mode)?;
            }
            Ok(())
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = mode;
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_speaker(
    index: i32,
    az_deg: f32,
    el_deg: f32,
    dist_m: f32,
    gain_db: f32,
    mute: i32,
    feed: i32,
) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match global_live().and_then(|mut g| {
            if let Some(eng) = g.as_mut() {
                eng.set_speaker(index, az_deg, el_deg, dist_m, gain_db, mute, feed)?;
            }
            Ok(())
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (index, az_deg, el_deg, dist_m, gain_db, mute, feed);
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_speaker_count(n: i32) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match global_live().and_then(|mut g| {
            if let Some(eng) = g.as_mut() {
                eng.set_speaker_count(n)?;
            }
            Ok(())
        }) {
            Ok(()) => OK,
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = n;
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_energy_frames() -> u64 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.frames_with_energy()))
            .unwrap_or(0)
    }
    #[cfg(not(windows))]
    {
        0
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_last_energy_ms() -> u64 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.last_energy_ms()))
            .unwrap_or(0)
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// Newline-separated output device names (wet cpal path). Empty name = default.
#[no_mangle]
pub extern "C" fn yinwei_live_list_output_devices(out: *mut c_char, cap: usize) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::list_output_device_names;
        let joined = list_output_device_names().join("\n");
        write_cstr(&joined, out, cap)
    }
    #[cfg(not(windows))]
    {
        write_cstr("", out, cap)
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_set_output_device(name: *const c_char) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, global_live};
        let s = match cstr_to_str(name) {
            Ok(s) => s,
            Err(c) => return c,
        };
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match global_live() {
            Ok(mut g) => {
                if let Some(eng) = g.as_mut() {
                    eng.set_output_device_name(s);
                }
                OK
            }
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = name;
        OK
    }
}

#[no_mangle]
pub extern "C" fn yinwei_live_output_device(out: *mut c_char, cap: usize) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::global_live;
        let name = global_live()
            .ok()
            .and_then(|g| g.as_ref().map(|e| e.output_device_name()))
            .unwrap_or_default();
        write_cstr(&name, out, cap)
    }
    #[cfg(not(windows))]
    {
        write_cstr("", out, cap)
    }
}

/// 1 = hold wet silent (pin-before-wet); 0 = play. Survives live_start restart.
#[no_mangle]
pub extern "C" fn yinwei_live_set_output_hold(hold: i32) -> i32 {
    #[cfg(windows)]
    {
        use crate::live_transfer::{ensure_live, live_engine};
        if let Err(e) = ensure_live() {
            return map_err(e);
        }
        match live_engine() {
            Ok(eng) => {
                eng.set_output_hold(hold != 0);
                OK
            }
            Err(e) => map_err(e),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = hold;
        OK
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::write_test_sine_wav;
    use std::ffi::CString;

    #[test]
    fn ffi_open_rebuild_export() {
        let dir = std::env::temp_dir().join(format!("yinwei_ffi_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = dir.join("in.wav");
        let output = dir.join("out.wav");
        write_test_sine_wav(&input, 0.3, 440.0).unwrap();

        let in_c = CString::new(input.to_str().unwrap()).unwrap();
        let out_c = CString::new(output.to_str().unwrap()).unwrap();
        assert_eq!(yinwei_open(in_c.as_ptr()), OK);
        assert!(yinwei_track_duration_ms() >= 250);
        assert_eq!(unsafe { yinwei_apply_preset(5, ptr::null_mut()) }, OK); // LeftRear
        assert_eq!(yinwei_set_mode(1), OK);
        assert_eq!(yinwei_rebuild_preview(), OK);
        assert_eq!(yinwei_export_wav(out_c.as_ptr()), OK);
        assert!(output.metadata().unwrap().len() > 400);
        assert_eq!(yinwei_dispose(), OK);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
