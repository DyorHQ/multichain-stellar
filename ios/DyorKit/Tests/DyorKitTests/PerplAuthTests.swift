import BigInt
import CryptoKit
import XCTest
@testable import DyorKit

final class PerplAuthTests: XCTestCase {
    private func btc() -> PerpMarket {
        PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                   mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                   fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
    }

    // MARK: Encodings

    func testBase64urlNoPadding() {
        XCTAssertEqual(PerplAuth.base64url(Data([0xfb, 0xff, 0xbf])), "-_-_")           // + / → - _
        XCTAssertEqual(PerplAuth.base64url(Data([0x01])), "AQ")                          // no '=' padding
        XCTAssertFalse(PerplAuth.base64url(Data([0x00, 0x00])).contains("="))
    }

    func testRestCanonical() {
        let canonical = PerplAuth.restCanonical(chainId: 143, method: "GET", target: "/v1/trading/fills?count=1", timestamp: "1700000000000", nonce: "abc", body: "")
        // sha256("") = e3b0c442...
        XCTAssertEqual(canonical, "143\nGET\n/v1/trading/fills?count=1\n1700000000000\nabc\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testWsSigninCanonical() {
        XCTAssertEqual(PerplAuth.wsSigninCanonical(chainId: 143, timestamp: "1700000000000", nonce: "xyz"), "143\ntrading-ws-signin\n1700000000000\nxyz")
    }

    func testEd25519SignVerifyAndPublicKey() throws {
        let secret = PerplAuth.newSecret()
        XCTAssertEqual(secret.count, 32)
        let pubHex = try PerplAuth.publicKeyHex(secret: secret)
        XCTAssertTrue(pubHex.hasPrefix("0x"))
        XCTAssertEqual(pubHex.count, 2 + 64)

        let message = Data("perpl".utf8)
        let sigB64 = try PerplAuth.sign(message, secret: secret)
        // Decode base64url back and verify with CryptoKit
        var b64 = sigB64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let sig = Data(base64Encoded: b64)!
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hex: pubHex)!)
        XCTAssertTrue(pub.isValidSignature(sig, for: message))

