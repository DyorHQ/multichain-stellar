import BigInt
import XCTest
@testable import DyorKit

/// A list read either answers for every item or says it couldn't read: an item that exists but whose protocol reads
/// fail — as when a read reaches a node a block behind the one that listed the item, where the coin or NFT has no code
/// yet — is an error, never a shorter list, "not found" or "no Moment at this link". Only text an item's creator chose
/// may fail on its own, and then the item stays with stand-ins (`ChainText.unreadable`). Everything here uses service
/// calls only, so the same file shows what earlier builds answered.
final class ChainReadHonestyTests: XCTestCase {
    /// Cohort 4's addresses with two Moments, "Plain" and "Fresh".
    private static let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                                nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Plain", "Fresh"])

    private func throwsError<T>(_ label: String, _ body: () async throws -> T) async {
        do {
            let value = try await body()
            XCTFail("\(label) answered \(String(describing: value)) instead of throwing")
        } catch {}
    }

    // MARK: Moments

    /// Moment 2 is counted and its record reads, but its NFT answers nothing (no code at the block that was read): every
    /// reader of it throws. Its link must say "Couldn't open this Moment" (Retry), not "No Moment at this link".
    func testAMomentWhoseProtocolReadsFailIsAnErrorNotMissing() async throws {
        let stack = Self.stack
        MomentsChainStub.install { to, data in
            if to == stack.nft(2) { return Data() }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        await throwsError("moments()") { try await service.moments().map(\.id) }
        await throwsError("info(id: 2)") { try await service.info(id: 2).map(\.id) }
        await throwsError("moment(id: 2)") { try await service.moment(id: 2).map(\.info.id) }
        await throwsError("infos(ids: [1, 2])") { try await service.infos(ids: [1, 2]).map(\.id) }
        let one = try await service.info(id: 1)
        XCTAssertEqual(one?.name, "Plain", "a Moment whose reads answer still opens")
        let past = try await service.info(id: 3)
        XCTAssertNil(past, "an id past the count is no Moment")
    }

    /// Moment 2's coin answers nothing for its name and symbol: the Moment keeps its place in the feed with stand-ins, and
    /// its link opens it.
    func testAMomentWhoseTextCantBeReadKeepsItsPlace() async throws {
        let stack = Self.stack
        MomentsChainStub.install { to, data in
            if to == stack.coin(2) { return Data() }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let listed = try await service.moments()
        XCTAssertEqual(listed.map(\.id), [2, 1])
        XCTAssertEqual(listed.first?.name, "\u{FFFD}")
        XCTAssertEqual(listed.first?.symbol, "\u{FFFD}")
        XCTAssertEqual(listed.first?.editions, 1, "the Moment's numbers are read as usual")
        let opened = try await service.info(id: 2)
        XCTAssertEqual(opened?.key, MomentKey(factory: stack.addresses.factory, id: 2))
        let infos = try await service.infos(ids: [1, 2])
        XCTAssertEqual(infos.map(\.id), [1, 2])
    }

    // MARK: Launches

    /// The factory lists two coins; the second's record comes back empty (the record read reached a node that hasn't seen
    /// that launch): the Launch board says it couldn't read, never shows the first coin alone.
    func testALaunchWhoseRecordIsNotThereYetIsAnError() async throws {
        let chain = HonestyLaunchpad(recorded: [HonestyLaunchpad.alpha])
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        await throwsError("launches()") { try await service.launches().map(\.name) }
    }

    /// The second coin's curve refuses `price()`: its page throws, never "not found", and the board throws too.
    func testALaunchWhosePriceCantBeReadIsAnErrorNotNotFound() async throws {
        var chain = HonestyLaunchpad()
        chain.priceFails = true
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        await throwsError("launch(token: beta)") { try await service.launch(token: HonestyLaunchpad.beta).map(\.launch.name) }
        await throwsError("launches()") { try await service.launches().map(\.name) }
        let alpha = try await service.launch(token: HonestyLaunchpad.alpha)
        XCTAssertEqual(alpha?.launch.name, "Alpha")
        let stranger = try await service.launch(token: Address(literal: "0x00000000000000000000000000000000000beef0"))
        XCTAssertNil(stranger, "a coin the factory never launched is not found")
    }

    /// The second coin answers nothing for its name, symbol and token info: it keeps its place on the board with stand-ins
    /// and its numbers, and its page opens.
    func testALaunchWhoseTextCantBeReadKeepsItsPlace() async throws {
        var chain = HonestyLaunchpad()
        chain.textFails = true
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        let listed = try await service.launches()
        XCTAssertEqual(listed.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha])
        XCTAssertEqual(listed.first?.name, "\u{FFFD}")
        XCTAssertEqual(listed.first?.symbol, "\u{FFFD}")
        XCTAssertEqual(listed.first?.description, "")
        XCTAssertEqual(listed.first?.price, 7, "the launch's numbers are read as usual")
        let page = try await service.launch(token: HonestyLaunchpad.beta)
        XCTAssertEqual(page?.launch.token, HonestyLaunchpad.beta)
    }

    /// The live launchpad can't be read while a retired one lists a coin: the board with every launchpad throws, never a
    /// board of retired coins alone that looks like the live launchpad has none.
    func testALiveLaunchpadThatCantBeReadIsAnErrorNotARetiredOnlyBoard() async throws {
        var chain = HonestyLaunchpad()
        chain.liveFails = true
        chain.retiredCoin = HonestyLaunchpad.old
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        await throwsError("allLaunches()") { try await service.allLaunches().map(\.name) }
        await throwsError("launches()") { try await service.launches().map(\.name) }
    }
}

/// Two launches on the v2 fixture launchpad, "Alpha" then "Beta". `recorded` are the coins the factory's record read
/// knows (a node that hasn't seen the newest launch answers an empty record for it); `priceFails` makes Beta's curve
/// refuse `price()`, `textFails` makes Beta's token answer nothing for its text; `liveFails` makes the live factory
/// refuse `launchCount()`; `shortPage` makes its `getLaunches` answer one coin fewer than its count (a node behind);
/// `longText` gives that coin a description longer than the device keeps (`ChainSettled.maxKeptText`). The newest retired
/// stack lists `retiredCoin` ("Old") when set; the others launched nothing.
struct HonestyLaunchpad: Sendable {
    static let live = V2Fixture.launchpad
    static let alpha = Address(literal: "0x0000000000000000000000000000000000a1a100")
    static let beta = Address(literal: "0x0000000000000000000000000000000000a1a200")
    static func curve(_ token: Address) -> Address { Address(data: token.data.prefix(19) + Data([0xc0]))! }

