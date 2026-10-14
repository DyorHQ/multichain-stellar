import BigInt
import Foundation

/// Monad mainnet (chain id 143). Every address here was verified for bytecode on 2026-09-08 and comes from the
/// venue's own documentation; see docs/swap-spec.md and docs/app-wiring.md at the repository root.
public enum Monad {
    public static let chainId = 143
    public static let chainIdHex = "0x8f"
    public static let defaultRPC = URL(string: "https://rpc.monad.xyz")!
    /// Keyless public Monad RPC endpoints in failover order (docs.monad.xyz → Network information): QuickNode's
    /// rpc.monad.xyz (25 rps, batch ≤ 100) then Alchemy's rpc1.monad.xyz (15 rps, batch ≤ 100). Limits are per client
    /// IP, so every phone has its own budget — and no provider API key ever ships inside the app.
    public static let publicRPCs = [defaultRPC, URL(string: "https://rpc1.monad.xyz")!]
    public static let explorer = URL(string: "https://monadscan.com")!
    public static let nativeSymbol = "MON"

    public static let native = Address.zero
    public static let wmon = Address(literal: "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A")
    public static let usdc = Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603")
    public static let usdt0 = Address(literal: "0xe7cd86e13AC4309349F30B3435a9d337750fC82D")
    public static let weth = Address(literal: "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242")
    public static let ausd = Address(literal: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a")

    public static func explorerTransaction(_ hash: Data) -> URL { explorer.appending(path: "tx/\(hash.hexString)") }
    public static func explorerAddress(_ address: Address) -> URL { explorer.appending(path: "address/\(address.checksummed)") }
    public static func explorerToken(_ address: Address) -> URL { explorer.appending(path: "token/\(address.checksummed)") }
}

public enum Uniswap {
    public static let v3Factory = Address(literal: "0x204faca1764b154221e35c0d20abb3c525710498")
    public static let quoterV2 = Address(literal: "0x661e93cca42afacb172121ef892830ca3b70f08d")
    public static let swapRouter02 = Address(literal: "0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900")
    public static let poolManager = Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e")
    public static let v4Quoter = Address(literal: "0xa222dd357a9076d1091ed6aa2e16c9742dd26891")
    public static let stateView = Address(literal: "0x77395f3b2e73ae90843717371294fa97cc419d64")
    public static let universalRouter = Address(literal: "0x0d97dc33264bfc1c226207428a79b26757fb9dc3")
    public static let permit2 = Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3")
    public static let v3FeeTiers = [100, 500, 3000, 10000]
    /// Hookless v4 pools use the canonical fee / tick-spacing pairs.
    public static let v4Tiers: [(fee: Int, tickSpacing: Int)] = [(100, 1), (500, 10), (3000, 60), (10000, 200)]
}

/// Nad.fun's DEX — a Uniswap v2 fork where graduated Nad.fun memecoins (e.g. JAMES) hold their liquidity. Their
/// pairs are always against WMON, and prices come from the pair reserves rather than a v3 sqrt price.
public enum NadFun {
    public static let factory = Address(literal: "0xA25b13127e63ddae6d0b35570FF3D39dBD621001")
}

public enum MondayTrade {
    public static let factory = Address(literal: "0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21")
    public static let quoterV2 = Address(literal: "0xB97eCD41Aef0F842E773C8F9905919cDE49880C9")
    public static let swapRouter = Address(literal: "0xFE951b693A2FE54BE5148614B109E316B567632F")
    public static let feeTiers = [100, 300, 500, 3000, 10000]
}

public enum Kuru {
    public static let api = URL(string: "https://ws.kuru.io")!
    /// Kuru's public, unauthenticated token/market data host (distinct from the Flow quote host `api`).
    public static let dataApi = URL(string: "https://api.kuru.io")!
    public static let entrypoint = Address(literal: "0xb3e6778480b2E488385E8205eA05E20060B813cb")
}

public enum Perpl {
    public static let exchange = Address(literal: "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F")
    public static let collateral = Monad.ausd // AUSD
    public static let collateralDecimals = 6
    public static let api = URL(string: "https://app.perpl.xyz/api")!
    /// Perpl's market-data stream. It only accepts its own origin, so clients send `Origin: https://app.perpl.xyz`.
    public static let websocket = URL(string: "wss://app.perpl.xyz/ws/v1/market-data")!
    public static let websocketOrigin = "https://app.perpl.xyz"
    public static let minimumDeposit: BigUInt = 10_000_000 // 10 AUSD
}

/// A token the app knows how to show. Logos come from Monad's official token list.
public struct Token: Hashable, Sendable, Identifiable, Codable {
    public let address: Address
    public let symbol: String
    public let name: String
    public let decimals: Int
    public let logoURL: URL?
    public var isNative: Bool { address.isZero }
    public var isLaunchpad: Bool

    public var id: Address { address }

    /// The name a token the wallet holds is stored under when its symbol and name can't be read
    /// (`WalletTokenDiscovery`): English, as every earlier build stored it, so a stored list reads the same whatever
    /// language it was stored in and whichever build reads it. A screen shows `displayName`, in the app's language.
    // not localized: a stored value; `displayName` shows it in the app's language
    public static let unnamedName = "Token with no name"

    /// The name a screen shows: the token's own, or, for a token stored with no name (`unnamedName`, by this build or an
    /// earlier one), "Token with no name" in the app's language at the moment it is shown.
    public var displayName: String { name == Token.unnamedName ? L10n.tr("Token with no name") : name }

