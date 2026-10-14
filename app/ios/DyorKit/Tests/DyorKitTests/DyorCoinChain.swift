import BigInt
import Foundation
@testable import DyorKit

/// DyorHQ's factories as `DyorCoinRegistry` reads them, answered from memory through `MomentsChainStub`: every launchpad
/// stack of `DyorCoinRegistry.launchpads(live: .monadMainnet)` (each record in its own layout, the 16-field one on 0xad3d)
/// and every cohort of `cohorts(live: .monadMainnet)`, with the coins given, their tokens and NFTs. `mainnet` is the chain
/// as read on 2026-09-29 (block 109,033,713, rpc1.monad.xyz): 7 launches and 6 Moments.
struct DyorCoinChain: Sendable {
    struct LaunchCoin: Sendable {
        var token: Address
        var name: String
        var symbol: String
        var logo: String
        var deployer: Address
        var pair: Address = .zero
        var phase: LaunchPhase = .bonding
        var venue: GraduationVenue = .uniswapV4
        var curve: Address
        var poolId = Data(count: 32)
        /// The token the factory's record names: another token's, to test that such a record is refused.
        var recordToken: Address?
    }

    struct MomentCoin: Sendable {
        var coin: Address
        var nft: Address
        var creator: Address
        var name: String
        var symbol: String
        var mediaURI: String
        var mediaHash: Data
        var animationURI = ""
        /// The coin `getMoment` names: another, to test that such a Moment is refused.
        var momentCoin: Address?
    }

    static let stacks = DyorCoinRegistry.launchpads(live: .monadMainnet)
    static let cohortTable = DyorCoinRegistry.cohorts(live: .monadMainnet)

    /// Each launchpad's launches, in its `getLaunches` order.
    var launches: [Address: [LaunchCoin]] = [:]
    /// Each cohort's Moments, id 1 first.
    var moments: [Address: [MomentCoin]] = [:]
    /// Contracts every call to which reverts.
    var silent: Set<Address> = []
    /// Coins a node behind the chain hasn't reached yet: their factory's record of them is empty, and they answer as an
    /// account with no code (empty bytes), though the factory's list already names them.
    var lagging: Set<Address> = []
    /// Contracts whose calls burn the gas of the read they are in (`MomentsChainStub`'s `starving`): their call and every
    /// one after it in that read fail — a coin whose creator's strings cost more gas than a read has.
    var starving: Set<Address> = []
    /// Contracts that make any read they are in fail as a whole, out of gas (`MomentsChainStub`'s `breaking`).
    var breaking: Set<Address> = []
    /// Tokens no factory made that answer as if one did: `factory()` naming the live launchpad, `name`, `symbol`,
    /// `getTokenInfo` with DyorHQ's bucket.
    var impostors: Set<Address> = []
    /// Coins whose `name()` and `symbol()` answer these raw bytes (a `string`'s layout), as a creator who wrote bytes that
    /// aren't text has them.
    var rawText: [Address: Data] = [:]
    /// Coins, and Moments' NFTs, whose own calls revert however they are read: their text can't be read at all.
    var textReverts: Set<Address> = []
    /// Coins whose factory's `getLaunchedToken` or `momentIdByCoin` reverts: the factory's own record can't be read.
    var brokenRecords: Set<Address> = []

    /// A `string` answer holding `bytes` as they are.
    static func rawString(_ bytes: [UInt8]) -> Data { try! ABI.encode([.bytes(Data(bytes))], "bytes") }

