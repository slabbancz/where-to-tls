package main

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"reflect"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

type PingResponse struct {
	Pong  bool   `json:"pong"`
	Stack string `json:"stack"`
	Host  string `json:"host"`
}

type MetaResponse struct {
	Stack                 string   `json:"stack"`
	RuntimeVersion        string   `json:"runtime_version"`
	UpstreamRuntimeImage  string   `json:"upstream_runtime_image"`
	UpstreamRuntimeDigest string   `json:"upstream_runtime_digest"`
	TLSRuntime            string   `json:"tls_runtime"`
	TLSRuntimeVersion     string   `json:"tls_runtime_version"`
	OS                    string   `json:"os"`
	OSSource              string   `json:"os_source"`
	TLSTerminatedHere     bool     `json:"tls_terminated_here"`
	TLSVersion            string   `json:"tls_version"`
	CipherSuite           string   `json:"cipher_suite"`
	KeyExchangeGroup      string   `json:"key_exchange_group"`
	TLSResumption         bool     `json:"tls_resumption"`
	TLSHandshakeTimeout   int      `json:"tls_handshake_timeout_seconds"`
	HTTPRequestTimeout    int      `json:"http_request_timeout_seconds"`
	HTTPVersions          []string `json:"http_versions"`
	Hostname              string   `json:"hostname"`
	NumCPU                int      `json:"num_cpu"`
	PayloadPreallocate    bool     `json:"payload_preallocate"`
}

type Server struct {
	cfg         *Config
	payloads    *PayloadStore
	hostname    string
	pingJSON    []byte
	preallocate bool
}

func newHTTPServer(
	port int,
	handler http.Handler,
	tlsConfig *tls.Config,
	tlsHandshakeTimeout time.Duration,
	httpTimeout time.Duration,
) *http.Server {
	return &http.Server{
		Addr:              fmt.Sprintf(":%d", port),
		Handler:           handler,
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: tlsHandshakeTimeout,
		ReadTimeout:       httpTimeout,
		WriteTimeout:      httpTimeout,
		IdleTimeout:       120 * time.Second,
	}
}

func NewServer(cfg *Config) (*Server, error) {
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "localhost"
	}

	prealloc := true
	if cfg.Payload != nil {
		prealloc = cfg.Payload.Preallocate
	}

	pingBytes, err := json.Marshal(PingResponse{
		Pong:  true,
		Stack: "go",
		Host:  hostname,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to precompute ping JSON: %w", err)
	}

	return &Server{
		cfg:         cfg,
		payloads:    NewPayloadStore(prealloc),
		hostname:    hostname,
		pingJSON:    pingBytes,
		preallocate: prealloc,
	}, nil
}

func (s *Server) HandlePing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(s.pingJSON)
}

func (s *Server) HandlePayload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	bytesParam := r.URL.Query().Get("bytes")
	numBytes, err := strconv.Atoi(bytesParam)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bytes must be one of 1024, 65536, 1048576"}`))
		return
	}

	buf, ok := s.payloads.Get(numBytes)
	if !ok {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bytes must be one of 1024, 65536, 1048576"}`))
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(numBytes))
	w.WriteHeader(http.StatusOK)
	w.Write(buf)
}

