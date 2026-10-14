import BigInt
import XCTest
@testable import DyorKit

/// Text read from the chain is whatever bytes its writer chose: a launch's name, symbol, logo, description and links are
/// its creator's, a Moment's coin name, symbol and provenance too, and so is any token's or collection's text. Bytes that
/// aren't valid UTF-8 read as U+FFFD (`ABI.StringDecoding.lossy`), and a list never fails, or loses an item, for text it
/// can't read: the item shows stand-ins (`ChainText.unreadable`). A protocol value that can't be read fails the read
/// (`ChainListUnread`), never shortens the list. Text is written here as `bytes`, whose ABI layout is `string`'s.
final class ChainTextTests: XCTestCase {
    /// Ill-formed UTF-8: a lone continuation byte, overlong encodings, truncated sequences, a UTF-16 surrogate, a code
    /// point past U+10FFFF, and bytes that never occur in UTF-8.
    static let illFormed: [(name: String, bytes: [UInt8])] = [
        ("lone continuation", [0x80]),
        ("continuations", [0xbf, 0x80, 0xbf]),
        ("overlong slash", [0xc0, 0xaf]),
        ("overlong NUL", [0xc0, 0x80]),
        ("overlong three-byte", [0xe0, 0x80, 0xaf]),
        ("truncated two-byte", [0xc3]),
        ("truncated three-byte", [0xe2, 0x82]),
        ("truncated four-byte", [0xf0, 0x9f, 0x98]),
        ("surrogate", [0xed, 0xa0, 0x80]),
        ("past U+10FFFF", [0xf4, 0x90, 0x80, 0x80]),
        ("ff fe", [0xff, 0xfe]),
        ("ff fe fd fc", [0xff, 0xfe, 0xfd, 0xfc]),
    ]

    /// "A", the ill-formed bytes, "Z".
    static func text(_ bad: [UInt8]) -> Data { Data([0x41] + bad + [0x5a]) }

    /// The return data of a `string` getter answering `bytes`.
    static func stringReturn(_ bytes: Data) -> Data { try! ABI.encode([.bytes(bytes)], "bytes") }

    /// "A", only U+FFFD, "Z": what `text` reads as.
    static func isReplaced(_ value: String) -> Bool {
        value.count > 2 && value.hasPrefix("A") && value.hasSuffix("Z") && value.dropFirst().dropLast().allSatisfy { $0 == "\u{FFFD}" }
    }

    // MARK: ABI

    func testIllFormedTextReadsAsReplacementCharactersAndStrictRefusesIt() throws {
        for (name, bad) in Self.illFormed {
            let data = Self.stringReturn(Self.text(bad))
            let value = try ABI.decode(data, "string")[0].string
            XCTAssertTrue(Self.isReplaced(value), "\(name): \(value.debugDescription)")
            XCTAssertThrowsError(try ABI.decode(data, "string", strings: .strict), name) { XCTAssertEqual($0 as? ABIError, .invalidUTF8) }
        }
        // Unicode's maximal-subpart rule: a truncated sequence is one U+FFFD, a byte that can't start one is one each.
        XCTAssertEqual(try ABI.decode(Self.stringReturn(Self.text([0xf0, 0x9f, 0x98])), "string")[0].string, "A\u{FFFD}Z")
        XCTAssertEqual(try ABI.decode(Self.stringReturn(Self.text([0xff, 0xfe, 0xfd, 0xfc])), "string")[0].string, "A\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}Z")
    }

    func testIllFormedTextInsideTuplesAndArraysReadsAndTheRestIsIntact() throws {
        let bad = Self.text([0xff, 0xfe])
        let data = try ABI.encode([.tuple([.bytes(bad), .uint(7), .array([.bytes(Data("ok".utf8)), .bytes(bad)])]), .bytes(bad), .address(Monad.usdc)],
                                  "(bytes,uint256,bytes[]),bytes,address")
        let types = "(string,uint256,string[]),string,address"
        let values = try ABI.decode(data, types)
        XCTAssertEqual(values[0][0].string, "A\u{FFFD}\u{FFFD}Z")
        XCTAssertEqual(values[0][1].uint, 7)
        XCTAssertEqual(values[0][2].elements.map(\.string), ["ok", "A\u{FFFD}\u{FFFD}Z"])
        XCTAssertEqual(values[1].string, "A\u{FFFD}\u{FFFD}Z")
        XCTAssertEqual(values[2].address, Monad.usdc)
        XCTAssertThrowsError(try ABI.decode(data, types, strings: .strict)) { XCTAssertEqual($0 as? ABIError, .invalidUTF8) }
    }

