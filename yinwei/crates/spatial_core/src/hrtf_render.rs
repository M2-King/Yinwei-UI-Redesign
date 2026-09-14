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

/// Realtime streamer: 512-frame chunks (~10.7 ms @ 48 kHz).
/// Keep `INTERP=1`: higher interp multiplies OLS HRIR swaps → continuous buzz
/// during pose motion (see REPORT_POSE_SLEW_BUZZ.md). Motion uses dual-render
/// equal-power crossfade instead.
pub const STREAM_BLOCK: usize = 512;
pub const STREAM_INTERP: usize = 1;
pub const STREAM_CHUNK: usize = STREAM_BLOCK * STREAM_INTERP;

/// Max HRTF voices for the 2.0 array (L/R).
const ARRAY_VOICES: usize = crate::layout::MAX_SPEAKERS;
/// 2.0 opposite-channel bleed (no delay — Live lipsync). Fills phantom center.
const ARRAY_2_CROSSFEED: f32 = 0.30;
const ARRAY_2_TRIM: f32 = 0.90;
const ARRAY_2_REV: f32 = 1.12;

/// Large pose jumps slew at these rates (see `IMPLEMENTATION_POSE_SLEW.md`).
pub const SLEW_AZ_DEG_PER_SEC: f32 = 180.0;
pub const SLEW_EL_DEG_PER_SEC: f32 = 90.0;
pub const SLEW_DIST_M_PER_SEC: f32 = 3.0;
/// Below these deltas, use the softer exponential chase (slider / drag).
const CHASE_AZ_DEG: f32 = 35.0;
const CHASE_EL_DEG: f32 = 25.0;
const CHASE_DIST_M: f32 = 1.5;
const CHASE_A: f32 = 0.35;
/// Orbit HRTF azimuth quantum. Continuous dual-xfade every chunk buzzes and
/// underruns; step then dual-fade only when the quantum flips (see REPORT_ORBIT_BUZZ).
pub const ORBIT_HRIR_STEP_DEG: f32 = 8.0;

pub(crate) fn wrap_azimuth_deg(mut deg: f32) -> f32 {
    while deg > 180.0 {
        deg -= 360.0;
    }
    while deg <= -180.0 {
        deg += 360.0;
    }
    deg
}

pub(crate) fn shortest_azimuth_delta(from_deg: f32, to_deg: f32) -> f32 {
    let mut daz = to_deg - from_deg;
    while daz > 180.0 {
        daz -= 360.0;
    }
    while daz < -180.0 {
        daz += 360.0;
    }
    daz
}

pub(crate) fn quantize_azimuth_deg(az_deg: f32, step_deg: f32) -> f32 {
    let step = step_deg.abs().max(1e-3);
    wrap_azimuth_deg((az_deg / step).round() * step)
}

pub(crate) fn normalize(v: Vec3) -> Vec3 {
    let len = (v.x * v.x + v.y * v.y + v.z * v.z).sqrt();
    if len > 1e-6 {
        Vec3::new(v.x / len, v.y / len, v.z / len)
    } else {
        Vec3::new(0.0, 0.0, 1.0)
    }
}

fn vec3_near(a: Vec3, b: Vec3, eps: f32) -> bool {
    (a.x - b.x).abs() <= eps && (a.y - b.y).abs() <= eps && (a.z - b.z).abs() <= eps
}

/// Equal-power crossfade `a → b` into `out` (same length).
fn eq_power_crossfade(a: &[(f32, f32)], b: &[(f32, f32)], out: &mut [(f32, f32)]) {
    let n = out.len().min(a.len()).min(b.len());
    if n == 0 {
        return;
    }
    for i in 0..n {
        let t = (i as f32 + 1.0) / n as f32;
        let w_b = (t * std::f32::consts::FRAC_PI_2).sin();
        let w_a = ((1.0 - t) * std::f32::consts::FRAC_PI_2).sin();
        out[i] = (a[i].0 * w_a + b[i].0 * w_b, a[i].1 * w_a + b[i].1 * w_b);
    }
}

