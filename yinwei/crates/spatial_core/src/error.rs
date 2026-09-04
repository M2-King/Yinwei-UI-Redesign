use thiserror::Error;

#[derive(Debug, Error)]
pub enum SpatialError {
    #[error("file not found: {0}")]
    FileNotFound(String),
    #[error("no track loaded")]
    NoTrackLoaded,
    #[error("invalid parameter: {0}")]
    InvalidParam(String),
    #[error("engine lock poisoned")]
    LockPoisoned,
    #[error("io error: {0}")]
    Io(String),
    #[error("decode error: {0}")]
    Decode(String),
    #[error("hrtf error: {0}")]
    Hrtf(String),
    #[error("not implemented: {0}")]
    NotImplemented(String),
}
