#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-cloudflare.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/CloudflareModels.swift \
    tests/CloudflareTests.swift -o "$TEST_DIR/cloudflare-tests"
"$TEST_DIR/cloudflare-tests"
