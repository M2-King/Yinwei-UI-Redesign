//! Mid / Side encode-decode helpers.

use crate::decode::StereoFrame;

#[inline]
pub fn encode_ms(left: f32, right: f32) -> (f32, f32) {
    let mid = (left + right) * 0.5;
    let side = (left - right) * 0.5;
    (mid, side)
}

#[inline]
#[allow(dead_code)]
pub fn decode_ms(mid: f32, side: f32) -> StereoFrame {
    (mid + side, mid - side)
}

/// Split a stereo buffer into Mid and Side mono streams.
pub fn split_buffers(frames: &[StereoFrame]) -> (Vec<f32>, Vec<f32>) {
    let mut mid = Vec::with_capacity(frames.len());
    let mut side = Vec::with_capacity(frames.len());
    for &(l, r) in frames {
        let (m, s) = encode_ms(l, r);
        mid.push(m);
        side.push(s);
    }
    (mid, side)
}
