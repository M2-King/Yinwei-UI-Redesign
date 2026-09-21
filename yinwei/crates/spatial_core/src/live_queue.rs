//! Bounded realtime PCM queue.
//!
//! Policy (documented, stable):
//! - Capacity is [`LIVE_INPUT_Q_CHUNKS`] × [`STREAM_CHUNK`] stereo frames
//!   (4 × 512 = 2048 frames ≈ 42.7 ms at 48 kHz). Target is 2–6 chunks.
//! - Push never blocks and never grows past capacity.
//! - On overflow, **drop oldest** frames so capture stays current
//!   (same idea as Windows Live Transfer `trim_front` on the dry queue).
//! - If an incoming batch is itself larger than capacity, keep the newest
//!   `capacity` frames of that batch.
//!
//! The AudioRecord / JNI thread must use `try_lock` on the mutex wrapping
//! this queue so a slow DSP worker cannot stall capture.

use std::collections::VecDeque;

use crate::decode::StereoFrame;
use crate::hrtf_render::STREAM_CHUNK;

/// Same depth as Windows `LIVE_DRY_Q_CHUNKS`.
pub const LIVE_INPUT_Q_CHUNKS: usize = 4;
pub const LIVE_INPUT_Q_FRAMES: usize = STREAM_CHUNK * LIVE_INPUT_Q_CHUNKS;

#[derive(Debug, Default)]
pub struct PushOutcome {
    pub accepted_frames: u64,
    pub dropped_frames: u64,
    pub overrun: bool,
}

pub struct BoundedFrameQueue {
    q: VecDeque<StereoFrame>,
    capacity: usize,
    dropped_frames: u64,
    overruns: u64,
    high_water_frames: usize,
}

impl BoundedFrameQueue {
    pub fn new(capacity_frames: usize) -> Self {
        let capacity = capacity_frames.max(1);
        Self {
            q: VecDeque::with_capacity(capacity),
            capacity,
            dropped_frames: 0,
            overruns: 0,
            high_water_frames: 0,
        }
    }

    pub fn with_default_capacity() -> Self {
        Self::new(LIVE_INPUT_Q_FRAMES)
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn len(&self) -> usize {
        self.q.len()
    }

    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }

    pub fn dropped_frames(&self) -> u64 {
        self.dropped_frames
    }

    pub fn overruns(&self) -> u64 {
        self.overruns
    }

    pub fn high_water_frames(&self) -> usize {
        self.high_water_frames
    }

    pub fn clear(&mut self) {
        self.q.clear();
    }

    /// Non-blocking push. Drops oldest on overflow. Never allocates unbounded.
    pub fn push_frames(&mut self, frames: &[StereoFrame]) -> PushOutcome {
        if frames.is_empty() {
            return PushOutcome::default();
        }

        let mut dropped = 0u64;
        let mut overrun = false;

        let incoming = if frames.len() > self.capacity {
            overrun = true;
            dropped += (frames.len() - self.capacity) as u64;
            &frames[frames.len() - self.capacity..]
        } else {
            frames
        };

        let overflow = self
            .q
            .len()
            .saturating_add(incoming.len())
            .saturating_sub(self.capacity);
        if overflow > 0 {
            overrun = true;
            let drop_n = overflow.min(self.q.len());
            self.q.drain(..drop_n);
            dropped += drop_n as u64;
        }

        self.q.extend(incoming.iter().copied());
        debug_assert!(self.q.len() <= self.capacity);
        self.high_water_frames = self.high_water_frames.max(self.q.len());
        if overrun {
            self.overruns += 1;
            self.dropped_frames += dropped;
        }

        PushOutcome {
            accepted_frames: incoming.len() as u64,
            dropped_frames: dropped,
            overrun,
        }
    }

    pub fn pop_front(&mut self) -> Option<StereoFrame> {
        self.q.pop_front()
    }

    pub fn pop_n(&mut self, n: usize, dest: &mut Vec<StereoFrame>) -> usize {
        let take = n.min(self.q.len());
        dest.extend(self.q.drain(..take));
        take
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(n: usize, tag: f32) -> Vec<StereoFrame> {
        (0..n).map(|i| (tag, i as f32)).collect()
    }

    #[test]
    fn default_capacity_is_four_stream_chunks() {
        let q = BoundedFrameQueue::with_default_capacity();
        assert_eq!(q.capacity(), STREAM_CHUNK * 4);
        assert_eq!(q.capacity(), LIVE_INPUT_Q_FRAMES);
        assert!(LIVE_INPUT_Q_CHUNKS >= 2 && LIVE_INPUT_Q_CHUNKS <= 6);
    }

    #[test]
    fn overflow_drops_oldest_and_stays_bounded() {
        let mut q = BoundedFrameQueue::new(4);
        q.push_frames(&[(1.0, 1.0), (2.0, 2.0), (3.0, 3.0), (4.0, 4.0)]);
        let out = q.push_frames(&[(5.0, 5.0), (6.0, 6.0)]);
        assert!(out.overrun);
        assert_eq!(out.dropped_frames, 2);
        assert_eq!(q.len(), 4);
        assert_eq!(q.pop_front(), Some((3.0, 3.0)));
        assert_eq!(q.pop_front(), Some((4.0, 4.0)));
        assert_eq!(q.pop_front(), Some((5.0, 5.0)));
        assert_eq!(q.pop_front(), Some((6.0, 6.0)));
        assert_eq!(q.overruns(), 1);
        assert_eq!(q.dropped_frames(), 2);
        assert_eq!(q.high_water_frames(), 4);
    }

    #[test]
    fn giant_batch_keeps_newest_capacity_frames() {
        let mut q = BoundedFrameQueue::new(4);
        let out = q.push_frames(&frames(10, 9.0));
        assert!(out.overrun);
        assert_eq!(q.len(), 4);
        assert_eq!(q.dropped_frames(), 6);
        assert_eq!(q.pop_front(), Some((9.0, 6.0)));
    }

    #[test]
    fn clear_empties_frames_but_keeps_counters() {
        let mut q = BoundedFrameQueue::new(4);
        q.push_frames(&frames(6, 1.0));
        q.clear();
        assert!(q.is_empty());
        assert_eq!(q.dropped_frames(), 2);
        assert_eq!(q.overruns(), 1);
    }

    #[test]
    fn never_grows_past_capacity() {
        let mut q = BoundedFrameQueue::with_default_capacity();
        for i in 0..50 {
            q.push_frames(&frames(STREAM_CHUNK, i as f32));
            assert!(q.len() <= q.capacity());
        }
        assert_eq!(q.len(), q.capacity());
        assert!(q.overruns() > 0);
        assert!(q.dropped_frames() > 0);
    }
}
