//! HRTF binaural renderer with Mid/Side placement.
//!
//! HRIR dataset: IRCAM `IRC_1002_C.bin` (via Artezon/8D-Audio-Converter-HRTF, MIT).

use std::f32::consts::TAU;
use std::io::Cursor;

use hrtf::{HrirSphere, HrtfContext, HrtfProcessor, Vec3};

use crate::crossover::LinkwitzRileyCrossover;
use crate::decode::StereoFrame;
use crate::error::SpatialError;
use crate::mid_side::split_buffers;
use crate::params::{MotionMode, SpatialParams};
use crate::reverb::ReverbProcessor;

const HRIR_BYTES: &[u8] = include_bytes!("../assets/IRC_1002_C.bin");
const BLOCK: usize = 512;
const INTERP_STEPS: usize = 8;
const CHUNK: usize = BLOCK * INTERP_STEPS; // 4096

fn normalize(v: Vec3) -> Vec3 {
    let len = (v.x * v.x + v.y * v.y + v.z * v.z).sqrt();
    if len > 1e-6 {
        Vec3::new(v.x / len, v.y / len, v.z / len)
    } else {
        Vec3::new(0.0, 0.0, 1.0)
    }
}

/// Azimuth 0° = front (−Z), +90° = right (+X), elevation + = up (+Y).
pub fn spherical_to_vec(azimuth_deg: f32, elevation_deg: f32) -> Vec3 {
    let az = azimuth_deg.to_radians();
    let el = elevation_deg.to_radians();
    let cos_el = el.cos();
    Vec3::new(az.sin() * cos_el, el.sin(), -az.cos() * cos_el)
}

fn distance_gain(distance: f32) -> f32 {
    // Gentler inverse-distance from a 1.5 m reference.
    // Far should not only sound "quieter" — pair with air LP + reverb below.
    let d = distance.clamp(0.5, 10.0);
    (1.5 / d).clamp(0.22, 1.25)
}

/// One-pole coefficient for air absorption (higher = brighter).
fn air_absorption_coeff(distance: f32) -> f32 {
    let t = ((distance - 0.5) / 9.5).clamp(0.0, 1.0);
    0.96 - 0.42 * t
}

/// Wet mix grows with distance so "far" feels more room / less dry proximity.
fn distance_reverb_mix(base: f32, distance: f32) -> f32 {
    let t = ((distance - 0.5) / 9.5).clamp(0.0, 1.0);
    (base * (0.3 + 1.05 * t) + 0.1 * t).clamp(0.0, 0.72)
}

struct OnePoleLp {
    z_l: f32,
    z_r: f32,
}

impl OnePoleLp {
    fn new() -> Self {
        Self { z_l: 0.0, z_r: 0.0 }
    }

    fn process(&mut self, l: f32, r: f32, coeff: f32) -> (f32, f32) {
        let c = coeff.clamp(0.05, 0.99);
        self.z_l += c * (l - self.z_l);
        self.z_r += c * (r - self.z_r);
        (self.z_l, self.z_r)
    }
}

pub struct HrtfRenderer {
    sample_rate: u32,
    processor: HrtfProcessor,
    crossover_mid: LinkwitzRileyCrossover,
    crossover_side: LinkwitzRileyCrossover,
    reverb: ReverbProcessor,
}

impl HrtfRenderer {
    pub fn new(sample_rate: u32) -> Result<Self, SpatialError> {
        let sphere = HrirSphere::new(Cursor::new(HRIR_BYTES), sample_rate)
            .map_err(|e| SpatialError::Hrtf(format!("{e:?}")))?;
        let processor = HrtfProcessor::new(sphere, INTERP_STEPS, BLOCK);
        Ok(Self {
            sample_rate,
            processor,
            crossover_mid: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            crossover_side: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            reverb: ReverbProcessor::new(sample_rate, 0.5, 0.5, 0.9),
        })
    }

