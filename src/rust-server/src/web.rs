use std::{env, path::Path, sync::Arc};

use bytes::Bytes;
use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode,
    body::Incoming,
    header::{CONTENT_LENGTH, CONTENT_TYPE},
};
use serde::Serialize;

use crate::{config::Config, runtime_os, tls::ConnectionInfo};

pub type Body = Full<Bytes>;

pub struct AppState {
    pub config: Config,
    hostname: String,
    payloads: [Bytes; 3],
    ping: Bytes,
}

#[derive(Serialize)]
struct Ping<'a> {
    pong: bool,
    stack: &'a str,
    host: &'a str,
}

#[derive(Serialize)]
struct Meta<'a> {
    stack: &'a str,
    runtime_version: &'a str,
    upstream_runtime_image: String,
    upstream_runtime_digest: String,
    tls_runtime: String,
    tls_runtime_version: &'a str,
    os: String,
    os_source: String,
    tls_terminated_here: bool,
    tls_version: &'a str,
    cipher_suite: &'a str,
    key_exchange_group: &'a str,
    tls_resumption: bool,
    tls_handshake_timeout_seconds: u64,
    http_request_timeout_seconds: u64,
    http_versions: Vec<&'a str>,
    hostname: &'a str,
    num_cpu: usize,
    payload_preallocate: bool,
}

impl AppState {
    pub fn new(config: Config) -> Result<Self, String> {
        let hostname = env::var("HOSTNAME").unwrap_or_else(|_| "localhost".into());
        let ping = serde_json::to_vec(&Ping {
            pong: true,
            stack: "rust",
            host: &hostname,
        })
        .map(Bytes::from)
        .map_err(|error| format!("failed to encode ping response: {error}"))?;
        Ok(Self {
            config,
            hostname,
            payloads: [
                Bytes::from(vec![b'x'; 1024]),
                Bytes::from(vec![b'x'; 65_536]),
                Bytes::from(vec![b'x'; 1_048_576]),
            ],
            ping,
        })
    }
}

pub async fn handle(request: Request<Incoming>, state: Arc<AppState>) -> Response<Body> {
    if request.method() != Method::GET {
        return response(
            StatusCode::METHOD_NOT_ALLOWED,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"Method Not Allowed"),
        );
    }

    match request.uri().path() {
        "/healthz" => response(
            StatusCode::OK,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"ok"),
        ),
        "/ping" => response(StatusCode::OK, "application/json", state.ping.clone()),
        "/payload" => payload_response(&request, &state),
        "/meta" => meta_response(&request, &state),
        _ => response(
            StatusCode::NOT_FOUND,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"Not Found"),
        ),
    }
}

pub fn response(status: StatusCode, content_type: &'static str, body: Bytes) -> Response<Body> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, content_type)
        .header(CONTENT_LENGTH, body.len())
        .body(Full::new(body))
        .expect("static response headers are valid")
}

fn payload_response(request: &Request<Incoming>, state: &AppState) -> Response<Body> {
    let size = request
        .uri()
        .query()
        .and_then(|query| {
            query
                .split('&')
                .find_map(|pair| pair.strip_prefix("bytes="))
        })
        .and_then(|value| value.parse::<usize>().ok());
    let payload = match size {
        Some(1024) => Some((0, 1024)),
        Some(65_536) => Some((1, 65_536)),
        Some(1_048_576) => Some((2, 1_048_576)),
        _ => None,
    };
    match payload {
        Some((index, size)) => {
            let body = if state.config.payload.preallocate {
                state.payloads[index].clone()
            } else {
                Bytes::from(vec![b'x'; size])
            };
            response(StatusCode::OK, "application/octet-stream", body)
        }
        None => response(
            StatusCode::BAD_REQUEST,
            "application/json",
            Bytes::from_static(b"{\"error\":\"bytes must be one of 1024, 65536, 1048576\"}"),
        ),
    }
}

fn meta_response(request: &Request<Incoming>, state: &AppState) -> Response<Body> {
    let tls = request.extensions().get::<ConnectionInfo>();
    let (tls_version, cipher_suite, key_exchange_group) = tls
        .map(|info| {
            (
                info.tls_version.as_str(),
                info.cipher_suite.as_str(),
                info.key_exchange_group.as_str(),
            )
        })
        .unwrap_or(("none", "none", "none"));
    let os = match runtime_os::read(&[Path::new("/etc/os-release"), Path::new("/usr/lib/os-release")]) {
        Ok(os) => os,
        Err(error) => {
            return response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "text/plain; charset=utf-8",
                Bytes::from(format!("failed to read runtime OS evidence: {error}")),
            );
        }
    };
    let meta = Meta {
        stack: "rust",
        runtime_version: env!("RUSTC_VERSION"),
        upstream_runtime_image: require_runtime_provenance("WTT_UPSTREAM_RUNTIME_IMAGE"),
        upstream_runtime_digest: require_runtime_provenance("WTT_UPSTREAM_RUNTIME_DIGEST"),
        tls_runtime: tls_runtime_name(),
        tls_runtime_version: env!("RUSTLS_VERSION"),
        os: os.name,
        os_source: os.source,
        tls_terminated_here: tls.is_some(),
        tls_version,
        cipher_suite,
        key_exchange_group,
        tls_resumption: state.config.tls.as_ref().is_some_and(|tls| tls.resumption),
        tls_handshake_timeout_seconds: state.config.timeouts.tls_handshake_seconds,
        http_request_timeout_seconds: state.config.timeouts.http_request_seconds,
        http_versions: if tls.is_some() {
            vec!["1.1", "2"]
        } else {
            vec!["1.1"]
        },
        hostname: &state.hostname,
        num_cpu: std::thread::available_parallelism().map_or(1, usize::from),
        payload_preallocate: state.config.payload.preallocate,
    };
    match serde_json::to_vec(&meta) {
        Ok(body) => response(StatusCode::OK, "application/json", Bytes::from(body)),
        Err(_) => response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"Internal Server Error"),
        ),
    }
}

fn require_runtime_provenance(name: &str) -> String {
    env::var(name).unwrap_or_else(|_| panic!("{name} is required in the server image"))
}

fn tls_runtime_name() -> String {
    std::any::type_name::<rustls::ServerConfig>()
        .split("::")
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| panic!("rustls ServerConfig type did not expose a crate name"))
        .to_owned()
}