/// Render one mono HRTF path. When `from` and `to` differ, dual-render with a
/// full-chunk equal-power crossfade so OLS HRIR swaps do not buzz.
fn process_hrtf_path(
    processor: &mut HrtfProcessor,
    source: &[f32],
    output: &mut [(f32, f32)],
    from: Vec3,
    to: Vec3,
    prev_l: &mut Vec<f32>,
    prev_r: &mut Vec<f32>,
    from_gain: f32,
    to_gain: f32,
) {
    debug_assert_eq!(source.len(), STREAM_CHUNK);
    debug_assert!(output.len() >= STREAM_CHUNK);
    for s in output.iter_mut().take(STREAM_CHUNK) {
        *s = (0.0, 0.0);
    }

    let from_n = normalize(from);
    let to_n = normalize(to);
    let same_pose = vec3_near(from_n, to_n, 1e-4) && (from_gain - to_gain).abs() < 1e-4;

    if same_pose {
        let ctx = HrtfContext {
            source,
            output,
            new_sample_vector: to_n,
            prev_sample_vector: to_n,
            prev_left_samples: prev_l,
            prev_right_samples: prev_r,
            new_distance_gain: to_gain,
            prev_distance_gain: to_gain,
        };
        processor.process_samples(ctx);
        return;
    }

    let hist_l = prev_l.clone();
    let hist_r = prev_r.clone();
    let mut out_old = [(0.0f32, 0.0f32); STREAM_CHUNK];
    {
        let ctx = HrtfContext {
            source,
            output: &mut out_old,
            new_sample_vector: from_n,
            prev_sample_vector: from_n,
            prev_left_samples: prev_l,
            prev_right_samples: prev_r,
            new_distance_gain: from_gain,
            prev_distance_gain: from_gain,
        };
        processor.process_samples(ctx);
    }
    *prev_l = hist_l;
    *prev_r = hist_r;

    let mut out_new = [(0.0f32, 0.0f32); STREAM_CHUNK];
    {
        let ctx = HrtfContext {
            source,
            output: &mut out_new,
            new_sample_vector: to_n,
            prev_sample_vector: to_n,
            prev_left_samples: prev_l,
            prev_right_samples: prev_r,
            new_distance_gain: to_gain,
            prev_distance_gain: to_gain,
        };
        processor.process_samples(ctx);
    }
    eq_power_crossfade(&out_old, &out_new, output);
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
    // Mild high-shelf loss with distance — keep near-field bright.
    0.997 - 0.12 * t * t
}

/// Wet mix grows with distance so "far" feels more room / less dry proximity.
pub(crate) fn distance_reverb_mix(base: f32, distance: f32) -> f32 {
    let t = ((distance - 0.5) / 9.5).clamp(0.0, 1.0);
    // Keep far-field reverb gentle — heavy wet mix was reading as "damaged" audio.
    (base * (0.25 + 0.7 * t) + 0.05 * t).clamp(0.0, 0.55)
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
    /// Array voices — never read by [`Self::process_chunk`].
    crossover_arr_l: LinkwitzRileyCrossover,
    crossover_arr_r: LinkwitzRileyCrossover,
    array_voices: Vec<ArrayVoice>,
}

struct ArrayVoice {
    prev_l: Vec<f32>,
    prev_r: Vec<f32>,
    prev_pos: Vec3,
    smooth_az: f32,
    smooth_el: f32,
    smooth_dist: f32,
    prev_dist: f32,
}

