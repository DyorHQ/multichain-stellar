import XCTest
@testable import DyorKit

/// The server's wallet-history cache reads exactly the app's scans (`WalletHistoryScans`): the canonical
/// `supabase/functions/_shared/history-scans.json`, which migration 32 seeds into `history_scans` and the
/// history-indexer reads, must name the same events, contracts, wallet topic and floors. A cohort, a stack or an event
/// changed on one side only fails here (and in supabase/tests/history_cache_test.ts for the SQL seed, and in the
/// history-indexer's run-start check against the production rows, reported as `defsDrift`).
final class HistoryScanParityTests: XCTestCase {
    private struct Spec: Decodable {
        struct Window: Decodable { let days: Double; let secondsPerBlock: Double; let blocks: UInt64 }
        struct Event: Decodable { let signature: String; let topic: String }
        struct Scan: Decodable { let id: String; let kind: String; let walletTopic: Int; let floor: UInt64; let addresses: [String]; let events: [Event] }
        let version: Int
        let appTransferWindow: Window
        let scans: [Scan]
    }

    private func spec() throws -> Spec {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → the repository
        let file = root.appendingPathComponent("supabase/functions/_shared/history-scans.json")
        // supabase/ is always in this repository: a missing file is a rename or a move, and must fail, never skip.
        guard FileManager.default.fileExists(atPath: file.path) else {
            XCTFail("\(file.path) is missing: the server's scan definitions moved; update this test with them")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Spec.self, from: Data(contentsOf: file))
    }

    func testTheServerReadsExactlyTheAppScans() throws {
        let spec = try spec()
        XCTAssertEqual(spec.version, 1)
        let wallet = Address(literal: "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47")
        let walletWord = wallet.data.leftPadded(to: 32)
        // What the release build passes (AppEnvironment: launchpad.stacks, and [config.moments] + the retired cohorts).
        let scans = [
            WalletHistoryScans.launchpad(wallet: wallet),
            WalletHistoryScans.feeSharing(wallet: wallet, stacks: DyorCoinRegistry.launchpads(live: .monadMainnet)),
            WalletHistoryScans.moments(wallet: wallet, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet)),
            WalletHistoryScans.transfersOut(wallet: wallet),
            WalletHistoryScans.transfersIn(wallet: wallet),
        ]
        let app = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
        XCTAssertEqual(Set(spec.scans.map(\.id)), Set(WalletHistoryScans.ids))
        XCTAssertEqual(spec.scans.count, WalletHistoryScans.ids.count)
        for server in spec.scans {
            let mine = try XCTUnwrap(app[server.id], server.id)
            for event in server.events {
                XCTAssertEqual(ABI.eventTopic(event.signature).hexString, event.topic, "\(server.id): \(event.signature)")
            }
            let topic0 = try XCTUnwrap(mine.query.topics.first ?? nil, server.id)
            XCTAssertEqual(Set(topic0.map(\.hexString)), Set(server.events.map(\.topic)), server.id)
            XCTAssertEqual(topic0.count, server.events.count, "\(server.id): an event listed twice")
            XCTAssertEqual(mine.query.topics.count, server.walletTopic + 1, server.id)
            for position in 1..<mine.query.topics.count {
                let expected: [Data]? = position == server.walletTopic ? [walletWord] : nil
                XCTAssertEqual(mine.query.topics[position], expected, "\(server.id) topic \(position)")
            }
            XCTAssertEqual(Set(mine.query.addresses.map { $0.hex.lowercased() }), Set(server.addresses), server.id)
            XCTAssertEqual(mine.query.addresses.count, server.addresses.count, "\(server.id): an address listed twice")
            switch server.kind {
            case "global":
                XCTAssertEqual(mine.floor, .block(server.floor), server.id)
            case "wallet":
                XCTAssertEqual(server.floor, 0, "\(server.id): the server reads wallet scans from genesis")
                XCTAssertEqual(mine.floor, .blocks(spec.appTransferWindow.blocks), server.id)
            default:
                XCTFail("\(server.id): unknown kind \(server.kind)")
            }
        }
        XCTAssertEqual(spec.appTransferWindow.days * 86_400, WalletHistoryScans.transferDays)
        XCTAssertEqual(spec.appTransferWindow.secondsPerBlock, BlockClock.fallbackSecondsPerBlock)
        XCTAssertEqual(spec.appTransferWindow.blocks, WalletHistoryScans.transferBlocks)
    }
}
