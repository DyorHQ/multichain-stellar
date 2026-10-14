# DyorHQ for iOS

The native SwiftUI app. It talks to Monad mainnet directly (JSON-RPC and Multicall3), quotes swaps across Kuru
Flow, Uniswap v3/v4 and Monday Trade, trades perpetuals on Perpl's on-chain exchange, and runs the DyorHQ Launchpad
and Moments on their live contracts (`contracts/`). Sign-in is Privy (email code, Apple, Google) with its embedded
wallet, a passkey account (the Mera port), an on-device email-and-password wallet, an imported wallet, or a watch-only
address. Transactions are signed on the device and broadcast by the app itself, so Monad never needs to be on Privy's
hosted-network list.

## Layout

```
ios/
├─ project.yml            XcodeGen spec (run `xcodegen generate` after editing)
├─ Package.resolved       package pins the Xcode Cloud build uses (see Xcode Cloud below)
├─ ci_scripts/            Xcode Cloud: generates the project after the clone, gates the archive after the build
├─ scripts/               pin-packages.sh (refresh Package.resolved), testflight.sh (archive + upload, gated)
├─ ExportOptions.plist    App Store export options used by testflight.sh
├─ DyorHQ/                the app target (SwiftUI, iOS 18+)
│  ├─ App/                entry point, environment, root view, cross-tab router, language store, update gate
│  ├─ Config/             Secrets.example.xcconfig → Secrets.xcconfig (git-ignored), AppConfig
│  ├─ Design/             shared components (logos, amounts, change badges, confirmation rows, paragraphs)
│  ├─ Onboarding/         welcome, sign-in methods, email code, import a wallet, watch-only address
│  ├─ Home/ Trade/ Swap/ Perps/ Launchpad/ Moments/ Bridge/ Portfolio/ Social/ News/ Notifications/ Profile/
│  ├─ Menu/ Support/      side menu, Get Help and the public links
│  ├─ Backend/            Supabase session, sync and alerts
│  ├─ Wallet/             Session, the Privy / Mera / password / imported signers, TransactionRun + ConfirmationSheet
│  └─ Resources/          asset catalog, token logos, String Catalogs (en, es, fr, zh-Hans, ko), the chart web view,
│                         the Google Sans subset, privacy manifest
└─ DyorKit/               Swift package with everything testable without a simulator
   ├─ Sources/DyorKit/
   │  ├─ Core/            Keccak-256, ABI codec, JSON-RPC client, Multicall3, formatting
   │  ├─ Chain/           Monad constants, token list, ERC-20, RLP, transaction preparation and sending
   │  ├─ Services/        Swap (Kuru, Uniswap, Monday, wrap), Perpl, Launchpad, Moments, DyorCoins, Prices,
   │  │                   Aurora (bridge), Supabase, Mera (passkeys), News, Notifications, wallet holdings
   │  └─ Resources/       DyorKit's String Catalog
   └─ Tests/              unit tests with fixtures recorded against Monad mainnet
```

## Build and run

1. Install XcodeGen once: `brew install xcodegen`.
2. `cp DyorHQ/Config/Secrets.example.xcconfig DyorHQ/Config/Secrets.xcconfig` and fill in the Privy app id and the
   mobile client id created for bundle id `fun.dyorhq.app` with URL scheme `dyorhq` (the owner's values are in the
   private repository DyorHQ/internal, `ios-app/docs/env-setup.md`).
   Without them the app still runs: sign-in shows what is missing and **Watch an Address** works.
3. `xcodegen generate`, open `DyorHQ.xcodeproj`, pick a simulator or device, run.

Command line:

```bash
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Package tests (fast, no simulator): `cd DyorKit && swift test`. The fixtures under `Tests/DyorKitTests/Fixtures`
were generated with viem and real `eth_call`s against Monad mainnet, so encoders are checked against the reference
implementation and decoders against live contract output.

Passkey accounts (Mera) in the Simulator: no real passkey can associate with `accounts.dyorhq.fun` there, so a Debug
Simulator build launched with `-MeraStubAuthenticator` uses a stub provider instead of the system sheet
(`DyorHQ/Wallet/Mera/StubPasskeyAuthenticator.swift`, compiled out of every other build). Its PRF secrets are random per
install, and it refuses to run unless the build points at a local fork (`MONAD_RPC_URL=http://127.0.0.1:8545`). An
optional mode after the argument reproduces a provider case: `full` (default), `unsupported`, `deferred` or `single`.

