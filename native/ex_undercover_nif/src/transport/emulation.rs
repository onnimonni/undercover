use crate::error::RequestError;
use crate::profile::{BrowserProfile, Http2Profile, TlsProfile};
use crate::transport::plan::RequestPlan;
use brotli::{CompressorWriter, Decompressor};
use std::io::{self, Write};
use wreq::header::{HeaderMap, HeaderName, HeaderValue, OrigHeaderMap};
use wreq::http1::Http1Options;
use wreq::http2::{
    Http2Options, PseudoId, PseudoOrder, SettingId, SettingsOrder, StreamDependency, StreamId,
};
use wreq::tls::compress::{CertificateCompressionAlgorithm, CertificateCompressor, Codec};
use wreq::tls::{AlpnProtocol, AlpsProtocol, ExtensionType, KeyShare, TlsOptions, TlsVersion};
use wreq::Emulation;

#[derive(Debug)]
struct BrotliCertCompressor;

static BROTLI_CERT_COMPRESSOR: BrotliCertCompressor = BrotliCertCompressor;

impl CertificateCompressor for BrotliCertCompressor {
    fn compress(&self) -> Codec {
        Codec::Dynamic(Box::new(|input, output| {
            let mut writer = CompressorWriter::new(output, input.len(), 11, 22);
            writer.write_all(input)?;
            writer.flush()
        }))
    }

    fn decompress(&self) -> Codec {
        Codec::Dynamic(Box::new(|input, output| {
            let mut reader = Decompressor::new(input, 4096);
            io::copy(&mut reader, output)?;
            Ok(())
        }))
    }

    fn algorithm(&self) -> CertificateCompressionAlgorithm {
        CertificateCompressionAlgorithm::BROTLI
    }
}

pub fn build(plan: &RequestPlan, profile: &BrowserProfile) -> Result<Emulation, RequestError> {
    let (headers, orig_headers) = header_maps(plan)?;

    Ok(Emulation::builder()
        .tls_options(tls_options(&profile.tls)?)
        .http1_options(http1_options())
        .http2_options(http2_options(&profile.http2)?)
        .headers(headers)
        .orig_headers(orig_headers)
        .build(Default::default()))
}

pub fn protocol_name(version: http::Version) -> &'static str {
    match version {
        http::Version::HTTP_2 => "h2",
        http::Version::HTTP_3 => "h3",
        _ => "http/1.1",
    }
}

pub fn version_name(version: http::Version) -> &'static str {
    match version {
        http::Version::HTTP_09 => "http/0.9",
        http::Version::HTTP_10 => "http/1.0",
        http::Version::HTTP_11 => "http/1.1",
        http::Version::HTTP_2 => "h2",
        http::Version::HTTP_3 => "h3",
        _ => "unknown",
    }
}

fn header_maps(plan: &RequestPlan) -> Result<(HeaderMap, OrigHeaderMap), RequestError> {
    let mut headers = HeaderMap::new();
    let mut orig_headers = OrigHeaderMap::new();

    for (name, value) in &plan.headers {
        if managed_header(name) {
            continue;
        }

        let header_name = name
            .parse::<HeaderName>()
            .map_err(|err| RequestError::Protocol(err.to_string()))?;
        let header_value =
            HeaderValue::from_str(value).map_err(|err| RequestError::Protocol(err.to_string()))?;

        headers.insert(header_name, header_value);
        orig_headers.insert(name.clone());
    }

    Ok((headers, orig_headers))
}

fn managed_header(name: &str) -> bool {
    matches!(name, "connection" | "content-length" | "host")
}

fn http1_options() -> Http1Options {
    Http1Options::builder()
        .allow_obsolete_multiline_headers_in_responses(true)
        .max_headers(100)
        .build()
}

