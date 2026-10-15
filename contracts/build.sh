#!/usr/bin/env bash
# Builds the 13 contracts for wasm32v1-none and applies soroban-sdk spec shaking v2 (tools/spec-shake does what
# `stellar contract build` does), so a full stellar-cli install is optional. Output: dist/*.wasm (what we deploy) and
# dist/SHA256SUMS. dist/ is committed only by CT-10 (DESIGN-stellar-contracts-v2 §22).
#
# The v2 WASMs then go through wasm-opt -Oz, what `stellar contract optimize` runs, from binaryen $BINARYEN_VERSION
# exactly (macOS: brew install binaryen; CI downloads that release), so dist stays reproducible. v2 also builds with
# the cargo registry's path remapped, so no home-directory path ends up in a deployed WASM.
#
# v2 links a $V2_STACK_SIZE-byte stack instead of Rust's 1 MiB default. Every VM the host instantiates allocates its
# module's initial linear memory, and a graduation instantiates about 32 VMs, so the default (17 pages per module)
# put a Moments graduation at 126% of the network's 40 MiB per-transaction memory on a module-cache miss; with
# 128 KiB a module declares 3 pages. The value is 4× the smallest stack every test passed with (32 KiB, measured by
# CT-10); a stack overflow traps (wasm links stack-first), and inside a graduation's try_ frame a trap is a recorded
# failure, so keep the margin. integration-tests/tests/budgets.rs checks the declared pages of every v2 WASM.
#
# The WASMs embed /rustc/<commit>/ paths, so dist reproduces (and the reviewed hashes hold) only with rustc
# $RUSTC_VERSION exactly.
set -euo pipefail
cd "$(dirname "$0")"
export SOROBAN_SDK_BUILD_SYSTEM_SUPPORTS_SPEC_SHAKING_V2=1
BINARYEN_VERSION=133
RUSTC_VERSION="rustc 1.99.0 (b940084d7 2026-09-28)"
V2_STACK_SIZE=131072

if ! wasm-opt --version 2>/dev/null | grep -qx "wasm-opt version $BINARYEN_VERSION"; then
  echo "build.sh: needs wasm-opt from binaryen $BINARYEN_VERSION exactly (found: $(wasm-opt --version 2>/dev/null || echo none))" >&2
  exit 1
fi
if [ "$(rustc --version 2>/dev/null)" != "$RUSTC_VERSION" ]; then
  echo "build.sh: needs $RUSTC_VERSION exactly (found: $(rustc --version 2>/dev/null || echo none))" >&2
  exit 1
fi

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
# Its own target directory: the remapped flags would otherwise rebuild v1's dependencies on every run.
CARGO_TARGET_DIR=target/v2 \
  RUSTFLAGS="--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}/registry/src=/cargo/registry/src -C link-arg=-zstack-size=$V2_STACK_SIZE" \
  build "${V2[@]}"
(cd tools/spec-shake && cargo build --release -q)

mkdir -p dist
wasms=()
for pkg in "${V1[@]}"; do
  c=${pkg//-/_}
  tools/spec-shake/target/release/spec-shake "target/wasm32v1-none/release/$c.wasm" "dist/$c.wasm"
  wasms+=("dist/$c.wasm")
done
# The feature set Soroban accepts and `stellar contract optimize` uses: MVP plus mutable globals and sign-ext.
for pkg in "${V2[@]}"; do
  c=${pkg//-/_}
  tools/spec-shake/target/release/spec-shake "target/v2/wasm32v1-none/release/$c.wasm" "target/v2/$c.shaken.wasm"
  wasm-opt -Oz --converge --mvp-features --enable-mutable-globals --enable-sign-ext "target/v2/$c.shaken.wasm" -o "dist/$c.wasm"
  wasms+=("dist/$c.wasm")
done
# Exactly the 13 WASMs built above, in name order, so a stale file in dist/ never lands in SHA256SUMS.
# shellcheck disable=SC2046 # the paths hold no spaces
sha256sum $(printf '%s\n' "${wasms[@]}" | LC_ALL=C sort) | tee dist/SHA256SUMS
