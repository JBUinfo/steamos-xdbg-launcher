#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BIN="$ROOT/bin"

command -v go >/dev/null 2>&1 || {
	printf 'Error: Go is required to build the test binaries.\n' >&2
	exit 1
}

mkdir -p "$BIN"

build_pair() {
	local goarch=$1
	local label=$2

	printf 'Building Windows %s-bit server/client...\n' "$label"
	(
		cd "$ROOT"
		GOOS=windows GOARCH="$goarch" CGO_ENABLED=0 \
			go build -trimpath -ldflags='-s -w' \
			-o "$BIN/winsock${label}-server.exe" ./cmd/server
		GOOS=windows GOARCH="$goarch" CGO_ENABLED=0 \
			go build -trimpath -ldflags='-s -w' \
			-o "$BIN/winsock${label}-client.exe" ./cmd/client
	)
}

build_pair 386 32
build_pair amd64 64
printf 'Binaries written to %s\n' "$BIN"