    public init(address: Address, symbol: String, name: String, decimals: Int, logoURL: URL? = nil, isLaunchpad: Bool = false) {
        self.address = address
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.logoURL = logoURL
        self.isLaunchpad = isLaunchpad
    }

    /// Native MON trades as WMON on the concentrated-liquidity venues.
    public var wrappedAddress: Address { isNative ? Monad.wmon : address }

    private static func logo(_ symbol: String, _ ext: String = "svg") -> URL? {
        URL(string: "https://raw.githubusercontent.com/monad-crypto/token-list/refs/heads/main/mainnet/\(symbol)/logo.\(ext)")
    }

    /// Curated spot assets from Monad's official token list (monad-crypto/token-list, mainnet v2.48).
    public static let core: [Token] = [
        // not localized: the tokens' own names
        Token(address: Monad.native, symbol: "MON", name: "Monad", decimals: 18, logoURL: logo("MON")),
        Token(address: Monad.wmon, symbol: "WMON", name: "Wrapped MON", decimals: 18, logoURL: logo("WMON")),
        Token(address: Monad.usdc, symbol: "USDC", name: "USDC", decimals: 6, logoURL: logo("USDC")),
        Token(address: Monad.usdt0, symbol: "USDT0", name: "USDT0", decimals: 6, logoURL: logo("USDT0")),
        Token(address: Monad.weth, symbol: "WETH", name: "Wrapped Ether", decimals: 18, logoURL: logo("WETH")),
        Token(address: Address(literal: "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"), symbol: "WBTC", name: "Wrapped BTC", decimals: 8, logoURL: logo("WBTC")),
        Token(address: Address(literal: "0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b"), symbol: "cbBTC", name: "Coinbase Wrapped BTC", decimals: 8, logoURL: logo("cbBTC")),
        Token(address: Address(literal: "0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081"), symbol: "gMON", name: "gMON", decimals: 18, logoURL: logo("gMON")),
        Token(address: Address(literal: "0xA3227C5969757783154C60bF0bC1944180ed81B9"), symbol: "sMON", name: "Kintsu Staked Monad", decimals: 18, logoURL: logo("sMON")),
        Token(address: Address(literal: "0x0c65A0BC65a5D819235B71F554D210D3F80E0852"), symbol: "aprMON", name: "aPriori Monad LST", decimals: 18, logoURL: logo("aprMON")),
        Token(address: Address(literal: "0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c"), symbol: "shMON", name: "ShMonad", decimals: 18, logoURL: logo("shMON", "png")),
        Token(address: Monad.ausd, symbol: "AUSD", name: "AUSD", decimals: 6, logoURL: logo("AUSD")),
        // aBIL — Anchored's tokenized SPDR 1-3M T-Bill (an aStock). A transferable ERC-20 that trades in Monday's
        // spot AMM, so the app buys it like any token; it is the RWA-flavored launchpad pair without a partner key.
        Token(address: Address(literal: "0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f"), symbol: "aBIL", name: "SPDR 1-3M T-Bill aStock", decimals: 18, logoURL: nil),
        Token(address: Address(literal: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34"), symbol: "USDe", name: "USDe", decimals: 18, logoURL: logo("USDe")),
        Token(address: Address(literal: "0x111111d2bf19e43C34263401e0CAd979eD1cdb61"), symbol: "USD1", name: "World Liberty Financial USD", decimals: 6, logoURL: logo("USD1")),
        Token(address: Address(literal: "0xacA92E438df0B2401fF60dA7E4337B687a2435DA"), symbol: "mUSD", name: "MetaMask USD", decimals: 6, logoURL: logo("mUSD")),
        Token(address: Address(literal: "0xecAc9C5F704e954931349Da37F60E39f515c11c1"), symbol: "LBTC", name: "Lombard Staked Bitcoin", decimals: 8, logoURL: logo("LBTC")),
        Token(address: Address(literal: "0x2416092f143378750bb29b79eD961ab195CcEea5"), symbol: "ezETH", name: "Renzo Restaked ETH", decimals: 18, logoURL: logo("ezETH")),
        Token(address: Address(literal: "0xC50f2e735eDd9dCD8Ccd41EcFE9894E679e3195f"), symbol: "rETH", name: "Rocket Pool ETH", decimals: 18, logoURL: logo("rETH")),
    ]

    public static let mon = core[0]
    public static let wmon = core[1]
    public static let usdc = core[2]
    public static let ausd = core.first { $0.address == Monad.ausd }!
    public static let abil = core.first { $0.symbol == "aBIL" }!

    /// ERC-20s the launchpad offers as pair (quote) tokens once the owner approves them with `setPairEconomics`.
    /// Native MON (address(0)) is always offered by the factory, so it is not listed here. Order is the UI's
    /// default order after MON: a familiar USD curve, the stable that doubles as Perpl collateral, then the RWA pair.
    public static let launchpadPairAssets: [Address] = [Monad.usdc, Monad.ausd, abil.address]

    /// Intermediate tokens tried for two-hop routes on the concentrated-liquidity venues.
    public static let hopTokens: [Address] = [Monad.wmon, Monad.usdc, Monad.usdt0, Monad.weth]

    public static func core(_ address: Address) -> Token? { core.first { $0.address == address } }
}