```bash
xcrun simctl launch booted fun.dyorhq.app -MeraStubAuthenticator single
```

Mera parity: the Swift port in `DyorKit/Sources/DyorKit/Services/Mera` is derived from `@category-labs/mera` 0.2.0
(credited in `THIRD_PARTY_NOTICES.md` at the repo root). `scripts/mera-parity` checks it against the published package,
pinned exactly with `@scure/bip39` and `@scure/bip32` 2.3.0. A fake WebAuthn client stands in for the passkey, so the
check needs no authenticator and no network once installed. It reads the vectors from `MeraTests.swift` and recomputes
each one with the library: the default salt; for PRF `0x000102…1f` the 24-word phrase, seed, index-0 and index-1 keys
and addresses, and the vault key; and the vault the Swift test seals, which Mera must decrypt. It exits non-zero on any
difference. Run it after changing anything in the port or its vectors. It needs Node 22 or later; npm warns that Mera
asks for 24, and the check passes on 22 and 23.

```bash
# from the repo root
cd scripts/mera-parity && npm ci --ignore-scripts --no-audit --no-fund && npm run parity
```

## Xcode Cloud

The DyorHQ workflow archives `ios/DyorHQ.xcodeproj` on every push to `main`. That project is git-ignored, so
`ci_scripts/ci_post_clone.sh` creates it in the cloud checkout: it installs the pinned XcodeGen, writes
`Secrets.xcconfig` from the workflow's environment variables, runs `xcodegen generate`, and copies the pinned
`Package.resolved` into the project (Xcode Cloud never resolves packages on its own).

- Environment variables: App Store Connect → Xcode Cloud → Manage Workflows → DyorHQ → Environment. Add
  `PRIVY_APP_ID` and `PRIVY_CLIENT_ID` with Secret ticked, plus any optional key the script lists. The Aurora API key
  is not a build variable: it lives only in the `aurora-proxy` Edge Function's secrets, so it never ships in the app.
  Enter plain values (no quotes, URLs as-is). An archive fails without the two Privy ids, because sign-up needs them;
  any other missing value switches its feature off, exactly as in a local build.
- Xcode version: pin the workflow to the release the app is verified on (Xcode 26.6 at the time of writing) rather
  than "Latest Release", which moves on its own; Xcode Cloud reports the version it used in each build's summary.
- After changing a package requirement in `project.yml` or `DyorKit/Package.swift`, run `ios/scripts/pin-packages.sh`
  and commit `ios/Package.resolved`; the cloud build fails with an out-of-date resolved file until the pins match.

## Contract addresses and the release gate