    func testWellFormedTextReadsTheSameEitherWay() throws {
        for text in ["", "Nature", "Café 🔥", "日本語", "A\u{0}B", "\u{FFFD} kept", "https://dyorhq.fun/moments/c4/"] {
            let data = try ABI.encode([.string(text)], "string")
            XCTAssertEqual(try ABI.decode(data, "string")[0].string, text)
            XCTAssertEqual(try ABI.decode(data, "string", strings: .strict)[0].string, text)
        }
    }

    // MARK: Tokens, collections, revert reasons

    func testTokenTextAndRevertReasonsReadWithReplacementCharacters() async throws {
        let token = Address(literal: "0x000000000000000000000000000000000000beef")
        let bad = Self.text([0xc0, 0xaf])
        MomentsChainStub.install { to, data in
            guard to == token else { return nil }
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return Self.stringReturn(bad) }
            if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(6)], "uint8") }
            return nil
        }
        let multicall = Multicall(rpc: MomentsChainStub.rpc())
        let read = try await multicall.read([try ERC20.name(token), try ContractCall(to: token, "name()", returns: "string", strings: .strict)])
        XCTAssertEqual(try read[0].get()[0].string, "A\u{FFFD}\u{FFFD}Z")
        XCTAssertThrowsError(try read[1].get()) { XCTAssertEqual($0 as? ABIError, .invalidUTF8) }

        let added = try await ERC20.metadata(token, multicall: multicall)
        XCTAssertEqual(added?.symbol, "A\u{FFFD}\u{FFFD}Z")
        XCTAssertEqual(added?.decimals, 6)
        let batch = await ERC20.metadataBatch([token], multicall: multicall)
        XCTAssertEqual(batch.map(\.name), ["A\u{FFFD}\u{FFFD}Z"])
        let held = await WalletTokenDiscovery.metadata([token], multicall: multicall)
        XCTAssertEqual(held.tokens.map(\.symbol), ["A\u{FFFD}\u{FFFD}Z"])
        XCTAssertTrue(held.complete)

        let payload = "0x08c379a0" + Self.stringReturn(bad).hexString.dropFirst(2) // Error(string)
        XCTAssertEqual(RevertReason.describe(RPCError(code: 3, message: "execution reverted", data: payload)), "A\u{FFFD}\u{FFFD}Z")
    }

    // MARK: Launchpad

    func testALaunchWithIllFormedTextListsAndOneWhoseTextCantBeReadShowsStandIns() async throws {
        typealias C = TextLaunchpadChain
        MomentsChainStub.install { C(failing: .text).answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: C.live)

        let launches = try await service.launches()
        XCTAssertEqual(launches.map(\.token), [C.broken, C.poisoned, C.plain], "newest first; every launch the factory lists")
        let plain = try XCTUnwrap(launches.last)
        XCTAssertEqual([plain.name, plain.symbol, plain.logo, plain.description, plain.socials.website], ["Plain Coin", "PLAIN", "https://example.com/plain.png", "Plain", "https://example.com"])
        let poisoned = launches[1]
        let fields = [poisoned.name, poisoned.symbol, poisoned.logo, poisoned.description,
                      poisoned.socials.twitter, poisoned.socials.telegram, poisoned.socials.discord, poisoned.socials.website, poisoned.socials.farcaster]
        XCTAssertEqual(fields.count, C.poisonedText.count)
        for (field, raw) in zip(fields, C.poisonedText) {
            XCTAssertTrue(Self.isReplaced(field), "\(raw.hexString) read as \(field.debugDescription)")
        }
        XCTAssertEqual(poisoned.price, 1_000, "the numbers of a launch with ill-formed text are read as usual")
        let unreadable = try XCTUnwrap(launches.first)
        XCTAssertEqual([unreadable.name, unreadable.symbol], [ChainText.unreadable, ChainText.unreadable])
        XCTAssertEqual([unreadable.logo, unreadable.description, unreadable.socials.website], ["", "", ""])
        XCTAssertEqual(unreadable.price, 1_000, "the numbers of a launch whose text can't be read are read as usual")

        let all = try await service.allLaunches()
        XCTAssertEqual(all.map(\.token), [C.broken, C.poisoned, C.plain])
        let detail = try await service.launch(token: C.poisoned)
        XCTAssertEqual(detail?.launch.name, poisoned.name)
        let unreadableDetail = try await service.launch(token: C.broken)
        XCTAssertEqual(unreadableDetail?.launch.name, ChainText.unreadable)

        // Home's and the Portfolio's launch holdings: every coin is read as its launch.
        let wallet = C.tokens.map { Token(address: $0, symbol: "?", name: "?", decimals: 18) }
        let held = try await service.heldLaunches(wallet)
        XCTAssertEqual(Set(held.factories.keys), Set(C.tokens))
        XCTAssertEqual(Set(held.launches.keys), Set(C.tokens))
        XCTAssertEqual(held.launches[C.poisoned]?.symbol, poisoned.symbol)
        XCTAssertTrue(held.complete)
        let curve = try await service.curveHoldings(wallet)
        XCTAssertEqual(Set(curve.launches.keys), Set(C.tokens))
    }

    /// A launch whose curve refuses `price()`: the read didn't happen, so the board and the coin's page throw (Retry),
    /// never a shorter board or "not found"; the holdings keep the coins recorded and say they aren't complete.
    func testALaunchWhoseProtocolReadFailsFailsTheReadNotTheList() async throws {
        typealias C = TextLaunchpadChain
        MomentsChainStub.install { C(failing: .price).answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: C.live)
        do {
            let listed = try await service.launches()
            XCTFail("listed \(listed.map(\.token))")
        } catch {
            XCTAssertEqual(error as? ChainListUnread, ChainListUnread(.launch))
        }
        do {
            let page = try await service.launch(token: C.broken)
            XCTFail("the page read as \(String(describing: page))")
        } catch {
            XCTAssertEqual(error as? ChainListUnread, ChainListUnread(.launch))
        }
        let plain = try await service.launch(token: C.plain)
        XCTAssertEqual(plain?.launch.name, "Plain Coin")
        let wallet = C.tokens.map { Token(address: $0, symbol: "?", name: "?", decimals: 18) }
        let held = try await service.heldLaunches(wallet)
        XCTAssertEqual(Set(held.factories.keys), Set(C.tokens), "every coin stays recorded")
        XCTAssertFalse(held.complete)
    }

    // MARK: Moments

    func testAMomentWithIllFormedTextListsAndOneWhoseTextCantBeReadShowsStandIns() async throws {
        typealias C = TextMomentsChain
        MomentsChainStub.install { C(failing: .text).answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: C.stack.addresses)

        let moments = try await service.moments()
        XCTAssertEqual(moments.map(\.id), [3, 2, 1], "newest first; every Moment the cohort counts")
        XCTAssertEqual(moments.last?.name, "Plain")
        let poisoned = moments[1]
        for field in [poisoned.name, poisoned.symbol, poisoned.provenance.mediaURI, poisoned.provenance.place, poisoned.provenance.animationURI] {
            XCTAssertTrue(Self.isReplaced(field), field.debugDescription)
        }
        let unreadable = try XCTUnwrap(moments.first)
        XCTAssertEqual([unreadable.name, unreadable.symbol], [ChainText.unreadable, ChainText.unreadable])
        XCTAssertEqual([unreadable.provenance.mediaURI, unreadable.provenance.place], ["", ""])
        XCTAssertEqual(unreadable.editions, 1, "the numbers of a Moment whose text can't be read are read as usual")
        let infos = try await service.infos(ids: [1, 2, 3])
        XCTAssertEqual(infos.map(\.id), [1, 2, 3])
        let opened = try await service.info(id: 3)
        XCTAssertEqual(opened?.name, ChainText.unreadable)
        let past = try await service.info(id: 4)
        XCTAssertNil(past, "an id past the count is no Moment")

        let portfolio = try await service.portfolio(account: C.collector)
        XCTAssertEqual(portfolio.rows.map(\.moment.id), [2])
        XCTAssertEqual(portfolio.rows.first?.moment.name, poisoned.name)
    }

    /// A Moment whose ledger read fails: the read didn't happen, so the feed, the wallet's Moments and the Moment's page
    /// throw (Retry), never a shorter list or "no Moment"; name links still read, since names are all they need.
    func testAMomentWhoseProtocolReadFailsFailsTheReadNotTheList() async throws {
        typealias C = TextMomentsChain
        MomentsChainStub.install { C(failing: .ledger).answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: C.stack.addresses)
        let reads: [(String, () async throws -> Void)] = [
            ("moments()", { _ = try await service.moments() }), ("infos(ids:)", { _ = try await service.infos(ids: [1, 2, 3]) }),
            ("info(id: 3)", { _ = try await service.info(id: 3) }), ("moment(id: 3)", { _ = try await service.moment(id: 3) }),
            ("portfolio", { _ = try await service.portfolio(account: C.collector) }),
        ]
        for (label, read) in reads {
            do {
                try await read()
                XCTFail("\(label) answered")
            } catch {
                XCTAssertEqual(error as? ChainListUnread, ChainListUnread(.moment), label)
            }
        }
        let plain = try await service.info(id: 1)
        XCTAssertEqual(plain?.name, "Plain")

        // Name links: the ill-formed name has a slug like any other, and the Moments after it keep theirs.
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: [.c4])
        let first = try await directory.key(for: "plain")
        XCTAssertEqual(first, MomentKey(factory: C.stack.addresses.factory, id: 1))
        let link = try await directory.link(for: MomentKey(factory: C.stack.addresses.factory, id: 2))
        XCTAssertEqual(link?.url.absoluteString, "https://dyorhq.fun/moments/a-z")
        let after = try await directory.key(for: "broken")
        XCTAssertEqual(after, MomentKey(factory: C.stack.addresses.factory, id: 3))
    }

    /// The link base is compared with DyorHQ's and hashed into `termsHash()`, so it is read strictly: a base that isn't
    /// text fails the policy read rather than being published under.
    func testTheMomentsLinkBaseIsReadStrictly() async throws {
        let stack = TextMomentsChain.stack
        MomentsChainStub.install { to, data in
            if to == stack.addresses.factory, data.prefix(4) == ABI.selector(MomentsABI.Factory.externalBaseURI) {
                return Self.stringReturn(Data("https://dyorhq.fun/moments/c4/".utf8) + Data([0xff]))
            }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        do {
            _ = try await service.policy()
            XCTFail("a link base that isn't text was read")
        } catch {
            XCTAssertEqual(error as? ABIError, .invalidUTF8)
        }
    }
}