    var recorded: Set<Address> = [alpha, beta]
    var priceFails = false
    var textFails = false
    var liveFails = false
    var shortPage = false
    var longText: Address?
    var retiredCoin: Address?
    static let old = Address(literal: "0x0000000000000000000000000000000000a1a300")

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ s: String) -> Bool { selector == ABI.selector(s) }
        func enc(_ v: [ABIValue], _ t: String) -> Data { try! ABI.encode(v, t) }
        typealias F = LaunchpadABI.Factory
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        let arg = data.count >= 36 ? Address(data: data.dropFirst(4).prefix(32).suffix(20)) : nil
        // `getLaunches(offset, limit)` as the factory answers it: the page of its list from `offset`, at most `limit` long.
        func page(_ list: [Address]) -> Data {
            let words = data.dropFirst(4)
            let offset = Int(clamping: BigUInt(words.prefix(32)))
            let limit = min(list.count, Int(clamping: BigUInt(words.dropFirst(32).prefix(32))))
            let slice = offset < list.count ? Array(list[offset ..< min(list.count, offset + limit)]) : []
            return enc([.array(slice.map { .address($0) })], "address[]")
        }
        if to == Self.live.factory {
            if is_(F.launchCount) { return liveFails ? nil : enc([.uint(2)], "uint256") }
            if is_(F.getLaunches) { return page(shortPage ? [Self.alpha] : [Self.alpha, Self.beta]) }
            if is_(F.getLaunchedToken), let arg {
                let exists = recorded.contains(arg)
                let fields: [ABIValue] = [.address(exists ? arg : .zero), .address(exists ? Self.curve(arg) : .zero), .address(.zero), .address(.zero), .address(.zero),
                                          .uint(exists ? BigUInt(10).power(21) : 0), .uint(0), .uint(100), .int(60), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0),
                                          .uint(0), .bytes(Data(count: 32)), .bool(exists)]
                return enc([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: false))
            }
            if is_(F.stuckSince) { return enc([.uint(0)], "uint256") }
            if is_(F.poolKeyOf) { return enc([.tuple([.address(.zero), .address(arg ?? .zero), .uint(0), .int(60), .address(Self.live.hook)])], "(address,address,uint24,int24,address)") }
            return nil
        }
        if let retired = LaunchpadAddresses.retiredStacks.first(where: { $0.factory == to }) {
            let lists = retired.factory == LaunchpadAddresses.retiredStacks.first?.factory ? retiredCoin : nil
            if is_(F.launchCount) { return enc([.uint(lists == nil ? 0 : 1)], "uint256") }
            if is_(F.getLaunches), let lists { return page([lists]) }
            if is_(F.getLaunchedToken) {
                let exists = lists != nil && arg == lists
                var fields: [ABIValue] = [.address(exists ? lists! : .zero), .address(exists ? Self.curve(lists!) : .zero), .address(.zero), .address(.zero), .address(.zero),
                                          .uint(exists ? BigUInt(10).power(21) : 0), .uint(0), .uint(0), .int(0),
                                          .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
                if retired.generation.legacyRecord { fields.remove(at: 10) }
                return enc([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: retired.generation.legacyRecord))
            }
            return nil
        }
        for (token, name) in [(Self.alpha, "Alpha"), (Self.beta, "Beta"), (Self.old, "Old")] {
            if to == token {
                if token == Self.beta, textFails, is_(T.name) || is_(T.symbol) || is_(T.getTokenInfo) { return Data() }
                if is_(T.name) { return enc([.string(name)], "string") }
                if is_(T.symbol) { return enc([.string(String(name.prefix(1)))], "string") }
                if is_(T.getTokenInfo) {
                    let about = token == longText ? String(repeating: "a", count: ChainSettled.maxKeptText + 1) : "About \(name)"
                    return enc([.address(.zero), .string(""), .string(about), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,(string,string,string,string,string)")
                }
                if is_(T.totalSupply) { return enc([.uint(BigUInt(10).power(27))], "uint256") }
            }
            if to == Self.curve(token) {
                if is_(C.price) { return token == Self.beta && priceFails ? nil : enc([.uint(7)], "uint256") }
                if is_(C.completed) || is_(C.rescued) || is_(C.swept) { return enc([.bool(false)], "bool") }
                if is_(C.launchedAt) { return enc([.uint(1_789_000_000)], "uint64") }
                if is_(C.feeBps) { return enc([.uint(100)], "uint16") }
                if is_(C.snipeTaxSchedule) { return enc([.array([])], "uint16[]") }
                if is_(C.getReserves) { return enc([.uint(1), .uint(2)], "uint256,uint256") }
                return enc([.uint(1)], "uint256")
            }
        }
        if to == .zero { return Data() } // no code at address 0
        return nil
    }
}
