use crate::profile::BrowserProfile;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
pub struct RequestPayload {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
    pub profile: String,
    pub profile_data: Option<BrowserProfile>,
    pub proxy_tunnel: Option<String>,
    pub metadata: BTreeMap<String, serde_json::Value>,
}
