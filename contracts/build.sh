#!/usr/bin/env bash
# Builds the 13 contracts for wasm32v1-none and applies soroban-sdk spec shaking v2 (tools/spec-shake does what
# `stellar contract build` does), so a full stellar-cli install is optional. Output: dist/*.wasm (what we deploy) and
# dist/SHA256SUMS. dist/ is committed only by CT-10 (DESIGN-stellar-contracts-v2 §22).
set -euo pipefail
cd "$(dirname "$0")"
export SOROBAN_SDK_BUILD_SYSTEM_SUPPORTS_SPEC_SHAKING_V2=1

# v1: deployed and frozen. Built in a cargo invocation of its own, exactly as before v2 existed, so feature
# unification with the v2 crates can never change these WASMs: dist/SHA256SUMS must keep reproducing the hashes in
# backend/supabase/functions/_shared/deployments/testnet.json.
V1=(dyor-launch-token dyor-launchpad dyor-moments)
# v2 (§3.1). The integration-tests crate is host-only and never built here.
V2=(
  dyor-launchpad-v2 dyor-launch-token-v2 dyor-exec-soroswap dyor-exec-aquarius dyor-qa-exec-fail dyor-lp-locker
  dyor-moments-v2 dyor-moment-nft dyor-moment-coin dyor-moments-graduator
)

build() {
  local args=()
  for pkg in "$@"; do args+=(-p "$pkg"); done
  cargo build --target wasm32v1-none --release "${args[@]}"
}
build "${V1[@]}"
build "${V2[@]}"
(cd tools/spec-shake && cargo build --release -q)

mkdir -p dist
wasms=()
for pkg in "${V1[@]}" "${V2[@]}"; do
  c=${pkg//-/_}
  tools/spec-shake/target/release/spec-shake "target/wasm32v1-none/release/$c.wasm" "dist/$c.wasm"
  wasms+=("dist/$c.wasm")
done
# Exactly the 13 WASMs built above, in name order, so a stale file in dist/ never lands in SHA256SUMS.
# shellcheck disable=SC2046 # the paths hold no spaces
sha256sum $(printf '%s\n' "${wasms[@]}" | LC_ALL=C sort) | tee dist/SHA256SUMS
