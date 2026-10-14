import BigInt
import Foundation

/// A Moment's public link: what the Share button sends, and what a tapped link hands the app.
///
/// The link carries the Moment's name: `https://dyorhq.fun/moments/bitcoin-diva`. Names aren't unique, so the first
/// Moment published under a name gets it plain and later ones `-2`, `-3`… (`MomentSlug`). Names and the publish order
/// are fixed on chain, and a retired cohort's named Moments are frozen (`Cohort.namedMomentCount`), so a link never
/// starts pointing at another Moment. `dyorhq.fun/moments/*` is a universal link:
/// with the app installed it opens the Moment in the app, anywhere else the website's Moments page. The Moments' own
/// id form is read too — the NFTs' on-chain `external_url`: `https://dyorhq.fun/moments/c1/<id>` and `…/c2/<id>` for
/// cohorts 1 and 2, the bare `…/moments/<id>` for cohort 3, and `…/moments/c4/<id>` for the v2 Moments — and so is the
/// app scheme (`dyorhq://moments/<name or [cN/]id>`, for testing; never shared).
///
/// A link only navigates. Parsing yields a name or a `MomentKey`, nothing else (no amount, action or address); a name
/// resolves through `MomentDirectory` against the chain, and an id's factory comes from the pinned cohort table, never
/// from a live read. Parsing is strict and alias-free: exact host, `https` only, no userinfo, port 443 or none, the
/// percent-encoded path (`%31` is not `1`), ASCII only; the query and fragment are ignored and never acted on.
public struct MomentLink: Hashable, Identifiable, Sendable, CustomStringConvertible {
    /// What a link names: a Moment by its name (the shared form) or by (factory, id) (the on-chain form).
    public enum Target: Hashable, Sendable {
        case name(String)
        case key(MomentKey)
    }

    /// The Moments cohorts, in the order they were published — the order `MomentSlug` gives out names in, so it must
    /// never change: a new cohort goes at the end. `rawValue` is the path segment each factory put in its NFTs'
    /// `external_url` (read on chain 2026-09-28: cohort 1 `…/moments/c1/`, cohort 2 `…/moments/c2/`, cohort 3 the bare
    /// `…/moments/`; v2 is deployed with `…/moments/c4/`, `MomentsAddresses.expectedExternalBaseURI`). c1–c3 are the
    /// retired cohorts; c4 is the v2 factory, `MomentsAddresses.monadMainnet`, the only live one (in a Debug fork
    /// rehearsal, the rehearsal's). While v2 is not deployed its factory is zero and c4 is left out of parsing, links and
    /// the directory. `MomentLinkTests` pins the table to `MomentsAddresses`.
    public enum Cohort: String, CaseIterable, Sendable {
        case c1 = "c1", c2 = "c2", c3 = "", c4 = "c4"

        public var factory: Address {
            switch self {
            case .c1: return Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020")
            case .c2: return Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581")
            case .c3: return Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26")
            // Never a second literal: the v2 factory lives only in MomentsAddresses.monadMainnet. A Debug build pointed
            // at a fork rehearsal's v2 deployment names that one instead (`rehearse(liveFactory:)`).
            case .c4:
                #if DEBUG
                return Self.rehearsalFactory ?? MomentsAddresses.monadMainnet.factory
                #else
                return MomentsAddresses.monadMainnet.factory
                #endif
            }
        }

        #if DEBUG
        /// A fork rehearsal, in Debug builds only (none of this exists in a Release build). AppConfig's Debug-only
        /// MOMENTS_* override points the app at a v2 Moments deployment on a local fork, and c4 must name that factory too,
        /// or the rehearsal's own Moments get no link: `…/moments/c4/<id>` parses to nothing, Share has no link and no
        /// name reaches them. `AppEnvironment` calls this once at launch, before any link is read; nil (or the zero
        /// address) puts c4 back on `MomentsAddresses.monadMainnet`. c1–c3 never move.
        public static func rehearse(liveFactory: Address?) {
            rehearsalLock.lock()
            defer { rehearsalLock.unlock() }
            rehearsal = liveFactory.flatMap { $0.isZero ? nil : $0 }
        }

