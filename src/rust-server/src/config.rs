use std::path::Path;

use serde::Deserialize;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub plaintext_port: u16,
    pub tls: Option<TlsConfig>,
    #[serde(default)]
    pub payload: PayloadConfig,
    #[serde(default)]
    pub timeouts: TimeoutConfig,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TlsConfig {
    pub enabled: bool,
    pub port: u16,
    pub version: String,
    #[serde(default = "default_group")]
    pub group: String,
    pub resumption: bool,
    pub cert_file: String,
    pub key_file: String,
}

#[derive(Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PayloadConfig {
    #[serde(default)]
    pub preallocate: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TimeoutConfig {
    #[serde(default = "default_tls_timeout")]
    pub tls_handshake_seconds: u64,
    #[serde(default = "default_http_timeout")]
    pub http_request_seconds: u64,
}

impl Default for TimeoutConfig {
    fn default() -> Self {
        Self {
            tls_handshake_seconds: default_tls_timeout(),
            http_request_seconds: default_http_timeout(),
        }
    }
}

fn default_group() -> String {
    "P-256".into()
}

const fn default_tls_timeout() -> u64 {
    5
}

const fn default_http_timeout() -> u64 {
    10
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = std::fs::read(path)
            .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        let config: Self = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid config JSON in {}: {error}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), String> {
        if self.plaintext_port == 0 {
            return Err("config error: plaintextPort must be greater than zero".into());
        }
        for (name, value) in [
            ("tlsHandshakeSeconds", self.timeouts.tls_handshake_seconds),
            ("httpRequestSeconds", self.timeouts.http_request_seconds),
        ] {
            if !(1..=300).contains(&value) {
                return Err(format!(
                    "config error: timeouts.{name} must be from 1 through 300"
                ));
            }
        }

        if let Some(tls) = self.tls.as_ref().filter(|tls| tls.enabled) {
            if tls.port == 0 {
                return Err("config error: tls.port must be greater than zero".into());
            }
            if !matches!(tls.version.as_str(), "1.2" | "1.3") {
                return Err("config error: tls.version must be 1.2 or 1.3".into());
            }
            if !matches!(tls.group.as_str(), "P-256" | "X25519") {
                return Err("config error: tls.group must be P-256 or X25519".into());
            }
            for (name, path) in [("certFile", &tls.cert_file), ("keyFile", &tls.key_file)] {
                if !Path::new(path).is_file() {
                    return Err(format!(
                        "config error: tls.{name} '{path}' is not accessible"
                    ));
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config {
            plaintext_port: 8080,
            tls: None,
            payload: PayloadConfig::default(),
            timeouts: TimeoutConfig::default(),
        }
    }

    #[test]
    fn accepts_plaintext_defaults() {
        assert!(config().validate().is_ok());
    }

    #[test]
    fn rejects_unknown_fields() {
        let result = serde_json::from_str::<Config>(
            r#"{"plaintextPort":8080,"payload":{},"timeouts":{},"unexpected":true}"#,
        );
        assert!(result.is_err());
    }

    #[test]
    fn rejects_invalid_timeout() {
        let mut value = config();
        value.timeouts.tls_handshake_seconds = 0;
        assert_eq!(
            value.validate().unwrap_err(),
            "config error: timeouts.tlsHandshakeSeconds must be from 1 through 300"
        );
    }
}
