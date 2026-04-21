pub mod emulation;
pub mod plan;
pub mod stub;

use crate::error::RequestError;
use crate::request::RequestPayload;
use crate::response::ResponsePayload;

pub trait BrowserTransport {
    fn dispatch(&self, payload: RequestPayload) -> Result<ResponsePayload, RequestError>;
}

pub fn dispatch(payload: RequestPayload) -> Result<ResponsePayload, RequestError> {
    let transport = stub::StubTransport;
    transport.dispatch(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn rejects_unsupported_profiles_before_dispatching_network_requests() {
        let payload = RequestPayload {
            method: "get".to_string(),
            url: "https://example.test/".to_string(),
            headers: vec![],
            body: None,
            profile: "unknown_profile".to_string(),
            profile_data: None,
            proxy_tunnel: None,
            metadata: BTreeMap::new(),
        };

        assert!(matches!(
            dispatch(payload),
            Err(RequestError::UnsupportedProfile(profile)) if profile == "unknown_profile"
        ));
    }
}
