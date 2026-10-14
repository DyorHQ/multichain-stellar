// The owner's Stellar switch, read by the internal build itself. Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import Foundation
import Observation

/// The owner's switch for the network control: `flags.stellarLite` of the `app_config` row 'ios', the row `UpdateGate`
/// reads for the minimum build and the app's own switches, read the same way (PostgREST, the publishable key alone).
/// Unlike those switches it is OFF unless the row says JSON `true`: a row without it, `1`, `"true"`, any other value, or
/// no read yet leave Stellar hidden (`LiteGate.availability`). Read when the signed-in app appears and on every return
/// to the foreground, at most once every ten minutes, as `UpdateGate.check(client:)` is. A failed read keeps the last
/// value read, which is kept between launches as the app keeps its own switches, so a cold launch on Stellar opens on it
/// instead of on Monad until the read lands. The shared code (`RemoteFlags`, `UpdateGate`, `AppEnvironment`) stays
/// build 23's.
@Observable
@MainActor
final class StellarRemoteFlag {
    static let shared = StellarRemoteFlag()

    /// The row said `"stellarLite": true` the last time it was read (in this launch or an earlier one).
    private(set) var isOn: Bool
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let interval: TimeInterval = 10 * 60
    private static let key = "lite.stellarLite"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.key)
    }

    func check(client: SupabaseClient) async {
        guard !checking else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        guard let rows: [Row] = try? await client.read("app_config", query: [URLQueryItem(name: "key", value: "eq.ios"),
                                                                            URLQueryItem(name: "select", value: "value")]) else { return }
        isOn = rows.first?.value["flags"]["stellarLite"] == .bool(true)
        defaults.set(isOn, forKey: Self.key)
    }

    /// One row of the answer, `[{"value": {...}}]`. `JSON` reads a JSON boolean as `.bool` and nothing else as one: a `1`
    /// is a number and `"true"` a string (JSONDecoder decodes `Bool` from `true` and `false` only), the same rule as
    /// `RemoteFlags`' CFBoolean check, so only a real `true` turns the switch on.
    private struct Row: Decodable, Sendable {
        let value: JSON
    }
}
#endif