/// Three launches on the v2 fixture launchpad, oldest first: a plain one, one whose every text field is ill-formed, and
/// `broken`, whose token refuses its name, symbol and token info (`.text`) or whose curve refuses `price()` (`.price`).
/// Every retired stack answers that it launched none of them.
struct TextLaunchpadChain: Sendable {
    enum Failing: Sendable { case text, price }
    var failing: Failing
    static let live = V2Fixture.launchpad
    static let plain = Address(literal: "0x0000000000000000000000000000000000a1a100")
    static let poisoned = Address(literal: "0x0000000000000000000000000000000000a1a200")
    static let broken = Address(literal: "0x0000000000000000000000000000000000a1a300")
    static let tokens = [plain, poisoned, broken]
    static let deployer = Address(literal: "0x0000000000000000000000000000000000de9100")
    /// The poisoned launch's name, symbol, logo, description and five links, each a different kind of ill-formed UTF-8.
    static let poisonedText: [Data] = ChainTextTests.illFormed.prefix(9).map { ChainTextTests.text($0.bytes) }

    static func curve(_ token: Address) -> Address { Address(data: token.data.prefix(19) + Data([0xc0]))! }

    private func record(_ token: Address, legacy: Bool, exists: Bool) -> Data {
        var fields: [ABIValue] = [.address(exists ? token : .zero), .address(exists ? Self.curve(token) : .zero), .address(exists ? Self.deployer : .zero),
                                  .address(exists ? Self.deployer : .zero), .address(.zero), .uint(exists ? BigUInt(10).power(21) : 0), .uint(0), .uint(100), .int(60),
                                  .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
        if legacy { fields.remove(at: 10) }
        return try! ABI.encode([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: legacy))
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let arg = ABIWords(data.dropFirst(4)).address(0)
        typealias F = LaunchpadABI.Factory
        typealias C = LaunchpadABI.Curve
        typealias T = LaunchpadABI.Token
        if to == Self.live.factory {
            if is_(F.launchCount) { return encode([.uint(Self.tokens.count)], "uint256") }
            if is_(F.getLaunches) { return encode([.array(Self.tokens.map { .address($0) })], "address[]") }
            if is_(F.getLaunchedToken), let arg { return record(arg, legacy: false, exists: Self.tokens.contains(arg)) }
            if is_(F.stuckSince) { return encode([.uint(0)], "uint256") }
            if is_(F.poolKeyOf) { return encode([.tuple([.address(.zero), .address(arg ?? .zero), .uint(0), .int(60), .address(Self.live.hook)])], LaunchpadABI.poolKeyTuple) }
            return nil
        }
        if let retired = LaunchpadAddresses.retiredStacks.first(where: { $0.factory == to }) {
            if is_(F.launchCount) { return encode([.uint(0)], "uint256") }
            if is_(F.getLaunchedToken), let arg { return record(arg, legacy: retired.generation.legacyRecord, exists: false) }
            return nil
        }
        for token in Self.tokens {
            if to == token {
                if token == Self.broken, failing == .text, is_(T.name) || is_(T.symbol) || is_(T.getTokenInfo) { return nil }
                let text: [Data] = token == Self.poisoned ? Self.poisonedText
                    : ["Plain Coin", "PLAIN", "https://example.com/plain.png", "Plain", "", "", "", "https://example.com", ""].map { Data($0.utf8) }
                if is_(T.name) { return ChainTextTests.stringReturn(text[0]) }
                if is_(T.symbol) { return ChainTextTests.stringReturn(text[1]) }
                if is_(T.getTokenInfo) {
                    return encode([.address(Self.deployer), .bytes(text[2]), .bytes(text[3]), .tuple(text[4...8].map { ABIValue.bytes($0) })], "address,bytes,bytes,(bytes,bytes,bytes,bytes,bytes)")
                }
                if is_(T.totalSupply) { return encode([.uint(BigUInt(10).power(27))], "uint256") }
            }
            if to == Self.curve(token) {
                if is_(C.price) { return token == Self.broken && failing == .price ? nil : encode([.uint(1_000)], "uint256") }
                if is_(C.realQuoteReserve) || is_(C.sellableTokens) || is_(C.phantomQuote) || is_(C.reservedTokens) { return encode([.uint(1_000)], "uint256") }
                if is_(C.completed) || is_(C.rescued) || is_(C.swept) { return encode([.bool(false)], "bool") }
                if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
                if is_(C.feeBps) { return encode([.uint(100)], "uint16") }
                if is_(C.snipeTaxSchedule) { return encode([.array([])], "uint16[]") }
                if is_(C.getReserves) { return encode([.uint(1), .uint(2)], "uint256,uint256") }
            }
        }
        return nil
    }
}

/// Three Moments on the shipped c4 cohort's addresses (`FakeMomentsStack`): "Plain"; one whose coin name and symbol and
/// every provenance text are ill-formed ("A", ill-formed bytes, "Z"); and "Broken", whose coin refuses its name and
/// symbol and whose NFT its provenance (`.text`), or whose ledger read reverts (`.ledger`). `collector` holds the second
/// one's coin.
struct TextMomentsChain: Sendable {
    enum Failing: Sendable { case text, ledger }
    var failing: Failing
    static let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                        nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Plain", "Poisoned", "Broken"])
    static let collector = Address(literal: "0x00000000000000000000000000000000000c0113")

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let s = Self.stack
        let args = ABIWords(data.dropFirst(4))
        if to == s.coin(2) {
            if is_(MomentsABI.Coin.name) { return ChainTextTests.stringReturn(ChainTextTests.text([0xff, 0xfe, 0xfd, 0xfc])) }
            if is_(MomentsABI.Coin.symbol) { return ChainTextTests.stringReturn(ChainTextTests.text([0x80])) }
        }
        if to == s.nft(2), is_(MomentsABI.NFT.provenance) {
            let texts = [[0xc0, 0xaf], [0xe2, 0x82], [0xed, 0xa0, 0x80]].map { ChainTextTests.text($0) }
            return encode([.tuple([.bytes(texts[0]), .bytes(Data(count: 32)), .bytes(texts[1]), .uint(0), .bytes(texts[2])])], "(bytes,bytes32,bytes,uint64,bytes)")
        }
        if failing == .ledger, to == s.addresses.collect, is_(MomentsABI.Collect.ledger), args.uint(0) == 3 { return nil }
        if failing == .text, to == s.coin(3), is_(MomentsABI.Coin.name) || is_(MomentsABI.Coin.symbol) { return nil }
        if failing == .text, to == s.nft(3), is_(MomentsABI.NFT.provenance) { return nil }
        // The portfolio's reads: nothing vested or claimed anywhere; the collector holds the second Moment's coin.
        if to == s.addresses.vesting, is_(MomentsABI.Vesting.entitlement) || is_(MomentsABI.Vesting.claimed) || is_(MomentsABI.Vesting.creatorClaimed) {
            return encode([.uint(0)], "uint256")
        }
        if to == s.addresses.vesting, is_(MomentsABI.Vesting.claimable) { return encode([.uint(0), .uint(0)], "uint256,uint256") }
        if is_(MomentsABI.Coin.balanceOf), (1...3).contains(where: { to == s.coin($0) || to == s.nft($0) }) {
            return encode([.uint(to == s.coin(2) && args.address(0) == Self.collector ? BigUInt(10).power(18) : 0)], "uint256")
        }
        return s.answer(to, data)
    }
}