        private static let rehearsalLock = NSLock()
        nonisolated(unsafe) private static var rehearsal: Address?
        private static var rehearsalFactory: Address? {
            rehearsalLock.lock()
            defer { rehearsalLock.unlock() }
            return rehearsal
        }
        #endif

        public var isRetired: Bool { self != .c4 }

        /// Whether the cohort's factory is known: false for c4 while v2 is pending.
        public var isWired: Bool { !factory.isZero }

        /// The cohorts whose factory is known, in publish order.
        public static var wired: [Cohort] { allCases.filter(\.isWired) }

        /// A retired cohort's final Moment count: every coin it minted is in `MomentsAddresses.retiredMainnetCoins`
        /// (never traded in the app). Publishing is paused on chain on cohorts 1 and 2 but not on cohort 3 (owner
        /// decision 2026-09-28: the old stacks are retired in the app only), where builds before 16, or anyone calling
        /// the factory, can still publish. The release gate proves every pin on chain before an archive ships
        /// (`scripts/dev/check-launchpad-addresses.py --release`, also `--chain` by hand): cohorts 1 and 2 paused,
        /// `momentCount()` equal to the pin, and every coin in `MomentsAddresses.retiredMainnetCoins`. Cohort 3's is 1
        /// ("Nature", read at block 108,778,342): a Moment published there later makes the gate refuse until this pin
        /// and the coin table include it. Raising it moves no name: names stop at `namedMomentCount`. Nil for c4,
        /// which is counted live.
        public var finalMomentCount: Int? {
            switch self {
            case .c1: return 3
            case .c2: return 2
            case .c3: return 1
            case .c4: return nil
            }
        }

        /// How many of a retired cohort's Moments have a name: the ones it had when c4 went live (build 16). Frozen, whatever
        /// `finalMomentCount` becomes. A Moment published on the open cohort 3 after that (a build before 16, or a direct
        /// call to its factory) gets its id link only (`…/moments/<id>`), never a name, so it can never take a name
        /// ahead of a c4 Moment's, and raising the pin to take in its coin changes no link. The directory reads a retired
        /// cohort's names up to this count and never counts it on chain. Nil for c4, whose Moments are named as they
        /// are counted.
        public var namedMomentCount: Int? {
            switch self {
            case .c1: return 3
            case .c2: return 2
            case .c3: return 1
            case .c4: return nil
            }
        }

        /// The cohort a factory belongs to, or nil for an address that is not a Moments factory the app knows (the zero
        /// address included, so a pending c4 matches nothing).
        public init?(factory: Address) {
            guard !factory.isZero, let known = Self.allCases.first(where: { $0.factory == factory }) else { return nil }
            self = known
        }

        var pathPrefix: String { rawValue.isEmpty ? "" : rawValue + "/" }
    }

    /// The host of Moment links (`applinks:` in the entitlement; the website serves the association file).
    public static let host = "dyorhq.fun"
    /// The app's own URL scheme (`CFBundleURLSchemes`); Moment links use the host `moments` under it.
    public static let scheme = "dyorhq"
    /// Ids are per-factory counters; anything longer is not a Moment.
    public static let maxIdDigits = 18

    public let target: Target

    public var id: Target { target }
    public var description: String { url.absoluteString }

    /// The link to share: `https://dyorhq.fun/moments/<name>`, or the id form for a Moment known only by its key.
    public var url: URL { URL(string: "https://\(Self.host)/moments/\(path)")! }
    /// The app-scheme form. Any app can claim the scheme, so it is only ever a test hook.
    public var appURL: URL { URL(string: "\(Self.scheme)://moments/\(path)")! }

    private var path: String {
        switch target {
        case .name(let name): return name
        case .key(let key): return (Cohort(factory: key.factory)?.pathPrefix ?? "") + String(key.id)
        }
    }

    /// A link by name; nil unless `name` is a well-formed slug (`MomentSlug.isValid`).
    public init?(name: String) {
        guard MomentSlug.isValid(name) else { return nil }
        target = .name(name)
    }