impl ArrayVoice {
    fn at(az: f32, el: f32, dist: f32) -> Self {
        Self {
            prev_l: Vec::new(),
            prev_r: Vec::new(),
            prev_pos: spherical_to_vec(az, el),
            smooth_az: az,
            smooth_el: el,
            smooth_dist: dist,
            prev_dist: dist,
        }
    }
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
            crossover_arr_l: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            crossover_arr_r: LinkwitzRileyCrossover::new(sample_rate, 80.0),
            array_voices: (0..ARRAY_VOICES)
                .map(|i| match i {
                    0 => ArrayVoice::at(-30.0, 0.0, 1.8),
                    _ => ArrayVoice::at(30.0, 0.0, 1.8),
                })
                .collect(),
        })
    }

    pub fn reset(&mut self) {
        self.crossover_mid.reset_state();
        self.crossover_side.reset_state();
        self.crossover_arr_l.reset_state();
        self.crossover_arr_r.reset_state();
        self.reverb.reset_state();
        self.prev_mid_l.clear();
        self.prev_mid_r.clear();
        self.prev_side_l.clear();
        self.prev_side_r.clear();
        self.prev_side2_l.clear();
        self.prev_side2_r.clear();
        for v in &mut self.array_voices {
            v.prev_l.clear();
            v.prev_r.clear();
        }
        self.phase = 0.0;
        self.air_lp = OnePoleLp::new();
    }

    /// Instantly align smoothed pose to `params` (DSP start / new track).
    /// Does not clear convolution history — call [`Self::reset`] when filters
    /// must restart.
    pub fn snap_to_params(&mut self, params: &SpatialParams) {
        self.smooth_az = params.azimuth_deg;
        self.smooth_el = params.elevation_deg;
        self.smooth_dist = params.distance_m;
        self.smooth_env = params.envelopment;
        self.smooth_rev = params.reverb_mix;
        self.prev_mid_pos = spherical_to_vec(self.smooth_az, self.smooth_el);
        self.prev_side_pos = spherical_to_vec(self.smooth_az + 110.0, self.smooth_el * 0.5);
        self.prev_side2_pos = spherical_to_vec(self.smooth_az - 110.0, self.smooth_el * 0.5);
        self.prev_dist = self.smooth_dist;
        self.phase = 0.0;
    }

    #[allow(dead_code)] // used by unit tests / future FFI
    pub fn smooth_azimuth_deg(&self) -> f32 {
        self.smooth_az
    }

    pub fn smooth_elevation_deg(&self) -> f32 {
        self.smooth_el
    }

    /// Mid-source azimuth used for rendering (smooth base + orbit offset).
    pub fn effective_mid_azimuth_deg(&self, params: &SpatialParams) -> f32 {
        let orbit_offset = if params.motion == MotionMode::Orbit {
            self.phase.to_degrees()
        } else {
            0.0
        };
        wrap_azimuth_deg(self.smooth_az + orbit_offset)
    }

    /// Process one [`STREAM_CHUNK`]-sized block. Shorter tails are zero-padded.
    pub fn process_chunk(
        &mut self,
        input: &[StereoFrame],
        params: &SpatialParams,
    ) -> Result<[StereoFrame; STREAM_CHUNK], SpatialError> {
        params.validate()?;

        let dt = STREAM_CHUNK as f32 / self.sample_rate as f32;
        let daz = shortest_azimuth_delta(self.smooth_az, params.azimuth_deg);
        let del = params.elevation_deg - self.smooth_el;
        let ddist = params.distance_m - self.smooth_dist;

        // Large leaps (presets / big jumps): rate-limited shortest-path slew.
        // Keep prev_* HRTF vectors so block interpolation stays continuous —
        // no ring flush, no one-block full-sphere sweep.
        if daz.abs() > CHASE_AZ_DEG || del.abs() > CHASE_EL_DEG || ddist.abs() > CHASE_DIST_M {
            let max_az = SLEW_AZ_DEG_PER_SEC * dt;
            let max_el = SLEW_EL_DEG_PER_SEC * dt;
            let max_dist = SLEW_DIST_M_PER_SEC * dt;
            self.smooth_az = wrap_azimuth_deg(self.smooth_az + daz.clamp(-max_az, max_az));
            self.smooth_el += del.clamp(-max_el, max_el);
            self.smooth_dist += ddist.clamp(-max_dist, max_dist);
        } else {
            // Continuous drag: gentle chase (~35% / block).
            self.smooth_az = wrap_azimuth_deg(self.smooth_az + daz * CHASE_A);
            self.smooth_el += del * CHASE_A;
            self.smooth_dist += ddist * CHASE_A;
        }
        self.smooth_env += (params.envelopment - self.smooth_env) * CHASE_A;
        self.smooth_rev += (params.reverb_mix - self.smooth_rev) * CHASE_A;

        let mut padded = [(0.0f32, 0.0f32); STREAM_CHUNK];
        let n = input.len().min(STREAM_CHUNK);
        padded[..n].copy_from_slice(&input[..n]);

        let (mid, side) = split_buffers(&padded);

        if params.motion == MotionMode::Orbit {
            self.phase += dt * params.orbit_hz * TAU;
        }
        let orbit_offset = if params.motion == MotionMode::Orbit {
            self.phase.to_degrees()
        } else {
            0.0
        };

        // Orbit: quantize the HRTF frame so most chunks keep a stable HRIR
        // (single process). Dual-xfade only when the 8° step flips — avoids
        // perpetual 2–6× HRTF + continuous phase buzz (REPORT_ORBIT_BUZZ).
        let (mid_render_pos, side_pos_orbit, side2_pos_orbit) =
            if params.motion == MotionMode::Orbit {
                let mid_az = quantize_azimuth_deg(
                    wrap_azimuth_deg(self.smooth_az + orbit_offset),
                    ORBIT_HRIR_STEP_DEG,
                );
                let el = self.smooth_el;
                (
                    spherical_to_vec(mid_az, el),
                    spherical_to_vec(mid_az + 110.0, el * 0.4),
                    spherical_to_vec(mid_az - 110.0, el * 0.4),
                )
            } else {
                let mid = spherical_to_vec(self.smooth_az, self.smooth_el);
                (
                    mid,
                    spherical_to_vec(self.smooth_az + 110.0, self.smooth_el * 0.4),
                    spherical_to_vec(self.smooth_az - 110.0, self.smooth_el * 0.4),
                )
            };

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

        let mut mid_out = [(0.0f32, 0.0f32); STREAM_CHUNK];
        process_hrtf_path(
            &mut self.processor,
            &mid_high,
            &mut mid_out,
            self.prev_mid_pos,
            mid_render_pos,
            &mut self.prev_mid_l,
            &mut self.prev_mid_r,
            prev_g,
            new_g,
        );
        self.prev_mid_pos = mid_render_pos;

        let mut side_out = [(0.0f32, 0.0f32); STREAM_CHUNK];
        // Skip ambient HRTFs when envelopment is negligible — halves/thirds DSP
        // cost on the hot path (big help when the UI thread is also busy).
        if env > 0.05 {
            let side_pos = side_pos_orbit;
            let mut side_a = [(0.0f32, 0.0f32); STREAM_CHUNK];
            process_hrtf_path(
                &mut self.processor,
                &side_high,
                &mut side_a,
                self.prev_side_pos,
                side_pos,
                &mut self.prev_side_l,
                &mut self.prev_side_r,
                prev_g * 0.8,
                new_g * 0.8,
            );
            self.prev_side_pos = side_pos;

            if env > 0.35 {
                let side2_pos = side2_pos_orbit;
                let mut side_b = [(0.0f32, 0.0f32); STREAM_CHUNK];
                process_hrtf_path(
                    &mut self.processor,
                    &side_high,
                    &mut side_b,
                    self.prev_side2_pos,
                    side2_pos,
                    &mut self.prev_side2_l,
                    &mut self.prev_side2_r,
                    prev_g * 0.7,
                    new_g * 0.7,
                );
                for i in 0..STREAM_CHUNK {
                    let (a_l, a_r) = side_a[i];
                    let (b_l, b_r) = side_b[i];
                    side_out[i] = (a_l + b_l * 0.85, a_r + b_r * 0.85);
                }
                self.prev_side2_pos = side2_pos;
            } else {
                side_out = side_a;
            }
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

    /// Discrete 2.0 array: L/R HRTF voices + opposite-channel crossfeed.
    /// Does not touch Point prev_mid / envelopment / orbit state.
    pub fn process_chunk_array(
        &mut self,
        input: &[StereoFrame],
        params: &SpatialParams,
        layout: &crate::layout::ArrayLayout,
    ) -> Result<[StereoFrame; STREAM_CHUNK], SpatialError> {
        params.validate()?;

        let dt = STREAM_CHUNK as f32 / self.sample_rate as f32;
        self.smooth_rev += (params.reverb_mix - self.smooth_rev) * CHASE_A;

        let n = layout.speakers.len().min(self.array_voices.len());
        for i in 0..n {
            let spk = layout.speakers[i];
            let v = &mut self.array_voices[i];
            slew_speaker_pose(
                &mut v.smooth_az,
                &mut v.smooth_el,
                &mut v.smooth_dist,
                spk.az_deg,
                spk.el_deg,
                spk.dist_m,
                dt,
            );
        }

        let mut padded = [(0.0f32, 0.0f32); STREAM_CHUNK];
        let n_in = input.len().min(STREAM_CHUNK);
        padded[..n_in].copy_from_slice(&input[..n_in]);

        let mut bass = [0.0f32; STREAM_CHUNK];
        let mut high_l = [0.0f32; STREAM_CHUNK];
        let mut high_r = [0.0f32; STREAM_CHUNK];
        for i in 0..STREAM_CHUNK {
            let (b_l, h_l) = self.crossover_arr_l.process(padded[i].0);
            let (b_r, h_r) = self.crossover_arr_r.process(padded[i].1);
            bass[i] = (b_l + b_r) * 0.5;
            high_l[i] = h_l;
            high_r[i] = h_r;
        }

        let stereo2 = layout.mode == crate::layout::ArrayMode::Stereo2;
        let mut feed_l = high_l;
        let mut feed_r = high_r;
        if stereo2 {
            for i in 0..STREAM_CHUNK {
                feed_l[i] = high_l[i] + ARRAY_2_CROSSFEED * high_r[i];
                feed_r[i] = high_r[i] + ARRAY_2_CROSSFEED * high_l[i];
            }
        }

        let mut mix = [(0.0f32, 0.0f32); STREAM_CHUNK];
        let mut dist_acc = 0.0f32;
        let mut hrtf_n = 0u32;

        for i in 0..n {
            let spk = layout.speakers[i];
            if spk.mute {
                continue;
            }
            let gain = db_to_lin(spk.gain_db);
            let new_dist = self.array_voices[i].smooth_dist;
            let new_g = distance_gain(new_dist) * gain;

            let prev_g = distance_gain(self.array_voices[i].prev_dist) * gain;
            let pos = spherical_to_vec(
                self.array_voices[i].smooth_az,
                self.array_voices[i].smooth_el,
            );
            let high: &[f32] = match spk.feed {
                crate::layout::SpeakerFeed::Left => &feed_l,
                crate::layout::SpeakerFeed::Right => &feed_r,
            };
            let mut spk_out = [(0.0f32, 0.0f32); STREAM_CHUNK];
            let from_pos = self.array_voices[i].prev_pos;
            {
                let processor = &mut self.processor;
                let voice = &mut self.array_voices[i];
                process_hrtf_path(
                    processor,
                    high,
                    &mut spk_out,
                    from_pos,
                    pos,
                    &mut voice.prev_l,
                    &mut voice.prev_r,
                    prev_g,
                    new_g,
                );
                voice.prev_pos = pos;
                voice.prev_dist = new_dist;
            }
            for j in 0..STREAM_CHUNK {
                mix[j].0 += spk_out[j].0;
                mix[j].1 += spk_out[j].1;
            }
            dist_acc += new_dist;
            hrtf_n += 1;
        }

        let mean_dist = if hrtf_n > 0 {
            dist_acc / hrtf_n as f32
        } else {
            1.8
        };
        let air_c = air_absorption_coeff(mean_dist);
        let mut wet = distance_reverb_mix(self.smooth_rev, mean_dist);
        if stereo2 {
            wet = (wet * ARRAY_2_REV).clamp(0.0, 0.55);
        }

        let mut output = [(0.0f32, 0.0f32); STREAM_CHUNK];
        for i in 0..STREAM_CHUNK {
            let g = if hrtf_n > 0 {
                distance_gain(mean_dist)
            } else {
                0.0
            };
            let left = mix[i].0 * ARRAY_2_TRIM + bass[i] * g;
            let right = mix[i].1 * ARRAY_2_TRIM + bass[i] * g;
            let (dl, dr) = self.air_lp.process(left, right, air_c);
            let (rl, rr) = self.reverb.process(dl, dr);
            output[i] = (
                dl * (1.0 - wet) + rl * wet,
                dr * (1.0 - wet) + rr * wet,
            );
        }
        Ok(output)
    }
}

fn db_to_lin(db: f32) -> f32 {
    10.0f32.powf(db / 20.0)
}

fn slew_speaker_pose(
    smooth_az: &mut f32,
    smooth_el: &mut f32,
    smooth_dist: &mut f32,
    target_az: f32,
    target_el: f32,
    target_dist: f32,
    dt: f32,
) {
    let daz = shortest_azimuth_delta(*smooth_az, target_az);
    let del = target_el - *smooth_el;
    let ddist = target_dist - *smooth_dist;
    if daz.abs() > CHASE_AZ_DEG || del.abs() > CHASE_EL_DEG || ddist.abs() > CHASE_DIST_M {
        let max_az = SLEW_AZ_DEG_PER_SEC * dt;
        let max_el = SLEW_EL_DEG_PER_SEC * dt;
        let max_dist = SLEW_DIST_M_PER_SEC * dt;
        *smooth_az = wrap_azimuth_deg(*smooth_az + daz.clamp(-max_az, max_az));
        *smooth_el += del.clamp(-max_el, max_el);
        *smooth_dist += ddist.clamp(-max_dist, max_dist);
    } else {
        *smooth_az = wrap_azimuth_deg(*smooth_az + daz * CHASE_A);
        *smooth_el += del * CHASE_A;
        *smooth_dist += ddist * CHASE_A;
    }
    *smooth_el = smooth_el.clamp(-90.0, 90.0);
    *smooth_dist = smooth_dist.clamp(0.5, 10.0);
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

    #[test]
    fn streamer_slews_large_azimuth_jump_not_snap() {
        let sr = 48_000u32;
        let mut streamer = HrtfStreamer::new(sr).unwrap();
        let mut params = SpatialParams::default();
        params.azimuth_deg = 180.0; // Back
        params.motion = MotionMode::Fixed;
        streamer.snap_to_params(&params);

        let silence = vec![(0.0f32, 0.0f32); STREAM_CHUNK];
        params.azimuth_deg = 0.0; // Front — 180° shortest path
        streamer.process_chunk(&silence, &params).unwrap();

        let az = streamer.smooth_azimuth_deg();
        let step = SLEW_AZ_DEG_PER_SEC * (STREAM_CHUNK as f32 / sr as f32);
        // One block must not teleport to 0°; it should move ~step toward Front.
        assert!(
            az.abs() > 90.0,
            "expected partial slew after one block, got az={az}"
        );
        let expected = 180.0 - step; // daz = -180 → step negative from +180
        assert!(
            (az - expected).abs() < 1.0,
            "az={az} expected ~{expected} after one slew step"
        );
    }

    #[test]
    fn shortest_azimuth_prefers_half_turn() {
        assert!((shortest_azimuth_delta(180.0, 0.0).abs() - 180.0).abs() < 1e-3);
        assert!((shortest_azimuth_delta(-90.0, 90.0).abs() - 180.0).abs() < 1e-3);
        assert!((shortest_azimuth_delta(10.0, -10.0) + 20.0).abs() < 1e-3);
    }

    #[test]
    fn quantize_azimuth_snaps_to_step() {
        assert!((quantize_azimuth_deg(3.0, 8.0) - 0.0).abs() < 1e-3);
        assert!((quantize_azimuth_deg(5.0, 8.0) - 8.0).abs() < 1e-3);
        assert!((quantize_azimuth_deg(178.0, 8.0).abs() - 176.0).abs() < 1e-3 ||
            (quantize_azimuth_deg(178.0, 8.0).abs() - 180.0).abs() < 1e-3);
    }

    #[test]
    fn orbit_holds_hrir_across_adjacent_chunks() {
        let sr = 48_000u32;
        let mut streamer = HrtfStreamer::new(sr).unwrap();
        let mut params = SpatialParams::default();
        params.motion = MotionMode::Orbit;
        params.orbit_hz = 0.4;
        params.envelopment = 0.0; // Mid-only — isolate pose hold
        streamer.snap_to_params(&params);

        let silence = vec![(0.0f32, 0.0f32); STREAM_CHUNK];
        let mut last = streamer.prev_mid_pos;
        let mut changes = 0usize;
        const N: usize = 40;
        for _ in 0..N {
            streamer.process_chunk(&silence, &params).unwrap();
            let p = streamer.prev_mid_pos;
            if !vec3_near(last, p, 1e-5) {
                changes += 1;
                last = p;
            }
        }
        // Continuous dual would change every chunk (~40). 8° steps ≈ Δaz/chunk
        // 1.5° → flip every ~5 chunks → well under N/2.
        assert!(
            changes < N / 2,
            "Orbit HRIR should stay held most chunks; changes={changes}/{N}"
        );
        assert!(changes >= 1, "Orbit should still advance quantized steps");
    }

    fn stereo_tone(sr: u32) -> Vec<StereoFrame> {
        (0..STREAM_CHUNK)
            .map(|i| {
                let t = i as f32 / sr as f32;
                let l = (t * 440.0 * std::f32::consts::TAU).sin() * 0.25;
                let r = (t * 554.0 * std::f32::consts::TAU).sin() * 0.25;
                (l, r)
            })
            .collect()
    }

    fn block_energy(b: &[StereoFrame]) -> f32 {
        b.iter().map(|(l, r)| l * l + r * r).sum()
    }

    fn block_diff(a: &[StereoFrame], b: &[StereoFrame]) -> f32 {
        a.iter()
            .zip(b.iter())
            .map(|(x, y)| (x.0 - y.0).abs() + (x.1 - y.1).abs())
            .sum()
    }

    #[test]
    fn point_process_chunk_matches_fresh_streamer() {
        let sr = 48_000u32;
        let chunk = stereo_tone(sr);
        let mut params = SpatialParams::default();
        params.motion = MotionMode::Fixed;
        params.envelopment = 0.6;
        let mut a = HrtfStreamer::new(sr).unwrap();
        let mut b = HrtfStreamer::new(sr).unwrap();
        a.snap_to_params(&params);
        b.snap_to_params(&params);
        let out_a = a.process_chunk(&chunk, &params).unwrap();
        let out_b = b.process_chunk(&chunk, &params).unwrap();
        assert!(
            block_diff(&out_a, &out_b) < 1e-4,
            "Point process_chunk must stay deterministic after array fields"
        );
    }

    #[test]
    fn array_2_0_differs_from_point_plus_90() {
        let sr = 48_000u32;
        let chunk = stereo_tone(sr);
        let mut point_params = SpatialParams::default();
        point_params.azimuth_deg = 90.0;
        point_params.elevation_deg = 0.0;
        point_params.distance_m = 1.5;
        point_params.envelopment = 0.0;
        point_params.reverb_mix = 0.0;
        point_params.motion = MotionMode::Fixed;
        let mut layout = crate::layout::ArrayLayout::default();
        layout.set_mode(1).unwrap();

        let mut point = HrtfStreamer::new(sr).unwrap();
        let mut array = HrtfStreamer::new(sr).unwrap();
        point.snap_to_params(&point_params);
        array.snap_to_params(&point_params);
        let out_p = point.process_chunk(&chunk, &point_params).unwrap();
        let out_a = array
            .process_chunk_array(&chunk, &point_params, &layout)
            .unwrap();
        let diff = block_diff(&out_p, &out_a);
        assert!(
            diff > 5.0,
            "array 2.0 must not collapse to Point +90°; diff={diff}"
        );
    }

    #[test]
    fn array_mute_drops_energy() {
        let sr = 48_000u32;
        let chunk = stereo_tone(sr);
        let mut params = SpatialParams::default();
        params.reverb_mix = 0.0;
        params.envelopment = 0.0;
        params.motion = MotionMode::Fixed;
        let mut both = crate::layout::ArrayLayout::default();
        both.set_mode(1).unwrap();
        let mut muted = both.clone();
        muted.speakers[1].mute = true;

        let mut s_both = HrtfStreamer::new(sr).unwrap();
        let mut s_mute = HrtfStreamer::new(sr).unwrap();
        s_both.snap_to_params(&params);
        s_mute.snap_to_params(&params);
        let e_both = block_energy(
            &s_both
                .process_chunk_array(&chunk, &params, &both)
                .unwrap(),
        );
        let e_mute = block_energy(
            &s_mute
                .process_chunk_array(&chunk, &params, &muted)
                .unwrap(),
        );
        assert!(
            e_mute < e_both * 0.85,
            "muting one 2.0 speaker should drop energy; both={e_both} mute={e_mute}"
        );
    }

    #[test]
    fn array_path_does_not_move_point_prev_mid() {
        let sr = 48_000u32;
        let chunk = stereo_tone(sr);
        let params = SpatialParams::default();
        let mut layout = crate::layout::ArrayLayout::default();
        layout.set_mode(1).unwrap();
        let mut s = HrtfStreamer::new(sr).unwrap();
        s.snap_to_params(&params);
        let before = s.prev_mid_pos;
        s.process_chunk_array(&chunk, &params, &layout).unwrap();
        assert!(
            vec3_near(before, s.prev_mid_pos, 1e-6),
            "array render must not rewrite Point prev_mid"
        );
    }
}