    pub fn render(
        &mut self,
        input: &[StereoFrame],
        params: &SpatialParams,
        mut on_progress: Option<&mut dyn FnMut(f32)>,
    ) -> Result<Vec<StereoFrame>, SpatialError> {
        params.validate()?;
        self.crossover_mid.reset_state();
        self.crossover_side.reset_state();
        self.reverb.reset_state();

        let (mid, side) = split_buffers(input);
        let total = input.len();
        let mut output = vec![(0.0f32, 0.0f32); total];

        let mut prev_mid_l = Vec::new();
        let mut prev_mid_r = Vec::new();
        let mut prev_side_l = Vec::new();
        let mut prev_side_r = Vec::new();
        let mut prev_side2_l = Vec::new();
        let mut prev_side2_r = Vec::new();

        let mut prev_mid_pos = spherical_to_vec(params.azimuth_deg, params.elevation_deg);
        let mut prev_side_pos =
            spherical_to_vec(params.azimuth_deg + 110.0, params.elevation_deg * 0.5);
        let mut prev_side2_pos =
            spherical_to_vec(params.azimuth_deg - 110.0, params.elevation_deg * 0.5);
        let mut prev_dist = params.distance_m;
        let mut phase = 0.0f32;
        let mut air_lp = OnePoleLp::new();

        let num_chunks = (total + CHUNK - 1) / CHUNK;
        let dt = CHUNK as f32 / self.sample_rate as f32;

        for chunk_idx in 0..num_chunks {
            if let Some(cb) = on_progress.as_mut() {
                cb((chunk_idx as f32 / num_chunks.max(1) as f32).clamp(0.0, 1.0));
            }

            let start = chunk_idx * CHUNK;
            let end = (start + CHUNK).min(total);
            let len = end - start;

            if params.motion == MotionMode::Orbit {
                phase += dt * params.orbit_hz * TAU;
            }

            let orbit_offset = if params.motion == MotionMode::Orbit {
                phase.to_degrees()
            } else {
                0.0
            };

            // Fixed: Mid at selected 音位. Orbit: Mid holds base az, Side wraps around.
            let mid_az = params.azimuth_deg;
            let side_az = params.azimuth_deg + 120.0 + orbit_offset;

            let new_mid_pos = spherical_to_vec(mid_az, params.elevation_deg);
            let new_side_pos = spherical_to_vec(side_az, params.elevation_deg * 0.5);
            let new_dist = params.distance_m;
            let prev_g = distance_gain(prev_dist);
            let new_g = distance_gain(new_dist);
            let air_c = air_absorption_coeff(new_dist);
            let wet = distance_reverb_mix(params.reverb_mix, new_dist);

            let mut bass = vec![0.0f32; CHUNK];
            let mut mid_high = vec![0.0f32; CHUNK];
            let mut side_high = vec![0.0f32; CHUNK];

            let env = params.envelopment.clamp(0.0, 1.0);
            // Envelopment = surround wrap. Pure Side (L−R) is silent on mono /
            // hard-centered mixes, so also bleed Mid highs into the ambient path.
            for i in 0..len {
                let (b_m, h_m) = self.crossover_mid.process(mid[start + i]);
                let (b_s, h_s) = self.crossover_side.process(side[start + i]);
                bass[i] = b_m + b_s * 0.35;
                mid_high[i] = h_m * (1.0 - 0.28 * env);
                side_high[i] = (h_s + h_m * 0.55) * env;
            }

            let mut mid_out = vec![(0.0f32, 0.0f32); CHUNK];
            {
                let ctx = HrtfContext {
                    source: &mid_high,
                    output: &mut mid_out,
                    new_sample_vector: normalize(new_mid_pos),
                    prev_sample_vector: normalize(prev_mid_pos),
                    prev_left_samples: &mut prev_mid_l,
                    prev_right_samples: &mut prev_mid_r,
                    new_distance_gain: new_g,
                    prev_distance_gain: prev_g,
                };
                self.processor.process_samples(ctx);
            }

            let mut side_out = vec![(0.0f32, 0.0f32); CHUNK];
            if env > 0.01 {
                // Place ambient at ±110° around the focus so envelopment widens
                // the image instead of only boosting a silent Side channel.
                let el = params.elevation_deg * 0.4;
                let side_pos = if params.motion == MotionMode::Fixed {
                    spherical_to_vec(params.azimuth_deg + 110.0, el)
                } else {
                    new_side_pos
                };
                let side2_pos = if params.motion == MotionMode::Fixed {
                    spherical_to_vec(params.azimuth_deg - 110.0, el)
                } else {
                    spherical_to_vec(params.azimuth_deg - 120.0 + orbit_offset, params.elevation_deg * 0.5)
                };

                let mut side_a = vec![(0.0f32, 0.0f32); CHUNK];
                let mut side_b = vec![(0.0f32, 0.0f32); CHUNK];
                {
                    let ctx = HrtfContext {
                        source: &side_high,
                        output: &mut side_a,
                        new_sample_vector: normalize(side_pos),
                        prev_sample_vector: normalize(prev_side_pos),
                        prev_left_samples: &mut prev_side_l,
                        prev_right_samples: &mut prev_side_r,
                        new_distance_gain: new_g * 0.8,
                        prev_distance_gain: prev_g * 0.8,
                    };
                    self.processor.process_samples(ctx);
                }
                {
                    let ctx = HrtfContext {
                        source: &side_high,
                        output: &mut side_b,
                        new_sample_vector: normalize(side2_pos),
                        prev_sample_vector: normalize(prev_side2_pos),
                        prev_left_samples: &mut prev_side2_l,
                        prev_right_samples: &mut prev_side2_r,
                        new_distance_gain: new_g * 0.7,
                        prev_distance_gain: prev_g * 0.7,
                    };
                    self.processor.process_samples(ctx);
                }
                for i in 0..CHUNK {
                    let (a_l, a_r) = side_a[i];
                    let (b_l, b_r) = side_b[i];
                    side_out[i] = (a_l + b_l * 0.85, a_r + b_r * 0.85);
                }
                prev_side_pos = side_pos;
                prev_side2_pos = side2_pos;
            }

            // In Fixed mode, Mid should sit at the selected 音位 — already mid_az.
            // Optionally orbit Mid itself when Orbit mode:
            if params.motion == MotionMode::Orbit {
                // Re-render Mid with orbiting azimuth for stronger 8D motion of core content.
                let moving_mid = spherical_to_vec(
                    params.azimuth_deg + orbit_offset,
                    params.elevation_deg,
                );
                let mut mid_orbit_out = vec![(0.0f32, 0.0f32); CHUNK];
                let mut hist_l = prev_mid_l.clone();
                let mut hist_r = prev_mid_r.clone();
                {
                    let ctx = HrtfContext {
                        source: &mid_high,
                        output: &mut mid_orbit_out,
                        new_sample_vector: normalize(moving_mid),
                        prev_sample_vector: normalize(prev_mid_pos),
                        prev_left_samples: &mut hist_l,
                        prev_right_samples: &mut hist_r,
                        new_distance_gain: new_g,
                        prev_distance_gain: prev_g,
                    };
                    self.processor.process_samples(ctx);
                }
                mid_out = mid_orbit_out;
                prev_mid_l = hist_l;
                prev_mid_r = hist_r;
                prev_mid_pos = moving_mid;
            } else {
                prev_mid_pos = new_mid_pos;
            }

            for i in 0..len {
                let t = i as f32 / len.max(1) as f32;
                let g = prev_g + (new_g - prev_g) * t;
                let (ml, mr) = mid_out[i];
                let (sl, sr) = side_out[i];
                let left = ml + sl + bass[i] * g;
                let right = mr + sr + bass[i] * g;
                // Air absorption: high frequencies fall off with distance.
                let (dl, dr) = air_lp.process(left, right, air_c);
                let (rl, rr) = self.reverb.process(dl, dr);
                output[start + i] = (
                    dl * (1.0 - wet) + rl * wet,
                    dr * (1.0 - wet) + rr * wet,
                );
            }

            prev_dist = new_dist;
        }

        if let Some(cb) = on_progress.as_mut() {
            cb(1.0);
        }
        Ok(output)
    }
}