    func answer(_ to: Address, _ data: Data) -> Data? {
        if silent.contains(to) || textReverts.contains(to) { return nil }
        if lagging.contains(to) { return Data() }
        if let raw = rawText[to], data.prefix(4) == ABI.selector(LaunchpadABI.Token.name) || data.prefix(4) == ABI.selector(LaunchpadABI.Token.symbol) { return raw }
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        typealias F = LaunchpadABI.Factory
        typealias T = LaunchpadABI.Token
        if let stack = Self.stacks.first(where: { $0.factory == to }) {
            let list = launches[to] ?? []
            if is_(F.launchCount) { return encode([.uint(BigUInt(list.count))], "uint256") }
            if is_(F.getLaunches), let offset = args.uint(0).flatMap({ Int(exactly: $0) }), let limit = args.uint(1).flatMap({ Int(exactly: $0) }) {
                let end = min(list.count, offset + limit) // clamped, as `LaunchpadFactory.getLaunches` does
                return encode([.array(offset < end ? list[offset..<end].map { .address($0.token) } : [])], "address[]")
            }
            if is_(F.getLaunchedToken), let asked = args.address(0) {
                if brokenRecords.contains(asked) { return nil }
                let coin = lagging.contains(asked) ? nil : list.first { $0.token == asked }
                return encode([.tuple(Self.record(coin, legacy: stack.generation.legacyRecord))], LaunchpadABI.launchedTokenReturns(legacy: stack.generation.legacyRecord))
            }
            return nil
        }
        if Self.cohortTable.contains(where: { $0.factory == to }) {
            let list = moments[to] ?? []
            if is_(MomentsABI.Factory.momentCount) { return encode([.uint(BigUInt(list.count))], "uint256") }
            if is_(MomentsABI.Factory.getMoment), let id = args.uint(0).flatMap({ Int(exactly: $0) }) {
                guard id >= 1, id <= list.count else { return nil }
                let m = list[id - 1]
                return encode([.tuple([.address(m.creator), .address(.zero), .address(.zero), .address(m.momentCoin ?? m.coin), .address(m.nft),
                                       .uint(100_000), .uint(771_428_571), .uint(1), .uint(1), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500),
                                       .uint(1_790_000_000), .uint(1_790_086_400)])], MomentsABI.momentTuple)
            }
            if is_(MomentsABI.Factory.momentIdByCoin), let asked = args.address(0) {
                if brokenRecords.contains(asked) { return nil }
                let id = list.firstIndex { $0.coin == asked }.map { $0 + 1 } ?? 0
                return encode([.uint(BigUInt(id))], "uint256")
            }
            return nil
        }
        for list in launches.values {
            guard let coin = list.first(where: { $0.token == to }) else { continue }
            return Self.tokenAnswer(selector, name: coin.name, symbol: coin.symbol, logo: coin.logo, deployer: coin.deployer)
        }
        for list in moments.values {
            if let m = list.first(where: { $0.coin == to || $0.momentCoin == to }) {
                if is_(MomentsABI.Coin.name) { return encode([.string(m.name)], "string") }
                if is_(MomentsABI.Coin.symbol) { return encode([.string(m.symbol)], "string") }
                return nil
            }
            if let m = list.first(where: { $0.nft == to }), is_(MomentsABI.NFT.provenance) {
                return encode([.tuple([.string(m.mediaURI), .bytes(m.mediaHash), .string("Accra"), .uint(1_790_000_000), .string(m.animationURI)])], MomentsABI.provenanceTuple)
            }
        }
        if impostors.contains(to) {
            if is_("factory()") { return encode([.address(LaunchpadAddresses.monadMainnet.factory)], "address") }
            return Self.tokenAnswer(selector, name: "Quet", symbol: "QT", logo: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xabc/x.jpg", deployer: to)
        }
        return nil
    }

