import BigInt
import XCTest
@testable import DyorKit

/// Past-cohort Moment coins are never tradable in the app: past cohorts are claim-only, and a trade on cohort 1's or 2's
/// pool pays the retired platform wallet through its hook. The engine refuses every venue for each of the six coins
/// (cohorts 1–3) on either side before any network call, each venue refuses on its own, and the router calldata builders
/// refuse to encode a route through a retired coin or pool. Kuru Flow's ready-made calldata is refused when it hops through a retired coin or pool, even
/// for an ordinary pair. A normal pair still routes. Network traffic goes to `SwapNetStub`, which records every request.
final class SwapRetiredCoinTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let amount = BigUInt(10).power(18)
    private let deadline = BigUInt(2_000_000_000)

    /// The six pinned coins, as tokens (sorted so failures read the same on every run).
    private var retiredCoins: [Token] {
        MomentsAddresses.retiredMainnetCoins.keys.sorted { $0.hex < $1.hex }.map { Token(address: $0, symbol: "PAST", name: "Past cohort coin", decimals: 18) }
    }

    override func setUp() {
        super.setUp()
        SwapNetStub.reset()
    }

    private func engine() -> SwapEngine {
        let session = SwapNetStub.session()
        return SwapEngine(rpc: RPCClient(url: SwapNetStub.rpcURL, session: session), session: session, moments: V2Fixture.moments)
    }

    /// Every direction a retired coin can take in a trade: bought or sold against USDC, MON or WMON.
    private func pairs(_ coin: Token) -> [(Token, Token)] {
        [(Token.usdc, coin), (coin, Token.usdc), (Token.mon, coin), (coin, Token.mon), (Token.wmon, coin), (coin, Token.wmon)]
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: 50, account: account)
    }

    private func assertClosed(_ error: Error, _ coin: Address, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? SwapError, .tradingClosed(coin), label, file: file, line: line)
    }

    // MARK: Classification

    func testTheSixRetiredCoinsAreNotTradable() {
        XCTAssertEqual(retiredCoins.count, 6)
        XCTAssertTrue(retiredCoins.contains { $0.address == Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF") }, "cohort 3's Nature")
        for coin in retiredCoins {
            XCTAssertFalse(SwapEngine.isTradable(coin), coin.address.hex)
            for (tokenIn, tokenOut) in pairs(coin) {
                XCTAssertEqual(SwapEngine.tradingClosed(tokenIn, tokenOut), .tradingClosed(coin.address), "\(tokenIn.symbol) → \(tokenOut.symbol)")
            }
            let message = SwapError.tradingClosed(coin.address).errorDescription ?? ""
            XCTAssertTrue(message.contains("trading closed"), message)
            XCTAssertTrue(message.contains("retired Moment coin"), message)
        }
        for token in Token.core { XCTAssertTrue(SwapEngine.isTradable(token), token.symbol) }
        XCTAssertNil(SwapEngine.tradingClosed(.mon, .usdc))
        XCTAssertNil(SwapEngine.tradingClosed(.usdc, .mon))
        // A live-cohort coin (any address outside the pinned six) is not caught.
        let liveCoin = Token(address: Address(literal: "0x2222222222222222222222222222222222222222"), symbol: "LIVE", name: "Live coin", decimals: 18)
        XCTAssertNil(SwapEngine.tradingClosed(.usdc, liveCoin))
    }

    /// The pair check `Router.openSwap` and Swap's hand-off use: a retired coin on either side (the other set or not)
    /// opens nothing; an unset side is left alone.
    func testSwapOpensOnlyOnATradablePair() {
        XCTAssertTrue(SwapEngine.isTradablePair(nil, nil))
        XCTAssertTrue(SwapEngine.isTradablePair(.mon, .usdc))
        XCTAssertTrue(SwapEngine.isTradablePair(.usdc, nil))
        XCTAssertTrue(SwapEngine.isTradablePair(nil, .usdc))
        for coin in retiredCoins {
            XCTAssertFalse(SwapEngine.isTradablePair(.usdc, coin), coin.address.hex)
            XCTAssertFalse(SwapEngine.isTradablePair(coin, .mon), coin.address.hex)
            XCTAssertFalse(SwapEngine.isTradablePair(nil, coin), coin.address.hex)
            XCTAssertFalse(SwapEngine.isTradablePair(coin, nil), coin.address.hex)
        }
    }

    // MARK: Engine

    /// Each of the six coins, on either side, against every venue: `quote` throws `tradingClosed` and `quotes`
    /// returns no quote with the reason under every venue — and not one request leaves the device.
    func testEngineRefusesEveryVenueForEveryRetiredCoinWithoutNetwork() async {
        let engine = engine()
        for coin in retiredCoins {
            for (tokenIn, tokenOut) in pairs(coin) {
                let req = request(tokenIn, tokenOut)
                for venue in Venue.allCases {
                    do {
                        let quote = try await engine.quote(venue, for: req)
                        XCTFail("\(venue) quoted \(tokenIn.symbol) → \(tokenOut.symbol): \(String(describing: quote?.route))")
                    } catch {
                        assertClosed(error, coin.address, "\(venue) \(tokenIn.symbol) → \(tokenOut.symbol)")
                    }
                }
                let result = await engine.quotes(for: req)
                XCTAssertTrue(result.quotes.isEmpty, "\(tokenIn.symbol) → \(tokenOut.symbol)")
                XCTAssertNil(result.best)
                XCTAssertEqual(Set(result.errors.keys), Set(SwapEngine.quoteVenues))
                for venue in SwapEngine.quoteVenues {
                    XCTAssertEqual(result.errors[venue], SwapError.tradingClosed(coin.address).errorDescription, "\(venue)")
                }
            }
            // Even a zero amount (which is otherwise just "not quotable") is refused, not silently empty.
            do {
                _ = try await engine.quote(.kuru, for: SwapRequest(tokenIn: .usdc, tokenOut: coin, amountIn: 0, slippageBps: 50, account: account))
                XCTFail("a zero-amount quote for a retired coin must still be refused")
            } catch {
                assertClosed(error, coin.address, "zero amount")
            }
        }
        XCTAssertEqual(SwapNetStub.recorded(), [], "a retired coin must be refused before any venue or RPC is asked")
    }

    /// Each venue refuses by itself too, so no path that skips the engine can quote a retired coin.
    func testEachVenueRefusesOnItsOwnWithoutNetwork() async {
        let session = SwapNetStub.session()
        let multicall = Multicall(rpc: RPCClient(url: SwapNetStub.rpcURL, session: session))
        let v3 = V3Router(multicall: multicall)
        let kuru = KuruFlowClient(session: session)
        let uniswap = UniswapVenue(multicall: multicall, v3: v3, moments: V2Fixture.moments)
        let monday = MondayVenue(v3: v3)
        for coin in retiredCoins {
            for (tokenIn, tokenOut) in pairs(coin) {
                let req = request(tokenIn, tokenOut)
                let label = "\(tokenIn.symbol) → \(tokenOut.symbol)"
                do { _ = try await kuru.quote(req); XCTFail("Kuru Flow quoted \(label)") } catch { assertClosed(error, coin.address, "Kuru Flow \(label)") }
                do { _ = try await uniswap.quote(req); XCTFail("Uniswap quoted \(label)") } catch { assertClosed(error, coin.address, "Uniswap \(label)") }
                do { _ = try await monday.quote(req); XCTFail("Monday quoted \(label)") } catch { assertClosed(error, coin.address, "Monday \(label)") }
            }
        }
        XCTAssertEqual(SwapNetStub.recorded(), [])
    }

    // MARK: Calldata

    /// The router builders refuse a retired coin anywhere on the route — either end or the middle hop — for Uniswap v3
    /// (SwapRouter02), Monday Trade and Uniswap v4 (Universal Router), and a v4 hop through a retired cohort's hook.
    func testRouterCalldataRefusesRetiredCoinsOnEveryVenue() {
        let usdc = Monad.usdc
        for coin in retiredCoins.map(\.address) {
            let key = MomentsAddresses.retiredMainnetCoins[coin]!
            let hook = MomentsAddresses.retired(factory: key.factory)!.hook
            let routes = [
                V3Route(path: [usdc, coin], fees: [500]),
                V3Route(path: [coin, usdc], fees: [500]),
                V3Route(path: [Monad.wmon, coin, usdc], fees: [500, 3000]),
            ]
            for route in routes {
                for nativeIn in [false, true] {
                    XCTAssertThrowsError(try SwapCalldata.swapRouter02(route: route, amountIn: amount, minOut: 1, account: account, nativeIn: nativeIn, nativeOut: false, deadline: deadline)) {
                        assertClosed($0, coin, "SwapRouter02 \(route.path)")
                    }
                    XCTAssertThrowsError(try SwapCalldata.mondaySwap(route: route, amountIn: amount, minOut: 1, account: account, nativeIn: nativeIn, nativeOut: false, deadline: deadline)) {
                        assertClosed($0, coin, "Monday \(route.path)")
                    }
                }
            }
            // The coin's own graduated pool (coin ↔ USDC with its cohort's hook), bought and sold.
            let pool = PoolKey(currency0: BigUInt(usdc.data) < BigUInt(coin.data) ? usdc : coin, currency1: BigUInt(usdc.data) < BigUInt(coin.data) ? coin : usdc,
                               fee: 0, tickSpacing: 60, hooks: hook)
            XCTAssertThrowsError(try SwapCalldata.universalRouterV4(currencyIn: usdc, currencyOut: coin, hops: [V4Hop(key: pool, from: usdc)!], amountIn: amount, minOut: 1, deadline: deadline)) {
                assertClosed($0, coin, "v4 buy")
            }
            XCTAssertThrowsError(try SwapCalldata.universalRouterV4(currencyIn: coin, currencyOut: usdc, hops: [V4Hop(key: pool, from: coin)!], amountIn: amount, minOut: 1, deadline: deadline)) {
                assertClosed($0, coin, "v4 sell")
            }
            // Through the coin as the middle of a two-hop route: MON → coin → USDC.
            let monLeg = PoolKey.canonical(Monad.native, coin, fee: 3000, tickSpacing: 60)
            XCTAssertThrowsError(try SwapCalldata.universalRouterV4(currencyIn: Monad.native, currencyOut: usdc, hops: [V4Hop(key: monLeg, from: Monad.native)!, V4Hop(key: pool, from: coin)!], amountIn: amount, minOut: 1, deadline: deadline)) {
                assertClosed($0, coin, "v4 through the coin")
            }
        }
        // A pool on a retired cohort's hook is refused even between two ordinary currencies.
        for cohort in MomentsAddresses.retiredMainnet {
            let pool = PoolKey(currency0: Monad.native, currency1: Monad.usdc, fee: 0, tickSpacing: 60, hooks: cohort.hook)
            XCTAssertThrowsError(try SwapCalldata.universalRouterV4(currencyIn: Monad.native, currencyOut: Monad.usdc, hops: [V4Hop(key: pool, from: Monad.native)!], amountIn: amount, minOut: 1, deadline: deadline)) {
                assertClosed($0, cohort.hook, "retired hook")
            }
            let message = SwapError.tradingClosed(cohort.hook).errorDescription ?? ""
            XCTAssertTrue(message.contains("retired Moment pool"), message)
        }
    }

    // MARK: Kuru Flow's ready-made calldata

    /// Kuru Flow picks the route itself, so an ordinary MON → USDC trade could still hop through a retired coin's pool
    /// or a pool on a retired hook. Each of the six coins and three hooks, ABI-encoded as a word or raw in a packed
    /// path, gets the quote refused — from the venue and from the engine — while the other venues are still asked.
    func testKuruCalldataThroughARetiredCoinOrPoolIsRefused() async {
        XCTAssertEqual(SwapEngine.retiredAddresses.count, 9, "six coins and three hooks")
        XCTAssertEqual(SwapEngine.retiredHooks, Set(MomentsAddresses.retiredMainnet.map(\.hook)))
        XCTAssertEqual(SwapEngine.retiredHooks.count, 3)
        let engine = engine()
        let kuru = KuruFlowClient(session: SwapNetStub.session())
        let req = request(.mon, .usdc)
        for hit in SwapEngine.retiredAddresses {
            let word = Data(hex: "0x5f3bd1c8")! + Data(count: 12) + hit.data + Data(count: 32)
            let packed = Data(hex: "0xdeadbeef000000000000000000000000000000000000000000000000000000000040")! + Monad.wmon.data + Data([0, 0x0b, 0xb8]) + hit.data + Data([0, 0x01, 0xf4]) + Monad.usdc.data
            for calldata in [word, packed] {
                SwapNetStub.setKuruCalldata(calldata.hexString)
                do { _ = try await kuru.quote(req); XCTFail("Kuru Flow quoted a route through \(hit.hex)") } catch { assertClosed(error, hit, "Kuru Flow venue") }
                do { _ = try await engine.quote(.kuru, for: req); XCTFail("the engine quoted a route through \(hit.hex)") } catch { assertClosed(error, hit, "engine") }
                let result = await engine.quotes(for: req)
                XCTAssertFalse(result.quotes.contains { $0.venue == .kuru }, hit.hex)
                XCTAssertEqual(result.errors[.kuru], SwapError.tradingClosed(hit).errorDescription, hit.hex)
            }
        }
        // The pair itself is ordinary, so it was asked (unlike a retired coin on a side, which never leaves the device).
        XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"))
    }

    /// Kuru Flow's calldata is decoded, not trusted, for every account: a route that pays someone else, trades another
    /// token or amount, or enforces less than the requested slippage allows on the quoted output is blocked at the quote.
    func testKuruCalldataThatDoesntMatchTheRequestIsBlocked() async throws {
        let kuru = KuruFlowClient(session: SwapNetStub.session())
        let req = request(.mon, .usdc)
        let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
        let blocked: [(String, String)] = [
            ("pays another address", SwapNetStub.kuruSwap(recipient: stranger)),
            ("another token out", SwapNetStub.kuruSwap(tokenOut: Monad.wmon)),
            ("another token in", SwapNetStub.kuruSwap(tokenIn: Monad.usdc)),
            ("another amount in", SwapNetStub.kuruSwap(amountIn: 2 * amount)),
            ("a minimum below the requested slippage", SwapNetStub.kuruSwap(minOut: 2_586_999)),
            ("not a Kuru Flow swap", "0xdeadbeef"),
            // The app never asks Kuru for an integrator or referral fee, so any basis points are a skim (IOST-7, as web).
            ("an integrator fee", SwapNetStub.kuruSwap(feeRecipient: stranger, feeBps: 30)),
            ("a referral fee", SwapNetStub.kuruSwap(referrer: stranger, referrerBps: 30)),
            ("a fee on the input side", SwapNetStub.kuruSwap(feeRecipient: stranger, feeBps: 1, feeOnOutput: 0)),
            ("an enormous fee", SwapNetStub.kuruSwap(feeBps: BigUInt(1) << 255)),
            ("a fee flag that isn't a bool", SwapNetStub.kuruSwap(feeOnOutput: 2)),
        ]
        for (name, calldata) in blocked {
            SwapNetStub.setKuruCalldata(calldata)
            do {
                _ = try await kuru.quote(req)
                XCTFail("Kuru Flow quoted calldata that \(name)")
            } catch {
                XCTAssertEqual(error as? SwapError, .venue("Kuru Flow returned an unexpected transaction, so it was blocked for your safety."), name)
            }
        }
        // Paying this account by name is fine, and the minimum shown is the one the calldata enforces.
        SwapNetStub.setKuruCalldata(SwapNetStub.kuruSwap(recipient: account))
        let named = try await kuru.quote(req)
        XCTAssertEqual(named?.minOut, 2_587_000)
        SwapNetStub.setKuruCalldata(SwapNetStub.kuruSwap(minOut: 2_590_000))
        let stricter = try await kuru.quote(req)
        XCTAssertEqual(stricter?.minOut, 2_590_000, "a stricter minimum than the API's own field")
        // A fee recipient or referrer named at 0 bps receives nothing: the addresses aren't pinned (as web).
        SwapNetStub.setKuruCalldata(SwapNetStub.kuruSwap(feeRecipient: stranger, referrer: stranger, feeOnOutput: 1))
        let named0bps = try await kuru.quote(req)
        XCTAssertEqual(named0bps?.venue, .kuru)
    }

    // MARK: A normal pair still routes

    func testNormalPairCalldataStillBuilds() throws {
        let v3 = V3Route(path: [Monad.wmon, Monad.usdc], fees: [500])
        let v3Double = V3Route(path: [Monad.usdc, Monad.weth, Monad.wmon], fees: [500, 3000])
        for route in [v3, v3Double] {
            XCTAssertEqual(try SwapCalldata.swapRouter02(route: route, amountIn: amount, minOut: 1, account: account, nativeIn: false, nativeOut: false, deadline: deadline).to, Uniswap.swapRouter02)
            XCTAssertEqual(try SwapCalldata.mondaySwap(route: route, amountIn: amount, minOut: 1, account: account, nativeIn: false, nativeOut: false, deadline: deadline).to, MondayTrade.swapRouter)
        }
        let canonical = PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10)
        XCTAssertEqual(try SwapCalldata.universalRouterV4(currencyIn: Monad.native, currencyOut: Monad.usdc, hops: [V4Hop(key: canonical, from: Monad.native)!], amountIn: amount, minOut: 1, deadline: deadline).to, Uniswap.universalRouter)
        // A live-cohort Moment pool (the v2 hook; the fixture while the mainnet table is pending) still routes.
        let live = V2Fixture.moments
        let liveCoin = Address(literal: "0xffffffffffffffffffffffffffffffffffffff01")
        let livePool = PoolKey(currency0: live.usdc, currency1: liveCoin, fee: 0, tickSpacing: 60, hooks: live.hook)
        XCTAssertEqual(try SwapCalldata.universalRouterV4(currencyIn: live.usdc, currencyOut: liveCoin, hops: [V4Hop(key: livePool, from: live.usdc)!], amountIn: amount, minOut: 1, deadline: deadline).to, Uniswap.universalRouter)
    }

    /// MON → USDC through the engine: the guard lets it through, Kuru Flow (stubbed) answers, and the plan builds.
    func testNormalPairStillRoutesThroughTheEngine() async throws {
        let engine = engine()
        let req = request(.mon, .usdc)
        let quote = try await engine.quote(.kuru, for: req)
        let kuru = try XCTUnwrap(quote, "Kuru Flow must still quote MON → USDC")
        XCTAssertEqual(kuru.venue, .kuru)
        XCTAssertEqual(kuru.amountOut, SwapNetStub.kuruOutput)
        let steps = try await kuru.build(account)
        XCTAssertEqual(steps.count, 1, "native MON in needs no approval")
        XCTAssertEqual(steps.last?.request?.to, Kuru.entrypoint)
        XCTAssertEqual(steps.last?.request?.value, amount)

        let result = await engine.quotes(for: req)
        XCTAssertEqual(result.best?.venue, .kuru)
        XCTAssertFalse(result.errors.values.contains { $0.contains("trading closed") }, "\(result.errors)")
        XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"), "the normal pair reaches the venue")
    }
}

