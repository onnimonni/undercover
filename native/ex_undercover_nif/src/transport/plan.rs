use crate::error::RequestError;
use crate::profile::{resolve, BrowserProfile};
use crate::request::RequestPayload;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct RequestPlan {
    pub method: String,
    pub url: String,
    pub profile_id: String,
    pub headers: Vec<(String, String)>,
    pub alpn: Vec<String>,
    pub pseudo_header_order: Vec<String>,
    pub http2_settings: Vec<(String, u32)>,
    pub proxy_tunnel: Option<String>,
}

pub fn build(payload: &RequestPayload) -> Result<RequestPlan, RequestError> {
    let profile = payload
        .profile_data
        .clone()
        .or_else(|| resolve(&payload.profile))
        .ok_or_else(|| RequestError::UnsupportedProfile(payload.profile.clone()))?;

    Ok(RequestPlan {
        method: payload.method.clone(),
        url: payload.url.clone(),
        profile_id: profile.id.clone(),
        headers: effective_headers(&profile, &payload.headers),
        alpn: profile.tls.alpn.clone(),
        pseudo_header_order: profile.http2.pseudo_header_order.to_vec(),
        http2_settings: profile
            .http2
            .settings
            .iter()
            .map(|(name, value)| (name.clone(), *value))
            .collect(),
        proxy_tunnel: payload.proxy_tunnel.clone(),
    })
}

fn effective_headers(
    profile: &BrowserProfile,
    request_headers: &[(String, String)],
) -> Vec<(String, String)> {
    let mut merged = profile.headers.to_vec();

    for (name, value) in request_headers {
        let lname = name.to_ascii_lowercase();
        if let Some(existing) = merged.iter_mut().find(|(k, _)| k == &lname) {
            existing.1 = value.clone();
        } else {
            merged.push((lname, value.clone()));
        }
    }

    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::chrome_147;
    use crate::request::RequestPayload;
    use std::collections::BTreeMap;

    fn payload() -> RequestPayload {
        RequestPayload {
            method: "get".to_string(),
            url: "https://example.test/".to_string(),
            headers: vec![],
            body: None,
            profile: "chrome_147".to_string(),
            profile_data: None,
            proxy_tunnel: None,
            metadata: BTreeMap::new(),
        }
    }

    #[test]
    fn build_uses_embedded_profile_data_when_present() {
        let mut payload = payload();
        let mut profile = chrome_147();
        profile.id = "custom_chrome".to_string();
        payload.profile_data = Some(profile);

        let plan = build(&payload).expect("request plan should build");

        assert_eq!(plan.profile_id, "custom_chrome");
    }

    #[test]
    fn build_rejects_unknown_profiles() {
        let mut payload = payload();
        payload.profile = "unknown_profile".to_string();

        assert!(matches!(
            build(&payload),
            Err(RequestError::UnsupportedProfile(profile)) if profile == "unknown_profile"
        ));
    }

    #[test]
    fn effective_headers_overrides_profile_values_and_appends_new_headers() {
        let profile = chrome_147();
        let merged = effective_headers(
            &profile,
            &[
                ("User-Agent".to_string(), "custom-agent".to_string()),
                ("x-extra".to_string(), "1".to_string()),
            ],
        );

        assert!(merged
            .iter()
            .any(|(name, value)| name == "user-agent" && value == "custom-agent"));
        assert!(merged
            .iter()
            .any(|(name, value)| name == "x-extra" && value == "1"));
    }
}
