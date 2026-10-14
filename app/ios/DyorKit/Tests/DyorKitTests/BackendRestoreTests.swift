import XCTest
@testable import DyorKit

/// What a device takes back from the wallet's backend rows (MERA-PLAN §6): settings only as values the screens could
/// have set, activity rows checked field by field and merged into the device's feed without doubling any.
final class BackendRestoreTests: XCTestCase {
    private let appearances: Set<String> = ["system", "light", "dark"]

    // MARK: Settings

    func testAGenuineSnapshotRestoresAsItWas() {
        // As the app uploads it and JSONValue brings it back (whole numbers come back as Int).
        let snapshot: [String: Any] = ["appearance": "dark", "notificationsEnabled": false, "notifyFills": true, "notifyPriceAlerts": true,
                                       "defaultLeverage": 5, "slippageBps": 100]
        XCTAssertEqual(BackendRestore.settings(from: snapshot, appearances: appearances),
                       .init(appearance: "dark", notificationsEnabled: false, notifyFills: true, notifyPriceAlerts: true, defaultLeverage: 5, slippageBps: 100))
        // A leverage stored as a Double restores too, and every offered slippage choice survives.
        XCTAssertEqual(BackendRestore.settings(from: ["defaultLeverage": 12.0], appearances: appearances).defaultLeverage, 12)
        for bps in TradingDefaults.slippageChoicesBps { XCTAssertEqual(BackendRestore.slippageBps(bps), bps) }
        XCTAssertEqual(BackendRestore.leverage(1), 1)
        XCTAssertEqual(BackendRestore.leverage(50), 50)
        // Nothing in the snapshot: nothing changes on the device.
        XCTAssertEqual(BackendRestore.settings(from: [:], appearances: appearances), .init())
    }

