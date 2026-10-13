# Wiring Lite into the DyorHQ app (after the Oct 13 submission)

The submitted Monad app is not touched. This is the patch to apply afterwards: the drop-in files from
`ios/Integration/`, a remote flag, the root switch and five key hooks, all behind the `STELLAR_LITE` compile flag.

**What is verified (2026-10-13, against `origin/main` 5bcd812, Xcode 26.6).** The four drop-in files and the hooks
below, applied to a throwaway copy of the app, build with `STELLAR_LITE` (0 errors), and the app still builds without
it in Debug and Release. The drop-in files in this repo are the fixed versions from that build. Not yet built: the
separate internal target of §1, and anything at runtime.

## 0. Before you start

- **IOS-app is public** (as of 2026-10-13). Everything added there, including the files and hooks below, a submodule
  URL and the `STELLAR_LITE` code paths, becomes public. Apply this only once that is acceptable or the repository is
  private again.
- **The compile flag alone does not keep Lite out of the App Store binary.** Package products link in every
  configuration of a target. Xcode can't link them per configuration. With the packages on the `DyorHQ` target, a
  Release build without the flag still contained about 12,000 DyorLite, StellarCore and LiteClient symbols, plus the
  `StellarKit_StellarCore` and `swift-crypto_Crypto` resource bundles. Only the app's own Lite files dropped out. §1
  therefore links the packages to a separate internal target.

## 1. Packages, files and the internal target

1. **Get the packages into the app's checkout.** SwiftPM can't fetch them by git URL: a remote package needs
   `Package.swift` at the repository root, and DyorLite depends on StellarKit by a local path. Add this repo as a git
   submodule, for example at `ios/External/multichain-stellar`. Xcode Cloud then needs access to
   `DyorHQ/multichain-stellar` as an additional repository. The package paths are relative to `ios/project.yml`:
   ```yaml
   packages:
     StellarKit: { path: External/multichain-stellar/ios/Packages/StellarKit }
     DyorLite:  { path: External/multichain-stellar/ios/Packages/DyorLite }
   ```
2. Copy `ios/Integration/*.swift` into `DyorHQ/Lite/`.
3. **A separate target links them, not `DyorHQ`.** Move the `DyorHQ` target's spec into an XcodeGen
   `targetTemplates` entry. Then declare two targets from it:
   - `DyorHQ`: unchanged, for the App Store and external TestFlight.
   - `DyorHQ Internal`: adds the two package dependencies (`DyorLite`, and `StellarKit` with product `StellarKit`), and
     sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) STELLAR_LITE"` and
     `LITE_API_URL: "https:/$()/fmnjqrguvopusfufmirs.supabase.co/functions/v1/lite"`. In an xcconfig, `//` starts a
     comment, hence `/$()/`.

   Add `LITE_API_URL: "$(LITE_API_URL)"` to the shared Info.plist properties. It stays empty in `DyorHQ`, and with no
   URL there is no pill. Give `DyorHQ Internal` its own scheme. Only the internal TestFlight group gets its builds.

## 2. Remote flag (default off)

Every existing `RemoteFlags` switch is on unless the JSON says `false`. Lite inverts that: it stays off unless the
JSON says exactly `true`.

- `DyorKit/Services/Supabase/RemoteFlags.swift`:
  - Add `public let stellarLite: Bool` with an init default of `false`. `RemoteFlags.on` then has it off.
  - In `parse`, add `stellarLite: optIn(flags["stellarLite"])`, with `optIn` modelled on `flag()`:
    ```swift
    /// An opt-in switch's value: true only for JSON `true` (not 1, not "true"); off for everything else.
    private static func optIn(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    ```
    `as? Bool == true` is not enough: it also accepts JSON `1`.
- `AppEnvironment`: add `var stellarLiteEnabled = false`, and in `apply(_ flags: RemoteFlags)` set
  `stellarLiteEnabled = flags.stellarLite`. The flag isn't stored between launches, so the pill appears once the flags
  are read.
- Turn it on for testers: `app_config` 'ios' → `{"min_build": …, "flags": {"stellarLite": true}}`. App Store builds
  don't link Lite anyway (§1).

## 3. Root

