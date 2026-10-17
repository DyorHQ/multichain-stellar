# The network switch in the DyorHQ app

Stellar reaches the DyorHQ iPhone app as a **network**, not a mode (DECISIONS #18). Home's balance card starts with a
chip, "◉ Monad ⌄". Tapping it opens a sheet that switches to Stellar, and the screens change with the network. The
design is `docs/DESIGN-network-switch.md`. This page is how it is wired into the app and how to check it.

- **Where:** `DyorHQ/IOS-app`, branch `lite/network-switch`, on top of `release/23` (`d387a64`, build 23), with
  build number 24. Not pushed yet (see §0).
- **Verified (2026-10-13, Xcode 26.6, iPhone 17 simulator, against this repo's local stack):**
  - the internal build runs Select → Confirm → Setup (unlock, invite, sign in, account setup);
  - an instant switch back to Monad, and a swap on Stellar testnet;
  - English and Spanish, light and dark;
  - sign-out cleanup;
  - the App Store target unchanged.

## 0. Before you start

- **IOS-app is public** (2026-10-13). Pushing `lite/network-switch` publishes the Stellar code paths, `generate.py`
  and the name of this private repository. Push only with the owner's go-ahead.
- **The App Store target stays build 23 apart from the build number** (DECISIONS #19):
  - every change to an existing app file sits inside `#if STELLAR_LITE`;
  - new code lives in `ios/DyorHQ/Lite/`, each file wholly inside `#if STELLAR_LITE`;
  - the shared string catalog, `RemoteFlags` and `AppEnvironment` are build 23's.
- **A compile flag can't keep the packages out of a binary.** Xcode resolves and links every package a project
  references: a Release build with the packages on the `DyorHQ` target and the flag off still held about 12,000 Lite
  symbols. So the packages are only ever referenced by a separate, generated project (§1).

## 1. The internal project

`ios/Internal/generate.py` makes `DyorHQInternal.xcodeproj` next to `DyorHQ.xcodeproj`. `project.yml` stays the one
spec. The script takes XcodeGen's resolved dump of it (`xcodegen dump --type json --no-env`) and changes only the
`DyorHQ` target and the project name:

| What | Internal project |
|---|---|
| Name | `DyorHQInternal` (the target and the app stay `DyorHQ`, bundle id unchanged) |
| Packages | `StellarKit` and `DyorLite` from `../../multichain-stellar/ios/Packages`: this repo cloned beside the app's folder (`--lite` for another path) |
| Compile flag | `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) STELLAR_LITE"` |
| `LITE_API_URL` | Debug: `http://127.0.0.1:8000/lite` (the local stack). Release: `https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/lite`. Written `https:/$()/…`, since `//` starts an xcconfig comment |
| `LiteDebugForceOn` | Debug `YES`: shows Stellar without the remote flag. Release: empty |
| Info.plist | `Internal/Info.plist` (adds `LITE_API_URL`, `LiteDebugForceOn` and `NSAllowsLocalNetworking`). The App Store `DyorHQ/Info.plist` is excluded from the sources |
| Resources | `Internal/Resources/`: `Lite.xcstrings` (§4) and `logo-XLM.png` |

It writes `project-internal.json` (git-ignored) and runs `xcodegen generate` on it. From `ios/`:

```
python3 -I Internal/generate.py                          # from project.yml
python3 -I Internal/generate.py --spec project.local.yml # a local spec, e.g. without the real Secrets.xcconfig
```

`project.local.yml` is a local file (listed in `.git/info/exclude`) that includes `project.yml` and points both
configurations at `DyorHQ/Config/Secrets.example.xcconfig`. It lets a checkout without the real secrets build.

Not set up yet: Xcode Cloud for the internal project. It would need this private repository in the build (a clone step
or a submodule) and its own workflow for the internal TestFlight group.

## 2. Files

`ios/DyorHQ/Lite/`:

| File | Job |
|---|---|
| `AppNetwork.swift` | `AppNetwork` (`.monad`, `.stellar`): name, mark, testnet, and the account's remembered network (`network.<address>`) |
| `NetworkRoot.swift` | The signed-in root: Monad's `MainTabView` or Stellar's `LiteRootView`, the push between them, the account's `LiteSession`, and the chrome DyorLite draws with (`HomeHeader`, the chip, the locked card's unlock) |
| `NetworkChip.swift` | `NetworkMark`, `TestnetBadge`, `NetworkChip`, `NetworkChipRow`, `NetworkRoute`, `SheetHeader` |
| `NetworkSheet.swift` | The sheet: Select → Confirm (first switch to Stellar only) → Setup checklist, sized to its content |
| `StellarProfile.swift` | Profile › Network › Stellar account (pushes DyorLite's account screen), and Profile › Wallet's Receive and Send on Stellar (DyorLite's deposit and withdraw sheets) |
| `DyorHQLiteKeys.swift` | The Stellar key from the account's secret: unlock (passkey reveal, or Face ID and the Keychain seed), the key provider, and `LiteKeyBootstrap` (the hooks' entry points) |
| `LiteMode.swift` | `LiteGate`: availability (remote flag, debug force-on, account kind), API URL, pinned network |
| `StellarRemoteFlag.swift` | The `stellarLite` remote flag (§3) |
| `LiteText.swift` | `liteTr()`: text from table `Lite` |
| `AppCovers.swift` | The app's full-screen covers (side menu, Portfolio, News, Get Help, Profile, notifications), lifted out of `MainTabView` so they stay above the swap between the networks |

Hooks in existing files, each inside `#if STELLAR_LITE`:

| File | Hook |
|---|---|
| `RootView.swift` | `NetworkRoot()` where build 23 shows `MainTabView()` |
| `Router.swift` | `network`, `stellarTab`, `networkSheet`, `focusesNetworkChip`, and `ensureMonad()` for links and alerts that open a Monad screen |
| `HomeView.swift` | `NetworkChipRow(network: .monad)` as the balance card's first row |
| `SideMenuView.swift` | Rows and footer follow the network |
| `ProfileView.swift` | The Network section; the Wallet section follows the network |
| `Session.swift` | `PasswordKeys` keeps the pepper. After a password log-in or sign-up, `LiteKeyBootstrap.didDeriveEmailWallet` stores the Stellar key. Sign-out and erase call `LiteKeyBootstrap.forget` (erase calls it before the `UserDefaults` wipe, which holds the Stellar address) |
| `ImportWalletView.swift` | After an import, `LiteKeyBootstrap.didImport(phrase:)` (SEP-5) or `didImport(privateKey:)` |

## 3. Remote flag (default off)

`StellarRemoteFlag.swift` reads `app_config` 'ios' → `flags.stellarLite` itself. It is on only for JSON `true` (not
`1`, not `"true"`) and is cached in `UserDefaults` (`lite.stellarLite`), so a cold launch knows it before the network
answers. DyorKit's `RemoteFlags` is untouched. Turn it on for testers with
`{"min_build": …, "flags": {"stellarLite": true}}`. App Store builds don't contain Stellar at all (§0).

## 4. Text and logo

- **Strings:** every Lite string is in `ios/Internal/Resources/Lite.xcstrings` (table `Lite`: en, es, fr, zh-Hans, ko),
  looked up with `liteTr()` or `Text("…", tableName: "Lite")`. Only the internal project ships that table. Text the app
  already has (Close, Back, Network, Receive, Send…) still comes from `Localizable`. DyorLite's own screens use the
  package's catalog.
- **Logo:** `logo-XLM.png` is Stellar's official mark (stellar.org/brand-resources, "Logo Press Kit 2026") on a black
  disc. It sits in `Internal/Resources`, not in the shared `TokenLogos`.

## 5. Keys

- **Email and password (v2):** the app derives `HKDF(S ‖ p, salt "dyorhq/email-wallet/v2", info "secp256k1")`.
  StellarKit uses the same 64 bytes and salt with info `stellar-ed25519`. Legacy (pre-v2) email wallets have no pepper,
  so they have no Stellar key. The chip says why.
- **Imported phrase:** SEP-5 from the phrase, normalised the way DyorKit reads it (lowercased, split on any
  whitespace). A capitalised or CRLF phrase otherwise gave the right Monad wallet and the wrong Stellar key.
  **Imported private key:** HKDF-SHA256 over the key (salt `dyorhq/stellar/v1`, info `ed25519-from-secp256k1`).
- **Passkey (Mera):** the first switch runs one `revealPhrase` ceremony to learn the Stellar address, which is public
  and stored. Each later signature runs a fresh ceremony.
- **One unlock per setup run:**
  - the signer lives in memory only, for that run;
  - it is dropped when the run finishes, is cancelled or fails;
  - it is also dropped after 120 s idle and when the app goes to the background (the checklist then says "Unlock
    again to continue");
  - after setup, every transaction asks on its own.
- **Sign-out and erase** remove the Stellar seed and session from the Keychain, plus `lite.stellar.<address>`,
  `lite.activated.<G…>`, `network.<address>` and the intro flag. Only the app-wide flag cache stays.

## 6. Bridge

Stellar has no Bridge for now. `NetworkRoot` gives the account's `LiteSession` no Monad wallet (`monad: nil`), so nothing
on Stellar signs on Monad, and no Stellar screen, link or notification opens a bridge. Past bridges still show in
Portfolio's Activity, as plain history. The backend's bridge routes stay in place, unused by the app. Monad's Bridge is
unchanged.

## 7. Running it locally

1. This repo: `backend/scripts/local-stack.sh start`. That gives Postgres on 127.0.0.1:54329, the API at
   `http://127.0.0.1:8000/lite`, and the indexer with its 60 s loop. `local-stack.sh invite <label>` writes a
   single-use invite to `.secrets/local-invites.txt`; it is never printed.
2. The app: `python3 -I Internal/generate.py --spec project.local.yml`, then build the `DyorHQ` scheme of
   `DyorHQInternal.xcodeproj` (Debug) for an iOS Simulator. The simulator shares the Mac's loopback, so the Debug
   `LITE_API_URL` reaches the local stack.
3. Face ID on the simulator:
   - enrol: `xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1`, then
     `… notifyutil -p com.apple.BiometricKit.enrollmentChanged`;
   - match: `… notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.

## 8. Check

- **App Store target unchanged:**
  - every changed Swift file, with its `STELLAR_LITE` branches removed (and their `#else` kept), is byte-identical to
    `d387a64`;
  - every `Lite/` file compiles to nothing without the flag;
  - `nm` on a `DyorHQ.xcodeproj` Release build shows no `DyorLite`, `StellarCore` or `LiteClient` symbols, and the
    `.app` has no `StellarKit_StellarCore.bundle`.
- **Internal build, new account:**
  - it starts on Monad;
  - the chip → Stellar → Next → Confirm → Switch to Stellar runs one Face ID prompt, the invite and the setup, then
    lands on Stellar Home with 10,000 test XLM and USDC enabled;
  - the chip → Monad switches back at once, with no prompt.
- **Cold launch on Stellar:** no prompt. Stellar Home restores silently, or shows its locked card.
- **Sign out:** the keys in §5 are gone, and the next account starts on Monad.
