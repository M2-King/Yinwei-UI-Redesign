//! 6-band headphone-style graphic EQ (Clear Bass shelf + 5 peaking bands).
//!
//! Applied on the stereo output the user hears (after Spatial / Original),
//! not on WASAPI capture and not inside the HRTF split.

use biquad::{Biquad, Coefficients, DirectForm2Transposed, ToHertz, Type};

use crate::decode::StereoFrame;

pub const EQ_BANDS: usize = 6;
/// Clear Bass (low shelf) then 120 / 400 / 1k / 3.5k / 10k peaking.
pub const EQ_FREQ_HZ: [f32; EQ_BANDS] = [80.0, 120.0, 400.0, 1000.0, 3500.0, 10_000.0];

const GAIN_MIN: f32 = -12.0;
const GAIN_MAX: f32 = 12.0;

pub fn clamp_eq_gains(gains: [f32; EQ_BANDS]) -> [f32; EQ_BANDS] {
    let mut out = [0.0f32; EQ_BANDS];
    for i in 0..EQ_BANDS {
        out[i] = gains[i].clamp(GAIN_MIN, GAIN_MAX);
        if !out[i].is_finite() {
            out[i] = 0.0;
        }
    }
    out
}

pub fn eq_is_flat(gains: [f32; EQ_BANDS]) -> bool {
    gains.iter().all(|g| g.abs() < 0.05)
}

struct StereoBiquad {
    l: DirectForm2Transposed<f32>,
    r: DirectForm2Transposed<f32>,
}

impl StereoBiquad {
    fn new(c: Coefficients<f32>) -> Self {
        Self {
            l: DirectForm2Transposed::<f32>::new(c),
            r: DirectForm2Transposed::<f32>::new(c),
        }
    }

    fn update(&mut self, c: Coefficients<f32>) {
        self.l.update_coefficients(c);
        self.r.update_coefficients(c);
    }

    fn tick(&mut self, l: f32, r: f32) -> (f32, f32) {
        (self.l.run(l), self.r.run(r))
    }
}

pub struct GraphicEq {
    sample_rate: u32,
    gains_db: [f32; EQ_BANDS],
    bands: [StereoBiquad; EQ_BANDS],
}

impl GraphicEq {
    pub fn new(sample_rate: u32) -> Self {
        let sr = sample_rate.max(1);
        let gains = [0.0f32; EQ_BANDS];
        let bands = build_bands(sr, gains);
        Self {
            sample_rate: sr,
            gains_db: gains,
            bands,
        }
    }

    pub fn set_gains(&mut self, sample_rate: u32, gains: [f32; EQ_BANDS]) {
        let sr = sample_rate.max(1);
        let gains = clamp_eq_gains(gains);
        let same = sr == self.sample_rate
            && self
                .gains_db
                .iter()
                .zip(gains.iter())
                .all(|(a, b)| (a - b).abs() < 1e-4);
        if same {
            return;
        }
        let coeffs = band_coeffs(sr, gains);
        for i in 0..EQ_BANDS {
            self.bands[i].update(coeffs[i]);
        }
        self.sample_rate = sr;
        self.gains_db = gains;
    }

    pub fn process_pair(&mut self, mut l: f32, mut r: f32) -> (f32, f32) {
        if eq_is_flat(self.gains_db) {
            return (l, r);
        }
        for b in &mut self.bands {
            let t = b.tick(l, r);
            l = t.0;
            r = t.1;
        }
        (l.clamp(-1.0, 1.0), r.clamp(-1.0, 1.0))
    }

    pub fn process_frames(&mut self, frames: &mut [StereoFrame]) {
        if eq_is_flat(self.gains_db) {
            return;
        }
        for f in frames {
            *f = self.process_pair(f.0, f.1);
        }
    }
}

fn nyquist_safe(sr: u32, hz: f32) -> f32 {
    let max = sr as f32 * 0.45;
    hz.clamp(20.0, max.max(21.0))
}

fn band_coeffs(sr: u32, gains: [f32; EQ_BANDS]) -> [Coefficients<f32>; EQ_BANDS] {
    let fs = sr as f32;
    let one = |i: usize| {
        let hz = nyquist_safe(sr, EQ_FREQ_HZ[i]).hz();
        let db = gains[i];
        let kind = if i == 0 {
            Type::LowShelf(db)
        } else {
            Type::PeakingEQ(db)
        };
        let q = if i == 0 { 0.707 } else { 1.1 };
        Coefficients::<f32>::from_params(kind, fs.hz(), hz, q).expect("eq biquad")
    };
    [one(0), one(1), one(2), one(3), one(4), one(5)]
}

fn build_bands(sr: u32, gains: [f32; EQ_BANDS]) -> [StereoBiquad; EQ_BANDS] {
    let c = band_coeffs(sr, gains);
    [
        StereoBiquad::new(c[0]),
        StereoBiquad::new(c[1]),
        StereoBiquad::new(c[2]),
        StereoBiquad::new(c[3]),
        StereoBiquad::new(c[4]),
        StereoBiquad::new(c[5]),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, sr: u32, n: usize) -> Vec<StereoFrame> {
        (0..n)
            .map(|i| {
                let x = (2.0 * std::f32::consts::PI * freq * i as f32 / sr as f32).sin() * 0.25;
                (x, x)
            })
            .collect()
    }

    fn rms(frames: &[StereoFrame]) -> f32 {
        let mut s = 0.0f32;
        for (l, r) in frames {
            s += l * l + r * r;
        }
        (s / (frames.len().max(1) as f32 * 2.0)).sqrt()
    }

    #[test]
    fn flat_eq_is_identity() {
        let mut eq = GraphicEq::new(48_000);
        eq.set_gains(48_000, [0.0; 6]);
        let src = sine(1000.0, 48_000, 2048);
        let mut out = src.clone();
        eq.process_frames(&mut out);
        for i in 256..src.len() {
            assert!((src[i].0 - out[i].0).abs() < 1e-6);
        }
    }

    #[test]
    fn vocal_presence_boost_lifts_1k_more_than_120hz() {
        let mut eq = GraphicEq::new(48_000);
        eq.set_gains(48_000, [-1.0, -2.0, -1.5, 2.5, 3.5, 1.5]);
        let mut mid = sine(1000.0, 48_000, 4096);
        let mut low = sine(120.0, 48_000, 4096);
        let mid0 = rms(&mid);
        let low0 = rms(&low);
        eq.process_frames(&mut mid);
        let mut eq2 = GraphicEq::new(48_000);
        eq2.set_gains(48_000, [-1.0, -2.0, -1.5, 2.5, 3.5, 1.5]);
        eq2.process_frames(&mut low);
        let mid_ratio = rms(&mid) / mid0;
        let low_ratio = rms(&low) / low0;
        assert!(
            mid_ratio > low_ratio,
            "1k ratio={mid_ratio} 120 ratio={low_ratio}"
        );
        assert!(mid_ratio > 1.05);
    }
}
