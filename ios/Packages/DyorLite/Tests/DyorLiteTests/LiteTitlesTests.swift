@testable import DyorLite
import StellarKit
import XCTest

/// What the phone writes itself instead of the server's English: transaction and transfer titles (with the server's
/// units per kind, backend _shared/*.ts), asset and venue names, reserves in XLM, addresses in groups of four.
final class LiteTitlesTests: XCTestCase {
    private var saved: Locale!

    override func setUp() {
        saved = LiteL10n.locale
        LiteL10n.locale = Locale(identifier: "en_US")
    }

    override func tearDown() { LiteL10n.locale = saved }

    private func title(_ kind: String, _ display: [String: StellarJSON]? = nil) -> String? {
        LiteTitles.intent(kind: kind, display: display)
    }

    /// The catalog compiled into the bundle (Xcode's build): plurals and other languages resolve only then.
    private var compiled: Bool {
        LiteL10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "fr") != nil
    }

    func testEveryKindTheServerWritesHasATitle() {
        XCTAssertEqual(title("activate"), "Create your Stellar account")
        XCTAssertEqual(title("trust", ["asset": .string("USDC")]), "Enable USDC")
        // A payment's amount is written out by the server (account.ts, fromStroops).
        XCTAssertEqual(title("payment", ["asset": .string("XLM"), "amount": .string("10.5"), "to": .string("GABC"), "memo": .null]), "Send 10.5 XLM")
        // Every other amount is in base units of a 7-decimal asset, shown with at most 4 decimals, as holdings are.
        XCTAssertEqual(title("swap", ["venue": .string("aquarius"), "sell": .string("XLM"), "buy": .string("USDC"),
                                      "amountIn": .string("100000000"), "minOut": .string("229751758")]), "Swap 10 XLM for USDC")
        XCTAssertEqual(title("earn_deposit", ["asset": .string("USDC"), "amount": .string("125000000"), "pool": .string("TestnetV2")]), "Deposit 12.5 USDC to earn")
        XCTAssertEqual(title("earn_withdraw", ["asset": .string("XLM"), "amount": .string("123456789")]), "Withdraw 12.3456 XLM from Earn")
        XCTAssertEqual(title("launch_create", ["symbol": .string("ABC"), "name": .string("Abc"), "quote": .string("XLM"), "initialBuy": .string("0")]), "Launch ABC")
        XCTAssertEqual(title("launch_create", ["symbol": .string("ABC"), "quote": .string("XLM"), "initialBuy": .string("50000000")]), "Launch ABC and buy with 5 XLM")
        XCTAssertEqual(title("launch_buy", ["symbol": .string("ABC"), "quote": .string("XLM"), "amount": .string("20000000"), "minOut": .string("0")]), "Buy ABC with 2 XLM")
        XCTAssertEqual(title("launch_sell", ["symbol": .string("ABC"), "quote": .string("XLM"), "amount": .string("1000000000"), "minOut": .string("0")]), "Sell 100 ABC")
        XCTAssertEqual(title("launch_graduate"), "Move this launch to Soroswap")
        XCTAssertEqual(title("launch_claim"), "Claim your creator fees")
        XCTAssertEqual(title("moment_publish", ["price": .string("10000000"), "quote": .string("USDC"), "editions": .number(100)]), "Publish a Moment at 1 USDC")
        XCTAssertEqual(title("approve", ["amount": .string("50000000"), "spender": .string("Circle CCTP")]), "Allow Circle's bridge to move 5 USDC")
        XCTAssertEqual(title("bridge_out", ["amount": .string("50000000"), "to": .string("0x1234")]), "Send 5 USDC to Monad")
        // Friendbot's one grant (decision 7), by the faucet or by its activation of the account, logged as the same row.
        XCTAssertEqual(title("faucet", ["amount": .string("10000")]), "Funded with Friendbot")
        XCTAssertEqual(title("faucet"), "Funded with Friendbot", "an older row carries no intent: never the bare kind")
    }

    func testAnUnknownKindOrAMissingFieldKeepsTheServersWords() {
        XCTAssertNil(title("blend_borrow", ["asset": .string("USDC")]))
        XCTAssertNil(title("trust"))
        XCTAssertNil(title("payment", ["asset": .string("XLM")]))
        XCTAssertNil(title("swap", ["sell": .string("XLM"), "buy": .string("USDC"), "amountIn": .string("not a number")]))
        XCTAssertNil(title("moment_publish", ["price": .string("10000000"), "quote": .string("")]), "an empty code is missing")
        XCTAssertNil(title("approve", ["amount": .string("1"), "spender": .string("someone else")]), "only Circle's bridge moves USDC alone")
        XCTAssertNil(title("moment_collect", ["quantity": .number(0), "total": .string("1"), "quote": .string("USDC")]))
    }

    func testActivityRowsWordBridgeTransfersThemselvesAndOldCashTransfersNeutrally() throws {
        func item(_ json: String) throws -> StellarActivityItem { try JSONDecoder().decode(StellarActivityItem.self, from: Data(json.utf8)) }
        // A transaction: its intent's display (the server sends it with every tx row).
        let swap = try item(#"{"type":"tx","id":"h","kind":"swap","summary":"Swap 10 XLM for at least 22.9751758 USDC","status":"success","at":"2026-10-13T09:41:00.000Z","display":{"venue":"aquarius","sell":"XLM","buy":"USDC","amountIn":"100000000","minOut":"229751758"}}"#)
        XCTAssertEqual(LiteTitles.activity(swap), "Swap 10 XLM for USDC")
        // A bridge transfer's amount is in base units of the sending side's USDC: 6 decimals on Monad, 7 on Stellar.
        let fromMonad = try item(#"{"type":"bridge","id":"b1","kind":"monad_to_stellar","summary":"Moved USDC from Monad","amount":"12500000","status":"completed","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteTitles.activity(fromMonad), "Move 12.5 USDC from Monad")
        let toMonad = try item(#"{"type":"bridge","id":"b2","kind":"stellar_to_monad","summary":"Sent USDC to Monad","amount":"125000000","status":"attesting","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteTitles.activity(toMonad), "Send 12.5 USDC to Monad")
        let noAmount = try item(#"{"type":"bridge","id":"b3","kind":"stellar_to_monad","summary":"Sent USDC to Monad","amount":"0","status":"failed","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteTitles.activity(noAmount), "Send USDC to Monad")
        // A cash transfer from before cash was removed until mainnet (decision 7): the neutral title, whatever its kind,
        // its asset or the server's words.
        let cash = try item(#"{"type":"cash","id":"c1","kind":"deposit","summary":"Added native","amount":"50","display":{"asset":"native"},"status":"completed","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteTitles.activity(cash), "Transaction")
        let cashOut = try item(#"{"type":"cash","id":"c2","kind":"withdraw","summary":"Cashed out USDC","amount":null,"display":{"asset":"USDC"},"status":"incomplete","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteActivityRow.title(cashOut), "Transaction")
        let older = try item(#"{"type":"cash","id":"c3","kind":"deposit","summary":"Added USDC","amount":null,"status":"incomplete","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertNil(older.display)
        XCTAssertEqual(LiteTitles.activity(older), "Transaction")
        let unknown = try item(#"{"type":"airdrop","id":"x","kind":"drop","summary":"Got a drop","status":"success","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertNil(LiteTitles.activity(unknown), "Activity shows the server's summary")
    }

    /// Today's Activity row: the phone's words, else the server's summary while none of its words is a stand-in, else
    /// "Transaction"; a faucet row (no intent) never shows its bare kind.
    @MainActor
    func testTheActivityRowNeverShowsAStandInOrABareKind() throws {
        func item(_ json: String) throws -> StellarActivityItem { try JSONDecoder().decode(StellarActivityItem.self, from: Data(json.utf8)) }
        let faucet = try item(#"{"type":"tx","id":"f","kind":"faucet","summary":"faucet","status":"success","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteActivityRow.title(faucet), "Funded with Friendbot")
        let unknown = try item(#"{"type":"tx","id":"u","kind":"blend_borrow","summary":"Borrow 5 USDC","status":"success","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteActivityRow.title(unknown), "Borrow 5 USDC")
        let old = try item(#"{"type":"tx","id":"o","kind":"blend_borrow","summary":"Buy TOKEN with 2 XLM","status":"success","at":"2026-10-13T09:41:00.000Z"}"#)
        XCTAssertEqual(LiteActivityRow.title(old), "Transaction")
        XCTAssertNil(LiteFormat.sentence("Swap 1 XLM for $TOKEN."), "a stand-in with marks around it is still one")
        XCTAssertNil(LiteFormat.sentence("  "))
        XCTAssertEqual(LiteFormat.sentence("Tokenomics update"), "Tokenomics update", "only whole words")
    }

    /// The new field never costs the list: an older payload decodes without it, and a display the app can't read only
    /// costs that row its own wording.
    func testActivityItemsDecodeWithAnyDisplay() throws {
        let odd = #"{"items":[{"type":"tx","id":"h","kind":"swap","summary":"Swap","status":"success","at":"2026-10-13T09:41:00.000Z","display":{"route":["a","b"]}}]}"#
        struct R: Decodable { let items: [StellarActivityItem] }
        let items = try JSONDecoder().decode(R.self, from: Data(odd.utf8)).items
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].display)
        XCTAssertNil(LiteTitles.activity(items[0]))
    }

    func testPluralsAndLanguages() throws {
        guard compiled else { throw XCTSkip("the catalog is compiled into the bundle by Xcode's build (xcodebuild), not by swift build") }
        let collect = { (quantity: Double) in
            LiteTitles.intent(kind: "moment_collect", display: ["momentId": .number(7), "quantity": .number(quantity), "total": .string("30000000"), "quote": .string("USDC")])
        }
        XCTAssertEqual(collect(1), "Collect 1 edition for 3 USDC")
        XCTAssertEqual(collect(3), "Collect 3 editions for 3 USDC")

        LiteL10n.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(collect(1), "Collecter 1 édition pour 3 USDC")
        XCTAssertEqual(title("swap", ["sell": .string("XLM"), "buy": .string("USDC"), "amountIn": .string("100000000")]), "Échanger 10 XLM contre USDC")
        XCTAssertEqual(tr("Earn"), "Rendement")

        LiteL10n.locale = Locale(identifier: "es_ES")
        XCTAssertEqual(tr("Earn"), "Rendimientos")
        XCTAssertEqual(LiteTitles.assetName(id: "BUSDC", name: "Blend USDC"), "USDC de prueba de Blend")

        LiteL10n.locale = Locale(identifier: "ko_KR")
        XCTAssertEqual(collect(3), "에디션 3개 수집 (3 USDC)", "values reordered by position")
    }

    func testNamesRowsAndVenuesUse() {
        XCTAssertEqual(LiteTitles.assetName(id: "XLM", name: "Test XLM"), "Stellar Lumens")
        XCTAssertEqual(LiteTitles.assetName(id: "USDC", name: "Circle test USDC (testanchor, CCTP)"), "USD Coin")
        XCTAssertEqual(LiteTitles.assetName(id: "BUSDC", name: "Blend USDC"), "Blend test USDC")
        XCTAssertEqual(LiteTitles.assetName(id: "CABCDEF", name: "Abc Coin"), "Abc Coin", "any other asset: the server's name")
        XCTAssertEqual(LiteTitles.venue("sdex"), "Stellar DEX")
        XCTAssertEqual(LiteTitles.venue("aquarius"), "Aquarius")
        XCTAssertEqual(LiteTitles.venue("soroswap"), "Soroswap")
        XCTAssertEqual(LiteTitles.venue("phoenix"), "Phoenix")
        XCTAssertEqual(LiteTitles.venue("comet"), "Comet")
    }

    /// A settled action's notification (§8.15): Monad's words where Monad has them, past tense, with what it did.
    func testSettledActionsSayWhatHappened() throws {
        let swapped = try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"h","status":"success","result":{"amountOut":"18938032"}}"#.utf8))
        let swap = LiteTitles.settled(.swap(amountIn: 100_000_000, sell: "XLM", buy: "USDC", quotedOut: 18_000_000), results: [swapped])
        XCTAssertEqual(swap.title, "Swap complete")
        XCTAssertEqual(swap.body, "Swapped 10 XLM → 1.8938 USDC", "what came back, not the quote")
        XCTAssertEqual(LiteTitles.settled(.swap(amountIn: 100_000_000, sell: "XLM", buy: "USDC", quotedOut: 18_000_000), results: []).body,
                       "Swapped 10 XLM → 1.8 USDC")
        XCTAssertEqual(LiteTitles.settled(.earn(deposit: true, amount: 125_000_000, code: "USDC"), results: []).title, "Supplied to Earn")
        XCTAssertEqual(LiteTitles.settled(.earn(deposit: false, amount: 125_000_000, code: "USDC"), results: []).body, "12.5 USDC · Blend")
        XCTAssertEqual(LiteTitles.settled(.send(amount: 105_000_000, code: "XLM", to: "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"), results: []).body,
                       "10.5 XLM to GDRX…JUJ6")
        XCTAssertEqual(LiteTitles.settled(.launchTrade(buy: true, symbol: "ECAT", amount: 20_000_000, quoteCode: "XLM"), results: []).title, "Bought ECAT")
        XCTAssertEqual(LiteTitles.settled(.launchCreate(symbol: "ECAT", name: "E Cat"), results: []).title, "Launched $ECAT")
        XCTAssertEqual(LiteTitles.settled(.publish(title: "Sunset"), results: []).title, "Published Sunset")
        XCTAssertEqual(LiteTitles.settled(.launchGraduate(symbol: "ECAT"), results: []).title, "ECAT graduated")
        for summary: LiteActionSummary in [.enable(code: "USDC"), .launchClaim(symbol: "ECAT"), .bridgeOut(amount: 50_000_000),
                                           .collect(title: "Sunset", quantity: 2, total: 20_000_000, quoteCode: "XLM")] {
            XCTAssertFalse(LiteTitles.settled(summary, results: []).title.isEmpty, "\(summary)")
        }
    }

    func testAddressesBreakOnlyBetweenGroupsOfFour() {
        let address = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
        let groups = LiteAddressText.groups(address)
        XCTAssertEqual(groups.count, 14)
        XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
        XCTAssertEqual(groups.joined(), address, "the gaps are only drawn")
        XCTAssertEqual(LiteAddressText.groups("GABCDE"), ["GABC", "DE"])
    }

    /// Steps the server hasn't built yet come with an English label only: the store titles them itself.
    func testUnbuiltStepsGetThePhonesTitles() throws {
        let json = #"{"planId":"p","kind":"swap","expiresAt":"2026-10-13T10:00:00.000Z","steps":[{"id":"s1","label":"Enable USDC","status":"built","intent":{"kind":"trust","summary":"Enable USDC (reserve paid by DyorHQ)","spend":{},"display":{"asset":"USDC"}}},{"id":"s2","label":"Swap via Aquarius","status":"pending"}]}"#
        let plan = try JSONDecoder().decode(PlanView.self, from: Data(json.utf8))
        let titles = LiteStore.unbuilt(plan, main: "Swap 10 XLM for USDC", before: "Enable USDC")
        XCTAssertEqual(titles, ["s2": "Swap 10 XLM for USDC"], "built steps are titled from their intent")
    }
}
