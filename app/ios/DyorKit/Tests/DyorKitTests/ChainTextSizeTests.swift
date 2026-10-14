import BigInt
import XCTest
@testable import DyorKit

/// Text a creator chose can be as long as a transaction can store: about 44 KB of a launch's description, 20 KB of a
/// Moment's name, 40 KB of its media link. Monad refuses an `eth_call` whose answer is longer than about 4.1 MB (the
/// stub's `responseCap`, here half that), so a list of such items is read in small chunks, a chunk that fails is read again one item at
/// a time, and an item whose text can't be read even on its own keeps its place with stand-ins — except a Moment's name,
/// which gives its link: that one fails the lookup, so no slug ever moves. Uses service calls only, so the same file
/// shows what earlier builds answered.
final class ChainTextSizeTests: XCTestCase {
    /// Half Monad's limit, as the stub's cap: a chunk of maximum-length items stays well under the real one.
    static let cap = 2_000_000

    // MARK: Launches

    func testABoardOfLaunchesWithMaximumLengthTextLists() async throws {
        let chain = SizedLaunchpad(count: 50, description: 44_000)
        MomentsChainStub.install({ chain.answer($0, $1) }, responseCap: Self.cap)
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: SizedLaunchpad.live)
        let listed = try await service.launches(limit: 200)
        XCTAssertEqual(listed.count, 50, "every launch")
        XCTAssertTrue(listed.allSatisfy { $0.description.utf8.count == 44_000 }, "every description in full")
        let all = try await service.allLaunches(limit: 200)
        XCTAssertEqual(all.count, 50)
        let largest = MomentsChainStub.batches().map(\.count).max() ?? 0
        XCTAssertLessThan(largest, 50 * 9, "the launches are read in chunks, not in one read")
    }

    func testALaunchWhoseTextCantBeReadEvenAloneKeepsItsPlace() async throws {
        let chain = SizedLaunchpad(count: 30, description: 1_000, giant: 5, giantDescription: Self.cap + 1)
        MomentsChainStub.install({ chain.answer($0, $1) }, responseCap: Self.cap)
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: SizedLaunchpad.live)
        let listed = try await service.launches(limit: 200)
        XCTAssertEqual(listed.count, 30, "every launch, the one whose text can't be read too")
        let giant = try XCTUnwrap(listed.first { $0.token == SizedLaunchpad.token(5) })
        XCTAssertEqual([giant.name, giant.symbol, giant.description], ["\u{FFFD}", "\u{FFFD}", ""])
        XCTAssertEqual(giant.price, 7, "its numbers are read")
        XCTAssertEqual(listed.first { $0.token == SizedLaunchpad.token(6) }?.description.utf8.count, 1_000, "the others' text is read")
    }

    // MARK: Moments

    func testAFeedOfMomentsWithMaximumLengthTextLists() async throws {
        let chain = SizedMoments(count: 60, name: 20_000, media: 20_000)
        MomentsChainStub.install({ chain.answer($0, $1) }, responseCap: Self.cap)
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: chain.stack.addresses)
        let listed = try await service.moments(limit: 200)
        XCTAssertEqual(listed.count, 60, "every Moment")
        XCTAssertTrue(listed.allSatisfy { $0.name.utf8.count >= 20_000 && $0.provenance.mediaURI.utf8.count == 20_000 }, "every name and link in full")
    }

    /// Name links over 110 Moments with 20 KB names: every name is read (in chunks), each Moment gets the slug its name and
    /// the publish order give it, and a lookup never falls back to a stand-in name.
    func testNameLinksOverMaximumLengthNamesResolve() async throws {
        let chain = SizedMoments(count: 110, name: 20_000, media: 10)
        MomentsChainStub.install({ chain.answer($0, $1) }, responseCap: Self.cap)
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: [.c4])
        let factory = chain.stack.addresses.factory
        let expected = MomentSlug.assign(chain.stack.names.enumerated().map { (key: MomentKey(factory: factory, id: BigUInt($0.offset + 1)), name: $0.element) })
        for id in [1, 80, 110] {
            let key = MomentKey(factory: factory, id: BigUInt(id))
            let link = try await directory.link(for: key)
            XCTAssertEqual(link, MomentLink(name: try XCTUnwrap(expected[key])), "Moment \(id)")
            let found = try await directory.key(for: try XCTUnwrap(expected[key]))
            XCTAssertEqual(found, key)
        }
    }

    /// A name that can't be read even on its own fails the lookup (Retry): a stand-in would give that Moment, and every
    /// later one with the same name, another slug.
    func testANameThatCantBeReadEvenAloneFailsTheLookupAndMovesNoSlug() async throws {
        var chain = SizedMoments(count: 5, name: 100, media: 10)
        chain.giantName = 3
        MomentsChainStub.install({ [chain] in chain.answer($0, $1) }, responseCap: Self.cap)
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: [.c4])
        let factory = chain.stack.addresses.factory
        do {
            let link = try await directory.link(for: MomentKey(factory: factory, id: 4))
            XCTFail("a lookup answered \(String(describing: link)) without every name before it")
        } catch {}
    }
}