    /// A link by (factory, id), for a cohort the app knows.
    public init?(key: MomentKey) {
        guard Cohort(factory: key.factory) != nil, Self.isValidId(key.id) else { return nil }
        target = .key(key)
    }

    public init?(cohort: Cohort, id: BigUInt) {
        self.init(key: MomentKey(factory: cohort.factory, id: id))
    }

    /// Parses a link the app was handed. Everything that isn't exactly one of the accepted shapes is nil: never a guess.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil else { return nil }
        let host = parts.host?.lowercased() ?? ""
        // The percent-encoded path, so "%31" cannot alias "1"; empty segments are kept, so "//1" is rejected below.
        var segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "" else { return nil }
        segments.removeFirst()
        switch parts.scheme?.lowercased() {
        case "https":
            guard host == Self.host, parts.port == nil || parts.port == 443, segments.first == "moments" else { return nil }
            segments.removeFirst()
        case Self.scheme:
            guard host == "moments", parts.port == nil else { return nil }
        default:
            return nil
        }
        if segments.last == "" { segments.removeLast() } // one trailing slash
        switch segments.count {
        case 1:
            // A bare id is cohort 3's `external_url` form.
            let segment = String(segments[0])
            if let id = Self.parseId(segments[0]) {
                target = .key(MomentKey(factory: Cohort.c3.factory, id: id))
            } else if MomentSlug.isValid(segment.lowercased()) {
                target = .name(segment.lowercased())
            } else {
                return nil
            }
        case 2:
            // Only a named cohort segment (c1, c2, c4), exactly: "" would let "/moments//1" through, and a pending c4 has
            // no factory.
            guard let cohort = Cohort(rawValue: String(segments[0])), !cohort.rawValue.isEmpty, cohort.isWired, let id = Self.parseId(segments[1]) else { return nil }
            target = .key(MomentKey(factory: cohort.factory, id: id))
        default:
            return nil
        }
    }

    /// Whether a URL is addressed to DyorHQ's Moments at all, parsable or not: the website's Moments paths, or the app
    /// scheme's `moments` host. Privy's OAuth callback on the same scheme is not.
    public static func isOurs(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let host = parts.host?.lowercased() ?? ""
        switch parts.scheme?.lowercased() {
        case "https": return host == Self.host && parts.percentEncodedPath.hasPrefix("/moments")
        case Self.scheme: return host == "moments"
        default: return false
        }
    }

    /// A canonical decimal id: ASCII digits only (`Character.isNumber` would take "١" or "²"), no leading zero, at most
    /// `maxIdDigits`, greater than zero.
    static func parseId(_ text: Substring) -> BigUInt? {
        guard !text.isEmpty, text.count <= maxIdDigits, text.first != "0",
              text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return BigUInt(String(text))
    }

    static func isValidId(_ id: BigUInt) -> Bool { id > 0 && String(id).count <= maxIdDigits }
}

/// The readable part of a Moment's link, made from its name, and the rule that keeps every one unique.
///
/// `base` is deterministic on every device and OS version: compatibility decomposition (NFKD, which Unicode's
/// stability policy fixes for every assigned character: "é" → "e" + accent, "ﬁ" → "fi", fullwidth → ASCII), the
/// combining accents U+0300–U+036F dropped, ASCII letters lowercased, every other run of characters one "-", trimmed,
/// at most `maxBase` characters. A name with no ASCII letter ("2024", "🔥🔥") gets a "moment-" prefix, so a name is
/// never mistaken for an id; an empty result is "moment".
public enum MomentSlug {
    public static let maxBase = 60
    /// The longest well-formed slug: a base plus a "-<n>" suffix.
    public static let maxLength = 80

