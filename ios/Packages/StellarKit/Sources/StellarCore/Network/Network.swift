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

/// The contracts this build will sign calls to, by role. Generated per deployment (PinnedContracts+Testnet.swift);
/// a server can't add to it. Launch tokens are created at runtime, so they are recognised by their WASM hash.
public struct PinnedContracts: Equatable, Sendable {
    public let network: StellarNetwork
    /// The DyorHQ sponsor account: the only other account allowed to appear in a transaction, and only in an account's
    /// activation (as the creator of the account and the sponsor of its reserves), never as a sender.
    public let sponsor: String
    public let launchTokenWasmHash: String
    public let roles: [String: [String]]
    /// The fee caps every transaction is checked against before it is signed.
    public let feePolicy: FeePolicy
    /// The keyless Stellar RPC the phone reads contracts from (launch tokens' code, activation). A different RPC in the
    /// server's config is ignored (§5.5).
    public let rpcURL: URL
    /// Circle's CCTP domain for Monad, the only chain a bridge burn may send to (15 on testnet and mainnet).
    public let monadDomain: UInt32

    public init(
        network: StellarNetwork,
        sponsor: String,
        launchTokenWasmHash: String,
        roles: [String: [String]],
        feePolicy: FeePolicy = .standard,
        rpcURL: URL = PinnedContracts.testnetRPC,
        monadDomain: UInt32 = 15
    ) {
        self.network = network
        self.sponsor = sponsor
        self.launchTokenWasmHash = launchTokenWasmHash
        self.roles = roles
        self.feePolicy = feePolicy
        self.rpcURL = rpcURL
        self.monadDomain = monadDomain
    }

    /// The Stellar Development Foundation's public testnet RPC.
    public static let testnetRPC = URL(string: "https://soroban-testnet.stellar.org")!

    public var allContracts: Set<String> { Set(roles.values.flatMap { $0 }) }

    public func contracts(_ role: String) -> [String] { roles[role] ?? [] }
}
