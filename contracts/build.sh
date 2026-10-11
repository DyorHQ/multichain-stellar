#!/usr/bin/env bash
# Builds the three contracts for wasm32v1-none and applies soroban-sdk spec shaking v2 (tools/spec-shake does what
# `stellar contract build` does), so a full stellar-cli install is optional. Output: dist/*.wasm (what we deploy).
set -euo pipefail
cd "$(dirname "$0")"
export SOROBAN_SDK_BUILD_SYSTEM_SUPPORTS_SPEC_SHAKING_V2=1
cargo build --target wasm32v1-none --release -p dyor-launch-token -p dyor-launchpad -p dyor-moments
(cd tools/spec-shake && cargo build --release -q)
mkdir -p dist
for c in dyor_launch_token dyor_launchpad dyor_moments; do
  tools/spec-shake/target/release/spec-shake "target/wasm32v1-none/release/$c.wasm" "dist/$c.wasm"
done
sha256sum dist/*.wasm | tee dist/SHA256SUMS
