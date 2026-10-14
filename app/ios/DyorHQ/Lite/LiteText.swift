// The network switch's own text: table "Lite". Internal builds only (STELLAR_LITE).
//
// The table is ios/Internal/Resources/Lite.xcstrings, which Internal/generate.py adds to the internal target only: the
// App Store app never ships it, and its Localizable.xcstrings stays build 23's. Text the app already has (Close, Back, Try
// again, Network, Chain, Monad mainnet, No connection…, Confirm with %@, Signed in, Receive, Send) keeps coming from
// Localizable, through the app's own `tr()` and `Text("…")`.
//
// Every Lite literal names the table where it is written, so the build extracts it into this table:
// `LocalizedStringResource("…", table: "Lite", comment: "…")`, resolved with `liteTr(_:)` (or by `Paragraph` and
// `InlineError`, which take the resource as it is), and `Text("…", tableName: "Lite", comment: "…")` in SwiftUI.
//
// Keeping the table up to date, from the internal build only (the App Store build has none of this text):
// 1. Sync: build DyorHQInternal.xcodeproj (SWIFT_EMIT_LOC_STRINGS is on), then
//    `xcrun xcstringstool sync ios/Internal/Resources/Lite.xcstrings --stringsdata <file>…` with every .stringsdata under
//    the internal build's DyorHQ.build/Objects-normal (DerivedData/Build/Intermediates.noindex/DyorHQInternal.build/…).
//    Never scripts/dev/strings-sync.sh: it syncs Localizable and DyorKit's catalog, not this table.
// 2. Translate: give every key es, fr, zh-Hans and ko (and its English), with the comment written at its call site; a key
//    with a [tight] comment stays short. scripts/dev/check-strings.py reads every tracked ios/**/*.xcstrings, this table
//    included once it is committed: run it with --enforce.
#if STELLAR_LITE
import DyorKit
import Foundation

enum LiteText {
    /// The table every Lite string is in.
    static let table = "Lite"
}

/// Lite's text for a place that takes a `String`, in the language in use: `resource` resolved exactly as the app's `tr()`
/// resolves its own, with `L10n.locale` set on it, so an in-app language change reaches it at once. Its table must be
/// "Lite" (written at the call site, where the build reads it).
func liteTr(_ resource: LocalizedStringResource) -> String {
    assert(resource.table == LiteText.table, "Lite text is looked up in table \(LiteText.table): \(resource.key)")
    return tr(resource)
}
#endif
