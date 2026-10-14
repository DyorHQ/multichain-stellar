import DyorKit
import Foundation
import UIKit

/// Mirrors what the app records on the device into the wallet's own rows on Supabase — activity with its dollar
/// size, the notification center, price alerts and settings — and restores them on a fresh device
/// after one sign-in (for a passkey account, which keeps nothing on the device, that is its whole local history). Every write goes through the wallet's backend session (row-level security by wallet);
/// nothing here touches a key. Uploads are debounced and best-effort: the local stores stay the source of truth.
/// Nothing waits on the session being up (security audit 2026-09-26, RS-4): each activity record joins a per-wallet
/// queue kept on the device (`BackendMirrorQueue`) until an upload succeeds, and a store whose upload was skipped or
/// failed stays marked for another try. Both are retried whenever the wallet's session connects (`restore`), the app
/// returns to the foreground, and a new record arrives.
@MainActor
final class BackendSync {
    private let social: SocialSession
    private var settings: AppSettings?
    private var address: () -> Address? = { nil }
    private var debounced: [Store: Task<Void, Never>] = [:]
    /// Bumped by each upload scheduled for a store, so only the latest one can mark it as synced.
    private var generation: [Store: Int] = [:]
    /// The wallet a `restore` is running for. Its stores' changes meanwhile are marked, not sent: restore's closing
    /// flush sends their contents then.
    private var restoring: Address?
    /// Wallets waiting for a `flush`, and the one running them.
    private var flushQueue: [Address] = []
    private var flushTask: Task<Void, Never>?
    private var foreground: NSObjectProtocol?
    private(set) var lastError: String?

    init(social: SocialSession) { self.social = social }