    func testAHostileSnapshotCantLoosenATicket() {
        let hostile: [String: Any] = [
            "appearance": "<script>", "notificationsEnabled": "yes", "notifyFills": 1, "notifyPriceAlerts": NSNull(),
            "defaultLeverage": 1_000, "slippageBps": 5_000, "requireBiometrics": false, "extra": ["nested": true],
        ]
        let restored = BackendRestore.settings(from: hostile, appearances: appearances)
        // Trading defaults that are present but not offered come back as the defaults, never the nearest extreme.
        XCTAssertEqual(restored.slippageBps, TradingDefaults.slippageBps)
        XCTAssertEqual(restored.defaultLeverage, TradingDefaults.leverage)
        // Mistyped or unknown values leave the device's own alone; App Lock is never restored at all.
        XCTAssertNil(restored.appearance)
        XCTAssertNil(restored.notificationsEnabled)
        XCTAssertNil(restored.notifyFills, "a number is not a boolean")
        XCTAssertNil(restored.notifyPriceAlerts)

        // Slippage: only the Max Slippage choices, never above 3%.
        for bad: Any in [0, -50, 1, 25, 150, 300, 301, 500, 10_000, Int.max, Int.min, 50.5, Double.nan, Double.infinity, -Double.infinity,
                         1e300, "50", true, false, NSNull(), [50]] {
            XCTAssertEqual(BackendRestore.slippageBps(bad), TradingDefaults.slippageBps, "\(bad)")
        }
        XCTAssertEqual(BackendRestore.slippageBps(nil), TradingDefaults.slippageBps)
        XCTAssertTrue(TradingDefaults.slippageChoicesBps.allSatisfy { $0 <= TradingDefaults.maxRestoredSlippageBps })
        // Leverage: the stepper's whole steps from 1× to 50×.
        for bad: Any in [0, 0.4, -1, 51, 50.6, 1_000, Double.nan, Double.infinity, -Double.infinity, Int.max, "5", true, NSNull(), [5]] {
            XCTAssertEqual(BackendRestore.leverage(bad), TradingDefaults.leverage, "\(bad)")
        }
        XCTAssertEqual(BackendRestore.leverage(2.4), 2, "a fraction rounds to the nearest step")
        XCTAssertEqual(BackendRestore.leverage(49.6), 50)
        // JSONSerialization's numbers and booleans read the same way.
        let decoded = try! JSONSerialization.jsonObject(with: Data(#"{"defaultLeverage":true,"slippageBps":200,"notifyFills":1,"notificationsEnabled":true}"#.utf8)) as! [String: Any]
        XCTAssertEqual(BackendRestore.settings(from: decoded, appearances: appearances),
                       .init(notificationsEnabled: true, defaultLeverage: TradingDefaults.leverage, slippageBps: 200))
    }

    // MARK: Activity rows

    private func row(_ json: String) throws -> BackendRestore.ActivityRow {
        try JSONDecoder().decode(BackendRestore.ActivityRow.self, from: Data(json.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
    private let txHashHex = "0x" + String(repeating: "ab", count: 32)

    func testAGenuineActivityRowRestores() throws {
        let json = #"{"id":"7C4A8D09-CA37-4B3F-9D2E-1B6A5E0F7D11","wallet":"0xabc","kind":"swap","section":"spot","title":"Swapped","subtitle":"1 MON → 0.5 AUSD","tx_hash":"HASH","usd":12.5,"fee_usd":0.1,"occurred_at":"2026-09-20T08:15:30.123456+00:00"}"#
        let activity = try XCTUnwrap(BackendRestore.Activity(try row(json.replacingOccurrences(of: "HASH", with: txHashHex)), now: now))
        XCTAssertEqual(activity.id, UUID(uuidString: "7c4a8d09-ca37-4b3f-9d2e-1b6a5e0f7d11"))
        XCTAssertEqual(activity.kind, "swap")
        XCTAssertEqual(activity.section, "spot")
        XCTAssertEqual(activity.title, "Swapped")
        XCTAssertEqual(activity.subtitle, "1 MON → 0.5 AUSD")
        XCTAssertEqual(activity.txHash, Data(hex: txHashHex))
        XCTAssertEqual(activity.usd, 12.5)
        XCTAssertEqual(activity.feeUsd, 0.1)
        XCTAssertEqual(activity.time.timeIntervalSince1970, 1_789_892_130.123, accuracy: 0.001)
        // Whole seconds, and a row with no hash or dollar size (a perp order), restore too.
        let perp = try XCTUnwrap(BackendRestore.Activity(try row(#"{"id":"00000000-0000-0000-0000-000000000001","kind":"perp","section":"perps","title":"Long BTC","subtitle":null,"tx_hash":null,"usd":null,"fee_usd":null,"occurred_at":"2026-09-20T08:15:30+00:00"}"#), now: now))
        XCTAssertNil(perp.txHash)
        XCTAssertNil(perp.usd)
        XCTAssertEqual(perp.subtitle, "")
    }

    func testAHostileActivityRowIsDroppedOrDefused() throws {
        let base = #"{"id":"ID","kind":"KIND","title":"TITLE","occurred_at":"TIME"}"#
        func make(id: String = "00000000-0000-0000-0000-000000000002", kind: String = "swap", title: String = "Swapped", time: String = "2026-09-20T08:15:30Z") throws -> BackendRestore.Activity? {
            let json = base.replacingOccurrences(of: "ID", with: id).replacingOccurrences(of: "KIND", with: kind)
                .replacingOccurrences(of: "TITLE", with: title).replacingOccurrences(of: "TIME", with: time)
            return BackendRestore.Activity(try row(json), now: now)
        }
        XCTAssertNotNil(try make())
        // Dropped: no UUID id, no kind, a blank title, a time that isn't a timestamp or sits more than ten minutes ahead.
        XCTAssertNil(try make(id: "1; drop table activity"))
        XCTAssertNil(try make(kind: ""))
        XCTAssertNil(try make(kind: String(repeating: "k", count: 41)))
        XCTAssertNil(try make(title: "   "))
        XCTAssertNil(try make(time: "yesterday"))
        XCTAssertNil(try make(time: "9999-12-31T00:00:00Z"), "a far-future row would sit on top of the feed for good")
        XCTAssertNotNil(try make(time: "2026-09-21T12:00:00Z"), "earlier today")
        XCTAssertNotNil(try make(time: "2026-09-21T14:22:20Z"), "nine minutes ahead: another device's clock drift is fine")
        XCTAssertNil(try make(time: "2026-09-21T14:24:20Z"), "eleven minutes ahead")
        XCTAssertNil(try make(time: "2026-09-22T13:13:20Z"), "23 hours ahead: it would sit on top of the feed")
        // A missing or mistyped field makes that one row nil, not the whole read fail.
        let rows = try JSONDecoder().decode([BackendRestore.ActivityRow].self, from: Data(#"[{"id":5,"kind":["swap"],"title":{"x":1},"occurred_at":false,"usd":"lots"},{}]"#.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { BackendRestore.Activity($0, now: now) == nil })

        // Defused, the row kept: text cut to the upload's lengths, a hash that isn't 32 bytes and bad dollar sizes dropped.
        let long = #"{"id":"00000000-0000-0000-0000-000000000003","kind":"swap","section":"SECTION","title":"TITLE","subtitle":"SUB","tx_hash":"0xdead","usd":-5,"fee_usd":"1","occurred_at":"2026-09-20T08:15:30Z"}"#
            .replacingOccurrences(of: "TITLE", with: String(repeating: "t", count: 500))
            .replacingOccurrences(of: "SUB", with: String(repeating: "s", count: 5_000))
            .replacingOccurrences(of: "SECTION", with: String(repeating: "x", count: 41))
        let defused = try XCTUnwrap(BackendRestore.Activity(try row(long), now: now))
        XCTAssertEqual(defused.title.count, 120)
        XCTAssertEqual(defused.subtitle.count, 300)
        XCTAssertNil(defused.section)
        XCTAssertNil(defused.txHash)
        XCTAssertNil(defused.usd)
        XCTAssertNil(defused.feeUsd)
    }

    // MARK: Merge

    private struct Record: Equatable {
        let id: UUID
        let hash: Data?
        let time: Date
        var note = ""
    }

    private func merge(_ local: [Record], _ restored: [Record], cap: Int = 300) -> [Record] {
        BackendRestore.mergeActivity(local: local, restored: restored, cap: cap, id: \.id, txHash: \.hash, time: \.time)
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testRestoredActivityMergesWithoutDoublingAnything() {
        let h1 = Data(repeating: 1, count: 32), h2 = Data(repeating: 2, count: 32)
        // On the device: a swap (random id) and a perp order (no hash), recorded here.
        let swap = Record(id: UUID(), hash: h1, time: at(-10), note: "local")
        let perp = Record(id: UUID(), hash: nil, time: at(-5), note: "local")
        // On the backend: the same swap under the id it keys hashes by, the same perp order under its own id, and a
        // launch recorded on another device.
        let swapRow = Record(id: UUID(), hash: h1, time: at(-10), note: "backend")
        let perpRow = Record(id: perp.id, hash: nil, time: at(-5), note: "backend")
        let launch = Record(id: UUID(), hash: h2, time: at(-20), note: "backend")

        let merged = merge([perp, swap], [swapRow, launch, perpRow])
        XCTAssertEqual(merged, [perp, swap, launch], "newest first; the device's own copy of a row wins")
        // Merging the same rows again changes nothing.
        XCTAssertEqual(merge(merged, [swapRow, launch, perpRow]), merged)
        // A fresh device (nothing local) takes the backend rows, newest first, each once.
        XCTAssertEqual(merge([], [launch, swapRow, perpRow, launch]), [perpRow, swapRow, launch])
        // Nothing restored: the device's log as it was.
        XCTAssertEqual(merge([perp, swap], []), [perp, swap])
    }

    func testRestoredRowsOnlyFillTheRoomLeft() {
        let local = (0..<5).map { Record(id: UUID(), hash: nil, time: at(Double(-$0 * 2)), note: "local") }        // 0, -2, -4, -6, -8
        let restored = (0..<5).map { Record(id: UUID(), hash: nil, time: at(Double(-$0 * 2 - 1)), note: "backend") } // -1, -3, -5, -7, -9
        // Room for two: the two newest restored rows join every local one.
        XCTAssertEqual(merge(local, restored, cap: 7).map(\.time), [at(0), at(-1), at(-2), at(-3), at(-4), at(-6), at(-8)])
        // No room: the device's log as it was, however new the restored rows.
        XCTAssertEqual(merge(local, restored, cap: 5), local)
        XCTAssertEqual(merge(local, restored, cap: 4), local, "never fewer than the device's own")
        XCTAssertEqual(merge(local, restored, cap: 0), local)
        // A flood of rows dated newer than anything local (someone holding the backend session) can't evict one.
        let flood = (0..<400).map { _ in Record(id: UUID(), hash: nil, time: at(5), note: "backend") }
        let flooded = merge(local, flood, cap: 300)
        XCTAssertEqual(flooded.count, 300)
        XCTAssertEqual(flooded.filter { $0.note == "local" }, local, "every local row kept")
        // Equal times keep the device's rows first.
        let tie = Record(id: UUID(), hash: nil, time: at(0), note: "backend")
        XCTAssertEqual(merge([local[0]], [tie]), [local[0], tie])
    }
}
