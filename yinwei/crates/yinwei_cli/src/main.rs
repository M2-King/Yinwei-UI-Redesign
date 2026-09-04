use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, ValueEnum};
use spatial_core::{
    apply_preset, Engine, MotionMode, PlaybackMode, PositionPreset, RealtimePlayer, SpatialParams,
};

#[derive(Parser, Debug)]
#[command(name = "yinwei", about = "音围 Spatial Player — offline HRTF export / realtime play")]
struct Args {
    /// Input audio file (wav/mp3/flac/ogg/m4a)
    input: PathBuf,

    /// Output WAV path (required unless --play)
    #[arg(short, long)]
    output: Option<PathBuf>,

    /// Play through default audio device after rendering (P1)
    #[arg(long, default_value_t = false)]
    play: bool,

    /// Seconds to play when using --play (0 = whole file)
    #[arg(long, default_value_t = 0)]
    play_secs: u64,

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

fn map_preset(p: PresetArg) -> PositionPreset {
    match p {
        PresetArg::Front => PositionPreset::Front,
        PresetArg::LeftFront => PositionPreset::LeftFront,
        PresetArg::RightFront => PositionPreset::RightFront,
        PresetArg::Left => PositionPreset::Left,
        PresetArg::Right => PositionPreset::Right,
        PresetArg::LeftRear => PositionPreset::LeftRear,
        PresetArg::RightRear => PositionPreset::RightRear,
        PresetArg::Back => PositionPreset::Back,
        PresetArg::Overhead => PositionPreset::Overhead,
    }
}

fn main() {
    let args = Args::parse();
    if !args.play && args.output.is_none() {
        eprintln!("error: specify -o/--output or --play");
        std::process::exit(2);
    }

    let engine = Engine::new();
    let meta = engine.open(&args.input).unwrap_or_else(|e| {
        eprintln!("open failed: {e}");
        std::process::exit(1);
    });

    println!(
        "loaded: {}  {} ms  {} Hz",
        meta.title, meta.duration_ms, meta.sample_rate
    );

    let mut params = SpatialParams::default();
    apply_preset(&mut params, map_preset(args.preset));
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

    if let Some(out) = &args.output {
        engine
            .export_wav(out, Some(&mut progress))
            .unwrap_or_else(|e| {
                eprintln!("\nexport failed: {e}");
                std::process::exit(1);
            });
        println!("\nwrote {}", out.display());
    }

    if args.play {
        print!("\rbuilding preview…");
        let _ = std::io::Write::flush(&mut std::io::stdout());
        let (sr, frames) = engine.render_frames(Some(&mut progress)).unwrap_or_else(|e| {
            eprintln!("\nrender failed: {e}");
            std::process::exit(1);
        });
        println!("\npreview frames: {} @ {} Hz", frames.len(), sr);

        if !RealtimePlayer::has_output_device() {
            eprintln!("no audio output device — skip --play (buffer render OK)");
            return;
        }

        let player = RealtimePlayer::new();
        player.set_sample_rate(sr);
        player.load_frames(frames).unwrap();
        if let Err(e) = player.play() {
            eprintln!("play skipped: {e} (buffer render OK)");
            return;
        }

        let total_ms = meta.duration_ms;
        let limit_ms = if args.play_secs == 0 {
            total_ms
        } else {
            args.play_secs.saturating_mul(1000).min(total_ms)
        };

        println!("playing… (headphones recommended)");
        while player.is_playing() && player.position_ms() < limit_ms {
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = player.stop();
        println!("done");
    }
}
