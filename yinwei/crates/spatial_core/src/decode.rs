use std::fs::File;
use std::path::Path;

use hound::{SampleFormat, WavSpec, WavWriter};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::error::SpatialError;

const TARGET_RATE: u32 = 44_100;

/// Interleaved stereo frames as (left, right).
pub type StereoFrame = (f32, f32);

#[derive(Debug, Clone)]
pub struct DecodedAudio {
    pub sample_rate: u32,
    pub frames: Vec<StereoFrame>,
    pub title: String,
    pub artist: String,
    pub album: String,
}

pub fn load_audio(path: &Path) -> Result<DecodedAudio, SpatialError> {
    let file = File::open(path).map_err(|e| SpatialError::Io(e.to_string()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| SpatialError::Decode(e.to_string()))?;

    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| SpatialError::Decode("no audio track".into()))?
        .clone();

    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| SpatialError::Decode("missing sample rate".into()))?;
    let channels = track
        .codec_params
        .channels
        .map(|c| c.count())
        .unwrap_or(2);

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| SpatialError::Decode(e.to_string()))?;

    let mut mono_or_interleaved = Vec::new();
    let mut sample_buf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymphoniaError::ResetRequired) => {
                decoder.reset();
                continue;
            }
            Err(SymphoniaError::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(SymphoniaError::IoError(_)) => break,
            Err(e) => return Err(SpatialError::Decode(e.to_string())),
        };

        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                if sample_buf.is_none() {
                    let spec = *decoded.spec();
                    let duration = decoded.capacity() as u64;
                    sample_buf = Some(SampleBuffer::new(duration, spec));
                }
                if let Some(buf) = sample_buf.as_mut() {
                    buf.copy_interleaved_ref(decoded);
                    mono_or_interleaved.extend_from_slice(buf.samples());
                }
            }
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(e) => return Err(SpatialError::Decode(e.to_string())),
        }
    }

    let stereo = to_stereo(&mono_or_interleaved, channels);
    let frames = if sample_rate == TARGET_RATE {
        stereo
    } else {
        resample_linear(&stereo, sample_rate, TARGET_RATE)
    };

    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Untitled")
        .to_string();

    Ok(DecodedAudio {
        sample_rate: TARGET_RATE,
        frames,
        title: stem,
        artist: String::new(),
        album: String::new(),
    })
}

fn to_stereo(samples: &[f32], channels: usize) -> Vec<StereoFrame> {
    match channels {
        0 | 1 => samples.iter().map(|&s| (s, s)).collect(),
        2 => samples
            .chunks_exact(2)
            .map(|c| (c[0], c[1]))
            .collect(),
        n => samples
            .chunks(n)
            .map(|c| (c[0], c.get(1).copied().unwrap_or(c[0])))
            .collect(),
    }
}

/// Lightweight linear resampler (good enough for MVP; rubato later).
fn resample_linear(input: &[StereoFrame], from: u32, to: u32) -> Vec<StereoFrame> {
    if input.is_empty() || from == to {
        return input.to_vec();
    }
    let ratio = to as f64 / from as f64;
    let out_len = ((input.len() as f64) * ratio).round().max(1.0) as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 / ratio;
        let i0 = src.floor() as usize;
        let i1 = (i0 + 1).min(input.len() - 1);
        let t = (src - i0 as f64) as f32;
        let (l0, r0) = input[i0];
        let (l1, r1) = input[i1];
        out.push((l0 + (l1 - l0) * t, r0 + (r1 - r0) * t));
    }
    out
}

pub fn save_wav(path: &Path, frames: &[StereoFrame], sample_rate: u32) -> Result<(), SpatialError> {
    let spec = WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };
    let mut writer =
        WavWriter::create(path, spec).map_err(|e| SpatialError::Io(e.to_string()))?;
    for &(l, r) in frames {
        let ls = (l.clamp(-1.0, 1.0) * 32767.0) as i16;
        let rs = (r.clamp(-1.0, 1.0) * 32767.0) as i16;
        writer
            .write_sample(ls)
            .map_err(|e| SpatialError::Io(e.to_string()))?;
        writer
            .write_sample(rs)
            .map_err(|e| SpatialError::Io(e.to_string()))?;
    }
    writer
        .finalize()
        .map_err(|e| SpatialError::Io(e.to_string()))?;
    Ok(())
}

/// Build a short sine WAV for unit tests / CLI smoke.
pub fn write_test_sine_wav(path: &Path, seconds: f32, hz: f32) -> Result<(), SpatialError> {
    let sr = TARGET_RATE;
    let n = (seconds * sr as f32) as usize;
    let mut frames = Vec::with_capacity(n);
    for i in 0..n {
        let t = i as f32 / sr as f32;
        let s = (t * hz * std::f32::consts::TAU).sin() * 0.35;
        frames.push((s, s * 0.7));
    }
    save_wav(path, &frames, sr)
}

#[cfg(test)]
mod decode_tests {
    use super::*;

    #[test]
    fn writes_and_loads_wav() {
        let path = std::env::temp_dir().join("yinwei_roundtrip.wav");
        write_test_sine_wav(&path, 0.1, 440.0).unwrap();
        let decoded = load_audio(&path).unwrap();
        assert!(decoded.frames.len() > 100);
        let _ = std::fs::remove_file(path);
    }
}