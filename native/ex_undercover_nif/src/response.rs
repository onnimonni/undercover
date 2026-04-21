use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Debug, Serialize)]
pub struct ResponsePayload {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub remote_address: String,
    pub diagnostics: BTreeMap<String, serde_json::Value>,
}