        // proof-of-possession over a 32-byte digest verifies too
        let digest = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let pop = try PerplAuth.proofOfPossession(digest: digest, secret: secret)
        XCTAssertTrue(pub.isValidSignature(Data(hex: pop)!, for: digest))
    }

    // MARK: Order frames

    func testMarketEntryFrame() {
        let input = OrderInput(market: btc(), side: .long, kind: .market, size: 0.1, leverage: 10, slippageBps: 50)
        let frame = PerplOrders.entry(input, accountId: 5001, head: 12345678).json(rq: 1024, sn: 1)
        XCTAssertEqual(frame["mt"] as? Int, 22)
        XCTAssertEqual(frame["t"] as? Int, 1)          // OpenLong wire
        XCTAssertEqual(frame["p"] as? Int, 0)          // market
        XCTAssertEqual(frame["s"] as? Int, 10000)      // 0.1 * 10^5
        XCTAssertEqual(frame["ms"] as? Int, 50)
        XCTAssertEqual(frame["fl"] as? Int, 4)         // IOC
        XCTAssertEqual(frame["lv"] as? Int, 1000)      // 10x
        // `lb:0` on purpose, not `head + 100`: Perpl substitutes the market's own `order_ttl_blocks` window. A
        // computed `head + ttl` from the RPC head (which runs ahead of Perpl's) overshot that ceiling and every
        // entry was rejected with `last exec block too high` (b828fad). `head` no longer affects the frame.
        XCTAssertEqual(frame["lb"] as? Int, 0)
        XCTAssertNil(frame["tp"])
    }

    func testLimitEntryShortFrame() {
        let input = OrderInput(market: btc(), side: .short, kind: .limit, size: 0.1, price: 95000, leverage: 5)
        let frame = PerplOrders.entry(input, accountId: 5001, head: 100).json(rq: 2, sn: 2)
        XCTAssertEqual(frame["t"] as? Int, 2)          // OpenShort
        XCTAssertEqual(frame["p"] as? Int, 950000)     // 95000 * 10^1
        XCTAssertEqual(frame["fl"] as? Int, 0)         // GTC
        XCTAssertNil(frame["ms"])
        XCTAssertEqual(frame["lv"] as? Int, 500)
    }

    func testTakeProfitAndStopLossLong() {
        let tp = PerplOrders.takeProfit(side: .long, price: 110000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 42).json(rq: 3, sn: 3)
        XCTAssertEqual(tp["t"] as? Int, 3)             // CloseLong
        XCTAssertEqual(tp["p"] as? Int, 0)             // market on trigger
        XCTAssertEqual(tp["tp"] as? Int, 1100000)      // 110000 * 10^1
        XCTAssertEqual(tp["tpc"] as? Int, 1)           // GTELast
        XCTAssertEqual(tp["lp"] as? Int, 42)
        XCTAssertEqual(tp["fl"] as? Int, 4)            // IOC
        XCTAssertEqual(tp["lv"] as? Int, 0)
        XCTAssertEqual(tp["lb"] as? Int, 0)            // triggers require lb:0

        let sl = PerplOrders.stopLoss(side: .long, price: 90000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 42).json(rq: 4, sn: 4)
        XCTAssertEqual(sl["t"] as? Int, 3)
        XCTAssertEqual(sl["tp"] as? Int, 900000)
        XCTAssertEqual(sl["tpc"] as? Int, 4)           // LTEMark
        XCTAssertEqual(sl["lb"] as? Int, 0)
    }

    func testStopLossShortUsesMarkGte() {
        let sl = PerplOrders.stopLoss(side: .short, price: 100000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 7).json(rq: 5, sn: 5)
        XCTAssertEqual(sl["t"] as? Int, 4)             // CloseShort
        XCTAssertEqual(sl["tpc"] as? Int, 3)           // GTEMark
    }

    func testCancelFrame() {
        let cancel = PerplOrders.cancel(perpId: 1, orderId: 778899, accountId: 5001, head: 100).json(rq: 6, sn: 6)
        XCTAssertEqual(cancel["t"] as? Int, 5)         // Cancel
        XCTAssertEqual(cancel["oid"] as? Int, 778899)
        XCTAssertEqual(cancel["s"] as? Int, 0)
        XCTAssertEqual(cancel["lv"] as? Int, 0)
    }

    /// Add margin over the trading connection (p4 spec A.1): an IncreasePositionCollateral request (`t: 6`) whose `a` is
    /// the amount in 6-decimal units, written as a decimal string; nothing an order carries.
    func testAddMarginFrame() {
        let frame = PerplOrders.addMargin(perpId: 1, amountCNS: 25_000_000, accountId: 5001)
        XCTAssertNil(PerplOrders.problem(frame))
        let json = frame.json(rq: 7, sn: 7)
        XCTAssertEqual(json["mt"] as? Int, 22)
        XCTAssertEqual(json["t"] as? Int, 6)
        XCTAssertEqual(json["a"] as? String, "25000000", "a decimal string, never a number")
        XCTAssertEqual(json["s"] as? Int, 0)
        XCTAssertEqual(json["p"] as? Int, 0)
        XCTAssertEqual(json["lv"] as? Int, 0)
        XCTAssertEqual(json["fl"] as? Int, 0)
        XCTAssertEqual(json["lb"] as? Int, 0)
        XCTAssertEqual(json["acc"] as? Int, 5001)
        XCTAssertEqual(json["mkt"] as? Int, 1)
        for key in ["oid", "ms", "tp", "tpc", "tr", "lp"] { XCTAssertNil(json[key], key) }
        // Every other frame carries no `a`.
        XCTAssertNil(PerplOrders.cancel(perpId: 1, orderId: 3, accountId: 5001, head: 0).json(rq: 1, sn: 1)["a"])
        // An amount that rounds to nothing never leaves the device.
        XCTAssertEqual(PerplOrders.problem(PerplOrders.addMargin(perpId: 1, amountCNS: 0, accountId: 5001)), "The margin amount rounds to zero.")
        var none = frame
        none.amountCNS = nil
        XCTAssertEqual(PerplOrders.problem(none), "The margin amount rounds to zero.")
    }

    /// A close over the trading connection is the same reduce-only order the wallet's close signs (p4 spec A.1): CloseLong
    /// for a long, CloseShort for a short, at the position's leverage, a market close at 1% (`fl` 4) or a resting limit.
    func testCloseFrames() {
        let long = PerpPosition(perpId: 1, symbol: "BTC", side: .long, size: 0.002, entry: 80000, mark: 81650, margin: 32, unrealized: 0, premium: 0,
                                leverage: 5, liquidation: nil, notional: 0)
        let market = PerplService.closeInput(market: btc(), position: long, size: 0.0005, slippageBps: 100)
        XCTAssertTrue(market.reduceOnly)
        let frame = PerplOrders.entry(market, accountId: 5001, head: 0).json(rq: 9, sn: 9)
        XCTAssertEqual(frame["t"] as? Int, 3, "CloseLong")
        XCTAssertEqual(frame["p"] as? Int, 0)
        XCTAssertEqual(frame["ms"] as? Int, 100)
        XCTAssertEqual(frame["fl"] as? Int, 4)
        XCTAssertEqual(frame["s"] as? Int, 50)
        XCTAssertEqual(frame["lv"] as? Int, 500)
        XCTAssertEqual(frame["lb"] as? Int, 0)
        for key in ["oid", "tp", "tpc", "tr", "lp", "a"] { XCTAssertNil(frame[key], key) }

        let short = PerpPosition(perpId: 1, symbol: "BTC", side: .short, size: 0.002, entry: 80000, mark: 81650, margin: 32, unrealized: 0, premium: 0,
                                 leverage: 5, liquidation: nil, notional: 0)
        XCTAssertEqual(PerplOrders.entry(PerplService.closeInput(market: btc(), position: short, size: 0.002, slippageBps: 100), accountId: 5001, head: 0)
                        .json(rq: 1, sn: 1)["t"] as? Int, 4, "CloseShort")

        let limit = PerplOrders.entry(PerplService.closeInput(market: btc(), position: long, size: 0.002, slippageBps: 100, kind: .limit, limitPrice: 82000, postOnly: true),
                                      accountId: 5001, head: 0).json(rq: 2, sn: 2)
        XCTAssertEqual(limit["t"] as? Int, 3)
        XCTAssertEqual(limit["fl"] as? Int, 1, "post-only")
        XCTAssertEqual(limit["p"] as? Int, 820000)
        XCTAssertNil(limit["ms"])
        XCTAssertEqual(limit["s"] as? Int, 200)
    }
}
