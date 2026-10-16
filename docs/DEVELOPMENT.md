# Developing DyorHQ on Stellar

DyorHQ is one multichain iPhone app: the same screens on Monad and on Stellar, with a network switch. This repository
holds the Stellar side, on Stellar **testnet**:

| Path | What it is |
|---|---|
| `contracts/` | The Soroban contracts (launchpad, launch token, LP locker, Soroswap executor, Moments, Moment NFT and coin, graduator). `contracts/build.sh` builds `dist/*.wasm`. |
| `backend/` | The Supabase backend: the `lite` API and `lite-indexer` Edge Functions, the `lite` schema's migrations, and scripts. |
| `ios/Packages/` | `StellarKit` (keys, transaction building and the on-device verifier) and `DyorLite` (the app's Stellar store and session). |
| `app/` | The DyorHQ iOS app, with the Stellar network in `app/ios/DyorHQ/Lite/` (every file inside `#if STELLAR_LITE`). |
| `docs/` | Architecture, API, design and verification docs. |

The live testnet deployment's contract ids are in `backend/supabase/functions/_shared/deployments/testnet-v2.json`.
Hosted operations (deploying the backend, keys, testers, releases) are run by the maintainers and aren't documented
here.

## Prerequisites

- Rust with the `wasm32v1-none` target, at the exact `rustc` version `contracts/build.sh` names (the reviewed WASM
  hashes depend on it), and binaryen's `wasm-opt` (`brew install binaryen`).
- Deno 2, PostgreSQL 16 (`brew install postgresql@16`; keg-only is fine).
- Xcode 26 with an iOS 26 simulator, XcodeGen, and Python 3.

## Contracts

```bash
contracts/build.sh
```

```bash
cd contracts && cargo test
```

`build.sh` writes `dist/*.wasm` and `dist/SHA256SUMS`; `contracts/review/reviewed-wasm.sha256` lists the hashes that were
reviewed. `integration-tests/` runs the contracts together, including the memory budget of a graduation.

## Backend

The checks CI runs (type check, Deno unit tests, the API fixtures, and the SQL tests on a throwaway Postgres):

```bash
scripts/agent/verify-backend.sh "$PWD" 01
```

### A local backend

`backend/scripts/local-stack.sh` runs the backend on your Mac against Stellar testnet, with no hosted project:
Postgres 16, the `lite` API and `lite-indexer`, and a loop that calls the indexer every minute in place of the cron job.

```bash
backend/scripts/local-stack.sh start
```

```bash
backend/scripts/local-stack.sh status
```

```bash
backend/scripts/local-stack.sh stop
```

- **Ports.** By default the API listens on 127.0.0.1:8000, the indexer on 8001 and Postgres on 54329. `PORT_BASE=<n>`
  runs a stack of its own (API on `n`, indexer on `n+1`, Postgres on `n+2`), so several stacks run side by side; every
  command then takes the same `PORT_BASE`.
- **State.** Each stack keeps its data, logs, settings and media in `.local-stack/` (or `.local-stack/<PORT_BASE>`),
  which git ignores. `stop` keeps it; delete the directory after a stop to free the disk.
- **Options** (`start` is idempotent):
  - `--no-loop`: no indexer loop and no signing jobs, for a stack that only serves reads and your own test flows;
  - `--deployment testnet|testnet-qa`: which contract deployment the stack serves and indexes;
  - `--short-sessions`: sessions that expire in minutes, for testing renewal;
  - `--invite-required`: sign-in needs an invite, as on mainnet.
- **Other commands.** `migrate` applies new migrations, `logs [lite|indexer|loop|postgres|all]` tails the logs, and
  `e2e [phases…]` runs `backend/tests/e2e/lite_e2e.ts` against the stack.
- **Secrets.** The stack reads its function secrets from the git-ignored `.secrets/` directory, which the maintainers
  keep; each process starts from an empty environment and receives only its own settings. No secret is ever printed.

## The app

```bash
cd app/ios && python3 -I Internal/generate.py
```

This writes `DyorHQInternal.xcodeproj`: the app with the Stellar network. Its Debug build talks to the local backend at
`http://127.0.0.1:8000/lite` (the simulator shares the Mac's loopback), and its Release build to the hosted testnet
backend. Media on the local backend is served over plain HTTP, which the app's image loader refuses by design, so
pictures show their placeholder there and load on the hosted backend. `app/ios/Internal/README.md` explains the
internal project and the checks that keep the App Store build unchanged.

The app's checks (builds, strings, and DyorKit's tests):

```bash
QUICK=1 scripts/agent/verify-app.sh "$PWD" WP-01
```

`scripts/agent/README.md` lists every helper script.
