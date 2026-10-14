import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The app's list readers on a LOCAL anvil fork of Monad whose shipped v2 launchpad (`LaunchpadAddresses.monadMainnet`)
/// and cohort 4 (`MomentsAddresses.monadMainnet`) hold launches and Moments whose text isn't valid UTF-8, and ones whose
/// text is as long as a transaction stores (`ChainTextTests` and `ChainTextSizeTests` have the same without a fork). The
/// repository's seed scripts put them there; a fork without them fails the test, never skips it:
///
///   anvil --fork-url https://rpc3.monad.xyz --no-rate-limit --disable-code-size-limit --port 8741
///   node scripts/dev/seed-fork.mjs --text 8741 && node scripts/dev/seed-moments-fork.mjs --text 8741
///   cd ios/DyorKit && DYOR_TEXT_FORK_RPC=http://127.0.0.1:8741 swift test --filter ChainTextForkTests
///
/// Skipped only without `DYOR_TEXT_FORK_RPC`, or when it isn't a local RPC of chain 143. What each list must hold is read from the fork
/// itself: every launch the factory records and every Moment the cohort counts, with their text as raw bytes. Reads only.
final class ChainTextForkTests: XCTestCase {
    private var rpc: RPCClient!

    override func setUp() async throws {
        try await super.setUp()
        guard let text = ProcessInfo.processInfo.environment["DYOR_TEXT_FORK_RPC"], let url = URL(string: text) else {
            throw XCTSkip("set DYOR_TEXT_FORK_RPC (a local fork of Monad holding launches and Moments whose text isn't UTF-8)")
        }
        let rpc = RPCClient(url: url)
        guard rpc.isLocal else { throw XCTSkip("DYOR_TEXT_FORK_RPC must be a local fork (127.0.0.1 or localhost), never a public RPC") }
        let chain = try await rpc.call("eth_chainId")
        guard chain.string.flatMap({ BigUInt(hexQuantity: $0) }) == 143 else { throw XCTSkip("DYOR_TEXT_FORK_RPC is not a fork of Monad mainnet (chain 143)") }
        self.rpc = rpc
    }

    /// `text` as it must read in a list: its bytes when they are UTF-8, as they show (`shown`: `ChainText.shown` for a
    /// name, symbol, description or place, the text itself for a link), else with U+FFFD in place of what isn't.
    private static func check(_ listed: String, _ raw: Data, _ label: String, _ shown: (String) -> String = { $0 }) {
        if let exact = String(data: raw, encoding: .utf8) {
            XCTAssertEqual(listed, shown(exact), label)
        } else {
            XCTAssertTrue(listed.contains("\u{FFFD}"), "\(label): \(listed.debugDescription)")
        }
    }

    private static func isText(_ raw: Data) -> Bool { String(data: raw, encoding: .utf8) != nil }

    /// What the seed scripts' longest text is at least: a launch's description, a Moment's name.
    private static let longDescription = 20_000
    private static let longName = 8_000

    /// Each of `items`' calls, `calls(item)`, answered in order, `Multicall.textChunk` items per read (as the app reads
    /// them): one read of every item's text at once is more than anvil answers on a fork holding about 100 launches of
    /// the longest text ("EVM error MemoryOOG"), and this check's own read must never be what fails.
    private static func readInChunks<Item>(_ items: [Item], multicall: Multicall, _ calls: (Item) throws -> [ContractCall]) async throws -> [[ABIValue]] {
        var out: [[ABIValue]] = []
        for start in stride(from: 0, to: items.count, by: Multicall.textChunk) {
            out += try await multicall.readAll(try items[start ..< min(start + Multicall.textChunk, items.count)].flatMap(calls))
        }
        return out
    }

    /// One reader's answer, or nil with a failure naming the reader, so every reader is tried.
    private func read<T>(_ reader: String, _ body: () async throws -> T) async -> T? {
        do { return try await body() } catch {
            XCTFail("\(reader) threw \(error)")
            return nil
        }
    }

