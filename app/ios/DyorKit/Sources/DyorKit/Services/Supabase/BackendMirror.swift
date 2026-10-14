import Foundation

/// Rows waiting to reach the wallet's backend mirror (security audit 2026-09-26, RS-4). Kept on the device until an
/// upload succeeds, so a record made while the backend session is down — a passkey account before its first
/// ceremony, an expired token, no network — still arrives once the session is back. Bounded: at most `cap` rows (the
/// newest; a row re-queued under the same id replaces its earlier version), and a row the server keeps refusing for a
/// reason of its own (`BackendMirror.Outcome.refused`) is dropped after `maxAttempts` tries.
public struct BackendMirrorQueue<Row: Codable & Sendable>: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let id: String
        public let row: Row
        /// This version of the row: re-queuing the id makes a new one.
        public let version: UUID
        /// Uploads of this row the server refused (not counting outages).
        public var attempts: Int
    }

    public private(set) var entries: [Entry] = []
    public var cap: Int
    public var maxAttempts: Int

    public init(cap: Int, maxAttempts: Int = 3) {
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Queues `row` under `id`, replacing an earlier version of it; the oldest rows go past `cap`.
    public mutating func enqueue(id: String, row: Row) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, row: row, version: UUID(), attempts: 0))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    /// The rows now uploaded. Only the versions that were sent go: a row re-queued while the upload ran stays.
    public mutating func uploaded(_ sent: [Entry]) {
        let versions = Set(sent.map(\.version))
        entries.removeAll { versions.contains($0.version) }
    }

    /// The server refused these rows: each counts one attempt, and a row out of attempts is dropped. A newer version
    /// queued meanwhile starts afresh.
    public mutating func refused(_ sent: [Entry]) {
        let versions = Set(sent.map(\.version))
        for i in entries.indices where versions.contains(entries[i].version) { entries[i].attempts += 1 }
        entries.removeAll { $0.attempts >= maxAttempts }
    }
}

/// How a mirror upload failed, for `BackendMirrorQueue`.
public enum BackendMirror {
    public enum Outcome: Equatable {
        /// Nothing the row did: no session, no network, the server down or busy, the schema not migrated yet
        /// (PostgREST 42P10: no unique constraint matching `on_conflict`), or the wallet's profile row not created yet
        /// (23503: the first rows of a new wallet can race its sign-in's follow-up). Retried later, without limit.
        case unavailable
        /// The server refused the rows themselves (a constraint, row-level security, bad data). Counted per row.
        case refused
    }

    public static func outcome(of error: Error) -> Outcome {
        if error is URLError || error is CancellationError { return .unavailable }
        guard let error = error as? SupabaseError else { return .unavailable }
        switch error {
        case .notSignedIn, .rateLimited: return .unavailable
        case .http(let code, let body):
            if [401, 404, 408, 429].contains(code) || code >= 500 { return .unavailable }
            if code == 400, body.contains("42P10") { return .unavailable }
            if code == 409, body.contains("23503") { return .unavailable }
            return .refused
        case .decoding, .signInRejected: return .unavailable
        }
    }
}

extension BackendMirror {
    /// The PostgREST filter that deletes the wallet's rows of `kind` except those whose `client_id` is in `keeping`
    /// (all of them when it is empty): the second half of mirroring a whole list, after upserting what is kept.
    public static func pruneQuery(wallet: String, kind: String, keeping: [String]) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "wallet", value: "eq.\(wallet)"), URLQueryItem(name: "kind", value: "eq.\(kind)")]
        if !keeping.isEmpty { query.append(URLQueryItem(name: "client_id", value: "not.in.(\(keeping.joined(separator: ",")))")) }
        return query
    }
}
