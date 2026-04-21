#[derive(thiserror::Error, Debug)]
pub enum RequestError {
    #[error("unsupported profile: {0}")]
    UnsupportedProfile(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("serialization error: {0}")]
    Serde(String),
}
