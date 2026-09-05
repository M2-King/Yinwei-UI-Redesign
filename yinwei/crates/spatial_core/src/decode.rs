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
            &FormatOptions {
                enable_gapless: true,
                ..Default::default()
            },
            &MetadataOptions::default(),
        )
        .map_err(|e| SpatialError::Decode(e.to_string()))?;

    let mut format = probed.format;

    // MP4/MOV/M4A often list a video track first — pick the first *audio* track.
    let track = select_audio_track(format.as_ref())?;
    let track_id = track.id;

    // Codec params can be incomplete for AAC-in-MP4 until the first frame is decoded.
    // Prefer rate/channels from the decoded AudioBuffer spec once available.
    let mut src_rate = track.codec_params.sample_rate;
    let mut src_channels = track
        .codec_params
        .channels
        .map(|c| c.count())
        .unwrap_or(0);

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| {
            SpatialError::Decode(format!(
                "unsupported audio codec in container ({e}) — try WAV/MP3/AAC"
            ))
        })?;

    let mut interleaved = Vec::new();
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

        // Skip video / other packets in the container.
        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                // Trust decoded stream metadata over container hints.
                src_rate = Some(spec.rate);
                src_channels = spec.channels.count().max(1);

                // SampleBuffer::capacity() is in *samples*, AudioBuffer::capacity() is in *frames*.
                // Comparing them directly prevented growth → truncated AAC packets → chipmunk/fast audio.
                let need_samples = decoded.capacity() * src_channels;
                let recreate = sample_buf
                    .as_ref()
                    .map(|b| b.capacity() < need_samples)
                    .unwrap_or(true);
                if recreate {
                    sample_buf = Some(SampleBuffer::new(decoded.capacity() as u64, spec));
                }

                if let Some(buf) = sample_buf.as_mut() {
                    buf.copy_interleaved_ref(decoded);
                    interleaved.extend_from_slice(buf.samples());
                }
            }
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(e) => return Err(SpatialError::Decode(e.to_string())),
        }
    }

    if interleaved.is_empty() {
        return Err(SpatialError::Decode(
            "no audio samples decoded — file may be video-only or DRM-protected".into(),
        ));
    }

    let sample_rate = src_rate.ok_or_else(|| {
        SpatialError::Decode("could not determine audio sample rate from stream".into())
    })?;
    let channels = src_channels.max(1);

    let stereo = to_stereo(&interleaved, channels);
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

    let (title, artist, album) = read_metadata(&mut format, &stem);

    Ok(DecodedAudio {
        sample_rate: TARGET_RATE,
        frames,
        title,
        artist,
        album,
    })
}

/// Prefer a real audio track inside containers (MP4/MOV/etc.).
fn select_audio_track(
    format: &dyn symphonia::core::formats::FormatReader,
) -> Result<symphonia::core::formats::Track, SpatialError> {
    // Prefer tracks that look like PCM/compressed audio (have sample_rate).
    let audio = format.tracks().iter().find(|t| {
        t.codec_params.codec != CODEC_TYPE_NULL
            && t.codec_params.sample_rate.is_some()
            && t.codec_params.channels.is_some()
    });

    if let Some(t) = audio {
        return Ok(t.clone());
    }

    // Fallback: any non-null codec with a sample rate (some AAC omit channels early).
    if let Some(t) = format.tracks().iter().find(|t| {
        t.codec_params.codec != CODEC_TYPE_NULL && t.codec_params.sample_rate.is_some()
    }) {
        return Ok(t.clone());
    }

    Err(SpatialError::Decode(
        "no audio track found — open a file that contains an audio stream (MP4/MOV with sound, or WAV/MP3)"
            .into(),
    ))
}

fn read_metadata(
    format: &mut Box<dyn symphonia::core::formats::FormatReader>,
    fallback_title: &str,
) -> (String, String, String) {
    let mut title = fallback_title.to_string();
    let mut artist = String::new();
    let mut album = String::new();

    // Pull metadata revision if present.
    format.metadata().skip_to_latest();
    if let Some(meta) = format.metadata().current() {
        for tag in meta.tags() {
            let val = tag.value.to_string();
            if val.is_empty() {
                continue;
            }
            match tag.std_key {
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) => title = val,
                Some(symphonia::core::meta::StandardTagKey::Artist)
                | Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => {
                    if artist.is_empty() {
                        artist = val;
                    }
                }
                Some(symphonia::core::meta::StandardTagKey::Album) => album = val,
                _ => {}
            }
        }
    }

    (title, artist, album)
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
    use std::path::Path;

    #[test]
    fn writes_and_loads_wav() {
        let path = std::env::temp_dir().join("yinwei_roundtrip.wav");
        write_test_sine_wav(&path, 0.1, 440.0).unwrap();
        let decoded = load_audio(&path).unwrap();
        assert!(decoded.frames.len() > 100);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn extracts_audio_from_mp4_container() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/test_clip.mp4");
        assert!(path.exists(), "missing test fixture {:?}", path);
        let decoded = load_audio(&path).expect("mp4 audio extract");
        // Fixture is ~0.4s mono AAC @ 44.1k → ~17640 stereo frames after upmix.
        let secs = decoded.frames.len() as f64 / decoded.sample_rate as f64;
        assert!(
            (0.30..=0.55).contains(&secs),
            "expected ~0.4s, got {secs:.3}s ({} frames) — mono-as-stereo would be ~0.2s",
            decoded.frames.len()
        );
    }

    #[test]
    fn mp4_48k_stereo_duration_is_sane() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/test_clip_48k_stereo.mp4");
        if !path.exists() {
            eprintln!("skip missing fixture {:?}", path);
            return;
        }
        let d = load_audio(&path).expect("decode 48k mp4");
        let secs = d.frames.len() as f64 / d.sample_rate as f64;
        assert!(
            (0.90..=1.15).contains(&secs),
            "expected ~1s, got {secs:.3}s"
        );
    }

    #[test]
    fn mp4_mono_aac_is_not_halved() {
        // Regression: treating mono AAC as stereo halves duration and sounds like chipmunk/电子音.
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/test_clip.mp4");
        let d = load_audio(&path).expect("decode mono mp4");
        let secs = d.frames.len() as f64 / d.sample_rate as f64;
        assert!(
            secs > 0.30,
            "mono misread as stereo → ~2x speed; got {secs:.3}s"
        );
    }
}