    public static func base(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.decomposedStringWithCompatibilityMapping.unicodeScalars {
            let v = scalar.value
            if (0x300...0x36F).contains(v) { continue } // combining accents: "é" folds to "e"
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append((0x41...0x5A).contains(v) ? Unicode.Scalar(v + 0x20)! : scalar)
            } else {
                pendingDash = true
            }
        }
        if out.count > maxBase {
            out = String(out.prefix(maxBase))
            while out.hasSuffix("-") { out.removeLast() }
        }
        if out.isEmpty { return "moment" } // not localized: a link's slug
        if !out.unicodeScalars.contains(where: { (0x61...0x7A).contains($0.value) }) { return "moment-" + out }
        return out
    }

    /// Gives every Moment its slug, in publish order (`names` must be every named Moment, oldest first: cohort by cohort
    /// in `MomentLink.Cohort` order, ids ascending; a retired cohort's up to `Cohort.namedMomentCount`). The first Moment with a base gets it plain; a later one gets the first
    /// free "<base>-2", "<base>-3"… Each slug depends only on the Moments before it, so publishing more never changes
    /// an existing one.
    public static func assign(_ names: [(key: MomentKey, name: String)]) -> [MomentKey: String] {
        var taken = Set<String>()
        var slugs: [MomentKey: String] = [:]
        for (key, name) in names {
            let base = self.base(name)
            var slug = base
            var n = 2
            while taken.contains(slug) {
                slug = "\(base)-\(n)"
                n += 1
            }
            taken.insert(slug)
            slugs[key] = slug
        }
        return slugs
    }

    /// Well-formed: lowercase ASCII letters and digits in "-"-joined runs, at most `maxLength`, with at least one letter.
    public static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.utf8.count <= maxLength, !slug.hasPrefix("-"), !slug.hasSuffix("-"), !slug.contains("--") else { return false }
        var letter = false
        for byte in slug.utf8 {
            switch byte {
            case 0x61...0x7A: letter = true
            case 0x30...0x39, 0x2D: break
            default: return false
            }
        }
        return letter
    }
}

/// What to do with a Moment link that arrived, given where the app is. The link waits (on the App-level Router, which
/// outlives sign-in) until a state that may navigate; it is dropped under the update gate, where nothing that signs may
/// be reachable (GP-2); and it never tears down a running or open confirmation. Pure, so every row is a test.
public enum MomentLinkGate {
    public enum Phase: Hashable, Sendable {
        /// The session hasn't answered yet (a cold start lands here).
        case loading
        case signedOut
        case signedIn
    }

    public enum Decision: Hashable, Sendable {
        /// Keep the link; a later state change decides.
        case hold
        /// Keep it, and tell the person signing in that it is waiting.
        case banner
        /// Forget it.
        case drop
        /// Open the Moment now.
        case deliver
    }

    /// - Parameters:
    ///   - updateRequired: the build is below the minimum (`UpdateGate.required`).
    ///   - deletionScreen: the account-deleted or deletion-notice screen is up (shown before onboarding).
    ///   - busy: a confirmation sheet is on screen, or an approved action is still signing or sending.
    public static func decide(phase: Phase, updateRequired: Bool, deletionScreen: Bool, busy: Bool) -> Decision {
        switch phase {
        case .loading:
            return .hold
        case .signedOut:
            if deletionScreen { return .hold }
            return updateRequired ? .drop : .banner
        case .signedIn:
            if updateRequired { return .drop }
            return busy ? .hold : .deliver
        }
    }
}

