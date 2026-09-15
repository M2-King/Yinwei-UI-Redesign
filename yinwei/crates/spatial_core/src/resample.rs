//! Stereo resamplers for decode/playback rate conversion.

use crate::decode::StereoFrame;

/// Hermite cubic interpolation — much less dull/aliased than linear for
/// 44.1↔48 kHz conversion (common Windows WASAPI path).
pub fn resample_cubic(input: &[StereoFrame], from: u32, to: u32) -> Vec<StereoFrame> {
    if input.is_empty() || from == 0 || to == 0 || from == to {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let out_len = ((input.len() as f64) * (to as f64 / from as f64))
        .round()
        .max(1.0) as usize;
    let n = input.len();
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let i1 = src.floor() as isize;
        let t = (src - i1 as f64) as f32;
        let i0 = (i1 - 1).clamp(0, (n - 1) as isize) as usize;
        let i1u = i1.clamp(0, (n - 1) as isize) as usize;
        let i2 = (i1 + 1).clamp(0, (n - 1) as isize) as usize;
        let i3 = (i1 + 2).clamp(0, (n - 1) as isize) as usize;
        out.push((
            hermite(input[i0].0, input[i1u].0, input[i2].0, input[i3].0, t),
            hermite(input[i0].1, input[i1u].1, input[i2].1, input[i3].1, t),
        ));
    }
    out
}

#[inline]
fn hermite(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) -> f32 {
    let c0 = y1;
    let c1 = 0.5 * (y2 - y0);
    let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    ((c3 * t + c2) * t + c1) * t + c0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resample_48k_to_44k_preserves_approx_duration() {
        let sr_in = 48_000u32;
        let sr_out = 44_100u32;
        let secs = 1.0f64;
        let input: Vec<StereoFrame> = (0..(sr_in as f64 * secs) as usize)
            .map(|i| {
                let t = i as f32 / sr_in as f32;
                let s = (t * 440.0 * std::f32::consts::TAU).sin() * 0.2;
                (s, s)
            })
            .collect();
        let out = resample_cubic(&input, sr_in, sr_out);
        let out_secs = out.len() as f64 / sr_out as f64;
        assert!(
            (out_secs - secs).abs() < 0.01,
            "got {out_secs:.4}s from {secs}s"
        );
    }
}
