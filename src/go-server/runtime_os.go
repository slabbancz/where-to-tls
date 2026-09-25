package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

type RuntimeOperatingSystem struct {
	Name   string
	Source string
}

func readRuntimeOperatingSystem(paths ...string) (RuntimeOperatingSystem, error) {
	for _, path := range paths {
		contents, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return RuntimeOperatingSystem{}, fmt.Errorf("read runtime OS evidence %s: %w", path, err)
		}
		return RuntimeOperatingSystem{string(contents), path}, nil
	}
	return RuntimeOperatingSystem{"unexposed-by-runtime", "unexposed-by-runtime"}, nil
}
