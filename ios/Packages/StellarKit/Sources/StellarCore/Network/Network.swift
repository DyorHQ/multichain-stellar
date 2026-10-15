import Crypto
import Foundation

public struct StellarNetwork: Equatable, Hashable, Sendable {
    public let name: String
    public let passphrase: String

    public static let testnet = StellarNetwork(name: "testnet", passphrase: "Test SDF Network ; September 2015")
    public static let mainnet = StellarNetwork(name: "mainnet", passphrase: "Public Global Stellar Network ; September 2015")

    /// sha256(passphrase): the network id every signature commits to.
    public var networkID: [UInt8] { Array(SHA256.hash(data: Data(passphrase.utf8))) }
}

/// The most a transaction may declare, in stroops (docs/DESIGN-stellar-parity.md §4.2). Pinned, because a cap the server
/// served couldn't bound the server. Generated with the contracts from networks.ts's `feePolicy`.
public struct FeePolicy: Equatable, Hashable, Sendable {
    /// The most one transaction may declare (`tx.fee`).
    public let maxFee: Int64
    /// The most a transaction may bid for inclusion, per operation: a classic transaction's whole fee, a Soroban
    /// transaction's fee above its resource fee.
    public let maxInclusionFeePerOp: Int64
    /// The most a step the server marks as sponsored may declare: what a server that claims to pay and doesn't could
    /// charge the user.
    public let starterInnerFeeMax: Int64

    public init(maxFee: Int64, maxInclusionFeePerOp: Int64, starterInnerFeeMax: Int64) {
        self.maxFee = maxFee
        self.maxInclusionFeePerOp = maxInclusionFeePerOp
        self.starterInnerFeeMax = starterInnerFeeMax
    }

    /// Testnet's measured caps (3 XLM, 0.02 XLM per operation, 0.1 XLM), also mainnet's until it is re-measured.
    public static let standard = FeePolicy(maxFee: 30_000_000, maxInclusionFeePerOp: 200_000, starterInnerFeeMax: 1_000_000)
}

/// A v2 deployment's durations, in seconds (dyor_common::LaunchDurations and MomentsDurations;
/// docs/DESIGN-stellar-contracts-v2.md §4, §14.3). A launch's and a Moment's terms carry them, and the verifier holds
/// them to these pins, so a server can't bind other timings (§20.4). Generated with the contracts from the deployment
/// file.
public struct PinnedDurations: Equatable, Hashable, Sendable {
    /// launchpad-v2's durations.
    public struct Launch: Equatable, Hashable, Sendable {
        public let grace: UInt64
        /// After `stuck_since`, how long only the creator's venue may be retried before `graduate_fallback` (F14).
        public let fallbackDelay: UInt64
        public let rescueAdmin: UInt64
        public let rescuePublic: UInt64
        public let lockedFallback: UInt64
        public let takeoverDelay: UInt64
        public let takeoverWindow: UInt64
        public let timelock: UInt64
        public let timelockWindow: UInt64
        /// The LP locker's harvest interval (F6).
        public let harvestInterval: UInt64

        public init(
            grace: UInt64, fallbackDelay: UInt64, rescueAdmin: UInt64, rescuePublic: UInt64, lockedFallback: UInt64,
            takeoverDelay: UInt64, takeoverWindow: UInt64, timelock: UInt64, timelockWindow: UInt64, harvestInterval: UInt64
        ) {
            self.grace = grace
            self.fallbackDelay = fallbackDelay
            self.rescueAdmin = rescueAdmin
            self.rescuePublic = rescuePublic
            self.lockedFallback = lockedFallback
            self.takeoverDelay = takeoverDelay
            self.takeoverWindow = takeoverWindow
            self.timelock = timelock
            self.timelockWindow = timelockWindow
            self.harvestInterval = harvestInterval
        }
    }

    /// moments-v2's durations.
    public struct Moments: Equatable, Hashable, Sendable {
        public let vestPeriod: UInt64
        public let stuckExpiry: UInt64
        /// After `completed_at`, when a Moment still pending graduation may expire without a recorded failure (V11).
        public let pendingBackstop: UInt64
        public let timelock: UInt64
        public let timelockWindow: UInt64
        public let minWindow: UInt64
        public let maxWindow: UInt64
        /// The LP locker's harvest interval (F6).
        public let harvestInterval: UInt64