    /// Hooks every local store. Called once by the app environment.
    func install(settings: AppSettings, address: @escaping () -> Address?) {
        self.settings = settings
        self.address = address
        ActivityLog.onRecord = { record, owner in Task { @MainActor [weak self] in self?.activity(record, owner: owner) } }
        NotificationStore.onChange = { items, owner in Task { @MainActor [weak self] in self?.notifications(items, owner: owner) } }
        PriceAlertStore.onChange = { alerts, owner in Task { @MainActor [weak self] in self?.alerts(alerts, owner: owner) } }
        AppSettings.onChange = { Task { @MainActor [weak self] in self?.settingsChanged() } }
        // Back in the foreground: whatever is still waiting for the signed-in wallet goes now.
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let owner = self.address() else { return }
                self.flush(owner: owner)
            }
        }
    }

    // MARK: Uploads

    private struct ActivityRow: Codable, Sendable {
        let id: String, wallet: String, kind: String, section: String, title: String, subtitle: String
        let tx_hash: String?, usd: Double?, fee_usd: Double?, occurred_at: String

        /// Every key in every row, an absent value as JSON null: PostgREST refuses a bulk upsert whose objects don't all
        /// have the same keys (PGRST102), and a row without a hash or a dollar value would otherwise leave those out.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(wallet, forKey: .wallet)
            try c.encode(kind, forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(title, forKey: .title)
            try c.encode(subtitle, forKey: .subtitle)
            if let tx_hash { try c.encode(tx_hash, forKey: .tx_hash) } else { try c.encodeNil(forKey: .tx_hash) }
            if let usd { try c.encode(usd, forKey: .usd) } else { try c.encodeNil(forKey: .usd) }
            if let fee_usd { try c.encode(fee_usd, forKey: .fee_usd) } else { try c.encodeNil(forKey: .fee_usd) }
            try c.encode(occurred_at, forKey: .occurred_at)
        }
    }

    /// A new record joins the wallet's queue on the device first, then the queue is sent.
    private func activity(_ record: ActivityRecord, owner: Address) {
        let row = Self.row(record, owner: owner)
        Self.updateActivityQueue(owner) { $0.enqueue(id: row.id, row: row) }
        flush(owner: owner)
    }

    private static func row(_ record: ActivityRecord, owner: Address) -> ActivityRow {
        ActivityRow(id: stableID(record).uuidString.lowercased(), wallet: owner.checksummed.lowercased(), kind: record.kind.rawValue,
                    section: record.section ?? "wallet", title: String(record.title.prefix(120)), subtitle: String(record.subtitle.prefix(300)),
                    tx_hash: record.txHashHex?.lowercased(), usd: record.usd, fee_usd: record.feeUsd, occurred_at: iso(record.time))
    }

    /// The same settled transaction always maps to the same row, so re-recording it can never double a row. The row
    /// is keyed by wallet and id together (`on_conflict=wallet,id`, security audit 2026-09-26, SB-5): the id comes from
    /// a public transaction hash, so another wallet claiming it first must not keep this wallet's row out.
    private static func stableID(_ record: ActivityRecord) -> UUID {
        guard let hash = record.txHash, hash.count >= 16 else { return record.id }
        let b = [UInt8](hash.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Sends the wallet's queued activity rows, up to 100 per request. Rows the server takes leave the queue; when it
    /// refuses a batch, each row is sent on its own so one bad row can't hold back the rest, and a row refused
    /// `maxAttempts` times is dropped. An outage stops the flush; everything stays queued for the next one.
    private func flushActivity(owner: Address) async {
        let pending = Self.activityQueue(owner).entries
        var start = 0
        while start < pending.count {
            let batch = Array(pending[start..<min(start + 100, pending.count)])
            start += batch.count
            do {
                try await social.client.upsertRows("activity", batch.map(\.row), onConflict: "wallet,id")
                Self.updateActivityQueue(owner) { $0.uploaded(batch) }
            } catch where BackendMirror.outcome(of: error) == .refused {
                for entry in batch {
                    do {
                        try await social.client.upsertRows("activity", [entry.row], onConflict: "wallet,id")
                        Self.updateActivityQueue(owner) { $0.uploaded([entry]) }
                    } catch where BackendMirror.outcome(of: error) == .refused {
                        Self.updateActivityQueue(owner) { $0.refused([entry]) }
                        lastError = error.localizedDescription
                    } catch {
                        lastError = error.localizedDescription
                        return
                    }
                }
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    private struct NotificationRow: Encodable {
        let wallet: String, id: String, kind: String, title: String, body: String, read: Bool, data: AppNotification, created_at: String
    }

    private func notifications(_ items: [AppNotification], owner: Address?) {
        guard let owner else { return }
        // Marked, never dropped, while this wallet's restore runs (RS-4): its closing flush sends the store as it is then.
        guard restoring != owner else { Self.setDirty(.notifications, true, owner: owner); return }
        uploadNotifications(items, owner: owner, delay: 2)
    }

    private func uploadNotifications(_ items: [AppNotification], owner: Address, delay: Double) {
        let wallet = owner.checksummed.lowercased()
        let rows = items.prefix(200).map { NotificationRow(wallet: wallet, id: $0.id.uuidString.lowercased(), kind: $0.kind.rawValue, title: $0.title, body: $0.body, read: $0.read, data: $0, created_at: Self.iso($0.time)) }
        schedule(.notifications, owner: owner, delay: delay) { [social] in
            if rows.isEmpty {
                try await social.client.delete("notifications", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
            } else {
                try await social.client.upsertRows("notifications", rows, onConflict: "wallet,id")
            }
        }
    }

    /// A price alert row. Its primary key is the alert's own id (also `client_id`): the table's unique index on
    /// (wallet, client_id) is partial, which `on_conflict` can't name, so the upsert goes by id.
    private struct AlertRow: Encodable {
        let id: String, wallet: String, client_id: String, kind: String, market: String, op: String, threshold: Double, enabled: Bool, payload: PriceAlert
    }

    private func alerts(_ alerts: [PriceAlert], owner: Address) {
        guard restoring != owner else { Self.setDirty(.alerts, true, owner: owner); return }
        uploadAlerts(alerts, owner: owner, delay: 2)
    }

    /// Mirrors the wallet's own alert list (security audit 2026-09-26, RS-7): upsert what the device has, then delete
    /// what it no longer has — so the wallet's alerts are never missing server-side in between, and a failed request
    /// leaves the previous list rather than none.
    private func uploadAlerts(_ alerts: [PriceAlert], owner: Address, delay: Double) {
        let wallet = owner.checksummed.lowercased()
        let rows = alerts.map { alert -> AlertRow in
            let id = alert.id.uuidString.lowercased()
            return AlertRow(id: id, wallet: wallet, client_id: id, kind: "price", market: alert.token.checksummed.lowercased(), op: alert.above ? "above" : "below",
                            threshold: alert.target, enabled: true, payload: alert)
        }
        let prune = BackendMirror.pruneQuery(wallet: wallet, kind: "price", keeping: rows.map(\.client_id))
        schedule(.alerts, owner: owner, delay: delay) { [social] in
            try await social.client.upsertRows("alerts", rows, onConflict: "id")
            try await social.client.delete("alerts", query: prune)
        }
    }

    private struct SettingsRow: Encodable { let wallet: String, data: [String: JSONValue], updated_at: String }

    private func settingsChanged() {
        UserDefaults.standard.set(true, forKey: "settings.touched")
        guard let owner = address() else { return }
        guard restoring != owner else { Self.setDirty(.settings, true, owner: owner); return }
        uploadSettings(owner: owner, delay: 2)
    }

    private func uploadSettings(owner: Address, delay: Double) {
        guard let settings else { return }
        let wallet = owner.checksummed.lowercased()
        let data = settings.snapshot.compactMapValues(JSONValue.init(any:))
        schedule(.settings, owner: owner, delay: delay) { [social] in
            try await social.client.upsertRows("user_settings", [SettingsRow(wallet: wallet, data: data, updated_at: Self.iso(Date()))], onConflict: "wallet")
        }
    }

    // MARK: Restore

    private struct NotificationDown: Decodable { let data: AppNotification }
    private struct AlertDown: Decodable { let payload: PriceAlert }
    private struct SettingsDown: Decodable { let data: [String: JSONValue] }

    /// A fresh device: pulls what the wallet has on the backend into every local store that is still empty, and
    /// merges its activity into the device's (MERA-PLAN §6). Restored rows are checked before they're applied
    /// (`BackendRestore`): they're the wallet's own, but not the app's to trust blindly. A store with changes the
    /// backend hasn't got yet keeps them, and so does one that changes while its rows are read: what arrived meanwhile
    /// is kept and the restored rows are added to it. Then whatever is waiting for this wallet is sent (`flush`).
    func restore(owner: Address) async {
        guard social.isSignedIn else { return }
        let wallet = owner.checksummed.lowercased()
        let dirty = Self.dirty(owner)
        restoring = owner
        defer { if restoring == owner { restoring = nil }; flush(owner: owner) }
        func read<T: Decodable>(_ table: String, _ extra: [URLQueryItem], select: String = "*") async -> [T]? {
            try? await social.client.read(table, query: [URLQueryItem(name: "select", value: select), URLQueryItem(name: "wallet", value: "eq.\(wallet)")] + extra, authed: true)
        }
        // Activity merges even into a log that isn't empty: rows another device recorded join this one's, without
        // doubling any (same id or transaction hash), newest first and capped like the local log.
        let activity: [BackendRestore.ActivityRow]? = await read("activity", [URLQueryItem(name: "order", value: "occurred_at.desc"),
                                                                             URLQueryItem(name: "limit", value: "\(ActivityLog.cap)")],
                                                                select: BackendRestore.activityColumns)
        if let activity {
            let restored = activity.compactMap { BackendRestore.Activity($0) }.map(ActivityRecord.init(restored:))
            if !restored.isEmpty { ActivityLog.merge(restored: restored, owner: owner) }
            backfillActivity(owner: owner, onServer: Set(activity.compactMap { $0.id?.lowercased() }))
        }
        if NotificationStore.all(owner: owner).isEmpty, !dirty.contains(.notifications),
           let list: [NotificationDown] = await read("notifications", [URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "200")]),
           !list.isEmpty {
            let local = NotificationStore.all(owner: owner) // posted while the rows were read: newer, and kept
            let ids = Set(local.map(\.id))
            NotificationStore.save(local + list.map(\.data).filter { !ids.contains($0.id) }, owner: owner)
            NotificationHub.shared.bind(owner: owner)
        }
        if PriceAlertStore.all(owner: owner).isEmpty, !dirty.contains(.alerts),
           let list: [AlertDown] = await read("alerts", [URLQueryItem(name: "kind", value: "eq.price")]), !list.isEmpty {
            let local = PriceAlertStore.all(owner: owner) // added while the rows were read: kept
            let ids = Set(local.map(\.id))
            PriceAlertStore.save(local + list.map(\.payload).filter { !ids.contains($0.id) }, owner: owner)
        }
        if !UserDefaults.standard.bool(forKey: "settings.touched"), let settings,
           let list: [SettingsDown] = await read("user_settings", []), let data = list.first?.data,
           !UserDefaults.standard.bool(forKey: "settings.touched") { // a setting changed while it was read wins
            settings.apply(snapshot: data.mapValues(\.any))
        }
    }

    private static func backfilledKey(_ owner: Address) -> String { "backendSync.activityBackfilled.v1.\(owner.hex)" }

    /// Once per wallet: the records this device holds that the server doesn't (`onServer`: the ids of its newest rows)
    /// join the queue. Builds before the queue sent a record only while the session was up, so anything recorded while
    /// it was down was never uploaded (RS-4); from here on the queue keeps every new record until it is sent.
    private func backfillActivity(owner: Address, onServer: Set<String>) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.backfilledKey(owner)) else { return }
        let missing = ActivityLog.all(owner: owner).map { Self.row($0, owner: owner) }.filter { !onServer.contains($0.id) }
        // Oldest first, so the newest are the last to go past the queue's cap.
        if !missing.isEmpty { Self.updateActivityQueue(owner) { queue in for row in missing.reversed() { queue.enqueue(id: row.id, row: row) } } }
        defaults.set(true, forKey: Self.backfilledKey(owner))
    }

    // MARK: Retry

    /// Sends everything still waiting for `owner` — its queued activity rows, and each store marked for another try
    /// (from its current contents) — once its backend session is up. One flush at a time; wallets asked for meanwhile
    /// follow.
    func flush(owner: Address) {
        if !flushQueue.contains(owner) { flushQueue.append(owner) }
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            while let self, !self.flushQueue.isEmpty {
                let next = self.flushQueue.removeFirst()
                await self.flushOnce(owner: next)
            }
            self?.flushTask = nil
        }
    }

    private func flushOnce(owner: Address) async {
        guard await isConnected(as: owner) else { return }
        for store in Self.dirty(owner) where debounced[store] == nil {
            switch store {
            case .notifications: uploadNotifications(NotificationStore.all(owner: owner), owner: owner, delay: 0)
            case .alerts: uploadAlerts(PriceAlertStore.all(owner: owner), owner: owner, delay: 0)
            case .settings: if address() == owner { uploadSettings(owner: owner, delay: 0) }
            }
        }
        await flushActivity(owner: owner)
    }

    /// Whether the backend session is this wallet's own right now.
    private func isConnected(as owner: Address) async -> Bool {
        guard social.isSignedIn, social.isBound(to: owner) else { return false }
        return await social.client.signedInWallet == owner.checksummed.lowercased()
    }

    // MARK: Plumbing

    /// A store the device mirrors whole.
    private enum Store: String, CaseIterable { case notifications, alerts, settings }

    /// Uploads a store's current contents after `delay`, replacing an upload still waiting. The store stays marked
    /// for another try (`dirty`) until an upload of its latest contents succeeds — including when this one is skipped
    /// because the wallet's session is down.
    private func schedule(_ store: Store, owner: Address, delay: Double, _ work: @escaping @Sendable () async throws -> Void) {
        Self.setDirty(store, true, owner: owner)
        let current = (generation[store] ?? 0) + 1
        generation[store] = current
        debounced[store]?.cancel()
        debounced[store] = Task { @MainActor [weak self] in
            defer { if let self, self.generation[store] == current { self.debounced[store] = nil } }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, await self.isConnected(as: owner) else { return } // retried by `flush`
            do {
                try await work()
                if self.generation[store] == current { Self.setDirty(store, false, owner: owner) }
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    private static func activityQueueKey(_ owner: Address) -> String { "backendSync.activityQueue.v1.\(owner.hex)" }

    private static func activityQueue(_ owner: Address) -> BackendMirrorQueue<ActivityRow> {
        guard let data = UserDefaults.standard.data(forKey: activityQueueKey(owner)),
              let queue = try? JSONDecoder().decode(BackendMirrorQueue<ActivityRow>.self, from: data) else { return BackendMirrorQueue(cap: ActivityLog.cap) }
        return queue
    }

    /// Re-reads the wallet's queue (records may have joined it during an upload), changes it and stores it.
    private static func updateActivityQueue(_ owner: Address, _ change: (inout BackendMirrorQueue<ActivityRow>) -> Void) {
        var queue = activityQueue(owner)
        change(&queue)
        if queue.isEmpty { UserDefaults.standard.removeObject(forKey: activityQueueKey(owner)) }
        else { UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: activityQueueKey(owner)) }
    }

    private static func dirtyKey(_ owner: Address) -> String { "backendSync.dirty.v1.\(owner.hex)" }

    private static func dirty(_ owner: Address) -> Set<Store> {
        Set((UserDefaults.standard.stringArray(forKey: dirtyKey(owner)) ?? []).compactMap(Store.init(rawValue:)))
    }

    private static func setDirty(_ store: Store, _ dirty: Bool, owner: Address) {
        var set = Self.dirty(owner)
        guard dirty ? set.insert(store).inserted : set.remove(store) != nil else { return }
        UserDefaults.standard.set(set.map(\.rawValue).sorted(), forKey: dirtyKey(owner))
    }

    private static let isoFormatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

/// A JSON scalar/collection for `jsonb` columns without a fixed schema (the settings snapshot).
enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init?(any value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let a as [Any]: self = .array(a.compactMap(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.compactMapValues(JSONValue.init(any:)))
        default: return nil
        }
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
