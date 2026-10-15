//! Optional copy of rendered stereo PCM. Never drains a local output queue.
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use crate::decode::StereoFrame;
pub const OUTPUT_TAP_CHUNKS: usize = 8;
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct OutputTapMeta {
    pub epoch: u64,
    pub sequence: u64,
    pub first_frame: u64,
    pub sample_rate: u32,
    pub frame_count: u32,
    /// 0 Original, 1 Spatial, 2 DSP failed and fell back to dry.
    pub mode: u32,
    pub dropped_chunks: u32,
    pub azimuth_deg: f32,
    pub elevation_deg: f32,
}
pub struct OutputTapPacket { pub meta: OutputTapMeta, pub frames: Vec<StereoFrame> }
#[derive(Default)]
pub struct OutputTap {
    enabled: AtomicBool,
    epoch: AtomicU64,
    sequence: AtomicU64,
    dropped: AtomicU64,
    queue: Mutex<VecDeque<OutputTapPacket>>,
}
impl OutputTap {
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(false, Ordering::Release);
        self.invalidate();
        self.enabled.store(enabled, Ordering::Release);
    }
    pub fn epoch(&self) -> u64 { self.epoch.load(Ordering::Acquire) }
    pub fn invalidate(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut queue) = self.queue.lock() { queue.clear(); }
    }
    /// Capture-edge invalidation must not wait for a tap reader. A stale
    /// packet is rejected by the remote reader even if clearing is contended.
    pub fn invalidate_nonblocking(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut queue) = self.queue.try_lock() { queue.clear(); }
    }
    pub fn try_read(&self) -> Option<OutputTapPacket> {
        self.queue.try_lock().ok()?.pop_front()
    }
    pub fn publish(&self, epoch: u64, first_frame: u64, sample_rate: u32,
                   mode: u32, azimuth_deg: f32, elevation_deg: f32, frames: &[StereoFrame]) {
        if !self.enabled.load(Ordering::Acquire) { return; }
        let Ok(mut queue) = self.queue.try_lock() else {
            self.dropped.fetch_add(1, Ordering::Relaxed); return;
        };
        if epoch != self.epoch() || !self.enabled.load(Ordering::Acquire) { return; }
        if queue.len() >= OUTPUT_TAP_CHUNKS {
            queue.pop_front(); self.dropped.fetch_add(1, Ordering::Relaxed);
        }
        queue.push_back(OutputTapPacket {
            meta: OutputTapMeta {
                epoch, sequence: self.sequence.fetch_add(1, Ordering::Relaxed) + 1,
                first_frame, sample_rate, frame_count: frames.len() as u32, mode,
                dropped_chunks: self.dropped.load(Ordering::Relaxed).min(u32::MAX as u64) as u32,
                azimuth_deg, elevation_deg,
            }, frames: frames.to_vec(),
        });
    }
    pub fn read(&self) -> Option<OutputTapPacket> { self.queue.lock().ok()?.pop_front() }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_tap_has_no_pcm_and_enabled_copy_preserves_stereo() {
        let tap = OutputTap::default(); let pcm = [(0.25, -0.5), (-0.125, 0.75)];
        tap.publish(tap.epoch(), 0, 48000, 1, -90.0, 30.0, &pcm);
        assert!(tap.read().is_none());
        tap.set_enabled(true);
        tap.publish(tap.epoch(), 512, 48000, 1, -90.0, 30.0, &pcm);
        let packet = tap.read().unwrap();
        assert_eq!(packet.frames, pcm); assert_eq!(packet.meta.first_frame, 512);
        assert_eq!(packet.meta.frame_count, 2); assert_eq!(packet.meta.azimuth_deg, -90.0);
    }
    #[test]
    fn slow_reader_is_bounded_and_old_epoch_cannot_reappear() {
        let tap = OutputTap::default(); tap.set_enabled(true); let epoch = tap.epoch();
        for i in 0..100 { tap.publish(epoch, i, 48000, 0, 0.0, 0.0, &[(1.0, -1.0)]); }
        assert_eq!(tap.queue.lock().unwrap().len(), OUTPUT_TAP_CHUNKS);
        assert_eq!(tap.read().unwrap().meta.dropped_chunks, 85);
        tap.invalidate();
        tap.publish(epoch, 999, 48000, 0, 0.0, 0.0, &[(1.0, 1.0)]);
        assert!(tap.read().is_none()); tap.set_enabled(false);
        tap.publish(tap.epoch(), 0, 48000, 0, 0.0, 0.0, &[(1.0, 1.0)]);
        assert!(tap.read().is_none());
    }
    #[test]
    fn contended_tap_drops_instead_of_blocking_dsp() {
        let tap = OutputTap::default(); tap.set_enabled(true);
        let _reader = tap.queue.lock().unwrap();
        tap.publish(tap.epoch(), 0, 48000, 1, 0.0, 0.0, &[(0.2, 0.3)]);
        assert_eq!(tap.dropped.load(Ordering::Relaxed), 1);
    }
}
