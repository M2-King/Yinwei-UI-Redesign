use serde::{Deserialize, Serialize};

use crate::params::SpatialParams;

/// 3×3 preset grid from the UI mockup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PositionPreset {
    Front,
    LeftFront,
    RightFront,
    Left,
    Right,
    LeftRear,
    RightRear,
    Back,
    Overhead,
}

/// (azimuth_deg, elevation_deg, distance_m)
pub const PRESET_TABLE: [(PositionPreset, f32, f32, f32); 9] = [
    (PositionPreset::Front, 0.0, 0.0, 1.5),
    (PositionPreset::LeftFront, -45.0, 0.0, 1.5),
    (PositionPreset::RightFront, 45.0, 0.0, 1.5),
    (PositionPreset::Left, -90.0, 0.0, 1.5),
    (PositionPreset::Right, 90.0, 0.0, 1.5),
    (PositionPreset::LeftRear, -135.0, 0.0, 1.5),
    (PositionPreset::RightRear, 135.0, 0.0, 1.5),
    (PositionPreset::Back, 180.0, 0.0, 1.5),
    (PositionPreset::Overhead, 0.0, 75.0, 1.5),
];

impl PositionPreset {
    pub fn label(self) -> &'static str {
        match self {
            Self::Front => "Front",
            Self::LeftFront => "Left Front",
            Self::RightFront => "Right Front",
            Self::Left => "Left",
            Self::Right => "Right",
            Self::LeftRear => "Left Rear",
            Self::RightRear => "Right Rear",
            Self::Back => "Back",
            Self::Overhead => "Overhead",
        }
    }

    pub fn values(self) -> (f32, f32, f32) {
        PRESET_TABLE
            .iter()
            .find(|(p, _, _, _)| *p == self)
            .map(|(_, a, e, d)| (*a, *e, *d))
            .expect("preset in table")
    }
}

pub fn apply_preset(params: &mut SpatialParams, preset: PositionPreset) {
    let (az, el, dist) = preset.values();
    params.azimuth_deg = az;
    params.elevation_deg = el;
    params.distance_m = dist;
    params.selected_preset = Some(preset);
}
