import BigInt
import CoreText
import XCTest
@testable import DyorKit

/// A creator's text can't rearrange the app's text around it. The Launch ticket's balance line puts the coin's symbol
/// before the pair balance ("Balance: 1.2K PEPE · 10.5 MON"): a symbol carrying U+202E (right-to-left override) used to
/// show that as "… PEPE NOM 5.01 ·", and a right-to-left symbol ("אבג") as "Balance: 1.2K 10.5 · גבא MON". Laid out with
/// CoreText, the line reads in its own order. Uses service calls only, so the same file shows what earlier builds
/// answered.
final class ChainTextBidiTests: XCTestCase {
    /// `text` in the order CoreText draws it, left to right, on one line. Format characters (an isolate, an override)
    /// draw nothing, so they are left out.
    static func visual(_ text: String) -> String {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        let units = Array(text.utf16)
        var drawn: [(x: CGFloat, index: Int)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (index, position) in zip(indices, positions) { drawn.append((position.x, index)) }
        }
        return drawn.sorted { $0.x < $1.x }
            .filter { Unicode.Scalar(units[$0.index])?.properties.generalCategory != .format }
            .map { String(utf16CodeUnits: [units[$0.index]], count: 1) }.joined()
    }

    func testTheLayoutCheckSeesAnOverride() {
        let line = "Balance: 1.2K PEPE\u{202E} · 10.5 MON"
        XCTAssertNotEqual(Self.visual(line), "Balance: 1.2K PEPE · 10.5 MON", "an override reverses what follows it")
        XCTAssertEqual(Self.visual("Balance: 1.2K PEPE · 10.5 MON"), "Balance: 1.2K PEPE · 10.5 MON")
    }

    /// Without an isolate, right-to-left text takes the app's numbers after it into its own direction, and turns a line
    /// it leads right to left: what the tests below would see if the service didn't isolate it.
    func testTheLayoutCheckSeesRightToLeftTextCarryTheNumbers() {
        XCTAssertEqual(Self.visual("Balance: 1.2K אבג · 10.5 MON"), "Balance: 1.2K 10.5 · גבא MON")
        XCTAssertEqual(Self.visual("1.2M ب1 · 5 MON"), "1.2M 5 · 1ب MON")
        XCTAssertEqual(Self.visual("שלום ($M1)"), ")M1$( םולש")
    }

    func testALaunchSymbolCantReorderTheTicketsBalanceLine() async throws {
        let launch = try await listedLaunch(name: "Pepe\u{2067}", symbol: "PEPE\u{202E}", description: "\u{202E}gm")
        let balance = "Balance: 1.2K \(launch.symbol) · 10.5 MON"
        XCTAssertEqual(Self.visual(balance), "Balance: 1.2K PEPE · 10.5 MON", "the line reads in its own order")
        let title = "Buy \(launch.name) for 10.5 MON"
        XCTAssertEqual(Self.visual(title), "Buy Pepe for 10.5 MON")
        XCTAssertEqual(launch.description, "gm")
    }

    /// A right-to-left symbol, Hebrew or Arabic, draws its own letters right to left and leaves the app's numbers where
    /// they are: in the ticket's balance line and in a Recent Activity trade ("1.2M אבג · 5 MON").
    func testARightToLeftSymbolCantReorderTheNumbersAroundIt() async throws {
        for (symbol, drawn) in [("אבג", "גבא"), ("ب1", "1ب")] {
            let launch = try await listedLaunch(name: "Pepe", symbol: symbol)
            XCTAssertEqual(Self.visual("Balance: 1.2K \(launch.symbol) · 10.5 MON"), "Balance: 1.2K \(drawn) · 10.5 MON", "the ticket's balance line, \(symbol)")
            XCTAssertEqual(Self.visual("1.2M \(launch.symbol) · 5 MON"), "1.2M \(drawn) · 5 MON", "a Recent Activity trade, \(symbol)")
        }
    }

    /// A right-to-left name the same, where the app puts one in a line: after a number, and leading a line (an unverified
    /// coin's name and address, a Moment's name and symbol), which it used to turn right to left.
    func testARightToLeftNameCantReorderTheLineItIsIn() async throws {
        let launch = try await listedLaunch(name: "שלום עולם", symbol: "PEPE")
        XCTAssertEqual(Self.visual("Balance: 1.2K \(launch.name) · 10.5 MON"), "Balance: 1.2K םלוע םולש · 10.5 MON")
        XCTAssertEqual(Self.visual("1.2M \(launch.name) · 5 MON"), "1.2M םלוע םולש · 5 MON")
        XCTAssertEqual(Self.visual("\(launch.name) · \(launch.token.short)"), "םלוע םולש · \(launch.token.short)")

        let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["שלום"])
        MomentsChainStub.install { to, data in stack.answer(to, data) }
        let moments = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses).moments()
        let moment = try XCTUnwrap(moments.first)
        XCTAssertEqual(Self.visual("\(moment.name) ($\(moment.symbol))"), "םולש ($M1)")
        XCTAssertEqual(Self.visual("Bought 5 \(moment.name) · 10.5 USDC"), "Bought 5 םולש · 10.5 USDC")
    }

    /// The live launchpad listing one coin with `name`, `symbol` and `description`, as `launches()` reads it.
    private func listedLaunch(name: String, symbol: String, description: String = "") async throws -> Launch {
        let token = Address(literal: "0x0000000000000000000000000000000000a1b100")
        let curve = Address(literal: "0x0000000000000000000000000000000000a1b1c0")
        let live = V2Fixture.launchpad
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            func is_(_ s: String) -> Bool { selector == ABI.selector(s) }
            func enc(_ v: [ABIValue], _ t: String) -> Data { try! ABI.encode(v, t) }
            typealias F = LaunchpadABI.Factory
            if to == live.factory {
                if is_(F.launchCount) { return enc([.uint(1)], "uint256") }
                if is_(F.getLaunches) { return enc([.array([.address(token)])], "address[]") }
                if is_(F.getLaunchedToken) {
                    let fields: [ABIValue] = [.address(token), .address(curve), .address(.zero), .address(.zero), .address(.zero), .uint(BigUInt(10).power(21)), .uint(0), .uint(100),
                                              .int(60), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(true)]
                    return enc([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: false))
                }
                return nil
            }
            if LaunchpadAddresses.retiredStacks.contains(where: { $0.factory == to }) { return is_(F.launchCount) ? enc([.uint(0)], "uint256") : nil }
            if to == token {
                if is_(LaunchpadABI.Token.name) { return enc([.string(name)], "string") }
                if is_(LaunchpadABI.Token.symbol) { return enc([.string(symbol)], "string") }
                if is_(LaunchpadABI.Token.getTokenInfo) {
                    return enc([.address(.zero), .string(""), .string(description), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,(string,string,string,string,string)")
                }
                if is_(LaunchpadABI.Token.totalSupply) { return enc([.uint(BigUInt(10).power(27))], "uint256") }
            }
            if to == curve {
                if is_(LaunchpadABI.Curve.completed) || is_(LaunchpadABI.Curve.rescued) { return enc([.bool(false)], "bool") }
                if is_(LaunchpadABI.Curve.getReserves) { return enc([.uint(1), .uint(BigUInt(10).power(18))], "uint256,uint256") }
                return enc([.uint(1)], "uint256")
            }
            return nil
        }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: live)
        let listed = try await service.launches()
        return try XCTUnwrap(listed.first)
    }
}
