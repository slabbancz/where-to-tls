package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

type TLSConfig struct {
	Enabled    bool   `json:"enabled"`
	Port       int    `json:"port"`
	Version    string `json:"version"`
	Group      string `json:"group"`
	Resumption bool   `json:"resumption"`
	CertFile   string `json:"certFile"`
	KeyFile    string `json:"keyFile"`
}

type PayloadConfig struct {
	Preallocate bool `json:"preallocate"`
}

type TimeoutConfig struct {
	TLSHandshakeSeconds int `json:"tlsHandshakeSeconds"`
	HTTPRequestSeconds  int `json:"httpRequestSeconds"`
}

type Config struct {
	PlaintextPort int            `json:"plaintextPort"`
	TLS           *TLSConfig     `json:"tls,omitempty"`
	Payload       *PayloadConfig `json:"payload,omitempty"`
	Timeouts      *TimeoutConfig `json:"timeouts,omitempty"`
}

func (c *Config) Validate() error {
	if c.PlaintextPort <= 0 || c.PlaintextPort > 65535 {
		return fmt.Errorf("config error: invalid plaintextPort %d", c.PlaintextPort)
	}
	if c.Timeouts == nil {
		c.Timeouts = &TimeoutConfig{
			TLSHandshakeSeconds: 5,
			HTTPRequestSeconds:  10,
		}
	}
	if c.Timeouts.TLSHandshakeSeconds < 1 || c.Timeouts.TLSHandshakeSeconds > 300 {
		return fmt.Errorf("config error: timeouts.tlsHandshakeSeconds must be from 1 through 300")
	}
	if c.Timeouts.HTTPRequestSeconds < 1 || c.Timeouts.HTTPRequestSeconds > 300 {
		return fmt.Errorf("config error: timeouts.httpRequestSeconds must be from 1 through 300")
	}

	if c.TLS != nil && c.TLS.Enabled {
		if c.TLS.Group == "" {
			c.TLS.Group = "P-256"
		}
		if c.TLS.Group != "P-256" && c.TLS.Group != "X25519" {
			return fmt.Errorf("config error: tls.group must be P-256 or X25519")
		}
		if c.TLS.Port <= 0 || c.TLS.Port > 65535 {
			return fmt.Errorf("config error: invalid tls.port %d", c.TLS.Port)
		}
		if c.TLS.Version != "1.2" && c.TLS.Version != "1.3" {
			return fmt.Errorf("config error: invalid tls.version '%s'. Must be exactly '1.2' or '1.3' (Contract §3)", c.TLS.Version)
		}
		if c.TLS.CertFile == "" {
			return errors.New("config error: tls.certFile cannot be empty")
		}
		if _, err := os.Stat(c.TLS.CertFile); err != nil {
			return fmt.Errorf("config error: tls.certFile '%s' not accessible: %w", c.TLS.CertFile, err)
		}
		if c.TLS.KeyFile == "" {
			return errors.New("config error: tls.keyFile cannot be empty")
		}
		if _, err := os.Stat(c.TLS.KeyFile); err != nil {
			return fmt.Errorf("config error: tls.keyFile '%s' not accessible: %w", c.TLS.KeyFile, err)
		}
	}
	return nil
}

func LoadConfig(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file %s: %w", path, err)
	}
	defer f.Close()

	decoder := json.NewDecoder(f)
	// Contract §2a: Unknown fields are an error, not a warning
	decoder.DisallowUnknownFields()

	var cfg Config
	if err := decoder.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("invalid config JSON in %s: %w", path, err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return &cfg, nil
}
