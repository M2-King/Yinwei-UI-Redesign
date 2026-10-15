//! Real DSP acceptance, independent of output devices and account state.
use crate::live_ingress::LiveIngress;
use crate::live_dsp::LiveDspProcessor;
use crate::layout::ArrayLayout;
use crate::params::{PlaybackMode, SpatialParams};
use std::time::{Duration, Instant};

fn pcm() -> Vec<i16> {
    (0..1920).map(|i| ((i as f32 * 0.031).sin() * 8000.0) as i16).collect()
}
fn wait_output(ingress: &LiveIngress) -> crate::output_tap::OutputTapPacket {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(packet) = ingress.read_remote_output() { return packet; }
        assert!(Instant::now() < deadline, "no wet output: {:?}", ingress.snapshot());
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn remote_rebatch_matches_one_original_or_hrtf_processor_invocation() {
    for mode in [PlaybackMode::Original, PlaybackMode::Spatial] {
        let params = SpatialParams::default();
        let ingress = LiveIngress::start_remote(77, params.clone(), mode,
            [0.0; 6], ArrayLayout::default()).unwrap();
        let samples = pcm();
        assert!(ingress.try_push_remote_i16(&samples[..960], 77, 0, true).unwrap());
        assert!(ingress.try_push_remote_i16(&samples[960..], 77, 480, false).unwrap());
        let packet = wait_output(&ingress);
        let dry = crate::live_pcm::frames_from_interleaved_i16(&samples[..1024], 2).unwrap();
        let mut processor = LiveDspProcessor::new(48000).unwrap();
        processor.set_params(params).unwrap();
        processor.snap_to_current_params();
        processor.set_mode(mode);
        let expected = processor.process_chunk(&dry).unwrap();
        assert_eq!(packet.frames.len(), 512);
        assert_eq!(packet.meta.epoch, 77);
        assert_eq!(packet.meta.first_frame, 0);
        for (actual, expected) in packet.frames.iter().zip(expected) {
            assert!((actual.0 - expected.0).abs() < 1e-6);
            assert!((actual.1 - expected.1).abs() < 1e-6);
        }
        assert_eq!(ingress.snapshot().dsp_chunks, 1);
        ingress.stop();
        assert!(ingress.read_remote_output().is_none());
    }
}

#[test]
fn remote_gap_flushes_partial_input_output_and_filter_tails() {
    let ingress = LiveIngress::start_remote(88, SpatialParams::default(),
        PlaybackMode::Original, [0.0; 6], ArrayLayout::default()).unwrap();
    let old = vec![12000i16; 960];
    let new = vec![-5000i16; 960];
    ingress.try_push_remote_i16(&old, 88, 0, true).unwrap();
    std::thread::sleep(Duration::from_millis(30));
    ingress.try_push_remote_i16(&new, 88, 960, true).unwrap();
    ingress.try_push_remote_i16(&new, 88, 1440, false).unwrap();
    let packet = wait_output(&ingress);
    assert_eq!(packet.meta.first_frame, 960);
    for frame in packet.frames { assert_eq!(frame, (-5000.0 / 32768.0, -5000.0 / 32768.0)); }
    ingress.stop();
}

#[test]
fn remote_rejects_wrong_epoch_size_and_unmarked_source_gap() {
    let ingress = LiveIngress::start_remote(99, SpatialParams::default(),
        PlaybackMode::Original, [0.0; 6], ArrayLayout::default()).unwrap();
    assert!(ingress.try_push_remote_i16(&[0; 960], 98, 0, true).is_err());
    assert!(ingress.try_push_remote_i16(&[0; 958], 99, 0, true).is_err());
    assert!(ingress.try_push_remote_i16(&[0; 960], 99, 480, false).is_err());
    assert_eq!(ingress.snapshot().input_frames, 0);
    ingress.stop();
}
