//! Opus for the laptop's Listen stream: a small C ABI over libopus (built
//! from source by `audiopus_sys`), called from Dart FFI
//! (`lib/remote/opus_output_source.dart`). It only compresses the stereo the
//! engine has already rendered; no engine, HRTF or DSP code lives here.
//!
//! The decoder is exported for round-trip tests only; the iPad decodes with
//! Apple's own Opus decoder (AudioToolbox).

use audiopus_sys as ffi;
use std::os::raw::c_void;

const APPLICATION_AUDIO: i32 = 2049;
const SET_BITRATE: i32 = 4002;
const SET_VBR: i32 = 4006;
const SET_COMPLEXITY: i32 = 4010;
const SET_VBR_CONSTRAINT: i32 = 4020;
const SET_SIGNAL: i32 = 4024;
const GET_LOOKAHEAD: i32 = 4027;
const SIGNAL_MUSIC: i32 = 3002;
const RESET_STATE: i32 = 4028;

/// ABI version Dart checks before use.
#[no_mangle]
pub extern "C" fn yinwei_opus_version() -> u32 {
    1
}

/// A 48 kHz stereo music encoder at `bitrate` bits/s (64000..=510000);
/// null on failure.
#[no_mangle]
pub extern "C" fn yinwei_opus_encoder_new(bitrate: i32) -> *mut c_void {
    let mut error = 0;
    let enc = unsafe { ffi::opus_encoder_create(48_000, 2, APPLICATION_AUDIO, &mut error) };
    if enc.is_null() || error != 0 {
        return std::ptr::null_mut();
    }
    unsafe {
        // Full quality: the laptop has CPU to spare (about 1-2% of a core).
        ffi::opus_encoder_ctl(enc, SET_COMPLEXITY, 10);
        ffi::opus_encoder_ctl(enc, SET_SIGNAL, SIGNAL_MUSIC);
        // Constrained VBR: steadier packet sizes on a bumpy link.
        ffi::opus_encoder_ctl(enc, SET_VBR, 1);
        ffi::opus_encoder_ctl(enc, SET_VBR_CONSTRAINT, 1);
    }
    let enc = enc as *mut c_void;
    if yinwei_opus_encoder_set_bitrate(enc, bitrate) != 0 {
        yinwei_opus_encoder_free(enc);
        return std::ptr::null_mut();
    }
    enc
}

/// 0 on success.
#[no_mangle]
pub extern "C" fn yinwei_opus_encoder_set_bitrate(enc: *mut c_void, bitrate: i32) -> i32 {
    if enc.is_null() || !(64_000..=510_000).contains(&bitrate) {
        return -1;
    }
    unsafe { ffi::opus_encoder_ctl(enc as *mut ffi::OpusEncoder, SET_BITRATE, bitrate) }
}

/// Samples of delay the encoder adds (its lookahead).
#[no_mangle]
pub extern "C" fn yinwei_opus_encoder_lookahead(enc: *mut c_void) -> i32 {
    if enc.is_null() {
        return -1;
    }
    let mut value = 0i32;
    let status = unsafe {
        ffi::opus_encoder_ctl(enc as *mut ffi::OpusEncoder, GET_LOOKAHEAD, &mut value as *mut i32)
    };
    if status == 0 { value } else { -1 }
}

/// Encodes `frames` interleaved stereo f32 frames (120, 240, 480, 960, 1920
/// or 2880) into `out`; returns the packet's byte count, or < 0 on error.
#[no_mangle]
pub extern "C" fn yinwei_opus_encode(
    enc: *mut c_void,
    pcm: *const f32,
    frames: u32,
    out: *mut u8,
    capacity: u32,
) -> i32 {
    if enc.is_null() || pcm.is_null() || out.is_null() || !matches!(frames, 120 | 240 | 480 | 960 | 1920 | 2880) {
        return -1;
    }
    unsafe {
        ffi::opus_encode_float(
            enc as *mut ffi::OpusEncoder,
            pcm,
            frames as i32,
            out,
            capacity.min(i32::MAX as u32) as i32,
        )
    }
}

/// Forgets the previous audio (a new stream after a seek or source change).
#[no_mangle]
pub extern "C" fn yinwei_opus_encoder_reset(enc: *mut c_void) -> i32 {
    if enc.is_null() {
        return -1;
    }
    unsafe { ffi::opus_encoder_ctl(enc as *mut ffi::OpusEncoder, RESET_STATE) }
}

#[no_mangle]
pub extern "C" fn yinwei_opus_encoder_free(enc: *mut c_void) {
    if !enc.is_null() {
        unsafe { ffi::opus_encoder_destroy(enc as *mut ffi::OpusEncoder) }
    }
}

/// Test only: a 48 kHz stereo decoder.
#[no_mangle]
pub extern "C" fn yinwei_opus_decoder_new() -> *mut c_void {
    let mut error = 0;
    let dec = unsafe { ffi::opus_decoder_create(48_000, 2, &mut error) };
    if dec.is_null() || error != 0 { std::ptr::null_mut() } else { dec as *mut c_void }
}