    func testEveryLaunchIsListedWhateverItsText() async throws {
        let multicall = Multicall(rpc: rpc)
        let factory = LaunchpadAddresses.monadMainnet.factory
        let count = Int(try await multicall.readAll([try ContractCall(to: factory, "launchCount()", returns: "uint256")])[0][0].uint)
        let tokens = try await multicall.readAll([try ContractCall(to: factory, "getLaunches(uint256,uint256)", [.uint(0), .uint(count)], returns: "address[]")])[0][0]
            .elements.map(\.address)
        // Each coin's text as raw bytes (`bytes` shares `string`'s layout): name, symbol, then getTokenInfo's logo, description and links.
        let raw = try await Self.readInChunks(tokens, multicall: multicall) { token in
            [try ContractCall(to: token, "name()", returns: "bytes"), try ContractCall(to: token, "symbol()", returns: "bytes"),
             try ContractCall(to: token, "getTokenInfo()", returns: "address,bytes,bytes,(bytes,bytes,bytes,bytes,bytes)")]
        }
        func texts(_ i: Int) -> [Data] {
            let info = raw[3 * i + 2]
            return [raw[3 * i][0].bytes, raw[3 * i + 1][0].bytes, info[1].bytes, info[2].bytes] + info[3].elements.map(\.bytes)
        }
        let illFormed = tokens.indices.filter { !texts($0).allSatisfy(Self.isText) }.map { tokens[$0] }
        let long = tokens.indices.filter { texts($0)[3].count >= Self.longDescription }.map { tokens[$0] }
        guard !illFormed.isEmpty, !long.isEmpty else {
            return XCTFail("the fork's launchpad holds \(illFormed.count) launches whose text isn't UTF-8 and \(long.count) with a description of \(Self.longDescription) bytes or more: seed it (node scripts/dev/seed-fork.mjs --text <port>)")
        }
        XCTAssertLessThan(illFormed.count, tokens.count, "the fork holds ordinary launches too")
        print("ChainTextForkTests launchpad: \(tokens.count) launches, \(illFormed.count) with text that isn't UTF-8: \(illFormed.map(\.short)), \(long.count) with a long description: \(long.map { "\($0.short) \(texts(tokens.firstIndex(of: $0)!)[3].count) B" })")

        let service = LaunchpadService(rpc: rpc, addresses: .monadMainnet)
        let listed = await read("launches") { try await service.launches(limit: max(count, 1)) } ?? []
        XCTAssertEqual(Set(listed.map(\.token)), Set(tokens), "the Launch board lists every launch the factory records")
        for launch in listed {
            guard let i = tokens.firstIndex(of: launch.token) else { continue }
            let fields = [launch.name, launch.symbol, launch.logo, launch.description,
                          launch.socials.twitter, launch.socials.telegram, launch.socials.discord, launch.socials.website, launch.socials.farcaster]
            let shown: [(String) -> String] = [{ ChainText.shown($0) }, { ChainText.shown($0) }, { $0 }, { ChainText.shown($0, multiline: true) }] + Array(repeating: { $0 }, count: 5)
            for (j, (field, bytes)) in zip(fields, texts(i)).enumerated() { Self.check(field, bytes, launch.token.short, shown[j]) }
            if illFormed.contains(launch.token) { print("ChainTextForkTests listed \(launch.token.short): \(fields.map(\.debugDescription))") }
        }
        let all = await read("allLaunches") { try await service.allLaunches(limit: max(count, 1)) } ?? []
        XCTAssertTrue(Set(tokens).isSubset(of: Set(all.map(\.token))), "the board with the retired launchpads lists them too")

        // Home's launch holdings, a coin's own page, and Swap's add-by-address.
        let wallet = tokens.map { Token(address: $0, symbol: "?", name: "?", decimals: 18) }
        let held = await read("heldLaunches") { try await service.heldLaunches(wallet) }
        XCTAssertEqual(Set(held?.launches.keys.map { $0 } ?? []), Set(tokens), "every held launch coin is read as its launch")
        for token in illFormed + long {
            let detail = await read("launch(token:)") { try await service.launch(token: token) }
            XCTAssertEqual(detail??.launch.token, token, "the coin's page loads")
            let added = await read("ERC20.metadata") { try await ERC20.metadata(token, multicall: multicall) }
            XCTAssertNotNil(added ?? nil, "the coin can be added by address")
        }
    }

