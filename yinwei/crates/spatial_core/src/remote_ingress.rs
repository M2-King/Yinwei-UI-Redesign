//! Isolated remote source ownership. Reuses LiveIngress and its single DSP
//! invocation; owns no output device and never replaces other global sessions.
use std::sync::{Arc, Mutex};
use crate::error::SpatialError;
use crate::live_ingress::LiveIngress;
use crate::output_tap::OutputTapPacket;

static REMOTE: Mutex<Option<Arc<LiveIngress>>> = Mutex::new(None);

fn local_busy() -> Result<bool, SpatialError> {
    if crate::session::global_session()?.is_playing() { return Ok(true); }
    #[cfg(windows)]
    if crate::live_transfer::busy_for_remote() {
        return Ok(true);
    }
    Ok(false)
}

pub fn start(epoch: u64) -> Result<(), SpatialError> {
    if local_busy()? { return Err(SpatialError::AudioDevice("local source active".into())); }
    let mut slot = REMOTE.try_lock().map_err(|_| SpatialError::LockPoisoned)?;
    if slot.is_some() { return Err(SpatialError::AudioDevice("remote source already active".into())); }
    let (params, mode, eq, array) = crate::session::global_session()?.live_configuration()?;
    *slot = Some(Arc::new(LiveIngress::start_remote(epoch, params, mode, eq, array)?));
    Ok(())
}

pub fn push(samples: &[i16], epoch: u64, first_frame: u64, gap: bool) -> Result<bool, SpatialError> {
    if local_busy()? { return Err(SpatialError::AudioDevice("local source active".into())); }
    let Ok(slot) = REMOTE.try_lock() else { return Ok(false); };
    let Some(ingress) = slot.as_ref().cloned() else {
        return Err(SpatialError::AudioDevice("remote source stopped".into()));
    };
    drop(slot);
    ingress.try_push_remote_i16(samples, epoch, first_frame, gap)
}

pub fn read() -> Result<Option<OutputTapPacket>, SpatialError> {
    if local_busy()? { return Err(SpatialError::AudioDevice("local source active".into())); }
    let Ok(slot) = REMOTE.try_lock() else { return Ok(None); };
    let Some(ingress) = slot.as_ref().cloned() else { return Ok(None); };
    drop(slot);
    if let Some(error) = ingress.snapshot().last_error {
        return Err(SpatialError::AudioDevice(error));
    }
    Ok(ingress.read_remote_output())
}

pub fn stop() {
    let ingress = REMOTE.lock().ok().and_then(|mut slot| slot.take());
    if let Some(ingress) = ingress { ingress.stop(); }
}
