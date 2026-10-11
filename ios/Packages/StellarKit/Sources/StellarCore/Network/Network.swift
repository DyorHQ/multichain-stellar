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

/// The contracts this build will sign calls to, by role. Generated per deployment (PinnedContracts+Testnet.swift);
/// a server can't add to it. Launch tokens are created at runtime, so they are recognised by their WASM hash.
public struct PinnedContracts: Equatable, Sendable {
    public let network: StellarNetwork
    /// The DyorHQ sponsor account: the only other account allowed to appear in a transaction (as the sponsor of
    /// reserves), never as a sender.
    public let sponsor: String
    public let launchTokenWasmHash: String
    public let roles: [String: [String]]

    public init(network: StellarNetwork, sponsor: String, launchTokenWasmHash: String, roles: [String: [String]]) {
        self.network = network
        self.sponsor = sponsor
        self.launchTokenWasmHash = launchTokenWasmHash
        self.roles = roles
    }

    public var allContracts: Set<String> { Set(roles.values.flatMap { $0 }) }

    public func contracts(_ role: String) -> [String] { roles[role] ?? [] }
}
