import BigInt
import XCTest
@testable import DyorKit

/// Fixtures/launchpad.json was produced with viem 2.56 from the Solidity struct / function / event shapes in
/// contracts/src (see the generator in the session notes): every write's calldata, every getter's return blob,
/// and a set of curve event logs, all with fixed sample arguments. The launchpad contracts are not deployed on
/// Monad mainnet, so there are no live reads here — instead the Swift service's calldata is compared byte for
/// byte against viem, its decoders are run on the synthetic returns and asserted equal to what viem encoded, and
/// the trade / candle / activity parsers are exercised on canned logs. Because the fixture is built from the
/// contract source (not from the Swift signatures), a match confirms the Swift ABI surface is correct.
final class LaunchpadTests: XCTestCase {
    private static let fixture: JSON = {
        let url = Bundle.module.url(forResource: "launchpad", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }()

    private var f: JSON { Self.fixture }

    // MARK: Sample constants (mirror the generator)

    private let token = Address(literal: "0x1111111111111111111111111111111111111111")
    private let curve = Address(literal: "0x2222222222222222222222222222222222222222")
    private let deployer = Address(literal: "0x000000000000000000000000000000000000dead")
    private let recipient = Address(literal: "0x000000000000000000000000000000000000beef")
    private let creatorFeeRecipient = Address(literal: "0x000000000000000000000000000000000000cafe")
    private let factory = Address(literal: "0x00000000000000000000000000000000fac00000")
    private let router = Address(literal: "0x0000000000000000000000000000000000704e70")
    private let escrow = Address(literal: "0x00000000000000000000000000000000e5c00000")
    private let sharing = Address(literal: "0x0000000000000000000000000000000050ba0000")
    private let hook = Address(literal: "0x000000000000000000000000000000000000ac00")
    private let poolManager = Address(literal: "0x00000000000000000000000000000000900f0000")
    private let feeRecipient = Address(literal: "0x000000000000000000000000000000000000feed")
    private let buyer = Address(literal: "0x000000000000000000000000000000000000b0b0")
    private let seller = Address(literal: "0x0000000000000000000000000000000000005e11")
    private var usdc: Address { Monad.usdc }
    private var abil: Address { Token.abil.address }

    private let poolId = Data(hex: "0x" + String(repeating: "77", count: 32))!
    private let econHash = Data(hex: "0x" + String(repeating: "ab", count: 32))!
    private let salt = Data(hex: "0x" + String(repeating: "cd", count: 32))!

    private var monPair: PairInfo { .mon }
    private var usdcPair: PairInfo { PairInfo(address: usdc, symbol: "USDC", decimals: 6, isNative: false) }
    private var abilPair: PairInfo { PairInfo(address: abil, symbol: "aBIL", decimals: 18, isNative: false) }

    // MARK: Helpers

    private func hex(_ s: String) -> Data { Data(hex: s)! }
    private func bn(_ s: String) -> BigUInt { BigUInt(s)! }
    private func addr(_ j: JSON) -> Address { Address(j.string!)! }
    private func e6(_ n: Int) -> BigUInt { BigUInt(n) * 1_000_000 }
    private func e18(_ n: Int) -> BigUInt { BigUInt(n) * BigUInt(10).power(18) }
    private func cd(_ key: String) -> String { f["calldata"][key].string! }

    private var launchFee: BigUInt { bn(f["sample"]["launchFee"].string!) }
    private var initialBuy: BigUInt { e6(1000) }
    private var devMinOut: BigUInt { e18(5000) }
    private var buyQuoteIn: BigUInt { e6(750) }
    private var buyMinOut: BigUInt { e18(12345) }
    private var sellTokensIn: BigUInt { e18(500) }
    private var sellMinOut: BigUInt { e6(480) }

    private func makeService(deployed: Bool = true, generation: LaunchpadAddresses.Generation = .v1) -> LaunchpadService {
        let addresses = deployed
            ? LaunchpadAddresses(factory: factory, router: router, escrow: escrow, holderFeeSharing: sharing, hook: hook, poolManager: poolManager, generation: generation)
            : .none
        return LaunchpadService(rpc: RPCClient(url: Monad.defaultRPC), addresses: addresses)
    }

    private func makeLaunch(pairToken: Address, pair: PairInfo, holderFeeSharing: Bool = true, price: BigUInt = 0, poolId: Data = Data(repeating: 0, count: 32), symbol: String = "DYOR") -> Launch {
        Launch(token: token, curve: curve, deployer: deployer, creatorFeeRecipient: creatorFeeRecipient, pairToken: pairToken,
               graduationThreshold: e6(4000), creatorTaxBps: 250, poolFeeBps: 3000, tickSpacing: 60, holderFeeSharing: holderFeeSharing,
               graduationVenue: .uniswapV4, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: poolId, name: "Dyor Coin", symbol: symbol, logo: "",
               description: "", socials: .none, pair: pair, price: price, realQuoteReserve: 0, completed: false, rescued: false,
               launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0)
    }

    private func sampleInput(pairToken: Address, initialBuy: BigUInt, minTokensOut: BigUInt) -> LaunchInput {
        LaunchInput(
            name: "Dyor Coin", symbol: "DYOR", description: "A test launch", logo: "ipfs://logo",
            socials: Socials(twitter: "dyor", telegram: "tg", discord: "", website: "https://dyor.hq", farcaster: "fc"),
            creatorFeeRecipient: creatorFeeRecipient, creatorTaxBps: 250, holderFeeSharing: true,
            pairToken: pairToken, configId: 0, exemptions: [deployer, recipient],
            initialBuy: initialBuy, minTokensOut: minTokensOut, expectedEconomics: econHash, salt: salt
        )
    }

    private func log(_ j: JSON) -> Log {
        Log(address: addr(j["address"]), topics: j["topics"].array!.map { hex($0.string!) }, data: hex(j["data"].string!),
            blockNumber: UInt64(j["block"].number!), transactionHash: hex(j["tx"].string!), logIndex: Int(j["logIndex"].number!))
    }

    // MARK: - Write calldata parity (byte-for-byte vs viem)

    func testLaunchPlanCalldataMatchesViem() async throws {
        let service = makeService()

        // launchToken: no developer buy, native pair -> one call to the factory carrying the launch fee.
        let plain = try await service.launchPlan(sampleInput(pairToken: .zero, initialBuy: 0, minTokensOut: 0), launchFee: launchFee, from: recipient)
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain[0].request?.to, factory)
        XCTAssertEqual(plain[0].request?.data.hexString, cd("launchToken"))
        XCTAssertEqual(plain[0].request?.value, launchFee)

        // launchAndBuy with an ERC-20 pair: approve the pair for the router, then call the router (fee only as value).
        let usdcBuy = try await service.launchPlan(sampleInput(pairToken: usdc, initialBuy: initialBuy, minTokensOut: devMinOut), launchFee: launchFee, from: recipient)
        XCTAssertEqual(usdcBuy.count, 2)
        XCTAssertEqual(usdcBuy[0].kind, .approve(token: usdc, spender: router, amount: initialBuy))
        XCTAssertEqual(usdcBuy[1].request?.to, router)
        XCTAssertEqual(usdcBuy[1].request?.data.hexString, cd("launchAndBuyUSDC"))
        XCTAssertEqual(usdcBuy[1].request?.value, launchFee)
        XCTAssertEqual(try! ERC20.approveCalldata(spender: router, amount: initialBuy).hexString, cd("approvePairForRouter"))

        // launchAndBuy with a native pair: no approval, value = fee + developer buy.
        let nativeBuy = try await service.launchPlan(sampleInput(pairToken: .zero, initialBuy: initialBuy, minTokensOut: devMinOut), launchFee: launchFee, from: recipient)
        XCTAssertEqual(nativeBuy.count, 1)
        XCTAssertEqual(nativeBuy[0].request?.to, router)
        XCTAssertEqual(nativeBuy[0].request?.data.hexString, cd("launchAndBuyNative"))
        XCTAssertEqual(nativeBuy[0].request?.value, launchFee + initialBuy)
    }

