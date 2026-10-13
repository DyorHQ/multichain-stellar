# DyorHQ multichain: Stellar Lite

**Private and internal.** Lite is the Stellar side of DyorHQ: a simpler mode inside the same app, next to Pro on
Monad. In Lite you save, earn, swap, launch coins, collect Moments, and move cash in and out.

Access is limited to internal testers. Each tester gets a single-use invite, joins the internal TestFlight group, and
uses a build compiled with `STELLAR_LITE`. This stays closed until Metropolis ends and access is opened on purpose.

The design and the Kill Critics verdict are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). What was proven and
how is in [docs/VERIFICATION.md](docs/VERIFICATION.md).

```
contracts/   Soroban (Rust): launch-token, launchpad (bonding curve → Soroswap, LP locked), moments (SEP-50 editions)
backend/     Supabase: lite schema (RLS deny-all), Edge Functions `lite` (API) + `lite-indexer` (cron), scripts, tests
ios/         StellarKit (pure-Swift Stellar core + Lite client), DyorLite (SwiftUI), LiteHarness app, main-app integration
docs/        Architecture, decisions, runbook, iOS integration, verification
```

## Status (2026-10-13)

| Part | State |
|---|---|
| Contracts | 31 tests pass, including graduation against the real Soroswap WASM. Deployed to testnet. |
| Backend | 18 unit tests and the SQL tests pass. The full user journey ran on testnet through the API (27 sponsored transactions). |
| StellarKit | 11 Swift tests pass on Linux and macOS, including 39 shared verifier vectors. The live testnet journey ran on Linux (it skips without `LITE_API`). |
| DyorLite UI + harness | Both build in Xcode 26.6 with no errors or warnings, and DyorLite's 4 tests pass on an iPhone 17 simulator. No screen has been run against a live API yet. |
| Main-app integration | Drop-in files and a patch guide for after the Oct 13 submission. The live Monad app is untouched. |

## Run it

```bash
# Contracts
cd contracts && ./build.sh && cargo test

# Backend: local Postgres + the API against Stellar testnet
psql -f backend/supabase/migrations/20261011000001_lite_schema.sql   # into an empty database
export LITE_DB_URL=postgres://… LITE_JWT_SECRET=$(openssl rand -base64 36) SPONSOR_SECRET=S… LITE_NETWORK=testnet
deno run -A --config backend/supabase/functions/deno.json backend/supabase/functions/lite/index.ts
deno run -A --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e.ts   # the whole journey

# iOS
cd ios/Packages/StellarKit && swift test                      # Linux or macOS
cd ios && xcodegen generate && open LiteHarness.xcodeproj      # the internal Lite app
```

Production setup (the `lite` schema in the DyorHQ Supabase project, secrets, cron, invites, TestFlight) is in
[docs/RUNBOOK-testnet.md](docs/RUNBOOK-testnet.md). Wiring Lite into the DyorHQ app is in
[docs/INTEGRATION-ios.md](docs/INTEGRATION-ios.md).

## Rules

- No secrets in this repo. Testnet keys live in `.secrets/` (git-ignored) and in Supabase function secrets.
- Lite lives in the DyorHQ Supabase project (`fmnjqrguvopusfufmirs`, DECISIONS #17) but only in its own `lite` schema:
  its functions and scripts connect as `lite_api`, which can reach nothing else. The invite script refuses other roles.
- Every transaction a user signs is built by the API, checked on the phone against pinned contracts and the amounts
  the user confirmed, then signed on the phone. The sponsor pays the fee only for transactions the API built.
