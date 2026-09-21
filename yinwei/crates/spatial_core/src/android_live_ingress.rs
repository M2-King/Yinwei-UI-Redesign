//! Android JNI glue for [`crate::live_ingress`].
//!
//! Raw PCM stays on the Kotlin capture thread → JNI → bounded Rust queue.
//! It does **not** go Kotlin → MethodChannel → Dart → FFI.

#![cfg(target_os = "android")]

use jni::objects::{JClass, JFloatArray, JShortArray};
use jni::sys::{jdouble, jint, jlong, jstring};
use jni::JNIEnv;

use crate::live_ingress::{
    session_push_f32, session_push_i16, session_set_mode, session_set_params, session_snapshot,
    session_start, session_stop,
};
use crate::params::{MotionMode, PlaybackMode, SpatialParams};

pub const JNI_OK: jint = 0;
pub const JNI_ERR_INVALID: jint = -2;
pub const JNI_ERR_NOT_STARTED: jint = -3;
pub const JNI_ERR_FAILED: jint = -4;

fn err_code(err: &crate::error::SpatialError) -> jint {
    match err {
        crate::error::SpatialError::InvalidParam(_) => JNI_ERR_INVALID,
        crate::error::SpatialError::NotImplemented(_) => JNI_ERR_NOT_STARTED,
        _ => JNI_ERR_FAILED,
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeStart(
    _env: JNIEnv,
    _class: JClass,
    sample_rate: jint,
    channel_count: jint,
) -> jint {
    if sample_rate <= 0 || channel_count <= 0 {
        return JNI_ERR_INVALID;
    }
    match session_start(sample_rate as u32, channel_count as u32) {
        Ok(()) => JNI_OK,
        Err(e) => err_code(&e),
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeStop(
    _env: JNIEnv,
    _class: JClass,
) -> jint {
    match session_stop() {
        Ok(()) => JNI_OK,
        Err(e) => err_code(&e),
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativePushFloat(
    mut env: JNIEnv,
    _class: JClass,
    samples: JFloatArray,
    count: jint,
) -> jint {
    if count < 0 {
        return JNI_ERR_INVALID;
    }
    if count == 0 {
        return JNI_OK;
    }
    let len = match env.get_array_length(&samples) {
        Ok(n) => n,
        Err(_) => return JNI_ERR_INVALID,
    };
    if count > len {
        return JNI_ERR_INVALID;
    }
    let mut buf = vec![0.0f32; count as usize];
    if env.get_float_array_region(&samples, 0, &mut buf).is_err() {
        return JNI_ERR_FAILED;
    }
    match session_push_f32(&buf) {
        Ok(_) => JNI_OK,
        Err(e) => err_code(&e),
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativePushPcm16(
    mut env: JNIEnv,
    _class: JClass,
    samples: JShortArray,
    count: jint,
) -> jint {
    if count < 0 {
        return JNI_ERR_INVALID;
    }
    if count == 0 {
        return JNI_OK;
    }
    let len = match env.get_array_length(&samples) {
        Ok(n) => n,
        Err(_) => return JNI_ERR_INVALID,
    };
    if count > len {
        return JNI_ERR_INVALID;
    }
    let mut buf = vec![0i16; count as usize];
    if env.get_short_array_region(&samples, 0, &mut buf).is_err() {
        return JNI_ERR_FAILED;
    }
    match session_push_i16(&buf) {
        Ok(_) => JNI_OK,
        Err(e) => err_code(&e),
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeSetParams(
    _env: JNIEnv,
    _class: JClass,
    azimuth_deg: jdouble,
    elevation_deg: jdouble,
    distance_m: jdouble,
    motion: jint,
    mode: jint,
) -> jint {
    let mut params = SpatialParams::default();
    params.azimuth_deg = azimuth_deg as f32;
    params.elevation_deg = elevation_deg as f32;
    params.distance_m = distance_m as f32;
    params.motion = if motion == 1 {
        MotionMode::Orbit
    } else {
        MotionMode::Fixed
    };
    if session_set_params(params).is_err() {
        return JNI_ERR_INVALID;
    }
    let playback = if mode == 0 {
        PlaybackMode::Original
    } else {
        PlaybackMode::Spatial
    };
    match session_set_mode(playback) {
        Ok(()) => JNI_OK,
        Err(e) => err_code(&e),
    }
}

fn snapshot_string(env: &mut JNIEnv, s: &str) -> jstring {
    env.new_string(s)
        .map(|js| js.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeDspState<
    'local,
>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
) -> jstring {
    snapshot_string(&mut env, session_snapshot().state.as_str())
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeLastError<
    'local,
>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
) -> jstring {
    let snap = session_snapshot();
    snapshot_string(&mut env, snap.last_error.as_deref().unwrap_or(""))
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeInputFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().input_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeConsumedFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().consumed_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeDspChunks(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().dsp_chunks as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeWetFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().wet_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeDroppedFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().dropped_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeOverruns(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().overruns as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeQueueDepthFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().queue_depth_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeQueueHighWaterFrames(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    session_snapshot().queue_high_water_frames as jlong
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeWetRmsDb(
    _env: JNIEnv,
    _class: JClass,
) -> jdouble {
    session_snapshot().wet_rms_db as jdouble
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeWetPeakDb(
    _env: JNIEnv,
    _class: JClass,
) -> jdouble {
    session_snapshot().wet_peak_db as jdouble
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeEffectiveAzimuthDeg(
    _env: JNIEnv,
    _class: JClass,
) -> jdouble {
    session_snapshot().effective_azimuth_deg as jdouble
}

#[no_mangle]
pub extern "system" fn Java_dev_yinwei_yinwei_player_YinweiSpatialCoreBridge_nativeEffectiveElevationDeg(
    _env: JNIEnv,
    _class: JClass,
) -> jdouble {
    session_snapshot().effective_elevation_deg as jdouble
}
