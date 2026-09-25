use std::{convert::Infallible, io, sync::Arc, time::Duration};

use bytes::Bytes;
use hyper::{Request, StatusCode, body::Incoming, service::service_fn};
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server::conn::auto::Builder,
};
use tokio::{net::TcpListener, task::JoinSet, time::timeout};
use tokio_rustls::TlsAcceptor;

use crate::{
    config::Config,
    tls,
    web::{AppState, handle, response},
};

pub async fn run(config: Config) -> Result<(), String> {
    let state = Arc::new(AppState::new(config.clone())?);
    let plain = TcpListener::bind(("0.0.0.0", config.plaintext_port))
        .await
        .map_err(|error| format!("failed to bind plaintext listener: {error}"))?;

    let mut tasks = JoinSet::new();
    tasks.spawn(serve_plain(plain, state.clone()));
    let tls_port = if let Some(tls_config) = config.tls.as_ref().filter(|tls| tls.enabled) {
        let listener = TcpListener::bind(("0.0.0.0", tls_config.port))
            .await
            .map_err(|error| format!("failed to bind TLS listener: {error}"))?;
        let acceptor = TlsAcceptor::from(Arc::new(tls::build_config(tls_config)?));
        tasks.spawn(serve_tls(
            listener,
            acceptor,
            state,
            Duration::from_secs(config.timeouts.tls_handshake_seconds),
        ));
        tls_config.port
    } else {
        0
    };
    eprintln!(
        "[rust-server] starting plaintext=:{} tls=:{} preallocate={}",
        config.plaintext_port, tls_port, config.payload.preallocate
    );

    tokio::select! {
        result = tasks.join_next() => {
            match result {
                Some(Ok(Err(error))) => return Err(format!("listener failed: {error}")),
                Some(Err(error)) => return Err(format!("listener task failed: {error}")),
                _ => return Err("listener stopped unexpectedly".into()),
            }
        }
        result = shutdown_signal() => {
            result?;
            eprintln!("[rust-server] shutting down");
        }
    }

    async fn shutdown_signal() -> Result<(), String> {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .map_err(|error| format!("failed to register SIGTERM handler: {error}"))?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                result.map_err(|error| format!("failed to wait for Ctrl-C: {error}"))
            }
            _ = terminate.recv() => Ok(()),
        }
    }
    tasks.abort_all();
    Ok(())
}

async fn serve_plain(listener: TcpListener, state: Arc<AppState>) -> io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let state = state.clone();
        tokio::spawn(async move {
            let service = service_fn(move |request| request_with_timeout(request, state.clone()));
            if let Err(error) = Builder::new(TokioExecutor::new())
                .serve_connection(TokioIo::new(stream), service)
                .await
            {
                eprintln!("[rust-server] plaintext connection error: {error}");
            }
        });
    }
}

async fn serve_tls(
    listener: TcpListener,
    acceptor: TlsAcceptor,
    state: Arc<AppState>,
    handshake_timeout: Duration,
) -> io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let state = state.clone();
        let acceptor = acceptor.clone();
        tokio::spawn(async move {
            let stream = match timeout(handshake_timeout, acceptor.accept(stream)).await {
                Ok(Ok(stream)) => stream,
                Ok(Err(error)) => {
                    eprintln!("[rust-server] TLS handshake failed: {error}");
                    return;
                }
                Err(_) => {
                    eprintln!("[rust-server] TLS handshake timed out");
                    return;
                }
            };
            let info = tls::connection_info(stream.get_ref().1);
            let service = service_fn(move |mut request: Request<Incoming>| {
                request.extensions_mut().insert(info.clone());
                request_with_timeout(request, state.clone())
            });
            if let Err(error) = Builder::new(TokioExecutor::new())
                .serve_connection(TokioIo::new(stream), service)
                .await
            {
                eprintln!("[rust-server] TLS connection error: {error}");
            }
        });
    }
}

async fn request_with_timeout(
    request: Request<Incoming>,
    state: Arc<AppState>,
) -> Result<hyper::Response<crate::web::Body>, Infallible> {
    let duration = Duration::from_secs(state.config.timeouts.http_request_seconds);
    let response = timeout(duration, handle(request, state))
        .await
        .unwrap_or_else(|_| {
            response(
                StatusCode::REQUEST_TIMEOUT,
                "text/plain; charset=utf-8",
                Bytes::from_static(b"Request Timeout"),
            )
        });
    Ok(response)
}
