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
