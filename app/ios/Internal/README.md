# The internal project and its checks

`ios/Internal` holds what only the internal build has: the DyorHQ app with the Stellar network (DyorHQ Lite), for the
internal TestFlight group. The App Store project (`project.yml` → `DyorHQ.xcodeproj`) never references any of it.

- `generate.py` writes `DyorHQInternal.xcodeproj` from `project.yml`: the app target plus the two Lite packages
  (StellarKit and DyorLite, from DyorHQ/multichain-stellar), the `STELLAR_LITE` compilation condition, its own
  `Info.plist` and `Resources/`.
- `Resources/` holds the internal build's own resources: the `Lite` and `Stellar*` string tables and the XLM logo.
- `check-build23.py`, `check-lite-strings.py` and `check-copies.py` keep the App Store build equal to build 23
  (d387a64) while the Stellar code grows next to it. `unflagged-changes.txt` lists the changes `check-build23.py`
  accepts outside its rules.

The Stellar code lives in `ios/DyorHQ/Lite/`, every file wholly inside `#if STELLAR_LITE`. A build-23 file changes only
inside `#if STELLAR_LITE` blocks. Nothing under `ios/DyorKit` changes.

Every script runs with Python 3's standard library, in isolated mode (`python3 -I`), from `ios/`. Each prints paths,
line numbers, keys and hashes, never a file's contents, and exits 0 when clean, 1 on a finding and 2 when it can't
run.

## Generating and building

With DyorHQ/multichain-stellar checked out beside this repository, or `--lite` pointing at its `ios/Packages`
(`--spec` takes another XcodeGen spec, such as a local one):

```bash
cd ios
python3 -I Internal/generate.py
xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData-internal \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

The App Store build, for `check-build23.py --app`:

```bash
xcodegen generate
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData-appstore CODE_SIGNING_ALLOWED=NO build
```

## check-build23.py

```bash
python3 -I Internal/check-build23.py --base d387a64              # the commits since build 23
python3 -I Internal/check-build23.py --base d387a64 --worktree   # the working tree, untracked files included
python3 -I Internal/check-build23.py --base d387a64 \
  --app DerivedData-appstore/Build/Products/Release-iphonesimulator/DyorHQ.app
```

It diffs the whole repository against the base and checks each changed path:

| Path | Rule |
|---|---|
| `ios/DyorKit/**` | never changes, `Package.resolved` included |
| `ios/Internal/**` | anything |
| added `ios/DyorHQ/Lite/**.swift` | after stripping, only blank lines and `//` comments remain |
| modified `ios/DyorHQ/**.swift` | after stripping, byte for byte the base's file |
| any other added `.swift`; a deleted or renamed `ios/DyorHQ/**` file | fails |
| `ios/project.yml`, `ios/DyorHQ/Info.plist` | only the `CFBundleVersion` line |
| `ios/.gitignore` | only added `project-internal.json` and `DerivedData*` lines (and comments) |
| anything else | listed in `unflagged-changes.txt`, within its rule |

`swift test` in DyorKit and the internal build both rewrite `ios/DyorKit/Package.resolved` (the internal build adds the
Lite packages' pins): restore it with `git checkout -- ios/DyorKit/Package.resolved` before committing.

Stripping removes each `#if STELLAR_LITE` block's lines, keeps its `#else` branch, and drops the three directive lines.
Other `#if` blocks stay as written. `#elseif` inside a `#if STELLAR_LITE` block, `#if !STELLAR_LITE` and any other
condition that names `STELLAR_LITE` are unsupported and fail: write `#if STELLAR_LITE … #else … #endif`.

`--app` looks inside an App Store Release build (from `DyorHQ.xcodeproj`, never the internal project). It fails on any
symbol of DyorLite, StellarKit, StellarCore or LiteClient in its binaries (`nm -U`), on a bundle or framework of
theirs, and on a `Lite` or `Stellar*` string table or any other resource of `Internal/Resources`.

### unflagged-changes.txt

An entry is a path and its rule, then its reason on the indented lines below it:

```
ios/DyorHQ/Support/GetHelpView.swift literal "old text" "new text"
    Why this line changes in the App Store build.
```

- `any`: the file may change in any way. Not for a Swift file under `ios/DyorHQ`.
- `literal "<old>" "<new>"`: only lines that swap the old text for the new one differ. A Swift file is compared after
  stripping, so it can have `#if STELLAR_LITE` blocks as well.
- `keys -"<key>" +"<key>"`: a String Catalog with exactly those keys removed and added. Every other key, and
  everything outside `strings`, must be equal as JSON.

## check-lite-strings.py

```bash
python3 -I Internal/check-lite-strings.py --derived DerivedData-internal --base d387a64            # after a build
python3 -I Internal/check-lite-strings.py --derived DerivedData-internal --base d387a64 --enforce
```

It reads the `.stringsdata` the internal build extracts, what each source looks up and in which table, for the Lite
code: every source under `ios/DyorHQ/Lite/`, and the `#if STELLAR_LITE` blocks of the app's other sources. Build the
internal project first: a `.stringsdata` older than its source means the build is out of date. It fails when:

- a key in the `Lite` table or a `Stellar*` table (for example `StellarHome`) is missing from
  `Internal/Resources/<table>.xcstrings`, or isn't translated into es, fr, zh-Hans and ko;
- a translation changes a name that is never translated (Stellar, Monad, DyorHQ, XLM, USDC, EURC, Soroswap, Aquarius,
  Blend, Circle CCTP, Freighter, StellarExpert);
- a key in the default table (`Text("…")` or `LocalizedStringResource("…")` without a table) isn't one of build 23's
  `Localizable.xcstrings` keys: new copy names its table, and the App Store catalog never grows;
- a source uses any other table;
- with `--enforce`, a `Lite` or `Stellar*` table holds a key the Lite code doesn't use (without it, these are only
  listed).

New keys reach a table with `xcrun xcstringstool sync Internal/Resources/<table>.xcstrings --stringsdata <file>…`,
given every `.stringsdata` under the internal build's `DyorHQ.build/Objects-normal`. Never
`scripts/dev/strings-sync.sh`: it syncs the App Store catalogs.

## check-copies.py

A Monad piece that is private or EVM-typed is copied into `Lite/` with a `Stellar` name. The copy starts with a header
naming its source declaration and that declaration's hash at the base:

```swift
// Stellar copy of ios/DyorHQ/Home/HomeView.swift HomeAction (d387a64 sha256:3e32e86f1b75)
```

```bash
python3 -I Internal/check-copies.py --base d387a64                   # check every header under ios/DyorHQ/Lite
python3 -I Internal/check-copies.py --base d387a64 --header ios/DyorHQ/Home/HomeView.swift HomeAction
```

The second form prints the header for a new copy. The hash covers the declaration's lines, from the one with its
keyword through the one with its closing brace. When a name is declared more than once in the file, qualify it with its
enclosing type (`HomeView.heroCard`). When a later base changes the source, the check names the copy: re-sync it with
the source, then write the new header.