fn http2_options(profile: &Http2Profile) -> Result<Http2Options, RequestError> {
    let mut builder = Http2Options::builder();

    if let Some(value) = profile.setting("header_table_size") {
        builder = builder.header_table_size(value);
    }
    if let Some(value) = profile.setting("enable_push") {
        builder = builder.enable_push(value != 0);
    }
    if let Some(value) = profile.setting("max_concurrent_streams") {
        builder = builder.max_concurrent_streams(value);
    }
    if let Some(value) = profile.setting("initial_window_size") {
        builder = builder.initial_window_size(value);
    }
    if let Some(value) = profile.setting("max_frame_size") {
        builder = builder.max_frame_size(value);
    }
    if let Some(value) = profile.setting("max_header_list_size") {
        builder = builder.max_header_list_size(value);
    }
    if let Some(value) = profile.setting("enable_connect_protocol") {
        builder = builder.enable_connect_protocol(value != 0);
    }
    if let Some(value) = profile.setting("no_rfc7540_priorities") {
        builder = builder.no_rfc7540_priorities(value != 0);
    }
    if let Some(value) = profile.initial_stream_id {
        builder = builder.initial_stream_id(value);
    }
    if let Some(value) = profile.initial_connection_window_size {
        builder = builder.initial_connection_window_size(value);
    }
    if let Some(ref dependency) = profile.stream_dependency {
        builder = builder.headers_stream_dependency(StreamDependency::new(
            StreamId::from(dependency.stream_id),
            dependency.weight,
            dependency.exclusive,
        ));
    }

    builder = builder.headers_pseudo_order(pseudo_order(&profile.pseudo_header_order)?);
    builder = builder.settings_order(settings_order(&profile.settings_order)?);

    Ok(builder.build())
}

fn tls_options(profile: &TlsProfile) -> Result<TlsOptions, RequestError> {
    let mut builder = TlsOptions::builder()
        .min_tls_version(tls_version(&profile.min_version)?)
        .max_tls_version(tls_version(&profile.max_version)?)
        .pre_shared_key(profile.pre_shared_key)
        .enable_ech_grease(profile.ech_grease)
        .permute_extensions(profile.extension_permutation)
        .enable_ocsp_stapling(profile.ocsp_stapling)
        .enable_signed_cert_timestamps(profile.signed_cert_timestamps)
        .record_size_limit(profile.record_size_limit)
        .preserve_tls13_cipher_list(profile.preserve_tls13_cipher_list);

    if let Some(enabled) = profile.grease_enabled {
        builder = builder.grease_enabled(enabled);
    }
    if !profile.alpn.is_empty() {
        builder = builder.alpn_protocols(alpn_protocols(&profile.alpn)?);
    }
    if !profile.alps.is_empty() {
        builder = builder
            .alps_protocols(alps_protocols(&profile.alps)?)
            .alps_use_new_codepoint(profile.alps_use_new_codepoint);
    }
    if !profile.curves.is_empty() {
        builder = builder.curves_list(profile.curves.join(":"));
    }
    if !profile.cipher_suites.is_empty() {
        builder = builder.cipher_list(profile.cipher_suites.join(":"));
    }
    if !profile.delegated_credentials.is_empty() {
        builder = builder.delegated_credentials(profile.delegated_credentials.join(":"));
    }
    if !profile.signature_algorithms.is_empty() {
        builder = builder.sigalgs_list(profile.signature_algorithms.join(":"));
    }
    if !profile.key_share_groups.is_empty() {
        builder = builder.key_shares(key_shares(&profile.key_share_groups)?);
    }
    if !profile.extension_order.is_empty() {
        builder = builder.extension_permutation(extension_order(&profile.extension_order)?);
    }
    if !profile.certificate_compression.is_empty() {
        builder = builder
            .certificate_compressors(certificate_compressors(&profile.certificate_compression)?);
    }

    Ok(builder.build())
}

fn alpn_protocols(items: &[String]) -> Result<Vec<AlpnProtocol>, RequestError> {
    items.iter().map(|item| alpn_protocol(item)).collect()
}

fn alpn_protocol(value: &str) -> Result<AlpnProtocol, RequestError> {
    match value {
        "h2" => Ok(AlpnProtocol::HTTP2),
        "http/1.1" => Ok(AlpnProtocol::HTTP1),
        "h3" => Ok(AlpnProtocol::HTTP3),
        other => Err(RequestError::Protocol(format!(
            "unsupported ALPN protocol: {other}"
        ))),
    }
}

fn alps_protocols(items: &[String]) -> Result<Vec<AlpsProtocol>, RequestError> {
    items.iter().map(|item| alps_protocol(item)).collect()
}

fn alps_protocol(value: &str) -> Result<AlpsProtocol, RequestError> {
    match value {
        "h2" => Ok(AlpsProtocol::HTTP2),
        "http/1.1" => Ok(AlpsProtocol::HTTP1),
        "h3" => Ok(AlpsProtocol::HTTP3),
        other => Err(RequestError::Protocol(format!(
            "unsupported ALPS protocol: {other}"
        ))),
    }
}

