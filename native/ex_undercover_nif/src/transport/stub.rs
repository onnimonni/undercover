use crate::error::RequestError;
use crate::profile::{self, BrowserProfile};
use crate::request::RequestPayload;
use crate::response::ResponsePayload;
use crate::transport::emulation;
use crate::transport::plan;
use crate::transport::BrowserTransport;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;
use tokio::runtime::Builder as RuntimeBuilder;
use wreq::tls::trust::CertStore;
use wreq::Client;

pub struct StubTransport;

impl BrowserTransport for StubTransport {
    fn dispatch(&self, payload: RequestPayload) -> Result<ResponsePayload, RequestError> {
        let plan = plan::build(&payload)?;
        let profile = payload
            .profile_data
            .clone()
            .or_else(|| profile::resolve(&payload.profile))
            .ok_or_else(|| RequestError::UnsupportedProfile(payload.profile.clone()))?;

        let runtime = RuntimeBuilder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|err| RequestError::Io(err.to_string()))?;

        runtime.block_on(dispatch_async(&plan, &profile, &payload))
    }
}

async fn dispatch_async(
    plan: &plan::RequestPlan,
    profile: &BrowserProfile,
    payload: &RequestPayload,
) -> Result<ResponsePayload, RequestError> {
    let emulation = emulation::build(plan, profile)?;
    let client = client_from_payload(payload)?;

    let method = http::Method::from_bytes(uppercase_method(&plan.method).as_bytes())
        .map_err(|err| RequestError::Protocol(err.to_string()))?;

    let mut request = client
        .request(method, plan.url.as_str())
        .emulation(emulation)
        .timeout(Duration::from_secs(45));

    if let Some(body) = payload.body.as_ref() {
        request = request.body(body.clone());
    }

    let response = request
        .send()
        .await
        .map_err(|err| RequestError::Protocol(err.to_string()))?;

    let status = response.status().as_u16();
    let version = response.version();
    let remote_address = response
        .remote_addr()
        .map(|addr| addr.to_string())
        .unwrap_or_default();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_ascii_lowercase(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect::<Vec<_>>();
    let body = response
        .text()
        .await
        .map_err(|err| RequestError::Protocol(err.to_string()))?;

    Ok(ResponsePayload {
        status,
        headers,
        body,
        remote_address,
        diagnostics: diagnostics(plan, payload, profile, version),
    })
}

fn client_from_payload(payload: &RequestPayload) -> Result<Client, RequestError> {
    let mut builder = Client::builder().connect_timeout(Duration::from_secs(15));

    // HTTP CONNECT proxy (e.g. fauxbrowser on http://127.0.0.1:18443).
    // Takes priority over proxy_tunnel / SO_BINDTODEVICE: the NIF applies
    // Chrome TLS fingerprinting; the proxy handles VPN routing over CONNECT.
    if let Some(proxy_url) = metadata_string(&payload.metadata, "proxy_url") {
        let proxy = wreq::Proxy::all(proxy_url)
            .map_err(|err| RequestError::Protocol(err.to_string()))?;
        builder = builder.proxy(proxy);
    } else {
        // No explicit proxy: disable env-var proxy detection and optionally
        // bind to a specific WireGuard interface via SO_BINDTODEVICE.
        builder = builder.no_proxy();
        // Bind to WireGuard interface if specified (SO_BINDTODEVICE on Linux).
        if let Some(iface) = &payload.proxy_tunnel {
            builder = builder.interface(iface.clone());
        }
    }

    if let Some(path) = metadata_string(&payload.metadata, "ca_cert_file") {
        let pem = fs::read(path).map_err(|err| RequestError::Io(err.to_string()))?;
        let store = CertStore::from_pem_stack(&pem)
            .map_err(|err| RequestError::Protocol(err.to_string()))?;
        builder = builder.tls_cert_store(store);
    } else if let Some(pem) = metadata_string(&payload.metadata, "ca_cert_pem") {
        let store = CertStore::from_pem_stack(pem.as_bytes())
            .map_err(|err| RequestError::Protocol(err.to_string()))?;
        builder = builder.tls_cert_store(store);
    }

    if let Some(enabled) = metadata_bool(&payload.metadata, "tls_cert_verification") {
        builder = builder.tls_cert_verification(enabled);
    }

    if let Some(enabled) = metadata_bool(&payload.metadata, "tls_verify_hostname") {
        builder = builder.tls_verify_hostname(enabled);
    }

    builder
        .build()
        .map_err(|err| RequestError::Protocol(err.to_string()))
}

fn diagnostics(
    plan: &plan::RequestPlan,
    payload: &RequestPayload,
    profile: &BrowserProfile,
    version: http::Version,
) -> BTreeMap<String, Value> {
    let mut diagnostics = BTreeMap::new();

    diagnostics.insert(
        "transport".to_string(),
        Value::String("wreq_boringssl".to_string()),
    );
    diagnostics.insert(
        "profile_id".to_string(),
        Value::String(plan.profile_id.clone()),
    );
    diagnostics.insert(
        "profile_version".to_string(),
        Value::String(profile.version.to_string()),
    );
    diagnostics.insert(
        "profile_alpn".to_string(),
        Value::Array(plan.alpn.iter().cloned().map(Value::String).collect()),
    );
    diagnostics.insert(
        "http_version".to_string(),
        Value::String(emulation::version_name(version).to_string()),
    );
    diagnostics.insert(
        "negotiated_alpn".to_string(),
        Value::String(emulation::protocol_name(version).to_string()),
    );
    diagnostics.insert(
        "pseudo_header_order".to_string(),
        Value::Array(
            plan.pseudo_header_order
                .iter()
                .cloned()
                .map(Value::String)
                .collect(),
        ),
    );
    diagnostics.insert(
        "http2_settings".to_string(),
        Value::Array(
            plan.http2_settings
                .iter()
                .map(|(name, value)| {
                    Value::Array(vec![
                        Value::String(name.clone()),
                        Value::Number((*value as u64).into()),
                    ])
                })
                .collect(),
        ),
    );
    diagnostics.insert(
        "request_header_count".to_string(),
        Value::Number((plan.headers.len() as u64).into()),
    );
    diagnostics.insert("has_body".to_string(), Value::Bool(payload.body.is_some()));
    diagnostics.insert(
        "proxy_tunnel_requested".to_string(),
        Value::Bool(payload.proxy_tunnel.is_some()),
    );
    diagnostics.insert(
        "proxy_url_requested".to_string(),
        Value::Bool(metadata_string(&payload.metadata, "proxy_url").is_some()),
    );
    diagnostics.insert(
        "metadata_keys".to_string(),
        Value::Array(
            payload
                .metadata
                .keys()
                .cloned()
                .map(Value::String)
                .collect(),
        ),
    );

    diagnostics
}

fn uppercase_method(method: &str) -> String {
    method.to_ascii_uppercase()
}

fn metadata_string<'a>(metadata: &'a BTreeMap<String, Value>, key: &str) -> Option<&'a str> {
    metadata.get(key)?.as_str()
}