        public init(
            vestPeriod: UInt64, stuckExpiry: UInt64, pendingBackstop: UInt64, timelock: UInt64, timelockWindow: UInt64,
            minWindow: UInt64, maxWindow: UInt64, harvestInterval: UInt64
        ) {
            self.vestPeriod = vestPeriod
            self.stuckExpiry = stuckExpiry
            self.pendingBackstop = pendingBackstop
            self.timelock = timelock
            self.timelockWindow = timelockWindow
            self.minWindow = minWindow
            self.maxWindow = maxWindow
            self.harvestInterval = harvestInterval
        }
    }

    public let launch: Launch
    public let moments: Moments

    public init(launch: Launch, moments: Moments) {
        self.launch = launch
        self.moments = moments
    }
}

/// The contracts this build will sign calls to, by role. Generated per deployment (PinnedContracts+Testnet.swift);
/// a server can't add to it. Launch tokens are created at runtime, so they are recognised by their WASM hash. Once the
/// deployment's v2 file exists it also pins v2's roles (launchpadV2, momentsV2, lpLocker, execSoroswap, execAquarius
/// where the deployment has it, momentsGraduator), the runtime contracts' WASM hashes and the durations. testnet-qa's
/// test contracts (qa-exec-fail, the failing Moments stack) are never pinned, in any build (F4).
public struct PinnedContracts: Equatable, Sendable {
    public let network: StellarNetwork
    /// The DyorHQ sponsor account: the only other account allowed to appear in a transaction, and only in an account's
    /// activation (as the creator of the account and the sponsor of its reserves), never as a sender.
    public let sponsor: String
    /// v1's launch token.
    public let launchTokenWasmHash: String
    public let roles: [String: [String]]
    /// The fee caps every transaction is checked against before it is signed.
    public let feePolicy: FeePolicy
    /// The keyless Stellar RPC the phone reads contracts from (launch tokens' code, activation). A different RPC in the
    /// server's config is ignored (§5.5).
    public let rpcURL: URL
    /// Circle's CCTP domain for Monad, the only chain a bridge burn may send to (15 on testnet and mainnet).
    public let monadDomain: UInt32
    /// The WASM hashes of the contracts v2 creates at runtime, by role (`launchTokenV2`, `momentNft`, `momentCoin`):
    /// they have no fixed address, so the phone recognises them by hash. Empty until v2 is pinned.
    public let runtimeWasmHashes: [String: String]
    /// The v2 deployment's durations; nil until v2 is pinned.
    public let durations: PinnedDurations?
    /// The most a v2 launch's fee may be, in stroops. The verifier refuses terms that state a higher `launch_fee`, so a
    /// server can't make the phone sign a larger fee than the owner set (decision O6, F18).
    public let maxLaunchFeeStroops: Int64

    public init(
        network: StellarNetwork,
        sponsor: String,
        launchTokenWasmHash: String,
        roles: [String: [String]],
        feePolicy: FeePolicy = .standard,
        rpcURL: URL = PinnedContracts.testnetRPC,
        monadDomain: UInt32 = 15,
        runtimeWasmHashes: [String: String] = [:],
        durations: PinnedDurations? = nil,
        maxLaunchFeeStroops: Int64 = PinnedContracts.standardMaxLaunchFeeStroops
    ) {
        self.network = network
        self.sponsor = sponsor
        self.launchTokenWasmHash = launchTokenWasmHash
        self.roles = roles
        self.feePolicy = feePolicy
        self.rpcURL = rpcURL
        self.monadDomain = monadDomain
        self.runtimeWasmHashes = runtimeWasmHashes
        self.durations = durations
        self.maxLaunchFeeStroops = maxLaunchFeeStroops
    }

    /// The Stellar Development Foundation's public testnet RPC.
    public static let testnetRPC = URL(string: "https://soroban-testnet.stellar.org")!

    /// 10 XLM, the launch fee on testnet and mainnet (decision O6).
    public static let standardMaxLaunchFeeStroops: Int64 = 100_000_000

    public var allContracts: Set<String> { Set(roles.values.flatMap { $0 }) }

    public func contracts(_ role: String) -> [String] { roles[role] ?? [] }
}
