# Stellar section parity: design (authoritative)

**Status:** design, 2026-10-14. This document supersedes the five specs written that day (designer A's Home/Earn spec,
designer B's Launch/Moments spec, the architecture spec, the backend spec and the delivery plan) and the two critiques
of them. Where this document and an earlier spec disagree, this document wins. Developer document: it lives in the
private multichain-stellar repository and is never copied into DyorHQ/IOS-app.

**Bases.**

| Id | Repository | Branch and head | Checkout |
|---|---|---|---|
| A | The app copy inside S: `S:app/` (a subtree of DyorHQ/IOS-app `release/24`; owner decision 2026-10-14). The design was read on DyorHQ/IOS-app `lite/network-switch` at c2ee50e (build 23 d387a64, then c9ae994 and 4e7e89b, then the committed tagline c2ee50e). | S `main`, under `app/` | `$S/app` (each package: its own S worktree's `app/`) |
| S | DyorHQ/multichain-stellar (private) | `main` at 651918e | `~/Hackathon-b17/multichain-stellar` |

**Where the app code lives (owner decision 2026-10-14).** The app code now lives in the private repository's app copy,
`S:app/`, a subtree of the public app's `release/24`, instead of the public DyorHQ/IOS-app repository. So **A is
`$S/app`**: an A path `ios/…` in this document is `S:app/ios/…`; each package works in one worktree of the private
repository (§13.4); and nothing in this program is pushed to the public repository (§13.6, O-3). The build-23 rules
(I1, I2, §12.1) compare the app copy against its upstream snapshot: the latest "Squashed 'app/' content" commit, found by the checks themselves (WP-R1). Q2 (§14) is answered by this decision.

"Monad X.swift:n" is a build-23 file in A. "Research" is `research-2026-10-14.md` (six reports). Facts this document
relies on were re-checked in the code on 2026-10-14. The ones that changed a decision are cited where they are used.

**How to read it.** §1 says what we are building and what is binding. §2 records every conflict between the specs,
how it was resolved, what was dropped and which gaps were closed. §3 to §7 are the technical design. §8 is the
screen-by-screen spec. §9 to §12 cover placeholders, strings, accessibility and testing. §13 is the build plan, and
§14 and §15 are the owner questions and the risks.

---

## 1. Goals and owner decisions

### 1.1 Binding owner decisions (2026-10-14)

1. **The Stellar section looks and works like the Monad section.** The only intended difference is the network.
2. **Stay on Stellar testnet for now, with nothing fake.** Every figure is either real testnet on-chain data or real
   reference market data. Not allowed:
   - demo values or smoke-test items in live feeds;
   - placeholder symbols;
   - a fake owner or treasury.

   The owner will redeploy the Stellar contracts with their own admin and treasury keys (RUNBOOK-testnet §2), so
   nothing may depend on today's admin or treasury. The design stays mainnet-ready; mainnet values come later.
3. **Fees are hybrid.**
   - **DyorHQ pays only:**
     - (a) the one-time account setup: a sponsored account plus its USDC trustline on mainnet, Friendbot activation on
       testnet;
     - (b) on mainnet, the first swap into XLM for a user who holds no XLM.
   - **Users pay every other network fee in XLM**, exactly as they pay MON on Monad. They get a fee preview, "Not
     enough XLM for the network fee", a Max that keeps the fee and the minimum balance back, and an add-funds card.
   - **DyorHQ keeps paying protocol upkeep:** the TTL/rent keeper, the graduation keeper and the CCTP relay.
   - This supersedes DECISIONS #6 and #13.
4. **Stellar tabs: Home · Launch · Earn · Moments.** Earn sits exactly in Monad's Trade slot.
5. The tagline change is handled separately. Here it matters only because it is already committed (c2ee50e), and the
   build-23 check must allow it (§12.1).
6. **No access gating.** "Users should be able to access the app, no need for gating it since it's on Testnet."
   Viewing the Stellar section never asks for Face ID, the passcode or a passkey, and never shows a locked screen:
   not after a relaunch, not after 12 hours or more, not after the app was in the background. Signing follows Monad
   exactly: Face ID or the passcode only when the user's App Lock setting applies (`settings.appLockApplies(to:)`,
   Profile › Security), once per confirmed action; a passkey (Mera) account gets its passkey prompt only, never App
   Lock on top. This supersedes the 12-hour session lock, the setup run's "Unlock your Stellar key" step for seed
   accounts, the locked Home and resting cards, the locked sheet, "Unlock again to continue", and
   `GatedSeedKeyProvider`'s prompt on every signature. How:
   - **Seed accounts** (imported phrase or key, email & password v2: the Stellar seed is in this iPhone's Keychain)
     sign the SEP-53 sign-in challenge silently. It is a message signature, domain-separated from every transaction
     signature, and the phone signs only a challenge of the exact expected shape (§5.8).
   - **Every account** gets a rotating refresh token at sign-in (30 days, single use, this device only), so sessions
     renew silently before they end and on a 401 (§6.18). Passkey accounts therefore never prompt just to view after
     their setup.
   - **On-chain reads need no session at all** (balances, positions, editions, boards, markets: "viewer" routes,
     §6.0). DyorHQ's own history (Portfolio, Recent Activity, My Launchpad, My Moments) stays behind a session.
   - **Secrets hygiene stays:** no seed or signer is kept in memory longer than one signing operation that never
     waits on the user (§7.2).

   Scope: this covers the device lock, session expiry and, on TESTNET, the invite code too (lead decision on the
   owner's "no need for gating it since it's on Testnet"): `inviteRequired` is false on testnet, so a first sign-in
   needs no code and registers the address as a tester (still revocable). Mainnet keeps `inviteRequired` true.

### 1.2 Lead defaults adopted

- **(a) Earn tab.** Earn is built like Monad's Trade tab, with a top switch [Swap | Earn] that opens on Earn. The
  side menu's Spot row and every Swap entry open Swap mode.
- **(b) Moments.** Stellar Moments stay SEP-50 editions with no coin and no graduation (DECISIONS #3). Only the UI and
  the flows align with Monad. OpenSea doesn't support Stellar (research, opensea). Freighter shows an edition once
  the user adds it by contract and token ID.
- **(c) Architecture.** The Stellar screens move into the app target under `ios/DyorHQ/Lite/`, each file wholly
  inside `#if STELLAR_LITE`. DyorLite shrinks to the data, session, signing and plan layer. Build-23 files change only
  inside `#if STELLAR_LITE` blocks, and DyorKit doesn't change at all. Private Monad components are copied, with a
  `Stellar` prefix. Name collisions are removed (§3.4).
- **(d) Home mirrors Monad exactly**, with real data only. Reference USD prices are labelled truthfully.
- **(e) Truthful testnet labels stay.** Nothing on screen is fake.

### 1.3 What "done" means

The Stellar section is Monad's section on another network:

- **Tabs.** Home · Launch · Earn · Moments. Earn carries [Swap | Earn] in Trade's place.
- **Side menu.** Home, Spot, Earn, Launch, Moments, News, Portfolio, Get Help: Monad's list, with Earn in Perps' row.
- **Screens built from the app's own components.** Home, token page, search, Swap, Earn, the Launch board, launch
  page, Create, My Launchpad, the Moments board, Moment page, Publish, My Moments, Portfolio, Profile and Recent
  Activity. The review sheet, notifications and saved figures all behave as on Monad.
- **Fees.** Hybrid fees work end to end on testnet, user-paid except Friendbot setup. The sponsored mainnet paths are
  rehearsed on a local stack only.
- **No access gate** (decision 6). Opening and browsing Stellar never prompts and never locks; signing prompts as on
  Monad (App Lock when it applies, or the passkey).
- **No placeholders anywhere** (§9). The App Store build is still build 23 apart from the build number and the
  tagline (§12.1).

### 1.4 Non-goals (this program)

- **Mainnet values and deploy.** No mainnet pins, Blend mainnet pool, CCTP mainnet route, anchors or RPC provider.
  The code takes the network as a parameter; values come with the owner's mainnet program.
- **Contract changes.** Launchpad, launch-token and Moments WASMs are unchanged. The owner redeploys the same WASMs
  with their own keys and economics (O-1).
- **Privy Stellar wallets.** Apple, Google, email-code and Privy-passkey accounts still can't use Stellar (LiteMode.swift:32-34).
  That is the next program's job (§15, RK14).
- **Share links and Learn more on Stellar.** No Stellar Moment link route and no Stellar docs pages exist. Monad's
  would be false, so Stellar screens show neither until those routes exist.
- **Discovery of arbitrary Soroban tokens.** Holdings list every classic trustline and every DyorHQ launch token.
  Other SEP-41 tokens appear only when searched for by contract id (§6.5).

---

## 2. Resolutions log

### 2.1 Conflicts and how they were resolved

| # | Conflict | Resolution |
|---|---|---|
| R1 | Type collisions: an app-side alias file (designers, delivery plan) vs a rename at source (architecture, backend), and `StellarJSON` vs `IntentValue` | **Rename at source**, once, in StellarKit (WP-03), using the backend's list plus `JSONValue → StellarJSON` (§3.4). No alias file, because an alias to `LiteClient.Launch` stops compiling after the rename. `JSONValue` is declared in StellarCore (TxVerifier.swift:38), not LiteClient. |
| R2 | Four different file trees under `ios/DyorHQ/Lite/` | The architecture tree (`Core`, `Design`, `Home`, `Wallet`, `Bridge`, `Trade`, `Launch`, `Moments`, `Portfolio`, `Profile`, `Alerts`), §3.3. The delivery plan's seams are mapped into it (§13.3). |
| R3 | Two review sheets (`StellarConfirmationSheet`, `StellarReviewSheet`) with different data and wording | **One `StellarConfirmationSheet`** (Wallet/), owned by WP-20. It carries the launch and Moments rows, the enable section and the error table. Its error text is "Not enough XLM for the network fee." (§4.6, §8.7). |
| R4 | Five fee data contracts | The backend shapes (§6.2, §6.8), plus a reason enum `sponsorReason: setup \| starter_swap`. The phone recomputes every fee from the XDR (§4.4). |
| R5 | Fee cap from server config vs pinned | **Pinned** in `PinnedContracts.feePolicy`. A cap the server supplies can't bound the server (§4.4). |
| R6 | Starter swap on testnet; thresholds; caps; how it is requested | **Mainnet only** (`activation == "sponsored"`), following decision 3. It is rehearsed locally with `LITE_ACTIVATION=sponsored`. Eligibility is decided by the server and re-checked at submit. The phone shows the offer only from server flags, and enforces the pinned inner-fee cap (§4.3). |
| R7 | Price provider (Kraken / CoinGecko / StellarExpert) | Provider-agnostic module (§6.12). **Default: Kraken public data**, because it needs no key and was checked live, with a Horizon mainnet SDEX fallback for XLM. Owner question Q1 confirms the provider before the hosted deploy. |
| R8 | API shapes for markets, history, holdings, period, terms, Moments policy | The backend's shapes with four changes: VolumePeriod raw values (`day\|week\|month\|all`); `/v1/markets*` public; tabs sorted on the phone; one `/v1/economics` (§6). |
| R9 | Portfolio valued at trade time (delivery plan) vs today's prices | **Today's prices**, like Monad's PortfolioModel (PortfolioModel.swift:13-15). Bridge is a section. Network fees are a separate field and never count as fees (§6.7). |
| R10 | Earn as a drill-down list vs a Perps-style single screen | **Perps-style single screen** (§8.6.3). Earn takes Perps' slot, and Monad's PerpsView is a single screen (PerpsView.swift:6-8). |
| R11 | Curve slippage via SlippageSheet vs fixed | **Fixed 1%**, like Monad (LaunchpadView.swift:1091,1100). |
| R12 | A "Completed / migrating" board section | **None.** Completed curves stay in Explore, as Monad keeps `awaitsGraduation` in climbing. The backend serves no `migrating` section. |
| R13 | Media origin from server config vs pinned | **Build-pinned** `LITE_MEDIA_BASE` (Info.plist, per configuration), `lite-media` only, uploads path regex. No IPFS: the Stellar backend never writes it (§5.6). |
| R14 | Four saved-figure designs | **DyorKit's public `SavedScreens`**, in a directory per network and deployment, keyed by the Monad account (§3.9). After a redeploy, the old deployment's figures never show. |
| R15 | One `Lite` table vs per-area tables | **A table per area** (`Stellar<Area>.xcstrings`), so packages never share a catalog. `liteTr` widens to accept `Lite` and `Stellar*` (§10). |
| R16 | Strip check in the public vs private repo; tagline committed | One Python checker, `ios/Internal/check-build23.py`, in A. It allows the committed tagline hunks of c2ee50e by listing them (§12.1). No `unifdef` (its exit code 1 breaks `set -e`). |
| R17 | Router fields, reference grammar, recording point | The architecture's: `StellarDestination` with reference `stellar:<tab>[/<id>]`. The store's `onSettled` fires even after the sheet has closed. Notification route is `.home` (§3.7). |
| R18 | Recent Activity and its row specified twice; explorer label; bridge ETA | One owner (WP-41) using designer B's row mapping. The label is "View on StellarExpert". ETA is the median of real transfers, or omitted (§6.10). |
| R19 | Moments treasury shown or omitted | **Shown in the publish review**, read live from the contract through the API and never stored (§6.9), as Monad shows it. |
| R20 | BUSDC in Top Tokens | **Not listed.** It is Blend's test token, with no market, and not Circle's USDC. It shows in holdings with a "Blend test" badge. |
| R21 | Network sheet summary wording | In tab order: "Launch, swap, earn and collect". |
| R22 | Holdings discovery v1; read state | **Every classic trustline plus launch tokens** in v1 (Monad shows the whole wallet). The app reuses DyorKit's `HomeReadState` (earn mapped to `.perps` internally). |
| R23 | Avail. Balance = spot − locked XLM (designer A) vs Monad's spot value | **Monad's definition** (`availableBalance = spotValue`, HomeView.swift:889), so the card's Spot split and Avail. Balance agree. Locked XLM is shown on the XLM token page, in balance footers and in Max (§8.2.2). |
| R24 | 24h change units: fractions on the wire vs `ChangeBadge`, which takes percent (Components.swift:252-267) | Fractions on the wire (backend convention). DyorLite models expose `…Percent` accessors, and views only ever pass those. Covered by a test (§7.3). |
| R25 | Error codes (backend set vs one `insufficient_xlm`) | The backend set plus stable contract-error codes (§6.13). |
| R26 | Add-funds thresholds | Card floor 0.1 XLM spendable, mirroring Monad's 0.1 MON floor. Starter eligibility below 0.05 XLM. The amount to send comes from the server's `suggestXlm` (§4.5). |
| R27 | Resource-fee margin and inclusion bid | Margin ×1.15 + 50,000 stroops. Inclusion bid at the getFeeStats p90, clamped to [100, maxInclusionPerOp ÷ 2] (§4.2). |
| R28 | Sponsorship ledger (`sponsorships` vs `sponsored_actions`) | The backend's `lite.sponsorships` with `reserve_sponsorship()` and its abuse caps (§6.15). |
| R29 | App test target | Add a hosted `DyorHQInternalTests` target for the app-side glue. Pure logic stays in DyorLite/StellarKit tests (§12.2). |
| R30 | LiteHarness deleted vs kept | **Kept as a session/data harness**, because it is the private CI's only iOS compile check (§13, WP-50). |
| R31 | The 12-hour Lite JWT, the setup run's unlock, the signer's 120 s idle and background drop, the locked Home/resting cards and `GatedSeedKeyProvider`'s prompt per signature vs owner decision 6 | **Decision 6 wins.** Silent SEP-53 sign-in for seed accounts (§5.8), rotating refresh tokens for every account (§6.18), viewer routes that need no session (§6.0), App Lock once per confirmed action through `LiteKeyProvider.beginSigning` (§7.2), no locked state anywhere (§8). Access tokens drop to 1 hour, because they now renew silently and a leaked one is useful for less time. Follow-up packages WP-02b and WP-03b adjust what M0 committed. |

### 2.2 Dropped as infeasible

| Item (source) | Why it can't ship | Instead |
|---|---|---|
| Fee cap read from `LiteConfig.fees.capPerTx` (designer A) | The server would bound itself | Pinned `FeePolicy` (§4.4) |
| `typealias StellarLaunch = LiteClient.Launch` file | Breaks after the source rename | Rename at source (R1) |
| `SlippageSheet` on curve trades | Not Monad's behaviour | Fixed 1% (R11) |
| Portfolio at trade-time snapshots with gas in fees | Contradicts Monad's PortfolioModel | §6.7 |
| "Tagline uncommitted, allow later" | c2ee50e is committed | Listed in `unflagged-changes.txt` from WP-00 on |
| PlanRunner `.signing` as a new event | Already exists (PlanRunner.swift:13,86) | Reused |
| `MomentsMath.ipfsGateways` | Doesn't exist, and Stellar never writes IPFS | Removed |
| Bridge chain and RPC from server config | A compromised Stellar API could drive the user's Monad wallet (MonadBridgeAdapter.swift:16-25 signs any call) | Chain pinned; EVM steps decoded and checked against pinned addresses (§5.7) |
| `/v1/markets` behind the JWT while Top Tokens shows when locked | A locked session has no store (LiteSession.swift:92,267) | Public market routes plus `LiteSession.publicReads` (§7.2) |
| `UIPasteboard.general.string = <any string>` in copy buttons | FormattedTextIsolationTests allows only `address.checksummed`, `account.address.checksummed`, `""` and setItems in WalletExportView | `StellarAccountID.checksummed` for G…/C…; token IDs are selectable text, never copied (§3.10) |
| `.navigationTitle(liteTr(…"literal"…))` | LanguageWiringTests accepts only `tr(` or `Text(verbatim:` there | `.navigationTitle(tr(LocalizedStringResource("…", table: "Stellar…", comment:)))` |
| `.searchable(prompt: "…")` | Same test | `prompt: Text("…", tableName:, comment:)` |
| Stored `let title: String` in a view; `title: String` helper parameters | LocalizableHelpersTests | Pass a `LocalizedStringResource`, a `Text` or the model |
| `launch.price` / `launch.marketCap` / `$0.marketCap` | AppCoinValueTests regex scans every app file | Fields `priceQuote`, `marketCapQuote`, `marketCapUsd`; variables named `coin` |
| `default:` (or the word) inside `Router.open(route:reference:)` | LocalNotificationTests | The Stellar hook is a one-line `if` with no such word |
| New Swift files outside `ios/DyorHQ/Lite/` | AppStringsTests counts exactly 30 files in its folders | Every new app file is under `Lite/` |
| Removing `MenuItem.items(for:)` / `subtitle(on:)` | SideMenuView's STELLAR_LITE blocks call them (SideMenuView.swift:26,203); `MenuItem.subtitle` calls `subtitle(on: .stellar)` (Router.swift:398) | Kept and edited in place |
| "Holders are exact before graduation because transfers are locked" | The launch token allows transfers to and from the launchpad, and burns (launch-token lib.rs:84-92) | Holders from indexed transfer, mint and burn events from launch on (§6.11) |
| `x-upsert:false` and uuid paths as write-once | Storage's service write is insert-on-conflict-update (IOS-app migration 26) | Write-once trigger on `lite-media` (§6.15, migration 09) |
| Literal "Not the real %@", "Unverified: in your wallet", "Refresh", "Bridge fee", "Select Market" as reused keys | Not in build-23 `Localizable.xcstrings` ("Not the real %@" is in DyorKit's catalog) | Stellar-table keys |
| `DetailRow("Locked")`, `Toggle("Open edition")` and similar for new copy | Those initializers take a `LocalizedStringKey` in the default table | `Text(…, tableName:)` / `LocalizedStringResource(…, table:)` forms |
| `SymbolSafety` comparison against registry codes | No such public API | The backend's `lookAlike` flag plus a small Stellar fold (§6.11) |
| `LiteStore.markets` used for both Earn and Top Tokens | Same property name twice | Earn's becomes `earnMarkets` |
| Collect stepper `1...min(20, max-minted)` | Traps when sold out | Upper bound clamped to at least 1; the ticket is hidden when sold out |
| A "Monad: up to X MON" bridge row from `LiteMonadBridge.send` | The protocol has no preview | `LiteMonadBridge.preview(_:)` added (§5.7) |
| Placeholder scan for "placeholder/demo/mock" | Matches legitimate code (`RemoteImage` placeholder, `PerpsDemo`) | Targeted patterns plus an allowlist (§12.1) |

### 2.3 Gaps closed

Each row names the gap and the section that closes it.

| Gap | Closed in |
|---|---|
| The verifier doesn't bind payment destination, memo, SAC `to`, curve/router min-out and recipient arguments, or the CCTP mint recipient | §5.2, WP-11 |
| `ContractInspector` uses the server's `rpcUrl` | Pinned phone RPC (§5.5) |
| The phone trusts the server's "sponsored" flag | §4.3 |
| Archived Soroban entries: nobody restores them | §4.9 |
| Testnet setup signs a user-paid trust with no fee preview | §8.14 |
| Bridge signing is unchecked and has no MON fee preview | §5.7 |
| CCTP relay griefing | Minimum amount and per-user relay cap (§6.10) |
| Moment publish has no "terms changed" guard | §8.11.4 |
| Pasteboard, coin-value and title lints not covered by the UI specs | §3.10 |
| Blend pool status not shown | §8.6.3 |
| Smoke items in the live feed before the owner's redeploy | §6.16 |
| Faucet amount hard-coded | Served by config (§6.2) |
| `lite.`-prefixed UserDefaults keys | App Lock's first-run rule (Theme.swift:61-63), §3.10 |
| New migrations must repeat the RLS loop; storage changes guarded for CI's plain Postgres | §6.15 |
| No CI builds the internal project | Local `verify-app.sh` gate; LiteHarness kept (§12, WP-50) |
| No upload budget on `lite-media` | §6.9 |
| USDC Earn on testnet needs Blend's test USDC | Truthful copy plus a swap route check (§8.6.3) |
| Route order: new `/v1/moments/*` routes vs `/:id` | §6.1 |
| Price alerts for Stellar | WP-60 (M4) |
| Transfer shortfall swap (Monad's MON→AUSD top-up) | WP-61/62 (M4) |
| Wallet-wide Stellar swap history for Portfolio | WP-63 (M4) |
| The tests the critics listed as missing | §12 |

---

## 3. Architecture and file layout

### 3.1 Invariants (every work package keeps all of them)

| # | Invariant | Proven by |
|---|---|---|
| I1 | **The App Store build equals build 23** apart from the build number and the committed tagline. Rules: existing app files change only inside `#if STELLAR_LITE` blocks (new blocks may be added); new app code lives only in `ios/DyorHQ/Lite/**`, each file wholly inside `#if STELLAR_LITE`. | `ios/Internal/check-build23.py` (§12.1), plus an `nm` and bundle check of the App Store Release `.app` |
| I2 | **`ios/DyorKit/**` is untouched**, `Package.resolved` included. `swift test` rewrites `Package.resolved`, so every run restores it. | check-build23.py |
| I3 | **Lite files pass every DyorKit source lint.** About 20 DyorKit tests scan every `.swift` under `ios/DyorHQ`, Lite/ included (§3.10). | `cd ios/DyorKit && swift test` in every A package |
| I4 | **No new key reaches `ios/DyorHQ/Resources/Localizable.xcstrings`.** | `ios/Internal/check-lite-strings.py` (§10) |
| I5 | **The Stellar signer never leaves DyorLite.** The app never holds a `StellarSigner`. | API shape (§7.2) |
| I6 | **The internal project builds after every merge.** Package changes are additive first, and deletions come last (WP-50). | §13 ordering |
| I7 | **Nothing depends on today's admin or treasury.** Contract ids come from `PinnedContracts`/config, which `gen-pinned.ts` regenerates. Economics are read live from the contracts. | grep (§12.1); WP-04 acceptance |
| I8 | **No placeholder data** (§9). Before the backend serves a figure, the screen shows Monad's reading, empty or error state. | review and simulator QA |
| I9 | **Security-relevant values are pinned in the build, never served:** fee caps, the media base, the phone RPC, bridge contracts and explorer links. | §5 |
| I10 | **No access gate (decision 6).** Viewing Stellar never prompts and never shows a locked state; a prompt appears only to sign: App Lock (seed accounts, only when it applies, once per confirmed action) or the passkey (passkey accounts). No seed or signer outlives one signing operation that doesn't wait on the user. | LiteSessionTests with a counting fake provider (§12.2); QA F04, F04b, F19 (Appendix A) |

### 3.2 Layers and repositories

```
DyorHQ/multichain-stellar (S, private)
app/ (A: the app copy, a subtree of DyorHQ/IOS-app release/24)
  app/ios/DyorHQ/Lite/**   Stellar screens (SwiftUI)  →  ios/Packages/DyorLite    session, store, plan running, titles,
     uses the app's components, Router,                                         errors, pure helpers (no views after WP-50)
     NotificationHub, SavedScreens (DyorKit)              ios/Packages/StellarKit  StellarCore (XDR, keys, TxVerifier,
  app/ios/Internal/**      internal project, checks,                               PinnedContracts, XLMReserve)
                           Stellar string tables, tests                            LiteClient (LiteAPI, models, PlanRunner,
                                                                                   PlanFees, anchors)
                                                          backend/                 Deno lite API, lite-indexer, migrations
                                                          contracts/               unchanged
```

- **StellarKit** stays pure Swift. It re-exports LiteClient and StellarCore (`@_exported`, StellarKeychain.swift:2-3).
- **App imports.** App files import StellarKit and DyorLite only under `Lite/`. A non-Lite file never imports them.
- **Concurrency.** DyorLite types are `@MainActor @Observable` where they hold UI state, as today.

### 3.3 File tree (A = `S:app/`)

Every file below is new unless marked (existing), and is wholly inside `#if STELLAR_LITE`. Basenames never repeat an
app file's basename, because `.o` and `.stringsdata` files are named by basename; the `Stellar` prefix guarantees it.
Paths are under `S:app/`; the rest of this document writes them from `ios/` on.

```
S:app/ios/DyorHQ/Lite/
  (existing glue) AppCovers, AppNetwork, DyorHQLiteKeys, LiteMode, LiteText, MonadBridgeAdapter, NetworkChip,
                  NetworkRoot, NetworkSheet, StellarProfile, StellarRemoteFlag
  Core/      StellarRootView (tab bar, resting tabs), StellarRouting (Router extension, StellarDestination,
             StellarTradeMode, StellarSwapRequest), StellarActivityRecorder, StellarActions (environment actions),
             StellarSaved, StellarImages (LiteMediaPolicy → RemoteImageSource), StellarFormat, StellarAccountID
  Design/    StellarTokenLogo (+ StellarLogoDisc, StellarLogoMonogram), StellarArtwork (launch art),
             StellarMomentArtwork, StellarMomentStateBadge, StellarAmountField, StellarTokenBadge (+ imitation,
             test-asset, new badges), StellarAddressText, StellarAddressRow, StellarNetworkLine, StellarActivityRow,
             StellarTransactionProgress, StellarSignInRow (a history part with no session, §8)
  Wallet/    StellarConfirmationSheet, StellarReceiveSheet, StellarSendSheet, StellarCashSheet, StellarCashTracker,
             StellarTransferSheet (no locked sheet: decision 6)
  Home/      StellarHomeView, StellarHomeModel, StellarHomeRows, StellarAddFundsCard, StellarTokenDetailView,
             StellarSearchSheet
  Trade/     StellarTradeView (+ StellarTradeModeSwitcher), StellarSwapView, StellarSwapModel, StellarSwapHistory,
             StellarEarnView, StellarEarnModel, StellarSelectMarketSheet, StellarRateChart
  Bridge/    StellarBridgeView, StellarBridgeInReview, StellarBridgeTracker, StellarBridgePins, StellarEvmStepCheck
  Launch/    StellarLaunchpadView (board, StellarLaunchCard), StellarLaunchDetailView (+ StellarLaunchTradeRow),
             StellarCreateLaunchView (+ StellarLaunchPreviewCard), StellarLaunchpadProfileView
  Moments/   StellarMomentsView (board, StellarMomentCard), StellarMomentDetailView,
             StellarCreateMomentView, StellarMomentsPortfolioView, StellarFreighterSheet
  Portfolio/ StellarPortfolioView, StellarPortfolioModel
  Profile/   StellarAccountView, StellarRecentActivityView
  Alerts/    StellarPriceAlerts (M4)
S:app/ios/Internal/
  generate.py (existing), Info.plist (existing, regenerated), README.md
  check-build23.py, check-lite-strings.py, check-copies.py, unflagged-changes.txt
  Resources/ Lite.xcstrings (existing), logo-XLM.png (existing), Stellar<Area>.xcstrings (one per area, §10)
  Tests/     <Area>Tests.swift (hosted DyorHQInternalTests target)
```

### 3.4 Type renames and name rules

**Collisions verified 2026-10-14.** StellarKit's public names are compared against DyorKit's public and the app's
internal names (scratchpad intersection):

| Name | Clash | Resolution |
|---|---|---|
| ActivityItem, Amount, Candle, Launch, LaunchDetail, Moment, MomentDetail | DyorKit public (ambiguous) | Renamed |
| JSONValue | App's internal BackendSync.swift:355 (silent shadow) | Renamed |
| Mnemonic | DyorKit's is internal | Left as is |

**Renamed at source in WP-03:**

| Old (module) | New |
|---|---|
| `Launch`, `LaunchDetail`, `LaunchTrade`, `Candle` (LiteClient) | `StellarLaunch`, `StellarLaunchDetail`, `StellarLaunchTrade`, `StellarCandle` |
| `Moment`, `MomentDetail`, `OwnedEdition` (LiteClient) | `StellarMoment`, `StellarMomentDetail`, `StellarEdition` |
| `ActivityItem`, `Prices` (LiteClient) | `StellarActivityItem`, `StellarPrices` |
| `Amount` (StellarCore) | `StellarAmount` |
| `JSONValue` (StellarCore, TxVerifier.swift:38) | `StellarJSON` |

**Rules.**

- **New public types.** Every new public LiteClient, StellarCore or DyorLite type is `Stellar`- or `Lite`-prefixed.
- **New app views.** Every new app type under `Lite/` starts with `Stellar`.
- **Latent clashes.** `Transaction`, `Operation` and `Asset` (StellarCore XDR) are never written bare in `Lite/`.
  Write `StellarCore.Transaction`, or `SwiftUI.Transaction` where SwiftUI's is meant.
- **Retired DyorLite types.** `PricePoint`, `SafariView`, `TestnetBadge`, `SendSheet`, `ReceiveSheet` and
  `LaunchDetailView` are deleted with the DyorLite views. The app's `PricePoint` (DyorKit), `SafariView` and
  `TestnetBadge` are used instead.
- **Silent rebinding.** Moved code that calls DyorLite's internal `tr("…")` would bind to the app's
  `tr(LocalizedStringResource)`. Moved code that calls `describe(_:)` would bind to the app's Components.swift:697.
  Every Stellar string therefore names its table, and every Stellar error goes through `LiteErrorText.describe(_:)`
  (§7.2). check-lite-strings.py catches a miss.

### 3.5 Monad components: reuse, copy, hook

**Reuse as they are.** These are internal, value-driven, and need no edit:

- **Layout and figures:** `HomeHeader(showSearch:error:updatedAt:)`, `View.cardBackground()`,
  `View.unreadFigure(_:)`, `AllocationDonut`, `HomeTokenTab`, `ChangeText`, `ChangeBadge`, `USDText`, `SavedLine`.
- **Controls and text:** `InlineError`, `PrimaryButton`, `DetailRows`/`DetailRow`, `Paragraph`/`ParagraphLabel`,
  `Haptics`, `RemoteImage`, `ImageLoadingSpinner`, `Avatar`, `SettingsRow`, `SheetHeader`.
- **Network marks:** `NetworkChip`/`NetworkChipRow`/`NetworkMark`, `TestnetBadge` (Lite/NetworkChip.swift:40).
- **Sheets and charts:** `SlippageSheet(slippageBps:)` (swap only), `PriceChart(points:isLoading:tint:)` with
  DyorKit `PricePoint(block:time:usd:)`, `QRCode.image(for:)`, `SafariView`.
- **Moments helpers:** `CountdownSchedule`, `MomentsFormat`, `Clock`, `MovieFile` with `coverFrame`,
  `UIImage.launchJPEG()`/`avatarJPEG()`.
- **Transaction run:** `TransactionRun.alreadySent`/`.notSent`, `BackgroundTime`, `.holdsMomentLinks()`.
- **Hooks into the menu:** `keyboardDoneButton()`, `VolumePeriod`/`Router.period`, `TradeMode.swap.label`,
  `MenuItem.title`, `HoldingCategory` labels, `LaunchSort`.
- **Shared screens:** `NotificationHub`/`NotificationCenterView`, `SideMenuView`, `ProfileView`.
- **DyorKit public:** `PriceFormat`, `NumberStyle`, `SymbolSafety.isDisplaySafe`/`isNameDisplaySafe`/`createRefusal`,
  `SavedScreens`, `BoardFirstRead`, `BoardPrefetch`, `RelativeTime`, `HomeReadState`, `ImageSizeBucket`,
  `RemoteImageSource`, `RemoteImageWait`, `BiometricGate`, `LaunchPhase.title`, `TransactionSender.feePreview`.

`MarketLogo(symbol:)` is used only for network marks, never for a Stellar asset: it picks a logo by symbol, so a
launch named "USDC" would wear Circle's.

**Copies.** These Monad pieces are private or EVM-typed, so they are copied into `Lite/` with a `Stellar` prefix.
Each copy keeps the original's metrics exactly. It starts with a header naming its source:
`// Stellar copy of ios/DyorHQ/Home/HomeView.swift HomeAction (<snapshot> sha256:<first 12 hex>)`.
`check-copies.py` re-hashes each named declaration in the base, brace-matched from its declaration line, and lists
copies whose source changed. When a later base changes Monad, the copy is re-synced instead of drifting. There is no
shared JSON registry, so packages never edit a common file.

| Copy | Monad source |
|---|---|
| StellarHomeAction, StellarTokenListRow, StellarHoldingRow, StellarLaunchHoldingRow, StellarEarnPositionRow, StellarMomentHoldingRow, StellarNewBadge | HomeView.swift:559, :632, :667, :704, :731, :1623, :1458 |
| StellarTokenDetailView | HomeView.swift:1273 |
| StellarLogoDisc, StellarLogoMonogram, StellarTokenLogo, StellarTokenBadge | Components.swift:65, :82, :13, :112 |
| StellarAmountField, StellarAddressRow, StellarTransactionProgress | Components.swift:314, :371, :610 |
| StellarConfirmationSheet | TransactionRun.swift:156 |
| StellarTradeView, StellarTradeModeSwitcher | TradeView.swift:8, :22 |
| StellarSwapView, StellarSwapHistory, StellarSearchSheet | SwapView.swift:7, :766, :798 |
| StellarEarnView, StellarSelectMarketSheet | PerpTradeView.swift (header :285, ticket :482, rates :452, buttons :720, tabs :851); SelectPerpetualSheet :2148 |
| StellarLaunchpadView, StellarLaunchCard, StellarArtwork, StellarLaunchDetailView, StellarLaunchTradeRow, StellarCreateLaunchView, StellarLaunchPreviewCard | LaunchpadView.swift:12, :346, :443, :627, :1187, :1228, :1501 |
| StellarLaunchpadProfileView | LaunchpadProfileView.swift:10 |
| StellarMomentsView, StellarMomentCard, StellarMomentStateBadge, StellarMomentArtwork | MomentsView.swift:6; MomentsUI.swift:172, :90, :15 |
| StellarMomentDetailView, StellarCreateMomentView, StellarMomentsPortfolioView | MomentDetailView.swift:8; CreateMomentView.swift:13; MomentsPortfolioView.swift:13 |
| StellarPortfolioView | PortfolioView.swift:8 (activity row :342) |
| StellarReceiveSheet, StellarSendSheet | ProfileView.swift:356, :407 (asset picker :841, :895) |
| StellarRecentActivityView, StellarActivityRow | RecentActivityView.swift:8, :88 |
| StellarBridgeView, StellarBridgeTracker | BridgeView.swift:7; BridgeTracker.swift:50 |
| StellarTransferSheet | TransferSheet.swift:8 |
| StellarAddFundsCard | AddFundsCard.swift:9 |

**Hooks.** These are the only edits to build-23 files, and every one sits inside a `#if STELLAR_LITE` block:

| File | Change | Owner |
|---|---|---|
| App/Router.swift, stored-property block (:88) | Add `stellarTradeMode: StellarTradeMode = .earn`, `pendingStellar: StellarDestination?`, `stellarAvailable = false`. | WP-21 |
| App/Router.swift, `open(route:reference:)` (:254) | Before `ensureMonad()`: `if openStellar(reference: reference) { return }`. One line; the word "default" must not appear. | WP-21 |
| App/Router.swift, `open(_ item:)` (:274) | On Stellar: `if openOnStellar(item) { return }`, which replaces the `stellarTab` branch. | WP-21 |
| App/Router.swift, `MenuItem` extension (:403-439) | `items(for: .stellar) = [.home, .spot, .earn, .launch, .moments, .news, .portfolio, .help]`. `stellarTab`: `.spot`/`.earn` → `.earn`, `.portfolio` → nil. `subtitle(on: .stellar)` gains `.spot` and `.portfolio`, and Home's line changes (§8.13). The titles of `MenuItem.title`/`subtitle` stay at 8 `tr(` each (AppStringsTests). | WP-21 |
| Menu/SideMenuView.swift `isCurrent` (:153) | On Stellar: `.spot` = Earn tab in swap mode; `.earn` = Earn tab in earn mode; the others by `stellarTab`. | WP-21 |
| Profile/ProfileView.swift Stellar extension (:235-312) | Wallet: Receive, Send, Recent Activity. Network: Chain, RPC, Stellar account, footer (§8.12). | WP-41 |
| Wallet/PriceAlerts.swift (new block) | Lists the Stellar alerts below Monad's (M4). | WP-60 |

The lines that DyorKit tests read must not move: `openLaunch` (LaunchpadCurveRoutingTests), `openMoment(_ link:)`
read whole (MomentsSpeedTests), and the body of `open(route:reference:)` (LocalNotificationTests).

### 3.6 The tab root

- **`StellarRootView(session:)`** (WP-21) replaces `LiteRootView` in NetworkRoot.swift:47-52. NetworkRoot's
  `chrome(_:)` and `LiteStyle.dyorHQ` are deleted.
- **Tabs.** Monad's `Tab(_:systemImage:value:)` API, bound to `router.stellarTab`:
  - Home (`house`);
  - Launch (`flame`);
  - Earn (`leaf`, title `MenuItem.earnTitle`);
  - Moments (`camera.aperture`).

  The bar adds `.sensoryFeedback(.selection, trigger: router.stellarTab)`.
- **Resting tabs.** A tab other than Home shows `StellarRestingTab` until `session.home == .ready`:
  - paused: the reason, plus Switch to Monad;
  - loading: a spinner.

  These use the app's `PrimaryButton`. There is no locked state (decision 6): an account that finished setup is
  `.ready` at once on a cold launch, with or without a session (§7.2).
- **`StellarTab`** (AppNetwork.swift) becomes `home, launch, earn, moments`. The `LiteTab` bridge is deleted.
- **Summary.** `AppNetwork.summary` for Stellar is "Launch, swap, earn and collect".

### 3.7 Routing, notifications and activity

**Types** (`Lite/Core/StellarRouting.swift`):

```swift
enum StellarTradeMode: String { case swap, earn }      // labels: TradeMode.swap.label, MenuItem.earnTitle
struct StellarSwapRequest: Hashable { var sell: String?; var buy: String?; var starter = false }
enum StellarDestination: Hashable {
  case home, swap(StellarSwapRequest), earn(market: String?), launch(token: String?), moment(id: Int?),
       portfolio, bridge(id: String?)
  init?(reference: String)            // "stellar:<tab>[/<id>]"
  var reference: String
}
```

Reference grammar:

| Reference | Destination |
|---|---|
| `stellar:home` | Home |
| `stellar:swap[/<sell>,<buy>]` | Swap |
| `stellar:earn[/<marketId>]` | Earn |
| `stellar:launch[/<C…>]` | Launch |
| `stellar:moment[/<id>]` | Moment |
| `stellar:portfolio` | Portfolio |
| `stellar:bridge[/<id>]` | Bridge |

No Monad reference starts with `stellar:`, and a test proves `init?(reference:)` refuses Monad's references.

**Router extension:**

| Function | Behaviour |
|---|---|
| `ensureStellar() -> Bool` | When `stellarAvailable` (set by `NetworkRoot.follow()`: availability offered and a session object exists): sets `network = .stellar`, with no sheet and no prompt, as on a cold launch. Otherwise sets `linkNotice` ("Stellar isn't available for this account.") and returns false. |
| `openStellar(_ destination:)` | Sets `presented = nil` and `menuOpen = false`, then sets `stellarTab`, `stellarTradeMode` and `pendingStellar`. |
| `openStellar(reference:) -> Bool` | True when the reference is Stellar's. It handles the reference whether or not Stellar is available. |
| `openStellarSwap(sell:buy:starter:)` | The single route for every Stellar swap entry: Home search pick, token page Swap, graduated launch Buy/Sell, side-menu Spot and the add-funds card. |
| `openOnStellar(_ item: MenuItem) -> Bool` | home/launch/moments → tab. spot → Earn tab in swap mode. earn → earn mode. portfolio → `presented = .portfolio`, with no `ensureMonad`. news and help fall through to Monad's handling. |

Monad destinations keep `ensureMonad()`.

**Recording and notifications:**

- **Who fires it.** `LiteStore.run(_:)` fires `session.onSettled(LiteSettledAction)` once per settled plan. It runs in
  the store's task, so it outlives the sheet (the GL-3 rule).
- **Who posts.** `StellarActivityRecorder` (installed in `NetworkRoot.makeSession`) posts once to
  `NotificationHub.shared.post(kind:title:body:route:reference:owner:)` with:
  - **kind:** spot and bridge → `.swap`; moments → `.moments`; earn, launch, wallet, cash → `.transaction`.
  - **title:** from `LiteTitles` (§8.15).
  - **body:** ends with " · Stellar testnet" on testnet, or " · Stellar" on mainnet.
  - **route:** `.home`. An App Store build restoring the row opens Monad Home, which is harmless.
  - **reference:** the destination's reference.
  - **owner:** the account's Monad `Address`.
- **Deduplication** is by plan id. The background trackers (bridge, anchors) dedupe by transfer id, stored under
  `lite.notified.<G>` and erased by forget.
- **Never `ActivityLog`.** Stellar actions are never written to `Activity.record`/`ActivityLog`. That log is the
  Monad wallet's: BackendSync mirrors it into volume tables, and its rows link to Monadscan. Stellar activity is the
  server's `lite.tx_log`, served by `/v1/activity`.
- **Banner taps** take the same path: `deliverPendingNotificationRoute` passes the hub item's reference to `open`.

**`StellarActions`** (environment, `Lite/Core/StellarActions.swift`) carries closures that the root sets, so shared
components never reference area types:
- `addFunds()` opens Receive;
- `openSwap(_:)`;
- `signIn()`: `session.signIn()`, for `StellarSignInRow` only (a passkey account's history part with no session; §8);
- `switchToMonad()`.

There is no `unlock()` (decision 6).

### 3.8 Images

- **Policy.** `LiteMediaPolicy` (DyorLite, pure) accepts only `<LITE_MEDIA_BASE>uploads/G[A-Z2-7]{55}/[0-9a-f-]{36}.(jpg|jpeg|png|webp|gif)`.
  Stricter rules: https only (loopback http only when the base itself is loopback, i.e. Debug), the exact host, no
  port, userinfo, query or fragment, a clean path, and at most 2,048 bytes. Videos are the same with `mp4|mov`.
  Anything else returns `[]`, and the view shows letters or the placeholder art.
- **Base URL.** `LITE_MEDIA_BASE` is an Info.plist key that generate.py writes per configuration:
  - Release: `https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/`;
  - Debug: `http://127.0.0.1:8000/lite/v1/local-media/lite-media/` (the local stand-in, §6.17).

  It is never taken from the server.
- **Sources.** Release: `[render URL (…/render/image/public/lite-media/<path>?width=<px>&resize=contain&quality=70), original]`,
  where `px = ImageSizeBucket.bucket(points:)`. The render URL is left out for gif and for buckets above 768. Debug
  serves the original only.
- **Pipeline.** `StellarImages` turns these into `RemoteImageSource`s for `RemoteImage`; `AsyncImage` is never used.
  Media URLs read back from a saved snapshot go through the policy again.
- **Server side.** `lite-media` becomes write-once with a trigger (migration 09). Until that is applied, the pipeline
  treats the bucket as mutable (hourly revalidation).

### 3.9 Saved figures

`Lite/Core/StellarSaved.swift` wraps DyorKit's public `SavedScreens`.

- **Directory:** `Application Support/saved-screens-stellar-<network>-<deployment8>`, where `deployment8` is the
  first 8 hex digits of the sha256 of the pinned launchpad and Moments ids. After a redeploy, the old deployment's
  launches never show.
- **Build and keys:** the build string is the app's `version(build)`. Entries are keyed by the account's Monad
  `Address`.
- **Screens:** `.home`, `.portfolio`, `.launchBoard`, `.momentsBoard`, `.myLaunchpad`. The Earn total is part of the
  home snapshot. Earn positions themselves are never saved, as on Monad.
- **When:** written after a full read, under the `SavedScreens` epoch guard. Read in `.onAppear` under
  `withTransaction(\.disablesAnimations, true)`, before the first frame.
- **Erased** for that account by `DyorHQLiteKeys.forget(evm:)` (sign-out and erase device) and by
  `LiteSession.signOut()` (through `onSignOut`).

### 3.10 Rules Lite files must obey (DyorKit source lints and app rules)

1. **Pasteboard.** The only pasteboard write is `UIPasteboard.general.string = address.checksummed`, where
   `address: StellarAccountID` (G… or C…, StrKey CRC checked; `checksummed` is the canonical StrKey).
   - Token IDs, memos and amounts are never copied. They are shown with `.textSelection(.enabled)`.
   - No `copyToPasteboard(text)` helper exists.
2. **Coin value.** No text matching `priceNumber`, `LaunchpadMath.marketCap(` or
   `\b(launch|\$0|\$1)\.(price|marketCap)\b`. Name Stellar variables `coin` or `row`, and use the fields
   `priceQuote`, `marketCapQuote` and `marketCapUsd`.
3. **Titles and search prompts.** `.navigationTitle(` takes `tr(LocalizedStringResource("…", table: "Stellar…",
   comment: "…"))`, `Text(verbatim:)` or a property. `.searchable(prompt:)` takes a `Text`, never a literal.
4. **Helpers.** No view struct stores `title|label|subtitle|detail|caption|message|text|placeholder|note|header|side:
   String` at the top level. No `func … -> some View` takes such a parameter as `String`. Pass a
   `LocalizedStringResource`, a `Text` or the model.
5. **Keys and amounts.**
   - No placeholder-only keys ("%@ %@") at helper calls; write those `verbatim:`.
   - `Amount.parse(` / `fieldNumber(` take a bare field name.
   - Amount fields are written with an exact writer (`StellarFormat.plain(units:decimals:)`), never with `PriceFormat.`,
     `NumberStyle.`, `USDText`, `.formatted(` or `String(format:`.
6. **Forbidden calls.** Never use `env.history.kick`, `history.refresh(`, `.currency(code:`, `"US$"`,
   `String(localized:` with `locale:`, `https://dyorhq.gitbook.io` or `LearnMoreLink`.
7. **Reused keys.** A reused Localizable key is written with no comment, or through its enum label (`HomeTokenTab.label`,
   `HoldingCategory`, `VolumePeriod.label`, `TradeMode.swap.label`, `MenuItem.title`). A new key always names its
   table **before** its comment.
8. **Paragraphs.** Multi-line copy goes through `Paragraph` (KoreanParagraphsTests).
9. **UserDefaults.** Every key starts with `lite.`. App Lock's first-run rule treats `settings.`, `session.`, `mera.`,
   `localWallet.`, `venueTokens.`, `activityLog.`, `notifications.`, `knownTokens.`, `priceAlerts.`, `bridge.` and
   `perp.` as signs of an earlier install (Theme.swift:61-63).
10. **File placement.** No new Swift file outside `ios/DyorHQ/Lite/`.

Every A package runs the full DyorKit suite (§12.3), because these rules are only proven by it.

---

## 4. Hybrid fee model

### 4.1 Who pays what

| What | Payer | Mechanism |
|---|---|---|
| Every ordinary user transaction | **User, in XLM** | The user is the source. Its `fee` field is the most it can cost. No fee-bump. |
| Testnet account activation | Friendbot | `/v1/account/activate` calls Friendbot (10,000 test XLM). |
| Testnet "Enable USDC" after Friendbot | **User** | A plain `changeTrust`. Its 0.5 XLM reserve and the fee come from the user's own test XLM. |
| Mainnet account activation: `createAccount(user, 0)` + sponsored USDC trustline (3 base reserves, 1.5 XLM) and that transaction's fee | DyorHQ sponsor | The existing `activate` builder (account.ts:45-64). The sponsor is the source; sponsor and user both sign. |
| Mainnet starter swap: one swap of a registry asset into XLM while spendable XLM < 0.05 | DyorHQ sponsor | Fee-bump of the user-signed swap, once per address (§4.3). |
| Graduation keeper, TTL/rent keeper, CCTP `mint_and_forward` relay | DyorHQ keeper key (`KEEPER_SECRET`) | The keeper's own transactions. |
| Testnet faucet ("Get 10,000 test XLM", once a day) | Friendbot | Unchanged, testnet only. |

Ordinary user transactions cover: send, trustline, swap, Earn deposit and withdraw, launch create/buy/sell/claim/
graduate, Moment publish and collect, bridge approve and burn, and restore.

**Removed:**
- the fee-bump on every step (plans.ts:154-171, stellar.ts:219-239);
- the trust sponsorship sandwich (account.ts:31-43);
- the 50 XLM per user per day budget (env.ts:45-53, `lite.sponsor_usage`, `lite.reserve_fee_budget`);
- every "Paid by DyorHQ" outside the two sponsored kinds.

### 4.2 Network fee policy (server: `_shared/networks.ts`, phone: `PinnedContracts.feePolicy`)

| Value | Testnet | Mainnet (re-measure before use) | Where it lives |
|---|---|---|---|
| `maxFee`: the most one transaction may declare (`tx.fee`) | 30,000,000 (3 XLM) | 30,000,000 | Pinned in the app and in networks.ts (generated together) |
| `maxInclusionPerOp` | 200,000 (0.02 XLM) | 200,000 | Pinned and networks.ts |
| `starterInnerFeeMax`: the most a sponsored starter step's inner fee may declare | 1,000,000 (0.1 XLM) | 1,000,000 | Pinned and networks.ts |
| `activationMaxFee` | 100,000 | 100,000 | networks.ts |
| `starterThreshold` (spendable XLM below which the starter swap is offered) | n/a (no starter on testnet) | 500,000 (0.05 XLM) | networks.ts |
| `starterMinXlmOut` | n/a | 10,000,000 (1 XLM) | networks.ts |
| `fundingFloor` (the add-funds card shows below it) | 1,000,000 (0.1 XLM) | 1,000,000 | networks.ts |
| inclusion bid | getFeeStats p90 of `inclusionFee` (classic) or `sorobanInclusionFee`, clamped to [100, maxInclusionPerOp ÷ 2], cached 30 s, fallback 100 | same | `_shared/fees.ts` |
| Soroban headroom | +25% instructions (+100k), +20% bytes (+1k), resource fee ×1.15 + 50,000 | same | `_shared/stellar.ts` |

**Why 3 XLM fits testnet.** The largest measured testnet fees are a launch (0.42 XLM), a keeper graduation (0.80 XLM),
a first Blend deposit (0.30 XLM) and a 2-edition collect (0.20 XLM) (research, fees §4). The e2e adds a 20-edition
collect and a first Blend deposit against the cap (§12.6). If any of them exceeds it, the cap is raised in networks.ts
and regenerated into the pins in one commit.

### 4.3 Sponsorship rules

**Activation** (`POST /v1/account/activate`):

| Account state | Response |
|---|---|
| Missing, activation `friendbot` (testnet) | Friendbot as today, then a **user-paid** `trust` plan if USDC isn't enabled. |
| Missing, activation `sponsored` (mainnet; testnet only via `LITE_ACTIVATION=sponsored` on a local stack) | `sponsorAvailable("activate")` is checked read-only first, then `createPlan("activate", …)`. The sponsorship is reserved at submit. |
| Exists | A user-paid `trust` plan if needed. With too little XLM, 409 `not_enough_xlm_for_reserve`; the app shows the add-funds card. |

**Starter swap.** `starterSwapEligibility` is pure and tested.

- **Eligible only when all hold:**
  - activation is `sponsored`;
  - buy is XLM;
  - sell is a registry asset other than XLM;
  - spendable XLM < `starterThreshold`;
  - the quote's minOut ≥ `starterMinXlmOut`;
  - this address has no reserved, sent or successful starter.
- **At build.** `buildSwap` marks an eligible step `feePayer: "sponsor", sponsorReason: "starter_swap"`. If the best
  route's inner fee would exceed `starterInnerFeeMax`, it uses an SDEX route when one exists. Otherwise it builds a
  normal user-paid step, which then fails `not_enough_xlm_for_fee` before signing.
- **At submit.** Eligibility is re-checked live, then `reserve_sponsorship()` runs, then the sponsor fee-bumps (its
  outer fee is capped at `starterInnerFeeMax`).
- **The quote** carries `starterSwap: {eligible, reason}`.

**Abuse limits** live in Postgres (`lite.reserve_sponsorship`, §6.15), never in memory:
- one activation and one starter per address;
- at most 3 attempts per address and kind;
- daily count and fee caps per kind;
- a daily cap per hashed IP: `HMAC-SHA256(LITE_JWT_SECRET, ip + "|" + utcDay)`. Raw IPs are never stored.

Every session belongs to an unrevoked tester: on mainnet an invited one; on testnet (`inviteRequired` false) any
address that signed in. Sponsorship caps are per address. Viewer routes in their public view (§6.0) need no session; they show only on-chain facts and never sponsor
anything.

**What the phone believes.** The phone never trusts the server's word that DyorHQ pays. "Paid by DyorHQ" is shown
for a step only when the phone can verify it:
- (a) the decoded transaction's source is the pinned sponsor and the intent kind is `activate`; or
- (b) the step is flagged `starter_swap` and its decoded inner fee is ≤ the pinned `starterInnerFeeMax`.

PlanRunner refuses a step flagged sponsored whose inner fee exceeds that cap. A lying server can therefore charge a
user it claims to sponsor at most 0.1 XLM, and such a user by definition holds under 0.05 spendable XLM. A test vector
covers this (§12.4).

### 4.4 Phone-side bounds (StellarKit)

**TxVerifier** and `verify.ts` behave identically and share vectors. They add these checks after the expiry and
operation-count checks:

1. `fee > feePolicy.maxFee` → "the network fee is above the limit".
2. Soroban: `resourceFee < 0 || resourceFee > fee` → "the resource fee is out of range". Then
   `fee − resourceFee > maxInclusionPerOp × ops` → "the inclusion fee is above the limit".
3. Classic: `fee > maxInclusionPerOp × ops` → "the inclusion fee is above the limit".
4. The sponsor appears (as source, op source, `beginSponsoringFutureReserves`, or `createAccount` with 0) **only when
   `intent.kind == "activate"`**. Today any intent may carry a sponsor sandwich (TxVerifier.swift:100-147).

**`PlanFees`** (LiteClient, new) is computed on the phone:
- a built step's `maxFee` is its decoded `tx.fee`;
- an unbuilt step's `maxFee` is the server's ceiling for its kind;
- any value above the pinned cap throws, so the sheet never shows a fee the runner would refuse;
- `userMax` sums the user-paid steps;
- `newReserves` sums `reserveDelta`.

**PlanRunner** gets the new signature `run(_ plan:, limits:, fees: PlanFees, signer:, onEvent:)`. After verifying,
it requires `decoded fee ≤ fees.maxFee(step)`; otherwise `Failure.feeAboveConfirmed`, with the message "Not signed:
the network fee for %@ went up since you confirmed. Nothing was sent." An unbuilt step is built later, and its real fee
must fit the number the user confirmed. That is what stops the server choosing fees silently.

### 4.5 Minimum balance, Max and the add-funds card

**Minimum balance.**

```
minBalance = max(0, 2 + subentries + numSponsoring − numSponsored) × baseReserve     // baseReserve from the ledger header
spendable  = max(0, balance − minBalance − sellingLiabilities)
maxSend    = max(0, spendable − feeEstimate(kind) × 5/4 − newReserves × baseReserve)  // XLMReserve.maxSend
```

Server and phone compute the same values. The phone recomputes `spendable` from the parts the server sends, and never
hard-codes 0.5 XLM.

**Worked examples** (base reserve 0.5 XLM):

| Case | minBalance | spendable / Max |
|---|---|---|
| Friendbot account with USDC enabled: balance 10,000, 1 subentry | 1.5 XLM | 9,998.5 spendable; Max of an XLM → USDC Soroswap swap (estimate 0.05) = 9,998.4375 |
| Mainnet sponsored account: balance 0, 1 subentry, 3 sponsored | 0 | 0, so the starter swap is eligible |
| After a starter swap delivered 2 XLM | 0 | 2 XLM, and the user pays their own fees from now on |
| Enabling EURC later | +0.5 XLM of the user's own | `reserveDelta = 1` on the review |

**Max and the percent buttons.**
- **Max of XLM** = `maxSend` for the action's step kind. When the review is open, it uses the built step's real fee.
- **Max of any other asset** = the whole balance; the XLM fee is checked at review.
- **25/50/75%** are shares of `spendable` for XLM and of the balance for other assets. **100%** = Max.

**Add-funds card** (`/v1/account.firstFunding`, computed on the server):

| Field | Rule |
|---|---|
| `needsXlm` | spendable < `fundingFloor` (0.1 XLM) |
| `suggestXlm` | 2 XLM when the account doesn't exist (1 XLM minimum + 0.5 USDC trustline + fees); otherwise 1 XLM plus any reserve the account is missing |
| `starterSwap` | `available` \| `used` \| `unavailable` |
| `faucet` | testnet only: `{amount: "10000", usedToday: bool}` |

### 4.6 UX (mirrors Monad one for one)

**Max network fee row** (review sheet). `DetailRow("Max network fee", summary)` reuses Monad's keys
(TransactionRun.swift:128-138):

| Situation | Summary |
|---|---|
| Every step built | `tr("Up to \(fee)")`, with fee = "0.0154 XLM" (`NumberStyle.number(xlm, maximumFractionDigits: 7)` + " XLM") |
| Some steps not built yet | `tr("Up to \(fee) + \(n) more steps")` |
| Nothing built yet | `tr("Priced as each step is signed")` |

Its footer reuses Monad's paragraph ("The most the network can charge. Each transaction's fee is checked again before
it's signed, and refused if it's unusually high.").

**Sponsored step** (only when verified, §4.3). The value is "Paid by DyorHQ". The footer is one of:
- "DyorHQ pays this one: your account's setup."
- "DyorHQ pays this one: your first swap into XLM. After it, you pay each network fee in XLM."

**Enable section.** For each `trust` step, before the action:
- `DetailRow` "Enable" with the asset code;
- the footer "Stellar holds %@ XLM of your balance while %@ is enabled. It's returned if you remove it.", with
  `baseReserve`;
- on mainnet setup only: "DyorHQ pays this reserve."

**Not enough XLM** (a review preflight, the counterpart of Monad's "Not enough MON to pay for gas.").

```
need = Σ maxFee(user-paid built steps) + Σ feeEstimate(unbuilt user-paid steps) + XLM spent by the plan
       + baseReserve × newReserves
```

If `spendable < need`:
- `InlineError("Not enough XLM for the network fee.")` (or "Not enough XLM for Stellar's minimum balance." when only
  the reserve breaks it);
- the Paragraph "You need about %@ XLM and can spend %@ XLM. Your account keeps %@ XLM to stay open.";
- the button "Add XLM" (`StellarActions.addFunds`; on mainnet with USDC, the starter card's swap).

Confirm stays disabled until a fresh `/v1/account` read clears it. The sheet re-reads the account on appear and on
return from Deposit.

**Forms.** The Swap, Send, Earn and Launch tickets use Monad's form titles. "Insufficient %@" applies when the amount
exceeds the balance, or for XLM exceeds `maxSend`.

**Errors**, mapped by `LiteErrorText` (§6.13):

| Server condition | Copy |
|---|---|
| `not_enough_xlm_for_fee`, `tx_insufficient_balance`, `tx_insufficient_fee` | "Not enough XLM for the network fee." |
| `not_enough_xlm_for_reserve`, `op_low_reserve`, `CHANGE_TRUST_LOW_RESERVE` | "Not enough XLM for Stellar's minimum balance." |
| `not_enough_xlm` | "Not enough XLM. %@ XLM stays in your account." |
| `fee_too_high` / cap refusal | "Not signed: the network fee is unusually high right now (%@ XLM). Nothing was sent. Try again in a minute." |

The add-funds card and these errors ship in the same milestone as the fee change, so the testnet experience never
regresses (§15, RK24).

**Prompts (decision 6).** Reading fees, the preview, Max and the add-funds card never prompts and needs no unlock:
`/v1/fees` and `/v1/config` are public, and the account's XLM position comes from the viewer `/v1/account` (§6.0).
Confirm is the only prompt point, and it follows Monad's ConfirmationSheet (TransactionRun.swift:403-408): Face ID or
the passcode once per confirmed action when `settings.appLockApplies(to: account)`, nothing when App Lock is off, and
the passkey for each signed step on a passkey account (§8.7). When App Lock applies and the device has no passcode,
Confirm refuses with Monad's "App Lock needs a device passcode. Set one in iOS Settings, then try again." (key).

### 4.7 Keeper key

- **Signer.** `stellar.ts` gains `keeper()`, used by graduation (`lite-indexer`), TTL keep-alive and
  `relayMintAndForward`.
- **Fallback.** On testnet, `KEEPER_SECRET` falls back to `SPONSOR_SECRET` and logs one warning. On mainnet it is
  required, and must differ from the sponsor.
- **Logging.** Every keeper transaction goes into `lite.keeper_log`.
- **Pinning.** The sponsor stays pinned in the app, because activation and the starter swap check it, and
  `LiteSession.gate` still compares it (LiteSession.swift:334). The keeper never appears in a user transaction, so it
  isn't pinned.

### 4.8 Submit path

`POST /v1/tx/submit` stays. It feeds:
- the transaction log (Activity, Portfolio, fee estimates);
- the plan state machine;
- the starter fee-bump;
- server re-verification.

It also keeps a keyed RPC off the phone. The server can't change what is sent, because the hash is bound and signed;
it can only withhold it.

`submitStep`, in order:
1. Hash match, `signedBy(user)`, then re-verify.
2. If `fee > maxFee`, 422 `fee_too_high`.
3. Branch on payer:
   - user-paid: `sendUserTx(tx)`;
   - activate: reserve the sponsorship, then `sendSigned`;
   - starter: re-check eligibility, reserve, then `feeBumpAndSend(tx, starterInnerFeeMax)`.
4. On failure: release the sponsorship and mark the step failed.
5. Insert into `tx_log` with `fee_payer`, `step_kind`, `section` and `max_fee`.

`settle()` writes `fee_charged` and `result.amountOut` (§6.11).

A direct-RPC fallback from the phone (send the signed envelope to the pinned keyless RPC, then report it) is **not**
in this program.

### 4.8b Rent and TTL upkeep (protocol upkeep)

The keeper's `ttl` job rotates through, oldest check first, at most 400 per run:
- contract instances: launchpad, Moments, every launch token and every graduated pair;
- the launch-token WASM;
- the launchpad's persistent `Curve(token)` entries for launches traded in the last 90 days, or with holders;
- the Moments contract's persistent `Moment(id)` entries still collecting.

TTL policy: testnet threshold 10 days, extend to 30; mainnet threshold 30, extend to 150. Dead launches (no trade in
90 days and no holders) are not extended. That bounds the keeper's cost against spam launches.

### 4.9 Archived entries: user-paid restore

- **When.** A simulation that answers `restorePreamble` (today `needs_restore`, stellar.ts:155) makes the server insert
  a `restore` step before the action. That step is a `RestoreFootprint` transaction built from the preamble.
- **Verifier.** Both verifiers allow `restoreFootprint` **only** when `intent.kind == "restore"`, with every
  footprint key belonging to:
  - an allowlisted contract;
  - a verified launch token;
  - the pinned launch-token WASM code.

  The fee caps apply.
- **Review.** The step's title is "Restore archived data for %@", and its fee is in the Max network fee row like any
  other user-paid step.
- **Owner.** Usually the entry restored is the user's own balance or position. Protocol state (curves, instances) is
  kept alive by the keeper (§4.8b), so restores are rare.

---

## 5. Security bindings (pinned values and verifier upgrades)

These ship in the same milestone as user-paid fees: from then on a buggy or hostile server could cost users money.
Commit messages in IOS-app must not describe them as vulnerabilities (CLAUDE.md, public repository).

### 5.1 Fee bounds

§4.4.

### 5.2 Destinations, memos and amounts are bound

**`Intent` gains** (StellarCore and verify.ts, decode-tolerant):
- `to: String?`: the G… or C… the user typed or confirmed. For `bridge_out`, it is the Monad address as 0x-hex.
- `memo: {type: "text" | "id" | "hash", value: String}?`.

**Both verifiers enforce:**

| Operation or call | Check |
|---|---|
| `payment` from the user | destination == `intent.to` |
| `createAccount` from the user | destination == `intent.to` |
| A SAC or SEP-41 `transfer`/`transfer_from` the user authorizes | `to` == `intent.to`, unless the call is in the call-rule table below |
| Memo | equals `intent.memo`; no memo when the intent has none |
| `pathPaymentStrictSend` | destination == user (as today) |

**Call-rule table.** A rule per allowlisted function, written by reading each contract's signature in the repo
(`contracts/launchpad`, `contracts/moments`) and the pinned routers' published ABIs:

| Call | Rule |
|---|---|
| Soroswap `swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline)` | `to` == user; `amount_out_min` ≥ `intent.receive` |
| Aquarius swap (`swap_chained` or the router's function in use) | user == `user`; `out_min` ≥ `intent.receive` |
| Launchpad buy / sell | trader == user; `min_tokens_out` / `min_quote_out` ≥ `intent.receive` |
| Blend `submit(from, spender, to, requests)` | `from`, `spender`, `to` == user |
| CCTP `deposit_for_burn` on Stellar | `destination_domain` == pinned Monad domain; `mint_recipient` == `intent.to` as bytes32 |
| Moments `collect` | collector == user |

A rule that can't be written for a function keeps that function out of the allowlist. Shared vectors cover each rule
(§12.4). The review rows always show the bound value (`intent.to`), never a free display string.

### 5.3 Sponsor only in activation

§4.4, rule 4.

### 5.4 Restore only as its own intent

§4.9.

### 5.5 The phone's RPC is pinned

- **Field.** `PinnedContracts` gains `rpcURL` (keyless; testnet `https://soroban-testnet.stellar.org`; mainnet a
  keyless public endpoint, chosen later), generated by gen-pinned.ts from `networks.ts.phoneRpcUrl`.
- **Use.** `ContractInspector` (the launch-token WASM check) and the activation path use it, never `config.rpcUrl`
  (LiteStore.swift:298-300, LiteSession.swift:717).
- **Mismatch.** A different RPC in config is ignored.

### 5.6 Media

The media base is pinned (§3.8). Server-built links that open in Safari, such as explorer links, are rebuilt on the
phone from the pinned network through `StellarExplorer`, so server `explorerUrl` fields are informational only.

### 5.7 The Monad side of the bridge

- **Chain.** `MonadBridgeAdapter` stays hard-pinned to Monad testnet 10143 and `https://testnet-rpc.monad.xyz` while
  Stellar is on testnet.
- **Step checks.** Before signing, every EVM step is decoded by `StellarEvmStepCheck` (Lite/Bridge) against
  `StellarBridgePins`. The pins are per chain: USDC, TokenMessengerV2 and MessageTransmitterV2; testnet values come
  from networks.ts TESTNET `bridge.monad` and `cctp`.

  | Step | Rule |
  |---|---|
  | `approve` | spender == TokenMessengerV2; amount ≤ the typed amount in 6 decimals |
  | `depositForBurn` or `depositForBurnWithHook` | amount == typed; `destinationDomain` == 27; `mintRecipient` == `destinationCaller` == the pinned CctpForwarder as bytes32; `hookData` carries the user's G-address |
  | `receiveMessage` (Claim on Monad) | `to` == MessageTransmitterV2 |

  Any other `to`, or any other function selector, is refused.
- **Fee preview.** `LiteMonadBridge` gains `preview(_ steps:) async throws -> LiteMonadFeePreview?`, with a default
  implementation returning nil, so the protocol change is additive. The adapter implements it with
  `TransactionSender(rpc:chainId:).feePreview(_:from:)` (DyorKit public), so the bridge review shows "Monad network fee:
  Up to %@ MON".
- **Mainnet.** Chain 143 values sit in `StellarBridgePins`, disabled. Enabling them is the mainnet program's job.

### 5.8 Silent sign-in signs only a sign-in (decision 6)

Seed accounts sign the sign-in challenge with no prompt, so the phone must make sure that signature can't be anything
else. Three bindings, all in StellarKit (WP-03b) and the app's key provider (WP-20):

1. **Domain separation (SEP-53).** The provider never exposes a raw signing call for sign-in: it answers
   `signInSignature(for: message)`, which is `StellarSigner.signMessage(_:)`, an ed25519 signature over
   `sha256("Stellar Signed Message:\n" + message)`. A transaction signature is over
   `sha256(networkId ‖ ENVELOPE_TYPE_TX ‖ tx)`, whose first 32 bytes are the network's passphrase hash, never the 24
   ASCII bytes of the SEP-53 prefix, so one can't stand for the other (short of a SHA-256 second preimage).
2. **Shape check before signing.** `LiteAPI.signIn` asks the provider to sign only when the challenge is exactly five
   lines and at most 512 bytes:
   `DyorHQ Lite sign-in` / `Network: <pinned network name>` / `Address: <this account's G…>` /
   `Nonce: <the response's nonce, [A-Za-z0-9_-]{16,64}>` / `Issued: <an ISO-8601 time>`.
   Anything else (another network, another address, a nonce that differs, an extra line) is refused before any key
   is read. The Issued time isn't compared with the phone's clock, so a wrong clock never blocks sign-in.
3. **Self-check after signing.** Before `auth/verify` is sent, LiteAPI verifies the returned signature as SEP-53 over
   that exact message with the account's public key (`StellarSigner.verifyMessage`). A provider that signed without
   the prefix, or signed something else, is caught on the phone.

The seed is read from the Keychain for that one signature and dropped (the item stays
`WhenUnlockedThisDeviceOnly`, never synced). The resulting session can read and build plans but can't sign: every
transaction still needs the seed under the App Lock rule, or the passkey.

### 5.9 Refresh tokens

- **What.** 32 random bytes, base64url with an `lrt_` prefix, issued by `auth/verify` and by every refresh. The
  server stores only `sha256(token)` (`lite.auth_refresh`, §6.15 migration 12).
- **Lifetime.** 30 days from issue, renewed on every use (sliding). Single use: a refresh rotates it. Each sign-in
  starts a family; presenting a token that was already used revokes the whole family (theft signal), and the phone
  falls back to a silent sign-in (seed accounts) or the public view (passkey accounts, §6.18).
- **On the phone.** Kept with the access token in the Keychain item `session.<network>.<G…>`
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable, so never in a backup or on another device).
  Erased by Sign out of Stellar, by app sign-out and by erase-this-device (`DyorHQLiteKeys.forget`), each of which
  also asks the server to revoke the family (best effort, 3 s).
- **Access tokens** drop from 12 hours to 1 hour (`JWT_TTL_S`): they renew silently now, and a leaked one (it can
  read history and build plans, never sign) is useful for less time. Revoking a tester still takes effect at once
  (`requireUser` checks `lite.testers` on every request).

---

## 6. Backend, API and migrations

### 6.0 Conventions

- **Amounts** in base units are decimal-integer **strings** ("12500000" = 1.25 of a 7-decimal asset).
- **USD** values are JSON numbers. Unknown is `null`, never `0`.
- **Prices in a quote asset** are decimal strings in human units ("0.0000021").
- **Changes and rates** are **fractions** (0.0123 = +1.23%). DyorLite exposes `…Percent` accessors (R24).
- **Times** are ISO-8601 UTC with milliseconds.
- **Periods** use the app's `VolumePeriod` raw values: `day | week | month | all`.
- **Auth: three route classes** (decision 6; details in §6.18).
  - **public** (no token, nothing about any account): `auth/*`, `config`, `fees`, `markets*`, `prices`,
    `economics`, `earn/markets`, `earn/history`, `local-media/*`. They read only the database, the in-isolate caches
    and cached contract views, are cacheable (`Cache-Control: public, max-age=30`), and are covered by the
    per-isolate rate limit.
  - **viewer** (a session is optional): `GET /v1/account`, `/v1/holdings`, `/v1/earn/positions`, `/v1/moments/owned`,
    `/v1/launches`, `/v1/launches/:token`, `/v1/moments`, `/v1/moments/:id`, `/v1/assets`. With a valid Bearer token:
    the **owner view** of the token's address, as specified in each section. With no `Authorization` header: the
    **public view** for `?address=G…` (required where the answer is about an account; 400 `address_required`
    otherwise): only on-chain facts, every DyorHQ-history field `null`, `"view": "public"`, `Cache-Control: public,
    max-age=15`. A token that is present but invalid or expired gets 401, so the phone renews instead of silently
    getting less. The public view never checks the tester list and answers every valid G… alike.
  - **session** (JWT required): everything else: DyorHQ's history (`portfolio`, `activity`, `launchpad/me`,
    `moments/mine`, `tx/:hash`) and every write or plan (`account/activate|trust|faucet`, `recipient`, `send`,
    `plans/*`, `tx/submit`, `swap/*`, `earn/build`, `launches/*` writes and quotes, `moments/*` writes, `media/*`,
    `bridge/*`, `cash/*`).
- **New optional fields** decode older payloads in Swift (`decodeIfPresent`).
- **Fixtures.** Every new or changed payload has a fixture in `backend/tests/fixtures/api/<name>.json` (WP-03).
  Deno tests produce the payloads from seeded data and compare them with these. Swift decodes the same files
  (`StellarKit/Tests/LiteClientTests/Fixtures/`, synced by `backend/tests/fixtures/sync.sh`).

### 6.1 Module layout (WP-02)

`lite/index.ts` keeps auth, the router and the module registration order. Routes move into
`lite/routes/<area>.ts`, each exporting `register(router)`:

| Module | Routes | Owner after WP-02 |
|---|---|---|
| auth | `/v1/auth/*` (challenge, verify; refresh and signout from WP-02b) | WP-02, then WP-02b |
| config | `GET /v1/config` | WP-02 |
| fees | `GET /v1/fees` | WP-10 |
| account | `/v1/account`, `/activate`, `/trust`, `/faucet`, `POST /v1/send`, `GET /v1/recipient/:address` | WP-10 |
| plans | `/v1/plans/*`, `/v1/tx/*` | WP-10 |
| swap | `/v1/swap/*` | WP-10 |
| markets | `GET /v1/markets`, `/v1/markets/:id`, `/v1/markets/:id/history`, `GET /v1/prices` | WP-13 |
| assets | `GET /v1/assets` (search) | WP-18 |
| launches | `/v1/launches*`, `/v1/economics`, `/v1/launchpad/me` | WP-14 |
| earn | `/v1/earn/*` | WP-15 |
| moments | `/v1/moments*` (static paths `owned`, `mine` registered before `:id`), `/v1/media/*`, `/v1/local-media/*` | WP-16 |
| bridge, cash | `/v1/bridge/*`, `/v1/cash/*` | WP-17 |
| holdings, portfolio, activity | `GET /v1/holdings`, `GET /v1/portfolio`, `GET /v1/activity` | WP-18 |

WP-02 creates every route module above, existing routes moved verbatim and new ones as empty `register()`
functions. WP-02b (M0) then adds the viewer class to `index.ts`'s guard and `viewer(req)` to `routes/auth.ts`
(§6.18), so `index.ts` never changes after M0. It also adds three transitional exports to `_shared/launchpad.ts`
that WP-14 implements: `launchMarketRows()`, `launchHistory(token, range)` and `launchSearch(q)`, which return `[]`
until then. Launch rows are therefore absent from Top Tokens until WP-14 lands. Nothing fake is shown; the list is
simply shorter.

The router matches the first registered route (http.ts:50-70). `router.test.ts` asserts that every route in a table
answers its own handler, with `/v1/moments/mine` and `/owned` never reaching `:id`.

The indexer (`lite-indexer/index.ts`) keeps the cursor, the reset and the time budget. Jobs move into
`lite-indexer/jobs/<name>.ts`, and the main contract events are handled in `lite-indexer/handlers/<contract>.ts`:

| Job | Owner |
|---|---|
| `main_events` (dispatch only) and `reset` | WP-02 |
| `handlers/launchpad`, `watch`, `reconcile` | WP-14 |
| `handlers/moments` | WP-16 |
| `refprices`, `purge` | WP-13 |
| `settle`, `graduate`, `ttl`, `ops` | WP-10 |
| `bridges` | WP-17 |
| `earn` | WP-15 |

Order: `main_events → watch → refprices → settle → graduate → bridges → ttl → reconcile (10 min) → earn (10 min) →
ops (10 min) → purge (daily)`, within a 45 s budget. Jobs after `bridges` are skipped once 40 s have passed, and
`lite.job_runs` records each one.

**Resets.**
- The "ledger went backwards" wipe runs on testnet only.
- The new-deployment wipe needs testnet, or `LITE_INDEXER_ALLOW_RESET=1`.
- Both truncate every indexed table: launches, launch_trades, moments, moment_collects, pool_swaps, creator_claims,
  token_events, token_balances, watch_contracts, watch_groups, moment_editions. Each truncate is guarded with
  `to_regclass`.
- Metadata and reference tables are kept.

### 6.2 `GET /v1/config` (public; WP-02)

These fields are added; existing fields stay.

```jsonc
{ "network": "testnet", "passphrase": "…", "rpcUrl": "…", "horizonUrl": "…", "activation": "friendbot",
  "sponsor": "G…", "deployment": { "id": "testnet", "launchpad": "C…", "moments": "C…" },
  "explorer": "https://stellar.expert/explorer/testnet",
  "fees": { "payer": "user", "maxFee": "30000000", "maxInclusionPerOp": "200000", "starterInnerFeeMax": "1000000",
            "starterSwap": false, "fundingFloor": "1000000" },
  "faucet": { "amount": "10000" },                       // null off testnet
  "limits": { "momentMaxEditions": 100000, "momentWindowSecs": [3600, 2592000], "collectMax": 20,
              "launchName": [1, 32], "launchSymbol": [2, 10], "uriMax": 256, "uploadBytes": 26214400 },
  "pricing": { "kind": "reference", "source": "Kraken", "network": "mainnet",
               "note": "Testnet assets have no market. XLM and USDC are valued at mainnet market prices." },
  "assets": [ { "id": "XLM", "code": "XLM", "name": "Stellar Lumens", "decimals": 7, "contract": "C…",
                "classic": "native", "note": "Test XLM", "priceRef": "XLM", "logo": "XLM", "listed": true } ],
  "contracts": { "…": "…" }, "allowlist": { "…": [] }, "anchors": [], "bridge": { "…": "…" },
  "flags": { "enabled": true, "maintenance": false }, "minBuild": 24 }
```

- **`assets[].priceRef`:** `XLM` or `USDC`. BUSDC maps to USDC.
- **`assets[].logo`:** a bundled-logo key (`XLM`, `USDC`) or null.
- **`assets[].listed`:** false for BUSDC.
- **Mainnet:** `pricing.kind` is `market` and `pricing.note` is null.
- The phone's own pins win wherever they overlap (I9).

### 6.3 `GET /v1/fees` (public; WP-10)

```json
{ "network": "testnet", "baseReserve": "5000000", "baseFee": "100",
  "inclusionFee": { "classic": "100", "soroban": "150" },
  "estimates": { "payment": "10000", "payment_token": "300000", "trust": "10000", "restore": "500000",
                 "swap_sdex": "10000", "swap_soroswap": "500000", "swap_aquarius": "500000",
                 "blend_submit_deposit": "5000000", "blend_submit_withdraw": "500000",
                 "launch_create": "10000000", "launch_buy": "500000", "launch_sell": "500000",
                 "launch_graduate": "15000000", "launch_claim": "500000", "moment_publish": "3000000",
                 "moment_collect": "10000000", "token_approve": "300000", "cctp_burn": "500000" },
  "estimateBasis": { "swap_soroswap": "history", "launch_create": "default" }, "updatedAt": "…" }
```

**Estimates** are the p90 over 7 days of the declared `max_fee` per `step_kind`, × 5/4. Without history, the
defaults above apply (shipped in Swift too, as `StellarFeeDefaults`). An estimate is never above `maxFee`.

### 6.4 `GET /v1/account` (WP-10)

These fields are added:

```jsonc
{ "address": "G…", "exists": true, "network": "testnet", "activation": "friendbot", "sponsor": "G…",
  "balances": [ /* BalanceRow, real codes: never "TOKEN" (§9) */ ],
  "xlm": { "balance": "100000000000", "minBalance": "15000000", "sellingLiabilities": "0",
           "spendable": "99985000000", "baseReserve": "5000000",
           "reserves": { "base": 2, "subentries": 1, "sponsoring": 0, "sponsored": 0 } },   // null when no account
  "firstFunding": { "needsXlm": false, "suggestXlm": "10000000", "starterSwap": "unavailable",
                    "faucet": { "amount": "10000", "usedToday": false } },
  "reserves": { "subentries": 1, "sponsoredByDyorHQ": 0 } }
```

- **Balances.** Every Horizon trustline, except liquidity-pool shares, plus held launch tokens.
- **`BalanceRow`** gains `kind` (`native|classic|sac|launch`), `verified` and `logo`.
- **Viewer route** (§6.0). The public view (`?address=`) has the same shape with `"view": "public"`;
  `firstFunding.starterSwap` and `firstFunding.faucet.usedToday` are `null` (server state, not on-chain facts), and
  launch balances are the indexed ones, with no live `balance()` call. `needsXlm` and `suggestXlm` stay: they follow
  from the ledger.

**`GET /v1/recipient/:address?asset=`** (WP-10) returns `{ "kind": "account|contract", "exists": bool, "trusts":
bool|null }`. It refuses M… addresses with 400 `muxed_unsupported`. Muxed recipients are out of scope; the copy tells
the user to send to the G… address with the memo their exchange gives.

### 6.5 `GET /v1/holdings` (WP-18)

Feeds Home's balance card, My Holdings, the allocation ring and Portfolio's assets.

```jsonc
{ "address": "G…", "exists": true, "asOf": "…", "pricing": { /* §6.2 */ }, "xlm": { /* §6.4 */ },
  "spot": [ { "id": "USDC", "kind": "registry", "contract": "C…", "classic": "USDC:G…", "code": "USDC",
              "name": "USD Coin", "decimals": 7, "balance": "52300000", "enabled": true, "verified": true,
              "badges": [], "note": "Circle test USDC", "logo": "USDC", "priceUsd": 0.9999, "valueUsd": 5.2295,
              "change24h": 0.0001 } ],
  "earn": [ { "pool": "C…", "poolName": "Blend TestnetV2", "asset": "C…", "code": "XLM", "supplied": "1000000000",
              "deposited": "1000000000", "withdrawn": "0", "earned": "1234", "earnedComplete": true,
              "supplyApy": 0.031, "valueUsd": 19.01 } ],
  "launch": [ { "token": "C…", "symbol": "ECAT", "name": "E2E Cat", "image": null, "balance": "…",
                "priceUsd": 0.0000004, "valueUsd": 0.37, "change24h": 0.12, "phase": "curve", "progress": 0.42,
                "costBasisUsd": 0.4, "pnlUsd": -0.03, "stale": false } ],
  "moments": { "count": 2, "editions": [ { "tokenId": 7, "momentId": 3, "title": "…", "posterUrl": "…",
                                           "mediaUrl": "…", "mediaType": "video", "contract": "C…" } ] },
  "totals": { "spot": 12.3, "earn": 19.01, "launch": 0.37, "moments": 0, "total": 31.68, "complete": true },
  "change24h": { "usd": -0.42, "pct": -0.013, "complete": true },
  "parts": { "spot": "ok", "earn": "ok", "launch": "ok", "moments": "ok" } }
```

**Kinds.**
- `spot[].kind` is `registry`, or `classic` for any other trustline. A classic row has `verified: false`, an
  Unverified badge, and its name and logo from `lite.asset_directory` or null.
- Launch tokens are listed under `launch` only, and counted once.

**Totals.**
- `total` is null and `complete` is false when any part failed. The phone also gates on `parts` through `HomeReadState`.
- Moments are worth 0: editions have no market (Monad counts "no market yet" as zero).
- `change24h.usd = Σ value × c / (1 + c)` over priced holdings.

**Launch balances** come from `lite.token_balances`, confirmed by a live `balance()` view (at most 50 in parallel).
On an RPC failure, the indexed value is shown with `stale: true`.

**Public view** (viewer route, §6.0): the same shape with `"view": "public"`. Balances, Earn `supplied`, editions,
prices, totals and `change24h` are on-chain facts and stay. These are DyorHQ history and are `null`: `earn[].deposited`,
`withdrawn`, `earned` (with `earnedComplete: false`), `launch[].costBasisUsd` and `pnlUsd`. Launch balances are the
indexed ones with no live `balance()` call (no RPC fan-out for an unauthenticated caller), and each answer is cached
15 s per address.

**Asset directory.** On a miss, Horizon `/assets` gives `_links.toml`. The server fetches that toml (https only, 3 s,
at most 100 KB) and reads `[[CURRENCIES]]` for `name` and `image`, keeping https images only. The result is cached
for 7 days. The directory's name is shown. Its logo is **not** shown in v1, because the phone's media policy
accepts only `lite-media` (§3.8): the row shows letters and the Unverified badge.

### 6.6 Markets and assets (WP-13; public)

**`GET /v1/markets`** → `{ "asOf", "pricing", "rows": [MarketRow] }`, in Popular order:
- registry rows with `listed: true`, in registry order;
- then listed, priced launch tokens, by 24h USD volume and then newest;
- at most 50 rows.

Unlisted, smoke and look-alike launches are excluded.

```jsonc
// MarketRow
{ "id": "XLM", "kind": "registry", "contract": "C…", "classic": "native", "code": "XLM", "name": "Stellar Lumens",
  "decimals": 7, "logo": "XLM", "verified": true, "badges": [], "note": "Test XLM",
  "priceUsd": 0.1901, "change24h": -0.0123, "isNew": false, "volume24hUsd": 3712345.2, "marketCapUsd": null,
  "priceSource": { "kind": "reference", "market": "Kraken XLM/USD", "at": "…" }, "stale": false, "launch": null }
// a launch row: "kind": "launch", "id" = "contract" = token, "classic": null, "logo": null,
//   "image": "<lite-media URL>|null", "badges": ["launch"] (+ "lookAlike" never listed),
//   "priceSource": { "kind": "curve"|"pool", "quote": "XLM", "quotePrice": "0.0000021", "at": "…" },
//   "marketCapUsd": priceUsd × circulating, "isNew": created < 24 h (change24h null then),
//   "launch": { "phase": "curve"|"completed"|"graduated", "progress": 0.42, "pair": null }
```

The phone derives the other tabs exactly as `HomeModel.topTokens` does (HomeView.swift:909-919):
- **Hot:** |change| descending;
- **Gainers / Losers:** sorted by change;
- unpriced rows are dropped.

**`GET /v1/markets/:id`** →

```json
{ "row": MarketRow, "about": { "contract": "C…", "classic": "native", "issuer": null, "decimals": 7, "homeDomain": null } }
```

Balances come from the viewer `/v1/account` (§6.0).

**`GET /v1/markets/:id/history?range=day|week|month|all`** →

```json
{ "id": "XLM", "range": "day", "intervalS": 900, "source": "Kraken", "complete": true,
  "points": [{ "t": "…", "usd": 0.1903 }] }
```

- **Registry assets** use `lite.ref_candles`: day uses 900 s buckets, week and month 3600 s, all 86400 s.
- **Launch tokens** use `lite.token_candles` close × `lite.ref_usd_at(quoteRef, bucket)`, forward-filled per bucket
  from max(since, createdAt). Their `source` is `"curve+pool"`.

**`GET /v1/assets?q=`** (viewer: `held` from the token's address, or in the public view from `?address=`; without
either, `held` is `false`) →

```json
{ "results": [ { "id", "kind": "registry"|"launch"|"classic"|"contract", "code", "name", "contract", "classic",
                 "verified", "held" } ] }
```

- At most 30 results, matched with `ilike` on code and name, or exactly on a C… id or a `CODE:G…`.
- A pasted C… id that isn't a launch is looked up live (`symbol()`, `name()`, `decimals()` through the server's RPC)
  and returned as `kind: "contract", verified: false`.

`GET /v1/prices` stays as a thin wrapper (`{usd, reference, at}`) for older clients. Its values come from the
reference cache, BUSDC = USDC through `priceRef`, and the hard-coded 1s are deleted.

### 6.7 `GET /v1/portfolio?period=day|week|month|all` (WP-18)

```jsonc
{ "period": "week", "since": "…", "asOf": "…", "pricing": { },
  "totals": Stats, "sections": { "spot": Stats, "earn": Stats, "launch": Stats, "moments": Stats, "bridge": Stats },
  "activity": [ { "id": "<hash|uuid>", "section": "launch", "kind": "launch_buy", "title": "…", "subtitle": "…",
                  "at": "…", "usd": 3.1, "hash": "…" } ],
  "coverage": { "from": "<first tx_log row>", "note": "Swaps made outside DyorHQ between non-launch assets aren't counted." } }
// Stats = { "volume": 12.5, "fees": 0.13, "pnl": -1.2, "claimedFees": 0, "trades": 4, "pnlComplete": true,
//           "networkFeesXlm": "123400", "networkFeesUsd": 0.0023 }
```

Formulas (`_shared/stats.ts`, pure). All use **today's prices**, as Monad's PortfolioModel does.

| Section | Volume | Fees | P&L | Other |
|---|---|---|---|---|
| spot | Successful `tx_log` swaps with `section='spot'`: amountIn × p(sell), or amountOut × p(buy) when the sell side is unpriced | 0 (venue fees are in the price) | Σ(amountOut × p(buy) − amountIn × p(sell)). A missing `result.amountOut` sets `pnlComplete=false`. | |
| launch | `launch_trades` + `pool_swaps` where trader = user (trades from any wallet count): quote_amount × p(quote) | `launch_trades.fees` × p | received − spent + Σ Δtokens × p(token) | claimedFees = `creator_claims` × p |
| earn | Σ deposit and withdraw intent amounts × p | 0 | (supplied now + withdrawn − deposited) × p. Without recorded deposits, `pnlComplete=false`. | |
| moments | paid × p | paid × platform_bps × p | 0 (pending, not a loss) | claimedFees = creators' proceeds |
| bridge | completed `bridge_transfers` amount × p(USDC) | Circle fee | 0 | trades = count |

- **Network fees** (`networkFeesXlm`) are Σ `fee_charged` over the user-paid `tx_log` rows in the section. They are
  never in `fees`.
- **No double counting.** A launch buy made through DyorHQ is in both `tx_log` and `launch_trades`; only
  `launch_trades` counts toward volume, and `tx_log` contributes only network fees.

### 6.8 Plans, steps and transactions (WP-10)

```jsonc
// PlanStep (added fields)
{ "id": "s1", "label": "…", "status": "built", "stepKind": "swap_soroswap", "intent": { /* §5.2 adds to, memo */ },
  "xdr": "…", "hash": "…", "maxFee": "153400", "feePayer": "user", "sponsorReason": null, "reserveDelta": 0 }
// PlanView (added)
{ "fees": { "userMax": "153400", "sponsored": false, "newReserves": 1 } }
// TxStatus (added)
{ "feeCharged": "41210", "feePayer": "user", "result": { "amountOut": "1903400" } }
```

- **`maxFee`:** for a built step, its `tx.fee`. For an unbuilt step, `feeCeiling(stepKind)` from §6.3.
- **`sponsorReason`:** `setup` (activate) or `starter_swap`, only when `feePayer` is `sponsor`.
- **The phone recomputes** `maxFee` and payer from the XDR (§4.4). The server's values exist for display before a
  step is built.

**Swap** (WP-10):
- **`POST /v1/swap/quote`** keeps every venue's route: `routes: [{venue, amountOut, minOut, priceImpactBps, path,
  best}]`. It adds `needsEnable: [assetId]` and `starterSwap: {eligible, reason}`. `best` and `alternatives` stay
  for older clients.
- **`POST /v1/swap/build`** takes `{quoteId, venue?}`.

**Send.** `POST /v1/send` takes `memo` and sets `intent.to`/`memo`. It refuses a non-XLM send to a missing account,
and a send to an account without the asset's trustline (`recipient_missing`, `recipient_no_trust`).

### 6.9 Launches, economics, Moments, media (WP-14, WP-16)

**`GET /v1/launches?section=explore|graduated&sort=newest|market_cap|near_graduation&q=&limit=50&cursor=`** →
`{ "launches": [LaunchRow], "nextCursor": "…"|null, "counts": { "explore": 12, "graduated": 3 } }`.

- `sort=new|hot|graduated` stays accepted for older clients.
- Explore holds every coin that hasn't graduated, completed curves included.

```jsonc
// LaunchRow (adds to launchpad.ts:30-54)
{ "token": "C…", "creator": "G…", "quote": "C…", "quoteCode": "XLM", "name": "…", "symbol": "…", "uri": "…",
  "image": "<lite-media URL>|null", "description": null, "links": { "website": null, "x": null, "telegram": null },
  "supply": "…", "burned": "0", "circulating": "…", "quoteReserve": "…", "tokenReserve": "…", "realQuote": "…",
  "threshold": "…", "progress": 0.42, "phase": "curve", "completed": false, "graduated": false, "pair": null,
  "priceQuote": "0.0000021", "priceUsd": 0.0000004, "change24h": 0.12, "isNew": false,
  "marketCapQuote": "21000.5", "marketCapUsd": 3990.1, "volume24hQuote": "…", "volume24hUsd": 12.3,
  "trades": 12, "holders": 5, "holdersComplete": true, "feeBps": 100, "protocolShareBps": 5000,
  "creatorFeeBps": 100, "poolFeeBps": null, "lookAlike": false, "lastPrice": "0.0000021",
  "createdAt": "…", "graduatedAt": null, "lastTradeAt": "…" }
```

- **Price:** `priceQuote = quoteReserve / tokenReserve` on the curve, and `pool_quote / pool_token` after graduation.
- **Market cap:** `circulating = supply − burned`, and `marketCapQuote = priceQuote × circulating`.
- **Holders:** `holders = launch_holders(token, [launchpad, pair])`.
- **24h change:** in USD, `(p_now × q_now) / (p_24h × q_24h) − 1`.
- **Pool fee:** `poolFeeBps` is read from the pair or the factory at graduation and kept in backend config, never
  hard-coded in the app.

**`GET /v1/launches/:token`** adds:

```json
{ "stats": { "volume24hQuote": "…", "volume24hUsd": 12.3, "holders": 5, "holdersComplete": true,
             "marketCapQuote": "…", "marketCapUsd": 3990.1, "priceQuote": "…", "priceUsd": 0.0000004, "change24h": 0.12 },
  "creatorFees": { "unclaimed": "…", "claimed": "…", "quote": "XLM", "unclaimedUsd": 0.1, "claimedUsd": 0.2 },
  "you": { "balance": "…", "costBasisQuote": "…", "pnlQuote": "…", "isCreator": false },
  "economics": { "feeBps": 100, "protocolShareBps": 5000, "creatorFeeBps": 100, "supply": "…", "phantom": "…", "threshold": "…" },
  "pricePoints": [{ "t": "…", "price": "…" }] }
```

- `trades` merges curve and pool trades, each with `venue: "curve"|"soroswap"`, newest 50.
- `pricePoints` hold at most 300 points.
- **Viewer routes** (§6.0): the board and the detail answer without a session. In the public view, `you` is
  `{balance, isCreator, costBasisQuote: null, pnlQuote: null}` for `?address=` (indexed balance), or `null` without
  it. `GET /v1/economics` is public.

**`POST /v1/launches/:token/quote`** returns separate `baseFee`, `creatorFee`, `snipeFee`, `used` and `refund`.

**`POST /v1/launches/metadata`** takes `{name, symbol, description?, imageUrl?, website?, x?, telegram?}` and returns
`{ "uri": "<base>launches/<G>/<uuid>.json" }`.
- `imageUrl` must start with `<base>uploads/<user>/`.
- `website` must be https; `x` must be `https://x.com/…` or `https://twitter.com/…`; `telegram` must be `https://t.me/…`.
- Each link is at most 200 characters, and the description at most 500.
- It writes `lite.launch_metadata` and the JSON `{name, symbol, description, image, links}`.

**`POST /v1/launches/build`** (create):
- `uri` must be empty, or a `launch_metadata.uri` created by the same user;
- the ticker must match `^[A-Z0-9]{2,10}$`;
- the name is at most 32 UTF-8 bytes;
- 400 `look_alike_symbol` when `symbolLooksReserved` matches. It folds 0→O, 1/L→I, 5→S and 8→B, then compares
  against `reservedSymbols` and the registry codes.

**`GET /v1/economics`.** Read live from the launchpad's `config()` and `quote_economics(quote)`, and the Moments
contract's `config()` and `quote_rule(quote)`. Cached 5 minutes, never stored.

```json
{ "launchpad": { "contract": "C…", "launchesEnabled": true, "supply": "…", "feeBps": 100, "protocolShareBps": 5000,
                 "maxCreatorFeeBps": 1000, "snipeSchedule": [9800, 2500, 300, 30],
                 "quotes": [ { "asset": "XLM", "contract": "C…", "phantom": "…", "threshold": "…", "enabled": true } ] },
  "moments": { "contract": "C…", "platformBps": 500, "royaltyBps": 500, "publishingEnabled": true,
               "treasury": "G…", "maxPerCollect": 20, "maxEditions": 100000,
               "quotes": [ { "asset": "XLM", "minPrice": "1000000", "enabled": true } ] } }
```

The admin is never exposed. `treasury` is shown only in the publish review.

**`GET /v1/launchpad/me`**:

```json
{ "held": [ { "token": "C…", "balance": "…", "valueUsd": 0.37, "costBasisQuote": "…", "pnlQuote": "…",
              "pnlUsd": -0.03, "onCurve": true, "launch": LaunchRow } ],
  "created": [ { "launch": LaunchRow, "creatorFees": { "unclaimed": "…", "claimed": "…", "quote": "XLM",
                                                        "unclaimedUsd": 0.1, "claimedUsd": 0.2 } } ],
  "fees": { "byQuote": [ { "quote": "XLM", "received": "…", "claimable": "…", "receivedUsd": 0.2, "claimableUsd": 0.1 } ] },
  "activity": [ StellarActivityItem ] }
```

`unclaimed` is `get_curve(token).creator_fees`, read live and cached 30 s.

**Moments** (WP-16):

| Route | Behaviour |
|---|---|
| `GET /v1/moments?filter=all\|collecting\|closed&limit=` | `listed` Moments only. `closed` covers sold out and window closed. |
| `GET /v1/moments/:id` | Adds `collectorsSummary {count, largest {address, editions}}`, `you {editions: [ids still owned], spent}`, `creatorEarned`. |
| `GET /v1/moments/owned` | Reads `lite.moment_editions where owner = user`, replacing the `owner_of` loop (moments.ts:47-59). |
| `GET /v1/moments/mine` | `{ "created": [MomentRow & {"proceeds", "proceedsUsd"}], "collected": [{"tokenId", "momentId", "contract", "moment": MomentRow}], "totals": {"editions", "moments", "spentByQuote", "earnedByQuote"} }` (session: DyorHQ history) |

The feed, `/:id` and `/owned` are viewer routes (§6.0). In the public view, `/:id`'s `you` is
`{editions, spent: null}` for `?address=` (or `null` without it), and `/owned` needs `?address=`.

```jsonc
// MomentRow (adds to moments.ts momentRow)
{ "id": 3, "creator": "G…", "uri": "…", "title": "…", "description": "…", "place": "Accra", "takenOn": "2026-10-14",
  "mediaUrl": "…", "mediaType": "video", "posterUrl": "…", "price": "10000000", "quote": "C…", "quoteCode": "XLM",
  "priceUsd": 0.19, "maxEditions": 10, "minted": 3, "collects": 2, "collectors": 2, "deadline": "…",
  "state": "collecting"|"sold_out"|"closed", "platformBps": 500, "royaltyBps": 500, "publishedAt": "…" }
```

**`POST /v1/moments/metadata`** takes `{title, description?, mediaUrl, mediaType, posterUrl?, place?, takenOn?}` and
returns `{uri, posterUrl}`.
- `posterUrl` is **required for a video**; the phone takes a frame and uploads a JPEG. For a photo, the poster is the
  photo.
- The JSON written follows SEP-50: `name`, `description`, `image` (always: the photo, or the video's poster),
  `animation_url` (videos only) and `attributes`: Creator, Network ("Stellar Testnet" / "Stellar"), Place, Date.
- `external_url` is written only when `LITE_MOMENT_LINK_BASE` is set; there is no such route yet.

**`POST /v1/moments/build`** (publish):
- returns the policy it used (`platformBps`, `royaltyBps`, `minPrice`) in `intent.display`, for the "terms changed"
  guard (§8.11.4);
- adds a user-paid `trust` step when the price is in USDC and the creator lacks the trustline.

**Media** (`POST /v1/media/upload-url`):
- **Paths and types:** signed uploads to `uploads/<user>/<uuid>.<ext>` with no upsert. Images are jpeg, png, webp or
  gif; videos are mp4 or quicktime, with the real content type.
- **Size:** at most 25 MB (`limits.uploadBytes`).
- **Daily budget per user:** 50 uploads and 200 MB, recorded in `lite.media_uploads` and checked before the URL is
  issued. Answers 429 `upload_budget`.
- **Write-once:** a trigger on `storage.objects` refuses updates and moves for `lite-media` (migration 09, guarded for
  CI's plain Postgres, as 20261011000003 is).

**Local media stand-in** (testnet only, and only when `LITE_LOCAL_STORAGE_DIR` is set):
- `PUT /v1/local-media/upload/:token` takes an HMAC of path and expiry under `LITE_JWT_SECRET`, valid 10 minutes, and
  is write-once.
- `GET /v1/local-media/lite-media/<path>` serves the stored content type.
- The stand-in is refused on mainnet.

### 6.10 Earn, activity, bridge, cash (WP-15, WP-17, WP-18)

**Earn** (WP-15):

| Route | Change |
|---|---|
| `GET /v1/earn/markets` | Adds `totalSuppliedUsd`, `freeLiquidityUsd` (supplied − borrowed, in USD), `priceUsd` and `poolStatus` (`active \| on_ice \| frozen`, from Blend's pool status: 0–1 active, 2–3 on ice, 4–5 frozen; setup = frozen). |
| `GET /v1/earn/positions` | Rows become the `earn` holding rows of §6.5. |
| `GET /v1/earn/history?pool=&asset=&range=week\|month` | `{ "points": [{ "t", "supplyApy", "utilization" }] }` from `lite.earn_snapshots`, taken every 10 minutes. |
| Auth classes (§6.0) | `markets` and `history` become public; `positions` is a viewer route whose public view leaves `deposited`, `withdrawn` and `earned` `null` (`earnedComplete: false`). |

**Activity** (WP-18). `GET /v1/activity?section=&kind=&period=&market=&limit=` items add `section`, `hash`,
`feeCharged`, `feePayer`, `result` (with `amountOut`), `ref` (`{token}` or `{momentId}` or `{market}`), resolved
`symbol`/`name`, `title`, `subtitle` and `usd`.

**Bridge** (WP-17):
- **Quote fee:** Iris `GET {iris}/v2/burn/USDC/fees/{src}/{dst}`, row `finalityThreshold 2000`:
  `ceil(amount × minimumFee / 10⁴)`, cached 10 minutes, with `feeSource: "circle-iris"`.
- **ETA:** `etaSeconds` is the median of `updated_at − created_at` over the last 20 completed transfers in that
  direction, or null with fewer than 3 (`etaBasis`). The fixed 60/120 s stub is deleted.
- **Relay limits:** a minimum inbound amount of 1 USDC, and at most 10 relayed inbound transfers per user per UTC day
  (`bridge_relay_limit`).
- **Relay key:** `keeper()`.
- **Mainnet:** the testnet-only 501 gate (bridge.ts:103) stays until the mainnet program.

**Cash** (WP-17):
- `/v1/cash/anchors` is unchanged.
- `POST /v1/cash/track` records the anchor transfer in `tx_log`-linked rows, so the background tracker can resume it
  from `/v1/activity`.

### 6.11 Indexer additions

**Main filter** (launchpad and Moments; handlers are pure `decode*(event)` functions, unit-tested):

| Event | New behaviour |
|---|---|
| launchpad `launch` | `listed = token ∉ deployment.smoke.launches`; `look_alike = symbolLooksReserved(symbol)`; metadata joined from `lite.launch_metadata` by uri (an image uri on our storage counts as the image); watches the token (`watch_contracts`, role `token`). |
| `trade` | as today, plus `last_trade_at`. |
| `graduate` | Records `burned`, `pool_token`, `pool_quote`, `graduated_ledger`, `graduated_at` and `pair_token0_is_launch` (read once with `token_0`). Watches the pair (role `pair`). |
| `claim_creator` | Inserts into `creator_claims`; adds to `launches.creator_fees_claimed`. |
| Moments `publish` | Metadata from `moment_metadata` by uri; otherwise fetched **only** from our storage base. Reads `get_moment(id)` for `platform_bps` and `royalty_bps`. `listed = title && image && id ∉ deployment.smoke.moments`. |
| `collect` | As today, plus `moment_editions(first…first+qty−1, owner = collector)`; `collectors = count(distinct)`. |
| Moments NFT `transfer` | `moment_editions.owner = to`. |

**Watched contracts** (launch tokens and graduated pairs; `jobs/watch.ts`):
- **Request shape.** At most 5 filters × 5 contract ids per `getEvents` request, and 10,000 ledgers scanned (verified
  in go-stellar-sdk), so one request covers a group of up to 25 contracts. Each group has its own cursor, starting
  at its members' creation ledger.
- **Merging and duplicates.** Groups that have caught up merge, keeping the smaller cursor. `event_id` primary keys
  remove duplicates.
- **Gaps.** A start older than RPC retention, or a refused cursor, marks the tokens `holders_complete = false`.
- **Token events** (OpenZeppelin stellar-tokens 0.7.2): `transfer [transfer, from, to]` with data `i128` or
  `{amount, to_muxed_id}`; `mint [mint, to] {amount}`; `burn [burn, from] {amount}`. They update `token_balances`
  in the same transaction as the event insert.
- **Pair events** (Soroswap `("SoroswapPair", name)`): `sync`, `deposit` and `withdraw` set reserves and `last_price`.
  `swap` inserts into `pool_swaps`. Side is `buy` when the launch token goes out. The price comes from the `sync` in
  the same transaction.
- **Reconcile** (every 10 minutes): 60 balances per run, oldest check first, against a live `balance()`. Mismatches are
  overwritten and counted.

**Settle outcome** (`outcomeOf(stepKind, settled)`, pure). `amountOut` comes from:

| Step kind | Source |
|---|---|
| `swap_sdex` | the `pathPaymentStrictSend` result's last amount |
| `swap_soroswap` | the last element of the returned `Vec<i128>` |
| `swap_aquarius` | the returned `u128` |
| `launch_buy` | `tokens_out` |
| `launch_sell` | `quote_out` |
| others | `returnValue` |

**Section** (`sectionOf(intent)`):
- a swap is `launch` when either side is a launch, otherwise `spot`;
- payment → `spot`;
- trust, activate, faucet, restore → `account`;
- `earn_*` → `earn`; `launch_*` → `launch`; `moment_*` → `moments`;
- approve and `bridge_out` → `bridge`.

**Snapshots and ops:** Earn snapshots every 10 minutes. Ops every 10 minutes reads the sponsor and keeper XLM into
`job_runs('ops')`, warning below `LITE_SPONSOR_MIN_XLM` and `LITE_KEEPER_MIN_XLM`.

### 6.12 Reference prices (WP-13)

- **Provider-agnostic module** `_shared/refprices.ts` with adapters. Kraken is the default (Q1):
  - ticker `GET https://api.kraken.com/0/public/Ticker?pair=XLMUSD,USDCUSD`;
  - OHLC `…/OHLC?pair=…&interval=15|60|1440&since=`.
- **Fallback for XLM:** Horizon mainnet `trade_aggregations` (native/USDC:GA5ZSEJY…, 15 min) × the last good USDC/USD.
  USDC never falls back to a constant: with no fresh value, its price is `null`.
- **Cadence.** The indexer's `refprices` job writes `lite.ref_quotes` every run and `lite.ref_candles` every 5 minutes
  (15m), hourly (1h) and daily (1d). The first run backfills. `purge` keeps 15m for 35 days and 1h for 400 days.
- **Reading.** The API reads from the database with a 15 s in-isolate cache. A quote older than 10 minutes is
  `stale: true`; one older than 24 hours is `null`.
- **24h change:** `last / close(bucket at floor(now − 24h)) − 1`, else the 1h candles, else null.
- **Attribution:** the token page's source line names the provider ("Mainnet market price (Kraken). …", §8.3). If the
  owner picks CoinGecko, its required "Price data: CoinGecko" line replaces it.

### 6.13 Error codes

| HTTP / code | When | App copy (Stellar tables, 5 languages) |
|---|---|---|
| 409 `not_enough_xlm_for_fee` | fee > spendable; also `tx_insufficient_balance`/`tx_insufficient_fee` at submit | Not enough XLM for the network fee. |
| 409 `not_enough_xlm_for_reserve` | a new trustline's 0.5 XLM doesn't fit; `op_low_reserve`, `CHANGE_TRUST_LOW_RESERVE` | Not enough XLM for Stellar's minimum balance. |
| 409 `not_enough_xlm` | amount + fee + reserve > spendable; `op_underfunded` (native) | Not enough XLM. %@ XLM stays in your account. |
| 422 `fee_too_high` | built `tx.fee > maxFee` | Not signed: the network fee is unusually high right now (%@ XLM). Nothing was sent. Try again in a minute. |
| 429 `sponsor_limit` | daily, IP or attempt cap | DyorHQ's free setup is busy today. Try again tomorrow. |
| 409 `already_set_up` | activate or starter already used | Your account is already set up. |
| 400 `unsupported_asset` | id not in the registry, `lite.launches`, a valid `CODE:ISSUER` or a C… token | DyorHQ doesn't support that token on Stellar. |
| 400 `look_alike_symbol` | create with a reserved-looking ticker | That ticker looks like another token's. Choose another. |
| 400 `muxed_unsupported` | M… recipient | Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given. |
| 409 `recipient_missing` / `recipient_no_trust` | send checks | This account doesn't exist yet, so it can't receive %@. / This account hasn't enabled %@, so it can't receive it. |
| 422 `simulation_failed` with `contractCode` | stable per contract error: `launch.slippage`, `launch.closed`, `launch.disabled`, `launch.nothing_to_claim`, `moment.closed`, `moment.sold_out`, `moment.price_too_low`, `trust.missing` | The price moved past your 1% limit. Nothing was sent. Review again for a new price. / This curve isn't taking trades now. / New launches are paused. / Nothing to claim yet. / This Moment's collect window has closed. / This Moment is sold out. / The price is below the minimum (%@). / Enable %@ first. |
| 429 `upload_budget`, `bridge_relay_limit` | budgets | You've uploaded a lot today. Try again tomorrow. / You've bridged in many times today. Try again tomorrow. |
| 422 `tx_rejected` (existing) | other send errors | the server message, verbatim |
| 401 `unauthorized` (existing) | a Bearer token that is invalid or expired | none: the phone renews silently and retries once (§6.18) |
| 401 `refresh_invalid` / `refresh_reused` | refresh token unknown, expired or revoked / already used (the family is revoked) | none: silent sign-in (seed accounts) or the public view (passkey accounts) |
| 400 `address_required` | a viewer route about an account called with neither a token nor `?address=` | none (a phone bug) |

### 6.14 Environment

| Var | Change |
|---|---|
| `LITE_DAILY_FEE_BUDGET`, `LITE_MAX_FEE_PER_TX`, `MONAD_RELAYER_KEY`, `SOROSWAP_API_KEY` | Removed |
| `KEEPER_SECRET` | Testnet falls back to the sponsor, with a warning. Mainnet: required, and must differ from the sponsor. |
| `LITE_ACTIVATION` | `friendbot` (testnet default); `sponsored` rehearses mainnet locally. Mainnet is always `sponsored`. |
| `LITE_SPONSOR_ACTIVATIONS_PER_DAY` | 1000 / 200 |
| `LITE_SPONSOR_STARTERS_PER_DAY` | 1000 / 200 |
| `LITE_SPONSOR_PER_IP_PER_DAY` | 5 / 3 |
| `LITE_SPONSOR_DAILY_FEE_CAP` (stroops per day, per kind) | 1,000,000,000 / 200,000,000 |
| `LITE_SPONSOR_MAX_ATTEMPTS` | 3 |
| `LITE_SPONSOR_MIN_XLM`, `LITE_KEEPER_MIN_XLM` | 100 |
| `LITE_DEPLOYMENT` | Default: the network name. `testnet-qa` selects the QA deployment (§6.16). |
| `LITE_INDEXER_ALLOW_RESET` | — |
| `LITE_MOMENT_LINK_BASE` | — |
| `LITE_LOCAL_STORAGE_DIR`, `LITE_PUBLIC_BASE` | Local stack only; refused on mainnet. |
| `LITE_JWT_TTL_S`, `LITE_REFRESH_TTL_S` (WP-02b) | QA overrides of the access-token (default 3600) and refresh-token (default 2592000) lifetimes, so the "no prompt after expiry" checks run in minutes. Testnet only, at least 60 and 120 s; ignored with a warning on mainnet. `local-stack.sh --short-sessions` writes 120 / 600. |

Numeric pairs are testnet / mainnet. `networkByName` throws on any name other than `testnet` or `mainnet`.

### 6.15 Migrations

Each migration repeats the RLS-and-policy loop of 20261013000004 for new tables, revokes `PUBLIC` execute on new
functions and grants `lite_api`. Storage changes are guarded with `to_regclass('storage.objects')`.

| File | Owner | Contents |
|---|---|---|
| `20261014000005_lite_fees.sql` | WP-10 | `tx_log` + `fee_payer` (earlier rows `sponsor`, default `user`; check `user\|sponsor\|external`), `step_kind`, `result jsonb`, `section`, `max_fee`, `fee_charged`, index on (`step_kind`, `created_at`) where success. Drops `reserve_fee_budget` and `sponsor_usage`. New `lite.sponsorships` with the unique once-index and `lite.reserve_sponsorship(...)` (backend spec §4 text, adopted as is), `lite.keeper_log`, `lite.job_runs`. |
| `20261014000006_lite_prices.sql` | WP-13 | `lite.ref_quotes`, `lite.ref_candles`, `lite.ref_usd_at()`, `lite.asset_directory`. |
| `20261014000007_lite_launch.sql` | WP-14 | `launch_metadata`; new `launches` columns (burned, pool_token, pool_quote, pair_token0_is_launch, graduated_ledger, graduated_at, last_trade_at, creator_fees_claimed, image_url, description, links jsonb, listed, look_alike, holders_complete, ttl_checked_at, pool_fee_bps); `pool_swaps`, `creator_claims`, `watch_groups`, `watch_contracts`, `token_events`, `token_balances`; functions `token_candles`, `token_price_at`, `launch_holders`. |
| `20261014000008_lite_earn.sql` | WP-15 | `earn_snapshots`. |
| `20261014000009_lite_moments_media.sql` | WP-16 | `moment_metadata`; new `moments` columns (description, place, taken_on, media_type, poster_url, platform_bps, royalty_bps, collectors, listed); `moment_editions`; `media_uploads`; the guarded write-once trigger for `lite-media`. |
| `20261014000010_lite_portfolio.sql` | WP-18 | Indexes for portfolio and activity reads (`tx_log(address, section, created_at)`, `launch_trades(trader, ts)`, `moment_collects(collector, ts)`). |
| `20261014000011_lite_bridge.sql` | WP-17 | `bridge_transfers.relay_day` and an index for the relay cap. |
| `20261014000012_lite_auth_refresh.sql` | WP-02b | `lite.auth_refresh` (`id uuid`, `family uuid`, `address`, `token_hash text unique` (sha256 hex), `created_at`, `expires_at`, `used_at`, `revoked_at`, `replaced_by`), indexes on `family` and `address`, the RLS loop, `lite_api` grants. No raw token is ever stored. |
| `20261014000013_lite_wallet_history.sql` | WP-63 (M4) | `lite.external_trades` (renumbered from 12 so the M0 migration sorts first). |

Hosted order (owner, O-2): 20261011000001, 0004, 0003, 0002 (the cron, last), then 0005 to 0012 in order, before the
cron is switched on. 0013 comes with M4.

### 6.16 Deployments, smoke items and the QA deployment (WP-04)

- **Registry.** `_shared/deployments/index.ts` exports deployments by name: `testnet` (live), `testnet-qa` (optional)
  and `mainnet: null`. The indexer and `networks.ts` select by `LITE_DEPLOYMENT`.
- **Deployment JSON** gains `smoke: {launches: [token], moments: [id]}` and `indexFromLedger`.
- **Today's deployment.** WP-04 records its existing smoke items (the "Deploy Check" CHECK launch and Moment #1),
  found from the deploy's own chain events. The indexer then marks them `listed = false`, so they leave the live feeds
  **before** the owner's redeploy. The UI never filters anything by hand.
- **`deploy-contracts.ts --deployment <name>`:**
  - every deployment except `testnet-qa` refuses to generate keys: it needs `DEPLOYER_SECRET` and `TREASURY_PUBLIC`,
    read silently;
  - a preflight checks that admin and treasury exist and that the treasury trusts every enabled classic quote (USDC);
  - economics come from `economics.<name>.json`;
  - the smoke test is opt-in (`SMOKE=1`, refused on mainnet), and `indexFromLedger` is the ledger after configuration
    and any smoke.
- **`gen-pinned.ts --deployment <name>`** writes `PinnedContracts+<Name>.swift`, with `feePolicy` and `rpcURL` taken
  from `networks.ts`.
- **`testnet-qa`** has throwaway keys (`.secrets/testnet-qa-deployer.env`) and small economics. It exists only if the
  owner allows it (Q3). Debug builds select it with `LITE_PINNED=testnet-qa`; Release ignores the setting.

### 6.17 Local stack (WP-04)

`backend/scripts/local-stack.sh` gains:
- **Incremental migrations:** a `local_stack_migrations` table and a `migrate` command.
- **Parallel stacks:** `PORT_BASE` (API, indexer, Postgres, storage stand-in) and a per-worktree state directory.
- **Quiet runs:** `--no-loop` and `LITE_KEEPER=off`, so package stacks never race the sponsor's sequence number.
- **Options:** `--deployment <name>`; `--activation sponsored`, which writes `LITE_ACTIVATION=sponsored` for the
  starter rehearsal; the local media stand-in env (`LITE_LOCAL_STORAGE_DIR`, `LITE_PUBLIC_BASE`).
- **`status`:** fee payer mode, sponsor and keeper XLM, reference price age and watch groups.
- **`e2e [phases…]`.**

`lite_schema_test.sql` runs inside `begin; … rollback;`.

### 6.18 Sessions: sign-in, refresh, sign-out and the viewer class (WP-02b; decision 6)

**Sign-in** (unchanged routes, changed answer):
- `POST /v1/auth/challenge {address}` → `{nonce, message, expiresAt}` as today (nonce single use, 5 minutes).
- `POST /v1/auth/verify {address, nonce, signature, inviteCode?}` → `{token, expiresAt, refreshToken,
  refreshExpiresAt, tester}`. `token` is the HS256 access JWT, now 1 hour (`LITE_JWT_TTL_S` on testnet QA only).
  `refreshToken` starts a new family (§5.9). An `inviteCode` sent by an existing tester is ignored, not consumed, so
  the phone may send one whenever it has one.

**`POST /v1/auth/refresh {address, refreshToken}`** (public; 30 a minute per IP) → the same answer as verify:
1. In one transaction: `update lite.auth_refresh set used_at = now() where token_hash = $h and address = $a and
   used_at is null and revoked_at is null and expires_at > now() returning family`.
2. No row, and the hash exists with `used_at` set: revoke the family, 401 `refresh_reused`. No row otherwise: 401
   `refresh_invalid`.
3. The tester must still be allowed (403 `access_revoked` otherwise, and the family is revoked).
4. Insert the successor in the same family (`replaced_by` on the old row), expiring 30 days from now; sign a new
   access JWT.
5. Opportunistic cleanup: delete at most 500 rows that expired more than 7 days ago.

**`POST /v1/auth/signout {refreshToken}`** (public; 20 a minute per IP) → 204. Revokes that token's family. Unknown
tokens also get 204 (no oracle).

**Guard** (`lite/index.ts`, `routes/auth.ts`):

```ts
const PUBLIC = /^[A-Z]+ \/v1\/(auth\/|config$|fees$|markets(\/|$)|prices$|economics$|earn\/(markets|history)$|local-media\/)/;
const VIEWER = /^GET \/v1\/(account|holdings|earn\/positions|moments\/owned|launches(\/:token)?|moments(\/:id)?|assets)$/;
before(req, route):
  public                         → rateLimit(`public:${ip}`, 300)
  viewer, no Authorization header → rateLimit(`view:${ip}`, 120)        // public view
  otherwise                      → await auth.user(req)                 // 401 / 403 as today
viewer(req) → { address, scope: "owner" } from the token, or { address: ?address (StrKey-checked) | null, scope: "public" }
```

Handlers of viewer routes call `viewer(req)` and build the public view from on-chain and indexed data only
(§6.4, §6.5, §6.9, §6.10). The public view answers every valid G… alike, member or not, so it reveals nothing about
who uses DyorHQ.

**What the phone does** (StellarKit WP-03b, DyorLite WP-12):

| When | What happens | Prompt |
|---|---|---|
| Before expiry | While the app is active, the session renews 10 minutes before `expiresAt`, and again on becoming active if less than 10 minutes are left. | never |
| A 401 on any authenticated request | LiteAPI runs one renewal (shared by concurrent requests) and retries the request once. | never |
| Renewal order | 1. `auth/refresh` with the stored refresh token. 2. Seed accounts: the silent SEP-53 sign-in (§5.8). 3. Otherwise: no session. Viewer requests are retried without the token (public view); session requests report "needs sign-in" to the screen (§8). | never |
| 403 `access_revoked` | The paused card with "Access to Stellar was turned off for this account." (not a lock: a server refusal). | never |
| Offline | The token is kept; reads fail with Monad's error and Retry states over the saved figures. | never |
| A passkey account with no session that starts an action, or taps a history part's "Sign in with your passkey" | `session.signIn()`: one passkey ceremony, used for the SEP-53 sign-in only, then dropped. An action's own per-step passkey prompts follow as usual. This happens only after the refresh token was lost (revoked, signed out, or 30 days unused). | the passkey, once |

---

## 7. StellarKit and DyorLite (the headless layer)

### 7.1 StellarKit

**WP-03 (API contract):**
- the renames of §3.4;
- every new Codable model for §6, with new optional fields decoded by `decodeIfPresent`;
- every new `LiteAPI` method;
- fixtures, plus `LiteClientTests.testDecodesApiFixtures`.

New models, all `Stellar`-prefixed:
`StellarFees`, `StellarXLMPosition`, `StellarFirstFunding`, `StellarPricing`, `StellarStats`, `StellarMarketRow`,
`StellarMarkets`, `StellarMarketDetail`, `StellarPriceHistory`, `StellarAssetResult`, `StellarRecipient`,
`StellarHoldings` (+ rows), `StellarPortfolio`, `StellarLaunchBoard`, `StellarEconomics`, `StellarMyLaunchpad`,
`StellarMomentsMine`, `StellarEarnHistory`, `StellarQuoteRoute`, and `VolumePeriodKey` (`day|week|month|all`).

Changed models:
- `PlanStep` gains `stepKind`, `maxFee`, `feePayer`, `sponsorReason`, `reserveDelta`.
- `PlanView` gains `fees`.
- `TxStatus` gains `feeCharged`, `feePayer`, `result`.
- `AccountView` gains `xlm` and `firstFunding`.
- `LiteConfig` gains `deployment`, `explorer`, `fees`, `faucet`, `limits`, `pricing`.
- `AssetInfo` gains `priceRef`, `logo`, `listed`.
- `SwapQuote` gains `routes`, `needsEnable`, `starterSwap`.
- `EarnMarket` gains `totalSuppliedUsd`, `freeLiquidityUsd`, `priceUsd`, `poolStatus`.
- `StellarLaunch` gains the §6.9 fields.
- `StellarMoment` gains the §6.9 fields.
- `StellarActivityItem` gains the §6.10 fields.
- `Intent` gains `to`, `memo`.

**WP-03b (sessions without gating, decision 6):**
- `AuthResult` gains `refreshToken` and `refreshExpiresAt` (optional, so older answers decode).
- Viewer payloads gain an optional `view` (`owner | public`). Fields that are `null` in the public view become
  optional where they weren't: `StellarFirstFunding.starterSwap`, its `faucet.usedToday`, and the Moment detail's
  `you.spent`.
- **`LiteAPI`:**
  - `signIn(address:inviteCode:timeout:sign:)`, where `sign: @Sendable (String) async throws -> String` returns a
    SEP-53 signature. It runs the §5.8 shape check before calling `sign`, and verifies the result before
    `auth/verify`. The old `signIn(signer:inviteCode:timeout:)` stays as a wrapper over it.
  - `init(baseURL:network:session:)`: the pinned network name, for the shape check.
  - `refresh(address:refreshToken:timeout:) -> AuthResult` and `revoke(refreshToken:)` (`auth/signout`, best effort).
  - Three access modes replace `authenticated: Bool`: `.public` (never a token), `.viewer` (the token when held,
    otherwise `?address=` from `viewerAddress`), `.session` (token required).
  - `setRenewal(_:)`: on a 401 to a request that carried a token, one shared renewal, then one retry. If renewal
    fails, a viewer request is retried without the token, and a session request throws `.notSignedIn`.
- `StellarKeychain`'s session item also holds `refreshToken` and `refreshExpiresAt` (decode-tolerant), with the same
  this-device-only attributes. `eraseSession` and `erase` remove them.
- `contract.ts` and `API-lite.md` carry the three classes, the refresh and signout routes, the public-view field table
  and the codes `refresh_invalid`, `refresh_reused` and `address_required`. `prices` is public, as WP-02 serves it.

**WP-11 (verifiers and fees):**
- `PinnedContracts.feePolicy: FeePolicy {maxFee, maxInclusionFeePerOp, starterInnerFeeMax}` and
  `PinnedContracts.rpcURL`. The init has defaults (`FeePolicy.standard`, the testnet RPC), so the code compiles before
  the generated file is regenerated.
- `StellarCore/Fees/XLMReserve.swift`.
- `LiteClient/PlanFees.swift`.
- The PlanRunner signature, `Failure.feeAboveConfirmed`, and the `PlanBackend` / `LaunchTokenInspecting` protocols,
  so tests can pass fakes.
- The TxVerifier rules (§4.4, §5.2, §4.9).
- XDR decoding of the memo, footprint keys and `ScVal` arguments the call rules need.

### 7.2 DyorLite public API (WP-12)

```swift
public struct LiteEnvironment: Sendable {                       // + mediaBase, renderBase (pinned by the host)
  public let apiURL: URL; public let pinned: PinnedContracts; public let buildNumber: Int
  public let mediaBase: URL; public let renderBase: URL?
}
public protocol LiteMonadBridge: Sendable {                      // + preview, default nil (additive)
  var monadAddress: String { get }
  func send(_ steps: [EvmStep]) async throws -> String
  func preview(_ steps: [EvmStep]) async throws -> LiteMonadFeePreview?
}

// The host's key provider (decision 6). Nothing here hands out a signer outside a signing run.
public protocol LiteKeyProvider: Sendable {
  var address: String { get }; var canSign: Bool { get }; var methodLabel: String { get }; var canExportSecret: Bool { get }
  var signsInSilently: Bool { get }                       // true: a seed on this iPhone; false: passkey, watch-only
  func signInSignature(for message: String) async throws -> String   // SEP-53, base64; never prompts (§5.8);
                                                          // throws LiteSession.Failure.needsPasskey when !signsInSilently
  func beginSigning(reason: String) async throws -> LiteSigningRun  // seed: App Lock once, only when it applies
                                                          // (Monad's rule, read live); passkey: no prompt here
  func revealSecret(reason: String) async throws -> String           // always the device owner (Face ID or passcode),
}                                                         // whatever App Lock says, as Monad's key export
public protocol LiteSigningRun: Sendable {                // one confirmed action; holds no secret
  func signer(reason: String) async throws -> StellarSigner           // seed: Keychain read, no prompt; passkey: one
  func end()                                              // ceremony per call. After end(), signer throws.
}

@MainActor @Observable public final class LiteSession {         // today's API, changed by decision 6:
  public enum HomePhase: Equatable, Sendable { case loading, ready, paused(Failure) }   // was internal; no `locked`
  public enum Access: Equatable, Sendable { case session, publicView }   // publicView: reading with no session
  public enum Step: Hashable, Sendable { case signIn, invite, setUp }   // no `unlock`
  public private(set) var home: HomePhase; public private(set) var access: Access
  public private(set) var address: String?; public let env: LiteEnvironment
  public var methodLabel: String? { get }; public var canExportSecret: Bool { get }; public var canSign: Bool { get }
  public var isTestnet: Bool { get }
  public let publicReads: LitePublicReads                        // markets with no token at all
  public init(env:stellarAddress:monad:keys:setupKey:)            // setupKey: a passkey account's one setup ceremony
  public func plan() -> Plan                                       // .instant once set up on this iPhone, unless signed out
  public func resumeAtLaunch() async                               // never prompts; .ready when set up; renews in the background
  public func signIn() async throws                                // seed: silent; passkey: one ceremony (sign-in only)
  public func appDidBecomeActive()                                 // renews if under 10 minutes are left
  public func appDidEnterBackground()                              // stops the renewal timer; ends a running setup run
  public func refreshHome() async
  public func revealSecret(reason: String) async throws -> String   // replaces views calling signer(reason:).secret
  public func signOut() async                                      // revokes the refresh family; erases session and figures
  public var onSettled: (@MainActor (LiteSettledAction) -> Void)?
  public var onSignOut: (@MainActor (String) -> Void)?           // the host erases its saved figures
  public var setupFee: PlanFees? { get }                           // the trust step's fee + reserve: estimate, then decoded (§8.14)
}

@MainActor @Observable public final class LitePublicReads {
  public private(set) var markets: [StellarMarketRow]; public private(set) var marketsError: String?
  public func refreshMarkets() async
  public func market(_ id: String) async throws -> StellarMarketDetail
  public func history(_ id: String, range: VolumePeriodKey) async throws -> StellarPriceHistory
}

@MainActor @Observable public final class LiteStore {
  // reads (nil/empty until read; `parts` says which answered)
  public private(set) var config: LiteConfig?, account: AccountView?, fees: StellarFees?, holdings: StellarHoldings?
  public private(set) var earnMarkets: [EarnMarket], activity: [StellarActivityItem]   // `markets` renamed earnMarkets
  public private(set) var portfolio: [VolumePeriodKey: StellarPortfolio]
  public private(set) var parts: [LitePart: LiteReadStatus]     // spot, earn, launch, moments, activity, portfolio
  public private(set) var lastError: String?, updatedAt: Date?
  public func refreshAll() async; public func refreshAccount() async; public func refreshHoldings() async
  public func refreshEarn() async; public func refreshActivity(section: String?, kind: String?, period: VolumePeriodKey?) async
  public func refreshPortfolio(_ period: VolumePeriodKey) async
  public func launchBoard(section: String, sort: String, query: String?, cursor: String?) async throws -> StellarLaunchBoard
  public func launchDetail(_ token: String) async throws -> StellarLaunchDetail
  public func economics() async throws -> StellarEconomics
  public func myLaunchpad() async throws -> StellarMyLaunchpad
  public func moments(filter: String) async throws -> [StellarMoment]
  public func momentDetail(_ id: Int) async throws -> StellarMomentDetail
  public func myMoments() async throws -> StellarMomentsMine
  public func earnHistory(pool: String, asset: String, range: VolumePeriodKey) async throws -> StellarEarnHistory
  public func searchAssets(_ q: String) async throws -> [StellarAssetResult]
  public func recipient(_ address: String, asset: String) async throws -> StellarRecipient
  // actions → PreparedAction (verified, fee-priced)
  public func swapQuote(sell:buy:amount:slippageBps:) async throws -> SwapQuote
  public func swapPlan(_ quote: SwapQuote, venue: String) async throws -> PreparedAction
  public func sendPlan(asset:to:amount:memo:) async throws -> PreparedAction
  public func enablePlan(asset:) async throws -> PreparedAction
  public func earnPlan(deposit:market:amount:) async throws -> PreparedAction
  public func launchQuote(token:buy:amount:) async throws -> StellarLaunchQuote
  public func launchTradePlan(token:buy:amount:minOut:) async throws -> PreparedAction
  public func launchCreatePlan(_ form: StellarLaunchForm, image: Data?) async throws -> PreparedAction  // metadata inside
  public func graduatePlan(token:) async throws -> PreparedAction; public func claimPlan(tokens: [String]) async throws -> [PreparedAction]
  public func publishPlan(_ form: StellarMomentForm, media: StellarMedia) async throws -> PreparedAction // poster inside
  public func collectPlan(moment:quantity:) async throws -> PreparedAction
  public func bridgeOutPlan(amount:monadAddress:) async throws -> (PreparedAction, BridgeTransfer)
  public func bridgeIn(amount6:) async throws -> BridgeTransfer; public func bridgePreview(amount6:) async throws -> LiteMonadFeePreview?
  public func bridgeStatus(id:) async throws -> BridgeStatus; public func claimOnMonad(_:) async throws
  public func startCash(anchor:deposit:asset:) async throws -> LiteCashFlow   // SEP-10 inside DyorLite (I5)
  public func cashStatus(_:) async throws -> AnchorClient.AnchorTransaction
  public func faucet() async throws                              // testnet only
  public func maxAmount(asset: String, stepKind: String, newReserves: Int) -> Int64   // XLMReserve.maxSend for XLM
  public func run(_ action: PreparedAction, reason: String,
                  onEvent: @escaping @Sendable (PlanRunner.Event) -> Void = { _ in }) async throws -> [TxStatus]
}

public struct PreparedAction: Identifiable, Equatable {
  public let plan: PlanView; public let limits: [String: Int64]; public let title: String
  public let titles: [String: String]; public let section: LiteSection; public let reference: String?
  public let fees: PlanFees                                      // decoded on the phone (§4.4)
  public let sponsorVerified: Bool                               // §4.3 (a) or (b)
}
public enum LiteSection: String, Sendable { case spot, earn, launch, moments, bridge, cash, account }
public struct LiteSettledAction: Sendable { public let planId: String; public let title: String; public let body: String
  public let section: LiteSection; public let reference: String?; public let hashes: [String]; public let at: Date }
public enum LiteErrorText { public static func describe(_ error: Error) -> String }   // §6.13 codes, localized
public enum StellarExplorer { static func transaction/account/contract/asset(_:network:) -> URL }   // pinned network
public enum LiteMediaPolicy { static func imageSources(_ uri: String, base: URL, renderBase: URL?, pixels: Int?) -> [URL]
                              static func videoURL(_ uri: String, base: URL) -> URL? }
```

**Pure helpers** (DyorLite, unit-tested; views only render them):
- `StellarMarketRanking` (tabs, Monad's rules);
- `StellarMomentState` (`collecting | soldOut | windowClosed` at the boundaries, including open editions);
- `StellarLaunchMath` (sorts across quotes with a missing price, progress, holders text with "+", the 1% min-out);
- `StellarActivityPresenter` (kind → symbol, title and subtitle keys; never "TOKEN");
- `StellarFeeSummary` (the Max network fee text inputs);
- `StellarPercent` (fraction → percent, R24).

**Kept internal:** `LiteSession.keys`, `LiteBackend`, `LiteSessionVault`, `LiteStore.api`. `signer(reason:)` is
deleted: every signature goes through a `LiteSigningRun`.

**Session rules (decision 6).**
- **No lock.** `HomePhase.locked`, `State.locked`, the `.unlock` step, `UnlockResult` for seed accounts, `idleTimeout`,
  the idle timer and the "pending again" unlock row are deleted. `canSign` means the key: false for watch-only or a
  key not on this iPhone, never because of a session.
- **Reads.** The store reads viewer routes with the token when it has one and in the public view otherwise, so Home,
  boards, token pages, Earn and the wallet sheets always fill. Session-only parts (portfolio, activity, My Launchpad,
  My Moments) report `LiteReadStatus.needsSignIn` while `access == .publicView`; the screens show `StellarSignInRow`
  there (§8). `access` is `.session` whenever a token is held, and seed accounts are back in `.session` after any
  renewal that reaches the server.
- **Renewal** follows §6.18. The timer runs only while the scene is active; nothing is dropped at background
  because nothing secret is held.
- **Signing.** `LiteStore.run(_:reason:)` calls `keys.beginSigning(reason:)` once per action, which is where App Lock
  is asked when it applies, and `run.signer(reason: stepTitle)` per step. It ends the run on settle, failure or
  cancel. Before building, it makes sure of a session: silent for seed accounts; for a passkey account in the
  public view, one `signIn()` ceremony when the user starts the action (never to view).
- **Setup run** (§8.14):
  - seed accounts: check, silent sign-in, invite when asked (nothing held while waiting), account read, the Set Up
    tap, then App Lock if it applies (as a Monad Confirm), activate and enable;
  - passkey accounts: check, the Set Up tap (with the invite field on a first sign-in on this iPhone), then one
    `setupKey` ceremony whose signer signs the sign-in and, with no user wait in between, the Enable USDC step;
    then the signer is dropped.
  `appDidEnterBackground()` ends a running passkey run ("Not finished. Try again.") instead of keeping its signer.
- **Hygiene.** A `StellarSigner` exists only inside one signing operation that never waits on the user: one
  signature (a sign-in or a step), or a passkey account's setup run. It is never stored, never kept across a user
  wait or in the background, and never handed to a view.
- **Sign out of Stellar.** Revokes the refresh family (best effort), erases the Keychain session item and the saved
  figures, and sets `lite.signedOut.<G>`, so the next switch runs the sign-in step again (silent for seed accounts,
  one passkey prompt for passkey accounts). A successful sign-in clears it.

**Transitional:** the legacy DyorLite screens become `public` in WP-12 (`LiteLegacyScreens`), so the app's seams
(§13.3) can host them until each port lands. They are deleted in WP-50, together with `LiteTab`, `LiteStyle`,
`LiteChrome`, `LiteHeaderContext`, LiteTheme, LiteParagraph and Platform.

### 7.3 Units and formatting

- **Amounts.** `StellarFormat.units(_ units: String|Int64, decimals: 7, compact:)` formats through
  `NumberStyle.units(BigUInt, decimals:compact:)`.
- **Field text.** `StellarFormat.plain(units:decimals:)` writes amount fields (POSIX, no grouping).
- **XLM fees** use `NumberStyle.number(xlm, maximumFractionDigits: 7)` + " XLM".
- **USD** always goes through `PriceFormat` / `USDText`.
- **Percent.** Fractions become percent only in DyorLite accessors (`change24hPercent`, `supplyApyPercent`,
  `utilizationPercent`). A test asserts that 0.0123 renders as "+1.23%" in `ChangeBadge`.

---

## 8. Screen-by-screen spec (app, `ios/DyorHQ/Lite/`)

Every Stellar screen is built from the app's own components, with the same colour tokens, fonts and paddings as the
Monad screen it mirrors. Where a Monad layout is private, its Stellar copy keeps the numbers exactly.

The only intended differences are network facts:
- XLM is the fee asset;
- Stellar has a minimum balance;
- an asset must be enabled (trustline) before it can be held;
- Earn takes Perps' slot;
- Moments are editions with no coin;
- testnet labels show on testnet.

**No access gate on any screen (decision 6).**
- No Stellar screen has a locked variant, a locked card, an unlock button or "Unlock again to continue".
- Figures come from viewer and public routes, so they fill with or without a session (§6.0).
- The one place a session matters on screen is a DyorHQ-history part (Total Volume, Portfolio, Recent Activity, My
  Launchpad, My Moments, Swap History). It shows only for a passkey account whose refresh token is gone (§6.18).
  The part then shows `StellarSignInRow`: the Paragraph "Sign in again to see your Stellar history." and a bordered
  button "Sign in with your passkey", which calls `StellarActions.signIn()`. Nothing prompts until it is tapped. Seed
  accounts never see it.
- Prompts happen only when signing (§8.7).

Copy marked **(key)** reuses an existing build-23 Localizable key verbatim. All other copy is new, in the area's
Stellar table (§10).

### 8.1 Testnet labelling

Every one of these hangs off `AppNetwork.stellar.isTestnet`, so pinning mainnet removes them with no UI edit.

- **Chip row.** `NetworkChipRow(network: .stellar)` (reuse) shows "Stellar [Testnet] ⌄".
- **Dollar caption.** Every screen that shows a dollar value of a Stellar asset carries one caption: in Home's hero,
  in Portfolio's hero, and in the first section footer of the launch page, My Launchpad, the token page and the Moment
  page. It reads "Dollar values use mainnet market prices. Testnet assets have no value."
- **Boards** show quote-asset amounts only (Monad shows market cap in its pair), so they carry no caption.
- **Elsewhere.** The token page's source line (§8.3). Earn shows `TestnetBadge` beside the APY, plus the footnote
  "Testnet rates come from test activity, not real markets." The review sheet's first section header is
  `StellarNetworkLine`: `NetworkMark(.stellar, 14)` + "Stellar" + `TestnetBadge`. Bridge chips show "Monad testnet" and
  "Stellar testnet".
- **Faucet** rows exist only on testnet.
- **Never** a Testnet badge on every row.

### 8.2 Home: `StellarHomeView` (WP-31; mirrors HomeView.swift:32-128, hero :134-306, tiles :310-318, cards :342-449)

**Frame.**
- **Layout.** `NavigationStack { ScrollView { VStack(spacing: 16) { addFundsCard?; heroCard; tiles; allocationCard?;
  topTokensCard; holdingsCard } .padding(.horizontal, 16).padding(.vertical, 12) } }`, on `systemGroupedBackground`,
  with `.scrollIndicators(.hidden)` and the navigation bar hidden.
- **Header.** `.safeAreaInset(edge: .top) { HomeHeader(showSearch: $showSearch, error: model.error, updatedAt: model.updatedAt) }`,
  with a real `@State` binding.
  - The bell opens the shared center, which now holds Stellar items too.
  - The avatar opens Profile.
  - Search opens `StellarSearchSheet(purpose: .browse)`.
- **Removed:** the Activity card (activity is in Profile › Recent Activity and Portfolio, as on Monad), the fifth Swap
  tile and the Add cash tile.

#### 8.2.1 Balance card (copy of `heroCard`)

| Row | Content | Source |
|---|---|---|
| Chip row | `NetworkChipRow(network: .stellar)`. Card padding top 10, others 16. | reuse |
| Total | `Text(PriceFormat.usdValue(total ?? 0))`, serif 40 semibold, `monospacedDigit`, `lineLimit(1)`, `minimumScaleFactor(0.6)`, `.contentTransition(.numericText())`, `.unreadFigure(total == nil)` | `holdings.totals.total`, gated by `HomeReadState` |
| 24h change | `PriceFormat.usdValue(changeAmount, signed: true)`, tinted, and `ChangeBadge(value: change24hPercent)`. Unread placeholder until read. | `holdings.change24h` |
| Saved line | `SavedLine(date:reading:)` | §3.9 |
| Total Volume (right column) | Copy of `totalVolume` (:217-259): button "Total Volume" (key) with the figure, which sets `router.presented = .portfolio` (AppCovers shows the Stellar Portfolio); its own SavedLine; the period `Menu` chip bound to `router.period`. There is no "Reading your history… %" line, because the figure is one server call. | `store.portfolio[period].totals.volume` |
| Avail. Balance / In Use | `statColumn` "Avail. Balance" (key) = `totals.spot`; "In Use" (key) = `totals.earn`, tinted positive when above 0 | §6.5 (R23) |
| Split | Four `splitStat`s: Spot (`allocationSpot`, key `homeCategory.spot`), Earn (`allocationPerps`, Stellar key `homeCategory.earn` [tight]), Launch (`allocationLaunchpad`, key), Moments (`allocationMoments`, key) | totals |
| Testnet caption | Paragraph, footnote, secondary (§8.1) | |

**Variants.** The chip row always stays. The rest of the card is replaced only when **paused** (maintenance, an update
needed, or access turned off): `InlineError` with the reason, plus `PrimaryButton` "Switch to Monad". This has no
Monad equivalent; it is kept from DyorLite and rebuilt with app components. There is **no locked variant**
(decision 6): after a relaunch, after 12 hours or more, or after the background, the card shows the saved figures,
then the fresh ones, with no prompt. Total Volume shows `StellarSignInRow`'s state (an unread figure, the button
under it) only in the passkey public-view case of §8.

#### 8.2.2 Tiles (copy of `HomeAction` as `StellarHomeAction`)

`HStack(spacing: 10)`, with Monad's four labels and symbols and metrics. The symbol is `.body.weight(.semibold)` at
`@ScaledMetric(relativeTo: .body) 24`; the caption is medium, one line, scale 0.8; padding 12;
`secondarySystemGroupedBackground`; radius 14 continuous.

| Tile | Symbol | Opens | Enabled |
|---|---|---|---|
| Bridge | `point.3.connected.trianglepath.dotted` | `StellarBridgeView()` | Home ready |
| Deposit | `creditcard` | `StellarReceiveSheet()`: Receive + Add cash + testnet faucet | whenever the Stellar address is known |
| Withdraw | `arrow.up` | `StellarSendSheet()`: Send + Cash out | Home ready and `canSign` |
| Transfer | `arrow.left.arrow.right` | `StellarTransferSheet(direction: .toEarn, market: nil)` | Home ready and `canSign` |

#### 8.2.3 Add-funds card (copy of AddFundsCard.swift:8-196 as `StellarAddFundsCard`, with `StellarFundingWatch`)

- **Shown** for any Stellar account while Home is on screen and the app is active.
- **Phases** come only from `/v1/account.firstFunding` and the balances.
- **Polling:** every 4 s, only while a phase is watching.

| Phase | Condition | UI |
|---|---|---|
| `addFunds` | `needsXlm` and no other balance worth $1 or more | **Header:** tray icon in brand, "Add funds to start trading" (key). **Detail:** testnet "Send test XLM or USDC on the Stellar testnet to your account, or get free test XLM below."; mainnet "Send about %@ XLM or USDC on Stellar to your account. Funds usually arrive in seconds." (`suggestXlm`). **Body:** a 112 pt QR on a white plate; the short address (tap to reveal) with Copy (copies `address.checksummed`) and Share (keys); "Watching for your deposit" (key) with an animated radiowaves symbol; Divider. **Rows:** "Bridge from Monad"; testnet "Get %@ test XLM" (`faucet.amount`, locale digits). |
| `needsXLM` | `needsXlm` and another asset worth $1 or more | **Header:** "Get XLM for network fees". **Detail:** "Every Stellar transaction pays a small network fee in XLM. Send about %@ XLM to your account." **Buttons:** when `starterSwap == available`, `PrimaryButton("Swap %@ USDC for XLM")` with the caption "DyorHQ pays this first swap's network fee.", which calls `router.openStellarSwap(sell: "USDC", buy: "XLM", starter: true)`; on testnet, the faucet button. |
| `arrived` | a balance rose since the last read | "Funds arrived" (key), "%@ %@ is in your account." (key), a success haptic and a VoiceOver announcement |
| `firstTrade` | funded, with no trade in `/v1/activity` | "Make your first trade" (key); "Swap %@ for %@ at the best price across Stellar's venues."; `PrimaryButton` "Swap %@ for %@" (key) → `openStellarSwap`. The ✕ ("Hide", key) sets `done` (`lite.funding.<G>`). |

#### 8.2.4 Allocation

`AllocationDonut` (reuse), shown when every part is read and (total > 0 or there are holdings). Segments: Spot, Earn
(Earn label, `allocationPerps`), Launchpad (key) and Moments (key).

#### 8.2.5 Top Tokens (copy of `TokenListRow` as `StellarTokenListRow`)

- **Card.** "Top Tokens" (key), with `Picker("Filter")` segmented over `HomeTokenTab` (reuse).
- **Rows.** Six ranked rows. Dividers are inset by the text inset; `@ScaledMetric(relativeTo: .footnote) rankWidth = 16`.
  Each row: rank, `StellarTokenLogo` 34, code (subheadline semibold) plus badge, name (caption, one line),
  `USDText(price:)` and `ChangeBadge` (or `StellarNewBadge` under 24 h). A row pushes `StellarTokenDetailView(asset:)`.
- **Data.** `session.publicReads.markets`, so the card shows with or without a session, as Monad's always does.
  Tabs are sorted with `StellarMarketRanking`.
- **States.** Empty: "Loading markets…" (key). Failed: `InlineError("Markets couldn't be loaded just now.")` + Retry (key).

#### 8.2.6 My Holdings (copy of `holdingsCard`)

"My Holdings" (key), with `Picker("Category")` segmented over `StellarHoldingCategory` (spot, earn, launch, moments).

| Tab | Row | Content | Tap | Empty / reading |
|---|---|---|---|---|
| Spot | `StellarHoldingRow` | logo 34, code + badge (BUSDC: "Blend test"; classic unknown: Unverified), compact amount, value, price, `ChangeText` | token page | "No spot balances" / "Buy or swap a token and it appears here." (keys); "Reading your balances…" (key) |
| Earn | `StellarEarnPositionRow` (no logo, as Monad) | code + "%@ APY" chip (brand at 15% fill); "%@ %@ supplied"; right: earned `PriceFormat.usdValue(earnedUsd, signed: true)` over "Earned" | `router.openStellar(.earn(market:))` | "No Earn positions" / "Supply XLM or USDC on the Earn tab to start earning."; "Reading your positions…" (key) |
| Launch | `StellarLaunchHoldingRow` | `StellarArtwork` 34 (radius 9), symbol, units; right: value, then "%lld%% to graduation" (key) or "Graduated" (key) | launch page | "No launch holdings" / "Buy or launch a coin on the Launch tab." (keys) |
| Moments | `StellarMomentHoldingRow` | art 34; title or "Moment #%lld"; "%lld editions" (key); right: "No market" over "Open" or "Closed" | Moment page | "No Moments yet" (key) / "Collect a Moment on the Moments tab and your editions appear here." |

A part whose read failed shows its own InlineError ("Your Stellar balances couldn't be read just now." etc.) + Retry,
or a spinner while it reloads (Monad :482-525).

#### 8.2.7 Loading, refresh, polling

- **First frame.** Saved figures are applied before the first frame. A large `ProgressView` overlays only an empty
  first read.
- **Pull to refresh.** `.refreshable { await Task { async let h = model.load(force: true); async let p = portfolio
  .load(force: true); _ = await (h, p) }.value }`. It never calls `env.history.kick`.
- **Polling.** Every 30 s while on screen, the scene is active and Home is ready (with or without a session).
- **After any settled action:** the store refreshes the account, holdings, Earn and portfolio.

### 8.3 Token page: `StellarTokenDetailView(asset:)` (WP-30; copy of TokenDetailView, HomeView.swift:1273-1455)

`List(.insetGrouped)`, navigation title the code (`Text(verbatim:)`), inline. Sections:

1. **Price.**
   - `StellarTokenLogo` 44; the price in `.largeTitle` rounded semibold; `ChangeBadge` or `StellarNewBadge`.
   - **Source line**:

     | Case | Text |
     |---|---|
     | Registry asset, testnet | "Mainnet market price (%@). Testnet %@ has no value." |
     | Registry asset, mainnet | "Market price (%@)." |
     | Launch on its curve | "Price on its DyorHQ curve, in %@." |
     | Graduated launch | "Price on Soroswap, in %@." |
   - "Past 24 hours" (key), then `PriceChart` at 180 pt. Points are `PricePoint(block: UInt64(index), time: t, usd:)`
     from `publicReads.history(id, .day)`. With fewer than 2 points, PriceChart shows its own empty state.
2. **Warnings.**

   | Case | Content |
   |---|---|
   | Look-alike (`lookAlike` or `badges` contains it) | `StellarTokenBadge(.imitation)` "Not the real %@" + Paragraph "This token carries the name of another token. Check its contract before you trade it." |
   | DyorHQ launch | "Launched on DyorHQ" (key). Rows: "Made on" = "The DyorHQ launchpad on Stellar"; "Phase" = "On its curve" / "Graduated to Soroswap"; `StellarAddressRow` "Creator"; button "Open the Launch Page" (key) → launch page. Footer: the key "Anyone can launch a coin or publish a Moment on DyorHQ…". |
   | Unverified classic or contract | "Unverified token" (key) + Paragraph "DyorHQ didn't list this asset. Anyone can issue a Stellar asset with any code, including a real one's. Check the issuer below before you trade it." |
3. **Your Balance** (key), when the balance is above 0: "Amount", "Value" (keys). For XLM also:
   - "Locked" = `minBalance + sellingLiabilities`, with the footer "Stellar keeps %@ XLM of your balance as your
     account's minimum balance and for open offers. It's returned when you remove an asset or close an offer.";
   - "Available" (key) = `spendable`.
4. **About** (key): "Name"; "Code"; "Issuer" (`StellarAddressRow`, classic only); "Contract" (key; `StellarAddressRow`);
   "Decimals" (key).
5. **Actions.**
   - A launch on its curve: "Buy on its Launch Page" → launch page. Never Swap.
   - Otherwise: "Swap %@" (key) → `router.openStellarSwap(sell: id == "USDC" ? "XLM" : "USDC", buy: id)`, which
     dismisses the page and opens the Earn tab in Swap mode.
   - "View on StellarExpert" (`safari` symbol) → `StellarExplorer.asset/contract`.
   - Set Price Alert (M4, WP-60).

**Data:** the market row from `publicReads.market(id)`, and the balance from the store's account and holdings
(owner or public view, §6.0).

### 8.4 Search: `StellarSearchSheet(purpose:onPick:)` (WP-30; copy of TokenPickerSheet, SwapView.swift:798-940)

- **Purposes.** `enum StellarSearchPurpose { case browse, pay, receive }`. Browse pushes the token page; pay and
  receive set a swap side.
- **Frame.** `NavigationStack { List(.insetGrouped) }`, `.searchable(prompt: Text("Symbol, name or address"))` (key
  text through `Text`), title "Choose a Token" (key) via `tr(...)`, and Cancel.
- **Sections.**
  1. "By address" (key): a pasted C… or `CODE:G…`, looked up with `searchAssets`.
  2. Registry assets, then held assets, then launches held. Held rows float up, keeping curated order within each
     group.
  3. While searching: "DyorHQ launches" (server results).
  4. "Unverified: in your wallet" (Stellar key) for held classic assets with `verified: false`.
- **Rows.** `StellarTokenLogo` 32, code (headline) + badge, name (footnote), compact balance, and a checkmark on the
  selected row. For `pay`/`receive`, a launch still on its curve is shown disabled, with "Trades on its Launch page".
- **No match:** "No token matches. Paste a contract address to add any Stellar token."
- **Debounce:** 250 ms.

### 8.5 Earn tab: `StellarTradeView` (WP-21; copy of TradeView.swift:8-17)

- **Body.** `switch router.stellarTradeMode { case .swap: StellarSwapView(); case .earn: StellarEarnView() }`. It
  opens on Earn, and the mode survives tab switches.
- **`StellarTradeModeSwitcher`** (copy of TradeModeSwitcher :22-54):
  - a full-width underline switch, placed with `.safeAreaInset(edge: .top, spacing: 0)` in each mode's own
    `NavigationStack`;
  - subheadline semibold when active, regular otherwise; vertical padding 11; a 2.5 pt brand capsule underline;
    `.background(.bar)`; Divider;
  - `Haptics.selection()`; `.isSelected` on the active mode;
  - labels: `TradeMode.swap.label` and `MenuItem.earnTitle`.

### 8.6 Swap and Earn modes

#### 8.6.1 Swap: `StellarSwapView` + `StellarSwapModel` (WP-34; copy of SwapView.swift:7-381)

`List(.insetGrouped)`, in Monad's section order. Navigation title is the tab's name, "Earn", as Monad titles its swap
screen "Trade". The toolbar has the slippage button (`slider.horizontal.3`), which opens `SlippageSheet` (reuse);
slippage is stored per address under `lite.slippage.<G>`, default 100 bps.

| Section | Spec |
|---|---|
| You Pay (key) | Token row (`StellarTokenLogo` 32, code + badge, name, `chevron.up.chevron.down` → `StellarSearchSheet(.pay)`). `AmountField(title: "0", text:, token: nil) { useMax() }` (reuse). Percent row 25/50/75/100 (copy). Footer: "Balance: %@ %@" (key); for XLM, " · %@ locked" (Stellar). USD on the right. |
| Flip | Copy of `flipRow`: a 40 pt row, a circle button `arrow.up.arrow.down`, label "Swap direction" (key). |
| You Receive (key) | Token row; quoted amount (title2 medium) or "Finding the best price" (key) with a spinner. Footer: balance and USD. When the buy asset needs enabling: "Enabling %@ holds 0.5 XLM. It's part of this review." |
| Action | `PrimaryButton(title:)`: "Enter an Amount" or "Insufficient %@" (keys), else "Review Swap" (key). Disabled without a quote. |
| Curve | When a side is a launch on its curve: "This coin trades on its Launch page until it graduates." + "Open the Launch Page" (key). |
| Quotes (key) | One row per venue from `quote.routes`: name (SDEX = "Stellar DEX", Soroswap, Aquarius), route footnote, amount out, impact, selection circle. "Best" (key) on the best. "Checking…" (key) while the request runs. Footer: the key "Minimum received %@ %@ at %@ slippage. Quotes refresh every 15 seconds." Re-quotes every 15 s, or at `expiresAt` if sooner. |
| Swap History (key) | `Picker("Range")` over `VolumePeriod`. Rows `StellarSwapHistory` (copy of SwapHistoryRow): "Swapped", "10 XLM → 1.9 USDC" (real `amountOut`), relative time, StellarExpert link. "Loading swaps…" and "No swaps in this range yet." (keys). Data: `/v1/activity?section=spot&kind=swap&period=`. |

**Review.** `StellarConfirmationSheet(title: "Review Swap", confirmTitle: "Swap")` (keys). Rows: "You pay", "You
receive", "Minimum received", "Venue", "Route", "Slippage" (keys). The quote is frozen when Review is tapped. The
starter variant shows "Paid by DyorHQ" only when `sponsorVerified` (§4.3).

**Routing in.** `router.pendingStellar` of kind `.swap` applies on appear and on change.

#### 8.6.2 Starter swap

There is no separate screen. The add-funds card opens Swap with `starter: true`, and the quote's
`starterSwap.eligible` drives the review row. If the quote says not eligible, the review is a normal user-paid one,
and the "Not enough XLM" check applies.

#### 8.6.3 Earn: `StellarEarnView` + `StellarEarnModel` (WP-35; mirrors PerpsView.swift and PerpTradeView.swift)

```
[  Swap  |  Earn  ]
(◉) USDC ⌄            [📈|▤]  (…)
    Supply APY 4.21% [Testnet]    ● Active
┌ ticket ──────────────────┐ ┌ rates (150) ─┐
│ ◇ Blend · TestnetV2      │ │ Supply APY   │
│ Available 9,998.4 XLM ⊕  │ │ Borrow APY   │
│ [ amount        ] [Max]  │ │ Utilization ▓│
│ 25% 50% 75% 100%         │ │ Total supplied│
│ Supplied     100 USDC    │ │ Free to withdraw│
│ Est. yearly  $4.21       │ └──────────────┘
└──────────────────────────┘
[ Deposit ]  positive        [ Withdraw ]  tertiary fill
 Position | Assets | History
```

**Frame.** The PerpTradeView frame: `ScrollView { VStack(spacing: 16) { marketHeader; chart or (ticketGrid;
actionButtons); Divider; bottomSection } .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 28) }`, on
`systemBackground`, with the navigation bar hidden.

| Element | Spec (Monad source) | Data |
|---|---|---|
| Market header | Copy of `marketHeader` (:285-322): a button with `StellarTokenLogo` 34, code (title3 bold) and `chevron.down` → Select Market. Below it, "Supply APY %@" in a **neutral** colour (a rate isn't a gain), plus `TestnetBadge`, plus the pool status chip: Active (positive), On Ice (attention: "Borrowing paused"), Frozen (negative: "Deposits paused"). Right: the view-mode pill (`chart.xyaxis.line` / `list.bullet.rectangle`, 46×38; labels "Chart view"/"Order view", keys), then the ⋯ `Menu`: "Supply to Earn", "Withdraw to Spot" (key) → `StellarTransferSheet`; "Portfolio" (key); Divider; "Rates from Blend" (`building.columns`). | `/v1/earn/markets` |
| Ticket | Copy of `orderTicket`'s frame (:482-605). Row 1: a static chip "Blend · %@" (`building.columns`; VoiceOver "Lends through Blend, pool %@"). Row 2: "Available" (key) with the spendable amount (XLM via `maxAmount`) and `plus.circle` → `StellarActions.addFunds`. `StellarAmountField` with Max; the percent row. Summary rows: "Supplied"; "Est. yearly interest" = amount × APY in USD, "at today's rate". | `/v1/account`, holdings.earn |
| Rates column (150) | Mirrors `fundingPanel` and the book column (:452-480): "Supply APY", "Borrow APY", "Utilization" with a linear `Gauge` in brand, "Total supplied" (USD), "Free to withdraw" (USD). At accessibility sizes, `ViewThatFits` stacks it above the ticket. | earn markets |
| Buttons | Copy of `sideButton` (:720-745): headline semibold, vertical padding 15, radius 26. **Deposit:** positive fill, `onStatus` text, disabled when the pool is Frozen. **Withdraw:** `tertiarySystemFill`, primary text (not a loss), disabled without a position. Both open `StellarConfirmationSheet`. | |
| Chart view | `StellarRateChart` (a copy of PriceChart's structure with a percent axis): "Supply APY over the past %@", chips 7D / 30D (week, month), and a thin utilization line under it. Empty: `ContentUnavailableView("No Rate History Yet", description: "DyorHQ records this market's rate every 10 minutes from when it's listed.")`. | `/v1/earn/history` |
| Bottom tabs | Copy of `segmentedTabs` (:851-890): "Position" / "Assets" / "History" [tight]. | |
| Position | `StellarEarnPositionCard`: logo, code, pool; "Supplied", "Value", "Earned" (signed, tinted), "APY"; buttons "Supply More" and "Withdraw". Empty: "No position in this market". | holdings.earn |
| Assets | DetailRows across all markets: "Total supplied", "Earned", "Average APY", "Available in wallet". | |
| History | Deposits and withdrawals for this market, linked to StellarExpert. | `/v1/activity?section=earn&market=` |
| Select Market sheet | `StellarSelectMarketSheet` (copy of SelectPerpetualSheet :2148-2210): `SheetHeader` "Select Market"; a "Search…" (key) capsule; rows with `StellarTokenLogo` 38, code bold, pool name caption, APY semibold, "Utilization %@"; the selected row on `tertiarySystemFill` radius 14; dividers inset 64; detents large and medium. | |

- **Default market:** `pendingStellar(.earn(market))` if set, else the user's largest position, else the pool's USDC
  market, else the first.
- **Polling:** every 30 s while visible.
- **No markets:** `ContentUnavailableView("No Markets" (key), description: "Blend's markets couldn't be loaded. Try
  again.", actions: "Try Again" (key))`.
- **BUSDC on testnet.** The BUSDC market's footer says "On testnet, Blend's pool uses its own test USDC, not the USDC
  in your wallet." When `swapQuote(USDC → BUSDC)` finds a route, the ticket shows "Swap for Blend test USDC" →
  `openStellarSwap`. When it doesn't, only the footer shows. No market is hidden (§15, RK16).

### 8.7 Review sheet: `StellarConfirmationSheet` (WP-20; copy of ConfirmationSheet, TransactionRun.swift:156-445)

```swift
struct StellarConfirmationSheet<Details: View>: View {
  let title: LocalizedStringResource; let confirmTitle: LocalizedStringResource
  var build: () async throws -> PreparedAction
  let onDone: () -> Void
  var onCompleted: (([TxStatus]) -> Void)? = nil     // once, at settlement (GL-3), not on Done
  var onView: ((String) -> Void)? = nil              // default: StellarExplorer.transaction
  var check: ((PreparedAction) -> LocalizedStringResource?)? = nil   // caller guard, e.g. Moments terms (§8.11.4)
  @ViewBuilder var details: Details
}
```

`NavigationStack { List(.insetGrouped) }` with `.navigationTitle(tr(title))`, inline. Sections, in order:

1. **Details** (`details`). The header is `StellarNetworkLine` on testnet. Every entry of `PreparedAction.limits` is
   shown: "You pay" for exact spends, "You pay at most" where the contract may use less, "Minimum" (key) for minimum
   outs. Recipients come from `intent.to`. The footer reads "Your phone checks every transaction against this review
   before it signs, and refuses anything else."
2. **Enable** (one row per `trust` step): "Enable" + code; the reserve footer (§4.6).
3. **Restore** (one row per `restore` step): "Restore archived data for %@".
4. **Fee**: "Max network fee" (key), or the verified sponsored variant (§4.6).
5. **Not enough XLM** (§4.6), with "Add XLM".
6. **Caller check failure:** an `InlineError` with the caller's message. Confirm is disabled.
7. **Preparing:** "Preparing transaction" (key) with a spinner.
8. **Build error:** `InlineError(LiteErrorText.describe(error))` on a clear row background.
9. **Progress** (key): `StellarTransactionProgress` (copy of TransactionProgress, Components.swift:610-668). One row
   per step, titled by `LiteTitles`:

   | Event | Row |
   |---|---|
   | `.building` | "Preparing…" |
   | `.signing` (existing event) | passkey accounts: "%@: confirm with %@" (`faceid`; the passkey prompt's name); seed accounts: no change of row (the App Lock prompt, if any, came at Confirm) |
   | `.submitted` | "%@ sent" (key) + "View" (key) |
   | `.confirmed` | "%@ confirmed" (key), positive + "View" |
10. **Failure:** `InlineError(LiteErrorText.describe(error))`. If any step was sent, `TransactionRun.alreadySent`
    (reuse) and Close; Confirm is never offered again from this sheet.

**Bottom bar** (`.safeAreaInset(edge: .bottom)`, `.background(.bar)`):
- `PrimaryButton(title: tr(confirmTitle))`, disabled while preparing, on error, on a failed check, when XLM is short,
  or when a fee is over the cap.
- Above it, for more than one step **on a passkey account only**: "%lld steps · each asks for your passkey" (plural).
  Seed accounts get no such line: one Confirm covers every step, as on Monad.
- Then busy, then `PrimaryButton("Done", systemImage: "checkmark")`.

**Behaviour.**
- `.interactiveDismissDisabled(running)`, `.holdsMomentLinks()`, `BackgroundTime("Transaction")`.
- `.sensoryFeedback(.success)` on done; `.error` on failure.
- `onCompleted` fires once at settlement.
- Notifications come from the store's `onSettled` (§3.7), never from the sheet.
- Presentation is Monad's (copied).

**Signing prompt (decision 6: Monad's rule, TransactionRun.swift:403-408).** Confirm calls
`store.run(action, reason: "Confirm \(confirmTitle)")`, whose `keys.beginSigning(reason:)` decides:

| Account | App Lock on | App Lock off |
|---|---|---|
| Seed (imported, email & password) | Face ID or the passcode **once** at Confirm (`BiometricGate.authenticate`), then every step signs with no prompt; with no device passcode, Monad's "App Lock needs a device passcode…" (key) and nothing is signed | no prompt at all |
| Passkey (Mera) | App Lock never applies (`appLockApplies` is false for passkey accounts) | the passkey once per signed step, its reason the step's title |

A cancelled prompt leaves the sheet as it was: nothing was sent (`TransactionRun.notSent`). App Lock is read when
Confirm is tapped, so a change in Profile › Security applies to the next Confirm. `GatedSeedKeyProvider` no longer
prompts per signature (DyorHQLiteKeys.swift:85-98 at c2ee50e): its run reads the Keychain seed per step and drops
it after that signature.

**Callers:**

| Caller | Title | Confirm | Rows |
|---|---|---|---|
| Swap | "Review Swap" (key) | "Swap" (key) | §8.6.1 |
| Earn deposit / withdraw | "Supply to Earn" / "Withdraw to Spot" (key) | "Deposit" / "Withdraw" (keys) | "Amount", "To"/"From" = "Blend · %@", "Supply APY" |
| Send | "Review Send" | "Send" (key) | "To" (bound `intent.to`, short, spelled out), "Amount", "Memo" |
| Enable | "Enable %@" | "Enable" | the enable section |
| Bridge out | "Review Bridge" | "Bridge" | "Route" Circle CCTP, "Bridge fee", "To" (Monad address), "Amount" |
| Anchor payment | "Send to %@" | "Send" (key) | "To" anchor, "Amount", "Memo" (from the anchor) |
| Launch, buy, sell, graduate, claim, claim all, publish, collect | §8.10.5 | | |

### 8.8 Wallet sheets (WP-32)

#### 8.8.1 Deposit: `StellarReceiveSheet()` (copy of ReceiveSheet, ProfileView.swift:356-401)

- **Frame.** Title "Receive" (key), "Done", `presentationDetents([.large])`.
- **Body.**
  - A 220 pt QR (`QRCode.image(for:)`) on a white plate (padding 16, radius 16), labelled "QR code of your address"
    (key).
  - The full G… address (footnote monospaced, `textSelection`, spelled out by VoiceOver).
  - Paragraph "Send XLM or any Stellar asset you've enabled to this address. No memo needed: this address is yours
    alone."
  - Copy (`address.checksummed`) and Share, bordered (keys).
- **Row card** (`secondarySystemGroupedBackground`, radius 16):
  - "Add cash" (`banknote`) → `StellarCashSheet(mode: .deposit)`;
  - "Bridge from Monad" → `StellarBridgeView(direction: .toStellar)`;
  - testnet only, "Get %@ test XLM" (`drop`) with a spinner, then "%@ test XLM added", or the server's message ("You
    already got test XLM today.");
  - when USDC isn't enabled, "Enable USDC to receive it" → the Enable review.
- **No locked state** (decision 6). Every row is always enabled. Add cash and the faucet need a session: seed
  accounts always have one (silent renewal); a passkey account in the public view gets its one passkey sign-in
  when it taps the row, then the row continues.

#### 8.8.2 Withdraw: `StellarSendSheet(asset:)` (copy of SendSheet, ProfileView.swift:404+)

`Form`, title "Send" (key), Cancel and Review.

- **To** (key).
  - `TextField("Address")` (key), monospaced, no autocorrection. The Paste button (key) strips invisible
    characters, with the key footer "Hidden characters were removed from the pasted address. Check it matches the
    source."
  - **Checks:**
    - a valid G… or C… StrKey ("That isn't a Stellar address.");
    - M… is refused (`muxed_unsupported` copy);
    - own address: "That's your own address." (key);
    - `recipient()`: a missing account accepts XLM only, with the footer "This account doesn't exist yet. Sending at
      least 1 XLM creates it."; other assets are blocked;
    - no trustline: blocked;
    - a C… recipient needs the toggle "Send to this contract anyway" (key) and Monad's contract paragraph (key).
  - "Memo (optional)", with the footer "Exchanges and cash providers often need a memo. Use the one they give you."
- **Amount.** Ranked asset picker (copy of `assetRow` and the `WalletHoldings` ranking) with logos and USD.
  `StellarAmountField` with Max (§4.5). Footer "Available: %@ %@" (key) + " · %@ locked" for XLM.
- **Cash out** (header): "Cash out to a bank or cash pickup" → `StellarCashSheet(mode: .withdraw)`.

#### 8.8.3 Add cash / Cash out: `StellarCashSheet(mode:)`

`List(.insetGrouped)`, title "Add Cash" or "Cash Out" (via `tr(...)`).

- **Controls.** A segmented "Add cash | Cash out", then the asset row (USDC, XLM).
- **Providers.** Rows with name, domain and countries. A tap runs `store.startCash` (SEP-10 inside DyorLite, through
  a signing run with the reason "Sign in to %@": App Lock once if it applies, or the passkey), then opens
  `SafariView` on the SEP-24 page.
- **No provider:** `ContentUnavailableView` "No provider for your country yet."
- **Status** (key), shown after start: "Started at %@" → "Waiting for you at %@" → "%@ is processing" →
  "Completed". A Cash out at `pending_user_transfer_start` shows "Send %@ %@ to %@", which opens the anchor-payment
  review with the anchor's memo bound. Refresh.
- **Testnet footer:** "Testnet uses the Stellar test anchor: no real money moves."
- **Tracker.** `StellarTransferTracker` polls every 10 s while the app is active. It posts "Cash added" / "Cash out
  complete" once, and resumes from `/v1/activity` at launch.

#### 8.8.4 Transfer (Spot ↔ Earn): `StellarTransferSheet(direction:market:)` (copy of TransferSheet.swift)

`Form`, title "Transfer" (key), detents medium and large.

- **Controls.** Direction segmented "Spot → Earn" / "Earn → Spot" [tight]. Asset `Menu` over the Earn markets (logo,
  code, APY). `StellarAmountField` with Max. The header is "Supply to Earn" or "Withdraw to Spot" (key).
- **Footer:** "In wallet: %@ %@" or "Supplied: %@ %@", plus any problem:
  - "More than your %@ %@." (key);
  - "More than you have supplied.";
  - "The pool doesn't have that much free to withdraw right now.";
  - a Frozen pool: "Deposits are paused in this pool."
- **Shortfall** (until WP-61/62): "Swap for %@" → `openStellarSwap`.
- **Review:** the Earn caller rows.

#### 8.8.5 Locked sheet: removed

Decision 6 removes it: no `StellarLockedSheet` is built. (DyorLite at 651918e has no such sheet type either; its
locked states are LiteRootView's resting card and LiteHomeView's locked card, which WP-12 removes and WP-50 deletes
with the other DyorLite views.)

### 8.9 Bridge: `StellarBridgeView(direction:)` + `StellarBridgeTracker` (WP-33; copy of BridgeView's form, BridgeView.swift:117-250)

Title "Bridge" (key), Close (key). `ScrollView { VStack(spacing: 12) { … } }`:

- **Send card.** A "From" chip (`NetworkMark` + "Monad" or "Stellar", plus `TestnetBadge`), USDC logo, amount field,
  and "Balance: %@ USDC on %@". The Monad side's balance is read through the adapter's RPC.
- **Flip button.**
- **Receive card.** A "To" chip, and "You receive ≈ %@ USDC".
- **Summary** (DetailRows):
  - "Route" = Circle CCTP;
  - "Bridge fee" = the Iris fee, or "None" when it is 0;
  - "Time" only when `etaSeconds` is present;
  - "Network fees": Monad → Stellar "Monad: up to %@ MON (from your Monad wallet)" from `bridgePreview`, plus
    "Delivery on Stellar: paid by DyorHQ" (protocol upkeep); Stellar → Monad "Stellar: up to %@ XLM".
- **Status card.** "Sent on %@", "Circle confirmed", then "Arrived on %@" or "Claim on Monad", each with a link.
- **Prechecks.** The Stellar account exists and USDC is enabled; otherwise the row "Enable USDC first" with a button.
  The amount is at least 1 USDC.
- **CTA "Review".**
  - Monad → Stellar: the steps are decoded and checked (§5.7) before the Monad wallet signs through the adapter. The
    review is `StellarBridgeInReview` (Bridge/, WP-33), which has the same anatomy as `StellarConfirmationSheet`:
    details, then "Max network fee" in MON from `bridgePreview`, then progress and Done. Its details show the decoded
    approve and burn (amount, Stellar recipient). Its run is `store.bridgeIn(amount6:)`.
  - Stellar → Monad: the normal review.
- **Tracker.** Posts "Bridge complete" with "%@ bridged from %@ to %@." (keys), or "Ready to claim on Monad".

### 8.10 Launch tab

#### 8.10.1 Board: `StellarLaunchpadView` (WP-37; copy of LaunchpadView.swift:12-314)

**Frame.**
- **Navigation.** `NavigationStack(path:)` with `StellarLaunchPage = .launch(StellarLaunch) | .token(String)`. `.token`
  reads the launch first.
- **Title.** "Launch" (key) via `tr`.
- **Toolbar.** Leading: "My Launchpad" (`person.crop.circle`) → §8.10.4, disabled with no account. Trailing: "New
  Launch" (`plus.circle.fill`) → §8.10.3, disabled when there is no launchpad, `launchesEnabled == false`, or the
  session can't sign.
- **Search.** `.searchable(prompt: Text("Search coins"))` (key) sends `q` to the server.
- **Refresh and polling.** `.refreshable`; `.task(id: address)` polls every 20 s while on screen.
- **Saved and first load.** Saved boards show on appear without animation. The `BoardFirstRead` overlay covers an
  empty first read.
- **Routing in.** `pendingStellar(.launch(token))` pushes `.token`.

**Scroll content.** `LazyVStack(alignment: .leading, spacing: 22)`, padding 16 horizontal / 12 vertical, on
`systemGroupedBackground`. In order:

1. `StellarNetworkLine` (testnet).
2. "New launches open soon." (key, `clock`) when there is no launchpad. "New launches are paused." (`pause.circle`,
   attention) when `launchesEnabled == false`.
3. Error: InlineError + Retry (key). Coins already shown stay.
4. `SavedLine` while saved coins show.
5. **Empty states** (Monad :262-274):
   - with a search: `ContentUnavailableView.search`;
   - launchpad live: "No Launches Yet" / "Be the first to launch a coin on DyorHQ." / "Launch a Coin" (keys);
   - no launchpad: "New Launches Open Soon" (key) / "Launches appear here once the DyorHQ launchpad is live on
     Stellar."
6. **Graduated** (key): a count capsule; subtitle "Cleared the graduation threshold" (key); `section=graduated`,
   newest first. Hidden when empty.
7. **Explore** (key): count; "Coins still climbing toward graduation" (key). Chips are `LaunchSort` (Newest · Market
   Cap · Near Graduation), with the server sorts `newest`, `market_cap` and `near_graduation`. Completed curves stay
   here. An empty Explore shows the invitation card "No coins on the curve yet: launch the first one." + "Launch a
   Coin" (keys).
8. **Grid:** a 2-column `LazyVGrid` with 12 pt spacing; `BoardPrefetch.following` warms the next cards' art.

Monad's "Refund & Migrating" and "Your Sell-Only Coins" sections are left out: the Stellar contract has no such
phases. Today's New/Hot/Graduated segmented control is removed.

**Card: `StellarLaunchCard`** (copy of LaunchCard :346-438):
- **Art.** `StellarArtwork` (policy sources) at square aspect.
- **Badge.** Graduated: `LaunchPhase.graduated.title` with `checkmark.seal.fill`, positive. Otherwise, at progress
  ≥ 0.8: "%lld%%" in brand.
- **Text.** Name (subheadline semibold, one line) · `$SYMBOL` (verbatim, caption). "Market cap" (key) over
  `marketCapQuote` + quote code (compact), or "—". Age (`RelativeTime.short`).
- **Progress.** A capsule and "%lld%% to graduation" (key) while not graduated.
- **No 24h change**, because Monad's card has none.

#### 8.10.2 Launch page: `StellarLaunchDetailView(token:)` (WP-36; copy of LaunchDetailView :627-1183)

`List(.insetGrouped)`, title `$SYMBOL` verbatim. Sections in Monad's order (:709-721):

1. **Header.**
   - `StellarTokenLogo(.launch)` 48, the name, and a status line: `LaunchPhase` title, or "Graduation pending" (the
     translations copied from DyorKit's key).
   - Price in quote, `.title` rounded semibold, over USD (`PriceFormat.spoken` for VoiceOver).
   - Market cap in quote over USD.
   - While on the curve: a `Gauge` ("Graduation"), and "Graduates at %@ %@ raised. Liquidity then moves to a Soroswap
     pool, locked forever." (threshold from the row).
   - Footer: the dollar caption (§8.1).
2. **Stats.** "24h Volume", "Holders", "Progress" (keys).
   - Holders show `"\(n)+"` when `holdersComplete == false`, with the Paragraph "Counted from this coin's transfers
     we've read, so there may be more holders."
   - Per-part `InlineError`s: "Some details of this launch couldn't be read just now." / "This coin's trades couldn't
     be read just now." (keys).
3. **Chart.** "Price" (key) and `PriceChart` at 180 pt. Points come from `pricePoints` × the quote USD, ending on the
   live price; with fewer than 2 points, a launch-time baseline is prepended. Tint by direction. Accessibility:
   "Price from curve trades" (key) or "Price from curve trades and the Soroswap pool". With zero trades, the key "No
   trades yet — the chart moves up as people buy on the curve and down as they sell." If the quote's USD price can't
   be read: "Prices couldn't be read just now." + Retry, and no chart in quote units.
4. **Ticket "Trade on the Curve"** (key), while not completed:
   - Buy/Sell segmented (keys); `StellarAmountField`.
   - **Max:** Buy with XLM uses `maxAmount(XLM, "launch_buy", newReserves)`; Buy with USDC uses the balance; Sell uses
     the token balance.
   - **Quote rows:** Buy shows "You receive" `tokensOut`, "Curve fee", "Creator tax" (> 0), "Early-buy tax"
     (attention, > 0) and "Refunded (curve full)" (> 0). Sell shows "You receive", "Curve fee", "Creator tax". All
     keys.
   - `PrimaryButton` "Buy %@"/"Sell %@" (keys).
   - **Footer:** a shortfall in attention, as "Not enough %@: you have %@." (key) or, for XLM, "Not enough XLM: you can
     spend %@. The rest keeps your account open and pays the network fee."; otherwise "Balance: %@ %@ · %@ %@".
   - **Slippage: fixed 1%**, so `minOut = quote × 99 / 100` (R11).
5. **Graduation pending** (key), when completed: "The curve is full. It graduates next, into a Soroswap pool with its
   liquidity locked forever, and then trades on Swap. DyorHQ graduates it within a few minutes, or you can do it now
   and pay only the network fee." Button "Graduate" (key).
6. **Graduated:** "Swap %@ on %@" (key, venue "Soroswap" verbatim) → `openStellarSwap`. "Pool fee" (key) =
   `poolFeeBps`. Footer: "The curve's liquidity is locked forever in a Soroswap pool. Trades now route through Swap.
   The pool's fee stays with the pool; no creator tax is charged after graduation."
7. **Your Holdings** (key), when `you.balance > 0`: "Balance", "Value" (keys), and "P&L" on curve trades.
8. **Creator Fees:**
   - "Creator tax" (key); "Curve fee share" = feeBps × (10000 − protocolShareBps) / 10000;
   - `StellarAddressRow` "Fee recipient" (key);
   - for the creator: "Your claimable fees" (key) + "Claim Creator Fees" (key), or "Nothing to claim yet — fees
     accrue as people trade your coin." (key);
   - footer: "The creator earns the creator tax plus a share of the %@ curve fee on every curve trade. Fees wait in
     the launchpad until the creator claims them."

   This section always shows, as on Monad.
9. **Recent Trades** (key): the newest 25, `StellarLaunchTradeRow` (copy :1187-1223):
   - an icon disc (buy `arrow.down.left` positive 14%, sell `arrow.up.right` negative 14%);
   - "Buy %@ %@"/"Sell %@ %@", the short trader, the quote amount, "%@ ago" (key);
   - venue `soroswap` rows say so; each row links to StellarExpert.
10. **About** (key):
    - Paragraph(description);
    - `StellarAddressRow` "Token" and "Creator" (keys);
    - "Creator tax"; "Priced in"; "Graduation venue" "Soroswap";
    - links Website (key), X, Telegram (https or http with a host only);
    - "View on StellarExpert".

**Loading.** The header comes from the row passed in. Unread figures show "—" or `unreadFigure`. Each part's failure
keeps the last good value and shows its own InlineError + Retry, driven by a `reloads` counter.

#### 8.10.3 Create: `StellarCreateLaunchView` (WP-36; copy of CreateLaunchView :1228-1498)

**Frame.** `NavigationStack { Form }`, title "Launch a Coin" (key) via `tr`, `.keyboardDoneButton()`, Cancel and
Review (keys). Sections in Monad's order:

1. **Blocker:** "The launchpad's terms couldn't be read. Close this screen and try again." (key); "New launches are
   paused."
2. **Image.**
   - `StellarArtwork` 72; `PhotosPicker`; "Choose Image"/"Change Image" (keys).
   - Status: "Uploading…" (key) / the error / "Square images look best." (key).
   - Pipeline: `UIImage.launchJPEG()`, then `POST /v1/media/upload-url`, then PUT. The local preview shows at once.
3. **Your Coin preview:** `StellarLaunchPreviewCard` (copy of :1501-1533), with "New" (key) and "Pairs with %@" (key).
4. **Coin.**
   - "Name" (key): at most 32 UTF-8 bytes, with `SymbolSafety.createRefusal(name:symbol:maxName: 32)` shown inline.
   - "Ticker" (key): `.characters`, filtered to A–Z and 0–9, 2–10 characters.
   - "Description" (key): `axis: .vertical`, `lineLimit(2...5)`, at most 500 characters.
5. **Links:** "Website", "X profile", "Telegram" (keys), URL keyboard.
6. **Pairing** (key):
   - `Picker("Paired with")` (key) over the enabled `economics.launchpad.quotes`;
   - "Graduates on" = "Soroswap", read-only;
   - footer "Graduates to a Soroswap pool, liquidity locked forever, once the curve raises %@ %@."
7. **Developer Buy (Optional)** (key): `StellarAmountField`, with Max from `maxAmount(XLM, "launch_create", 0)`. The
   key footer "Buy your own coin in the same transaction — snipe-tax exempt."
8. **Advanced** (key): `Stepper("Creator tax %@")` (key) over `0...maxCreatorFeeBps`, step 25. Footer: "Creator tax
   is charged on curve trades only. You receive it with your share of the curve fee." There is no holder-sharing
   toggle and no venue picker: the contract has neither.

**Review.** `store.launchCreatePlan` writes the metadata, then builds the plan. `onView` opens the new coin's page,
whose token comes from `TxStatus.returnValue`.

**Valid when:** the name has at least 2 characters and fits in bytes; the ticker is valid; there is no refusal; the
terms are read; there is no blocker; no upload is running.

#### 8.10.4 My Launchpad: `StellarLaunchpadProfileView` (WP-37; copy of LaunchpadProfileView.swift:10-453)

**Frame.** A sheet, `List(.insetGrouped)`, "My Launchpad" (key), Done.
- **Header:** `Avatar` with the name from `SocialSession` (the same DyorHQ account); `StellarAddressRow` "Address";
  `SavedLine`; three stats ("Portfolio", "Launched", "Holdings", keys).
- **Fees** (key): `feeTile`s (copy :248-271), one line per quote asset with a USD caption:
  - "Total fees" spans the width;
  - "Received" and "Claimable" sit side by side.
- **Claim rows:** `claimRow` (copy :274-288), "Creator fees · %@" (key) with Claim. "Claim All" (key) when more than
  one is claimable; it runs one transaction per coin, in sequence, in one sheet. The footer explains it.
- **Picker** Holdings · Launches · Activity (keys):
  - **Holdings:** `StellarPositionRow` (copy :455-495), with value and on-curve P&L, or no P&L for coins received by
    transfer. Empty: keys.
  - **Launches:** `StellarCreatedRow` (copy :497-525). Empty: keys.
  - **Activity:** `StellarActivityRow` (§8.12.3) for the launch kinds. Empty: keys.

#### 8.10.5 Review rows (all via `StellarConfirmationSheet`)

| Id | Title / confirm | Rows | After settle |
|---|---|---|---|
| L launch | "Launch %@" (key) / same | "Coin" `name ($SYM)`, "Paired with", "Graduation" threshold, "Graduation venue" Soroswap, "Creator tax", "Developer buy" (> 0), "Minimum" (`minOut`, 1% slippage) | open the coin page |
| B buy | "Buy %@" / "Buy" | "You pay at most" amount, "You receive", "Minimum" "%@ %@ (1% slippage)" (key) | clear the amount, reload |
| S sell | "Sell %@" / "Sell" | "You sell", "You receive", "Minimum" | same |
| G graduate | "Graduate %@" / "Graduate" (key) | "Venue" Soroswap, "Who pays" (key) = "You (network fee only)" | reload |
| C claim | "Claim Creator Fees" (key) / "Claim Fees" (key) | "Claimable", "To" (bound) | reload, refresh My Launchpad |
| CA claim all | "Claim All Fees" (key) / "Claim All" (key) | one row per coin, "Creator · %@" | same |

### 8.11 Moments tab

#### 8.11.1 Board: `StellarMomentsView` (WP-39; copy of MomentsView.swift:6-238)

- **Navigation.** `NavigationStack(path:)` with destinations `StellarMoment` and `StellarMomentLink(id:)`; the link
  loads the Moment first.
- **Title.** "Moments" (key).
- **Toolbar.** "My Moments" (key) → §8.11.5; "Publish" (key) → §8.11.4, disabled when there is no contract,
  publishing is off, or the session can't sign.
- **Polling.** `.task(id: "\(address)-\(scenePhase == .active)")` polls every 20 s, waiting out what is left since
  the last read. `Clock` (reuse) re-filters when a window closes.
- **Not deployed:** "Moments Not Live Yet" (key) / "New Moments appear here once the DyorHQ Moments contract is live on
  Stellar."
- **Header** (:190-221):
  - eyebrow "MOMENTS" (key), then `SavedLine`, then `TestnetBadge`;
  - the serif title "Make your favorite moments last forever." (key);
  - Paragraph "Publish a photo or video as an NFT on Stellar. Share it with everyone and earn every time it's
    collected.";
  - policy lines "Publishing new Moments is paused." / "The Moments terms couldn't be read. Publish is off until they
    are."
- **Filter.** `Picker("Filter")` (key) segmented: All (key `momentFilter.all`), Collecting (key), Closed [tight].
- **Grid:** 2 columns, 12 pt, prefetch at the column width.
- **Empty:** `camera.aperture`, "No Moments yet" / "Be the first: publish a photo or video and make it last
  forever." / "Publish a Moment" (keys). Filtered empty: "Nothing here yet" / "Change the filter to see other
  Moments." / "Show All Moments" (keys).
- **First load:** `BoardFirstRead`.

**Card: `StellarMomentCard`** (copy of MomentCard, MomentsUI.swift:172-225):
- **Art:** `StellarMomentArtwork` (poster for video), with an `allocationMoments` 35% / brand 18% gradient placeholder
  showing initials or `camera.aperture`.
- **Badge:** `StellarMomentStateBadge` on the media.
- **Title**, or "Moment #%lld". No `$SYMBOL`, because there is no coin.
- **Figures:** "Per edition" (key) over price + code; "Editions" (key) over `minted` or `minted/max`.
- **Progress:** only for a capped edition still collecting, with "%lld of %lld collected".

**`StellarMomentStateBadge`** (copy of MomentStateBadge :90-168), with state from `StellarMomentState`:

| State | Text | Symbol | Tint |
|---|---|---|---|
| collecting | "Collecting · %@" (key), countdown on media (`MomentsFormat.countdown`, `CountdownSchedule`) | `clock` | brand |
| sold out | "Sold out" [tight] | `checkmark.seal.fill` | positive |
| window closed | "Window closed" (key) | `clock.badge.xmark` | secondary |

#### 8.11.2 Moment page: `StellarMomentDetailView(id:)` (WP-38; pushed; copy of MomentDetailView.swift:8-660)

`List(.insetGrouped)`, with `.task(id: reloads)`, `.refreshable` and `Clock`. No share button and no OpenSea rows.

1. **Header:**
   - art 240 pt (a video loops muted over its poster);
   - title (title2 semibold), the state badge, place and date labels;
   - the first failed part's InlineError + Retry.
2. **Stats:** "Per edition", "Editions", "Collects" (keys), "Collectors" [tight].
3. **Collect** (key), while collecting:
   - `Stepper(value:in: 1...max(1, min(policy.maxPerCollect, max > 0 ? max − minted : maxPerCollect)))`. The ticket is
     hidden when sold out.
   - "You pay" (key).
   - "Your %@": the quote balance, or for XLM `maxAmount(XLM, "moment_collect", 0)`, in attention when short.
   - Button "Collect %lld Editions" (key; plural variant for 1).
   - "Sign in to collect." (key) when the session can't sign.
   - Footer: "Paid in %@: %@ to the creator, %@ DyorHQ. Your editions show in My Moments as soon as it settles."
4. **Your Position** (key): "Editions" `#12, #13 +4`. For the first 3: "View #%@ in Freighter" (`wallet.bifold`) →
   `StellarFreighterSheet`. Footer: "Each edition is an NFT in your Stellar account. Freighter can show it once you
   add it."
5. **You Created This** (key): "Earned" per quote. Footer: "%@ of every collect is paid straight to your account as it
   happens; there is nothing to withdraw."
6. **Collectors:** "Collectors" count and "Largest collector" `short · %lld editions`. Empty: "No collects yet."
7. **About this Moment** (key):
   - `StellarAddressRow` "Creator"; "Published"; "Collect window" "until %@" (keys);
   - "Split" "%@ creator · %@ DyorHQ"; "NFT royalty" (key); "Edition size" (max, or "Open edition");
   - "Open video" / "Open media" (keys; URL through the media policy);
   - `StellarAddressRow` "Collection"; "View on StellarExpert".
   - Footer: "Fixed at publish; nothing about a live Moment can be changed." (key)

#### 8.11.3 Collect review (MC)

"Collect %@" / "Collect" (key). Rows: "Moment", "Editions", "You pay", "Your NFTs" = "In My Moments once it settles".
After settle, it reloads and refreshes the owned editions.

#### 8.11.4 Publish: `StellarCreateMomentView` (WP-38; copy of CreateMomentView.swift:13-500)

**Frame.** `Form`, title "Publish a Moment" (key), `.keyboardDoneButton()`, `.scrollDismissesKeyboard(.interactively)`.

**Media.**
- An 84 pt preview: the local image or the video's cover frame; a play badge for video; a dim overlay while uploading.
- `PhotosPicker(.any(of: [.images, .videos]))` with "Choose Photo or Video" / "Change Photo" / "Change Video" (keys).
- Status: "Uploading…" / the error / "This becomes the NFT." (keys).
- **Photo:** `avatarJPEG(maxDimension: MomentsMath.photoMaxPixels, quality: 0.85)` off the main thread.
- **Video:** `MovieFile`; size ≤ 25 MB ("Videos up to 25 MB."); `MovieFile.coverFrame` → poster JPEG; upload both,
  the video with its real content type.
- Footer: "Shown in DyorHQ and in Freighter as the NFT." For a video, also "The video plays in DyorHQ; its cover frame
  is the NFT image."

**Moment:** "Name" (key), at most 48 characters and 80 bytes, with the `SymbolSafety` name refusal; "Place" (key), at
most 64; `DatePicker("When", in: ...Date())` (key).

**Economics** (key):
- "Collect price" (key) with its code;
- "Priced in" only when more than one quote is enabled;
- "Open edition" toggle, else editions 1…`maxEditions`;
- `Stepper("Collect window")` 1–30 days, "%lld days" (keys);
- footer: "Minimum %@. Each collect pays %@ to you and %@ to DyorHQ, straight away. Collecting ends when the window
  closes or the editions sell out.", with problems in attention ("The minimum price is %@.", key).

**Preview:** DetailRows "Collect price", "Edition size", "Each collect", "NFT royalty", "Window closes".

**Review (MP):** "Publish Moment" / "Publish" (key). Rows: "Moment", "Collect price", "Edition size", "Window", "Each
collect", "Minimum price", "NFT royalty", "Treasury wallet" (short, from `economics.moments.treasury`, read live), and
"Media" = "photo, stored by DyorHQ" / "video + cover frame, stored by DyorHQ".
- **Terms-changed guard:** the sheet's `check` compares `intent.display.platformBps`, `royaltyBps` and `minPrice`
  with the form's preview. On a mismatch: "The Moments terms changed since you started. Review them again." Confirm
  stays disabled (mirrors CreateMomentView.swift:244-259).
- **USDC price** without the trustline: the plan carries a `trust` step, so the enable section shows.

**On settle:** `returnValue` is the Moment id; the view dismisses and pushes it.

#### 8.11.5 My Moments: `StellarMomentsPortfolioView` (WP-39; copy of MomentsPortfolioView.swift:13-320)

A sheet, `List(.insetGrouped)`, "My Moments" (key), Done.
- **Tiles** (2×2, the metrics of :119-130):
  - "Editions" / "in your account";
  - "Moments" / "collected";
  - "Spent" / "collecting editions" (per quote);
  - "Earned" / "from your Moments" (per quote).
- **Your Editions:** `StellarEditionRow` (copy :281-320) showing art 44, title, "Edition #%@" and price. Swipe and
  context menu offer "View in Freighter".
- **Published by You:** art, title, "%lld of %lld collected" or "%lld collected", and earned.
- **Footer:** "Collected on Stellar. OpenSea doesn't list Stellar; add an edition to Freighter to see it there."
- **States:**
  - loading: "Reading your Moments…" (key);
  - error: InlineError + Retry;
  - empty: "No Moments Yet" (key) / "Collect a Moment and it shows up here." / "Browse Moments" (key).

#### 8.11.6 View in Freighter: `StellarFreighterSheet` (WP-38)

**Frame.** Detents medium and large; `SheetHeader` "View in Freighter"; a header row with art 56, the title and
"Edition #%@".

**Body.**
- Paragraph: "Freighter, the Stellar wallet, can show this edition once you add it. You'll need the contract address
  and the token ID."
- Numbered steps:
  1. "Open Freighter and switch to the test network." (testnet only);
  2. "Open Collectibles and choose Add manually.";
  3. "Paste the contract address, then type the token ID."
- "Contract address": a middle-truncated C… with a Copy button that copies `address.checksummed`
  (`StellarAccountID`).
- "Token ID": large monospaced digits with `.textSelection(.enabled)` and no Copy button (§3.10).
- Footers: "Needs Freighter 5.37 or later."; for video, "Freighter shows the cover image; the video plays in DyorHQ."
- "Get Freighter" → `https://freighter.app` in `SafariView`.

**Not included.** No deep link: no Freighter URL scheme was verified.

### 8.12 Portfolio, Profile, Recent Activity

#### 8.12.1 Portfolio: `StellarPortfolioView` (WP-40; copy of PortfolioView.swift:8-376)

**Opening.** `AppCovers` presents it when `router.network == .stellar` (`case .portfolio`). The ways in are Total
Volume, the side menu, Earn's ⋯ menu, and a `stellar:portfolio` notification.

**Frame.** Title "Portfolio" (key), ✕ (key), and a period Menu bound to `router.period`. Pull to refresh; saved
`.portfolio`.

| Card | Spec |
|---|---|
| Hero | "Cumulative Volume" (key); the period chip; serif 38 volume with `unreadFigure`; "Across Spot, Earn, Launch, Moments and Bridge"; a 2×2 grid of "Fees paid", "P&L" (with "*" when incomplete), "Fees received", "Trades" (keys); `SavedLine` / "Refreshing…" / an error / "Updated %@ ago" (keys); "Network fees paid: %@ XLM"; the testnet caption. |
| Volume by Section (key) | A stacked bar and legend: Spot, Earn (`allocationPerps`), Launch, Moments, Bridge (brand). |
| Section cards | Copy of `sectionCard` (:246-290) for the five sections. Earn's fourth column is "Trades", as Perps'; the others show "Received". A header tap dismisses and, after 300 ms, calls `router.open(menuItem)`, landing on the Stellar tab or mode. |
| Assets | `StellarAssetsCard` (copy of AssetsCard): tokens with values, then "Editions", a 3-column grid with title and "#%lld". No Past Cohorts card (Monad only). |
| Activity (key) | `StellarActivityRow`s from `portfolio.activity`; "Nothing in this period." / "Loading…" / "Show all %lld" (keys). |
| Coverage footer | The server's `coverage.note`, verbatim (M4 widens coverage). |

Portfolio is DyorHQ history (a session route). In the passkey public-view case (§8), the hero's figures stay unread
and `StellarSignInRow` sits under the hero; the Assets card still fills from holdings.

#### 8.12.2 Profile hooks (WP-41; the ProfileView STELLAR_LITE extension and `Lite/StellarProfile.swift`)

**Wallet on Stellar:**
- "Receive" → `StellarReceiveSheet`; "Send" → `StellarSendSheet` (disabled when the session can't sign);
- **"Recent Activity"** → `StellarRecentActivityView` (`SettingsRow`, keys);
- testnet footer: "On the Stellar testnet."

**Network on Stellar:**
- the Network row and chip are unchanged;
- "Chain" (key) = "Stellar testnet";
- **"RPC"** (key) = the pinned phone RPC's host;
- the "Stellar account" row → `StellarAccountView`;
- testnet footer, replacing "…DyorHQ pays the Stellar network fees.": "Testnet balances have no value. You pay
  Stellar's network fees in XLM, as you pay MON on Monad."

**`StellarAccountView`** (replaces DyorLite's `LiteAccountView`; `SettingsRow` / `DetailRow`):
- "Stellar address": `StellarAddressRow`, whose copy writes `address.checksummed`; "Secured by"; "Network" (Stellar +
  `TestnetBadge`);
- "Minimum balance" = `xlm.minBalance`, with the footer "Stellar keeps this much XLM in every account: %@ XLM for
  the account and %@ XLM for each enabled asset. It's returned when you remove the asset.";
- on mainnet only, "Set up by DyorHQ" (the sponsored reserve);
- "Show Stellar secret key", through `session.revealSecret`, with the import note (Freighter, LOBSTR, xBull). It
  always asks for Face ID or the passcode, whatever App Lock says, as Monad's key export does
  (WalletExportView.swift:166-180); with no device passcode it refuses with Monad's copy (key);
- "Sign out of Stellar" (§7.2): revokes the refresh token, erases the session and the Stellar saved figures, and
  switches to Monad. The next switch runs the sign-in step again: silent for a seed account, one passkey prompt for a
  passkey account. No prompt to sign out: the Stellar key stays where the account keeps it.

The faucet and "Reserves paid by DyorHQ" are removed from this page; the faucet lives in Deposit.

#### 8.12.3 Recent Activity: `StellarRecentActivityView` + `StellarActivityRow` (rows WP-20, list WP-41; copy of RecentActivityView.swift:8-120)

`List(.insetGrouped)`, "Recent Activity" (key). Rows from `/v1/activity`:
- an icon disc (34 pt, brand 14%), title, subtitle, "%@ ago" (key);
- the status override from Monad's PendingActivity: pending is `clock` with "Sent — confirmation not seen yet"
  (key); failed is `xmark.circle` with "Reverted — only the network fee was spent" (key);
- a link to `StellarExplorer.transaction`, and "Fee %@ XLM" (or "Fee paid by DyorHQ") in the subtitle's second line.

**Mapping** (`StellarActivityPresenter`, past tense, reusing Monad's keys):

| Kind | Symbol | Title | Subtitle |
|---|---|---|---|
| `launch_create` | `flame.fill` | "Launched $%@" (key) | name |
| `launch_buy` / `launch_sell` | `arrow.down` / `arrow.up` | "Bought %@" / "Sold %@" (keys) | "%@ %@ for %@ %@" (key) |
| `launch_claim` | `dollarsign.circle.fill` | "Collected %@ creator fees" (key) | amount + code |
| `launch_graduate` | `checkmark.seal.fill` | "%@ graduated" (key) | Soroswap |
| `moment_publish` | `camera.aperture` | "Published %@" (key) | "%@ per edition" |
| `moment_collect` | `camera.aperture` | "Collected %@" (key) | "%lld editions · %@" (key) |
| `swap` | `arrow.left.arrow.right` | "Swapped" | "%@ → %@" |
| `payment` | `arrow.up` | "Sent %@" | to + amount |
| `earn_deposit` / `earn_withdraw` | `leaf` | "Supplied %@" / "Withdrew %@" | Blend · pool |
| `bridge_out` / `bridge_in` | `point.3.connected.trianglepath.dotted` | "Bridged %@" | from → to |
| `trust` / `activate` / `restore` / `faucet` | `checkmark.circle` | "Enabled %@" / "Set up your account" / "Restored data" / "Got %@ test XLM" | |

**Other states.**
- Footer: "Open full history on StellarExpert" → the account page.
- Empty: `ContentUnavailableView` "No Activity Yet" (key) / "Your swaps, launches, Moments and Earn deposits on
  Stellar show up here." / "Start Trading" (key), which closes Profile and opens Earn in Swap mode.
- Loading: "Loading activity…" (key). Error: InlineError + Retry. Pull to refresh.
- No session (the passkey public-view case of §8): `StellarSignInRow` in place of the list.

### 8.13 Side menu (WP-21; SideMenuView reused, Router `MenuItem` hook)

**Rows on Stellar:** `[.home, .spot, .earn, .launch, .moments, .news, .portfolio, .help]`, Monad's list with Earn in
Perps' slot. The "Now" badge follows `isCurrent` (§3.5). The footer stays "DyorHQ %@ · Stellar testnet".

**Subtitles on Stellar:**

| Row | Subtitle |
|---|---|
| Home | "Balances and markets" (Stellar key, because Home now has markets) |
| Spot | "Swap across Stellar's venues" |
| Earn | "Lend XLM and USDC on Blend" (existing) |
| Launch | "Launch and trade coins on Stellar" (existing) |
| Moments | "Collect editions on Stellar" (existing) |
| Portfolio | "Volume, fees and P&L on Stellar" |
| News, Get Help | Monad's |

### 8.14 Network sheet setup (WP-22; `Lite/NetworkSheet.swift`)

- **Confirm step** adds: "You pay Stellar's network fees in XLM, as you pay MON on Monad."
- **Setup copy** (replaces NetworkSheet.swift:540-543 and :639):

  | Network | Copy |
  |---|---|
  | Testnet | "Creates your test account with %@ test XLM from Stellar's testnet faucet, then enables USDC. Enabling USDC holds 0.5 XLM and costs a small network fee, paid from your test XLM." (`faucet.amount`) |
  | Mainnet | "Creates your Stellar account and enables USDC. DyorHQ pays this one-time setup. After it, you pay Stellar's network fees in XLM." |
- **Enable USDC row** in the setup checklist. Before the tap it shows "Holds %@ XLM · network fee up to %@ XLM" from
  `session.setupFee`: `baseReserve`, and the `trust` estimate of `/v1/fees` (public). Once the step is built, the
  decoded fee replaces the estimate, and PlanRunner refuses a built fee above the one confirmed (§4.4). It runs only
  after the user has tapped Set Up, which is the confirmation for that fee. That matches Monad, where the setup
  confirm shows the cost before anything is signed.
- **Steps (decision 6).** There is no "Unlock your Stellar key" step for any account, and no "Unlocked", "Unlock again
  to continue." or idle drop.

  | Account | Checklist | Prompts |
  |---|---|---|
  | Seed (imported phrase or key, email & password v2) | Sign in ("Signing in…", silent SEP-53, §5.8) → Invite code (only when the server asks; nothing is held while it waits) → Set up (the user's tap) | none to sign in. At Enable USDC, Face ID or the passcode once, only when App Lock applies, as a Monad Confirm. |
  | Passkey (Mera) | Set up first (the user's tap; on a first sign-in on this iPhone, an optional "Invite code" field: "Needed the first time you use Stellar.") → "Confirm with your passkey" → Sign in → Enable USDC | exactly one passkey prompt. Its signer signs the sign-in and then, with no user wait in between, the Enable USDC step, and is dropped. An account already set up stops after the sign-in, and nothing is spent. |

  A passkey account that left the invite field empty and turns out to need one sees the field again, with "Enter
  your invite code to continue."; the next tap asks for the passkey again (the run kept nothing). Going to the
  background during a passkey run ends it: "Not finished. Try again." (no signer survives it).
- **Already set up.** `plan()` is `.instant` for an account set up on this iPhone, session or not: the switch never
  opens this sheet, never prompts, and the session renews in the background (§6.18). After Sign out of Stellar, the
  switch shows only the Sign in step (silent for seed accounts).
- **Removed:** "you spend nothing", "DyorHQ pays the network fees and the reserve…", "Unlock your Stellar key",
  "Unlocked", "Unlock again to continue." and "Unlock was cancelled." (WP-52 prunes the keys).

### 8.15 Notifications (WP-21 recorder; titles from `LiteTitles`)

| Event | Kind | Title | Body (+ " · Stellar testnet") | Reference |
|---|---|---|---|---|
| Swap settled | `.swap` | "Swap complete" (key) | "Swapped %@ → %@" (key) | `stellar:swap` |
| Earn supply / withdraw | `.transaction` | "Supplied to Earn" / "Withdrawn to Spot" (key) | "%@ %@ · Blend" | `stellar:earn/<market>` |
| Send | `.transaction` | "Sent" | "%@ %@ to %@" | `stellar:home` |
| Launch create / buy / sell / claim / graduate | `.transaction` | Activity titles (§8.12.3) | amount | `stellar:launch/<token>` |
| Publish / collect | `.moments` | "Published %@" / "Collected %@" (keys) | | `stellar:moment/<id>` |
| Bridge complete / ready to claim (tracker) | `.swap` / `.transaction` | "Bridge complete" (key) / "Ready to claim on Monad" | "%@ bridged from %@ to %@." (key) | `stellar:bridge/<id>` |
| Cash added / out (tracker) | `.transaction` | "Cash added" / "Cash out complete" | "%@ %@ via %@" | `stellar:home` |
| Enable, restore, faucet | none (Activity only) | | | |

Route `.home`; owner = the Monad address; dedupe by plan id or transfer id (§3.7).

---

## 9. Placeholder removals

| Placeholder (evidence) | Fix | Owner | Test |
|---|---|---|---|
| Smoke "CHECK" launch and untitled Moment #1 in the live feeds (deploy-contracts.ts:138-168; indexer :64-66) | Today's ids are recorded as `smoke`, so `listed=false` hides them before O-1. Smoke is opt-in on new deploys, and `indexFromLedger` is set after configuration. | WP-04, WP-14, WP-16 | decode unit test; e2e asserts no `listed=false` row is served |
| "TOKEN"/"Token" for launch tokens (account.ts:120-123, swap.ts:35-40) | One `resolveAsset(id)` in `_shared/assets.ts`: registry → `lite.launches` → `symbol()`/`name()` on chain → `CODE:ISSUER` → 400 `unsupported_asset` | WP-10 | `resolve.test.ts` asserts no payload contains "TOKEN" |
| Untitled Moments and videos without an image (moments.ts:75-81) | `moment_metadata` written at publish; the poster is required for video; unlisted when metadata is unknown | WP-16 | metadata unit test; e2e |
| `USDC: 1, BUSDC: 1` and the order-book mid (prices.ts:27) | Reference cache; null when stale | WP-13 | `refprices.test.ts` |
| "Network fee: Paid by DyorHQ" (ConfirmSheet.swift:50,159), "DyorHQ pays the network fees and the reserve" (NetworkSheet.swift:639), "Reserves paid by DyorHQ" (LiteAccountView.swift:65,97), "DyorHQ pays the Stellar network fees." (ProfileView Stellar footer) | §4.6, §8.12, §8.14 | WP-20, WP-22, WP-41, WP-50 | placeholder scan pattern |
| Bridge quote `fee:"0"` and fixed ETA (bridge.ts:86-98) | Iris fee; measured ETA or null | WP-17 | Iris fixture test |
| Hard-coded launch economics copy (LiteLaunchView.swift:327) | `/v1/economics` | WP-14, WP-36 | e2e |
| Edition cap 10,000 in the UI vs 100,000 on the server | `config.limits` and `economics.moments` | WP-02, WP-38 | e2e asserts limits |
| Base reserve as a 0.5 constant (LiteAccountView.swift:26) | `xlm.baseReserve` | WP-10, WP-41 | XLMReserve tests |
| "10,000" in copy (NetworkSheet.swift:542, LiteHomeView faucet) | `config.faucet.amount` | WP-02, WP-22, WP-32 | placeholder scan |
| `LITE_NETWORK` typo meaning testnet (networks.ts:167-169) | Throws | WP-02 | `env.test.ts` |
| Unused `SOROSWAP_API_KEY`, `MONAD_RELAYER_KEY` | Deleted | WP-02 | type check |
| Indexer wipe on a lagging mainnet RPC (index.ts:45-50) | Testnet only, or an explicit flag | WP-02 | reset unit test |
| Only the 200 newest tokens kept alive (index.ts:202) | Rotation (§4.8b) | WP-10 | ttl unit test |
| "Valued at reference prices." on any network (LiteHomeView.swift:165-170) | The §8.1 caption, testnet only | WP-31 | QA |
| Moment metadata's hard-coded "Network: Stellar testnet" (moments.ts:80) | From `env.network` | WP-16 | metadata test |
| Treasury without a USDC trustline would break USDC collects (moments lib.rs:247-249) | Deploy preflight | WP-04 | script dry run |

`scripts/agent/scan-placeholders.sh` (WP-01) greps the new app and backend code for these patterns:
`"TOKEN"`, `example.invalid`, `USDC: 1`, `BUSDC: 1`, `Paid by DyorHQ`, `pays the Stellar network fees`,
`Reserves paid by DyorHQ`, `10,000 test`, `10000 test`, `Lorem`. Allowed exceptions sit in `scripts/agent/scan-allow.txt`
(path and pattern, with a reason): the sponsored rows in StellarConfirmationSheet and the Stellar tables' sponsored
strings.

---

## 10. Strings and localization (en, es, fr, zh-Hans, ko)

**Tables.**
- **Per area.** New copy goes in `ios/Internal/Resources/Stellar<Area>.xcstrings`, one table per area:
  `StellarCommon`, `StellarReview`, `StellarShell`, `StellarSetup`, `StellarHome`, `StellarToken`, `StellarWallet`,
  `StellarBridge`, `StellarSwap`, `StellarEarn`, `StellarLaunch`, `StellarLaunchBoard`, `StellarMoments`,
  `StellarMomentsBoard`, `StellarPortfolio`, `StellarProfile` and `StellarAlerts`.
- **One owner each.** Each table is owned by exactly one package (§13), so parallel packages never edit the same
  catalog.
- **Picked up automatically.** `Internal/Resources` is already a source folder of the internal target
  (generate.py:56), so new tables need no project edit.
- **`Lite.xcstrings`** keeps the existing glue's keys. Only WP-52 edits it (pruning stale keys, including the unlock,
  locked-card and idle-drop keys that decision 6 retires).

**Resolving.**
- **`liteTr(_:)`** (LiteText.swift) asserts that the table is `Lite` or starts with `Stellar` (WP-20).
- **Written forms:**
  - `liteTr(LocalizedStringResource("…", table: "StellarHome", comment: "…"))`;
  - `Text("…", tableName: "StellarHome", comment: "…")`;
  - `Paragraph(LocalizedStringResource(…, table: …))`;
  - `InlineError(message: LocalizedStringResource(…, table: …))`.
- **Order.** `table`/`tableName` always comes before `comment` (§3.10 rule 7).
- **Navigation titles** use `tr(LocalizedStringResource(…, table:, comment:))` (§3.10 rule 3).

**Reused keys.** Copy identical to Monad's reuses a build-23 Localizable key, written with no comment or through its
enum label. Examples: "Top Tokens", "My Holdings", "Total Volume", "Avail. Balance", "In Use", "Max network fee",
"Up to %@", "Review Swap", "Cumulative Volume", "Recent Activity", "Swap complete", "Bridge complete", "Withdrawn to
Spot", "%lld%% to graduation". A literal that isn't a key in the app snapshot must name a Stellar table (§2.2 lists keys the
specs wrongly assumed).

**Translations.**
- Every new key ships en, es, fr, zh-Hans and ko, state `translated`, with a call-site comment.
- Chips, tabs, segments, badges and stats carry `[tight]`.
- Plurals ("%lld editions", "%lld steps", "%lld more steps") use plural variations.
- Strings moving from DyorLite's catalog keep their translations (`scripts/dev/merge-translations.py`).
- Translations of DyorKit-only keys reused as Stellar keys ("Graduation pending", "Not the real %@") are copied from
  DyorKit's catalog.

**Never translated:** Stellar, Monad, DyorHQ, XLM, USDC, EURC, Soroswap, Aquarius, Blend, Circle CCTP, Freighter,
StellarExpert, tickers, addresses and amounts. Write them with `Text(verbatim:)` or pass them as `%@` arguments.

**Numbers and dates:** `NumberStyle`, `PriceFormat`, `RelativeTime` and `MomentsFormat`, with `L10n.locale`. Language
changes reach these screens at once (NetworkRoot.swift:63).

**Checks.**
1. **Sync.** `xcrun xcstringstool sync <table> --stringsdata <every .stringsdata under the internal build's
   DyorHQ.build/Objects-normal>`. Never `scripts/dev/strings-sync.sh`.
2. **`python3 -I scripts/dev/check-strings.py --enforce`.** It reads every tracked `ios/**/*.xcstrings`, the new
   tables included.
3. **`python3 -I ios/Internal/check-lite-strings.py --derived <DerivedData> --enforce`** reads the
   `.stringsdata` of sources under `ios/DyorHQ/Lite/`. It fails when:
   - a Stellar or Lite key is missing from its table or untranslated;
   - a default-table key doesn't exist in the snapshot's `ios/DyorHQ/Resources/Localizable.xcstrings`;
   - an unknown table is used;
   - with `--enforce`, a table holds a key no source uses;
   - a never-translated name was translated.
4. **DyorKit `AppStringsTests`.** The comment rules (§3.10).
5. **Simulator.** A pass in all five languages; ko and zh-Hans wraps checked at AX3.

---

## 11. Accessibility, Dynamic Type, appearance, motion

**VoiceOver.** Labels reuse Monad's wherever the element is Monad's. The Stellar additions:

| Element | Label / value | Hint |
|---|---|---|
| Hero total (unread) | "Loading…" (`unreadFigure`) | |
| Total Volume | "Total volume %@" (key, the period) | |
| Split stat | "%@, %@" (category, value) | |
| Top token row | combined "%@, %@, %@, %@" (code, name, price, change via ChangeBadge) | |
| Earn position row | "%@, %@ supplied, earned %@, %@ APY" | |
| Earn market header | "%@ market, supply APY %@" + ", test network" | "Changes the market." |
| Pool chip | "Lends through Blend, pool %@" | |
| Utilization gauge | "Utilization %@" | |
| Fee row | "Max network fee, up to %@ XLM" / "Max network fee, paid by DyorHQ" | |
| Enable row | "Enable %@. Holds %@ XLM while enabled." | |
| XLM balance footer | "Balance %@ XLM, of which %@ XLM is locked as Stellar's minimum balance" | |
| Launch card | "<name>, $<SYM>, Market cap 52.3 thousand XLM, 2 hours, 34% to graduation" (art hidden) | |
| Moment card | "<title>, Collecting, 2 days 3 hours left, Per edition 1.5 USDC, Editions 34 of 100" | |
| Charts | Their label + `.accessibilityValue("from %@ to %@")` | |
| Addresses | `speechSpellsOutCharacters()` | |
| Copy buttons | "Copy contract address", "Copy address" | |
| Mode switcher, bottom tabs, segmented pickers | `.isSelected` | |

**Announcements:** "Funds arrived", plus a review step's "sent", "confirmed" and failure text. Tracker completions
are notifications, not announcements.

**Dynamic Type up to AX5.**
- **Scaling:** hero `minimumScaleFactor(0.6)`, split 0.65, tiles 0.8 (Monad's values); the rank column and tile symbol
  use `@ScaledMetric`.
- **Layout:**
  - Earn's rates column stacks above the ticket (`ViewThatFits`);
  - stats rows go from `HStack` to `VStack` from `.accessibility2`;
  - the switcher and bottom tabs use `ViewThatFits`, falling back to horizontal scroll;
  - boards keep 2 columns, with `lineLimit(1)` + `minimumScaleFactor(0.7)` on figures;
  - sheets go `.large` and scroll;
  - the review bottom bar stays pinned.
- **Korean** multi-line copy uses `Paragraph`.

**Hit targets** are at least 44 pt.

**Colour is never the only signal.** Deposit and Withdraw differ by text, changes have a sign, warnings and statuses
carry words.

**Appearance.**
- **Colours:** only semantic tokens (`systemGroupedBackground`, `secondarySystemGroupedBackground`, `tertiarySystemFill`,
  `Color.brand`, `positive`, `negative`, `attention`, `onStatus`, `allocation*`, `logoRing`, `.bar`). The only fixed
  colour is the QR's white plate.
- **Marks:** logos and art use `accessibilityIgnoresInvertColors()`. XLM's mark is a black disc edged by `logoRing` in
  dark mode.
- **Contrast:** `TestnetBadge` is 5.4:1 light and 7.5:1 dark. The "Blend test" capsule is `.secondary` on a 14% fill.
- **QA:** every screen in light, dark and Smart Invert.

**Motion and haptics.**
- `Haptics.tap()` on toolbar buttons;
- `Haptics.selection()` on chips, filters and pickers;
- `Haptics.commit()` in `PrimaryButton`;
- success or error haptics at a review's end.

Saved figures never animate in. With Reduce Motion, no transitions are added.

---

## 12. Testing and QA

### 12.1 Build-23 and repository checks (WP-00, WP-01)

**`ios/Internal/check-build23.py [--worktree] [--app <App Store .app>]`** (Python, no `unifdef`):

1. It diffs base..HEAD (or base..worktree) over the whole repository and checks each path:

   | Path | Rule |
   |---|---|
   | `ios/DyorKit/**` | changed → fail |
   | Added `ios/DyorHQ/Lite/**.swift` | after stripping, only blank lines and `//` comments may remain |
   | Modified `ios/DyorHQ/**.swift` | `strip(text)` must equal the base blob byte for byte |
   | Any other added `.swift`, or a deleted or renamed app file | fail |
   | `ios/Internal/**` | allowed |
   | `ios/project.yml`, `ios/DyorHQ/Info.plist` | only the `CFBundleVersion` line |
   | `ios/.gitignore` | only the `project-internal.json` and `DerivedData*` lines |
   | Anything else | must be listed in `ios/Internal/unflagged-changes.txt` with a reason |

   `unflagged-changes.txt` starts with the committed tagline c2ee50e: `ios/DyorHQ/Support/GetHelpView.swift` (the
   tagline literal line); `ios/DyorHQ/Resources/Localizable.xcstrings` (exactly the old key removed and the new key
   added, compared key by key as JSON); `brand/dyorhq-brand-guide.md`; `brand/dyorhq-design-system.md`.
2. **`strip`** keeps a line-based `#if` stack:
   - `#if STELLAR_LITE` opens a dropped frame;
   - `#else` in that frame flips it to kept;
   - `#endif` closes the frame;
   - directive lines are removed;
   - other `#if` frames are kept verbatim and tracked for nesting;
   - `#elseif` inside a STELLAR_LITE frame, or `#if !STELLAR_LITE`, fails as unsupported.
3. **`--app`:**
   - `nm -U <app>/DyorHQ | grep -E 'DyorLite|StellarCore|LiteClient|StellarKit'` must be empty;
   - no `StellarKit_*`/`DyorLite_*` bundle may be present;
   - no `Lite.xcstrings`, `Stellar*.xcstrings` or `.strings` from them may be present.
4. It prints paths and the first differing line only. It never prints file contents.

**Other checks.**
- **`ios/Internal/check-copies.py`** reads every `// Stellar copy of <path> <symbol> (d387a64
  sha256:<12>)` header under `Lite/`. It brace-matches the symbol's declaration in the base blob and compares hashes.
  A mismatch lists the copy to re-sync.
- **`ios/Internal/check-lite-strings.py`:** §10.
- **`scripts/agent/scan-placeholders.sh <A> <S>`:** §9.
- **`git grep -n "SEAM(" -- ios/DyorHQ/Lite`** must be empty at I2 (§13.3).

### 12.2 Test targets

| Target | Holds | Run |
|---|---|---|
| StellarKit (`swift test`, also Linux CI) | renames; fixtures decode (public views and old auth answers included); XLMReserve; PlanFees; PlanRunner with fakes (fee above confirmed, sponsor outside activation, sponsored inner fee cap, limits); verifier vectors; LiteSessionAPITests (WP-03b: challenge shape refusals never call `sign`; a non-SEP-53 signature is refused before verify; one shared renewal for concurrent 401s, then one retry; a viewer request falls back to `?address=`; a session request throws `notSignedIn`; refresh stores the rotated token) | `cd $S/ios/Packages/StellarKit && swift test` |
| DyorLite (xcodebuild on the agent simulator) | LiteSessionTests, journey, titles, l10n, with a fake provider that counts prompts (decision 6: zero prompts on resume, renewal, 401 and reads; no `locked` state reachable; App Lock prompt once per run only when its closure says so; passkey setup is one ceremony; no signer held after a run or the background); LiteDerived (totals gating, maxAmount); LiteMediaPolicy; LiteSettled (once per plan, fires with no view, carries section and reference); LiteErrorText codes; StellarMarketRanking; StellarMomentState; StellarLaunchMath; StellarActivityPresenter (never "TOKEN"); StellarPercent (0.0123 → 1.23) | `xcodebuild -scheme DyorLite -destination "platform=iOS Simulator,id=$SIM" test` |
| DyorHQInternalTests (new hosted target, WP-20) | StellarRouting (menu order, tab mapping, `StellarDestination` round trip, refuses Monad references, `openOnStellar`); tab order; StellarFormat (fee summary strings: one step, more steps, unpriced, sponsored); StellarAccountID (checksum); StellarImages; StellarSaved (separate directory, erase on forget, epoch guard); StellarActivityRecorder (kind, route `.home`, reference, owner, dedupe); StellarKeys (WP-20: `GatedSeedKeyProvider` signs the sign-in with no gate call; `beginSigning` calls the gate only when App Lock applies and fails closed with no passcode; `revealSecret` always calls it; the passkey provider never calls it); per-area model tests | `xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ … test -only-testing:DyorHQInternalTests` |
| DyorKit (`swift test`) | the source lints over Lite/ (§3.10) | `cd $A/ios/DyorKit && swift test`, then restore `Package.resolved` |
| Deno unit (`backend/tests/unit/`) | §12.5 | `deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/` |
| SQL (`backend/tests/sql/*.sql`, each inside `begin … rollback`) | reserve_sponsorship (once, released retry, attempts, daily count, daily fee, IP); token_candles merge; token_price_at; ref_usd_at preference; launch_holders exclusion; `lite.auth_refresh` (unique hash, single use, family revoke; `anon` can't read it); `lite_api` executes new functions and `anon` can't; the RLS loop | `backend/scripts/schema-test.sh <port>` |

### 12.3 Verification blocks (referenced by every package)

`$S` is the package's worktree of the private repository (`scripts/agent/worktree.sh`) and `$A` is `$S/app`, its app
copy (owner decision 2026-10-14). `$SIM` is the agent simulator
`3672E24D-0458-4181-B351-94A3D1FCDB01`. `$WP` is the package id.

```sh
# V-APP (every netswitch package)
cd $A/ios && python3 -I Internal/generate.py --spec project.local.yml --lite $S/ios/Packages
for c in Debug Release; do xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ -configuration $c \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData-$WP -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO build; done
xcodegen generate --spec project.local.yml
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData-$WP-as CODE_SIGNING_ALLOWED=NO build
python3 -I Internal/check-build23.py --app DerivedData-$WP-as/Build/Products/Release-iphonesimulator/DyorHQ.app
python3 -I Internal/check-copies.py
# V-STR
python3 -I Internal/check-lite-strings.py --derived DerivedData-$WP --enforce
(cd $A && python3 -I scripts/dev/check-strings.py --enforce)
# V-DYORKIT (every netswitch package)
(cd $A/ios/DyorKit && swift test); git -C $A checkout -- ios/DyorKit/Package.resolved
# V-INT (hosted tests; sim lock)
$S/scripts/agent/lock.sh acquire sim $WP
xcodebuild -project $A/ios/DyorHQInternal.xcodeproj -scheme DyorHQ -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $A/ios/DerivedData-$WP test -only-testing:DyorHQInternalTests
$S/scripts/agent/lock.sh release sim $WP
# V-KIT
(cd $S/ios/Packages/StellarKit && swift test)
# V-LITE (sim lock)
(cd $S/ios/Packages/DyorLite && xcodebuild -scheme DyorLite -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $S/.dd-$WP -skipPackagePluginValidation test)
# V-BE
cd $S && C=backend/supabase/functions/deno.json
deno check --config $C backend/supabase/functions/lite/index.ts backend/supabase/functions/lite-indexer/index.ts \
  backend/scripts/*.ts backend/tests/e2e/lite_e2e.ts
deno test -A --config $C backend/tests/unit/
backend/scripts/schema-test.sh 55${NN}
# V-LIVE (private stack, testnet; NN = the package's two digits)
PORT_BASE=2${NN}00 backend/scripts/local-stack.sh start --no-loop
LITE_API=http://127.0.0.1:2${NN}00/lite deno run -A --config $C backend/tests/e2e/lite_e2e.ts <phases>
PORT_BASE=2${NN}00 backend/scripts/local-stack.sh stop
# V-SCAN
$S/scripts/agent/scan-placeholders.sh $A $S
```

`QUICK=1 scripts/agent/verify-app.sh $S $WP` (packages: internal Debug build and the source checks) or `scripts/agent/verify-app.sh $S $WP` (the lead's integration: also the internal Release build, the App Store build with `check-build23.py --app` and DyorKit's tests) runs V-APP, V-STR and V-DYORKIT in order and stops at the first failure.
`scripts/agent/verify-backend.sh $S $NN` runs V-BE.

### 12.4 Shared verifier vectors

Generated by `backend/tests/vectors/gen-vectors.ts` and committed to
`ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/verifier.json`. The Swift `StellarCoreTests` and the Deno
`verify.test.ts` must agree on every vector, and the count stays above 30.

- **Every vector** gains `feePolicy`, and `decoded` gains `resourceFee`, `memo` and `to`.
- **Changed:** the old "sponsored trust ok" now fails, as "sponsor outside activation".
- **New, synthetic:**
  - classic fee at the cap ok; inclusion over the cap; Soroban fee over the cap; resource fee above fee;
  - activate ok; activate funds XLM (fails); user-paid trust ok;
  - payment to another destination than `intent.to` (fails); memo mismatch (fails);
  - SAC transfer to another `to` (fails);
  - Soroswap `to` ≠ user (fails); Soroswap `amount_out_min` below receive (fails);
  - curve buy `min_tokens_out` below receive (fails);
  - Blend submit to another account (fails);
  - CCTP burn to another mint recipient (fails);
  - restore with a footprint outside the allowlist (fails); restore ok;
  - starter step with an inner fee above the cap (fails in PlanFees).
- **Real vectors** are regenerated from a database filled by a fresh e2e run at I1, so they reflect user-paid plans.

### 12.5 Backend unit tests

| File | Covers |
|---|---|
| `router.test.ts` (WP-02, then WP-02b) | every route to its handler; static Moments paths before `:id`; public routes need no JWT; viewer routes answer without a header (public view), refuse a bad or expired token with 401, and need `?address=` where they are about an account; session routes need the JWT |
| `env.test.ts` (WP-02, then WP-02b) | unknown network throws; keeper required on mainnet and different from the sponsor; the session TTL overrides apply on testnet only, with their minimums |
| `session.test.ts` (WP-02b) | verify returns a refresh token; refresh rotates it; a reused token revokes the family (401 `refresh_reused`) and its successor stops working; expired and unknown tokens get `refresh_invalid`; a revoked tester gets 403 and the family goes; signout revokes and answers 204 for unknown tokens; access JWT lifetime 1 h; the invite is not consumed for an existing tester |
| `fees.test.ts` (WP-10) | minBalance and spendable from Horizon fixtures (Friendbot, sponsored mainnet, liabilities); `assertAffordable` order and codes; `feeCeiling` fallback and cap; `starterSwapEligibility` truth table |
| `resolve.test.ts`, `outcome.test.ts`, `symbols.test.ts` (WP-10) | resolution; never "TOKEN"; `amountOut` from SDEX XDR, Soroswap Vec, Aquarius u128; look-alike folding |
| `verify.test.ts` (WP-11) | the vectors |
| `refprices.test.ts`, `markets.test.ts` (WP-13) | Kraken and Horizon fixtures (captured 2026-10-14); fallback order; stale and null; never a constant; Popular order; `isNew`; change; market cap |
| `launch.test.ts`, `watch.test.ts` (WP-14) | decode of launch, trade, graduate, claim_creator; token transfer as `i128` and as `{amount, to_muxed_id}`; mint and burn; Soroswap swap and sync either way round; cursor merge |
| `earn.test.ts` (WP-15) | earned, pool status mapping, history |
| `moments.test.ts`, `localmedia.test.ts` (WP-16) | metadata (poster required), states, editions decode, upload budget, local media HMAC/expiry/write-once/refused on mainnet |
| `bridge.test.ts` (WP-17) | Iris fixture, ETA median, relay cap, minimum |
| `stats.test.ts`, `holdings.test.ts` (WP-18) | each section's figures against hand-computed numbers; no launch double count; totals gating |
| `<area>_fixtures.test.ts` (each backend package) | the package's payloads equal the WP-03 fixtures |

### 12.6 End-to-end phases (`backend/tests/e2e/lite_e2e.ts` driver + `phases/<area>.ts`)

| Phase | Owner | Asserts |
|---|---|---|
| `auth` | WP-10 | the trust step is `feePayer: user`; XLM fell by `fee_charged` plus the 0.5 XLM reserve |
| `session` | WP-02b | verify gives a refresh token; refresh rotates; reuse revokes the family; signout revokes; with `--short-sessions`, a request after the access token expired gets 401 and succeeds after one refresh; each viewer route that is implemented answers its public view for `?address=` with no header |
| `fees` | WP-10 | Max-send XLM to a fresh address with XLMReserve math succeeds; a swap is then refused before signing with `not_enough_xlm_for_fee`; the faucet restores |
| `starter` | WP-10 | only with `--activation sponsored`: sponsored activation; a USDC → XLM starter is sponsored once (`tx_log.fee_payer = sponsor`, sponsorship `success`); the second is user-paid; a third starter is refused |
| `send`, `swap` | WP-10 | memo bound; `result.amountOut` set |
| `earn` | WP-15 | first deposit within the 3 XLM cap; `earned ≥ 0`; history fills |
| `launch` | WP-14 | metadata; holders 1 → 2; `marketCapUsd` set; claim recorded; graduated `pool_swaps` row after a Soroswap buy; `/launchpad/me`. Runs on `testnet-qa` only after O-1 (Q3). |
| `moments` | WP-16 | upload through local media; publish photo and video (poster set); collect 2 and 20 editions within the cap; `moment_editions` owned |
| `bridge`, `anchor` | WP-17 | Iris fee; ETA null or measured; anchor tracked |
| `markets`, `prices` | WP-13 | XLM and USDC have a non-null `priceUsd`, or null with `stale` when Kraken is unreachable (never 1) |
| `holdings`, `portfolio`, `activity` | WP-18 | totals complete; change present; period `day`: launch volume > 0, spot trades ≥ 1, `networkFeesXlm > 0` |

**Which deployment e2e runs on.**
- **Before O-1:** the current deployment, which the redeploy retires along with its feed.
- **After O-1:** create, graduate and publish run only on `testnet-qa` (Q3). Without it, those phases are skipped and
  the lead QA's them by hand with owner-approved content.

### 12.7 Simulator QA (lead; the step-by-step script is Appendix A)

- **Matrix.** iPhone SE and Pro Max; light and dark; AX5; en, es, fr, zh-Hans and ko; a VoiceOver walk of Home →
  token page → Swap review → Earn deposit → Portfolio.
- **Testnet journey with user-paid fees:** swap, enable, Earn deposit and withdraw, send with memo, bridge, anchor,
  launch buy and sell, collect. Each review's fee row is checked against `fee_charged` and `fee_account` on Horizon.
- **Separation check.** Monad's Recent Activity count and Portfolio Total Volume are unchanged by Stellar actions; a
  Stellar notification tapped from Monad switches to Stellar; a Moment link opened from Stellar switches to Monad.
- **Lifecycle.** Cold launch on Stellar (no prompt); sign-out erases the Stellar snapshots; Monad screens are
  identical to build 23.
- **No access gate (decision 6).** No prompt and no locked state to open or browse Stellar after a relaunch, after
  12+ hours (locally, `--short-sessions` expires the tokens in minutes instead), or after the background. A seed
  account's transactions prompt only with App Lock on (once per Confirm); a passkey account's only for its passkey.
  Appendix A F04 and F04b.

---

## 13. Milestones and work packages

### 13.1 Milestones

| M | Contents | Exit |
|---|---|---|
| 0 | WP-00 build-23 checks; WP-01 agent tooling; WP-02 backend scaffold and network policy; WP-03 API contract and renames; then WP-03b and WP-02b, the decision-6 follow-ups (sessions without gating: refresh tokens, viewer routes, silent SEP-53 sign-in in StellarKit) | Every check green on the merged heads; the contract reviewed by the lead |
| 1 | WP-11 verifiers; WP-13 markets; WP-04 deploy/pin/local stack; WP-10 hybrid fees server; WP-14 launch, WP-15 earn, WP-16 moments+media, WP-17 bridge+cash backends; WP-12 DyorLite; WP-18 holdings/portfolio/activity; WP-20 app foundations; WP-21 shell and routing; WP-22 setup sheet | **I1**: user-paid fees end to end on testnet; tab order and menu right; seams host the old screens |
| 2 | WP-30…WP-41 screens | **I2**: no `SEAM(`; full agent QA en-light plus es-dark |
| 3 | WP-50 DyorLite slimming; WP-51 docs; WP-52 strings | **I3**: full QA matrix; lead QA on the owner's panel; then O-2, hosted QA, O-3 |
| 4 | WP-60 Stellar price alerts; WP-61/62 Transfer shortfall swap; WP-63 wallet-wide Stellar history | Parity extras |

### 13.2 Ownership map (disjoint per wave)

Ownership passes in dependency order; a later package never edits a file that a running package owns. Files marked
"seam" are created by WP-21 and pass to the named M2 package (§13.3). Strings: each package owns only its own
`Stellar<Area>.xcstrings`. Internal tests: each package owns only `ios/Internal/Tests/<Area>Tests.swift`. Backend:
each package owns its own route module, jobs, migration, unit and SQL tests, and e2e phase files. The full map, with
dependencies, is Appendix B.

### 13.3 Seams (created by WP-21; each passes to its M2 package)

Each seam has its final type name and init. Until its port lands, it delegates to the public legacy DyorLite screen,
or for a screen with no legacy counterpart shows the closest legacy screen. It carries `// SEAM(WP-xx)`. All of them
are gone at I2.

| File (`S:app/ios/DyorHQ/Lite/…`) | Type and init | Port |
|---|---|---|
| `Home/StellarHomeView.swift` | `StellarHomeView()` | WP-31 |
| `Home/StellarTokenDetailView.swift` | `StellarTokenDetailView(asset: String)` | WP-30 |
| `Home/StellarSearchSheet.swift` | `StellarSearchSheet(purpose: StellarSearchPurpose, onPick: @escaping (String) -> Void)` + `enum StellarSearchPurpose { case browse, pay, receive }` | WP-30 |
| `Wallet/StellarReceiveSheet.swift` | `StellarReceiveSheet()` | WP-32 |
| `Wallet/StellarSendSheet.swift` | `StellarSendSheet(asset: String? = nil)` | WP-32 |
| `Wallet/StellarTransferSheet.swift` | `StellarTransferSheet(direction: StellarTransferDirection, market: String?)` + `enum StellarTransferDirection { case toEarn, toSpot }` | WP-32 |
| `Bridge/StellarBridgeView.swift` | `StellarBridgeView(direction: StellarBridgeDirection = .toStellar)` + `enum StellarBridgeDirection { case toStellar, toMonad }` | WP-33 |
| `Trade/StellarSwapView.swift` | `StellarSwapView()` | WP-34 |
| `Trade/StellarEarnView.swift` | `StellarEarnView()` | WP-35 |
| `Launch/StellarLaunchDetailView.swift` | `StellarLaunchDetailView(token: String)` | WP-36 |
| `Launch/StellarLaunchpadView.swift` | `StellarLaunchpadView()` | WP-37 |
| `Moments/StellarMomentDetailView.swift` | `StellarMomentDetailView(id: Int)` | WP-38 |
| `Moments/StellarMomentsView.swift` | `StellarMomentsView()` | WP-39 |
| `Portfolio/StellarPortfolioView.swift` | `StellarPortfolioView()` | WP-40 |
| `Profile/StellarAccountView.swift` | `StellarAccountView()` | WP-41 |
| `Profile/StellarRecentActivityView.swift` | `StellarRecentActivityView()` | WP-41 |

Every view reads the session from `@Environment(\.stellarSession)` and the router from `@Environment(Router.self)`.
The seams make M2's packages independent: none of them references a type another M2 package creates.

### 13.4 Worktrees, locks and commits

- **One worktree per package, in the private repository** (owner decision 2026-10-14: the app code lives in
  `S:app/`). `scripts/agent/worktree.sh WP-xx` (WP-01) creates `~/Hackathon-b17/wt/WP-xx/multichain-stellar`
  (branch `stellar/WP-xx` from `main`); the package's A is that worktree's `app/` (`$A = $S/app`). App and package
  changes of one package therefore land on one branch. It also:
  - copies `ios/project.local.yml` into `app/ios/`;
  - excludes `/.secrets` in S;
  - symlinks S's `.secrets` to the main checkout's, so `local-stack.sh` can read it.

  Nobody prints `.secrets`. M0 packages begun before this decision (WP-00 to WP-03, each with an IOS-app worktree
  beside it) finish where they are; the lead carries WP-00's app-side files into `S:app/` when integrating, and
  `worktree.sh` and `verify-app.sh` take `$A = $S/app` from M1 on.
- **Locks.** `scripts/agent/lock.sh acquire|release <sim|stack|xcode|cargo> WP-xx` (one `xcode` holder for every xcodebuild and simulator run, two `cargo` slots) (mkdir locks under `~/Hackathon-b17/wt/.locks`)
  guards the agent simulator (every `xcodebuild test` and simulator run) and the default local stack (ports 8000,
  8001, 54329). Package stacks use `PORT_BASE` and `--no-loop`. The owner's simulator is the lead's only.
- **Commits** go on `stellar/WP-xx` only, as "Stellar parity WP-xx: …", ending with the Co-Authored-By line. Hooks
  stay on; never `--no-verify`. Each package's hand-off report is at most 15 lines: files, commands and results, open
  issues, screenshot paths.
- **Not allowed:** push, deploy, Supabase writes and mainnet actions. Testnet on-chain actions are allowed only in
  e2e and QA runs on a package's private stack.
- **Commit messages and public files** never describe vulnerabilities, incidents or internal findings (CLAUDE.md).
  `S:app/` is a copy of a public repository's tree, so it gets the same care: nothing written there should need to be
  hidden if it is ever upstreamed.

### 13.5 Integration (lead)

- **I1** (after M1):
  1. Merge into S `main`: WP-01, 02, 03, 03b, 02b, 11, 13, 04, 10, 14, 15, 16, 17, 18, 12.
  2. Merge the app packages into S `main` too (their files are under `app/`): WP-00, 20, 21, 22.
  3. Run every verification block.
  4. Run the local stack and the full e2e (with `--activation sponsored` for `starter`).
  5. Regenerate the real verifier vectors.
  6. Simulator smoke: switch, setup (user-paid Enable USDC; check `fee_account`), tab order, menu routing, the seams'
     old screens, a swap showing "Up to X XLM".
  7. If O-1 is done: run `gen-pinned --deployment testnet`, commit the pins and `testnet.json`, restart, and confirm no
     smoke item is served.
  8. Run the full `scripts/agent/verify-app.sh $S lead` on the merged head (the patch is gone: the app copy is in S).
- **I2** (after M2): merge in package order; `SEAM(` grep empty; every block; agent QA (§12.7) en-light plus es-dark
  screens. Fixes go back to the owning package as `WP-xx-fix`.
- **I3** (after M3): merge; every block and the full matrix; patch regenerated; lead QA on the owner's panel
  (`BB64623A-…`); then O-2, hosted QA, O-3.

### 13.6 Owner actions

| Id | Action |
|---|---|
| O-1 | **Redeploy the live testnet contracts** after WP-04 merges: own `DEPLOYER_SECRET` (admin) and `TREASURY_PUBLIC` (a G-address with a USDC trustline), an economics file (Q4), `deploy-contracts.ts --deployment testnet` without `SMOKE`. The lead then commits the regenerated `testnet.json` and pins (no secret in either). |
| O-2 | **Supabase production deploy** (project fmnjqrguvopusfufmirs). Agents may prepare; the owner approves each write in the Claude UI: migrations (§6.15 order), the `lite_api` role, the `lite-media` bucket and its write-once trigger, function secrets (`SPONSOR_SECRET`, **`KEEPER_SECRET`**, `LITE_JWT_SECRET`, `LITE_CRON_SECRET`, `LITE_NETWORK=testnet`, `LITE_DEPLOYMENT=testnet`, `LITE_MIN_BUILD`), the `lite` and `lite-indexer` functions, the cron last, then `app_config` flags and tester invites. |
| O-3 | **Push** S `main` (private), which carries the app copy `app/`. Nothing goes to the public DyorHQ/IOS-app (owner decision 2026-10-14). |
| O-4 | **Internal TestFlight:** archive `DyorHQInternal.xcodeproj` with the owner's Xcode account. |
| O-5 | **Funding:** testnet sponsor and keeper top-ups via Friendbot. Mainnet funding, RPC provider, audit, anchors and Privy Stellar wallets belong to the mainnet program. |

---

## 14. Owner questions (only those that block)

- **Q1: price source.** Top Tokens, token pages and every dollar figure need XLM and USDC reference prices. The build
  defaults to **Kraken's public market data**: no key, checked live 2026-10-14, but its terms for showing prices in a
  commercial app aren't reviewed. The alternatives:
  - CoinGecko's Demo plan: you create a key we keep on the server, the app shows "Price data: CoinGecko", and it
    allows 10,000 calls a month;
  - StellarExpert: no key, terms not published.

  Confirm or choose **before the hosted deploy (O-2)**. Development does not wait.
- **Q2: public code. Answered 2026-10-14:** the app code lives in the private repository's app copy (`S:app/`), and
  nothing from this program is pushed to the public DyorHQ/IOS-app.
- **Q3: QA deployment.** May agents deploy a separate testnet contract set, `testnet-qa`, with throwaway admin and
  treasury keys and small economics? It is used only for e2e and simulator tests of create, graduate and publish
  after your redeploy, and keeps test launches and Moments out of the live feed. Without it, those flows are tested
  only by the lead, on the live deployment, with content you approve.
- **Q4: redeploy inputs (O-1).** These decide what users see; the code reads them from the contracts.
  - Launch economics: match Monad in dollars (about $2,000 at launch and $20,000 to graduate) or stay small
    (2,000 XLM phantom, about 4,325 XLM threshold)?
  - The Moments minimum price.
  - Stellar Moments priced in USDC only, like Monad, or also XLM?

  The treasury needs a USDC trustline either way.
- **Q5: contract-driven differences.** You asked that the network be the only difference. These come from the
  contracts, not the network:
  - Launchpad: no launch fee, Soroswap is the only graduation venue, no holder fee sharing, no refund mode.
  - Moments: editions with no coin, graduation or vesting (lead default b).

  This program ships them as they are, and the screens show only what the contracts do. Do you accept that for now,
  or should a contract change and an audit be scheduled?
- **Q6: the invite code on testnet: decided.** The lead read "no need for gating it since it's on Testnet" as
  including the invite: testnet has no invite (`inviteRequired` false, WP-02b); mainnet keeps it. The owner can
  reverse it with a server setting (`LITE_INVITE_REQUIRED`), no app release.

Decided without asking (reasons in §2):
- Kraken as the default provider;
- no share links or Learn more on Stellar until those routes exist;
- mainnet sponsorship caps (§6.14 defaults) confirmed in the mainnet program;
- Privy Stellar wallets are the next program.

---

## 15. Risks

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| RK1 | An unflagged edit reaches a build-23 file, or DyorKit changes | M | H | check-build23 with `--app` in every A package and every integration | lead |
| RK2 | DyorKit lints fail on Lite files (pasteboard, coin value, titles, helpers, keys) | H | M | §3.10 rules; full DyorKit suite in every A package | all A |
| RK3 | The rename of public StellarKit types breaks the LiteHarness, the patch file or older branches | M | L | one commit in WP-03; patch regenerated at I1 | WP-03 |
| RK4 | Parallel packages edit the same file | M | M | ownership map, module split, per-area tables, seams; a conflict goes back to the package | lead |
| RK5 | One agent simulator; fixed ports | H | M | locks; `PORT_BASE`; `--no-loop` | WP-01, WP-04 |
| RK6 | The owner's redeploy changes contract ids | H | M | gen-pinned, the indexer's reset on key change, the saved-figure directory keyed by deployment | lead |
| RK7 | QA puts test items in the live feed | M | M | before O-1 they vanish with the old deployment; after it, `testnet-qa` (Q3) | lead |
| RK8 | A gap in the verifier lets a bad server overcharge or redirect users who now pay | M | H | fee caps, destination/memo/argument binding, PlanRunner's per-step check, shared vectors, pinned RPC | WP-11 |
| RK9 | Starter-swap or activation farming (mainnet) | M | M | once per address, attempts, daily, fee and IP caps, invite gate | WP-10 |
| RK10 | Price source down or rate-limited | M | M | indexer-side cache, stale flag, null, XLM fallback | WP-13 |
| RK11 | Testnet resets wipe accounts and contracts | M | M | reset tied to the deployment key; runbook redeploy; setup re-runs | WP-02, WP-04 |
| RK12 | RPC's 7-day event retention leaves holders or editions incomplete | M | M | per-group cursors, reconcile, `holdersComplete`, an archive endpoint later | WP-14 |
| RK13 | The Stellar UI becomes public code | L | M | Answered (Q2): the app code lives in `S:app/`, private; nothing secret or internal in A in case it is ever upstreamed | owner |
| RK14 | Privy users (most users) can't use Stellar | H | H | the next program; the sheet explains it truthfully | owner |
| RK15 | Translation volume across 17 tables × 4 languages | M | M | each package translates its own table; WP-52 audit | all |
| RK16 | Blend's testnet pool lends its own test USDC | H | L | truthful labels, swap route check, nothing hidden | WP-35 |
| RK17 | The Monad-testnet bridge needs testnet MON and USDC | H | L | truthful refusal copy; QA marks F09 conditional | WP-33 |
| RK18 | Uploads don't work locally | H | M | local media stand-in (testnet only) | WP-04, WP-16 |
| RK19 | Keeper or sponsor runs dry; TTL lapses | M | M | `KEEPER_SECRET` split, ops balance warning, runbook top-up | WP-10, owner |
| RK20 | The committed tagline trips the strip check | L | L | listed in `unflagged-changes.txt` from WP-00 | WP-00 |
| RK21 | LiteHarness and the internal project aren't built by any CI | M | M | the harness kept as a data harness (private CI); `verify-app.sh` locally | WP-50 |
| RK22 | Stellar actions leak into Monad's activity, history or volume | L | H | never `Activity.record`; QA F12 | WP-21 |
| RK23 | Lower resource margin causes on-chain resource failures | M | M | instruction and byte headroom kept; e2e on Blend and launch | WP-10 |
| RK24 | Users run out of XLM on testnet once they pay fees | M | M | the add-funds card, errors and faucet ship in M1/M2 with the fee change | WP-10, WP-31 |
| RK25 | Soroban contracts are unaudited | H | H | testnet only; audit before mainnet money | owner |
| RK26 | Notifications mirror to the Monad account's backend row; an App Store build restores Stellar rows | M | L | route `.home` and the body names the network | WP-21 |
| RK27 | Copies drift from later Monad changes (build 24+) | M | M | `check-copies.py` on every rebase | lead |
| RK28 | Soroswap pair assumptions (`token_0` read once; sync before swap) | L | M | read at graduation; unit fixtures; reconcile | WP-14 |
| RK29 | With no access gate, someone holding an unlocked phone can see the Stellar section (decision 6, as on Monad) | M | L | testnet only; App Lock still gates every signature, and is on by default for new installs with a passcode (Theme.swift:55-68); key export always asks | owner |
| RK30 | A stolen refresh token keeps a session alive | L | M | hashed at rest; this-device-only Keychain; single use with family revoke on reuse; 30-day expiry; revoked at sign-out and erase; a session can read history and build plans but never sign | WP-02b, WP-03b |
| RK31 | Silent sign-in is talked into signing something else | L | H | SEP-53 domain separation, the exact five-line shape check, the phone's own check of the signature (§5.8); no raw-sign API on the provider | WP-03b, WP-20 |
| RK32 | Public viewer reads are used to fan out RPC or scrape | M | L | indexed values only (no live RPC) in the public view; 120 a minute per IP; 15 s cache per address; only on-chain facts are served | WP-02b, WP-10, WP-18 |

---

## Appendix A. Simulator QA script (lead, at I1/I2/I3)

**Setup.**
- Agent device `$SIM` (`3672E24D-0458-4181-B351-94A3D1FCDB01`). Hold both locks. Screenshots go to `$QA` (the
  scratchpad's `qa/<date>`).
- QA wallets (QA-A main, QA-B starter rehearsal, QA-C drained, plus a Monad account with history) are generated by
  script into `.secrets/qa-wallets.env` (mode 600) and typed into the simulator's Import screen. They are never
  printed or pasted into chat. QA-P is a Mera passkey account, on the simulator's passkey stub (Debug) where it covers
  the phrase ceremony, otherwise on the owner's device at I3.

Screen ids used below: S01 Home, S02 Home after the session expired (no lock), S03 paused Home, S04 add-funds card, S05 search, S06 token pages, S07 Deposit, S08 Withdraw, S09 Transfer, S10 Bridge, S11 cash, S12 Launch board, S13 curve launch page, S14 graduated launch page, S15 Create, S16 My Launchpad, S17 Earn mode, S18 Select Market and ticket, S19 Swap mode, S20 Moments board, S21 Moment page and Freighter sheet, S22 Publish, S23 My Moments, S24 user-paid review, S25 sponsored review, S26 progress and Done, S27 side menu, S28 Portfolio, S29 Profile, S30 Stellar account, S31 Recent Activity, S32 Profile Receive, S33 Profile Send, S34 notification center, S35 network sheet, S36 resting tabs.

1. **Backend.** `backend/scripts/local-stack.sh start --short-sessions` (testnet; access tokens last 120 s and
   refresh tokens 600 s, standing in for "12+ hours"; add `--activation sponsored` only for F05), then
   (testnet needs no invite; for the mainnet-style run with `LITE_INVITE_REQUIRED=1`, `backend/scripts/local-stack.sh invite qa` writes the code to `.secrets/local-invites.txt`, never printed).
2. **App.**
   1. `cd $A/ios && python3 -I Internal/generate.py --spec project.local.yml --lite $S/ios/Packages` (`$A = $S/app`).
   2. Build Debug for `$SIM`, then `xcrun simctl install` and `launch fun.dyorhq.app`.
   3. Enrol Face ID with `notifyutil` (INTEGRATION-ios §7), and match it when prompted. Count every prompt from here
      on: decision 6 allows one only where a step below says so.
3. **F01 First switch** (QA-A, App Lock on). Chip → Stellar → Confirm, which shows "You pay Stellar's network fees in
   XLM…". Then setup: Sign in (no prompt), Set up, Friendbot, Enable USDC (no invite step on testnet; with `LITE_INVITE_REQUIRED=1` the invite step appears after Sign in). The Enable row shows "Holds 0.5 XLM
   · network fee up to … XLM" before the tap. Exactly one Face ID prompt, at Enable USDC (App Lock); no "Unlock your
   Stellar key" row anywhere.
   - Horizon `fee_account` of the trust tx is the user.
   - You land on Stellar Home.
   - QA-P (passkey): Set up first (no invite field on testnet), then exactly one passkey prompt for sign-in and Enable USDC
     together, and no Face ID App Lock prompt.
4. **F02 Tabs and menu.**
   - The tab bar reads Home · Launch · Earn · Moments.
   - Menu rows: Home, Spot, Earn, Launch, Moments, News, Portfolio, Get Help.
   - Spot opens Earn in Swap mode; Earn opens Earn mode; Portfolio opens the Stellar Portfolio.
   - The Monad menu is unchanged after switching back.
5. **F03 Home** (S01).
   - Balance card: total, 24h change, Total Volume and period chip, Avail. Balance = the Spot split, In Use = Earn,
     the split, the testnet caption.
   - Four tiles; allocation; Top Tokens in all four tabs (no BUSDC, no CHECK); My Holdings in all four segments.
   - Every figure traces to a source: balances to Horizon for QA-A's G-address, launch and portfolio figures to the
     local database (`lite.*` tables), prices to `lite.ref_quotes`.
6. **F04 No lock, and paused** (decision 6; QA-A, then QA-P). Each case shows no prompt and no locked card, and Home's
   figures, Top Tokens, the boards and Earn fill:
   - **Relaunch:** kill and relaunch on Stellar.
   - **Expiry:** wait 3 minutes (past the 120 s access token; on the hosted stack, 12+ hours) and pull to refresh, then
     open every tab (S02). The API log shows one `auth/refresh` and no `auth/challenge`.
   - **Background:** background the app for 3 minutes, mid-review included; on return the review still confirms with
     no extra prompt.
   - **Refresh gone, seed account:** revoke QA-A's family on the local database
     (`update lite.auth_refresh set revoked_at = now() where address = '<QA-A G…>'`) and expire the session: the next
     read signs in silently (`auth/challenge` then `auth/verify` in the log), still with no prompt.
   - **Refresh gone, passkey account (QA-P):** the same revoke. Figures still fill (public view). Portfolio, Recent
     Activity, My Launchpad and My Moments show `StellarSignInRow`, with no prompt until "Sign in with your passkey" is
     tapped (one passkey prompt, then the history shows).
   - **Paused (S03):** `lite.app_config` maintenance, on the local database only, and the paused card shows Switch to
     Monad. Resting tabs (S36) show only loading or paused.
7. **F04b App Lock and signing** (decision 6; Profile › Security):
   - QA-A with App Lock **on**: a 2-step plan (Enable EURC + swap) asks for Face ID **once**, at Confirm. Cancel at
     the prompt: nothing is sent and the review stays.
   - QA-A with App Lock **off**: the same plan signs with no prompt.
   - QA-P: no App Lock prompt whatever the setting; one passkey prompt per signed step ("%lld steps · each asks for
     your passkey" shows on the review).
   - "Show Stellar secret key" asks for Face ID or the passcode even with App Lock off.
8. **F05 Starter swap** (local `--activation sponsored` only), with QA-B:
   1. A sponsored activation gives 0 XLM and USDC enabled.
   2. QA-A sends 5 USDC.
   3. The add-funds card shows "Swap … USDC for XLM", and the review says "Paid by DyorHQ".
   4. Horizon `fee_account` is the sponsor.
   5. A second USDC → XLM swap is user-paid, or blocked by "Not enough XLM".
9. **F06 Max and fees** (QA-A, XLM → USDC Max):
   - the amount equals spendable − the swap estimate × 5/4;
   - the review shows "Max network fee · Up to X XLM";
   - after Confirm, `fee_account` is the user and the minimum balance is intact;
   - the Stellar notification is in the bell, and tapping it lands on Stellar Swap.
10. **F07 Not enough XLM** (QA-C, after sending Max XLM away):
    - Earn Deposit's review shows "Not enough XLM for the network fee." with Add XLM;
    - the add-funds card shows on Home;
    - Deposit's "Get … test XLM" restores the balance.
11. **F08 Token pages and search** (S05, S06): XLM, USDC, a curve launch and a graduated launch. Check the source line,
    chart, Locked/Available for XLM and the StellarExpert link. A pasted C… id shows Unverified.
12. **F09 Swap mode** (S19): quotes per venue, best marked, 15 s refresh, slippage sheet, Swap History ranges.
13. **F10 Earn** (S17, S18):
    - market header with pool status; Select Market; ticket Max; Deposit and Withdraw;
    - Position, Assets and History tabs; the APY chart fills;
    - Home's Transfer sheet in both directions;
    - the BUSDC footer, plus "Swap for Blend test USDC" only when a route exists.
14. **F11 Wallet** (S07, S08, S11): Deposit (QR, Copy writes the address, Add cash, faucet on testnet only). Send with
    a memo; the review "To" is the typed address. Send to a missing account accepts XLM ≥ 1 only. An M… address is
    refused. Cash: testanchor deposit and cash-out, and the tracker posts once.
15. **F12 Bridge** (S10): a real Iris fee; ETA present or omitted.
    - With testnet MON and USDC on the QA Monad wallet: Monad → Stellar, where the review shows the decoded approve
      and burn and "Up to … MON"; then Stellar → Monad with Claim.
    - Otherwise: a quote and a truthful refusal.
16. **F13 Launch** (S12–S16).
    - **On the live deployment (read-only plus trades):** board sections, chips, search; launch page stats and
      holders; buy and sell at 1% with the shortfall copy; My Launchpad.
    - **On `testnet-qa` (Q3) or before O-1:** create with an image, description and links plus a developer buy; fill
      the curve; graduate by hand; claim fees; Claim All.
17. **F14 Moments** (S20–S23), on `testnet-qa` or before O-1:
    - publish a photo, and a video whose poster shows on the card;
    - collect 2 on a capped Moment until sold out (the ticket hides);
    - the terms-changed guard (admin `set_policy` on `testnet-qa` only);
    - My Moments;
    - View in Freighter: Copy copies the contract; the token ID is selectable text; the values match `owner_of` on
      chain.
18. **F15 Review sheets** (S24–S26): user-paid, enable, restore (if any), the sponsored starter, progress, View links;
    Done and Close after a sent failure.
19. **F16 Portfolio** (S28): every period; the five section cards; network fees; the coverage note.
20. **F17 Profile** (S29–S33):
    - Wallet with Recent Activity (fee and payer per row);
    - Network with RPC = the pinned host;
    - the account page (minimum balance, no faucet, no "Reserves paid by DyorHQ");
    - sign out of Stellar: no prompt; the API log shows `auth/signout`; the next launch starts on Monad and the
      Stellar snapshots are gone; the next switch shows only the Sign in step (silent for QA-A, one passkey prompt
      for QA-P).
21. **F18 Separation.** On Monad, note Recent Activity's count and Portfolio's All volume. Run F06 on Stellar. Back on
    Monad, both are unchanged, and the bell's Monad items open Monad screens.
22. **F19 Cold launch and links.** A cold launch on Stellar shows no prompt and no locked state, also after the
    session expired (F04). A Moment link opened from Stellar switches to Monad. A Stellar notification tapped while on
    Monad switches to Stellar, with no prompt.
23. **F20 Languages and appearance.**
    - Repeat S01–S36 in es, light and dark.
    - Spot-check fr, zh-Hans and ko at AX3 for wraps.
    - S01 and S24 at AX5.
    - VoiceOver walk: Home → token page → Swap review → Earn deposit → Portfolio.
    - Monad and Stellar names are never translated.
24. **F21 Evidence.** For every on-chain step, save `curl -s https://horizon-testnet.stellar.org/transactions/<hash> |
    jq '.fee_account,.fee_charged'` into `$QA`, next to the screenshot of its review's fee row.
25. **Hosted QA (after O-2).** Release internal build against the hosted API on the owner's panel: F01, F03, F04 (with
    the real 1-hour token, and a reopen after 12+ hours), F04b, F06, F11, F17, F18.

## Appendix B. Work packages (summary; full briefs are returned with this document)

Repo A means `S:app/` (owner decision 2026-10-14); every package works in one S worktree (§13.4).

| Id | Repo | M | Depends on | Owns (exclusively, while running) |
|---|---|---|---|---|
| WP-00 | A | 0 | — | `ios/Internal/{check-build23.py, check-lite-strings.py, check-copies.py, unflagged-changes.txt, README.md}` |
| WP-01 | S | 0 | — | `scripts/agent/*`, `backend/scripts/schema-test.sh` |
| WP-02 | S | 0 | — | `lite/index.ts`, `lite/routes/*` (creates all), `_shared/{env,networks,http,db}.ts`, `_shared/deployments/index.ts`, launchpad.ts transitional exports and `stellar.ts keeper()` (one-time), `lite-indexer/index.ts`, `jobs/*` + `handlers/*` (creates all), `tests/unit/{router,env,auth_http,bridge}.test.ts` (split), `tests/sql/lite_schema_test.sql`, `tests/e2e/lite_e2e.ts` + `phases/*` (creates all), `.github/workflows/backend.yml` |
| WP-03 | S | 0 | — | `docs/API-lite.md`, `_shared/contract.ts`, `backend/tests/fixtures/**`, StellarKit `LiteClient/{Models,LiteAPI,Anchors}.swift` + new `Models+*.swift`, `StellarCore/Amount.swift`, rename-only edits elsewhere in StellarKit and DyorLite and LiteHarness, StellarKit and DyorLite tests |
| WP-03b | S | 0 | WP-03 | decision 6 in the contract and StellarKit: `docs/API-lite.md`, `_shared/contract.ts`, `backend/tests/fixtures/api/**` (auth and public-view fixtures), `backend/tests/fixtures/fixtures.test.ts`, StellarKit `LiteClient/{LiteAPI, Models, Models+Wallet, Models+Moments}.swift`, `StellarKit/StellarKeychain.swift`, `Tests/LiteClientTests/**` |
| WP-02b | S | 0 | WP-02, WP-03b | decision 6 on the server: `_shared/auth.ts`, `lite/routes/auth.ts`, `lite/index.ts` (guard), `_shared/env.ts` (session TTL overrides), migration 12, `tests/unit/{auth_http, router, env, session}.test.ts`, `tests/sql/auth_refresh_test.sql`, `tests/e2e/lite_e2e.ts` (phase list) + `phases/session.ts` |
| WP-11 | S | 1 | WP-02, WP-03 | `StellarCore/{Verify/TxVerifier, XDR/Types, XDR/XDRReader, Network/Network, Network/PinnedContracts+Testnet}.swift`, new `Fees/XLMReserve.swift`, `LiteClient/{PlanRunner, PlanFees}.swift`, `StellarCoreTests/**`, new LiteClient tests, `_shared/verify.ts`, `tests/vectors/gen-vectors.ts`, `tests/unit/verify.test.ts`, `backend/scripts/gen-pinned.ts` |
| WP-13 | S | 1 | WP-02, WP-03 | `_shared/{prices, refprices, markets, directory}.ts`, `routes/markets.ts`, `jobs/{refprices,purge}.ts`, migration 06, its tests and phases |
| WP-04 | S | 1 | WP-02, WP-02b, WP-11 | `backend/scripts/{deploy-contracts, gen-pinned, new-testnet-secrets}.ts`, `local-stack.sh`, `scripts/local/*`, `_shared/deployments/*`, generated pins, `docs/RUNBOOK-testnet.md` |
| WP-10 | S | 1 | WP-02, WP-02b, WP-03, WP-03b, WP-11 | `_shared/{plans, stellar, account, swap, ttl, fees, sponsor, assets}.ts`, `routes/{fees,account,plans,swap}.ts`, `jobs/{settle,graduate,ttl,ops}.ts`, migration 05, `lite_schema_test.sql`, its tests and phases |
| WP-14 | S | 1 | WP-02, WP-02b, WP-03, WP-03b, WP-11, WP-13 | `_shared/{launchpad, symbols, launch_metadata, economics}.ts`, `routes/launches.ts`, `handlers/launchpad.ts`, `jobs/{watch,reconcile}.ts`, migration 07, its tests and phases |
| WP-15 | S | 1 | WP-02, WP-02b, WP-03, WP-03b, WP-11, WP-13 | `_shared/earn.ts`, `routes/earn.ts`, `jobs/earn.ts`, migration 08, its tests and phases |
| WP-16 | S | 1 | WP-02, WP-02b, WP-03, WP-03b, WP-11, WP-13 | `_shared/{moments, media, localmedia}.ts`, `routes/moments.ts`, `handlers/moments.ts`, migration 09, its tests and phases |
| WP-17 | S | 1 | WP-02, WP-03, WP-11 | `_shared/bridge.ts`, `routes/{bridge,cash}.ts`, `jobs/bridges.ts`, migration 11, `tests/unit/bridge.test.ts`, its tests and phases |
| WP-12 | S | 1 | WP-03, WP-03b, WP-11 | `ios/Packages/DyorLite/**` (data layer + public legacy screens), DyorLite tests, `ios/LiteHarness/**` |
| WP-18 | S | 1 | WP-02b, WP-10, WP-13, WP-14, WP-15, WP-16, WP-17 | `_shared/{holdings, portfolio, stats, activity}.ts`, `routes/{holdings,portfolio,activity,assets}.ts`, migration 10, its tests and phases |
| WP-20 | A | 1 | WP-00, WP-12 | `ios/Internal/{generate.py, Info.plist}`, `ios/Internal/Tests/StellarFoundationsTests.swift`, `Lite/{LiteText, LiteMode, DyorHQLiteKeys}.swift`, `Lite/Core/{StellarActions, StellarSaved, StellarImages, StellarFormat, StellarAccountID}.swift`, `Lite/Design/*` (StellarSignInRow included), `Lite/Wallet/StellarConfirmationSheet.swift`, `Resources/{StellarCommon,StellarReview}.xcstrings` |
| WP-21 | A | 1 | WP-20 | `Lite/{AppNetwork, NetworkRoot, AppCovers}.swift`, `Lite/Core/{StellarRootView, StellarRouting, StellarActivityRecorder}.swift`, `Lite/Trade/StellarTradeView.swift`, the seam files (§13.3), the STELLAR_LITE blocks of `App/Router.swift` and `Menu/SideMenuView.swift`, `Resources/StellarShell.xcstrings`, `Tests/StellarRoutingTests.swift` |
| WP-22 | A | 1 | WP-20 | `Lite/NetworkSheet.swift`, `Resources/StellarSetup.xcstrings`, `Tests/StellarSetupTests.swift` |
| WP-30 | A | 2 | WP-21 | seams `Home/StellarTokenDetailView`, `Home/StellarSearchSheet`; `StellarToken.xcstrings`; `Tests/StellarTokenTests.swift` |
| WP-31 | A | 2 | WP-21 | seam `Home/StellarHomeView`; `Home/{StellarHomeModel, StellarHomeRows, StellarAddFundsCard}.swift`; `StellarHome.xcstrings`; `Tests/StellarHomeTests.swift` |
| WP-32 | A | 2 | WP-21 | seams `Wallet/{StellarReceiveSheet, StellarSendSheet, StellarTransferSheet}`; `Wallet/{StellarCashSheet, StellarCashTracker}.swift` (no locked sheet); `StellarWallet.xcstrings`; `Tests/StellarWalletTests.swift` |
| WP-33 | A | 2 | WP-21 | seam `Bridge/StellarBridgeView`; `Bridge/{StellarBridgeInReview, StellarBridgeTracker, StellarBridgePins, StellarEvmStepCheck}.swift`; `Lite/MonadBridgeAdapter.swift`; `StellarBridge.xcstrings`; `Tests/StellarBridgeTests.swift` |
| WP-34 | A | 2 | WP-21 | seam `Trade/StellarSwapView`; `Trade/{StellarSwapModel, StellarSwapHistory}.swift`; `StellarSwap.xcstrings`; `Tests/StellarSwapTests.swift` |
| WP-35 | A | 2 | WP-21 | seam `Trade/StellarEarnView`; `Trade/{StellarEarnModel, StellarSelectMarketSheet, StellarRateChart}.swift`; `StellarEarn.xcstrings`; `Tests/StellarEarnTests.swift` |
| WP-36 | A | 2 | WP-21 | seam `Launch/StellarLaunchDetailView`; `Launch/StellarCreateLaunchView.swift`; `StellarLaunch.xcstrings`; `Tests/StellarLaunchTests.swift` |
| WP-37 | A | 2 | WP-21 | seam `Launch/StellarLaunchpadView`; `Launch/StellarLaunchpadProfileView.swift`; `StellarLaunchBoard.xcstrings`; `Tests/StellarLaunchBoardTests.swift` |
| WP-38 | A | 2 | WP-21 | seam `Moments/StellarMomentDetailView`; `Moments/{StellarCreateMomentView, StellarFreighterSheet}.swift`; `StellarMoments.xcstrings`; `Tests/StellarMomentsTests.swift` |
| WP-39 | A | 2 | WP-21 | seam `Moments/StellarMomentsView`; `Moments/StellarMomentsPortfolioView.swift`; `StellarMomentsBoard.xcstrings`; `Tests/StellarMomentsBoardTests.swift` |
| WP-40 | A | 2 | WP-21 | seam `Portfolio/StellarPortfolioView`; `Portfolio/StellarPortfolioModel.swift`; `StellarPortfolio.xcstrings`; `Tests/StellarPortfolioTests.swift` |
| WP-41 | A | 2 | WP-21 | seams `Profile/{StellarAccountView, StellarRecentActivityView}`; the STELLAR_LITE extension of `Profile/ProfileView.swift`; `Lite/StellarProfile.swift`; `StellarProfile.xcstrings`; `Tests/StellarProfileTests.swift` |
| WP-50 | S | 3 | WP-22, WP-30…WP-41 | DyorLite deletions and trims, its catalog, `Package.swift`, tests, `ios/LiteHarness/**`, `ios/project.yml`, `ios/Config/Lite.xcconfig`, `.github/workflows/ios.yml` |
| WP-51 | S | 3 | WP-04, WP-50 | `docs/{DECISIONS, ARCHITECTURE, DESIGN-network-switch, INTEGRATION-ios, VERIFICATION, RUNBOOK-testnet}.md` |
| WP-52 | A | 3 | WP-22, WP-30…WP-41 | `ios/Internal/Resources/Lite.xcstrings` (other tables audited read-only; fixes routed back) |
| WP-60 | A | 4 | WP-30, WP-52 | new `Lite/Alerts/StellarPriceAlerts.swift`, a new STELLAR_LITE block in `Wallet/PriceAlerts.swift`, `Home/StellarTokenDetailView.swift`, `StellarAlerts.xcstrings`, `Tests/StellarAlertsTests.swift` |
| WP-61 | S | 4 | WP-15 | `_shared/earn.ts`, `routes/earn.ts`, earn tests and phase |
| WP-62 | A | 4 | WP-32, WP-61, WP-52 | `Wallet/StellarTransferSheet.swift`, `StellarWallet.xcstrings`, `Tests/StellarWalletTests.swift` |
| WP-63 | S | 4 | WP-18 | new `jobs/wallet_history.ts`, `lite-indexer/index.ts` registration, `_shared/{portfolio,stats}.ts`, migration 13, tests |
