import Foundation

/// An EVM chain the same DyorHQ wallet key can sign for — its `0x…` address is identical across all of them, which is
/// what makes the cross-chain Bridge a same-wallet flow. `auroraId` is the `blockchain` value Aurora uses in `/tokens`
/// and quote requests; `chainId` is the EVM chain id the app signs the source-chain transfer with; `rpcURL` is where
/// that transfer (and balance reads) go. Monad's RPC comes from app config at the environment layer, not from here.
public struct EVMChain: Sendable, Hashable, Identifiable {
    public let auroraId: String
    public let chainId: Int
    public let name: String
    public let nativeSymbol: String
    public let rpcURL: URL
    public var id: String { auroraId }
    public var isMonad: Bool { chainId == Monad.chainId }

    public init(auroraId: String, chainId: Int, name: String, nativeSymbol: String, rpcURL: URL) {
        self.auroraId = auroraId
        self.chainId = chainId
        self.name = name
        self.nativeSymbol = nativeSymbol
        self.rpcURL = rpcURL
    }

    private static func url(_ s: String) -> URL { URL(string: s)! }

    /// The block-explorer transaction URL for this chain — used by the Bridge's "View" link so the user can confirm the
    /// on-chain deposit / arrival themselves (like the explorer link on a swap). Keyed by `auroraId`; Monad uses
    /// monadscan. Returns nil for a chain we don't have an explorer for.
    public func explorerTx(_ hash: String) -> URL? {
        let base: String
        switch auroraId {
        case "eth": base = "https://etherscan.io"
        case "base": base = "https://basescan.org"
        case "arb": base = "https://arbiscan.io"
        case "op": base = "https://optimistic.etherscan.io"
        case "pol": base = "https://polygonscan.com"
        case "bsc": base = "https://bscscan.com"
        case "avax": base = "https://snowtrace.io"
        case "gnosis": base = "https://gnosisscan.io"
        case "scroll": base = "https://scrollscan.com"
        case "bera": base = "https://berascan.com"
        case "monad": base = Monad.explorer.absoluteString
        default: return nil
        }
        return URL(string: "\(base)/tx/\(hash)")
    }

    /// The EVM chains the Bridge supports, keyed to Aurora's `blockchain` ids so a `/tokens` row maps straight to a
    /// chain we can sign on. Public RPCs (publicnode) for the sources; Monad here is a placeholder whose RPC the app
    /// replaces with its configured endpoint.
    public static let supported: [EVMChain] = [
        // not localized: the chains' names
        EVMChain(auroraId: "eth", chainId: 1, name: "Ethereum", nativeSymbol: "ETH", rpcURL: url("https://ethereum-rpc.publicnode.com")),
        EVMChain(auroraId: "base", chainId: 8453, name: "Base", nativeSymbol: "ETH", rpcURL: url("https://base-rpc.publicnode.com")),
        EVMChain(auroraId: "arb", chainId: 42161, name: "Arbitrum", nativeSymbol: "ETH", rpcURL: url("https://arbitrum-one-rpc.publicnode.com")),
        EVMChain(auroraId: "op", chainId: 10, name: "Optimism", nativeSymbol: "ETH", rpcURL: url("https://optimism-rpc.publicnode.com")),
        EVMChain(auroraId: "pol", chainId: 137, name: "Polygon", nativeSymbol: "POL", rpcURL: url("https://polygon-bor-rpc.publicnode.com")),
        EVMChain(auroraId: "bsc", chainId: 56, name: "BNB Chain", nativeSymbol: "BNB", rpcURL: url("https://bsc-rpc.publicnode.com")),
        EVMChain(auroraId: "avax", chainId: 43114, name: "Avalanche", nativeSymbol: "AVAX", rpcURL: url("https://avalanche-c-chain-rpc.publicnode.com")),
        EVMChain(auroraId: "gnosis", chainId: 100, name: "Gnosis", nativeSymbol: "xDAI", rpcURL: url("https://gnosis-rpc.publicnode.com")),
        EVMChain(auroraId: "scroll", chainId: 534352, name: "Scroll", nativeSymbol: "ETH", rpcURL: url("https://scroll-rpc.publicnode.com")),
        EVMChain(auroraId: "bera", chainId: 80094, name: "Berachain", nativeSymbol: "BERA", rpcURL: url("https://berachain-rpc.publicnode.com")),
        EVMChain(auroraId: "monad", chainId: Monad.chainId, name: "Monad", nativeSymbol: "MON", rpcURL: Monad.defaultRPC),
    ]

    public static func byAuroraId(_ id: String) -> EVMChain? { supported.first { $0.auroraId == id } }
    /// The Monad entry, but pointed at `rpc` (the app's configured Monad endpoint) instead of the public default.
    public static func monad(rpc: URL) -> EVMChain {
        EVMChain(auroraId: "monad", chainId: Monad.chainId, name: "Monad", nativeSymbol: "MON", rpcURL: rpc)
    }
}