/// Answers the swap tests' traffic without the network and records every request as `host/path`. RPC calls fail fast
/// with HTTP 400 (no failover, no retry); Kuru Flow issues a token and returns one fixed MON → USDC quote.
final class SwapNetStub: URLProtocol {
    static let rpcURL = URL(string: "https://rpc.swap-stub.invalid")!
    static let kuruOutput = BigUInt(2_600_000)
    /// A real-shaped `0xce1e7030` swap of 1 MON for USDC paying the caller, with the minimum a 0.5% slippage allows on
    /// `kuruOutput` (2,587,000) — what the client's calldata check accepts.
    static let kuruSwapCalldata = kuruSwap()

    /// KuruFlowEntrypoint calldata: `0xce1e7030` (pays the caller), or `0x31343b21` with an explicit `recipient`.
    static func kuruSwap(tokenOut: Address = Monad.usdc, minOut: BigUInt = 2_587_000, tokenIn: Address = .zero,
                             amountIn: BigUInt = BigUInt(10).power(18), recipient: Address? = nil,
                             feeRecipient: Address = .zero, feeBps: BigUInt = 0, referrer: Address = .zero, referrerBps: BigUInt = 0, feeOnOutput: BigUInt = 0) -> String {
        func pad(_ hex: String) -> String { String(repeating: "0", count: 64 - hex.count) + hex }
        func word(_ value: BigUInt) -> String { pad(String(value, radix: 16)) }
        func word(_ address: Address) -> String { pad(address.data.hexString.replacingOccurrences(of: "0x", with: "")) }
        var words = [word(tokenOut), word(minOut), word(tokenIn), word(amountIn),
                     word(feeRecipient), word(feeBps), word(referrer), word(referrerBps), word(feeOnOutput), // the fee tuple
                     word(BigUInt(recipient == nil ? 320 : 352))] // the route's offset
        if let recipient { words.append(word(recipient)) }
        words.append(word(BigUInt(0))) // an empty route
        return (recipient == nil ? "0xce1e7030" : "0x31343b21") + words.joined()
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var kuruCalldata = kuruSwapCalldata

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
        kuruCalldata = kuruSwapCalldata
    }

    /// The calldata Kuru Flow's quote returns (hex, with or without 0x) until the next `reset()`.
    static func setKuruCalldata(_ hex: String) {
        lock.lock(); defer { lock.unlock() }
        kuruCalldata = hex
    }

    static func recorded() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwapNetStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let entry = "\(url.host ?? "")\(url.path)"
        Self.lock.lock(); Self.requests.append(entry); let calldata = Self.kuruCalldata; Self.lock.unlock()
        let status: Int
        let body: String
        if url.host == Kuru.api.host, url.path.hasSuffix("generate-token") {
            status = 200
            body = #"{"token":"stub-token","expires_at":\#(Int(Date().timeIntervalSince1970) + 3600)}"#
        } else if url.host == Kuru.api.host, url.path.hasSuffix("api/quote") {
            status = 200
            body = #"{"status":"success","output":"\#(Self.kuruOutput)","minOut":"2587000","transaction":{"to":"\#(Kuru.entrypoint.checksummed)","calldata":"\#(calldata)","value":"1000000000000000000"}}"#
        } else {
            status = 400
            body = #"{"error":"stubbed"}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