    func testBuyPlanCalldataMatchesViem() async throws {
        let service = makeService()

        // Native pair: a single buy carrying the quote as value, no approval.
        let native = try await service.buyPlan(launch: makeLaunch(pairToken: .zero, pair: monPair), quoteIn: buyQuoteIn, minTokensOut: buyMinOut, recipient: recipient)
        XCTAssertEqual(native.count, 1)
        XCTAssertEqual(native[0].kind, .call)
        XCTAssertEqual(native[0].request?.to, curve)
        XCTAssertEqual(native[0].request?.data.hexString, cd("buy"))
        XCTAssertEqual(native[0].request?.value, buyQuoteIn)

        // ERC-20 pair: approve the pair for the curve first, then buy with zero value.
        let erc20 = try await service.buyPlan(launch: makeLaunch(pairToken: usdc, pair: usdcPair), quoteIn: buyQuoteIn, minTokensOut: buyMinOut, recipient: recipient)
        XCTAssertEqual(erc20.count, 2)
        XCTAssertEqual(erc20[0].kind, .approve(token: usdc, spender: curve, amount: buyQuoteIn))
        XCTAssertEqual(erc20[1].request?.data.hexString, cd("buy"))
        XCTAssertEqual(erc20[1].request?.value, 0)
        XCTAssertEqual(try! ERC20.approveCalldata(spender: curve, amount: buyQuoteIn).hexString, cd("approvePairForCurve"))
    }

