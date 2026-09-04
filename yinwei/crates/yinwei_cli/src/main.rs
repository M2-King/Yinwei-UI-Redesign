use std::path::PathBuf;

use clap::{Parser, ValueEnum};
use spatial_core::{
    apply_preset, Engine, MotionMode, PlaybackMode, PositionPreset, SpatialParams,
};

#[derive(Parser, Debug)]
#[command(name = "yinwei", about = "音围 Spatial Player — offline HRTF export CLI")]
struct Args {
    /// Input audio file (wav/mp3/flac/ogg/m4a)
    input: PathBuf,

    /// Output WAV path
    #[arg(short, long)]
    output: PathBuf,

    /// Bypass HRTF
    #[arg(long, default_value_t = false)]
    original: bool,

    #[arg(long, value_enum, default_value_t = PresetArg::Right)]
    preset: PresetArg,

    #[arg(long, value_enum, default_value_t = MotionArg::Fixed)]
    motion: MotionArg,

    #[arg(long, default_value_t = 0.6)]
    envelopment: f32,

    #[arg(long, default_value_t = 0.2)]
    reverb: f32,

    #[arg(long, default_value_t = 0.4)]
    orbit_hz: f32,
}

#[derive(Clone, Debug, ValueEnum)]
enum PresetArg {
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

#[derive(Clone, Debug, ValueEnum)]
enum MotionArg {
    Fixed,
    Orbit,
}

fn main() {
    let args = Args::parse();
    let engine = Engine::new();
    let meta = engine
        .open(&args.input)
        .unwrap_or_else(|e| {
            eprintln!("open failed: {e}");
            std::process::exit(1);
        });

    println!(
        "loaded: {}  {} ms  {} Hz",
        meta.title, meta.duration_ms, meta.sample_rate
    );

    let preset = match args.preset {
        PresetArg::Front => PositionPreset::Front,
        PresetArg::LeftFront => PositionPreset::LeftFront,
        PresetArg::RightFront => PositionPreset::RightFront,
        PresetArg::Left => PositionPreset::Left,
        PresetArg::Right => PositionPreset::Right,
        PresetArg::LeftRear => PositionPreset::LeftRear,
        PresetArg::RightRear => PositionPreset::RightRear,
        PresetArg::Back => PositionPreset::Back,
        PresetArg::Overhead => PositionPreset::Overhead,
    };

    let mut params = SpatialParams::default();
    apply_preset(&mut params, preset);
    params.motion = match args.motion {
        MotionArg::Fixed => MotionMode::Fixed,
        MotionArg::Orbit => MotionMode::Orbit,
    };
    params.envelopment = args.envelopment.clamp(0.0, 1.0);
    params.reverb_mix = args.reverb.clamp(0.0, 1.0);
    params.orbit_hz = args.orbit_hz.clamp(0.0, 2.0);

    engine.set_params(params).unwrap();
    engine
        .set_playback_mode(if args.original {
            PlaybackMode::Original
        } else {
            PlaybackMode::Spatial
        })
        .unwrap();

    let mut last = -1;
    let mut progress = |p: f32| {
        let pct = (p * 100.0) as i32;
        if pct != last {
            print!("\rrendering {pct}%");
            let _ = std::io::Write::flush(&mut std::io::stdout());
            last = pct;
        }
    };

    engine
        .export_wav(&args.output, Some(&mut progress))
        .unwrap_or_else(|e| {
            eprintln!("\nexport failed: {e}");
            std::process::exit(1);
        });

    println!("\nwrote {}", args.output.display());
}