#[cfg(test)]
mod distance_tests {
    use super::*;

    #[test]
    fn farther_is_quieter_but_not_extreme() {
        let near = distance_gain(0.5);
        let mid = distance_gain(2.0);
        let far = distance_gain(8.0);
        assert!(near > mid && mid > far);
        assert!(far > 0.2);
        assert!(near < 1.3);
    }

    #[test]
    fn farther_has_more_reverb_and_darker_air() {
        assert!(air_absorption_coeff(0.5) > air_absorption_coeff(8.0));
        assert!(distance_reverb_mix(0.2, 8.0) > distance_reverb_mix(0.2, 0.5));
    }

    #[test]
    fn envelopment_changes_mono_render() {
        // Mono has Side=0; envelopment must still alter the binaural image.
        let sr = 44_100u32;
        let mut frames = Vec::with_capacity(sr as usize / 5);
        for i in 0..(sr / 5) {
            let t = i as f32 / sr as f32;
            let s = (t * 440.0 * std::f32::consts::TAU).sin() * 0.3;
            frames.push((s, s));
        }
        let mut dry_params = SpatialParams::default();
        dry_params.envelopment = 0.0;
        dry_params.reverb_mix = 0.0;
        dry_params.motion = MotionMode::Fixed;
        let mut wet_params = dry_params.clone();
        wet_params.envelopment = 1.0;

        let mut r0 = HrtfRenderer::new(sr).unwrap();
        let mut r1 = HrtfRenderer::new(sr).unwrap();
        let out0 = r0.render(&frames, &dry_params, None).unwrap();
        let out1 = r1.render(&frames, &wet_params, None).unwrap();
        let mut diff = 0.0f32;
        for i in 0..out0.len() {
            diff += (out0[i].0 - out1[i].0).abs() + (out0[i].1 - out1[i].1).abs();
        }
        assert!(
            diff > 50.0,
            "envelopment 0 vs 1 should differ on mono; sum abs diff={diff}"
        );
    }
}