    func testSellPlanCalldataMatchesViem() async {
        let service = makeService()
        let plan = await service.sellPlan(launch: makeLaunch(pairToken: usdc, pair: usdcPair), tokensIn: sellTokensIn, minQuoteOut: sellMinOut, recipient: recipient)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].kind, .approve(token: token, spender: curve, amount: sellTokensIn))
        XCTAssertEqual(plan[1].request?.to, curve)
        XCTAssertEqual(plan[1].request?.data.hexString, cd("sell"))
        XCTAssertEqual(plan[1].request?.value, 0)
        XCTAssertEqual(try! ERC20.approveCalldata(spender: curve, amount: sellTokensIn).hexString, cd("approveTokenForCurve"))
    }

    func testClaimAndAdminPlansMatchViem() async {
        let service = makeService()
        let native = makeLaunch(pairToken: .zero, pair: monPair, poolId: poolId)
        let erc20 = makeLaunch(pairToken: usdc, pair: usdcPair, poolId: poolId)

        // Holder rewards, unknown state: claim on the sharing contract only.
        let rewards = await service.claimRewardsPlan(launch: native)
        XCTAssertEqual(rewards.count, 1)
        XCTAssertEqual(rewards[0].request?.to, sharing)
        XCTAssertEqual(rewards[0].request?.data.hexString, cd("claimHolder"))

        // With a view: holder claim + escrow claim (native escrow uses claim()).
        let both = await service.claimRewardsPlan(launch: native, view: LaunchAccountView(tokenBalance: 0, pairBalance: 0, allowance: 0, snipeTaxBps: 0, pendingRewards: 5, escrowBalance: 9))
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[0].request?.data.hexString, cd("claimHolder"))
        XCTAssertEqual(both[1].request?.to, escrow)
        XCTAssertEqual(both[1].request?.data.hexString, cd("claimEscrowNative"))

        // No pending rewards but escrow due: holder claim is skipped (it would revert).
        let escrowOnly = await service.claimRewardsPlan(launch: native, view: LaunchAccountView(tokenBalance: 0, pairBalance: 0, allowance: 0, snipeTaxBps: 0, pendingRewards: 0, escrowBalance: 9))
        XCTAssertEqual(escrowOnly.count, 1)
        XCTAssertEqual(escrowOnly[0].request?.to, escrow)
        XCTAssertEqual(escrowOnly[0].request?.data.hexString, cd("claimEscrowNative"))

        // ERC-20 escrow claim targets the pair token.
        let claimToken = await service.claimEscrowPlan(launch: erc20)
        XCTAssertEqual(claimToken[0].request?.to, escrow)
        XCTAssertEqual(claimToken[0].request?.data.hexString, cd("claimEscrowToken"))

        // graduate(token) on the factory.
        let graduate = await service.graduatePlan(launch: erc20)
        XCTAssertEqual(graduate[0].request?.to, factory)
        XCTAssertEqual(graduate[0].request?.data.hexString, cd("graduate"))

        // sweepPoolFees(poolId, currency) on the hook, defaulting the currency to the pair token.
        let sweep = await service.sweepPoolFeesPlan(launch: erc20)
        XCTAssertEqual(sweep[0].request?.to, hook)
        XCTAssertEqual(sweep[0].request?.data.hexString, cd("sweepPoolFees"))
    }

    // MARK: - Decode synthetic returns (asserted equal to what viem encoded)

    func testDecodeLaunchedRecord() throws {
        let tuple = try ABI.decode(hex(f["returns"]["getLaunchedToken"].string!), LaunchpadABI.launchedTokenTuple)[0]
        let r = LaunchpadABI.LaunchRecord(tuple)
        let d = f["decoded"]["launchedToken"]
        XCTAssertEqual(r.token, addr(d["token"]))
        XCTAssertEqual(r.curve, addr(d["curve"]))
        XCTAssertEqual(r.deployer, addr(d["deployer"]))
        XCTAssertEqual(r.creatorFeeRecipient, addr(d["creatorFeeRecipient"]))
        XCTAssertEqual(r.pairToken, addr(d["pairToken"]))
        XCTAssertEqual(r.graduationThreshold, bn(d["graduationThreshold"].string!))
        XCTAssertEqual(r.creatorTaxBps, 250)
        XCTAssertEqual(r.poolFeeBps, 3000)
        XCTAssertEqual(r.tickSpacing, 60)
        XCTAssertTrue(r.holderFeeSharing)
        XCTAssertEqual(r.graduationVenue, .monday, "graduationVenue 1 decodes to .monday, and every field after it stays aligned")
        XCTAssertEqual(r.phase, .graduated, "phase 2 == PoolCreated maps to .graduated")
        XCTAssertEqual(r.sweptQuote, bn(d["sweptQuote"].string!))
        XCTAssertEqual(r.sweptTokens, bn(d["sweptTokens"].string!))
        XCTAssertEqual(r.sweptAt, 1_700_000_000)
        XCTAssertEqual(r.poolId.hexString, d["poolId"].string!)
        XCTAssertTrue(r.exists)
    }

    func testDecodeLaunchConfig() throws {
        let tuple = try ABI.decode(hex(f["returns"]["getLaunchConfig"].string!), LaunchpadABI.launchConfigTuple)[0]
        let c = LaunchpadABI.LaunchConfig(tuple)
        let d = f["decoded"]["launchConfig"]
        XCTAssertEqual(c.supply, bn(d["supply"].string!))
        XCTAssertEqual(c.curveFeeBps, 100)
        XCTAssertEqual(c.poolFeeBps, 3000)
        XCTAssertEqual(c.tickSpacing, 60)
        XCTAssertEqual(c.snipeTaxSchedule, [500, 400, 300, 200, 100])
        XCTAssertTrue(c.enabled)
    }

    func testDecodeTokenInfo() throws {
        let values = try ABI.decode(hex(f["returns"]["tokenInfo"].string!), "address,string,string,\(LaunchpadABI.socialsTuple)")
        let info = LaunchpadABI.TokenInfo(values)
        XCTAssertEqual(info.deployer, deployer)
        XCTAssertEqual(info.logo, "ipfs://logo")
        XCTAssertEqual(info.description, "A test launch")
        XCTAssertEqual(info.socials.twitter, "dyor")
        XCTAssertEqual(info.socials.telegram, "tg")
        XCTAssertEqual(info.socials.discord, "")
        XCTAssertEqual(info.socials.website, "https://dyor.hq")
        XCTAssertEqual(info.socials.farcaster, "fc")
    }

    func testDecodeQuotes() throws {
        let bq = LaunchpadABI.buyQuote(try ABI.decode(hex(f["returns"]["quoteBuy"].string!), "uint256,uint256,uint256,uint256,uint256,uint256"))
        let d = f["decoded"]["quoteBuy"]
        XCTAssertEqual(bq.tokensOut, bn(d["tokensOut"].string!))
        XCTAssertEqual(bq.used, bn(d["used"].string!))
        XCTAssertEqual(bq.fee, bn(d["fee"].string!))
        XCTAssertEqual(bq.tax, bn(d["tax"].string!))
        XCTAssertEqual(bq.snipe, bn(d["snipe"].string!))
        XCTAssertEqual(bq.refund, 0)
        // minimumOut applies the web formula out * (10000 - slippage) / 10000.
        XCTAssertEqual(bq.minimumOut(slippageBps: 100), bq.tokensOut * 9_900 / 10_000)

        let sq = LaunchpadABI.sellQuote(try ABI.decode(hex(f["returns"]["quoteSell"].string!), "uint256,uint256,uint256"))
        let s = f["decoded"]["quoteSell"]
        XCTAssertEqual(sq.quoteOut, bn(s["quoteOut"].string!))
        XCTAssertEqual(sq.fee, bn(s["fee"].string!))
        XCTAssertEqual(sq.tax, bn(s["tax"].string!))
        XCTAssertEqual(sq.minimumOut(slippageBps: 250), sq.quoteOut * 9_750 / 10_000)
    }

    func testDecodeFeePolicyAndPoolKey() throws {
        let policy = try ABI.decode(hex(f["returns"]["feePolicy"].string!), "(address,uint16)")[0]
        XCTAssertEqual(policy[0].address, feeRecipient)
        XCTAssertEqual(LaunchpadABI.int(policy[1]), 1000)

        let pk = LaunchpadABI.poolKey(try ABI.decode(hex(f["returns"]["poolKey"].string!), LaunchpadABI.poolKeyTuple)[0])
        XCTAssertEqual(pk.currency0, .zero)
        XCTAssertEqual(pk.currency1, usdc)
        XCTAssertEqual(pk.fee, 3000)
        XCTAssertEqual(pk.tickSpacing, 60)
        XCTAssertEqual(pk.hooks, hook)
    }

    /// pairTokenEconomics decode for a 6-decimal pair (USDC/AUSD shape) and an 18-decimal pair (aBIL): the raw
    /// reserves are the same layout, and the per-pair decimals turn them into the right human amounts.
    func testDecodePairEconomicsPerDecimals() throws {
        let usdcVals = try ABI.decode(hex(f["returns"]["pairEconomicsUSDC"].string!), "uint256,uint256,uint8,bool")
        XCTAssertEqual(usdcVals[0].uint, e6(1000))
        XCTAssertEqual(usdcVals[1].uint, e6(4000))
        XCTAssertEqual(LaunchpadABI.int(usdcVals[2]), 6)
        XCTAssertTrue(usdcVals[3].bool)
        let usdcEcon = PairEconomics(pair: usdcPair, phantomQuote: usdcVals[0].uint, graduationThreshold: usdcVals[1].uint, approved: usdcVals[3].bool)
        XCTAssertEqual(Amount.units(usdcEcon.phantomQuote, decimals: usdcEcon.pair.decimals), 1_000, accuracy: 1e-6)
        XCTAssertEqual(Amount.units(usdcEcon.graduationThreshold, decimals: usdcEcon.pair.decimals), 4_000, accuracy: 1e-6)

        let abilVals = try ABI.decode(hex(f["returns"]["pairEconomicsABIL"].string!), "uint256,uint256,uint8,bool")
        XCTAssertEqual(abilVals[0].uint, e18(500))
        XCTAssertEqual(abilVals[1].uint, e18(2000))
        XCTAssertEqual(LaunchpadABI.int(abilVals[2]), 18)
        let abilEcon = PairEconomics(pair: abilPair, phantomQuote: abilVals[0].uint, graduationThreshold: abilVals[1].uint, approved: abilVals[3].bool)
        XCTAssertEqual(Amount.units(abilEcon.phantomQuote, decimals: abilEcon.pair.decimals), 500, accuracy: 1e-6)
        XCTAssertEqual(Amount.units(abilEcon.graduationThreshold, decimals: abilEcon.pair.decimals), 2_000, accuracy: 1e-6)
    }

    // MARK: - Retired stacks (real mainnet return blobs, fetched with `cast call` on 2026-09-23)

    /// `getLaunchedToken(0x73F9…)` on the first factory 0xad3d…: the legacy 16-field record of a MON launch that
    /// graduated to the Monday pool 0x7248…, whose address is the record's `poolId`.
    private static let legacyRecordWords = [
        "00000000000000000000000073f942e084ab047a94e4e3b5d6ae571e23a51856",
        "00000000000000000000000074e552a81eef9ccc77eba745164755a64f216002",
        "00000000000000000000000090f3e7c3b4e32494b06814fd2f4556671f5f4c47",
        "00000000000000000000000090f3e7c3b4e32494b06814fd2f4556671f5f4c47",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "000000000000000000000000000000000000000000000015af1d78b58c400000",
        "0000000000000000000000000000000000000000000000000000000000000032",
        "0000000000000000000000000000000000000000000000000000000000000064",
        "000000000000000000000000000000000000000000000000000000000000003c",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000002",
        "000000000000000000000000000000000000000000000015af1d78b58c400000",
        "000000000000000000000000000000000000000000a56fa5b99019a5c8240e13",
        "000000000000000000000000000000000000000000000000000000006aa3c618",
        "00000000000000000000000072484c6c9f2a41dd9f34c61584bcd2b72eeef325",
        "0000000000000000000000000000000000000000000000000000000000000001",
    ]

    /// `getLaunchedToken(0xA4D9…)` on the retired factory 0x10F3…: the current 17-field record of a bonding MON launch.
    private static let currentRecordWords = [
        "000000000000000000000000a4d9b2697254292ad30e06ce968a7e18de6ff884",
        "000000000000000000000000be36bd571e1f4d7e25f4fc891fc8407460feb9e6",
        "0000000000000000000000006115caf237026b45b037191b20056d1e4afaffa3",
        "0000000000000000000000006115caf237026b45b037191b20056d1e4afaffa3",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000029b2e31f32c7b0fc4bf8",
        "0000000000000000000000000000000000000000000000000000000000000064",
        "0000000000000000000000000000000000000000000000000000000000000064",
        "000000000000000000000000000000000000000000000000000000000000003c",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000001",
    ]

    /// The record as one return blob, with small integer `overrides` (word index → value) written in.
    private func blob(_ words: [String], replacing overrides: [Int: Int] = [:]) -> Data {
        var words = words
        for (index, value) in overrides {
            let digits = String(value, radix: 16)
            words[index] = String(repeating: "0", count: 64 - digits.count) + digits
        }
        return hex("0x" + words.joined())
    }

    func testDecodeLegacyRecordFromMainnet() throws {
        let tuple = try ABI.decode(blob(Self.legacyRecordWords), LaunchpadABI.launchedTokenReturns(legacy: true))[0]
        let r = LaunchpadABI.LaunchRecord(tuple, legacy: true)
        XCTAssertEqual(r.token, Address(literal: "0x73F942e084Ab047a94e4E3B5D6ae571e23A51856"))
        XCTAssertEqual(r.curve, Address(literal: "0x74E552A81eeF9ccC77Eba745164755a64f216002"))
        XCTAssertEqual(r.deployer, Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47"))
        XCTAssertEqual(r.creatorFeeRecipient, r.deployer)
        XCTAssertEqual(r.pairToken, .zero)
        XCTAssertEqual(r.graduationThreshold, e18(400))
        XCTAssertEqual(r.creatorTaxBps, 50)
        XCTAssertEqual(r.poolFeeBps, 100)
        XCTAssertEqual(r.tickSpacing, 60)
        XCTAssertFalse(r.holderFeeSharing)
        XCTAssertEqual(r.graduationVenue, .monday, "the legacy record has no venue field; every launch on that factory is Monday")
        XCTAssertEqual(r.phase, .graduated)
        XCTAssertEqual(r.sweptQuote, e18(400))
        XCTAssertEqual(r.sweptTokens, bn("200000000000000000002362899"))
        XCTAssertEqual(r.sweptAt, 1_789_117_976)
        XCTAssertEqual(r.poolId.hexString, "0x00000000000000000000000072484c6c9f2a41dd9f34c61584bcd2b72eeef325")
        XCTAssertTrue(r.exists)
        // Read as the current 17-field tuple, the 16-word blob does not decode, which is why the stack is flagged.
        XCTAssertThrowsError(try ABI.decode(blob(Self.legacyRecordWords), LaunchpadABI.launchedTokenTuple))
    }

    /// QT's Monday Trade pool (0x7248…, the record's poolId) prices it from its own `slot0()` (mainnet word,
    /// 2026-09-23; token0 = WMON): ~2.084e-6 MON per QT, not the curve's final 2.5e-6.
    func testMondayGraduatedPoolPrice() {
        let slot0 = hex("0x00000000000000000000000000000000000002b4afdc075311eaca037b2aef49")
        let price = LaunchpadMath.poolPrice(slot0: slot0, token: Address(literal: "0x73F942e084Ab047a94e4E3B5D6ae571e23A51856"), pairToken: Monad.wmon)
        XCTAssertEqual(price, 2_084_135_672_368)
    }

    func testDecodeCurrentRecordFromMainnet() throws {
        let tuple = try ABI.decode(blob(Self.currentRecordWords), LaunchpadABI.launchedTokenReturns(legacy: false))[0]
        let r = LaunchpadABI.LaunchRecord(tuple)
        XCTAssertEqual(r.token, Address(literal: "0xA4D9b2697254292AD30E06ce968a7E18DE6fF884"))
        XCTAssertEqual(r.curve, Address(literal: "0xbe36BD571e1f4d7E25f4Fc891fC8407460fEb9e6"))
        XCTAssertEqual(r.pairToken, .zero)
        XCTAssertEqual(r.graduationThreshold, bn("196916912098179890826232"))
        XCTAssertEqual(r.creatorTaxBps, 100)
        XCTAssertEqual(r.poolFeeBps, 100)
        XCTAssertEqual(r.tickSpacing, 60)
        XCTAssertFalse(r.holderFeeSharing)
        XCTAssertEqual(r.graduationVenue, .uniswapV4)
        XCTAssertEqual(r.phase, .bonding)
        XCTAssertEqual(r.sweptQuote, 0)
        XCTAssertTrue(r.exists)
    }

    /// The swap venue reads `exists` at [16], `phase` at [11] and `graduationVenue` at [10] of the 17-field record.
    func testSwapLaunchedTokenIndices() throws {
        let returns = try SwapCalldata.launchedToken(factory: factory, token: token).returnTypes
        func record(_ overrides: [Int: Int]) throws -> ABIValue { try ABI.decode(blob(Self.currentRecordWords, replacing: overrides), returns)[0] }

        let bonding = try record([:])
        XCTAssertTrue(bonding[16].bool)
        XCTAssertEqual(bonding[11].uint, 0)
        XCTAssertEqual(bonding[10].uint, 0)
        XCTAssertFalse(SwapCalldata.graduatedOnV4(bonding), "still on the curve: no pool to route through")

        XCTAssertTrue(SwapCalldata.graduatedOnV4(try record([11: 2])), "PoolCreated on Uniswap v4")
        XCTAssertFalse(SwapCalldata.graduatedOnV4(try record([11: 2, 10: 1])), "PoolCreated on Monday Trade is not a v4 pool")
        XCTAssertFalse(SwapCalldata.graduatedOnV4(try record([11: 1])), "Swept (migrating) has no pool yet")
        XCTAssertFalse(SwapCalldata.graduatedOnV4(try record([11: 2, 16: 0])), "an unknown token does not exist")

        // The synthetic viem fixture (venue Monday, phase PoolCreated) decodes the same way.
        let synthetic = try ABI.decode(hex(f["returns"]["getLaunchedToken"].string!), returns)[0]
        XCTAssertEqual(synthetic[10].uint, 1)
        XCTAssertEqual(synthetic[11].uint, 2)
        XCTAssertTrue(synthetic[16].bool)
        XCTAssertFalse(SwapCalldata.graduatedOnV4(synthetic))
    }

    /// Every per-launch plan goes to the launch's own stack; `.zero` and the live factory mean the live (v2) stack.
    func testPlansTargetTheLaunchStack() async throws {
        let service = makeService(generation: .v2)
        let retired = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        let auditFix = try XCTUnwrap(LaunchpadAddresses.retiredStack(for: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7")))
        let legacy = try XCTUnwrap(LaunchpadAddresses.retiredStacks.last)
        func launch(on factory: Address) -> Launch {
            let l = makeLaunch(pairToken: usdc, pair: usdcPair, poolId: poolId)
            return Launch(token: l.token, curve: l.curve, deployer: l.deployer, creatorFeeRecipient: l.creatorFeeRecipient, pairToken: l.pairToken,
                          graduationThreshold: l.graduationThreshold, creatorTaxBps: l.creatorTaxBps, poolFeeBps: l.poolFeeBps, tickSpacing: l.tickSpacing,
                          holderFeeSharing: l.holderFeeSharing, graduationVenue: .monday, phase: l.phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: l.poolId,
                          name: l.name, symbol: l.symbol, logo: "", description: "", socials: .none, pair: l.pair, price: 0, realQuoteReserve: 0,
                          completed: false, rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
        }

        // v2: no in-app fallback (it needs ~22M gas, over the app's 15M cap); DyorHQ's keepers take it.
        for live in [launch(on: .zero), launch(on: factory)] {
            XCTAssertFalse(live.isRetiredLaunchpad)
            let rewards = await service.claimRewardsPlan(launch: live)
            XCTAssertEqual(rewards[0].request?.to, sharing)
            let graduate = await service.graduatePlan(launch: live)
            XCTAssertEqual(graduate.map { $0.request?.to }, [factory], "Retry Graduation stays: plain graduate, gas estimated")
        }
        XCTAssertTrue(launch(on: .zero).keepersTakeGraduateFallback)

        // v1 (0x6B1C, 0x10F3): the keepers take the fallback there too; the app only retries the plain graduation.
        for stack in [retired, auditFix] {
            XCTAssertEqual(stack.generation, .v1)
            let v1 = launch(on: stack.factory)
            XCTAssertTrue(v1.keepersTakeGraduateFallback)
            let graduate = await service.graduatePlan(launch: v1)
            XCTAssertEqual(graduate.map { $0.request?.to }, [stack.factory])
            XCTAssertEqual(graduate.first?.request?.data, LaunchpadABI.calldata(LaunchpadABI.Factory.graduate, [.address(v1.token)]))
        }

        let old = launch(on: retired.factory)
        XCTAssertTrue(old.isRetiredLaunchpad)
        let rewards = await service.claimRewardsPlan(launch: old, view: LaunchAccountView(tokenBalance: 0, pairBalance: 0, allowance: 0, snipeTaxBps: 0, pendingRewards: 1, escrowBalance: 1))
        XCTAssertEqual(rewards.map { $0.request?.to }, [retired.holderFeeSharing, retired.escrow])
        XCTAssertEqual(rewards[1].request?.data.hexString, cd("claimEscrowToken"))
        let graduate = await service.graduatePlan(launch: old)
        XCTAssertEqual(graduate[0].request?.to, retired.factory)
        let sweep = await service.sweepPoolFeesPlan(launch: old)
        XCTAssertEqual(sweep[0].request?.to, retired.hook)
        XCTAssertEqual(sweep[0].request?.data.hexString, cd("sweepPoolFees"))

        // The pre-audit stacks (0x2F02, 0xad3d) have no `graduateFallback` at all: nothing for the keepers to take either.
        let preAuditStacks = LaunchpadAddresses.retiredStacks.filter { $0.generation < .v1 }
        XCTAssertEqual(preAuditStacks.map(\.generation), [.preAudit, .legacy])
        for stack in preAuditStacks {
            let preAudit = launch(on: stack.factory)
            XCTAssertFalse(preAudit.generation.hasGraduateFallback)
            XCTAssertFalse(preAudit.keepersTakeGraduateFallback)
        }
        let legacyEscrow = await service.claimEscrowPlan(launch: launch(on: legacy.factory))
        XCTAssertEqual(legacyEscrow[0].request?.to, legacy.escrow)

        // Escrow sweeps default to the live escrow and take another stack's on request.
        let liveSweep = await service.claimEscrowPlan(native: true, tokens: [usdc])
        XCTAssertEqual(liveSweep.map { $0.request?.to }, [escrow, escrow])
        let retiredSweep = await service.claimEscrowPlan(native: true, tokens: [usdc], escrow: retired.escrow)
        XCTAssertEqual(retiredSweep.map { $0.request?.to }, [retired.escrow, retired.escrow])

        // Stacks: live first, then every retired one; an unknown factory resolves to itself alone.
        let stacks = await service.stacks
        XCTAssertEqual(stacks.map(\.factory), [factory] + LaunchpadAddresses.retiredFactories)
        let unknown = Address(literal: "0x00000000000000000000000000000000000f00d0")
        let alone = await service.stack(for: unknown)
        XCTAssertEqual(alone.factory, unknown)
        XCTAssertTrue(alone.escrow.isZero)
        XCTAssertTrue(alone.holderFeeSharing.isZero)
    }

    // MARK: - Derived quantities (checked against the web formulas)

    func testMarketCapAndProgress() {
        for c in f["derived"]["marketCap"].array! {
            XCTAssertEqual(LaunchpadMath.marketCap(price: bn(c["price"].string!), supply: bn(c["supply"].string!)), bn(c["expected"].string!))
        }
        for c in f["derived"]["progress"].array! {
            let phase = LaunchPhase(rawValue: Int(c["phase"].number!))!
            XCTAssertEqual(
                LaunchpadMath.progressBps(phase: phase, realQuoteReserve: bn(c["real"].string!), sweptQuote: bn(c["swept"].string!), threshold: bn(c["threshold"].string!)),
                Int(c["expected"].number!), "\(c)"
            )
        }
    }

    /// The board's Market Cap sort compares every pair asset in dollars, from each coin's decimal price
    /// (`Launch.marketCapInPair`): a 50,000 USDC coin above a 1 MON coin, an aBIL coin by aBIL's price, a coin whose pair
    /// has no price yet after every priced one, by its cap in whole units, and a coin whose own price wasn't read last.
    /// The integer `Launch.marketCap` (raw units, from the rounded `price()`) never decides.
    func testMarketCapSortComparesPairAssetsInDollars() {
        let usdc = PairInfo(address: Monad.usdc, symbol: "USDC", decimals: 6, isNative: false)
        let ausd = PairInfo(address: Monad.ausd, symbol: "AUSD", decimals: 6, isNative: false)
        let abil = PairInfo(address: Token.abil.address, symbol: "aBIL", decimals: 18, isNative: false)
        /// One whole coin at `cap` whole pair units, its raw integer cap `raw`.
        func launch(_ n: UInt8, _ pair: PairInfo, cap: Double?, raw: BigUInt = 0) -> Launch {
            Launch(token: Address(data: Data(repeating: n, count: 20))!, curve: curve, deployer: deployer, creatorFeeRecipient: creatorFeeRecipient, pairToken: pair.address,
                   graduationThreshold: 0, creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .uniswapV4, phase: .bonding,
                   sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(repeating: 0, count: 32), name: "Coin \(n)", symbol: "C\(n)", logo: "", description: "",
                   socials: .none, pair: pair, price: 0, realQuoteReserve: 0, completed: false, rescued: false, launchedAt: Int(n), supply: e18(1), marketCap: raw, progressBps: 0,
                   pairPrice: cap)
        }
        let oneMON = launch(1, .mon, cap: 1, raw: e18(1))
        let bigUSDC = launch(2, usdc, cap: 50_000, raw: e6(50_000))
        let smallAUSD = launch(3, ausd, cap: 2, raw: e6(2))
        let abilCoin = launch(4, abil, cap: 30, raw: e18(30))
        let unpriced = launch(5, PairInfo(address: Address(literal: "0x00000000000000000000000000000000000a0005"), symbol: "NEW", decimals: 18, isNative: false), cap: 1_000_000, raw: e18(1_000_000))
        let prices: [Address: Double] = [Monad.native: 0.03, Monad.usdc: 1, Monad.ausd: 1, Token.abil.address: 101]
        let sorted = LaunchpadMath.byMarketCap([oneMON, smallAUSD, unpriced, bigUSDC, abilCoin], pairUSD: prices)
        XCTAssertEqual(sorted.map(\.symbol), ["C2", "C4", "C3", "C1", "C5"], "50,000 USDC, 30 aBIL ($3,030), 2 AUSD, 1 MON ($0.03), then the unpriced one")
        // Raw amounts alone would have put every 6-decimal coin last.
        XCTAssertEqual([oneMON, smallAUSD, unpriced, bigUSDC, abilCoin].sorted { $0.marketCap > $1.marketCap }.map(\.symbol), ["C5", "C4", "C1", "C2", "C3"])
        // With no prices at all, whole units still compare across decimals; equal caps keep their order.
        XCTAssertEqual(LaunchpadMath.byMarketCap([oneMON, smallAUSD, bigUSDC], pairUSD: [:]).map(\.symbol), ["C2", "C3", "C1"])
        XCTAssertEqual(LaunchpadMath.byMarketCap([launch(6, usdc, cap: 5), launch(7, ausd, cap: 5)], pairUSD: prices).map(\.symbol), ["C6", "C7"])
        // A USDC coin at a true $0.0000035 over 1B coins is a $3,500 cap, which the rounded price() puts at $3,000: the
        // decimal one ranks it above a $3,200 coin. One whose price wasn't read ranks after both, whatever its raw cap.
        let dust = launch(8, usdc, cap: 3_500, raw: e6(3_000))
        let middle = launch(9, usdc, cap: 3_200, raw: e6(3_200))
        let unread = launch(10, usdc, cap: nil, raw: e6(9_999))
        XCTAssertEqual(LaunchpadMath.byMarketCap([unread, middle, dust], pairUSD: prices).map(\.symbol), ["C8", "C9", "C10"])
    }

    func testPhaseMappingAndDecimalPrice() {
        XCTAssertEqual(LaunchPhase(raw: BigUInt(0)), .bonding)
        XCTAssertEqual(LaunchPhase(raw: BigUInt(1)), .migrating)
        XCTAssertEqual(LaunchPhase(raw: BigUInt(2)), .graduated)
        XCTAssertEqual(LaunchPhase(raw: BigUInt(3)), .refund)
        XCTAssertEqual(LaunchPhase(raw: BigUInt(99)), .bonding, "an unknown phase falls back to bonding")

        // A launch is valued at its decimal price alone: dollars are pairPrice × the pair's dollar price, the cap is
        // pairPrice × the whole supply, and without a decimal price there is neither, whatever the integer price says.
        let priced = Launch(token: token, curve: curve, deployer: deployer, creatorFeeRecipient: creatorFeeRecipient, pairToken: usdc,
                            graduationThreshold: e6(4000), creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false,
                            graduationVenue: .uniswapV4, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32), name: "Dyor Coin",
                            symbol: "DYOR", logo: "", description: "", socials: .none, pair: usdcPair, price: 3, realQuoteReserve: 0, completed: false, rescued: false,
                            launchedAt: 0, supply: e18(1_000_000_000), marketCap: e6(3_000), progressBps: 0, pairPrice: 0.0000035)
        XCTAssertEqual(try XCTUnwrap(priced.usdPrice(pairUSD: 1)), 0.0000035, accuracy: 1e-18)
        XCTAssertEqual(try XCTUnwrap(priced.marketCapInPair), 3_500, accuracy: 1e-6)
        XCTAssertNil(priced.usdPrice(pairUSD: nil), "no pair price, no dollars")
        let unread = makeLaunch(pairToken: usdc, pair: usdcPair, price: e6(2))
        XCTAssertNil(unread.pairPrice)
        XCTAssertNil(unread.usdPrice(pairUSD: 1), "never the integer price()")
        XCTAssertNil(unread.marketCapInPair)
        for bad in [0, -1, Double.nan, .infinity] {
            let launch = Launch(token: token, curve: curve, deployer: deployer, creatorFeeRecipient: creatorFeeRecipient, pairToken: usdc, graduationThreshold: 0,
                                creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .uniswapV4, phase: .bonding, sweptQuote: 0,
                                sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32), name: "Dyor Coin", symbol: "DYOR", logo: "", description: "", socials: .none,
                                pair: usdcPair, price: 3, realQuoteReserve: 0, completed: false, rescued: false, launchedAt: 0, supply: e18(1), marketCap: 0,
                                progressBps: 0, pairPrice: bad)
            XCTAssertNil(launch.pairPrice, "\(bad) is no price")
        }
    }

    func testPoolPriceAndSlot() {
        for c in f["derived"]["poolPrice"].array! {
            let result = LaunchpadMath.poolPrice(slot0: hex(c["slot0"].string!), token: addr(c["token"]), pairToken: addr(c["pairToken"]))
            if c["expected"].isNull {
                XCTAssertNil(result)
            } else {
                XCTAssertEqual(result, bn(c["expected"].string!), "\(c)")
            }
        }
        XCTAssertEqual(LaunchpadABI.slot0(of: poolId).hexString, f["derived"]["slot0Slot"].string!)
    }

    // MARK: - Event topics and log parsing

    func testEventTopicsMatchKeccak() {
        // The Transfer topic is a well-known constant, so this pins eventTopic to real keccak, not the fixture alone.
        XCTAssertEqual(ABI.eventTopic("Transfer(address,address,uint256)").hexString, "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
        XCTAssertEqual(ABI.eventTopic("Transfer(address,address,uint256)").hexString, f["events"]["topics"]["transfer"].string!)
        XCTAssertEqual(LaunchpadABI.Events.buyTopic.hexString, f["events"]["topics"]["buy"].string!)
        XCTAssertEqual(LaunchpadABI.Events.sellTopic.hexString, f["events"]["topics"]["sell"].string!)
        XCTAssertEqual(LaunchpadABI.Events.launchedTopic.hexString, f["events"]["topics"]["launched"].string!)
        XCTAssertEqual(LaunchpadABI.Events.graduatedTopic.hexString, f["events"]["topics"]["graduated"].string!)
        XCTAssertEqual(RPCClient.eventTopic("CurveBuy(address,address,uint256,uint256,uint256,uint256)"), ABI.eventTopic("CurveBuy(address,address,uint256,uint256,uint256,uint256)"))
    }

    func testLogFilterAndLogEncoding() {
        let filter = LogFilter(address: curve, topics: [LaunchpadABI.Events.buyTopic, nil], fromBlock: 100, toBlock: 200)
        XCTAssertEqual(filter.json["fromBlock"].string, "0x64")
        XCTAssertEqual(filter.json["toBlock"].string, "0xc8")
        XCTAssertEqual(filter.json["address"].string, curve.hex)
        XCTAssertEqual(filter.json["topics"][0].string, LaunchpadABI.Events.buyTopic.hexString)
        XCTAssertTrue(filter.json["topics"][1].isNull)

        // A filter with no address omits the key; an empty topic list omits it too.
        let bare = LogFilter(fromBlock: 0, toBlock: 5)
        XCTAssertTrue(bare.json["address"].isNull)
        XCTAssertTrue(bare.json["topics"].isNull)

        let entry = f["events"]["buyLog"]
        let logJSON: JSON = .object([
            "address": .string(curve.hex),
            "topics": .array(entry["topics"].array!.map { .string($0.string!) }),
            "data": .string(entry["data"].string!),
            "blockNumber": .string("0x3e8"),
            "transactionHash": .string(entry["tx"].string!),
            "logIndex": .string("0x3"),
        ])
        let parsed = Log(json: logJSON)!
        XCTAssertEqual(parsed.address, curve)
        XCTAssertEqual(parsed.blockNumber, 1000)
        XCTAssertEqual(parsed.logIndex, 3)
        XCTAssertEqual(parsed.id, "\(entry["tx"].string!)-3")
        XCTAssertEqual(parsed.indexedAddress(0), buyer)
        XCTAssertEqual(parsed.indexedAddress(1), buyer)
        XCTAssertNil(Log(json: .object(["address": .string("nope")])), "a malformed log parses to nil, never traps")
    }

    func testWordCoercion() {
        // A 32-byte value passes through; a short value is left-padded; a long value is truncated to 32 bytes.
        XCTAssertEqual(LaunchpadABI.word(poolId).hexString, poolId.hexString)
        let short = LaunchpadABI.word(Data(hex: "0xabcd")!)
        XCTAssertEqual(short.count, 32)
        XCTAssertEqual(short.hexString, "0x" + String(repeating: "00", count: 30) + "abcd")
        let long = LaunchpadABI.word(Data(repeating: 0xff, count: 40))
        XCTAssertEqual(long, Data(repeating: 0xff, count: 32))
    }

    // MARK: - Trade parser and candles

    func testTradeParsing() {
        let anchor = BlockHeader(number: UInt64(f["events"]["anchor"]["number"].number!), timestamp: Int(f["events"]["anchor"]["timestamp"].number!))
        let buys = [log(f["events"]["buyLog"])]
        let sells = [log(f["events"]["sellLog"])]

        // Direct fill parse of the CurveBuy log.
        let fill = LaunchpadABI.fill(buys[0])!
        XCTAssertEqual(fill.trader, buyer)
        XCTAssertEqual(fill.recipient, buyer)
        XCTAssertEqual(fill.amountIn, e6(1000))
        XCTAssertEqual(fill.amountOut, e18(500))
        XCTAssertEqual(fill.fee, e6(8))
        XCTAssertEqual(fill.tax, e6(2))

        let trades = LaunchpadService.trades(buys: buys, sells: sells, anchor: anchor, pair: usdcPair, secondsPerBlock: BlockClockFixture.secondsPerBlock)
        XCTAssertEqual(trades.count, 2)
        // Sorted by block ascending: the sell at 998 precedes the buy at 1000.
        let sell = trades[0], buy = trades[1]
        XCTAssertFalse(sell.isBuy)
        XCTAssertTrue(buy.isBuy)

        let be = f["events"]["buyLog"]["expected"]
        XCTAssertEqual(buy.trader, buyer)
        XCTAssertEqual(buy.quoteAmount, bn(be["quote"].string!), "buy quote is the input net of fee and tax")
        XCTAssertEqual(buy.tokenAmount, bn(be["tokens"].string!))
        XCTAssertEqual(buy.quoteDecimals, 6)
        XCTAssertEqual(buy.time, anchor.timestamp)
        XCTAssertEqual(buy.price, 1.98, accuracy: 1e-9)
        XCTAssertEqual(buy.id, "\(f["events"]["buyLog"]["tx"].string!)-3")

        let se = f["events"]["sellLog"]["expected"]
        XCTAssertEqual(sell.trader, seller)
        XCTAssertEqual(sell.quoteAmount, bn(se["quote"].string!), "sell quote is the gross before fees")
        XCTAssertEqual(sell.tokenAmount, bn(se["tokens"].string!))
        XCTAssertEqual(sell.price, 2.0, accuracy: 1e-9)
        // Two blocks before the anchor at the pace two mainnet headers measured (0.30212 s), rounded to the second.
        XCTAssertEqual(sell.time, 1_699_999_999, "two blocks before the anchor at the measured pace")
        XCTAssertEqual(sell.time, Int((Double(anchor.timestamp) - 2 * BlockClockFixture.secondsPerBlock).rounded()))
        let slower = LaunchpadService.trades(buys: buys, sells: sells, anchor: anchor, pair: usdcPair, secondsPerBlock: 2)
        XCTAssertEqual(slower[0].time, anchor.timestamp - 4, "the time follows the pace given, never a constant")
    }

    func testCandles() {
        func trade(_ time: Int, _ price: Double, _ quote: BigUInt) -> CurveTrade {
            CurveTrade(id: "x", block: 0, logIndex: 0, time: time, trader: .zero, isBuy: true, quoteAmount: quote, tokenAmount: 0, quoteDecimals: 6, price: price)
        }
        let trades = [
            trade(100, 1.0, e6(1)),
            trade(110, 2.0, e6(2)),
            trade(300, 0.0, e6(9)), // price <= 0 is ignored
            trade(250, 1.5, e6(3)),
        ]
        let candles = LaunchpadService.candles(from: trades, interval: 60)
        // Buckets 60 and 240 hold trades; 120 and 180 are carried forward from bucket 60's close.
        XCTAssertEqual(candles.map(\.time), [60, 120, 180, 240])
        XCTAssertEqual(candles[0].open, 1.0)
        XCTAssertEqual(candles[0].high, 2.0)
        XCTAssertEqual(candles[0].low, 1.0)
        XCTAssertEqual(candles[0].close, 2.0)
        XCTAssertEqual(candles[0].volume, 3.0, accuracy: 1e-9, "1 + 2 USDC in pair units")
        for gap in [candles[1], candles[2]] {
            XCTAssertEqual(gap.open, 2.0)
            XCTAssertEqual(gap.high, 2.0)
            XCTAssertEqual(gap.low, 2.0)
            XCTAssertEqual(gap.close, 2.0)
            XCTAssertEqual(gap.volume, 0)
        }
        XCTAssertEqual(candles[3].open, 1.5)
        XCTAssertEqual(candles[3].close, 1.5)
        XCTAssertEqual(candles[3].volume, 3.0, accuracy: 1e-9)

        XCTAssertEqual(LaunchpadService.candles(from: trades, interval: 0), [], "a non-positive interval yields no candles")
    }

    /// The curve fills a wallet's history decodes (`LaunchpadABI.fill`): the trader, the quote a buyer paid in gross and
    /// the net quote a seller received, and the tokens; the launch and graduation events beside them.
    func testEventParsing() throws {
        let buy = try XCTUnwrap(LaunchpadABI.fill(log(f["events"]["buyLog"])))
        XCTAssertEqual(buy.trader, buyer)
        XCTAssertEqual(buy.amountIn, e6(1000), "the gross quote a buyer paid")
        XCTAssertEqual(buy.amountOut, e18(500))

        let sell = try XCTUnwrap(LaunchpadABI.fill(log(f["events"]["sellLog"])))
        XCTAssertEqual(sell.trader, seller)
        XCTAssertEqual(sell.amountOut, e6(490), "the net quote a seller received")
        XCTAssertEqual(sell.amountIn, e18(250))
        XCTAssertNil(LaunchpadABI.fill(log(f["events"]["launchedLog"])), "not a fill")

        // Direct event parsers.
        let le = LaunchpadABI.launched(log(f["events"]["launchedLog"]))!
        XCTAssertEqual(le.token, token); XCTAssertEqual(le.curve, curve); XCTAssertEqual(le.deployer, deployer)
        XCTAssertEqual(le.pairToken, usdc); XCTAssertEqual(le.launchConfigId, 0); XCTAssertEqual(le.graduationThreshold, e6(4000))
        let ge = LaunchpadABI.graduated(log(f["events"]["graduatedLog"]))!
        XCTAssertEqual(ge.token, token); XCTAssertEqual(ge.liquidity, e18(42)); XCTAssertEqual(ge.poolId.hexString, poolId.hexString)
    }

    // MARK: - Not deployed

    func testNotDeployedReturnsEmptyWithoutThrowing() async throws {
        XCTAssertFalse(LaunchpadAddresses.none.isDeployed)
        XCTAssertTrue(LaunchpadAddresses(factory: factory).isDeployed)

        let service = makeService(deployed: false)
        let deployed = await service.isDeployed
        XCTAssertFalse(deployed)
        // These read paths short-circuit before any network call when nothing is deployed.
        let launches = try await service.launches()
        XCTAssertEqual(launches, [])
        let protocolInfo = try await service.protocolInfo()
        XCTAssertNil(protocolInfo)
        let one = try await service.launch(token: token)
        XCTAssertNil(one)
        let canLaunch = try await service.canLaunch(account: recipient)
        XCTAssertFalse(canLaunch)
        // The retired stacks' board, feed and history keep working meanwhile (LaunchpadPendingTests).

        // The calldata-building reads that need the factory throw rather than build a bad transaction.
        do {
            _ = try await service.previewLaunchEconomics(configId: 0, pairToken: .zero)
            XCTFail("previewLaunchEconomics must throw when not deployed")
        } catch { XCTAssertEqual(error as? LaunchpadError, .notDeployed) }
        do {
            _ = try await service.launchPlan(sampleInput(pairToken: .zero, initialBuy: 0, minTokensOut: 0), from: recipient)
            XCTFail("launchPlan must throw when not deployed")
        } catch { XCTAssertEqual(error as? LaunchpadError, .notDeployed) }
    }

    /// A launch carries the terms hash read with the terms the screen showed (IOST-2): one that changed since is refused
    /// before anything is signed, and one that didn't is what the launch carries.
    func testLaunchTermsAreBoundToWhatWasShown() throws {
        let shown = Data(repeating: 0xaa, count: 32)
        XCTAssertEqual(try LaunchpadService.boundEconomics(shown: shown, current: shown), shown)
        XCTAssertThrowsError(try LaunchpadService.boundEconomics(shown: shown, current: Data(repeating: 0xbb, count: 32))) {
            XCTAssertEqual($0 as? LaunchpadError, .termsChanged)
        }
        XCTAssertEqual(try LaunchpadService.boundEconomics(shown: nil, current: shown), shown, "no shown hash: the current one, as before")
        XCTAssertTrue(LaunchpadError.termsChanged.localizedDescription.contains("nothing was sent"))
    }

    func testServiceConstants() {
        XCTAssertEqual(LaunchpadService.maxExemptions, 32)
        XCTAssertEqual(LaunchpadService.tradeLookbackMargin, 20_000, "the margin a coin's launch block is estimated early by")
        XCTAssertEqual(LaunchpadService.defaultLogsRPC.absoluteString, "https://rpc1.monad.xyz")
    }
}
