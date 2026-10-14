import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The harness of the v2 fork suites (`V2ForkTests` for Moments, `LaunchpadV2ForkTests`, `MeraV2ForkTests` and
/// `CohortsV2ForkTests`): the app's own DyorKit plans against a real v2 deployment on a LOCAL anvil fork of Monad, sent
/// through `TransactionSender`, the path the app takes. Every suite is skipped unless both are set:
///
///   DYOR_V2_FORK_RPC      a local RPC (127.0.0.1 / localhost) of chain 143, e.g. `anvil --fork-url https://rpc3.monad.xyz
///                         --no-rate-limit --auto-impersonate --disable-code-size-limit --port 8651`
///   DYOR_V2_FORK_RECORDS  a folder with the fork deploy's records, as `contracts/script/deploy-v2.sh FORK=1` (or the two
///                         forge scripts) writes them, with `deployBlock` (the factory's creation block) added by hand as
///                         for mainnet. deploy-v2.sh FORK=1 deletes its records on exit, so copy them out first (or
///                         rebuild them from the factories' getters):
///                           pending-143.json                the launchpad (the launchpad suite skips without it)
///                           pending-moments-143.json        Moments, deployed with EXTERNAL_BASE_URI=https://dyorhq.fun/moments/c4/
///                                                           and a GUARDIAN
///                           pending-moments-small-143.json  optional: a second Moments stack with THRESHOLD_USDC=10000000,
///                                                           whose Moments graduate for 13.34 USDC (those tests skip without it)
///                         or `shipped`: the deployment the app ships with, on a fork of mainnet as it stands, with no
///                         deploy and no Debug override: `LaunchpadAddresses.monadMainnet` and `MomentsAddresses.monadMainnet`
///                         themselves, the roles and deploy blocks from the committed `contracts/deployments/143.json` and
///                         `moments-143.json` (checked equal to the tables). Mainnet has no small-threshold stack, so a
///                         Moment graduates at the owner's threshold there, and c4 is the shipped cohort, not a rehearsal.
///
///   cd ios/DyorKit && DYOR_V2_FORK_RPC=http://127.0.0.1:8651 DYOR_V2_FORK_RECORDS=<folder> swift test --filter V2ForkTests
///
/// Each test runs between an `evm_snapshot` and an `evm_revert`: it starts from the deployment as recorded, may warp time,
/// and leaves the fork as it found it. Wallets are fresh in-memory keys funded with anvil cheats and never printed; the
/// owner, governance, the guardian and token holders are impersonated on the fork only. Nothing here can reach a public
/// RPC.
class V2ForkCase: XCTestCase {
    private(set) var rpc: RPCClient!
    private var folder: URL!
    /// `DYOR_V2_FORK_RECORDS=shipped`: the deployment the app ships with, not a fork deploy's.
    private(set) var shipped = false
    private var snapshot: JSON?

    var sender: TransactionSender { TransactionSender(rpc: rpc) }

    static let mon = BigUInt(10).power(18)
    static let usdcUnit = BigUInt(1_000_000)
    /// Kuru's MarginAccount, a large USDC and AUSD holder on Monad; impersonated on the fork only, to fund test wallets.
    static let kuruMarginAccount = Address(literal: "0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5")
    /// Monday Trade's aBIL/USDC pool, the largest aBIL holder; impersonated on the fork only.
    static let mondayAbilPool = Address(literal: "0xb8700E0D0Df2B0b09A1374FbCdCC85E2E14F7898")

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let text = env["DYOR_V2_FORK_RPC"], let url = URL(string: text), let folder = env["DYOR_V2_FORK_RECORDS"] else {
            throw XCTSkip("set DYOR_V2_FORK_RPC (a local fork of Monad) and DYOR_V2_FORK_RECORDS (its v2 deploy records)")
        }
        let rpc = RPCClient(url: url)
        guard rpc.isLocal else { throw XCTSkip("DYOR_V2_FORK_RPC must be a local fork (127.0.0.1 or localhost), never a public RPC") }
        let chain = try await rpc.call("eth_chainId")
        guard chain.string.flatMap({ BigUInt(hexQuantity: $0) }) == 143 else { throw XCTSkip("DYOR_V2_FORK_RPC is not a fork of Monad mainnet (chain 143)") }
        self.rpc = rpc
        shipped = folder == "shipped"
        self.folder = URL(fileURLWithPath: folder)
        snapshot = try await rpc.call("evm_snapshot")
    }

    override func tearDown() async throws {
        if let rpc, let snapshot {
            _ = try await rpc.call("evm_setAutomine", [.bool(true)])
            let reverted = try await rpc.call("evm_revert", [snapshot])
            XCTAssertEqual(reverted, .bool(true), "the fork is back at this test's snapshot")
        }
        snapshot = nil
        try await super.tearDown()
    }

    // MARK: Records

    /// The committed mainnet record each fork deploy record stands for when `shipped`.
    static let shippedRecords = ["pending-143.json": "143.json", "pending-moments-143.json": "moments-143.json"]

    /// A record from DYOR_V2_FORK_RECORDS, or nil when the folder has none by that name. When `shipped`, the committed
    /// mainnet record in its place (`shippedRecords`); there is none for the small-threshold stack.
    func record(_ name: String) throws -> [String: Any]? {
        if shipped { return try Self.shippedRecords[name].map(LaunchpadDeploymentTests.deploymentRecord) }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
    }

    static func address(_ record: [String: Any], _ key: String) throws -> Address {
        try XCTUnwrap((record[key] as? String).flatMap(Address.init), "\(key) is missing from the record")
    }

    /// A v2 Moments deployment and its roles.
    struct ForkMoments {
        let addresses: MomentsAddresses
        let governance: Address
        let guardian: Address
        let rpc: RPCClient
        var service: MomentsService { MomentsService(rpc: rpc, addresses: addresses) }
    }

    /// The Moments deployment in `name` (the c4 one by default); the test is skipped when the folder has none. When
    /// `shipped`, `MomentsAddresses.monadMainnet` itself.
    func moments(_ name: String = "pending-moments-143.json") throws -> ForkMoments {
        guard let record = try record(name) else { throw XCTSkip("no \(name) in DYOR_V2_FORK_RECORDS") }
        func address(_ key: String) throws -> Address { try Self.address(record, key) }
        var addresses = MomentsAddresses(
            factory: try address("factory"), collect: try address("collect"), vesting: try address("vesting"), graduation: try address("graduation"),
            locker: try address("locker"), hook: try address("hook"), buyback: try address("buyback"), usdc: try address("usdc"), permit2: try address("permit2"),
            poolManager: try address("poolManager"), platform: try address("platform"), treasury: try address("treasury"),
            deployBlock: try XCTUnwrap((record["deployBlock"] as? NSNumber)?.uint64Value, "deployBlock"), generation: .v2
        )
        if shipped {
            XCTAssertEqual(addresses, MomentsAddresses.monadMainnet, "moments-143.json is the table the app ships")
            addresses = .monadMainnet
        }
        return ForkMoments(addresses: addresses, governance: try address("governance"), guardian: try address("guardian"), rpc: rpc)
    }

    /// The small-threshold Moments stack (THRESHOLD_USDC=10000000), for graduations.
    func smallMoments() throws -> ForkMoments { try moments("pending-moments-small-143.json") }

    /// A v2 launchpad deployment and its roles.
    struct ForkLaunchpad {
        let addresses: LaunchpadAddresses
        let owner: Address
        let mondayExecutor: Address
        let treasury: Address
        let rpc: RPCClient
        var service: LaunchpadService { LaunchpadService(rpc: rpc, addresses: addresses, logsRPC: rpc) }
    }

    /// The launchpad deployment; the test is skipped when the folder has none. When `shipped`,
    /// `LaunchpadAddresses.monadMainnet` itself.
    func launchpad() throws -> ForkLaunchpad {
        guard let record = try record("pending-143.json") else { throw XCTSkip("no v2 launchpad record (pending-143.json) in DYOR_V2_FORK_RECORDS") }
        func address(_ key: String) throws -> Address { try Self.address(record, key) }
        var addresses = LaunchpadAddresses(factory: try address("factory"), router: try address("launchAndBuyRouter"), escrow: try address("escrow"),
                                           holderFeeSharing: try address("holderFeeSharing"), hook: try address("hook"), poolManager: try address("poolManager"), generation: .v2)
        if shipped {
            XCTAssertEqual(addresses, LaunchpadAddresses.monadMainnet, "143.json is the table the app ships")
            addresses = .monadMainnet
        }
        return ForkLaunchpad(addresses: addresses, owner: try address("owner"), mondayExecutor: try address("mondayExecutor"), treasury: try address("treasury"), rpc: rpc)
    }

    // MARK: Wallets and funding

    /// A fresh in-memory key, funded with fork MON (1,000 by default) and any tokens asked for.
    func wallet(mon: BigUInt = 1_000 * mon, usdc: BigUInt = 0, ausd: BigUInt = 0, abil: BigUInt = 0) async throws -> ForkWallet {
        let wallet = ForkWallet()
        _ = try await rpc.call("anvil_setBalance", [.string(wallet.address.hex), .string(mon.hexQuantity)])
        if usdc > 0 { try await fund(Monad.usdc, usdc, to: wallet.address) }
        if ausd > 0 { try await fund(Monad.ausd, ausd, to: wallet.address) }
        if abil > 0 { try await fund(Token.abil.address, abil, to: wallet.address) }
        return wallet
    }

    /// Moves `amount` of `token` to `account` from a holder impersonated on the fork.
    func fund(_ token: Address, _ amount: BigUInt, to account: Address) async throws {
        let holder = token == Token.abil.address ? Self.mondayAbilPool : Self.kuruMarginAccount
        try await sendAs(holder, to: token, "transfer(address,uint256)", [.address(account), .uint(amount)])
    }

    /// Fork only: a transaction from an impersonated account (the owner, governance, the guardian, a holder, anyone).
    @discardableResult
    func sendAs(_ from: Address, to: Address, data: Data, value: BigUInt = 0, expectSuccess: Bool = true) async throws -> TransactionReceipt {
        _ = try await rpc.call("anvil_setBalance", [.string(from.hex), .string((1_000 * Self.mon + value).hexQuantity)])
        _ = try await rpc.call("anvil_impersonateAccount", [.string(from.hex)])
        let hash = try await rpc.call("eth_sendTransaction", [.object(["from": .string(from.hex), "to": .string(to.hex), "data": .string(data.hexString), "value": .string(value.hexQuantity)])])
        let receipt = try await rpc.waitForReceipt(try XCTUnwrap(hash.string.flatMap { Data(hex: $0) }))
        _ = try await rpc.call("anvil_stopImpersonatingAccount", [.string(from.hex)])
        if expectSuccess { XCTAssertTrue(receipt.success, "impersonated call to \(to.short) from \(from.short)") }
        return receipt
    }

    @discardableResult
    func sendAs(_ from: Address, to: Address, _ signature: String, _ args: [ABIValue] = []) async throws -> TransactionReceipt {
        try await sendAs(from, to: to, data: try ABI.encodeCall(signature, args))
    }

    // MARK: Plans

    /// Runs a plan the way the app does: `TransactionSender.run`, signed by the wallet.
    @discardableResult
    func run(_ steps: [TransactionStep], _ wallet: ForkWallet) async throws -> Data {
        try await sender.run(steps, from: wallet, onEvent: { _ in })
    }

    /// The sentence `TransactionSender.prepare` refuses a plan with (a step's simulation reverted, or its fee is out of
    /// bounds), or nil when every step went through.
    func refusal(_ steps: [TransactionStep], _ wallet: ForkWallet) async -> String? {
        do {
            try await run(steps, wallet)
            return nil
        } catch TransactionError.rejected(let why) {
            return why
        } catch {
            return "\(error)"
        }
    }

    /// The app's sentence for a contract error without arguments.
    func sentence(_ error: String) -> String? { RevertReason.knownErrors[ABI.selector("\(error)()").hexString] }

    // MARK: Chain

    func balance(_ token: Address, _ account: Address) async throws -> BigUInt {
        if token.isZero { return try await rpc.balance(of: account) }
        return try await Multicall(rpc: rpc).readAll([try ERC20.balanceOf(token, account)])[0][0].uint
    }

    func latest() async throws -> (number: UInt64, timestamp: Int) {
        let block = try await rpc.call("eth_getBlockByNumber", [.string("latest"), .bool(false)])
        let number = try XCTUnwrap(block["number"].string.flatMap { BigUInt(hexQuantity: $0) })
        let timestamp = try XCTUnwrap(block["timestamp"].string.flatMap { BigUInt(hexQuantity: $0) })
        return (UInt64(number), Int(timestamp))
    }

    func mine() async throws { _ = try await rpc.call("evm_mine") }

    /// Moves the fork's clock `seconds` ahead and mines a block there.
    func warp(_ seconds: Int) async throws {
        _ = try await rpc.call("evm_increaseTime", [.number(Double(seconds))])
        try await mine()
    }

    /// Mines the next block at `timestamp`.
    func warp(to timestamp: Int) async throws {
        _ = try await rpc.call("evm_setNextBlockTimestamp", [.string(BigUInt(timestamp).hexQuantity)])
        try await mine()
    }
}

/// A fresh in-memory key for a fork test; it counts what it signs. Never printed.
final class ForkWallet: Wallet, MomentsPermitSigner, @unchecked Sendable {
    let account: Secp256k1Account
    private let lock = NSLock()
    private var signed = 0
    var address: Address { account.address }
    var signatures: Int { lock.withLock { signed } }

    init() {
        var key: Secp256k1Account?
        while key == nil { key = Secp256k1Account(privateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
        account = key!
    }

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        lock.withLock { signed += 1 }
        return try account.sign(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data { try account.signMessage(message) }

    /// A Permit2 digest, signed as the app's local wallet signs it.
    func signDigest(_ digest: Data) async throws -> String {
        lock.withLock { signed += 1 }
        return try account.sign(hash32: digest).hexString
    }
}
