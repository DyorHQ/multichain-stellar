# Wiring Lite into the DyorHQ app (after the Oct 13 submission)

The submitted Monad app is not touched. This is the patch to apply afterwards. It is about 30 lines in the app plus the
drop-in files from `ios/Integration/`, and everything sits behind the `STELLAR_LITE` compile flag. A build without the
flag (App Store, external TestFlight) compiles none of it.

## 1. Packages and files

1. In `project.yml`, add the two local packages and link them to the app target:
   ```yaml
   packages:
     StellarKit: { path: ../multichain-stellar/ios/Packages/StellarKit }   # or a git URL to the private repo
     DyorLite:  { path: ../multichain-stellar/ios/Packages/DyorLite }
   targets:
     DyorHQ:
       dependencies:
         - package: DyorLite
         - package: StellarKit
           product: StellarKit
   ```
2. Copy `ios/Integration/*.swift` into `DyorHQ/Lite/`.
3. Add an **Internal** build configuration (a copy of Release) with
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) STELLAR_LITE` and `LITE_API_URL = https://<ref>.supabase.co/functions/v1/lite`.
   Add `LITE_API_URL` to Info.plist as `$(LITE_API_URL)`. Only the internal TestFlight group gets Internal builds.

## 2. Remote flag (default off)

Every existing `RemoteFlags` switch is on unless the JSON says false. Lite inverts that: it stays off unless the JSON
explicitly says `true`.

- In `DyorKit/Services/Supabase/RemoteFlags.swift`:
  - Add `public let stellarLite: Bool` (init default `false`).
  - In `parse`, set it only when `flags["stellarLite"] as? Bool == true`.
- In `AppEnvironment`:
  - Add `var stellarLiteEnabled = false`.
  - In `apply(_ flags: RemoteFlags)`, set `stellarLiteEnabled = flags.stellarLite`.
- Turn it on for testers: `app_config` 'ios' → `{"min_build": …, "flags": {"stellarLite": true}}`. Production's flag
  stays absent, so production stays off.

## 3. Root

In `RootView.swift`, `.signedIn` case:

```swift
#if STELLAR_LITE
ProLiteRoot()
#else
MainTabView()
#endif
```

`ProLiteRoot` shows the Pro ⇄ Lite pill above the Pro tabs when Lite is available. When the user picks Lite, it swaps
the Pro tabs for `LiteRootView`, and remembers the mode per account.

## 4. Key hooks (two lines)

| Where | Add | Why |
|---|---|---|
| `Session.commitPasswordWallet` (where seed + pepper are in hand) | `LiteKeyBootstrap.didDeriveEmailWallet(seed: s, pepper: p, evm: account.address)` | Derives the Stellar key (HKDF, info `stellar-ed25519`) and stores it in the Keychain, this device only |
| The import flow, after `ImportedWalletStore.save(privateKey:)` or a phrase import | `LiteKeyBootstrap.didImport(privateKey:evm:)` / `didImport(phrase:evm:)` | Same, for imported accounts |

Passkey (Mera) accounts need no hook. The first switch to Lite runs one `session.mera.revealPhrase(expecting:)`
ceremony to learn the Stellar address (public, stored). Every Lite signature then runs a fresh ceremony, and the words
never outlive the call. Privy accounts (Apple, Google, email code) don't get the pill in phase 1.

## 5. Bridge

`MonadBridgeAdapter` signs the Monad side with the Pro wallet (`session.wallet(for: nil)`), through DyorKit's own
`TransactionSender(rpc: RPCClient(url:), chainId: 10143)`. On testnet that is Monad testnet, where CCTP v2 is
registered both ways. Mainnet uses NEAR Intents through the same protocol (`LiteMonadBridge`).

## 6. Check

- Internal build, tester account: the pill appears.
  - Lite asks for the invite once, then activation (one tap), then the tabs.
  - Switching back shows the Pro tabs unchanged.
- External or App Store build: no pill, and `nm` on the binary shows no `DyorLite` symbols.
- Sign out or account deletion: also call `StellarKeychain.erase(account: <stellar address>)` (a one-line add next to
  the existing Keychain wipe in `Session.eraseLocalData`).