    private static func tokenAnswer(_ selector: Data, name: String, symbol: String, logo: String, deployer: Address) -> Data? {
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        typealias T = LaunchpadABI.Token
        if selector == ABI.selector(T.name) { return encode([.string(name)], "string") }
        if selector == ABI.selector(T.symbol) { return encode([.string(symbol)], "string") }
        if selector == ABI.selector(T.decimals) { return encode([.uint(18)], "uint8") }
        if selector == ABI.selector(T.getTokenInfo) {
            return encode([.address(deployer), .string(logo), .string("A coin"), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)")
        }
        return nil
    }

    /// A factory's `getLaunchedToken` answer: the coin's record, or the empty record a factory gives a token it never
    /// launched, in the 17-field layout or the legacy 16-field one.
    static func record(_ coin: LaunchCoin?, legacy: Bool) -> [ABIValue] {
        var fields: [ABIValue] = [
            .address(coin.map { $0.recordToken ?? $0.token } ?? .zero), .address(coin?.curve ?? .zero), .address(coin?.deployer ?? .zero), .address(coin?.deployer ?? .zero),
            .address(coin?.pair ?? .zero), .uint(coin == nil ? 0 : 400), .uint(coin == nil ? 0 : 50), .uint(coin == nil ? 0 : 100), .int(coin == nil ? 0 : 60), .bool(false),
            .uint(BigUInt(coin?.venue.rawValue ?? 0)), .uint(BigUInt(coin?.phase.rawValue ?? 0)), .uint(0), .uint(0), .uint(0), .bytes(coin?.poolId ?? Data(count: 32)), .bool(coin != nil),
        ]
        if legacy { fields.remove(at: 10) }
        return fields
    }

    func install() {
        let chain = self
        MomentsChainStub.install({ chain.answer($0, $1) }, breaking: breaking, starving: starving)
    }

    // MARK: Mainnet, 2026-09-29

    static let legacy = Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea")
    static let preAudit = Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4")
    static let audit = Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7")
    static let relaunch = Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB")
    static let c1 = Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020")
    static let c2 = Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581")
    static let c3 = Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26")

    static let owner = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")
    static let creator = Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")
    static let aBIL = Address(literal: "0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f")
    static let qt = Address(literal: "0x73F942e084Ab047a94e4E3B5D6ae571e23A51856")
    /// JAMES, "The Busy Bull of Monad": a nad.fun coin (its pools are on Nadswap, Capricorn, PancakeSwap and Uniswap), in
    /// none of DyorHQ's factories.
    static let james = Address(literal: "0x43cf5407bda1400498b8064d50a7e17528d87777")

    static func media(_ folder: Address, _ file: String) -> String {
        "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/\(folder.hex)/\(file)"
    }

    static let mainnet = DyorCoinChain(
        launches: [
            audit: [
                LaunchCoin(token: Address(literal: "0xA4D9b2697254292ad30e06Ce968a7e18De6fF884"), name: "Laptop", symbol: "LP", logo: media(creator, "d0ead8f2-b44a-438b-9e64-b21cf1c1e69c.jpg"),
                           deployer: creator, curve: Address(literal: "0xbe36BD571e1f4d7E25f4Fc891fC8407460fEb9e6")),
            ],
            preAudit: [
                LaunchCoin(token: Address(literal: "0x74b215C1788A90aAF45A33f83584C1a04ba402b8"), name: "Good Morning", symbol: "GMGM", logo: media(creator, "6ab421df-20b7-4e3f-929b-9183714341c0.jpg"),
                           deployer: creator, venue: .monday, curve: Address(literal: "0xCD88738a3dD6677930d3881a51219AE93aF3BAD3")),
                LaunchCoin(token: Address(literal: "0xB281906b67b6EFed8C805c8595888255a0F46979"), name: "Pons", symbol: "BPP", logo: media(creator, "758d9514-09af-4f28-a419-3a90d3d4934f.jpg"),
                           deployer: creator, venue: .monday, curve: Address(literal: "0x804b420E636b88d23559764a34CC8c420984E3cD")),
            ],
            legacy: [
                LaunchCoin(token: qt, name: "Quet", symbol: "QT", logo: media(owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg"), deployer: owner, phase: .graduated, venue: .monday,
                           curve: Address(literal: "0x74E552A81eeF9ccC77Eba745164755a64f216002"), poolId: Data(hex: "0x00000000000000000000000072484c6c9f2a41dd9f34c61584bcd2b72eeef325")!),
                LaunchCoin(token: Address(literal: "0xCD83D45F985BB42b7d6ABB1f2cC12860B4610c3D"), name: "Justice", symbol: "JUST", logo: media(owner, "791608ff-3715-48c6-9847-c39c802558f2.jpg"),
                           deployer: owner, pair: aBIL, venue: .monday, curve: Address(literal: "0x9D8452763000a673de749Bd0730F16FeB228ec65")),
                LaunchCoin(token: Address(literal: "0x40C5bebd974fb622A42ce68823F514ca03f48666"), name: "Binance Boy", symbol: "BB", logo: media(creator, "afb86749-09ae-4b06-bb25-6c7299b690c0.jpg"),
                           deployer: creator, pair: aBIL, venue: .monday, curve: Address(literal: "0x0f8A9C03E3c2877b3efEB31648430fC335B8eb8d")),
                LaunchCoin(token: Address(literal: "0x959B3a85a1Db6a60595Ce7B31Dd1e91acfa977bf"), name: "Baby Pons", symbol: "BP", logo: media(creator, "50a091f0-695c-45fb-a00c-155b023c8e79.jpg"),
                           deployer: creator, pair: aBIL, venue: .monday, curve: Address(literal: "0x6750b5058E092D74E2Ca3B6dD1bA7B8468A4aE8D")),
            ],
        ],
        moments: [
            c3: [
                MomentCoin(coin: Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF"), nft: Address(literal: "0x79E61CDF2C8B9Ff505e940b3a5437B5BCA047EAc"), creator: owner,
                           name: "Nature", symbol: "NAT", mediaURI: "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe",
                           mediaHash: Data(hex: "0x46a0fa05ecc0fd0f47856df1d8a6fbd69145d1d9df6da9927301719b4a06a6c5")!,
                           animationURI: "ipfs://bafybeie4rh73i7kfugowp4jyjdjpnng3a7z4suslievdbulqfjb6ywzvuy"),
            ],
            c2: [
                MomentCoin(coin: Address(literal: "0xC18941ca9fBaa613841c3d31a7Dd1D262a47a2E5"), nft: Address(literal: "0xad733C679e6AB917b46d44A0Be8931fE0Aac2f2D"), creator: creator,
                           name: "0N1 Force", symbol: "0N1", mediaURI: "ipfs://bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q",
                           mediaHash: Data(hex: "0xdb08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900")!),
                MomentCoin(coin: Address(literal: "0x01D2c48E3cd38804a643E391421289933ed3D4a7"), nft: Address(literal: "0x326507b51031bbfc8C919251Bbe09f4F397870C2"), creator: creator,
                           name: "RWA", symbol: "RWA", mediaURI: "ipfs://bafybeie5josast65hwkon53hsbyatzk46pvmpn36rbxl6yshlr66lk6siy",
                           mediaHash: Data(hex: "0x78032fa9b79b9c0981114833c73bae4c62db250db348758905844329030b6992")!),
            ],
            c1: [
                MomentCoin(coin: Address(literal: "0xDc1bC41b7C197DE19f17C7832bec3Bb748D92297"), nft: Address(literal: "0x1f247c933e903354E51f60a0708Ac686ddCf9DE0"), creator: creator,
                           name: "Spectacular", symbol: "SPT", mediaURI: media(creator, "moment-1bba9cd9-1a1e-4bba-a364-df5466842c37.jpg"),
                           mediaHash: Data(hex: "0x4b807a9d9cd134af92a2a2f7626f25108b1337a15ddad83d0d90bd176cba800d")!),
                MomentCoin(coin: Address(literal: "0xd6c17E083b53fa1c46b71120D6959303Ae4B8e1F"), nft: Address(literal: "0x42a2461Adb3659d034845eC314a5C6a2C3799B50"), creator: creator,
                           name: "Bitcoin Diva", symbol: "BTCD", mediaURI: media(creator, "moment-d9958223-2bc3-49c9-8963-07cca31fa3a3.jpg"),
                           mediaHash: Data(hex: "0x2353e5d3d95c7dbbb50168b44fb42405b7aa4f2527ff19f6edd0f18f4099bf0c")!,
                           animationURI: media(creator, "moment-46a2f002-5e7b-43db-b8e5-94b235902331.mov")),
                MomentCoin(coin: Address(literal: "0x8D2AEc229b5A4Fd4D4aB1725c92B6B7f53fBc50f"), nft: Address(literal: "0x255Ef819d221ec68C655f45F71d52f4A4806968C"),
                           creator: Address(literal: "0x2AF85656F1B17Ce935DE335A4Ce95A4eFa807af5"),
                           name: "0N1 Force NFT", symbol: "0N1F", mediaURI: "ipfs://bafybeifmoxw4n266mtz4howe7owiz3a3k7ar5gr6dke7ayauy5bpumlkby",
                           mediaHash: Data(hex: "0xdb08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900")!),
            ],
        ]
    )
}
