use biquad::{Biquad, Coefficients, DirectForm2Transposed, ToHertz, Type, Q_BUTTERWORTH_F32};

/// Linkwitz-Riley 4th-order crossover (ported from Artezon/8D-Audio-Converter-HRTF).
pub struct LinkwitzRileyCrossover {
    bass_stage1: DirectForm2Transposed<f32>,
    bass_stage2: DirectForm2Transposed<f32>,
    high_stage1: DirectForm2Transposed<f32>,
    high_stage2: DirectForm2Transposed<f32>,
}

impl LinkwitzRileyCrossover {
    pub fn new(sample_rate: u32, crossover_freq: f32) -> Self {
        let fs = sample_rate as f32;
        let f0 = crossover_freq.hz();

        let lowpass = Coefficients::<f32>::from_params(
            Type::LowPass,
            fs.hz(),
            f0,
            Q_BUTTERWORTH_F32,
        )
        .expect("lowpass coeffs");

        let highpass = Coefficients::<f32>::from_params(
            Type::HighPass,
            fs.hz(),
            f0,
            Q_BUTTERWORTH_F32,
        )
        .expect("highpass coeffs");

        Self {
            bass_stage1: DirectForm2Transposed::<f32>::new(lowpass),
            bass_stage2: DirectForm2Transposed::<f32>::new(lowpass),
            high_stage1: DirectForm2Transposed::<f32>::new(highpass),
            high_stage2: DirectForm2Transposed::<f32>::new(highpass),
        }
    }

    pub fn process(&mut self, input: f32) -> (f32, f32) {
        let bass = self.bass_stage2.run(self.bass_stage1.run(input));
        let high = self.high_stage2.run(self.high_stage1.run(input));
        (bass, high)
    }

    pub fn reset_state(&mut self) {
        self.bass_stage1.reset_state();
        self.bass_stage2.reset_state();
        self.high_stage1.reset_state();
        self.high_stage2.reset_state();
    }
}