/// Every Moment's name, read from the chain in publish order, turned into link slugs (`MomentSlug.assign`). A retired
/// cohort is read once, up to its frozen named count (`Cohort.namedMomentCount`) and never counted, so a Moment
/// published there later gets no name; the live cohort is re-counted when a lookup needs newer Moments. A cohort with no factory (c4 while v2 is pending) is left out: a
/// Multicall3 call to address 0 returns no data, and that one failed decode would fail every lookup. Nothing is kept
/// across launches, and a read that fails anywhere fails the whole lookup: a missing name would shift the slugs after it.
/// Names are read in chunks (`Multicall.nameChunk`, a chunk the node refuses again one name at a time), so no name,
/// however long, can make a read too large to answer; a name that can't be read even on its own fails the lookup too,
/// never gets a stand-in, since that would give its Moment, and later ones of the same name, other slugs.
public actor MomentDirectory {
    private let multicall: Multicall
    private let cohorts: [MomentLink.Cohort]
    private var names: [MomentLink.Cohort: [String]] = [:]
    private var counted: [MomentLink.Cohort: Date] = [:]
    private var refreshing: Task<Void, Error>?
    /// How long a count of the live cohort is trusted before a lookup reads it again.
    private let liveTTL: TimeInterval

    public init(rpc: RPCClient, cohorts: [MomentLink.Cohort] = MomentLink.Cohort.allCases, liveTTL: TimeInterval = 20) {
        multicall = Multicall(rpc: rpc)
        self.cohorts = cohorts.filter(\.isWired)
        self.liveTTL = liveTTL
    }

    /// The Moment a name link means, or nil when no Moment has that slug.
    public func key(for slug: String) async throws -> MomentKey? {
        if let hit = table().bySlug[slug] { return hit }
        try await refresh(force: true)
        return table().bySlug[slug]
    }

    /// The link to share for a Moment: its name form, or nil when the Moment isn't (yet) in the directory.
    public func link(for key: MomentKey) async throws -> MomentLink? {
        if let slug = table().byKey[key] { return MomentLink(name: slug) }
        try await refresh(force: true)
        return table().byKey[key].flatMap(MomentLink.init(name:))
    }

    private func table() -> (bySlug: [String: MomentKey], byKey: [MomentKey: String]) {
        var ordered: [(key: MomentKey, name: String)] = []
        for cohort in cohorts {
            for (i, name) in (names[cohort] ?? []).enumerated() {
                ordered.append((MomentKey(factory: cohort.factory, id: BigUInt(i + 1)), name))
            }
        }
        let byKey = MomentSlug.assign(ordered)
        var bySlug: [String: MomentKey] = [:]
        for (key, slug) in byKey { bySlug[slug] = key }
        return (bySlug, byKey)
    }

    /// Reads the names of Moments not read yet. One refresh at a time; a caller arriving meanwhile waits for it.
    private func refresh(force: Bool) async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.readNewNames(force: force) }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func readNewNames(force: Bool) async throws {
        let now = Date()
        // Every cohort that may have grown: a retired cohort once (to its named count), the live one when stale.
        let stale = cohorts.filter { cohort in
            guard let at = counted[cohort] else { return true }
            return cohort.namedMomentCount == nil && (force || now.timeIntervalSince(at) > liveTTL)
        }
        guard !stale.isEmpty else { return }
        // Only a cohort without a named count is counted on chain.
        let live = stale.filter { $0.namedMomentCount == nil }
        let liveCounts = live.isEmpty ? [] : try await multicall.readAll(live.map { MomentsABI.call($0.factory, MomentsABI.Factory.momentCount, returns: "uint256") })
        var counts: [MomentLink.Cohort: BigUInt] = [:]
        for (cohort, value) in zip(live, liveCounts) { counts[cohort] = value[0].uint }
        var wanted: [(cohort: MomentLink.Cohort, id: BigUInt)] = []
        for cohort in stale {
            let count = cohort.namedMomentCount.map { BigUInt($0) } ?? counts[cohort] ?? 0
            let have = BigUInt(names[cohort]?.count ?? 0)
            if count > have { for id in (have + 1)...count { wanted.append((cohort, id)) } }
        }
        if !wanted.isEmpty {
            let moments = try await multicall.readItems(wanted.map { [MomentsABI.call($0.cohort.factory, MomentsABI.Factory.getMoment, [.uint($0.id)], returns: MomentsABI.momentTuple)] },
                                                        text: [], what: .moment, chunk: Multicall.recordChunk)
            let coins = try zip(wanted, moments).map { MomentsABI.moment(id: $0.id, try $1[0].get()[0], factory: $0.cohort.factory).coin }
            let read = try await multicall.readItems(coins.map { [MomentsABI.call($0, MomentsABI.Coin.name, returns: "string")] }, text: [], what: .momentName,
                                                     chunk: Multicall.nameChunk)
            // Appended in id order per cohort, once every name is read: `wanted` is ascending within each cohort.
            let values = try read.map { try $0[0].get()[0].string }
            for (entry, value) in zip(wanted, values) { names[entry.cohort, default: []].append(value) }
        }
        for cohort in stale { counted[cohort] = now }
    }
}
