package main

import (
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServerTimeouts(t *testing.T) {
	for _, tlsConfig := range []*tls.Config{nil, {}} {
		server := newHTTPServer(8443, http.NotFoundHandler(), tlsConfig, 5*time.Second, 10*time.Second)
		if server.ReadHeaderTimeout != 5*time.Second ||
			server.ReadTimeout != 10*time.Second ||
			server.WriteTimeout != 10*time.Second {
			t.Fatalf("expected five-second TLS and ten-second HTTP deadlines: %+v", server)
		}
		if server.IdleTimeout != 120*time.Second {
			t.Fatalf("idle keep-alive timeout changed: %s", server.IdleTimeout)
		}
		if server.TLSConfig != tlsConfig {
			t.Fatal("TLS configuration was not preserved")
		}
	}
}

func TestConfiguredGroups(t *testing.T) {
	for name, want := range map[string]tls.CurveID{"": tls.CurveP256, "P-256": tls.CurveP256, "X25519": tls.X25519} {
		got, err := configuredCurve(name)
		if err != nil || got != want {
			t.Fatalf("configuredCurve(%q) = %v, %v", name, got, err)
		}
		srv := newTestServer(t, true)
		req := httptest.NewRequest(http.MethodGet, "/meta", nil)
		req.TLS = &tls.ConnectionState{Version: tls.VersionTLS12, CurveID: got}
		w := httptest.NewRecorder()
		srv.HandleMeta(w, req)
		var meta MetaResponse
		if err := json.Unmarshal(w.Body.Bytes(), &meta); err != nil {
			t.Fatal(err)
		}
		if name != "" && meta.KeyExchangeGroup != name {
			t.Fatalf("metadata reports %q, negotiated %q", meta.KeyExchangeGroup, name)
		}
	}
	if _, err := configuredCurve("P-384"); err == nil {
		t.Fatal("invalid group accepted")
	}
	cfg := &Config{PlaintextPort: 8080, TLS: &TLSConfig{Enabled: true, Group: "P-384"}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("invalid group accepted by config validation")
	}
}

func newTestServer(t *testing.T, prealloc bool) *Server {
	t.Helper()
	cfg := &Config{
		PlaintextPort: 8080,
		Payload: &PayloadConfig{
			Preallocate: prealloc,
		},
		Timeouts: &TimeoutConfig{
			TLSHandshakeSeconds: 5,
			HTTPRequestSeconds:  10,
		},
	}
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatalf("NewServer failed: %v", err)
	}
	return srv
}

