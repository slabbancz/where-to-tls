package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "/etc/wtt/config.json", "Path to JSON config file (Contract §2a)")
	flag.Parse()

	cfg, err := LoadConfig(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[go-server] FATAL: %v\n", err)
		os.Exit(1)
	}

	srv, err := NewServer(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[go-server] FATAL: %v\n", err)
		os.Exit(1)
	}

	if err := srv.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "[go-server] FATAL: %v\n", err)
		os.Exit(1)
	}
}

