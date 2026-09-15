//! Discrete virtual-speaker layout (stereo 2.0).
//!
//! Kept off [`crate::params::SpatialParams`] / `YinweiParamsC` so Point-source
//! playback stays bit-stable when array is off.

use crate::error::SpatialError;

/// 0 = Point (off), 1 = Stereo 2.0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum ArrayMode {
    Off = 0,
    Stereo2 = 1,
}

impl ArrayMode {
    pub fn from_i32(v: i32) -> Result<Self, SpatialError> {
        match v {
            0 => Ok(Self::Off),
            1 => Ok(Self::Stereo2),
            _ => Err(SpatialError::InvalidParam(format!(
                "array mode {v} (want 0=off, 1=2.0)"
            ))),
        }
    }

    pub fn to_i32(self) -> i32 {
        self as i32
    }

    pub fn enabled(self) -> bool {
        self != Self::Off
    }
}

/// Which stereo channel feeds this virtual speaker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum SpeakerFeed {
    Left = 0,
    Right = 1,
    /// Extra 2.0 points: (L+R)/2 at about −3 dB. Not a 5.1 upmix.
    Mid = 2,
}

impl SpeakerFeed {
    pub fn from_i32(v: i32) -> Result<Self, SpatialError> {
        match v {
            0 => Ok(Self::Left),
            1 => Ok(Self::Right),
            2 => Ok(Self::Mid),
            _ => Err(SpatialError::InvalidParam(format!(
                "speaker feed {v} (want 0=L, 1=R, 2=Mid)"
            ))),
        }
    }

    pub fn to_i32(self) -> i32 {
        self as i32
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Speaker {
    pub az_deg: f32,
    pub el_deg: f32,
    pub dist_m: f32,
    pub gain_db: f32,
    pub mute: bool,
    pub feed: SpeakerFeed,
}

impl Speaker {
    pub fn clamp(mut self) -> Self {
        while self.az_deg > 180.0 {
            self.az_deg -= 360.0;
        }
        while self.az_deg <= -180.0 {
            self.az_deg += 360.0;
        }
        self.el_deg = self.el_deg.clamp(-90.0, 90.0);
        self.dist_m = self.dist_m.clamp(0.5, 10.0);
        self.gain_db = self.gain_db.clamp(-12.0, 6.0);
        self
    }
}

fn spk(az: f32, dist: f32, gain_db: f32, feed: SpeakerFeed) -> Speaker {
    Speaker {
        az_deg: az,
        el_deg: 0.0,
        dist_m: dist,
        gain_db,
        mute: false,
        feed,
    }
}

/// ITU-style stereo pair. Dist 1.8 m gives a little more air than 1.5 m
/// (2.0 hole-in-middle / dryness tune; angles stay ±30°).
pub fn stereo_2_0() -> Vec<Speaker> {
    vec![
        spk(-30.0, 1.8, 0.0, SpeakerFeed::Left),
        spk(30.0, 1.8, 0.0, SpeakerFeed::Right),
    ]
}

pub const MAX_SPEAKERS: usize = 8;

/// Session / live Shared array state. Default is Point (off) with 2.0 poses
/// stored so enabling does not need a second FFI round-trip.
#[derive(Debug, Clone, PartialEq)]
pub struct ArrayLayout {
    pub mode: ArrayMode,
    pub speakers: Vec<Speaker>,
}

impl Default for ArrayLayout {
    fn default() -> Self {
        Self {
            mode: ArrayMode::Off,
            speakers: stereo_2_0(),
        }
    }
}

impl ArrayLayout {
    pub fn enabled(&self) -> bool {
        self.mode.enabled()
    }

    pub fn set_mode(&mut self, mode: i32) -> Result<(), SpatialError> {
        let next = ArrayMode::from_i32(mode)?;
        if next != self.mode {
            self.speakers = match next {
                ArrayMode::Off => self.speakers.clone(),
                ArrayMode::Stereo2 => {
                    if self.speakers.len() >= 2 {
                        self.speakers.clone()
                    } else {
                        stereo_2_0()
                    }
                }
            };
            if next == ArrayMode::Off && self.speakers.is_empty() {
                self.speakers = stereo_2_0();
            }
        }
        self.mode = next;
        Ok(())
    }

    pub fn set_speaker_count(&mut self, n: i32) -> Result<(), SpatialError> {
        if n < 2 || (n as usize) > MAX_SPEAKERS {
            return Err(SpatialError::InvalidParam(format!(
                "speaker count {n} (want 2..{MAX_SPEAKERS})"
            )));
        }
        let n = n as usize;
        if n > self.speakers.len() {
            while self.speakers.len() < n {
                self.speakers.push(spk(0.0, 1.8, 0.0, SpeakerFeed::Mid));
            }
        } else {
            self.speakers.truncate(n);
        }
        Ok(())
    }

    pub fn set_speaker(
        &mut self,
        index: i32,
        az_deg: f32,
        el_deg: f32,
        dist_m: f32,
        gain_db: f32,
        mute: i32,
        feed: i32,
    ) -> Result<(), SpatialError> {
        if index < 0 || (index as usize) >= self.speakers.len() {
            return Err(SpatialError::InvalidParam(format!(
                "speaker index {index} (want 0..{})",
                self.speakers.len().saturating_sub(1)
            )));
        }
        self.speakers[index as usize] = Speaker {
            az_deg,
            el_deg,
            dist_m,
            gain_db,
            mute: mute != 0,
            feed: SpeakerFeed::from_i32(feed)?,
        }
        .clamp();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_2_0_is_minus_plus_30() {
        let s = stereo_2_0();
        assert_eq!(s.len(), 2);
        assert!((s[0].az_deg + 30.0).abs() < 1e-5);
        assert!((s[1].az_deg - 30.0).abs() < 1e-5);
        assert_eq!(s[0].feed, SpeakerFeed::Left);
        assert_eq!(s[1].feed, SpeakerFeed::Right);
    }

    #[test]
    fn default_layout_is_point_off() {
        let a = ArrayLayout::default();
        assert_eq!(a.mode, ArrayMode::Off);
        assert!(!a.enabled());
    }

    #[test]
    fn enabling_2_0_keeps_existing_speakers() {
        let mut a = ArrayLayout::default();
        a.speakers[0].az_deg = -90.0;
        a.set_mode(1).unwrap();
        assert_eq!(a.mode, ArrayMode::Stereo2);
        assert!((a.speakers[0].az_deg + 90.0).abs() < 1e-5);
        a.set_speaker_count(3).unwrap();
        assert_eq!(a.speakers.len(), 3);
        assert_eq!(a.speakers[2].feed, SpeakerFeed::Mid);
        a.set_speaker_count(2).unwrap();
        assert_eq!(a.speakers.len(), 2);
        assert!(a.set_speaker_count(9).is_err());
        assert!(a.set_mode(2).is_err());
    }
}
