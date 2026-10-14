import Foundation

/// The oldest iOS build the backend still supports (security audit 2026-09-26, GP-2): the public, read-only
/// `app_config` row 'ios', `{"min_build": 15, "message": "…", "url": "https://…"}` (supabase migration 28). A build whose
/// CFBundleVersion is below `minBuild` shows "Update required": balances and key export stay reachable, and nothing
/// signs. The app fails open — a row it can't read or parse blocks nothing — so a broken row can never lock anyone out
/// of their funds.
public struct MinimumBuild: Equatable, Sendable {
    /// The lowest CFBundleVersion still supported; 0 blocks nothing.
    public let minBuild: Int
    /// The owner's text for the Update screen, trimmed; empty for the app's own.
    public let message: String
    /// Where to get the update: an https URL, or nil when the row has none the app would open.
    public let url: URL?

    public init(minBuild: Int, message: String, url: URL?) {
        self.minBuild = minBuild
        self.message = message
        self.url = url
    }

    /// PostgREST's answer to `app_config?key=eq.ios&select=value`: `[{"value": {...}}]`. Nil for anything else — no
    /// row, a missing or mistyped field, a negative or fractional build — which the caller treats as "nothing blocked".
    public static func parse(_ data: Data) -> MinimumBuild? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 1,
              let value = rows[0]["value"] as? [String: Any],
              let number = value["min_build"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 1_000_000_000, double.rounded() == double else { return nil }
        let message = (value["message"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) } ?? ""
        let url = (value["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" && $0.host() != nil ? $0 : nil }
        return MinimumBuild(minBuild: Int(double), message: message, url: url)
    }

    /// Whether `bundleVersion` (CFBundleVersion) is older than the minimum. False — nothing blocked — when it isn't a
    /// whole number.
    public func requiresUpdate(bundleVersion: String?) -> Bool {
        guard let text = bundleVersion?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }),
              let build = Int(text) else { return false }
        return build < minBuild
    }
}
