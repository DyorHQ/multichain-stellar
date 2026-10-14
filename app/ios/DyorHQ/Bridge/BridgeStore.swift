import DyorKit
import Foundation

/// A completed cross-chain bridge, kept locally so the Portfolio can count its volume — a bridge moves funds across
/// chains, so the Monad history scan never sees it. Public numbers only; one record per source tx.
struct BridgeRecord: Codable, Identifiable, Hashable {
    let id: String            // the source-chain deposit tx hash
    let usd: Double
    let fromChain: String
    let toChain: String
    let inSymbol: String
    let outSymbol: String
    let time: Date
}

/// Per-wallet persistence of completed bridges (UserDefaults).
enum BridgeStore {
    private static func key(_ owner: Address?) -> String { "bridge.records.v1." + (owner?.checksummed.lowercased() ?? "none") }

    static func all(owner: Address?) -> [BridgeRecord] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([BridgeRecord].self, from: data)) ?? []
    }

    static func record(_ record: BridgeRecord, owner: Address?) {
        var list = all(owner: owner)
        guard !list.contains(where: { $0.id == record.id }) else { return }
        list.insert(record, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(500))), forKey: key(owner))
    }

    /// Takes back a completion recorded before the bridge was refunded or failed (`BridgeTracker`).
    static func remove(id: String, owner: Address?) {
        let list = all(owner: owner)
        guard list.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(list.filter { $0.id != id }), forKey: key(owner))
    }
}
