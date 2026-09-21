//! Portable PCM sanitization and interleaved → stereo conversion.
//!
//! Capture backends (WASAPI, AudioPlaybackCapture) may differ. This layer
//! does not implement HRTF; it only produces [`StereoFrame`]s for the shared
//! DSP path.

use crate::decode::StereoFrame;
use crate::error::SpatialError;

/// PCM_FLOAT: replace NaN/Inf with 0, then clamp to [-1, 1].
pub fn sanitize_f32(sample: f32) -> f32 {
    if sample.is_finite() {
        sample.clamp(-1.0, 1.0)
    } else {
        0.0
    }
}

/// PCM_16BIT → float in [-1, 1]. Uses 32768.0 so i16::MIN does not exceed -1.
pub fn pcm16_to_f32(sample: i16) -> f32 {
    sanitize_f32(sample as f32 / 32768.0)
}

/// Convert interleaved PCM_FLOAT to stereo frames.
///
/// - 1 channel: duplicate mono → L=R
/// - 2 channels: L R L R …
/// - >2 channels: use the first L/R pair of each frame (do not scramble later
///   channels into L/R). Caller should surface this as a diagnostic.
pub fn frames_from_interleaved_f32(
    samples: &[f32],
    channels: u32,
) -> Result<Vec<StereoFrame>, SpatialError> {
    frames_from_iter(
        samples.iter().copied().map(sanitize_f32),
        channels,
        samples.len(),
    )
}

/// Convert interleaved PCM_16BIT to stereo frames. Same channel policy as float.
pub fn frames_from_interleaved_i16(
    samples: &[i16],
    channels: u32,
) -> Result<Vec<StereoFrame>, SpatialError> {
    frames_from_iter(
        samples.iter().copied().map(pcm16_to_f32),
        channels,
        samples.len(),
    )
}

fn frames_from_iter<I>(
    samples: I,
    channels: u32,
    sample_count: usize,
) -> Result<Vec<StereoFrame>, SpatialError>
where
    I: IntoIterator<Item = f32>,
{
    let ch = channels as usize;
    if ch == 0 {
        return Err(SpatialError::InvalidParam(
            "channelCount must be >= 1".into(),
        ));
    }
    let frames_n = sample_count / ch;
    let mut out = Vec::with_capacity(frames_n);
    let mut iter = samples.into_iter();
    for _ in 0..frames_n {
        let left = iter.next().unwrap_or(0.0);
        let right = if ch == 1 {
            left
        } else {
            iter.next().unwrap_or(0.0)
        };
        // Skip remaining channels in this frame so a 6ch buffer cannot
        // mis-assign C/LFE/surround into stereo L/R.
        for _ in 2..ch {
            let _ = iter.next();
        }
        out.push((left, right));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interleaved_stereo_float_becomes_stereo_frames() {
        let samples = [0.25f32, -0.5, 0.75, 1.0];
        let frames = frames_from_interleaved_f32(&samples, 2).unwrap();
        assert_eq!(frames, vec![(0.25, -0.5), (0.75, 1.0)]);
    }

    #[test]
    fn pcm16_converts_by_dividing_32768() {
        let samples = [32767i16, -16384, 0, 32767];
        let frames = frames_from_interleaved_i16(&samples, 2).unwrap();
        assert!((frames[0].0 - 32767.0 / 32768.0).abs() < 1e-6);
        assert!((frames[0].1 - (-16384.0 / 32768.0)).abs() < 1e-6);
        assert_eq!(frames[1], (0.0, 32767.0 / 32768.0));
    }

    #[test]
    fn i16_min_clamps_to_minus_one() {
        assert!((pcm16_to_f32(i16::MIN) + 1.0).abs() < 1e-6);
    }

    #[test]
    fn mono_is_duplicated_to_stereo() {
        let samples = [0.3f32, -0.2, 0.1];
        let frames = frames_from_interleaved_f32(&samples, 1).unwrap();
        assert_eq!(frames, vec![(0.3, 0.3), (-0.2, -0.2), (0.1, 0.1)]);
    }

    #[test]
    fn nan_and_infinity_become_zero_then_clamp() {
        let samples = [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 2.5, -4.0];
        let frames = frames_from_interleaved_f32(&samples, 1).unwrap();
        assert_eq!(frames[0], (0.0, 0.0));
        assert_eq!(frames[1], (0.0, 0.0));
        assert_eq!(frames[2], (0.0, 0.0));
        assert_eq!(frames[3], (1.0, 1.0));
        assert_eq!(frames[4], (-1.0, -1.0));
    }

    #[test]
    fn more_than_two_channels_uses_first_lr_pair() {
        // L R C LFE — C/LFE must not become a stereo frame of their own
        // interleaved as L=C R=LFE.
        let samples = [
            0.1f32, 0.2, 0.9, 0.8, // frame 0
            -0.3, -0.4, 0.7, 0.6, // frame 1
        ];
        let frames = frames_from_interleaved_f32(&samples, 4).unwrap();
        assert_eq!(frames, vec![(0.1, 0.2), (-0.3, -0.4)]);
    }

    #[test]
    fn leftover_partial_frame_is_dropped() {
        let samples = [0.1f32, 0.2, 0.3];
        let frames = frames_from_interleaved_f32(&samples, 2).unwrap();
        assert_eq!(frames, vec![(0.1, 0.2)]);
    }

    #[test]
    fn zero_channels_is_an_error() {
        assert!(matches!(
            frames_from_interleaved_f32(&[0.1], 0),
            Err(SpatialError::InvalidParam(_))
        ));
    }
}