fn tls_version(value: &str) -> Result<TlsVersion, RequestError> {
    match value {
        "tls1.0" => Ok(TlsVersion::TLS_1_0),
        "tls1.1" => Ok(TlsVersion::TLS_1_1),
        "tls1.2" => Ok(TlsVersion::TLS_1_2),
        "tls1.3" => Ok(TlsVersion::TLS_1_3),
        other => Err(RequestError::Protocol(format!(
            "unsupported TLS version: {other}"
        ))),
    }
}

fn key_shares(items: &[String]) -> Result<Vec<KeyShare>, RequestError> {
    items.iter().map(|item| key_share(item)).collect()
}

fn key_share(value: &str) -> Result<KeyShare, RequestError> {
    match value {
        "X25519MLKEM768" => Ok(KeyShare::X25519_MLKEM768),
        "X25519" => Ok(KeyShare::X25519),
        "P-256" => Ok(KeyShare::P256),
        "P-384" => Ok(KeyShare::P384),
        "P-521" => Ok(KeyShare::P521),
        other => Err(RequestError::Protocol(format!(
            "unsupported key share: {other}"
        ))),
    }
}

fn extension_order(items: &[String]) -> Result<Vec<ExtensionType>, RequestError> {
    items.iter().map(|item| extension(item)).collect()
}

fn extension(value: &str) -> Result<ExtensionType, RequestError> {
    match value {
        "server_name" => Ok(ExtensionType::SERVER_NAME),
        "extended_master_secret" => Ok(ExtensionType::EXTENDED_MASTER_SECRET),
        "renegotiate" => Ok(ExtensionType::RENEGOTIATE),
        "supported_groups" => Ok(ExtensionType::SUPPORTED_GROUPS),
        "ec_point_formats" => Ok(ExtensionType::EC_POINT_FORMATS),
        "session_ticket" => Ok(ExtensionType::SESSION_TICKET),
        "application_layer_protocol_negotiation" => {
            Ok(ExtensionType::APPLICATION_LAYER_PROTOCOL_NEGOTIATION)
        }
        "status_request" => Ok(ExtensionType::STATUS_REQUEST),
        "delegated_credential" => Ok(ExtensionType::DELEGATED_CREDENTIAL),
        "certificate_timestamp" => Ok(ExtensionType::CERTIFICATE_TIMESTAMP),
        "key_share" => Ok(ExtensionType::KEY_SHARE),
        "supported_versions" => Ok(ExtensionType::SUPPORTED_VERSIONS),
        "signature_algorithms" => Ok(ExtensionType::SIGNATURE_ALGORITHMS),
        "psk_key_exchange_modes" => Ok(ExtensionType::PSK_KEY_EXCHANGE_MODES),
        "record_size_limit" => Ok(ExtensionType::RECORD_SIZE_LIMIT),
        "cert_compression" => Ok(ExtensionType::CERT_COMPRESSION),
        "encrypted_client_hello" => Ok(ExtensionType::ENCRYPTED_CLIENT_HELLO),
        "padding" => Ok(ExtensionType::PADDING),
        other => Err(RequestError::Protocol(format!(
            "unsupported extension type: {other}"
        ))),
    }
}

fn certificate_compressors(
    items: &[String],
) -> Result<Vec<&'static dyn CertificateCompressor>, RequestError> {
    items
        .iter()
        .map(|item| certificate_compressor(item))
        .collect()
}

fn certificate_compressor(value: &str) -> Result<&'static dyn CertificateCompressor, RequestError> {
    match value {
        "brotli" => Ok(&BROTLI_CERT_COMPRESSOR),
        other => Err(RequestError::Protocol(format!(
            "unsupported certificate compressor: {other}"
        ))),
    }
}

fn pseudo_order(items: &[String]) -> Result<PseudoOrder, RequestError> {
    let mut order = PseudoOrder::builder();

    for item in items {
        order = order.push(pseudo_id(item)?);
    }

    Ok(order.build())
}