/// `count` launches on the v2 fixture launchpad, each description `description` bytes of ASCII; launch `giant` (0-based)
/// has a description of `giantDescription` bytes, more than an `eth_call` may answer even alone. Retired stacks launched
/// nothing.
struct SizedLaunchpad: Sendable {
    static let live = V2Fixture.launchpad
    let count: Int
    private let info: Data
    private let giant: Int?
    private let giantInfo: Data

    init(count: Int, description: Int, giant: Int? = nil, giantDescription: Int = 0) {
        self.count = count
        self.giant = giant
        info = Self.tokenInfo(description)
        giantInfo = giant == nil ? Data() : Self.tokenInfo(giantDescription)
    }

    private static func tokenInfo(_ length: Int) -> Data {
        try! ABI.encode([.address(.zero), .string(""), .string(String(repeating: "d", count: length)), .tuple(Array(repeating: .string(""), count: 5))],
                        "address,string,string,(string,string,string,string,string)")
    }

    static func token(_ i: Int) -> Address { Address(data: Data(count: 16) + Data([0xa2, UInt8(i >> 8), UInt8(i & 0xff), 0x00]))! }
    static func curve(_ i: Int) -> Address { Address(data: Data(count: 16) + Data([0xa2, UInt8(i >> 8), UInt8(i & 0xff), 0xc0]))! }

    /// The launch index of a token or curve address, and whether it is the curve.
    private func index(_ address: Address) -> (Int, Bool)? {
        let d = address.data
        guard d.prefix(16).allSatisfy({ $0 == 0 }), d[d.startIndex + 16] == 0xa2 else { return nil }
        let i = Int(d[d.startIndex + 17]) << 8 | Int(d[d.startIndex + 18])
        guard i < count else { return nil }
        switch d[d.startIndex + 19] {
        case 0x00: return (i, false)
        case 0xc0: return (i, true)
        default: return nil
        }
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ s: String) -> Bool { selector == ABI.selector(s) }
        func enc(_ v: [ABIValue], _ t: String) -> Data { try! ABI.encode(v, t) }
        typealias F = LaunchpadABI.Factory
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        let words = data.dropFirst(4)
        func word(_ n: Int) -> Data { Data(words.dropFirst(32 * n).prefix(32)) }
        if to == Self.live.factory {
            if is_(F.launchCount) { return enc([.uint(count)], "uint256") }
            if is_(F.getLaunches) {
                let offset = Int(BigUInt(word(0))), n = Int(BigUInt(word(1)))
                return enc([.array((offset ..< min(count, offset + n)).map { .address(Self.token($0)) })], "address[]")
            }
            if is_(F.getLaunchedToken), let arg = Address(data: word(0).suffix(20)), let (i, isCurve) = index(arg), !isCurve {
                let fields: [ABIValue] = [.address(arg), .address(Self.curve(i)), .address(.zero), .address(.zero), .address(.zero), .uint(BigUInt(10).power(21)), .uint(0),
                                          .uint(100), .int(60), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(true)]
                return enc([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: false))
            }
            return nil
        }
        if LaunchpadAddresses.retiredStacks.contains(where: { $0.factory == to }) {
            return is_(F.launchCount) ? enc([.uint(0)], "uint256") : nil
        }
        guard let (i, isCurve) = index(to) else { return nil }
        if isCurve {
            if is_(C.price) { return enc([.uint(7)], "uint256") }
            if is_(C.getReserves) { return enc([.uint(7), .uint(BigUInt(10).power(18))], "uint256,uint256") }
            if is_(C.completed) || is_(C.rescued) { return enc([.bool(false)], "bool") }
            if is_(C.launchedAt) { return enc([.uint(1_789_000_000)], "uint64") }
            return enc([.uint(1)], "uint256")
        }
        if is_(T.name) { return enc([.string("Coin \(i)")], "string") }
        if is_(T.symbol) { return enc([.string("C\(i)")], "string") }
        if is_(T.getTokenInfo) { return i == giant ? giantInfo : info }
        if is_(T.totalSupply) { return enc([.uint(BigUInt(10).power(27))], "uint256") }
        return nil
    }
}

/// `count` Moments on cohort 4's addresses (`FakeMomentsStack`), each name `name` bytes ("Moment <id> " and x's) and each
/// media link `media` bytes; Moment `giantName` has a name longer than an `eth_call` may answer even alone.
struct SizedMoments: Sendable {
    let stack: FakeMomentsStack
    private let provenance: Data
    var giantName: Int?

    init(count: Int, name: Int, media: Int) {
        let names = (1...count).map { id in
            let head = "Moment \(id) "
            return head + String(repeating: "x", count: max(0, name - head.utf8.count))
        }
        stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                 nftBase: MomentsAddresses.expectedExternalBaseURI, names: names)
        provenance = try! ABI.encode([.tuple([.string(String(repeating: "m", count: media)), .bytes(Data(count: 32)), .string("Accra"), .uint(0), .string("")])], MomentsABI.provenanceTuple)
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        if selector == ABI.selector(MomentsABI.NFT.provenance), (1...stack.names.count).contains(where: { stack.nft($0) == to }) { return provenance }
        if let giantName, to == stack.coin(giantName), selector == ABI.selector(MomentsABI.Coin.name) {
            return try! ABI.encode([.string(String(repeating: "g", count: ChainTextSizeTests.cap + 1))], "string")
        }
        return stack.answer(to, data)
    }
}