/// Test only: decodes one packet into interleaved stereo f32; returns frames.
#[no_mangle]
pub extern "C" fn yinwei_opus_decode(
    dec: *mut c_void,
    data: *const u8,
    len: u32,
    pcm: *mut f32,
    max_frames: u32,
) -> i32 {
    if dec.is_null() || data.is_null() || pcm.is_null() {
        return -1;
    }
    unsafe { ffi::opus_decode_float(dec as *mut ffi::OpusDecoder, data, len as i32, pcm, max_frames as i32, 0) }
}

#[no_mangle]
pub extern "C" fn yinwei_opus_decoder_free(dec: *mut c_void) {
    if !dec.is_null() {
        unsafe { ffi::opus_decoder_destroy(dec as *mut ffi::OpusDecoder) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic music-like test signal: two tones per channel plus a
    /// slow sweep, also used to make the iPad decoder's test fixture.
    pub fn signal(frames: usize) -> Vec<f32> {
        let mut out = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            let t = i as f32 / 48_000.0;
            let sweep = (2.0 * std::f32::consts::PI * (200.0 * t + 400.0 * t * t)).sin();
            let l = 0.3 * (2.0 * std::f32::consts::PI * 440.0 * t).sin() + 0.15 * sweep;
            let r = 0.3 * (2.0 * std::f32::consts::PI * 660.0 * t).sin() + 0.15 * sweep;
            out.push(l);
            out.push(r);
        }
        out
    }

    fn snr_db(reference: &[f32], decoded: &[f32], lag: usize) -> f64 {
        let (mut s, mut n) = (0f64, 0f64);
        for i in (48_000 * 2)..(reference.len() - 48_000) {
            let r = reference[i] as f64;
            let d = decoded[i + lag * 2] as f64;
            s += r * r;
            n += (r - d) * (r - d);
        }
        10.0 * (s / n.max(1e-20)).log10()
    }

    fn round_trip(bitrate: i32) -> (f64, usize, i32) {
        let enc = yinwei_opus_encoder_new(bitrate);
        let dec = yinwei_opus_decoder_new();
        assert!(!enc.is_null() && !dec.is_null());
        let lookahead = yinwei_opus_encoder_lookahead(enc);
        let input = signal(48_000 * 4);
        let mut decoded = Vec::new();
        let mut bytes = 0usize;
        let mut out = [0u8; 1500];
        let mut pcm = vec![0f32; 960 * 2];
        for chunk in input.chunks(960 * 2) {
            let n = yinwei_opus_encode(enc, chunk.as_ptr(), 960, out.as_mut_ptr(), out.len() as u32);
            assert!(n > 0, "encode failed: {n}");
            bytes += n as usize;
            let frames = yinwei_opus_decode(dec, out.as_ptr(), n as u32, pcm.as_mut_ptr(), 960);
            assert_eq!(frames, 960);
            decoded.extend_from_slice(&pcm);
        }
        yinwei_opus_encoder_free(enc);
        yinwei_opus_decoder_free(dec);
        (snr_db(&input, &decoded, lookahead as usize), bytes, lookahead)
    }

    #[test]
    fn high_quality_round_trip() {
        for bitrate in [320_000, 510_000] {
            let (snr, bytes, lookahead) = round_trip(bitrate);
            let kbps = bytes as f64 * 8.0 / 4.0 / 1000.0;
            eprintln!("{bitrate}: SNR {snr:.1} dB, {kbps:.0} kbit/s, lookahead {lookahead}");
            assert!(snr > 25.0, "SNR too low at {bitrate}: {snr}");
            assert!(kbps < bitrate as f64 / 1000.0 * 1.15, "bitrate overshoot {kbps}");
        }
    }

    #[test]
    fn rejects_bad_input() {
        assert!(yinwei_opus_encoder_new(1_000).is_null());
        let enc = yinwei_opus_encoder_new(320_000);
        let pcm = vec![0f32; 1024];
        let mut out = [0u8; 1500];
        assert_eq!(yinwei_opus_encode(enc, pcm.as_ptr(), 512, out.as_mut_ptr(), 1500), -1);
        assert_eq!(yinwei_opus_encoder_set_bitrate(enc, 600_000), -1);
        assert_eq!(yinwei_opus_encoder_reset(enc), 0);
        yinwei_opus_encoder_free(enc);
    }

    /// Writes the iPad decoder test fixture (YINWEI_OPUS_FIXTURE=path):
    /// [u32 count] then per packet [u16 len][bytes], 1 s of `signal` at 320 kbit/s.
    #[test]
    fn write_fixture() {
        let Ok(path) = std::env::var("YINWEI_OPUS_FIXTURE") else { return };
        let enc = yinwei_opus_encoder_new(320_000);
        let input = signal(48_000);
        let mut file = Vec::new();
        file.extend_from_slice(&50u32.to_le_bytes());
        let mut out = [0u8; 1500];
        for chunk in input.chunks(960 * 2) {
            let n = yinwei_opus_encode(enc, chunk.as_ptr(), 960, out.as_mut_ptr(), 1500);
            assert!(n > 0);
            file.extend_from_slice(&(n as u16).to_le_bytes());
            file.extend_from_slice(&out[..n as usize]);
        }
        yinwei_opus_encoder_free(enc);
        std::fs::write(path, file).unwrap();
    }
}
