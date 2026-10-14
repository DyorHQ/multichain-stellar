# DyorHQ

DyorHQ is a self-custodial iPhone app for Monad (chain id 143). From one account it swaps tokens across Kuru Flow,
Uniswap v3/v4 and Monday Trade, trades perpetuals on Perpl's on-chain exchange, launches memecoins on the DyorHQ
Launchpad (bonding curves that graduate into a Uniswap v4 or Monday Trade pool), turns photos and videos into Moments
(an NFT with its own coin), bridges from other EVM chains through Aurora Intents, and keeps a portfolio, alerts, news and
a social feed. Keys stay on the phone: Privy's embedded wallet (email code, Apple or Google sign-in), passkey accounts
(a Swift port of Mera), an on-device email-and-password wallet, an imported wallet, or a watch-only address. Every
transaction is signed on the device and broadcast by the app itself to keyless public Monad RPCs. The app ships in
English, Spanish, French, Simplified Chinese and Korean.

This repository holds the app and everything it depends on. There is no web app.

## Repository map

| Path | What it is |
|---|---|
| `ios/` | The SwiftUI app `DyorHQ` (iOS 18+), generated with XcodeGen from `ios/project.yml`. Start with [`ios/README.md`](ios/README.md). |
| `ios/DyorKit/` | The Swift package behind the app: Keccak, ABI codec, JSON-RPC and Multicall3, transactions, and the venue, Perpl, launchpad, Moments, prices, Supabase, Mera and news services, with their tests. |
| `supabase/` | The backend for what is not on chain: wallet sign-in sessions, email accounts, profiles and social, alerts, sync, media pinning and the bridge proxy. Migrations, Edge Functions and their tests. See [`supabase/README.md`](supabase/README.md). |
| `contracts/` | The Foundry contracts (Launchpad, Moments), deployment records per chain, deploy scripts and the keepers that run graduations and buybacks. See [`contracts/README.md`](contracts/README.md). |
| `brand/` | The brand guide, the design system and the identity assets. |
| `docs/` | Developer docs: [`docs/app-wiring.md`](docs/app-wiring.md) (what every screen reads and writes) and [`docs/swap-spec.md`](docs/swap-spec.md) (spot trading across the venues). |
| `scripts/dev/` | Developer tools: the leak guard, the release gate (`check-launchpad-addresses.py`), string-catalog tools, fork seeding helpers. |
| `scripts/mera-parity/` | Checks the Swift port of Mera against the published JavaScript package. |
| `tests/` | Node tests of the leak guard and of the agents' secret-file guard. |
| `.githooks/`, `.github/workflows/`, `.leakguard`, `.gitleaks.toml` | The leak guard: local git hooks and the CI workflow that refuse secrets, env files, signing material and internal documents. |
| `.claude/` | Settings and the secret-file guard for AI coding sessions in this repository. |
| `THIRD_PARTY_NOTICES.md` | Credits for derived and bundled third-party work. |

## How the pieces fit

- **On chain first.** The app reads Monad directly (JSON-RPC, Multicall3, `eth_getLogs`) and signs every transaction on
  the device. No provider API key ships in the app; a Debug build can point at a local Anvil fork.
- **Venues and protocols.** Swaps quote Kuru Flow, Uniswap v3/v4 and Monday Trade and execute the best route. Perps use
  Perpl's Exchange contract with its market-data feeds. Launches and Moments use the DyorHQ contracts in `contracts/`,
  whose live addresses are baked into DyorKit and checked by the release gate before any archive.
- **Backend only where needed.** Supabase holds profiles, follows, alerts, activity sync and media pointers behind
  row-level security keyed to a wallet-signed session; the Edge Functions mint sessions, pin Moment media and proxy
  bridge quotes. No private key or signing secret is ever stored there.
- **Keepers.** `contracts/keepers` are dry-run-by-default Node jobs for the deployed contracts (launch and Moment
  graduations, buybacks, fee sweeps, governance checks), signing through Foundry `cast` with a keystore or Ledger,
  never a raw key.

## Build and test

Prerequisites: Xcode 26.6 with the iOS 18+ simulators, [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46,
Node 22.13 or later, [Foundry](https://getfoundry.sh) for the contracts, and Deno for the backend tests.

```bash
git clone --recurse-submodules https://github.com/DyorHQ/IOS-app.git && cd IOS-app
```

The app, from the repository root. The example xcconfig (every value empty) is enough to build and run: without Privy
ids, sign-in explains what is missing and **Watch an Address** still works.

```bash
cp ios/DyorHQ/Config/Secrets.example.xcconfig ios/DyorHQ/Config/Secrets.xcconfig
(cd ios && xcodegen generate && open DyorHQ.xcodeproj)
```

The package tests run without a simulator:

```bash
(cd ios/DyorKit && swift test)
```

The contracts (the size flag is for Monad's 128 KiB contract limit, which Foundry's default lint predates):

```bash
(cd contracts && forge test --offline --code-size-limit 100000000)
```

The keepers, the leak guard and the backend:

```bash
npm install && npm test && npm run keepers:test
deno test -A --no-config --node-modules-dir=none supabase/functions/ supabase/tests/
```

## Continuous integration

- **leak-guard** (GitHub Actions) runs on every push and pull request and nightly: forbidden paths, secret patterns,
  gitleaks, and the guard's own tests. It always uses the default branch's copy of the guard, so a push cannot switch
  off its own check.
- **Xcode Cloud** archives `ios/DyorHQ.xcodeproj` on every push to `main`. The project is generated in the cloud
  checkout by `ios/ci_scripts/ci_post_clone.sh`, which needs `PRIVY_APP_ID` and `PRIVY_CLIENT_ID` in the workflow's
  environment; the archive stops, by design, when they are missing. The Xcode Cloud section of
  [`ios/README.md`](ios/README.md) has the setup.

## Security

Never commit secrets or internal documents. The leak guard (`scripts/dev/install-hooks.sh`, CI `leak-guard`) enforces
this; see `CLAUDE.md`. Audit reports, runbooks and handoffs live in the private repository DyorHQ/internal. Report
vulnerabilities to team@dyorhq.fun.
