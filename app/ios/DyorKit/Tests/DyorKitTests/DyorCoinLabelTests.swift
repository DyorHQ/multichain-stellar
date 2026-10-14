import XCTest
@testable import DyorKit

/// What a coin shows, end to end: the registry reads the factories (`MomentsChainStub`, `DyorCoinChain`), and the badge
/// and the picture follow from its entry. QT gets "DyorHQ Launch" and its launch image; DyorHQ coins with Chinese, Korean or
/// Japanese symbols are labelled; a DyorHQ launch named "USDC" warns and shows letters; JAMES, a nad.fun coin, stays
/// Unverified with its letters; and a read that failed labels nothing.
final class DyorCoinLabelTests: XCTestCase {
    private let policy = ImageSourcePolicy(supabaseURL: URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!)

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
    }

    private func registry(_ chain: DyorCoinChain) -> DyorCoinRegistry {
        chain.install()
        return DyorCoinRegistry(rpc: MomentsChainStub.rpc())
    }

    /// A token as a wallet's stored snapshot has it: what the coin calls itself, and no logo.
    private func snapshot(_ address: Address, _ symbol: String, _ name: String = "Coin") -> Token {
        Token(address: address, symbol: symbol, name: name, decimals: 18)
    }

    /// QT, graduated on the retired legacy launchpad 0xad3d: "DyorHQ Launch" wherever it is listed — sent to the wallet or
    /// bought in it — and its launch image from DyorHQ's bucket, filled, in place of the "QT" monogram. Found by
    /// enumeration and, for a held coin not seen yet, by point proof.
    func testQTIsADyorHQLaunchWithItsImage() async throws {
        let enumerated = registry(.mainnet)
        await enumerated.refresh()
        let found = await enumerated.coin(DyorCoinChain.qt)
        let proving = registry(.mainnet)
        let proof = await proving.prove([DyorCoinChain.qt])
        guard case .dyor(let proven)? = proof[DyorCoinChain.qt] else { return XCTFail("QT by point proof") }
        let qt = try XCTUnwrap(found)
        XCTAssertEqual(proven, qt)
        let token = snapshot(DyorCoinChain.qt, "QT", "Quet")
        XCTAssertEqual(TokenBadge.of(token, coin: qt, receivedUnasked: true), .dyorLaunch)
        XCTAssertEqual(TokenBadge.of(token, coin: qt, receivedUnasked: false), .dyorLaunch)
        XCTAssertEqual(TokenBadge.dyorLaunch.title, "DyorHQ Launch")
        let image = URL(string: DyorCoinChain.media(DyorCoinChain.owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg"))!
        XCTAssertEqual(CoinIcon.resolve(token, coin: qt, policy: policy), .remote([RemoteImageSource(url: image)], fill: true))
        XCTAssertTrue(qt.retired, "0xad3d is retired; the label doesn't depend on it")
    }

    /// DyorHQ coins whose symbols are Chinese, Korean or Japanese are labelled like any other, with their art.
    func testChineseKoreanAndJapaneseSymbolsAreLabelled() async throws {
        var chain = DyorCoinChain.mainnet
        let v2 = LaunchpadAddresses.monadMainnet.factory
        let doge = Address(literal: "0x0000000000000000000000000000000000d09e01")
        chain.launches[v2] = [DyorCoinChain.LaunchCoin(token: doge, name: "狗狗币", symbol: "狗狗", logo: DyorCoinChain.media(DyorCoinChain.creator, "d.jpg"),
                                                         deployer: DyorCoinChain.creator, curve: Address(literal: "0x0000000000000000000000000000000000c0e001"))]
        let puppy = Address(literal: "0x0000000000000000000000000000000000d09e02")
        chain.launches[DyorCoinChain.relaunch] = [DyorCoinChain.LaunchCoin(token: puppy, name: "ドージコイン", symbol: "ドージ", logo: "ipfs://bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q",
                                                                         deployer: DyorCoinChain.creator, curve: Address(literal: "0x0000000000000000000000000000000000c0e002"))]
        let dog = Address(literal: "0x0000000000000000000000000000000000d09e03")
        chain.moments[MomentsAddresses.monadMainnet.factory] = [
            DyorCoinChain.MomentCoin(coin: dog, nft: Address(literal: "0x0000000000000000000000000000000000d09e04"), creator: DyorCoinChain.creator, name: "강아지 코인", symbol: "강아지",
                                     mediaURI: "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe", mediaHash: Data(repeating: 0x5a, count: 32)),
        ]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        for (address, symbol, badge) in [(doge, "狗狗", TokenBadge.dyorLaunch), (puppy, "ドージ", .dyorLaunch), (dog, "강아지", .dyorMoment)] {
            let coin = try XCTUnwrap(coins[address], symbol)
            let token = snapshot(address, symbol)
            XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: true), badge, symbol)
            guard case .remote(let sources, let fill) = CoinIcon.resolve(token, coin: coin, policy: policy) else { return XCTFail("\(symbol) shows its art") }
            XCTAssertTrue(fill && !sources.isEmpty, symbol)
        }
        XCTAssertEqual(coins[dog]?.retired, false, "cohort 4 is the live one")
        XCTAssertEqual(coins[puppy]?.retired, true, "0x6B1C is retired, and still open on chain")
    }

    /// A DyorHQ launch named "USDC" — made directly on the factory, since the create forms refuse it — is a DyorHQ coin
    /// that warns: the imitation beats the label, and it shows its letters, never USDC's logo nor its own art.
    func testADyorHQLaunchNamedUSDCWarns() async throws {
        var chain = DyorCoinChain()
        let fake = Address(literal: "0x0000000000000000000000000000000000005dc1")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [DyorCoinChain.LaunchCoin(token: fake, name: "USD Coin", symbol: "USDC", logo: DyorCoinChain.media(DyorCoinChain.creator, "usdc.jpg"),
                                                                                            deployer: DyorCoinChain.creator, curve: Address(literal: "0x0000000000000000000000000000000000c0e003"))]
        let registry = registry(chain)
        await registry.refresh()
        let found = await registry.coin(fake)
        let coin = try XCTUnwrap(found, "it is a DyorHQ coin")
        let token = snapshot(fake, "USDC", "USD Coin")
        XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: false), .imitates(.usdc))
        XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: true), .imitates(.usdc))
        XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: policy), .letters)
        XCTAssertNotNil(SymbolSafety.createRefusal(name: "USD Coin", symbol: "USDC"), "the create forms refuse it")
    }

    /// JAMES, "The Busy Bull of Monad", came from nad.fun: no DyorHQ factory names it, so it isn't DyorHQ's, stays
    /// Unverified when it was sent to the wallet, and keeps its letters.
    func testJAMESStaysUnverified() async {
        let registry = registry(.mainnet)
        let proof = await registry.prove([DyorCoinChain.james])
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor)
        let james = snapshot(DyorCoinChain.james, "JAMES", "The Busy Bull of Monad")
        let coin = await registry.coin(DyorCoinChain.james)
        XCTAssertNil(coin)
        XCTAssertEqual(TokenBadge.of(james, coin: coin, receivedUnasked: true), .unverified)
        XCTAssertEqual(CoinIcon.resolve(james, coin: coin, policy: policy), .letters)
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == DyorCoinChain.james }, "nothing is asked of JAMES itself")
    }

    /// A chain read that fails labels nothing: the coin is unknown, never "DyorHQ Launch", and shows as today — Unverified
    /// if it was sent to the wallet — and it is asked again next time.
    func testAFailedReadLabelsNothing() async {
        MomentsChainStub.install({ DyorCoinChain.mainnet.answer($0, $1) }, refusing: ["eth_call"])
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        let complete = await registry.refresh()
        XCTAssertFalse(complete)
        let proof = await registry.prove([DyorCoinChain.qt])
        XCTAssertEqual(proof[DyorCoinChain.qt], .unknown)
        let coin = await registry.coin(DyorCoinChain.qt)
        XCTAssertNil(coin)
        let qt = snapshot(DyorCoinChain.qt, "QT", "Quet")
        XCTAssertEqual(TokenBadge.of(qt, coin: coin, receivedUnasked: true), .unverified)
        XCTAssertEqual(TokenBadge.of(qt, coin: coin, receivedUnasked: false), .none)
        XCTAssertEqual(CoinIcon.resolve(qt, coin: coin, policy: policy), .letters)

        DyorCoinChain.mainnet.install()
        let again = await registry.prove([DyorCoinChain.qt])
        guard case .dyor? = again[DyorCoinChain.qt] else { return XCTFail("asked again once the chain answers") }
    }
}
