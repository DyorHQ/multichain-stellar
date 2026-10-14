import Foundation

/* What a device takes back from the wallet's own backend rows (Supabase) after a sign-in — a fresh device, a
   reinstall, or a passkey account on any iPhone (MERA-PLAN §6). The rows are the wallet's under row-level security,
   but they are still input from outside the app: anyone holding that wallet's backend session, or a bug in another
   build, can write them. So a restored setting is only ever a value the app's own screens could have set, a restored
   activity row is checked field by field, and the activity feed is merged into the device's, never replaced. The app
   half (the reads, the stores) is in DyorHQ/Backend/BackendSync.swift; the rules are here so `swift test` pins them. */

/// The trade tickets' defaults and the values the Settings screens offer (Profile › Trading Preferences).
public enum TradingDefaults {
    /// Max Slippage choices, in basis points: 0.1%, 0.5%, 1%, 2%.
    public static let slippageChoicesBps = [10, 50, 100, 200]
    public static let slippageBps = 50
    /// Never restore a slippage above this, whatever the choices become (MERA-PLAN §6).
    public static let maxRestoredSlippageBps = 300
    /// The Default Leverage stepper: whole steps from 1× to 50×. Each market still caps it to its own maximum.
    public static let leverageRange: ClosedRange<Double> = 1...50
    public static let leverage: Double = 2
}

public enum BackendRestore {
    // MARK: Settings

    /// A backend settings snapshot, reduced to what may be applied. A key that is missing (or not understood) stays
    /// nil and leaves the device's value alone; a trading default that is present but is not one the screens offer
    /// becomes the default, never the nearest extreme — a hostile 5 000 bps slippage restores as 0.5%, not 3%, and a
    /// 1 000× leverage as 2×, not 50×.
    public struct Settings: Equatable, Sendable {
        public var appearance: String?
        public var notificationsEnabled: Bool?
        public var notifyFills: Bool?
        public var notifyPriceAlerts: Bool?
        public var notifyMargin: Bool?
        public var defaultLeverage: Double?
        public var slippageBps: Int?

        public init(appearance: String? = nil, notificationsEnabled: Bool? = nil, notifyFills: Bool? = nil, notifyPriceAlerts: Bool? = nil,
                    notifyMargin: Bool? = nil, defaultLeverage: Double? = nil, slippageBps: Int? = nil) {
            self.appearance = appearance
            self.notificationsEnabled = notificationsEnabled
            self.notifyFills = notifyFills
            self.notifyPriceAlerts = notifyPriceAlerts
            self.notifyMargin = notifyMargin
            self.defaultLeverage = defaultLeverage
            self.slippageBps = slippageBps
        }
    }

    /// Checks a snapshot (`AppSettings.snapshot`'s keys, as JSON decoded it) against what the screens offer.
    /// `appearances` is the set of appearance modes the app knows.
    public static func settings(from snapshot: [String: Any], appearances: Set<String>) -> Settings {
        var out = Settings()
        if let raw = snapshot["appearance"] as? String, appearances.contains(raw) { out.appearance = raw }
        out.notificationsEnabled = bool(snapshot["notificationsEnabled"])
        out.notifyFills = bool(snapshot["notifyFills"])
        out.notifyPriceAlerts = bool(snapshot["notifyPriceAlerts"])
        out.notifyMargin = bool(snapshot["notifyMargin"])
        if snapshot.keys.contains("defaultLeverage") { out.defaultLeverage = leverage(snapshot["defaultLeverage"]) }
        if snapshot.keys.contains("slippageBps") { out.slippageBps = slippageBps(snapshot["slippageBps"]) }
        return out
    }

    /// One of the Max Slippage choices, and never above `maxRestoredSlippageBps`; anything else is the default.
    public static func slippageBps(_ value: Any?) -> Int {
        guard let n = number(value), n == n.rounded(), abs(n) <= Double(Int32.max) else { return TradingDefaults.slippageBps }
        let bps = Int(n)
        guard TradingDefaults.slippageChoicesBps.contains(bps), bps <= TradingDefaults.maxRestoredSlippageBps else { return TradingDefaults.slippageBps }
        return bps
    }

    /// A whole leverage within the stepper's range (a fraction rounds to the nearest whole step); anything else —
    /// out of range, not finite, not a number — is the default.
    public static func leverage(_ value: Any?) -> Double {
        guard let n = number(value), n.isFinite else { return TradingDefaults.leverage }
        let whole = n.rounded()
        return TradingDefaults.leverageRange.contains(whole) ? whole : TradingDefaults.leverage
    }

    /// A JSON number (never a boolean, which Foundation also boxes as a number).
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// A JSON boolean (never a number).
    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    // MARK: Activity