fn metadata_bool(metadata: &BTreeMap<String, Value>, key: &str) -> Option<bool> {
    metadata.get(key)?.as_bool()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::chrome_147;
    use crate::request::RequestPayload;
    use crate::transport::plan::RequestPlan;

    fn payload() -> RequestPayload {
        RequestPayload {
            method: "get".to_string(),
            url: "https://example.test/".to_string(),
            headers: vec![],
            body: Some("payload".to_string()),
            profile: "chrome_147".to_string(),
            profile_data: None,
            proxy_tunnel: Some("wg0".to_string()),
            metadata: BTreeMap::from([
                ("tls_cert_verification".to_string(), Value::Bool(true)),
                ("tls_verify_hostname".to_string(), Value::Bool(true)),
            ]),
        }
    }

    fn plan() -> RequestPlan {
        let profile = chrome_147();

        RequestPlan {
            method: "GET".to_string(),
            url: "https://example.test/".to_string(),
            profile_id: profile.id.clone(),
            headers: profile.headers.clone(),
            alpn: profile.tls.alpn.clone(),
            pseudo_header_order: profile.http2.pseudo_header_order.clone(),
            http2_settings: profile.http2.settings.clone(),
            proxy_tunnel: Some("wg0".to_string()),
        }
    }

    #[test]
    fn builds_client_without_custom_ca_bundle() {
        assert!(client_from_payload(&payload()).is_ok());
    }

    #[test]
    fn rejects_missing_custom_ca_file() {
        let mut payload = payload();
        payload.metadata.insert(
            "ca_cert_file".to_string(),
            Value::String("/missing/cert.pem".to_string()),
        );

        assert!(matches!(
            client_from_payload(&payload),
            Err(RequestError::Io(_))
        ));
    }

    #[test]
    fn produces_transport_diagnostics() {
        let profile = chrome_147();
        let diagnostics = diagnostics(&plan(), &payload(), &profile, http::Version::HTTP_2);

        assert_eq!(diagnostics["transport"], "wreq_boringssl");
        assert_eq!(diagnostics["profile_id"], "chrome_147");
        assert_eq!(diagnostics["http_version"], "h2");
        assert_eq!(diagnostics["negotiated_alpn"], "h2");
        assert_eq!(diagnostics["has_body"], Value::Bool(true));
        assert_eq!(diagnostics["proxy_tunnel_requested"], Value::Bool(true));
    }

    #[test]
    fn extracts_metadata_values() {
        let metadata = BTreeMap::from([
            ("name".to_string(), Value::String("value".to_string())),
            ("enabled".to_string(), Value::Bool(false)),
        ]);

        assert_eq!(metadata_string(&metadata, "name"), Some("value"));
        assert_eq!(metadata_string(&metadata, "missing"), None);
        assert_eq!(metadata_bool(&metadata, "enabled"), Some(false));
        assert_eq!(metadata_bool(&metadata, "missing"), None);
        assert_eq!(uppercase_method("post"), "POST");
    }
}
