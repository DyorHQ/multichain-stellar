// The Stellar section's own text: the network switch's table "Lite" and a table per area, "Stellar<Area>"
// (docs/DESIGN-stellar-parity.md §10). Internal builds only (STELLAR_LITE).
//
// The tables are ios/Internal/Resources/Lite.xcstrings and Stellar<Area>.xcstrings (StellarCommon, StellarReview,
// StellarHome, …), which Internal/generate.py adds to the internal target only: the App Store app never ships them, and
// its Localizable.xcstrings stays build 23's. Each table has one owner, so packages never edit the same catalog. Text
// the app already has (Close, Back, Try again, Network, Chain, Monad mainnet, No connection…, Confirm with %@, Signed
// in, Receive, Send, Max network fee, Up to %@) keeps coming from Localizable, through the app's own `tr()` and
// `Text("…")`, written with no comment (or through its enum label).
//
// Every new literal names its table where it is written, before its comment, so the build extracts it into that table:
// `LocalizedStringResource("…", table: "StellarCommon", comment: "…")`, resolved with `liteTr(_:)` (or by `Paragraph`
// and `InlineError`, which take the resource as it is), and `Text("…", tableName: "StellarCommon", comment: "…")` in
// SwiftUI.
//
// Keeping the tables up to date, from the internal build only (the App Store build has none of this text):
// 1. Sync: build DyorHQInternal.xcodeproj (SWIFT_EMIT_LOC_STRINGS is on), then
//    `xcrun xcstringstool sync ios/Internal/Resources/<table>.xcstrings --stringsdata <file>…` with every .stringsdata
//    under the internal build's DyorHQ.build/Objects-normal (DerivedData/Build/Intermediates.noindex/DyorHQInternal.build/…).
//    Never scripts/dev/strings-sync.sh: it syncs Localizable and DyorKit's catalog, not these tables.
// 2. Translate: give every key es, fr, zh-Hans and ko (and its English), with the comment written at its call site; a key
//    with a [tight] comment stays short. scripts/dev/check-strings.py reads every tracked ios/**/*.xcstrings, these tables
//    included once they are committed: run it with --enforce, and Internal/check-lite-strings.py after the build.
#if STELLAR_LITE
import DyorKit
import Foundation

enum LiteText {
    /// The network switch's table.
    static let table = "Lite"
    /// The start of every area's table: StellarCommon, StellarReview, StellarHome, …
    static let areaPrefix = "Stellar"

    /// Whether `table` is one of the Stellar section's: "Lite", or a "Stellar<Area>" table.
    static func isLiteTable(_ table: String?) -> Bool {
        guard let table else { return false }
        return table == Self.table || (table.hasPrefix(areaPrefix) && table.count > areaPrefix.count)
    }
}

/// Lite's text for a place that takes a `String`, in the language in use: `resource` resolved exactly as the app's `tr()`
/// resolves its own, with `L10n.locale` set on it, so an in-app language change reaches it at once. Its table must be
/// "Lite" or a "Stellar<Area>" table (written at the call site, where the build reads it).
func liteTr(_ resource: LocalizedStringResource) -> String {
    assert(LiteText.isLiteTable(resource.table), "Lite text is looked up in table Lite or Stellar<Area>: \(resource.key)")
    return tr(resource)
}
#endif
