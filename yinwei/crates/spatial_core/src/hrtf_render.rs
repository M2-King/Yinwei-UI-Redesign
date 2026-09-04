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
    let d = distance.max(0.1);
    (1.0 / d).powf(1.5).min(2.0)
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

        let mut prev_mid_pos = spherical_to_vec(params.azimuth_deg, params.elevation_deg);
        let mut prev_side_pos =
            spherical_to_vec(params.azimuth_deg + 110.0, params.elevation_deg * 0.5);
        let mut prev_dist = params.distance_m;
        let mut phase = 0.0f32;

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
            let mid_az = params.azimuth_deg
                + if params.motion == MotionMode::Fixed {
                    0.0
                } else {
                    0.0
                };
            let side_az = params.azimuth_deg + 120.0 + orbit_offset;

            let new_mid_pos = spherical_to_vec(mid_az, params.elevation_deg);
            let new_side_pos = spherical_to_vec(side_az, params.elevation_deg * 0.5);
            let new_dist = params.distance_m;
            let prev_g = distance_gain(prev_dist);
            let new_g = distance_gain(new_dist);

            let mut bass = vec![0.0f32; CHUNK];
            let mut mid_high = vec![0.0f32; CHUNK];
            let mut side_high = vec![0.0f32; CHUNK];

            for i in 0..len {
                let (b_m, h_m) = self.crossover_mid.process(mid[start + i]);
                let (b_s, h_s) = self.crossover_side.process(side[start + i]);
                bass[i] = b_m + b_s * 0.35;
                mid_high[i] = h_m;
                side_high[i] = h_s * params.envelopment;
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
            if params.envelopment > 0.01 {
                // Fixed mode: also nudge Mid source with orbit_offset=0 side placement
                let side_pos = if params.motion == MotionMode::Fixed {
                    spherical_to_vec(params.azimuth_deg + 110.0, params.elevation_deg * 0.4)
                } else {
                    new_side_pos
                };
                let ctx = HrtfContext {
                    source: &side_high,
                    output: &mut side_out,
                    new_sample_vector: normalize(side_pos),
                    prev_sample_vector: normalize(prev_side_pos),
                    prev_left_samples: &mut prev_side_l,
                    prev_right_samples: &mut prev_side_r,
                    new_distance_gain: new_g * 0.85,
                    prev_distance_gain: prev_g * 0.85,
                };
                self.processor.process_samples(ctx);
                prev_side_pos = side_pos;
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
                let (rl, rr) = self.reverb.process(left, right);
                let mix = params.reverb_mix;
                output[start + i] = (
                    left * (1.0 - mix) + rl * mix,
                    right * (1.0 - mix) + rr * mix,
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