    /// The `activity` columns a restore reads (PostgREST `select`).
    public static let activityColumns = "id,kind,section,title,subtitle,tx_hash,usd,fee_usd,occurred_at"

    /// One row of the backend `activity` table, as it comes back. Every field decodes leniently — a missing or
    /// mistyped one is nil — so one bad row is dropped by `Activity.init` instead of failing the whole read.
    public struct ActivityRow: Decodable, Sendable {
        public let id: String?
        public let kind: String?
        public let section: String?
        public let title: String?
        public let subtitle: String?
        public let tx_hash: String?
        public let usd: Double?
        public let fee_usd: Double?
        public let occurred_at: String?

        private enum CodingKeys: String, CodingKey { case id, kind, section, title, subtitle, tx_hash, usd, fee_usd, occurred_at }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
            func amount(_ key: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: key) }
            id = text(.id); kind = text(.kind); section = text(.section); title = text(.title); subtitle = text(.subtitle)
            tx_hash = text(.tx_hash); usd = amount(.usd); fee_usd = amount(.fee_usd); occurred_at = text(.occurred_at)
        }
    }

    /// A backend activity row that checked out, ready to become a local record.
    public struct Activity: Equatable, Sendable {
        public let id: UUID
        public let kind: String
        public let section: String?
        public let title: String
        public let subtitle: String
        /// A 32-byte transaction hash, or nil (a perp order has none).
        public let txHash: Data?
        public let usd: Double?
        public let feeUsd: Double?
        public let time: Date

        /// Nil for a row that can't be a real record: no UUID id, no kind or title, a time that isn't an ISO 8601
        /// timestamp or is ahead of `now` by more than another device's clock could be (`futureSkew`; it would sit on top
        /// of the feed). A malformed hash or dollar value is dropped rather than the row; text is cut to the lengths the
        /// upload allows.
        public init?(_ row: ActivityRow, now: Date = Date()) {
            guard let id = row.id.flatMap(UUID.init(uuidString:)), let kind = row.kind, !kind.isEmpty, kind.count <= 40,
                  let time = row.occurred_at.flatMap(BackendRestore.timestamp), time <= now.addingTimeInterval(Self.futureSkew) else { return nil }
            let title = String((row.title ?? "").prefix(120))
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.id = id
            self.kind = kind
            section = row.section.flatMap { $0.isEmpty || $0.count > 40 ? nil : $0 }
            self.title = title
            subtitle = String((row.subtitle ?? "").prefix(300))
            txHash = row.tx_hash.flatMap { Data(hex: $0) }.flatMap { $0.count == 32 ? $0 : nil }
            usd = Self.dollars(row.usd)
            feeUsd = Self.dollars(row.fee_usd)
            self.time = time
        }

        /// How far ahead of this device's clock a restored row may be dated: ten minutes of clock drift between devices.
        public static let futureSkew: TimeInterval = 10 * 60

        private static func dollars(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
    }

    /// The device's feed with the backend's rows merged in, newest first: every local record kept as it is, and backend
    /// records added — unless the feed already has them (the same id, or the same transaction hash: the backend keys a
    /// settled transaction's row by its hash, the device by a random id) — only into the room left under `cap`, newest
    /// first. So restored rows never push the device's own out, however many there are or however they are dated.
    /// Merging the same rows again changes nothing.
    public static func mergeActivity<Record>(local: [Record], restored: [Record], cap: Int,
                                              id: (Record) -> UUID, txHash: (Record) -> Data?, time: (Record) -> Date) -> [Record] {
        var ids = Set<UUID>()
        var hashes = Set<Data>()
        func isNew(_ record: Record) -> Bool {
            let hash = txHash(record)
            guard !ids.contains(id(record)), !(hash.map(hashes.contains) ?? false) else { return false }
            ids.insert(id(record))
            if let hash { hashes.insert(hash) }
            return true
        }
        var merged: [(offset: Int, record: Record)] = []
        for record in local where isNew(record) { merged.append((merged.count, record)) }
        // Restored rows fill only the room left, newest first (on a tie, in the order the backend sent them).
        let room = max(0, cap - merged.count)
        let candidates = restored.enumerated().sorted { time($0.element) != time($1.element) ? time($0.element) > time($1.element) : $0.offset < $1.offset }
        var added = 0
        for (_, record) in candidates {
            guard added < room else { break }
            if isNew(record) { merged.append((merged.count, record)); added += 1 }
        }
        // Newest first; on a tie the device's own order (local rows first) decides.
        merged.sort { time($0.record) != time($1.record) ? time($0.record) > time($1.record) : $0.offset < $1.offset }
        return merged.map(\.record)
    }

    // MARK: Plumbing

    /// PostgREST's `timestamptz`: ISO 8601 with an offset, with or without fractional seconds.
    static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? whole.date(from: text)
    }
}