The live launchpad and Moments addresses are baked into DyorKit, each stack in one constant:
`LaunchpadAddresses.monadMainnet` and `MomentsAddresses.monadMainnet`, the v2 contracts deployed on 2026-09-28
(`contracts/deployments/143.json` and `moments-143.json`; the stacks they replaced are `143-retired-0x6B1C.json` and
`moments-143-cohort3.json`). A future stack is wired the same way, in one reviewed change: promote its records (with
`deployBlock`, the factory's creation block, added by hand), fill in the constant from them, and commit the records and
the Swift together. `V2WiringTests` accepts only all-zero tables (a `// PENDING` marker: Launch and Publish say "not
live yet", and the retired stacks and Moments cohorts keep serving their coins, claims and links) or fully wired tables
that match the records.

A build with a pending table must not ship, nor one whose String Catalogs lack a count's English plural forms, so
before a release:

```bash
(cd DyorKit && DYORHQ_RELEASE_GATE=1 swift test --filter 'AppStringsTests|PerpsWalletStringsTests|MomentsStringsTests|DyorKitStringsTests|TradeStringsTests|ShippedLanguagesTests|V2WiringTests')
(cd DyorKit && DYOR_LIVE_DOCS=1 swift test --filter DocsLinksTests)
python3 ../scripts/dev/check-launchpad-addresses.py --release
```

The first and the last fail while either table is pending. The first also fails when a key with a count is missing
from the app's or DyorKit's catalog, or has no English "one" form there (a count of 1 would read "1 editions"): the
strings tests skip that check outside the gate, until `scripts/dev/strings-sync.sh` has filled the catalogs. After
changing any text, run `scripts/dev/strings-sync.sh` from the repository root (it builds into a scratch folder;
`--derived-data` reuses a build), give a new count key its English one and other forms, and run
`scripts/dev/check-strings.py --enforce`.
`ci_scripts/ci_post_xcodebuild.sh` (Xcode Cloud) and `scripts/testflight.sh` run the first command too, each refusing
the archive. The last one also proves the retired Moments cohorts final on chain
(read-only calls to a public Monad RPC): each factory's `momentCount()` equals its pin
(`MomentLink.Cohort.finalMomentCount`), and its coins are exactly its entries in `MomentsAddresses.retiredMainnetCoins`.
Cohort 3's publishing is not paused on chain (owner decision 2026-09-28: the old stacks are retired in the app only),
which the check reports as a note; a Moment published there after its pin makes it refuse until the pin and the coin
table take it in (so the app never trades its coin). That moves no name link: a retired cohort's names are frozen at
`MomentLink.Cohort.namedMomentCount`, so such a Moment shares its id link only. Cohorts 1 and 2 must stay
paused (their policy pays the retired wallets): either one open refuses. The same reads prove the live stacks as wired,
so a wrong record promoted with matching Swift still refuses: every module in the two tables has code, each factory's
getters name the table's modules and the records' owner, governance and guardian (and the Moments policy the table's
platform and treasury, its link base c4's), and each factory was created at its record's `deployBlock`. The two live
factories are pinned in the script as well, as the keepers pin them (`LIVE_FACTORIES`), so every run refuses Swift and
records that agree on another factory; a new stack moves both pins with its records. It also reads
the public docs' Contracts & Addresses page at the URL Get Help opens ("Verify every contract DyorHQ uses"): it refuses
until the page lists every address in the two tables with their factories as the current ones, and when the page cannot
be read, so publish the docs update for a new stack before its archive (`DYOR_LIVE_DOCS=1` runs the same check in
`DocsLinksTests`).
It runs in every archive: the DyorHQ target's install-only build phase (so Product › Archive in Xcode is gated too),
`ci_scripts/ci_post_xcodebuild.sh` (Xcode Cloud) and `scripts/testflight.sh`, each refusing the archive.
`python3 ../scripts/dev/check-launchpad-addresses.py --chain` runs the same chain checks without refusing a pending
table, so the pins of a future stack can be confirmed before it is wired.

A Debug build can point at a v2 deployment on a local fork: `MONAD_RPC_URL` plus the `LAUNCHPAD_*` and `MOMENTS_*` keys
in `Secrets.xcconfig` (see the example file). Release builds never read them.

## Design rules

- Apple's system: SF Pro through text styles (Dynamic Type), SF Symbols, system semantic colors, `List`, `Form`,
  sheets with detents, `ContentUnavailableView` for empty states, `.refreshable`, Swift Charts.
- Palette from `brand/dyorhq-design-system.md`: the accent is the text/canvas pair inverted (ink on paper,
  paper on ink), Positive #126A4B / #77D8AC, Negative #AD3047 / #F496AA, Attention #775812 / #E4C67D. No decorative
  accent. Gains and losses always carry a sign or a word, never color alone.
- The serif wordmark asset is the identity; the app icon is its D on paper.
- Copy: title case for buttons and titles, sentence case for everything else, no exclamation marks, numbers use
  tabular figures, every write ends in a confirmation sheet that shows exactly what will be sent.

## What needs the owner

- Privy keys (and a Privy mobile client for `fun.dyorhq.app`), Sign in with Apple capability on that App ID, and
  Google credentials configured in the Privy dashboard.
- The passkey host `accounts.dyorhq.fun` (the constant `Mera.relyingParty`) serving the AASA file for `fun.dyorhq.app`,
  and Associated Domains enabled on that App ID.
- The addresses of any future contract stack, wired into DyorKit in one reviewed change (see the release gate above).
