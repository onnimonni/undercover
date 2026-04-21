mod chrome_147;

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub use chrome_147::chrome_147;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct BrowserProfile {
    pub id: String,
    pub browser: String,
    pub version: String,
    pub platform: String,
    pub headers: Vec<(String, String)>,
    pub tls: TlsProfile,
    pub http2: Http2Profile,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TlsProfile {
    pub alpn: Vec<String>,
    pub alps: Vec<String>,
    pub alps_use_new_codepoint: bool,
    pub certificate_compression: Vec<String>,
    pub curves: Vec<String>,
    pub cipher_suites: Vec<String>,
    pub delegated_credentials: Vec<String>,
    pub signature_algorithms: Vec<String>,
    pub key_share_groups: Vec<String>,
    pub extension_order: Vec<String>,
    pub min_version: String,
    pub max_version: String,
    pub record_size_limit: Option<u16>,
    pub ech_grease: bool,
    pub extension_permutation: bool,
    pub grease_enabled: Option<bool>,
    pub pre_shared_key: bool,
    pub preserve_tls13_cipher_list: bool,
    pub ocsp_stapling: bool,
    pub signed_cert_timestamps: bool,
    pub notes: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Http2Profile {
    pub pseudo_header_order: Vec<String>,
    pub settings_order: Vec<String>,
    pub settings: Vec<(String, u32)>,
    pub initial_stream_id: Option<u32>,
    pub initial_connection_window_size: Option<u32>,
    pub stream_dependency: Option<Http2StreamDependency>,
    pub priority_header: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Http2StreamDependency {
    pub stream_id: u32,
    pub weight: u8,
    pub exclusive: bool,
}

impl Http2Profile {
    pub fn setting(&self, name: &str) -> Option<u32> {
        self.settings
            .iter()
            .find_map(|(key, value)| (key == name).then_some(*value))
    }
}

pub fn resolve(id: &str) -> Option<BrowserProfile> {
    match id {
        "chrome_147" => Some(chrome_147()),
        _ => None,
    }
}

#[derive(Serialize)]
pub struct ProfileMetadata {
    latest_aliases: BTreeMap<&'static str, &'static str>,
    profiles: Vec<BrowserProfile>,
}

pub fn profile_metadata() -> ProfileMetadata {
    let mut latest_aliases = BTreeMap::new();
    latest_aliases.insert("chrome_latest", "chrome_147");

    ProfileMetadata {
        latest_aliases,
        profiles: vec![chrome_147()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_known_profile_ids() {
        assert!(resolve("chrome_147").is_some());
        assert!(resolve("chrome_unknown").is_none());
    }

    #[test]
    fn exposes_http2_setting_lookup() {
        let profile = chrome_147();

        assert_eq!(profile.http2.setting("header_table_size"), Some(65_536));
        assert_eq!(profile.http2.setting("missing"), None);
    }

    #[test]
    fn serializes_profile_metadata() {
        let value = serde_json::to_value(profile_metadata()).expect("metadata should serialize");

        assert_eq!(value["latest_aliases"]["chrome_latest"], "chrome_147");
        assert_eq!(value["profiles"][0]["id"], "chrome_147");
    }
}