In `RootView.swift`, where the signed-in app shows `MainTabView()`:

```swift
#if STELLAR_LITE
ProLiteRoot()
#else
MainTabView()
#endif
```

`ProLiteRoot` shows the Pro ⇄ Lite pill above the Pro tabs when Lite is available. When the user picks Lite, it swaps
the Pro tabs for `LiteRootView` and remembers the mode per account. It re-checks when the remote flag arrives or turns
off.

## 4. Key hooks

Every hook sits inside `#if STELLAR_LITE`, because `LiteKeyBootstrap` exists only under the flag. Line numbers are
from `origin/main` 5bcd812.

| Where | Change | Why |
|---|---|---|
| `Session.swift`, `PasswordKeys` (384) and `derivePassword` (403) | Add `let pepper: Data` and pass `pepper: p` | Seed and pepper are both in hand only in `derivePassword`. It runs before the password is verified, so the hook can't go there |
| `Session.logInWithPassword`, after `commitPasswordWallet` (465) | `LiteKeyBootstrap.didDeriveEmailWallet(seed: keys.seed, pepper: keys.pepper, evm: keys.wallet.address)` | Log-in, after the password is verified |
| `Session.bindEmailPassword`, after `commitPasswordWallet` (592) | The same call | Sign-up, forgot password and the v2 upgrade |
| `ImportWalletView.runImport` (175) | Keep `let importedKind = kind` next to `importedSecret`. After `Haptics.success()`, call `didImport(phrase: importedSecret, …)` for a phrase, or `didImport(privateKey: derived.privateKey, …)` for a key, with `evm: derived.address` | `Session.importWallet` only receives the derived account. Hooking there would give a phrase import the private-key derivation instead of SEP-5 |
| `Session.signOut` (top) and `Session.eraseLocalData` (before the UserDefaults wipe) | `if let address { LiteKeyBootstrap.forget(evm: address) }` | Sign-out otherwise leaves the Stellar seed in the Keychain. The erase must run before UserDefaults, which holds the Stellar address, is wiped |

Checked:

- The email v2 derivation matches. The app derives `HKDF(S ‖ p, salt "dyorhq/email-wallet/v2", info "secp256k1")`.
  StellarKit uses the same 64 input bytes and salt, with info `stellar-ed25519`.
- Phrases are normalised the way DyorKit reads them (lowercased, split on any whitespace) before SEP-5. A capitalised
  or CRLF phrase otherwise imported the right Monad wallet but the wrong Stellar key.

Passkey (Mera) accounts need no hook. The first switch to Lite runs one `session.mera.revealPhrase(expecting:)`
ceremony to learn the Stellar address (public, stored). Every Lite signature then runs a fresh ceremony, and the words
never outlive the call. Privy accounts (Apple, Google, email code) don't get the pill in phase 1. Legacy (pre-v2)
email wallets (`continueWithLegacyWallet`) have no pepper, so they get no Stellar key, and Lite's "Sign in again" does
not help them. That is a known gap.

## 5. Bridge

`MonadBridgeAdapter` signs the Monad side with the Pro wallet (`session.wallet(for: nil)`), through DyorKit's own
`TransactionSender(rpc: RPCClient(url:), chainId: 10143)`. On testnet that is Monad testnet, where CCTP v2 is
registered both ways. Mainnet uses NEAR Intents through the same protocol (`LiteMonadBridge`).

- A passkey account gets a passkey prompt for every Monad testnet transaction: chain 10143 is outside the Mera
  signing policy's Monad check.
- The simulator's stub passkey refuses non-Monad chains.

## 6. Check

- `DyorHQ Internal` build, tester account: the pill appears. Lite asks for the invite once, then for activation (one
  tap), then shows the tabs. Switching back shows the Pro tabs unchanged.
- `DyorHQ` Release build: `nm` on the app binary shows no `DyorLite`, `StellarCore` or `LiteClient` symbols, and the
  `.app` has no `StellarKit_StellarCore.bundle`. In Debug, the code is in `DyorHQ.app/DyorHQ.debug.dylib`; the main
  executable is a stub.
- Sign out: the account's Stellar seed and Lite session are gone from the Keychain, and its remembered mode is cleared.