func TestPing(t *testing.T) {
	srv := newTestServer(t, true)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	w := httptest.NewRecorder()
	srv.HandlePing(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var resp PingResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if !resp.Pong || resp.Stack != "go" || resp.Host == "" {
		t.Fatalf("unexpected ping response: %+v", resp)
	}
}

func TestPayload(t *testing.T) {
	for _, prealloc := range []bool{true, false} {
		srv := newTestServer(t, prealloc)

		for _, size := range []string{"1024", "65536", "1048576"} {
			req := httptest.NewRequest(http.MethodGet, "/payload?bytes="+size, nil)
			w := httptest.NewRecorder()
			srv.HandlePayload(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("expected 200 for %s (prealloc=%v), got %d", size, prealloc, w.Code)
			}
			if w.Header().Get("Content-Type") != "application/octet-stream" {
				t.Fatalf("expected application/octet-stream, got %s", w.Header().Get("Content-Type"))
			}
			if w.Header().Get("Content-Length") != size {
				t.Fatalf("expected content-length %s, got %s", size, w.Header().Get("Content-Length"))
			}
			expectedLen := 0
			switch size {
			case "1024":
				expectedLen = 1024
			case "65536":
				expectedLen = 65536
			case "1048576":
				expectedLen = 1048576
			}
			if w.Body.Len() != expectedLen {
				t.Fatalf("expected body len %d, got %d", expectedLen, w.Body.Len())
			}
		}

		// 400 test cases
		for _, invalid := range []string{"", "512", "2048", "abc", "-1", "999999"} {
			req := httptest.NewRequest(http.MethodGet, "/payload?bytes="+invalid, nil)
			w := httptest.NewRecorder()
			srv.HandlePayload(w, req)

			if w.Code != http.StatusBadRequest {
				t.Fatalf("expected 400 for bytes=%s, got %d", invalid, w.Code)
			}
		}
	}
}

func TestHealthz(t *testing.T) {
	srv := newTestServer(t, true)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	srv.HandleHealthz(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if w.Body.String() != "ok" {
		t.Fatalf("expected ok, got %s", w.Body.String())
	}
}

func TestMeta(t *testing.T) {
	srv := newTestServer(t, true)
	req := httptest.NewRequest(http.MethodGet, "/meta", nil)
	w := httptest.NewRecorder()
	srv.HandleMeta(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var resp MetaResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if resp.Stack != "go" || resp.NumCPU < 1 {
		t.Fatalf("unexpected meta response: %+v", resp)
	}
	if resp.OSSource == "unexposed-by-runtime" {
		if resp.OS != "unexposed-by-runtime" {
			t.Fatal("missing OS evidence must not be inferred")
		}
	} else {
		contents, err := os.ReadFile(resp.OSSource)
		if err != nil || resp.OS != string(contents) {
			t.Fatalf("metadata must preserve runtime OS-release text: %v", err)
		}
	}
	if resp.TLSTerminatedHere {
		t.Fatalf("expected TLSTerminatedHere=false for plaintext request")
	}
	if !resp.PayloadPreallocate {
		t.Fatalf("expected PayloadPreallocate=true")
	}
	if resp.TLSResumption ||
		resp.TLSHandshakeTimeout != 5 ||
		resp.HTTPRequestTimeout != 10 {
		t.Fatalf("unexpected TLS timeout metadata: %+v", resp)
	}
}

func TestConfigValidation(t *testing.T) {
	// Invalid plaintext port
	cfg := &Config{
		PlaintextPort: 0,
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error for invalid plaintextPort")
	}

	// Existing handwritten configurations retain the deployment defaults.
	cfg = &Config{PlaintextPort: 8080}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected default timeouts to be valid: %v", err)
	}
	if cfg.Timeouts.TLSHandshakeSeconds != 5 || cfg.Timeouts.HTTPRequestSeconds != 10 {
		t.Fatalf("unexpected default timeouts: %+v", cfg.Timeouts)
	}

	for _, timeouts := range []*TimeoutConfig{
		{TLSHandshakeSeconds: 0, HTTPRequestSeconds: 5},
		{TLSHandshakeSeconds: 5, HTTPRequestSeconds: 301},
	} {
		cfg = &Config{PlaintextPort: 8080, Timeouts: timeouts}
		if err := cfg.Validate(); err == nil {
			t.Fatalf("expected error for invalid timeouts: %+v", timeouts)
		}
	}

	// TLS enabled: false does not require certs/keys
	cfg = &Config{
		PlaintextPort: 8080,
		TLS: &TLSConfig{
			Enabled: false,
		},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected valid config when tls.enabled=false, got: %v", err)
	}

	// TLS enabled: true requires valid port and version
	cfg = &Config{
		PlaintextPort: 8080,
		TLS: &TLSConfig{
			Enabled: true,
			Port:    0,
			Version: "1.2",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error for invalid tls.port")
	}

	// Invalid TLS version (e.g. 1.20)
	cfg = &Config{
		PlaintextPort: 8080,
		TLS: &TLSConfig{
			Enabled:  true,
			Port:     8443,
			Version:  "1.20",
			CertFile: "nonexistent",
			KeyFile:  "nonexistent",
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error for invalid TLS version '1.20'")
	}
}

func TestUnknownFieldsDisallowed(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	// JSON containing an unknown field
	content := `{
		"tlsPort": 8443,
		"plaintextPort": 8080,
		"unknownField": "should_fail"
	}`
	if err := os.WriteFile(configPath, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write test config: %v", err)
	}

	_, err := LoadConfig(configPath)
	if err == nil {
		t.Fatal("expected error for unknown field in config, got nil")
	}
}
