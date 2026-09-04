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
    #[error("not implemented: {0}")]
    NotImplemented(String),
}
