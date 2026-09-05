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

/// Realtime streamer uses 1 interp step × 512 for ~10 ms blocks @ 48 kHz.
pub const STREAM_BLOCK: usize = 512;
pub const STREAM_INTERP: usize = 1;
pub const STREAM_CHUNK: usize = STREAM_BLOCK * STREAM_INTERP;

pub(crate) fn normalize(v: Vec3) -> Vec3 {
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

pub(crate) fn distance_gain(distance: f32) -> f32 {
    // Gentler inverse-distance from a 1.5 m reference.
    // Far should not only sound "quieter" — pair with air LP + reverb below.
    let d = distance.clamp(0.5, 10.0);
    (1.5 / d).clamp(0.22, 1.25)
}

/// One-pole coefficient for air absorption (higher = brighter).
pub(crate) fn air_absorption_coeff(distance: f32) -> f32 {
    let t = ((distance - 0.5) / 9.5).clamp(0.0, 1.0);
    // Mild high-shelf loss with distance. The previous linear curve was too dark
    // near-field and read as "phone / call quality".
    0.995 - 0.18 * t * t
}

/// Wet mix grows with distance so "far" feels more room / less dry proximity.
pub(crate) fn distance_reverb_mix(base: f32, distance: f32) -> f32 {
    let t = ((distance - 0.5) / 9.5).clamp(0.0, 1.0);
    (base * (0.3 + 1.05 * t) + 0.1 * t).clamp(0.0, 0.72)
}

pub(crate) struct OnePoleLp {
    z_l: f32,
    z_r: f32,
}

impl OnePoleLp {
    pub(crate) fn new() -> Self {
        Self { z_l: 0.0, z_r: 0.0 }
    }

    pub(crate) fn process(&mut self, l: f32, r: f32, coeff: f32) -> (f32, f32) {
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

            // Single Mid HRTF pass. Orbit used to render Mid twice (fixed then
            // orbiting) which desynced HRIR history → metallic / electronic noise.
            let mid_render_pos = if params.motion == MotionMode::Orbit {
                spherical_to_vec(
                    params.azimuth_deg + orbit_offset,
                    params.elevation_deg,
                )
            } else {
                new_mid_pos
            };
            let mut mid_out = vec![(0.0f32, 0.0f32); CHUNK];
            {
                let ctx = HrtfContext {
                    source: &mid_high,
                    output: &mut mid_out,
                    new_sample_vector: normalize(mid_render_pos),
                    prev_sample_vector: normalize(prev_mid_pos),
                    prev_left_samples: &mut prev_mid_l,
                    prev_right_samples: &mut prev_mid_r,
                    new_distance_gain: new_g,
                    prev_distance_gain: prev_g,
                };
                self.processor.process_samples(ctx);
            }
            prev_mid_pos = mid_render_pos;

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


/// Stateful block HRTF processor for realtime playback (no full-song render).
///
/// Processes exactly [`STREAM_CHUNK`] frames per call and retains convolution /
/// crossover / reverb / air state across calls so pose changes are click-free.
pub struct HrtfStreamer {
    sample_rate: u32,
    processor: HrtfProcessor,
    crossover_mid: LinkwitzRileyCrossover,
    crossover_side: LinkwitzRileyCrossover,
    reverb: ReverbProcessor,
    prev_mid_l: Vec<f32>,
    prev_mid_r: Vec<f32>,
    prev_side_l: Vec<f32>,
    prev_side_r: Vec<f32>,
    prev_side2_l: Vec<f32>,
    prev_side2_r: Vec<f32>,
    prev_mid_pos: Vec3,
    prev_side_pos: Vec3,
    prev_side2_pos: Vec3,
    prev_dist: f32,
    phase: f32,
    air_lp: OnePoleLp,
    /// Smoothed pose toward the latest UI target (avoids zipper noise).
    smooth_az: f32,
    smooth_el: f32,
    smooth_dist: f32,
    smooth_env: f32,
    smooth_rev: f32,
}

impl HrtfStreamer {
    pub fn new(sample_rate: u32) -> Result<Self, SpatialError> {
        let sphere = HrirSphere::new(Cursor::new(HRIR_BYTES), sample_rate)
            .map_err(|e| SpatialError::Hrtf(format!("{e:?}")))?;
        let processor = HrtfProcessor::new(sphere, STREAM_INTERP, STREAM_BLOCK);
        let params = SpatialParams::default();
        Ok(Self {
            sample_rate,
            processor,
            crossover_mid: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            crossover_side: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            reverb: ReverbProcessor::new(sample_rate, 0.5, 0.5, 0.9),
            prev_mid_l: Vec::new(),
            prev_mid_r: Vec::new(),
            prev_side_l: Vec::new(),
            prev_side_r: Vec::new(),
            prev_side2_l: Vec::new(),
            prev_side2_r: Vec::new(),
            prev_mid_pos: spherical_to_vec(params.azimuth_deg, params.elevation_deg),
            prev_side_pos: spherical_to_vec(params.azimuth_deg + 110.0, params.elevation_deg * 0.5),
            prev_side2_pos: spherical_to_vec(params.azimuth_deg - 110.0, params.elevation_deg * 0.5),
            prev_dist: params.distance_m,
            phase: 0.0,
            air_lp: OnePoleLp::new(),
            smooth_az: params.azimuth_deg,
            smooth_el: params.elevation_deg,
            smooth_dist: params.distance_m,
            smooth_env: params.envelopment,
            smooth_rev: params.reverb_mix,
        })
    }

    pub fn reset(&mut self) {
        self.crossover_mid.reset_state();
        self.crossover_side.reset_state();
        self.reverb.reset_state();
        self.prev_mid_l.clear();
        self.prev_mid_r.clear();
        self.prev_side_l.clear();
        self.prev_side_r.clear();
        self.prev_side2_l.clear();
        self.prev_side2_r.clear();
        self.phase = 0.0;
        self.air_lp = OnePoleLp::new();
    }

    /// Process one [`STREAM_CHUNK`]-sized block. Shorter tails are zero-padded.
    pub fn process_chunk(
        &mut self,
        input: &[StereoFrame],
        params: &SpatialParams,
    ) -> Result<[StereoFrame; STREAM_CHUNK], SpatialError> {
        params.validate()?;

        // Smooth toward target (~15% per ~10 ms block ≈ 60 ms time constant).
        const A: f32 = 0.18;
        self.smooth_az += (params.azimuth_deg - self.smooth_az) * A;
        self.smooth_el += (params.elevation_deg - self.smooth_el) * A;
        self.smooth_dist += (params.distance_m - self.smooth_dist) * A;
        self.smooth_env += (params.envelopment - self.smooth_env) * A;
        self.smooth_rev += (params.reverb_mix - self.smooth_rev) * A;

        let mut padded = [(0.0f32, 0.0f32); STREAM_CHUNK];
        let n = input.len().min(STREAM_CHUNK);
        padded[..n].copy_from_slice(&input[..n]);

        let (mid, side) = split_buffers(&padded);
        let dt = STREAM_CHUNK as f32 / self.sample_rate as f32;

        if params.motion == MotionMode::Orbit {
            self.phase += dt * params.orbit_hz * TAU;
        }
        let orbit_offset = if params.motion == MotionMode::Orbit {
            self.phase.to_degrees()
        } else {
            0.0
        };

        let mid_az = self.smooth_az;
        let side_az = self.smooth_az + 120.0 + orbit_offset;
        let new_mid_pos = spherical_to_vec(mid_az, self.smooth_el);
        let new_side_pos = spherical_to_vec(side_az, self.smooth_el * 0.5);
        let new_dist = self.smooth_dist;
        let prev_g = distance_gain(self.prev_dist);
        let new_g = distance_gain(new_dist);
        let air_c = air_absorption_coeff(new_dist);
        let wet = distance_reverb_mix(self.smooth_rev, new_dist);
        let env = self.smooth_env.clamp(0.0, 1.0);

        let mut bass = [0.0f32; STREAM_CHUNK];
        let mut mid_high = [0.0f32; STREAM_CHUNK];
        let mut side_high = [0.0f32; STREAM_CHUNK];
        for i in 0..STREAM_CHUNK {
            let (b_m, h_m) = self.crossover_mid.process(mid[i]);
            let (b_s, h_s) = self.crossover_side.process(side[i]);
            bass[i] = b_m + b_s * 0.35;
            mid_high[i] = h_m * (1.0 - 0.28 * env);
            side_high[i] = (h_s + h_m * 0.55) * env;
        }

        let mid_render_pos = if params.motion == MotionMode::Orbit {
            spherical_to_vec(self.smooth_az + orbit_offset, self.smooth_el)
        } else {
            new_mid_pos
        };

        let mut mid_out = [(0.0f32, 0.0f32); STREAM_CHUNK];
        {
            let ctx = HrtfContext {
                source: &mid_high,
                output: &mut mid_out,
                new_sample_vector: normalize(mid_render_pos),
                prev_sample_vector: normalize(self.prev_mid_pos),
                prev_left_samples: &mut self.prev_mid_l,
                prev_right_samples: &mut self.prev_mid_r,
                new_distance_gain: new_g,
                prev_distance_gain: prev_g,
            };
            self.processor.process_samples(ctx);
        }
        self.prev_mid_pos = mid_render_pos;

        let mut side_out = [(0.0f32, 0.0f32); STREAM_CHUNK];
        if env > 0.01 {
            let el = self.smooth_el * 0.4;
            let side_pos = if params.motion == MotionMode::Fixed {
                spherical_to_vec(self.smooth_az + 110.0, el)
            } else {
                new_side_pos
            };
            let side2_pos = if params.motion == MotionMode::Fixed {
                spherical_to_vec(self.smooth_az - 110.0, el)
            } else {
                spherical_to_vec(self.smooth_az - 120.0 + orbit_offset, self.smooth_el * 0.5)
            };
            let mut side_a = [(0.0f32, 0.0f32); STREAM_CHUNK];
            let mut side_b = [(0.0f32, 0.0f32); STREAM_CHUNK];
            {
                let ctx = HrtfContext {
                    source: &side_high,
                    output: &mut side_a,
                    new_sample_vector: normalize(side_pos),
                    prev_sample_vector: normalize(self.prev_side_pos),
                    prev_left_samples: &mut self.prev_side_l,
                    prev_right_samples: &mut self.prev_side_r,
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
                    prev_sample_vector: normalize(self.prev_side2_pos),
                    prev_left_samples: &mut self.prev_side2_l,
                    prev_right_samples: &mut self.prev_side2_r,
                    new_distance_gain: new_g * 0.7,
                    prev_distance_gain: prev_g * 0.7,
                };
                self.processor.process_samples(ctx);
            }
            for i in 0..STREAM_CHUNK {
                let (a_l, a_r) = side_a[i];
                let (b_l, b_r) = side_b[i];
                side_out[i] = (a_l + b_l * 0.85, a_r + b_r * 0.85);
            }
            self.prev_side_pos = side_pos;
            self.prev_side2_pos = side2_pos;
        }

        let mut output = [(0.0f32, 0.0f32); STREAM_CHUNK];
        for i in 0..STREAM_CHUNK {
            let t = i as f32 / STREAM_CHUNK as f32;
            let g = prev_g + (new_g - prev_g) * t;
            let (ml, mr) = mid_out[i];
            let (sl, sr) = side_out[i];
            let left = ml + sl + bass[i] * g;
            let right = mr + sr + bass[i] * g;
            let (dl, dr) = self.air_lp.process(left, right, air_c);
            let (rl, rr) = self.reverb.process(dl, dr);
            output[i] = (
                dl * (1.0 - wet) + rl * wet,
                dr * (1.0 - wet) + rr * wet,
            );
        }
        self.prev_dist = new_dist;
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
    #[test]
    fn streamer_processes_chunks_without_full_song() {
        let sr = 48_000u32;
        let mut streamer = HrtfStreamer::new(sr).unwrap();
        let mut params = SpatialParams::default();
        params.envelopment = 0.5;
        let chunk: Vec<StereoFrame> = (0..STREAM_CHUNK)
            .map(|i| {
                let t = i as f32 / sr as f32;
                let s = (t * 440.0 * std::f32::consts::TAU).sin() * 0.2;
                (s, s)
            })
            .collect();
        let a = streamer.process_chunk(&chunk, &params).unwrap();
        params.azimuth_deg = -90.0;
        let b = streamer.process_chunk(&chunk, &params).unwrap();
        let mut diff = 0.0f32;
        for i in 0..STREAM_CHUNK {
            diff += (a[i].0 - b[i].0).abs() + (a[i].1 - b[i].1).abs();
        }
        assert!(diff > 1.0, "pose change should alter stream output; diff={diff}");
    }

}
