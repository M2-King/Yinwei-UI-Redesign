//! SpeakerSemanticsV1 — current stereo / Left-Right-Mid engine facts.

pub struct SpeakerSemanticsV1;

impl SpeakerSemanticsV1 {
    pub const INPUT: &'static str = "stereo";
    pub const INPUT_CHANNEL_COUNT: u32 = 2;
    pub const ACOUSTIC_FEEDS: &'static [&'static str] = &["left", "right", "mid"];
    pub const ARRAY_MODES: &'static [&'static str] = &["off", "stereo2"];
    pub const IS_DISCRETE_SURROUND_DECODER: bool = false;
    pub const IS_DISCRETE_71: bool = false;
    pub const MAX_VISUAL_EMITTERS: u32 = 8;
    pub const TRUE_MULTICHANNEL_ROUTING_IN_SCOPE: bool = false;
    pub const EXTRA_SLOT_FEED: &'static str = "mid";
    pub const VISUAL_ROLES_DO_NOT_IMPLY_ROUTING: &'static [&'static str] = &[
        "center", "lfe", "rear", "side", "C", "LFE", "Ls", "Rs", "Lb", "Rb",
    ];

    pub fn is_acoustic_feed(name: &str) -> bool {
        matches!(name.to_ascii_lowercase().as_str(), "left" | "right" | "mid")
    }
}