    func testEveryMomentIsListedWhateverItsText() async throws {
        let multicall = Multicall(rpc: rpc)
        let cohort = MomentsAddresses.monadMainnet
        let count = Int(try await multicall.readAll([try ContractCall(to: cohort.factory, "momentCount()", returns: "uint256")])[0][0].uint)
        guard count > 0 else { return XCTFail("the fork's cohort 4 holds no Moment: seed it (node scripts/dev/seed-moments-fork.mjs --text <port>)") }
        let ids = (1...count).map { BigUInt($0) }
        let moments = try await multicall.readAll(ids.map { try ContractCall(to: cohort.factory, "getMoment(uint256)", [.uint($0)], returns: MomentsABI.momentTuple) })
            .enumerated().map { MomentsABI.moment(id: ids[$0.offset], $0.element[0], factory: cohort.factory) }
        // Each Moment's text as raw bytes: its coin's name and symbol, its NFT's media URI, place and animation URI.
        let raw = try await Self.readInChunks(moments, multicall: multicall) { m in
            [try ContractCall(to: m.coin, "name()", returns: "bytes"), try ContractCall(to: m.coin, "symbol()", returns: "bytes"),
             try ContractCall(to: m.nft, "provenance()", returns: "(bytes,bytes32,bytes,uint64,bytes)")]
        }
        func texts(_ i: Int) -> [Data] {
            let p = raw[3 * i + 2][0]
            return [raw[3 * i][0].bytes, raw[3 * i + 1][0].bytes, p[0].bytes, p[2].bytes, p[4].bytes]
        }
        let illFormed = moments.indices.filter { !texts($0).allSatisfy(Self.isText) }.map { moments[$0] }
        let long = moments.indices.filter { texts($0)[0].count >= Self.longName }.map { moments[$0] }
        guard let poisoned = illFormed.first, let longest = long.first else {
            return XCTFail("the fork's cohort 4 holds \(illFormed.count) Moments whose text isn't UTF-8 and \(long.count) with a name of \(Self.longName) bytes or more: seed it (node scripts/dev/seed-moments-fork.mjs --text <port>)")
        }
        XCTAssertLessThan(illFormed.count, moments.count, "the fork holds ordinary Moments too")
        print("ChainTextForkTests moments: \(moments.count) Moments, \(illFormed.count) with text that isn't UTF-8: \(illFormed.map { String($0.id) }), \(long.count) with a long name: \(long.map { "\($0.id) \(texts(Int($0.id) - 1)[0].count) B" })")

        let service = MomentsService(rpc: rpc, addresses: .monadMainnet)
        let listed = await read("moments") { try await service.moments(limit: count) } ?? []
        XCTAssertEqual(Set(listed.map(\.id)), Set(ids), "the Moments feed lists every Moment the cohort counts")
        for info in listed {
            let i = Int(info.id) - 1
            let fields = [info.name, info.symbol, info.provenance.mediaURI, info.provenance.place, info.provenance.animationURI]
            let shown: [(String) -> String] = [{ ChainText.shown($0) }, { ChainText.shown($0) }, { $0 }, { ChainText.shown($0) }, { $0 }]
            for (j, (field, bytes)) in zip(fields, texts(i)).enumerated() { Self.check(field, bytes, "Moment \(info.id)", shown[j]) }
            if illFormed.contains(where: { $0.id == info.id }) { print("ChainTextForkTests listed Moment \(info.id): \(fields.map(\.debugDescription))") }
        }
        let infos = await read("infos(ids:)") { try await service.infos(ids: ids) }
        XCTAssertEqual(infos?.map(\.id), ids, "the wallet's Moments read every id")
        let portfolio = await read("portfolio") { try await service.portfolio(account: poisoned.creator) }
        XCTAssertNotNil(portfolio, "the Moments portfolio reads")
        let directory = MomentDirectory(rpc: rpc)
        for moment in [poisoned, longest] {
            let link = await read("MomentDirectory") { try await directory.link(for: MomentKey(factory: cohort.factory, id: moment.id)) }
            let slug = try XCTUnwrap(link ?? nil, "Moment \(moment.id) has a name link").url.lastPathComponent
            let back = await read("MomentDirectory") { try await directory.key(for: slug) }
            XCTAssertEqual(back ?? nil, MomentKey(factory: cohort.factory, id: moment.id), "\(slug) opens Moment \(moment.id)")
        }
    }
}
