mod config;
mod runtime_os;
mod server;
mod tls;
mod web;

use std::{env, path::Path};

use config::Config;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("[rust-server] FATAL: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let config_path = match (args.next().as_deref(), args.next(), args.next()) {
        (None, _, _) => "/etc/wtt/config.json".into(),
        (Some("--config"), Some(path), None) => path,
        _ => return Err("usage: rust-server [--config <path>]".into()),
    };
    server::run(Config::load(Path::new(&config_path))?).await
}
