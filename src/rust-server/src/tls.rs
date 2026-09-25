use std::{fs::File, io::BufReader, sync::Arc};

use rustls::{
    ServerConfig,
    crypto::ring::{cipher_suite, kx_group},
    pki_types::{CertificateDer, PrivateKeyDer},
    version::{TLS12, TLS13},
};

use crate::config::TlsConfig;

#[derive(Clone)]
pub struct ConnectionInfo {
    pub tls_version: String,
    pub cipher_suite: String,
    pub key_exchange_group: String,
}

pub fn build_config(config: &TlsConfig) -> Result<ServerConfig, String> {
    let mut provider = rustls::crypto::ring::default_provider();
    provider.kx_groups = match config.group.as_str() {
        "P-256" => vec![kx_group::SECP256R1],
        "X25519" => vec![kx_group::X25519],
        _ => return Err("tls.group must be P-256 or X25519".into()),
    };
    provider.cipher_suites = match config.version.as_str() {
        "1.2" => vec![cipher_suite::TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256],
        "1.3" => vec![cipher_suite::TLS13_AES_128_GCM_SHA256],
        _ => return Err("tls.version must be 1.2 or 1.3".into()),
    };
    let versions = match config.version.as_str() {
        "1.2" => &[&TLS12][..],
        "1.3" => &[&TLS13][..],
        _ => unreachable!(),
    };
    let mut tls = ServerConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(versions)
        .map_err(|error| format!("invalid TLS provider configuration: {error}"))?
        .with_no_client_auth()
        .with_single_cert(
            load_certificates(&config.cert_file)?,
            load_private_key(&config.key_file)?,
        )
        .map_err(|error| format!("failed to configure TLS certificate: {error}"))?;
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    if !config.resumption {
        tls.send_tls13_tickets = 0;
        tls.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
    }
    Ok(tls)
}

pub fn connection_info(session: &rustls::ServerConnection) -> ConnectionInfo {
    ConnectionInfo {
        tls_version: match session.protocol_version() {
            Some(rustls::ProtocolVersion::TLSv1_2) => "1.2".into(),
            Some(rustls::ProtocolVersion::TLSv1_3) => "1.3".into(),
            _ => "unknown".into(),
        },
        cipher_suite: session
            .negotiated_cipher_suite()
            .map_or_else(|| "unknown".into(), |suite| format!("{:?}", suite.suite())),
        key_exchange_group: session.negotiated_key_exchange_group().map_or_else(
            || "unexposed-by-runtime".into(),
            |group| match group.name() {
                rustls::NamedGroup::secp256r1 => "P-256".into(),
                rustls::NamedGroup::X25519 => "X25519".into(),
                other => format!("{other:?}"),
            },
        ),
    }
}

fn load_certificates(path: &str) -> Result<Vec<CertificateDer<'static>>, String> {
    let file = File::open(path).map_err(|error| format!("failed to open certificate: {error}"))?;
    rustls_pemfile::certs(&mut BufReader::new(file))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to parse certificate: {error}"))
}

fn load_private_key(path: &str) -> Result<PrivateKeyDer<'static>, String> {
    let file = File::open(path).map_err(|error| format!("failed to open private key: {error}"))?;
    rustls_pemfile::private_key(&mut BufReader::new(file))
        .map_err(|error| format!("failed to parse private key: {error}"))?
        .ok_or_else(|| "private key file contains no supported key".into())
}
