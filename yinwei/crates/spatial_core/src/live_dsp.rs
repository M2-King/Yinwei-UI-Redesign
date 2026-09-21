//! Platform-neutral realtime DSP: existing [`HrtfStreamer`] + graphic EQ.
//!
//! Windows Live Transfer and Android A2 share this processor so there is
//! still **one** HRTF implementation (`hrtf_render.rs`). Capture and output
//! backends stay platform-specific.

use crate::decode::StereoFrame;
use crate::eq::{clamp_eq_gains, GraphicEq, EQ_BANDS};
use crate::error::SpatialError;
use crate::hrtf_render::{HrtfStreamer, STREAM_CHUNK};
use crate::layout::ArrayLayout;
use crate::params::{PlaybackMode, SpatialParams};

pub struct LiveDspProcessor {
    sample_rate: u32,
    streamer: HrtfStreamer,
    eq: GraphicEq,
    params: SpatialParams,
    mode: PlaybackMode,
    eq_db: [f32; EQ_BANDS],
    array: ArrayLayout,
}

impl LiveDspProcessor {
    pub fn new(sample_rate: u32) -> Result<Self, SpatialError> {
        let sample_rate = sample_rate.max(1);
        let mut streamer = HrtfStreamer::new(sample_rate)?;
        let params = SpatialParams::default();
        streamer.snap_to_params(&params);
        Ok(Self {
            sample_rate,
            streamer,
            eq: GraphicEq::new(sample_rate),
            params,
            mode: PlaybackMode::Spatial,
            eq_db: [0.0; EQ_BANDS],
            array: ArrayLayout::default(),
        })
    }

    #[allow(dead_code)]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn set_params(&mut self, params: SpatialParams) -> Result<(), SpatialError> {
        params.validate()?;
        self.params = params;
        Ok(())
    }

    /// Align smoothed HRTF pose to the current params (DSP start).
    pub fn snap_to_current_params(&mut self) {
        self.streamer.snap_to_params(&self.params);
    }

    pub fn params(&self) -> &SpatialParams {
        &self.params
    }

    pub fn set_mode(&mut self, mode: PlaybackMode) {
        self.mode = mode;
    }

    pub fn mode(&self) -> PlaybackMode {
        self.mode
    }

    pub fn set_eq(&mut self, gains: [f32; EQ_BANDS]) {
        self.eq_db = clamp_eq_gains(gains);
    }

    pub fn set_array(&mut self, array: ArrayLayout) {
        self.array = array;
    }

    pub fn effective_azimuth_deg(&self) -> f32 {
        self.streamer.effective_mid_azimuth_deg(&self.params)
    }

    pub fn effective_elevation_deg(&self) -> f32 {
        self.streamer.smooth_elevation_deg()
    }

    /// Process one [`STREAM_CHUNK`] of dry stereo. Shorter input is zero-padded
    /// by [`HrtfStreamer`]. Wet PCM is returned; Android A2 discards it after
    /// measuring RMS/peak.
    pub fn process_chunk(
        &mut self,
        input: &[StereoFrame],
    ) -> Result<[StereoFrame; STREAM_CHUNK], SpatialError> {
        let mut wet: [StereoFrame; STREAM_CHUNK] = match self.mode {
            PlaybackMode::Original => {
                let mut out = [(0.0f32, 0.0f32); STREAM_CHUNK];
                let n = input.len().min(STREAM_CHUNK);
                out[..n].copy_from_slice(&input[..n]);
                out
            }
            PlaybackMode::Spatial => {
                if self.array.enabled() {
                    self.streamer
                        .process_chunk_array(input, &self.params, &self.array)?
                } else {
                    self.streamer.process_chunk(input, &self.params)?
                }
            }
        };
        self.eq.set_gains(self.sample_rate, self.eq_db);
        self.eq.process_frames(&mut wet);
        Ok(wet)
    }
}

/// RMS and peak of interleaved stereo, linear 0…1.
pub fn stereo_rms_peak(frames: &[StereoFrame]) -> (f32, f32) {
    if frames.is_empty() {
        return (0.0, 0.0);
    }
    let mut sum_sq = 0.0f32;
    let mut peak = 0.0f32;
    for (l, r) in frames {
        let la = l.abs();
        let ra = r.abs();
        peak = peak.max(la).max(ra);
        sum_sq += l * l + r * r;
    }
    let n = (frames.len() * 2) as f32;
    ((sum_sq / n).sqrt(), peak)
}

pub fn linear_to_db(linear: f32) -> f32 {
    if !linear.is_finite() || linear <= 1e-12 {
        f32::NEG_INFINITY
    } else {
        20.0 * linear.log10()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::params::MotionMode;

    fn sine_chunk(sr: u32, amp: f32) -> Vec<StereoFrame> {
        (0..STREAM_CHUNK)
            .map(|i| {
                let t = i as f32 / sr as f32;
                let s = (t * 440.0 * std::f32::consts::TAU).sin() * amp;
                (s, s)
            })
            .collect()
    }

    #[test]
    fn default_params_are_valid() {
        let p = LiveDspProcessor::new(48_000).unwrap();
        p.params().validate().unwrap();
        assert_eq!(p.mode(), PlaybackMode::Spatial);
        assert!((p.effective_azimuth_deg() - 90.0).abs() < 1.0);
    }

    #[test]
    fn set_params_rejects_invalid_and_keeps_previous() {
        let mut p = LiveDspProcessor::new(48_000).unwrap();
        let before = p.params().azimuth_deg;
        let mut bad = SpatialParams::default();
        bad.azimuth_deg = 400.0;
        assert!(p.set_params(bad).is_err());
        assert_eq!(p.params().azimuth_deg, before);
    }

    #[test]
    fn spatial_chunk_is_finite_and_non_silent() {
        let mut p = LiveDspProcessor::new(48_000).unwrap();
        let dry = sine_chunk(48_000, 0.35);
        let wet = p.process_chunk(&dry).unwrap();
        let (rms, peak) = stereo_rms_peak(&wet);
        assert!(rms.is_finite() && rms > 1e-4, "wet rms={rms}");
        assert!(peak.is_finite() && peak > 1e-4, "wet peak={peak}");
        let rms_db = linear_to_db(rms);
        let peak_db = linear_to_db(peak);
        assert!(rms_db.is_finite(), "wet rms dB={rms_db}");
        assert!(peak_db.is_finite(), "wet peak dB={peak_db}");
    }

    #[test]
    fn original_mode_copies_dry_before_eq() {
        let mut p = LiveDspProcessor::new(48_000).unwrap();
        p.set_mode(PlaybackMode::Original);
        let dry = sine_chunk(48_000, 0.2);
        let wet = p.process_chunk(&dry).unwrap();
        for i in 0..STREAM_CHUNK {
            assert!((wet[i].0 - dry[i].0).abs() < 1e-6);
            assert!((wet[i].1 - dry[i].1).abs() < 1e-6);
        }
    }

    #[test]
    fn params_can_change_without_recreating_processor() {
        let mut p = LiveDspProcessor::new(48_000).unwrap();
        let mut next = SpatialParams::default();
        next.azimuth_deg = -90.0;
        next.elevation_deg = 20.0;
        next.motion = MotionMode::Fixed;
        p.set_params(next).unwrap();
        let _ = p.process_chunk(&sine_chunk(48_000, 0.2)).unwrap();
        assert!((p.params().azimuth_deg + 90.0).abs() < f32::EPSILON);
        assert!(p.effective_elevation_deg().is_finite());
    }
}
