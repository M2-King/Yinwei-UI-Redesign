use freeverb::Freeverb;

/// Stereo reverb wrapper (Artezon/freeverb).
pub struct ReverbProcessor {
    freeverb: Freeverb,
    sample_rate: usize,
    room_size: f64,
    dampening: f64,
    width: f64,
}

impl ReverbProcessor {
    pub fn new(sample_rate: u32, room_size: f32, dampening: f32, width: f32) -> Self {
        let room_size = room_size.clamp(0.0, 1.0) as f64;
        let dampening = dampening.clamp(0.0, 1.0) as f64;
        let width = width.clamp(0.0, 1.0) as f64;
        let mut freeverb = Freeverb::new(sample_rate as usize);
        freeverb.set_room_size(room_size);
        freeverb.set_dampening(dampening);
        freeverb.set_width(width);
        Self {
            freeverb,
            sample_rate: sample_rate as usize,
            room_size,
            dampening,
            width,
        }
    }

    pub fn process(&mut self, left: f32, right: f32) -> (f32, f32) {
        let (l, r) = self.freeverb.tick((left as f64, right as f64));
        (l as f32, r as f32)
    }

    pub fn reset_state(&mut self) {
        let mut freeverb = Freeverb::new(self.sample_rate);
        freeverb.set_room_size(self.room_size);
        freeverb.set_dampening(self.dampening);
        freeverb.set_width(self.width);
        self.freeverb = freeverb;
    }
}