func (s *Server) HandleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func (s *Server) HandleMeta(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	isTLS := r.TLS != nil
	tlsVer := "none"
	cipherSuite := "none"
	httpVers := []string{"1.1"}

	if isTLS {
		httpVers = []string{"1.1", "2"}
		switch r.TLS.Version {
		case tls.VersionTLS13:
			tlsVer = "1.3"
		case tls.VersionTLS12:
			tlsVer = "1.2"
		default:
			tlsVer = fmt.Sprintf("0x%04x", r.TLS.Version)
		}

		cipherSuite = tls.CipherSuiteName(r.TLS.CipherSuite)
		if cipherSuite == "" {
			cipherSuite = fmt.Sprintf("0x%04x", r.TLS.CipherSuite)
		}
	}

	keyExchangeGroup := "none"
	if isTLS {
		keyExchangeGroup = "unexposed-by-runtime"
		// Contract §3: Read negotiated key exchange group from live connection
		switch r.TLS.CurveID {
		case tls.CurveP256:
			keyExchangeGroup = "P-256"
		case tls.X25519:
			keyExchangeGroup = "X25519"
		default:
			if r.TLS.CurveID != 0 {
				keyExchangeGroup = r.TLS.CurveID.String()
			}
		}
	}

	runtimeOS, err := readRuntimeOperatingSystem("/etc/os-release", "/usr/lib/os-release")
	if err != nil {
		log.Printf("failed to read runtime OS evidence: %v", err)
		http.Error(w, "failed to read runtime OS evidence", http.StatusInternalServerError)
		return
	}

	resp := MetaResponse{
		Stack:                 "go",
		RuntimeVersion:        runtime.Version(),
		UpstreamRuntimeImage:  requireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_IMAGE"),
		UpstreamRuntimeDigest: requireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_DIGEST"),
		TLSRuntime:            reflect.TypeOf(tls.Config{}).PkgPath(),
		TLSRuntimeVersion:     runtime.Version(),
		OS:                    runtimeOS.Name,
		OSSource:              runtimeOS.Source,
		TLSTerminatedHere:     isTLS,
		TLSVersion:            tlsVer,
		CipherSuite:           cipherSuite,
		KeyExchangeGroup:      keyExchangeGroup,
		TLSResumption:         s.cfg.TLS != nil && s.cfg.TLS.Resumption,
		TLSHandshakeTimeout:   s.cfg.Timeouts.TLSHandshakeSeconds,
		HTTPRequestTimeout:    s.cfg.Timeouts.HTTPRequestSeconds,
		HTTPVersions:          httpVers,
		Hostname:              s.hostname,
		NumCPU:                runtime.NumCPU(),
		PayloadPreallocate:    s.preallocate,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

func requireRuntimeProvenance(name string) string {
	value := os.Getenv(name)
	if value == "" {
		panic(fmt.Sprintf("%s is required in the server image", name))
	}
	return value
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ping", s.HandlePing)
	mux.HandleFunc("/payload", s.HandlePayload)
	mux.HandleFunc("/healthz", s.HandleHealthz)
	mux.HandleFunc("/meta", s.HandleMeta)
	return mux
}

func configuredCurve(group string) (tls.CurveID, error) {
	switch group {
	case "", "P-256":
		return tls.CurveP256, nil
	case "X25519":
		return tls.X25519, nil
	default:
		return 0, fmt.Errorf("config error: tls.group must be P-256 or X25519")
	}
}

func (s *Server) Run() error {
	handler := s.Routes()

	httpTimeout := time.Duration(s.cfg.Timeouts.HTTPRequestSeconds) * time.Second
	plainServer := newHTTPServer(s.cfg.PlaintextPort, handler, nil, httpTimeout, httpTimeout)
	plainServer.SetKeepAlivesEnabled(true)

	var tlsServer *http.Server
	var tlsListener net.Listener

	if s.cfg.TLS != nil && s.cfg.TLS.Enabled {
		cert, err := tls.LoadX509KeyPair(s.cfg.TLS.CertFile, s.cfg.TLS.KeyFile)
		if err != nil {
			return fmt.Errorf("failed to load TLS certificate or key: %w", err)
		}

		// Contract §2a & §3: Explicit switch with hard error if unexpected version
		var tlsVersion uint16
		switch s.cfg.TLS.Version {
		case "1.2":
			tlsVersion = tls.VersionTLS12
		case "1.3":
			tlsVersion = tls.VersionTLS13
		default:
			return fmt.Errorf("unsupported TLS version '%s' (must be exactly '1.2' or '1.3')", s.cfg.TLS.Version)
		}

		group, err := configuredCurve(s.cfg.TLS.Group)
		if err != nil {
			return err
		}
		tlsConfig := &tls.Config{
			Certificates:           []tls.Certificate{cert},
			MinVersion:             tlsVersion,
			MaxVersion:             tlsVersion,
			CurvePreferences:       []tls.CurveID{group},
			NextProtos:             []string{"h2", "http/1.1"},
			SessionTicketsDisabled: !s.cfg.TLS.Resumption,
		}

		if tlsVersion == tls.VersionTLS12 {
			tlsConfig.CipherSuites = []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256}
		}

		tlsHandshakeTimeout := time.Duration(s.cfg.Timeouts.TLSHandshakeSeconds) * time.Second
		// net/http derives its TLS handshake deadline from the minimum of these
		// three limits, so the header deadline deliberately remains distinct.
		tlsServer = newHTTPServer(s.cfg.TLS.Port, handler, tlsConfig, tlsHandshakeTimeout, httpTimeout)
		tlsServer.SetKeepAlivesEnabled(true)

		l, err := net.Listen("tcp", tlsServer.Addr)
		if err != nil {
			return fmt.Errorf("failed to listen on TLS port %d: %w", s.cfg.TLS.Port, err)
		}
		tlsListener = tls.NewListener(l, tlsConfig)
	}

	tlsPortLogged := 0
	if s.cfg.TLS != nil && s.cfg.TLS.Enabled {
		tlsPortLogged = s.cfg.TLS.Port
	}
	fmt.Fprintf(os.Stderr, "[go-server] starting plaintext=:%d tls=:%d preallocate=%v\n",
		s.cfg.PlaintextPort, tlsPortLogged, s.preallocate)

	errChan := make(chan error, 2)

	go func() {
		if err := plainServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errChan <- fmt.Errorf("plaintext listener error: %w", err)
		}
	}()

	if tlsListener != nil {
		go func() {
			if err := tlsServer.Serve(tlsListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errChan <- fmt.Errorf("TLS listener error: %w", err)
			}
		}()
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-errChan:
		return err
	case <-sigChan:
		fmt.Fprintln(os.Stderr, "[go-server] shutting down")
	}

	_ = plainServer.Close()
	if tlsServer != nil {
		_ = tlsServer.Close()
	}

	return nil
}