fn pseudo_id(value: &str) -> Result<PseudoId, RequestError> {
    match value {
        ":method" => Ok(PseudoId::Method),
        ":path" => Ok(PseudoId::Path),
        ":authority" => Ok(PseudoId::Authority),
        ":scheme" => Ok(PseudoId::Scheme),
        ":protocol" => Ok(PseudoId::Protocol),
        other => Err(RequestError::Protocol(format!(
            "unsupported pseudo-header: {other}"
        ))),
    }
}

fn settings_order(items: &[String]) -> Result<SettingsOrder, RequestError> {
    let mut order = SettingsOrder::builder();

    for item in items {
        order = order.push(setting_id(item)?);
    }

    Ok(order.build())
}

fn setting_id(value: &str) -> Result<SettingId, RequestError> {
    match value {
        "header_table_size" => Ok(SettingId::HeaderTableSize),
        "enable_push" => Ok(SettingId::EnablePush),
        "max_concurrent_streams" => Ok(SettingId::MaxConcurrentStreams),
        "initial_window_size" => Ok(SettingId::InitialWindowSize),
        "max_frame_size" => Ok(SettingId::MaxFrameSize),
        "max_header_list_size" => Ok(SettingId::MaxHeaderListSize),
        "enable_connect_protocol" => Ok(SettingId::EnableConnectProtocol),
        "no_rfc7540_priorities" => Ok(SettingId::NoRfc7540Priorities),
        other => Err(RequestError::Protocol(format!(
            "unsupported HTTP/2 setting id: {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::chrome_147;
    use crate::transport::plan::RequestPlan;

    fn request_plan() -> RequestPlan {
        let profile = chrome_147();

        RequestPlan {
            method: "GET".to_string(),
            url: "https://example.test/".to_string(),
            profile_id: profile.id.clone(),
            headers: profile.headers.clone(),
            alpn: profile.tls.alpn.clone(),
            pseudo_header_order: profile.http2.pseudo_header_order.clone(),
            http2_settings: profile.http2.settings.clone(),
            proxy_tunnel: None,
        }
    }

    #[test]
    fn builds_emulation_from_chrome_profile() {
        let profile = chrome_147();
        let plan = request_plan();

        assert!(build(&plan, &profile).is_ok());
    }

    #[test]
    fn identifies_managed_headers() {
        assert!(managed_header("host"));
        assert!(managed_header("connection"));
        assert!(!managed_header("user-agent"));
    }

    #[test]
    fn names_http_versions() {
        assert_eq!(protocol_name(http::Version::HTTP_2), "h2");
        assert_eq!(protocol_name(http::Version::HTTP_11), "http/1.1");
        assert_eq!(version_name(http::Version::HTTP_10), "http/1.0");
        assert_eq!(version_name(http::Version::HTTP_3), "h3");
    }

    #[test]
    fn compresses_and_decompresses_brotli_certificate_payloads() {
        let input = b"certificate-payload";
        let mut compressed = Vec::new();

        BROTLI_CERT_COMPRESSOR
            .compress(input, &mut compressed)
            .expect("compression should succeed");

        let mut decompressed = Vec::new();
        BROTLI_CERT_COMPRESSOR
            .decompress(&compressed, &mut decompressed)
            .expect("decompression should succeed");

        assert_eq!(decompressed, input);
        assert_eq!(
            BROTLI_CERT_COMPRESSOR.algorithm(),
            CertificateCompressionAlgorithm::BROTLI
        );
    }

    #[test]
    fn rejects_invalid_tls_and_http2_identifiers() {
        assert!(matches!(
            alpn_protocol("smtp"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            alps_protocol("smtp"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            tls_version("ssl3"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            key_share("bad-share"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            extension("bad-extension"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            certificate_compressor("gzip"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            pseudo_id(":status"),
            Err(RequestError::Protocol(_))
        ));
        assert!(matches!(
            setting_id("not_a_real_setting"),
            Err(RequestError::Protocol(_))
        ));
    }

    #[test]
    fn builds_header_maps_without_managed_headers() {
        let plan = RequestPlan {
            headers: vec![
                ("host".to_string(), "example.test".to_string()),
                ("user-agent".to_string(), "agent".to_string()),
                ("x-extra".to_string(), "1".to_string()),
            ],
            ..request_plan()
        };

        let (headers, _orig_headers) = header_maps(&plan).expect("header maps should build");

        assert!(!headers.contains_key("host"));
        assert!(headers.contains_key("user-agent"));
        assert!(headers.contains_key("x-extra"));
    }
}
