import BigInt
import Foundation

/// Where the launchpad lives on chain. `monadMainnet` is the audited v2 deployment the app ships with; a Debug build can
/// point at another one (a fork rehearsal) through Secrets.xcconfig. Any address may be `Address.zero`, and
/// `isDeployed` is what every read checks first.
public struct LaunchpadAddresses: Sendable, Hashable {
    public var factory: Address
    public var router: Address
    public var escrow: Address
    public var holderFeeSharing: Address
    public var hook: Address
    /// Uniswap v4 PoolManager (`Uniswap.poolManager` on Monad). Graduated launches are priced from its storage.
    public var poolManager: Address
    /// The contract source the stack runs: its record layout, which getters it answers and which graduation paths the
    /// app sends (`Generation`). The retired stacks are `.legacy` … `.v1`, `monadMainnet` is `.v2`.
    public var generation: Generation

    public init(factory: Address = .zero, router: Address = .zero, escrow: Address = .zero, holderFeeSharing: Address = .zero, hook: Address = .zero, poolManager: Address = .zero,
                generation: Generation = .v1) {
        self.factory = factory
        self.router = router
        self.escrow = escrow
        self.holderFeeSharing = holderFeeSharing
        self.hook = hook
        self.poolManager = poolManager
        self.generation = generation
    }

    /// The launchpad's contract generations, oldest first. A getter a generation lacks reverts, and in a Multicall3
    /// `readAll` one reverted sub-call fails the whole read, so every optional read and plan asks the stack's generation.
    public enum Generation: Int, Sendable, Hashable, Codable, Comparable, CaseIterable, CustomStringConvertible {
        /// 0xad3d…, the first deployment: the 16-field `getLaunchedToken` record (no `graduationVenue`); every launch
        /// graduates on Monday Trade.
        case legacy
        /// 0x2F02…, 2026-09-12: the 17-field record, but neither `queuedRewards` nor `graduateFallback` (audit fixes H-1, H-3).
        case preAudit
        /// 0x10F3… and 0x6B1C…, the audit-fix source (`3fc1f47`): `queuedRewards` and `graduateFallback`.
        case v1
        /// The audited v2 release: sealed modules, the per-launch `launchMondayOnly` snapshot, the hook's
        /// `pendingProtocolFees`, and a `graduateFallback` that needs at least 22,062,500 gas.
        case v2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            // not localized: identifiers, never shown
            case .legacy: return "legacy"
            case .preAudit: return "pre-audit"
            case .v1: return "v1"
            case .v2: return "v2"
            }
        }

        /// The factory returns the 16-field record.
        public var legacyRecord: Bool { self == .legacy }
        /// The fee escrow sends each fee straight to its recipient (`Paid`) and books a balance to claim only when that
        /// send fails (`Credited`); before v1 it books every fee to claim. Read from each stack's escrow code on mainnet.
        public var pushesFees: Bool { self >= .v1 }
        /// The fee-sharing contract has `queuedRewards` (audit fix H-1).
        public var hasQueuedRewards: Bool { self >= .v1 }
        /// The factory has `graduateFallback` (audit fix H-3). The app never sends it, on any generation (owner decision
        /// 2026-09-28): DyorHQ's keepers do, with the gas it needs — v2's reverts `InsufficientGasForGraduation` below
        /// `MONDAY_RETRY_GAS + GRADUATION_GAS × 33/32` (22,062,500) gas, over the app's 15M network-fee cap
        /// (`NetworkFeeLimits.monad`), and the keepers send it with about 29.9M.
        public var hasGraduateFallback: Bool { self >= .v1 }
        /// The v2-only getters: `modulesSealed`, `launchMondayOnly`, `MONDAY_ONLY_FALLBACK_DELAY` and `MONDAY_RETRY_GAS` on
        /// the factory, `pendingProtocolFees` on the hook.
        public var hasV2Getters: Bool { self >= .v2 }
    }

    public var isDeployed: Bool { !factory.isZero }

    public static let none = LaunchpadAddresses()

    // The only place the v2 launchpad addresses live. AppConfig, the swap routes and every stack list derive from this
    // constant.
    /// The launchpad v2 on Monad mainnet (chain 143), deployed 2026-09-28 at block 108,859,147, owned by the Owner Safe
    /// 0x6D2A… and Sourcify-verified: the five modules from `contracts/deployments/143.json`. `LaunchpadDeploymentTests`
    /// and `V2WiringTests` accept only all-zero or fully wired, fail a wired table that differs from the record, and fail
    /// a release built while it is pending (`DYORHQ_RELEASE_GATE=1`).
    public static let monadMainnet = LaunchpadAddresses(
        factory: Address(literal: "0x3B1f5f562f5F61B980aBfDDbebD6cdF9a73b0b5b"),
        router: Address(literal: "0x2a66b7106adac1BcD85679ba8E23dFc9aD4D8637"),
        escrow: Address(literal: "0x690eaa0b66C3738887007a0D99ED90b5f5af86F1"),
        holderFeeSharing: Address(literal: "0x5358a136a50eE4F961B532064dc641E8F4Fa5656"),
        hook: Address(literal: "0xb845b4Dd429684b67eeEa9D484F5e903B28360CC"),
        poolManager: Uniswap.poolManager,
        generation: .v2
    )

    /// Retired launchpads, newest first. The app launches nothing there, and their curves take sells only
    /// (`RetiredLaunchpad`, owner decision 2026-09-28); their launches, claims and trades stay part of a wallet's
    /// history, so every per-launch read and write goes to the launch's own stack. On chain 0x10F3, 0x2F02 and 0xad3d are
    /// closed to launches (whitelist on, config 0 off); 0x6B1C is not (retired in the app only, owner decision
    /// 2026-09-28), so builds before 16 can still launch there.
    public static let retiredStacks: [LaunchpadAddresses] = [
        // The 2026-09-23 relaunch with the rotated treasury and fee wallets, retired by the v2 release
        // (`143-retired-0x6B1C.json`). Same source as 0x10F3.
        LaunchpadAddresses(
            factory: Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"),
            router: Address(literal: "0x454822dc56072696ab7cf8Bac357FFd3315477Fc"),
            escrow: Address(literal: "0x5EDA8765934fE22fa63d671465eF914Cd196968e"),
            holderFeeSharing: Address(literal: "0xc618bB26bBc3C84c30519F31e32eE52EA2BFac52"),
            hook: Address(literal: "0xf2b849B3FC4a2b19B39DA3F707Fc32b801eea0Cc"),
            poolManager: Uniswap.poolManager,
            generation: .v1
        ),
        // The 2026-09-16 audit-fix redeploy, retired by the 2026-09-23 relaunch (`143-retired-0x10F3.json`).
        LaunchpadAddresses(
            factory: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            router: Address(literal: "0x3eE688C3b3aCd652914aD49d8Ee5ae1004bF3690"),
            escrow: Address(literal: "0xbc70ba9D66F761FFb7647D6B52C8Cf65a49E47fc"),
            holderFeeSharing: Address(literal: "0x70F8f64c6A4A76A507e322BCef19E6E37abe4eF6"),
            hook: Address(literal: "0x51A240c13164BcDF3FC11053FddEaC626A4160cc"),
            poolManager: Uniswap.poolManager,
            generation: .v1
        ),
        // The pre-audit 2026-09-12 deployment: no `queuedRewards`, no `graduateFallback`.
        LaunchpadAddresses(
            factory: Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
            router: Address(literal: "0xbaEa633e9Ba5d927bfD6a0f5b3FB3982784DA30D"),
            escrow: Address(literal: "0xeDC73b06BE454714b6Bd0C1c742e51e605664B2A"),
            holderFeeSharing: Address(literal: "0x1413CB051f78a4605cD150d4E97B1B06f81e2Bdf"),
            hook: Address(literal: "0x22957b1d794A7Ca37D054acB5e993e026826E0Cc"),
            poolManager: Uniswap.poolManager,
            generation: .preAudit
        ),
        // The first deployment: the 16-field record, and every one of its launches graduates on Monday Trade.
        LaunchpadAddresses(
            factory: Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea"),
            router: Address(literal: "0xd5862DfB44831868CF8f459aA270d05d32031CE1"),
            escrow: Address(literal: "0x1253b18077E8b52FC2522F5B62Ebd2B176383231"),
            holderFeeSharing: Address(literal: "0x0C7a1F7625696bAbF9a7309ed3c4A9086eFEE8dd"),
            hook: Address(literal: "0xB0c2Fa59aA9f30BC0907bcD785bFf068fEb0E0Cc"),
            poolManager: Uniswap.poolManager,
            generation: .legacy
        ),
    ]

    public static var retiredFactories: [Address] { retiredStacks.map(\.factory) }

    /// The retired stack whose factory is `factory`, or nil when it is not a retired one.
    public static func retiredStack(for factory: Address) -> LaunchpadAddresses? {
        retiredStacks.first { $0.factory == factory }
    }

    /// The factories whose graduated pools are Uniswap v4 swap routes (`SwapEngine`): the live one once it is deployed,
    /// then every retired one with the 17-field record (the legacy 0xad3d… launches all graduate on Monday Trade). A
    /// pending live stack adds nothing, so the retired routes stay while v2 is pending and nothing is read from address 0.
    public static func swapRouteFactories(live: LaunchpadAddresses) -> [Address] {
        (live.isDeployed ? [live.factory] : []) + retiredStacks.filter { !$0.generation.legacyRecord && $0.factory != live.factory }.map(\.factory)
    }
}

/// `Types.Phase` in the contracts: NotGraduated, Swept, PoolCreated, Rescued.
public enum LaunchPhase: Int, Sendable, Hashable, Codable, CaseIterable {
    case bonding = 0
    case migrating
    case graduated
    case refund

    public var title: String {
        switch self {
        case .bonding: return L10n.string(LocalizedStringResource("Bonding", bundle: L10n.kit, comment: "[tight] A launch's phase: its coin trades on its bonding curve."))
        case .migrating: return L10n.string(LocalizedStringResource("Migrating", bundle: L10n.kit, comment: "[tight] A launch's phase: its coin moves from its curve to its pool."))
        case .graduated: return L10n.string(LocalizedStringResource("Graduated", bundle: L10n.kit, comment: "[tight] A status: a launch's coin or a Moment has graduated, and trades in its pool."))
        case .refund: return L10n.string(LocalizedStringResource("Refund mode", bundle: L10n.kit, comment: "[tight] A launch's phase: its coin can only be sold back into its curve."))
        }
    }

    init(raw: BigUInt) { self = LaunchPhase(rawValue: Int(clamping: raw)) ?? .bonding }

    /// The Launch tab's section that lists a coin in this phase (and finds it by search), among the coins the board lists
    /// (`Launch.listsOnBoard`: a retired launchpad's only once graduated). Every phase has one. No screen sends a holder to
    /// the board for a coin: it opens the coin's page, from its launch or by reference (`CurveRoute.launchUnread`).
    public var boardSection: LaunchBoardSection {
        switch self {
        case .graduated: return .graduated
        case .bonding: return .climbing
        case .migrating, .refund: return .refundAndMigrating
        }
    }
}

/// The Launch tab board's sections (`LaunchPhase.boardSection`).
public enum LaunchBoardSection: Sendable, Hashable, CaseIterable {
    /// Graduated into a pool: trades on Swap.
    case graduated
    /// On the curve: climbing, or full and waiting to graduate.
    case climbing
    /// Off the curve's trading side without a pool: in refund mode (holders sell back into the curve) or migrating
    /// (nothing trades until it graduates).
    case refundAndMigrating
}

/// What the Launch tab's board shows beyond its public sections.
public enum LaunchBoard {
    /// The coins among `launches` that the public board leaves out (`Launch.listsOnBoard`: sell-only) and the wallet
    /// holds, per `balances`, newest first: the board's holder-only "Your Sell-Only Coins", so a holder can always reach
    /// their page from the Launch tab. Nil when a balance of one of them is missing (its read failed): the section then
    /// keeps what it last showed, never a coin dropped or added on a failed read. For the same reason `launches` must
    /// come from a complete listing (`LaunchListing.complete`): a retired factory that couldn't be read leaves its coins
    /// out, and a held one would drop from the section.
    public static func heldSellOnly(_ launches: [Launch], balances: [Address: BigUInt]) -> [Launch]? {
        var held: [Launch] = []
        for launch in launches where !launch.listsOnBoard {
            guard let balance = balances[launch.token] else { return nil }
            if balance > 0 { held.append(launch) }
        }
        return held.sorted { $0.launchedAt > $1.launchedAt }
    }

    /// What "Your Sell-Only Coins" says of `coins`: they sell on their page and can't be bought, and, when one of them
    /// takes no sell now (`Launch.curveSellsOpen`: its graduation is pending, or it migrates), that a coin waiting to
    /// graduate can't be sold until it does.
    public static func sellOnlySubtitle(_ coins: [Launch]) -> String {
        coins.allSatisfy(\.curveSellsOpen)
            ? L10n.tr("From retired launchpads: sell them on their page. They can't be bought.")
            : L10n.tr("From retired launchpads: sell them on their page. They can't be bought, and a coin waiting to graduate can't be sold until it does.")
    }
}

/// `Types.GraduationVenue` in the contracts: where a completed curve graduates. The creator chooses at launch;
/// aBIL-quoted (and any `pairMondayOnly`) launches are forced to Monday. UniswapV4 is the default (enum value 0).
public enum GraduationVenue: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case uniswapV4 = 0
    case monday = 1

    public var title: String {
        switch self {
        // not localized: the venues' names
        case .uniswapV4: return "Uniswap v4"
        case .monday: return "Monday Trade"
        }
    }

    init(raw: BigUInt) { self = GraduationVenue(rawValue: UInt8(clamping: raw)) ?? .uniswapV4 }
}

public struct Socials: Hashable, Sendable, Codable {
    public var twitter: String
    public var telegram: String
    public var discord: String
    public var website: String
    public var farcaster: String

    public init(twitter: String = "", telegram: String = "", discord: String = "", website: String = "", farcaster: String = "") {
        self.twitter = twitter
        self.telegram = telegram
        self.discord = discord
        self.website = website
        self.farcaster = farcaster
    }

    public static let none = Socials()
}

/// The asset a curve collects. Native MON is `Address.zero`.
public struct PairInfo: Hashable, Sendable, Codable {
    public let address: Address
    public let symbol: String
    public let decimals: Int
    public let isNative: Bool

    public init(address: Address, symbol: String, decimals: Int, isNative: Bool) {
        self.address = address
        self.symbol = symbol
        self.decimals = decimals
        self.isNative = isNative
    }

    public static let mon = PairInfo(address: .zero, symbol: Monad.nativeSymbol, decimals: 18, isNative: true)
}

public struct PairEconomics: Hashable, Sendable {
    public let pair: PairInfo
    public let phantomQuote: BigUInt
    public let graduationThreshold: BigUInt
    public let approved: Bool
    /// The pair can only graduate on Monday Trade (the factory's `pairMondayOnly`); the create screen then forces
    /// the Monday venue and disables the picker. aBIL is the canonical Monday-only quote asset.
    public let mondayOnly: Bool
    /// `previewLaunchEconomics(configId, pair)`, read in the same call as the terms above: what a launch shown these
    /// terms must carry (`LaunchpadService.launchPlan`'s `expectedEconomics`).
    public let economicsHash: Data?

    public init(pair: PairInfo, phantomQuote: BigUInt, graduationThreshold: BigUInt, approved: Bool, mondayOnly: Bool = false, economicsHash: Data? = nil) {
        self.pair = pair
        self.phantomQuote = phantomQuote
        self.graduationThreshold = graduationThreshold
        self.approved = approved
        self.mondayOnly = mondayOnly
        self.economicsHash = economicsHash
    }
}

/// Factory policy and the launch template the create screen offers (config 0).
public struct ProtocolInfo: Hashable, Sendable {
    public let launchFee: BigUInt
    public let configId: BigUInt
    public let supply: BigUInt
    public let curveFeeBps: Int
    public let poolFeeBps: Int
    public let snipeSchedule: [Int]
    public let configEnabled: Bool
    public let maxCreatorTaxBps: Int
    public let whitelistEnabled: Bool
    public let protocolFeeShareBps: Int
    public let launchCount: Int
    public let pairs: [PairEconomics]
    /// v2: `modulesSealed()`. Nil on an older factory, which has no such getter (its first launch sealed them).
    public let modulesSealed: Bool?
    /// v2: the factory's modules that aren't this build's (`LaunchpadModules.mismatches`); empty when every one is.
    public let moduleMismatches: [String]
    /// `canLaunch(account)` for the wallet the screen was loaded for; nil when none was.
    public let accountCanLaunch: Bool?

    public init(launchFee: BigUInt, configId: BigUInt, supply: BigUInt, curveFeeBps: Int, poolFeeBps: Int, snipeSchedule: [Int], configEnabled: Bool, maxCreatorTaxBps: Int, whitelistEnabled: Bool, protocolFeeShareBps: Int, launchCount: Int, pairs: [PairEconomics],
                modulesSealed: Bool? = nil, moduleMismatches: [String] = [], accountCanLaunch: Bool? = nil) {
        self.launchFee = launchFee
        self.configId = configId
        self.supply = supply
        self.curveFeeBps = curveFeeBps
        self.poolFeeBps = poolFeeBps
        self.snipeSchedule = snipeSchedule
        self.configEnabled = configEnabled
        self.maxCreatorTaxBps = maxCreatorTaxBps
        self.whitelistEnabled = whitelistEnabled
        self.protocolFeeShareBps = protocolFeeShareBps
        self.launchCount = launchCount
        self.pairs = pairs
        self.modulesSealed = modulesSealed
        self.moduleMismatches = moduleMismatches
        self.accountCanLaunch = accountCanLaunch
    }

    /// The snipe-tax window in seconds: one schedule entry per second after launch.
    public var snipeWindowSeconds: Int { snipeSchedule.count }

    /// Why Launch is off for the wallet the screen was loaded for, or nil when a launch can go ahead.
    public var launchBlocker: LaunchBlocker? {
        LaunchBlocker.check(modulesSealed: modulesSealed, moduleMismatches: moduleMismatches, configEnabled: configEnabled, whitelistEnabled: whitelistEnabled, accountCanLaunch: accountCanLaunch)
    }
}

/// Why the factory would refuse a launch right now. The create screen checks it before Review, and the launch plan
/// again from a fresh read, so nothing is signed for a launch that would revert: not even the approval a USDC, AUSD or
/// aBIL developer buy sends first, which costs a network fee of its own.
public enum LaunchBlocker: Hashable, Sendable {
    /// v2: the factory's modules can still be swapped (`modulesSealed() == false`); the deploy seals them.
    case modulesNotSealed
    /// v2: these modules aren't the ones this build sends to and reads from.
    case modulesChanged([String])
    /// Launch template 0 is switched off (`setLaunchConfigEnabled(0, false)`) or missing: `LaunchConfigDisabled`.
    case configDisabled
    /// The whitelist is on and the wallet isn't on it (`canLaunch`): `NotWhitelisted`.
    case notAllowed

    public var message: String {
        switch self {
        case .modulesNotSealed: return L10n.tr("The launchpad's contracts aren't locked yet, so launching stays off for now.")
        case .modulesChanged: return L10n.tr("The launchpad's contracts aren't the ones this version of DyorHQ was built for, so launching is off. Update the app.")
        case .configDisabled: return L10n.tr("New launches are paused right now.")
        case .notAllowed: return L10n.tr("Launching is limited to approved wallets right now, and this wallet isn't one.")
        }
    }

    /// The first reason, in the order that matters most: an unsealed or unexpected wiring before the owner's switches.
    public static func check(modulesSealed: Bool?, moduleMismatches: [String], configEnabled: Bool, whitelistEnabled: Bool, accountCanLaunch: Bool?) -> LaunchBlocker? {
        if modulesSealed == false { return .modulesNotSealed }
        if !moduleMismatches.isEmpty { return .modulesChanged(moduleMismatches) }
        if !configEnabled { return .configDisabled }
        if whitelistEnabled, accountCanLaunch != true { return .notAllowed }
        return nil
    }
}

/// A v2 factory's module wiring as read on chain (its getters), for the check before Launch.
public struct LaunchpadModules: Hashable, Sendable {
    public let hook: Address
    public let router: Address
    public let escrow: Address
    public let holderFeeSharing: Address
    public let locker: Address
    public let graduationExecutor: Address
    public let mondayExecutor: Address
    public let launchDeployer: Address

    public init(hook: Address, router: Address, escrow: Address, holderFeeSharing: Address, locker: Address, graduationExecutor: Address, mondayExecutor: Address, launchDeployer: Address) {
        self.hook = hook
        self.router = router
        self.escrow = escrow
        self.holderFeeSharing = holderFeeSharing
        self.locker = locker
        self.graduationExecutor = graduationExecutor
        self.mondayExecutor = mondayExecutor
        self.launchDeployer = launchDeployer
    }

    /// The modules that differ from `baked` (the four this build sends to or reads from: hook, router, escrow and
    /// fee sharing) or, for the rest (locker, both graduation executors, deployer), that are unset. Empty when the
    /// factory is wired the way the app expects.
    public func mismatches(_ baked: LaunchpadAddresses) -> [String] {
        let compared = [("hook", hook, baked.hook), ("router", router, baked.router), ("escrow", escrow, baked.escrow), ("holderFeeSharing", holderFeeSharing, baked.holderFeeSharing)]
        let set = [("locker", locker), ("graduationExecutor", graduationExecutor), ("mondayExecutor", mondayExecutor), ("launchDeployer", launchDeployer)]
        return compared.filter { $0.1 != $0.2 || $0.1.isZero }.map(\.0) + set.filter { $0.1.isZero }.map(\.0)
    }
}

/// The launches of every launchpad the app reads (`LaunchpadService.launchListing`), newest first: the live factory's,
/// then each retired factory's, newest stack first. A factory whose launches couldn't be read is in `unread`, with why,
/// and has none here: never taken for a factory with none.
public struct LaunchListing: Sendable {
    /// Every factory asked, in list order.
    public let factories: [Address]
    public let launches: [Launch]
    /// The factories whose launches couldn't be read, with the error.
    public let unread: [Address: any Error]

    public init(factories: [Address], launches: [Launch], unread: [Address: any Error] = [:]) {
        self.factories = factories
        self.launches = launches
        self.unread = unread
    }

    /// Every factory's launches were read.
    public var complete: Bool { unread.isEmpty }

    /// The error of the first factory, in list order, whose launches couldn't be read.
    public var firstError: (any Error)? { factories.lazy.compactMap { self.unread[$0] }.first }

    /// `launches`, with each factory that couldn't be read now keeping its launches from `previous` (an earlier read's),
    /// in its place in the list: what a screen shows beside its error, so a failed read never empties a list it had.
    public func keeping(_ previous: [Launch]) -> [Launch] {
        guard !unread.isEmpty else { return launches }
        return factories.flatMap { factory in (unread[factory] == nil ? launches : previous).filter { $0.factory == factory } }
    }

    /// The newest `limit` launches of each factory, in place, every factory and error kept: what a screen listing fewer
    /// takes from the list every screen shares (`LaunchpadService.launchListing`), exactly the launches a read of `limit`
    /// would have listed.
    public func prefix(perFactory limit: Int) -> LaunchListing {
        var taken: [Address: Int] = [:]
        let kept = launches.filter { launch in
            let count = taken[launch.factory, default: 0]
            guard count < limit else { return false }
            taken[launch.factory] = count + 1
            return true
        }
        return LaunchListing(factories: factories, launches: kept, unread: unread)
    }
}

/// One launch as the explore list shows it: the factory record plus the token metadata and live curve state. Codable, so
/// the screens that list it can keep what they last showed (`SavedScreens`), its text as it was shown.
public struct Launch: Identifiable, Hashable, Sendable, Codable {
    public var id: Address { token }

    public let token: Address
    public let curve: Address
    public let deployer: Address
    public let creatorFeeRecipient: Address
    public let pairToken: Address
    public let graduationThreshold: BigUInt
    public let creatorTaxBps: Int
    public let poolFeeBps: Int
    public let tickSpacing: Int
    public let holderFeeSharing: Bool
    public let graduationVenue: GraduationVenue
    public let phase: LaunchPhase
    public let sweptQuote: BigUInt
    public let sweptTokens: BigUInt
    public let sweptAt: Int
    public let poolId: Data
    public let name: String
    public let symbol: String
    public let logo: String
    public let description: String
    public let socials: Socials
    public let pair: PairInfo
    /// Quote per whole token in quote wei (18-decimal fixed point), from the curve or, once graduated, the pool, as the
    /// contract's `price()` counts it: whole units of the pair's smallest unit, so on a 6-decimal pair (USDC, AUSD) it
    /// moves in steps of $0.000001 and is 0 below that. Nothing is valued at it: every price and value on screen comes
    /// from `pairPrice`.
    public let price: BigUInt
    /// Quote collected by the curve; after graduation, what was swept into the pool.
    public let realQuoteReserve: BigUInt
    public let completed: Bool
    public let rescued: Bool
    public let launchedAt: Int
    public let supply: BigUInt
    public let marketCap: BigUInt
    public let progressBps: Int
    /// The factory that recorded the launch: the live one or a retired one. `.zero` means the live one.
    public let factory: Address
    /// The contract generation of that factory's stack: set from the stack when read, else the retired stack's, else
    /// the live table's (`.v2`).
    public let generation: LaunchpadAddresses.Generation
    /// Pair units per whole coin, to a Double's precision: its curve's reserves while it is on the curve, its pool's sqrt
    /// price once graduated — the reads Spot prices a DyorHQ coin from (`DyorListing`). Nil when that read didn't answer:
    /// a graduated coin is never valued at its curve's last price. The one launch price every screen values a coin at
    /// (`usdPrice(pairUSD:)`, `marketCapInPair`), never `price`.
    public let pairPrice: Double?

    public init(token: Address, curve: Address, deployer: Address, creatorFeeRecipient: Address, pairToken: Address, graduationThreshold: BigUInt, creatorTaxBps: Int, poolFeeBps: Int, tickSpacing: Int, holderFeeSharing: Bool, graduationVenue: GraduationVenue, phase: LaunchPhase, sweptQuote: BigUInt, sweptTokens: BigUInt, sweptAt: Int, poolId: Data, name: String, symbol: String, logo: String, description: String, socials: Socials, pair: PairInfo, price: BigUInt, realQuoteReserve: BigUInt, completed: Bool, rescued: Bool, launchedAt: Int, supply: BigUInt, marketCap: BigUInt, progressBps: Int, factory: Address = .zero,
                generation: LaunchpadAddresses.Generation? = nil, pairPrice: Double? = nil) {
        self.token = token
        self.curve = curve
        self.deployer = deployer
        self.creatorFeeRecipient = creatorFeeRecipient
        self.pairToken = pairToken
        self.graduationThreshold = graduationThreshold
        self.creatorTaxBps = creatorTaxBps
        self.poolFeeBps = poolFeeBps
        self.tickSpacing = tickSpacing
        self.holderFeeSharing = holderFeeSharing
        self.graduationVenue = graduationVenue
        self.phase = phase
        self.sweptQuote = sweptQuote
        self.sweptTokens = sweptTokens
        self.sweptAt = sweptAt
        self.poolId = poolId
        self.name = name
        self.symbol = symbol
        self.logo = logo
        self.description = description
        self.socials = socials
        self.pair = pair
        self.price = price
        self.realQuoteReserve = realQuoteReserve
        self.completed = completed
        self.rescued = rescued
        self.launchedAt = launchedAt
        self.supply = supply
        self.marketCap = marketCap
        self.progressBps = progressBps
        self.factory = factory
        self.generation = generation ?? LaunchpadAddresses.retiredStack(for: factory)?.generation ?? LaunchpadAddresses.monadMainnet.generation
        self.pairPrice = pairPrice.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Dollars per whole coin: `pairPrice` times its pair asset's dollar price (`pairUSD`). Nil without either, or for a
    /// product that isn't a positive finite number.
    public func usdPrice(pairUSD: Double?) -> Double? {
        guard let pairPrice, let pairUSD else { return nil }
        let usd = pairPrice * pairUSD
        return usd.isFinite && usd > 0 ? usd : nil
    }

    /// Market cap in whole pair units: `pairPrice` times the whole supply. Nil without a price.
    public var marketCapInPair: Double? { pairPrice.map { $0 * Amount.units(supply, decimals: 18) } }

    /// The launch was made on a retired launchpad: the app launches nothing there, and its curve takes sells only
    /// (`LaunchpadService.buyPlan` refuses a buy on it).
    public var isRetiredLaunchpad: Bool { LaunchpadAddresses.isRetired(factory) }

    /// Still on a retired launchpad's side of graduation — on its curve, between the curve and a pool, or in refund mode:
    /// holders can sell, nobody can buy (`RetiredLaunchpad`). A retired coin that graduated into a pool trades both ways.
    /// The sell goes into the curve, whenever it takes one (`curveSellsOpen`: not while a stuck graduation waits).
    public var isSellOnly: Bool { isRetiredLaunchpad && phase != .graduated }

    /// Listed on the Launch tab's public board: every live-launchpad coin, and a retired launchpad's coin only once it
    /// graduated into a pool, like QT (owner decision 2026-09-29). The rule follows the phase, so a retired coin that
    /// graduates later lists by itself. A sell-only coin stays reachable by its page (Home, the Portfolio, Swap, My
    /// Launchpad, and the board's "Your Sell-Only Coins" for its holders: `LaunchBoard.heldSellOnly`), never by the board.
    public var listsOnBoard: Bool { !isSellOnly }

    /// A stuck Monday graduation that DyorHQ's keepers finish, on every stack with a `graduateFallback` (v1 and v2): they
    /// retry Monday Trade with about 29.9M gas and take the Uniswap v4 fallback when it still fails. The app never sends
    /// the fallback itself (`LaunchpadService.graduateFallbackPlan` refuses it); anyone may still retry the plain
    /// graduation. The pre-audit stacks have no fallback at all.
    public var keepersTakeGraduateFallback: Bool { graduationVenue == .monday && generation.hasGraduateFallback }

    /// Quote raised towards graduation, capped at the threshold (what the token page shows as "Raised").
    public var raised: BigUInt { realQuoteReserve > graduationThreshold ? graduationThreshold : realQuoteReserve }

    /// Buys and sells are open on the curve.
    public var isTrading: Bool { phase == .bonding && !completed && !rescued }

    /// Sells are open in refund mode (fee-free, at the curve price).
    public var isRefunding: Bool { phase == .refund || rescued }

    /// Holders can sell into the curve now: while it trades, and in refund mode (fee-free, at the curve price). Not while
    /// a completed curve waits to graduate (`sell` reverts `CurveNotTrading`), while it migrates, or once it graduated.
    public var curveSellsOpen: Bool { isTrading || phase == .refund }

    /// Anyone can buy on the curve now: while it trades, and never on a retired launchpad (sell-only, `RetiredLaunchpad`).
    public var curveBuysOpen: Bool { isTrading && !isRetiredLaunchpad }

    /// The curve completed, but the coin neither graduated nor was rescued: its automatic graduation failed (the factory
    /// records `stuckSince`) and waits for a retry, anyone's plain `graduate` or DyorHQ's keepers. The record still says
    /// NotGraduated (`.bonding`), yet nothing trades: the curve refuses sells and there is no pool yet.
    public var awaitsGraduation: Bool { phase == .bonding && completed && !rescued }

    /// The coin page's status line: "Graduation pending" for a completed curve waiting to graduate, else the phase.
    public var statusTitle: String {
        awaitsGraduation ? L10n.string(LocalizedStringResource("Graduation pending", bundle: L10n.kit, comment: "[tight] A status: a launch's coin or a Moment waits to graduate into its pool.")) : phase.title
    }

    /// A sell-only coin's badge on its card: "Sell only" while its curve takes a sell, else what it waits for
    /// (`statusTitle`: "Graduation pending" or "Migrating"), when nothing trades until it graduates.
    public var sellOnlyBadge: String {
        curveSellsOpen ? L10n.string(LocalizedStringResource("Sell only", bundle: L10n.kit, comment: "[tight] A badge on a coin from a retired launchpad: it can be sold, not bought.")) : statusTitle
    }
}

/// Everything the token page needs beyond the list row.
public struct LaunchDetail: Identifiable, Hashable, Sendable {
    public var id: Address { launch.token }

    public let launch: Launch
    public let feeBps: Int
    public let snipeSchedule: [Int]
    public let quoteReserve: BigUInt
    public let tokenReserve: BigUInt
    public let sellableTokens: BigUInt
    public let phantomQuote: BigUInt
    public let reservedTokens: BigUInt
    public let swept: Bool
    public let stuckSince: Int
    public let poolKey: PoolKey?
    public let hookPendingFees: BigUInt
    public let hookPendingTax: BigUInt
    /// v2 only: DyorHQ's cut of pool fees whose holders' cut the hook already forwarded in the swap
    /// (`MemeHook.pendingProtocolFees`); on a v2 fee-sharing pool `hookPendingFees` stays 0 for the pair asset.
    public let hookPendingProtocolFees: BigUInt
    /// Holder rewards the sharing contract has received but not yet distributed: since the audit fix for flash
    /// reward-sniping, a reward is released to the balances standing at the first touch of a LATER block.
    public let queuedRewards: BigUInt
    /// v2, a Monday launch whose curve completed but that hasn't graduated: when its Uniswap v4 fallback opens.
    public let fallbackRule: GraduationFallbackRule?

    public init(launch: Launch, feeBps: Int, snipeSchedule: [Int], quoteReserve: BigUInt, tokenReserve: BigUInt, sellableTokens: BigUInt, phantomQuote: BigUInt, reservedTokens: BigUInt, swept: Bool, stuckSince: Int, poolKey: PoolKey?, hookPendingFees: BigUInt, hookPendingTax: BigUInt, queuedRewards: BigUInt = 0,
                hookPendingProtocolFees: BigUInt = 0, fallbackRule: GraduationFallbackRule? = nil) {
        self.launch = launch
        self.feeBps = feeBps
        self.snipeSchedule = snipeSchedule
        self.quoteReserve = quoteReserve
        self.tokenReserve = tokenReserve
        self.sellableTokens = sellableTokens
        self.phantomQuote = phantomQuote
        self.reservedTokens = reservedTokens
        self.swept = swept
        self.stuckSince = stuckSince
        self.poolKey = poolKey
        self.hookPendingFees = hookPendingFees
        self.hookPendingTax = hookPendingTax
        self.queuedRewards = queuedRewards
        self.hookPendingProtocolFees = hookPendingProtocolFees
        self.fallbackRule = fallbackRule
    }

    /// What the hook holds for this pool in the pair asset until someone calls `sweepPoolFees`: the creator's and
    /// DyorHQ's parts of the pool fee and the creator tax, plus (v2) DyorHQ's part of fees whose holders' part was
    /// already paid out as the trade happened.
    public var hookFeesAwaitingSweep: BigUInt { hookPendingFees + hookPendingTax + hookPendingProtocolFees }

    /// When anyone (DyorHQ's keepers included) may move this stuck launch to a locked Uniswap v4 pool, in unix seconds;
    /// nil when it isn't stuck or no v2 rule applies.
    public var v4FallbackOpensAt: Int? {
        guard let fallbackRule, stuckSince > 0 else { return nil }
        return fallbackRule.opensAt(stuckSince: stuckSince)
    }

    /// The Uniswap v4 fallback is open at `now` (the factory's `block.timestamp >= stuckSince + delay`).
    public func isV4FallbackOpen(at now: Int) -> Bool { v4FallbackOpensAt.map { now >= $0 } ?? false }

    /// Seconds of snipe tax left at `now`, clamped to the schedule so a chain clock ahead of the device never
    /// shows a longer window.
    public func snipeWindowLeft(at now: Int) -> Int {
        min(snipeSchedule.count, max(0, launch.launchedAt + snipeSchedule.count - now))
    }

    /// The snipe tax a non-exempt buyer would pay at `now`, from the schedule alone.
    public func snipeTaxBps(at now: Int) -> Int {
        guard snipeWindowLeft(at: now) > 0, !snipeSchedule.isEmpty else { return 0 }
        let index = max(0, min(snipeSchedule.count - 1, now - launch.launchedAt))
        return snipeSchedule[index]
    }
}

/// The v2 factory's rule for a stuck Monday launch's Uniswap v4 fallback (`graduateFallback`): open as soon as it is
/// stuck, unless its pair was Monday-only when it launched (aBIL; the `launchMondayOnly` snapshot, never today's
/// `pairMondayOnly`) and the owner hasn't allowed it (`v4FallbackAllowed`), in which case it opens `delay` seconds
/// (`MONDAY_ONLY_FALLBACK_DELAY`, one day) after it got stuck.
public struct GraduationFallbackRule: Hashable, Sendable {
    public let mondayOnly: Bool
    public let allowed: Bool
    public let delay: Int

    public init(mondayOnly: Bool, allowed: Bool, delay: Int) {
        self.mondayOnly = mondayOnly
        self.allowed = allowed
        self.delay = delay
    }

    /// Whether the rule makes it wait at all.
    public var waits: Bool { mondayOnly && !allowed }

    public func opensAt(stuckSince: Int) -> Int { waits ? stuckSince + delay : stuckSince }
}

/// A wallet's claimable fee-escrow balances, by pair asset. `native` is MON; `tokens` maps each ERC-20 pair asset
/// (USDC, AUSD, …) to its claimable amount. This is a creator's withdrawable fees, aggregated across their launches.
public struct EscrowBalances: Hashable, Sendable, Codable {
    public let native: BigUInt
    public let tokens: [Address: BigUInt]

    public init(native: BigUInt, tokens: [Address: BigUInt]) {
        self.native = native
        self.tokens = tokens
    }

    /// The pair tokens (excluding native) that currently hold a claimable balance.
    public var claimableTokens: [Address] { tokens.filter { $0.value > 0 }.map(\.key) }
    public var hasNative: Bool { native > 0 }
    public var isEmpty: Bool { native == 0 && tokens.values.allSatisfy { $0 == 0 } }
}

/// One launchpad's fee escrow and what an account can claim from it (`LaunchpadService.escrowReads`): nil balances when
/// the read failed.
public struct LaunchpadEscrowRead: Hashable, Sendable, Codable {
    public let escrow: Address
    public let factory: Address
    public let retired: Bool
    public let balances: EscrowBalances?
    /// The balances are an earlier read's, kept because this one failed (`keeping`).
    public let kept: Bool

    public init(escrow: Address, factory: Address, retired: Bool, balances: EscrowBalances?, kept: Bool = false) {
        self.escrow = escrow
        self.factory = factory
        self.retired = retired
        self.balances = balances
        self.kept = kept
    }

    /// `reads` as a screen shows them: an escrow read now as read, and one whose read failed with the balances `previous`
    /// had for it, marked `kept` (still unread, never zero, when it had none). `previous` is the screen's last `keeping`
    /// for the SAME account: a caller passes none once the wallet changed, so no wallet ever sees another's fees.
    public static func keeping(_ reads: [LaunchpadEscrowRead], previous: [LaunchpadEscrowRead]) -> [LaunchpadEscrowRead] {
        reads.map { read in
            guard read.balances == nil, let last = previous.first(where: { $0.escrow == read.escrow && $0.balances != nil }) else { return read }
            return LaunchpadEscrowRead(escrow: read.escrow, factory: read.factory, retired: read.retired, balances: last.balances, kept: true)
        }
    }

    /// `reads` once `token` (native MON when zero) was claimed from `escrow`: its balance there is zero, so a later read
    /// that fails can't bring the claimed amount back as kept (`keeping`). Every other balance is as it was.
    public static func claimed(_ token: Address, escrow: Address, in reads: [LaunchpadEscrowRead]) -> [LaunchpadEscrowRead] {
        reads.map { read in
            guard read.escrow == escrow, let balances = read.balances else { return read }
            var tokens = balances.tokens
            if !token.isZero, tokens[token] != nil { tokens[token] = 0 }
            let after = EscrowBalances(native: token.isZero ? 0 : balances.native, tokens: tokens)
            return LaunchpadEscrowRead(escrow: read.escrow, factory: read.factory, retired: read.retired, balances: after, kept: read.kept)
        }
    }
}

/// What one wallet holds and can claim for a launch.
public struct LaunchAccountView: Hashable, Sendable {
    public let tokenBalance: BigUInt
    public let pairBalance: BigUInt
    /// Pair-token allowance granted to the curve (always 0 for a native pair).
    public let allowance: BigUInt
    public let snipeTaxBps: Int
    public let pendingRewards: BigUInt
    public let escrowBalance: BigUInt

    public init(tokenBalance: BigUInt, pairBalance: BigUInt, allowance: BigUInt, snipeTaxBps: Int, pendingRewards: BigUInt, escrowBalance: BigUInt) {
        self.tokenBalance = tokenBalance
        self.pairBalance = pairBalance
        self.allowance = allowance
        self.snipeTaxBps = snipeTaxBps
        self.pendingRewards = pendingRewards
        self.escrowBalance = escrowBalance
    }
}

/// `BondingCurve.quoteBuy`: `used == tokens' net cost + fee + tax + snipe`, and `refund` is what a completing buy
/// hands back.
public struct BuyQuote: Hashable, Sendable {
    public let tokensOut: BigUInt
    public let used: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt
    public let snipe: BigUInt
    public let refund: BigUInt

    public init(tokensOut: BigUInt, used: BigUInt, fee: BigUInt, tax: BigUInt, snipe: BigUInt, refund: BigUInt) {
        self.tokensOut = tokensOut
        self.used = used
        self.fee = fee
        self.tax = tax
        self.snipe = snipe
        self.refund = refund
    }

    /// `out × (10 000 − slippageBps) / 10 000`, the `minTokensOut` the trade panel sends.
    public func minimumOut(slippageBps: Int) -> BigUInt { LaunchpadMath.minimumOut(tokensOut, slippageBps: slippageBps) }
}

public struct SellQuote: Hashable, Sendable {
    public let quoteOut: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt

    public init(quoteOut: BigUInt, fee: BigUInt, tax: BigUInt) {
        self.quoteOut = quoteOut
        self.fee = fee
        self.tax = tax
    }

    public func minimumOut(slippageBps: Int) -> BigUInt { LaunchpadMath.minimumOut(quoteOut, slippageBps: slippageBps) }
}

/// One curve fill from a `CurveBuy` / `CurveSell` event. `quoteAmount` is the quote that moved the reserves
/// (buys: input net of fees; sells: gross before fees) so `price` is the curve price the fill happened at.
public struct CurveTrade: Identifiable, Hashable, Sendable {
    /// `txHash-logIndex`.
    public let id: String
    public let block: UInt64
    public let logIndex: Int
    /// Unix seconds, estimated from the latest block at the session's measured pace (`BlockClock`).
    public let time: Int
    public let trader: Address
    public let isBuy: Bool
    public let quoteAmount: BigUInt
    public let tokenAmount: BigUInt
    /// Decimals of the quote asset, so volumes can be expressed in pair units.
    public let quoteDecimals: Int
    /// Pair units per whole token (the same scale as `Launch.pairPrice`).
    public let price: Double

    public init(id: String, block: UInt64, logIndex: Int, time: Int, trader: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt, quoteDecimals: Int, price: Double) {
        self.id = id
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.trader = trader
        self.isBuy = isBuy
        self.quoteAmount = quoteAmount
        self.tokenAmount = tokenAmount
        self.quoteDecimals = quoteDecimals
        self.price = price
    }

    public var transactionHash: Data? { Data(hex: String(id.prefix(66))) }
}

/// A window of one curve's fills (`LaunchpadService.trades`), and whether all of it was read.
public struct CurveTrades: Sendable, Hashable {
    /// The fills read, oldest first.
    public let trades: [CurveTrade]
    /// Every block of the window was read, so `trades` are all its fills. False: the read stopped short (its budget spent,
    /// an endpoint that didn't answer). It reads newest first, so `trades` are the latest fills, every one down to where it
    /// stopped, and the oldest of the window are missing: a screen says so, and never shows a sum of them (the 24h volume)
    /// as the whole.
    public let complete: Bool

    public init(trades: [CurveTrade], complete: Bool) {
        self.trades = trades
        self.complete = complete
    }
}

/// How many wallets hold a launch coin (`LaunchpadService.holders`): the addresses whose transfers since the launch leave
/// them a positive balance, the zero address and the coin's curve left out.
public struct HolderCount: Sendable, Hashable {
    public let count: Int
    /// Every transfer from before the coin's launch to the head was read: `count` is exact. False: the read stopped short
    /// of the launch, and `count` is a minimum. The transfers are read newest first, so what was read runs from some block
    /// to the head, and an address whose transfers there add up to more in than out holds the coin now, whatever it held
    /// before (a balance is never below zero): every address counted holds it, and only holders whose last transfer is
    /// older than the read are missing. Read oldest first, as in build 22 and earlier, the same count was of balances at
    /// some block in the past, neither a minimum nor the count: a coin launched in the last six days read 0.
    public let complete: Bool

    public init(count: Int, complete: Bool) {
        self.count = count
        self.complete = complete
    }
}

/// OHLC bucket for the lightweight chart. `volume` is quote traded, in pair units.
public struct Candle: Hashable, Sendable, Identifiable {
    public var id: Int { time }
    public let time: Int
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double

    public init(time: Int, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

/// What the create screen submits. Mirrors the web app's `LaunchInput`: `expectedEconomics` must be the bytes
/// `previewLaunchEconomics(configId, pairToken)` returns at submit time, which is how the contract guarantees
/// the owner cannot change the terms between the user reading them and the transaction landing.
public struct LaunchInput: Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var description: String
    public var logo: String
    public var socials: Socials
    /// Receives creator fees and any creator tax; `Address.zero` lets the contract default to the deployer.
    public var creatorFeeRecipient: Address
    public var creatorTaxBps: Int
    public var holderFeeSharing: Bool
    /// Where the curve graduates. Defaults to Uniswap v4; the create screen forces `.monday` for `pairMondayOnly`
    /// (aBIL) pairs, which the factory also enforces (`PairRequiresMonday`).
    public var graduationVenue: GraduationVenue
    public var pairToken: Address
    public var configId: BigUInt
    /// Snipe-tax exemptions (at most `LaunchpadService.maxExemptions`); the deployer and creator wallet are always exempt.
    public var exemptions: [Address]
    /// Developer buy in pair units, made in the same transaction through the router; 0 launches without one.
    public var initialBuy: BigUInt
    /// Slippage floor for the developer buy.
    public var minTokensOut: BigUInt
    /// 32 bytes from `LaunchpadService.previewLaunchEconomics`.
    public var expectedEconomics: Data
    /// 32 random bytes; the token and curve addresses derive from `keccak(deployer, salt)`.
    public var salt: Data

    public init(name: String, symbol: String, description: String = "", logo: String = "", socials: Socials = .none, creatorFeeRecipient: Address = .zero, creatorTaxBps: Int = 0, holderFeeSharing: Bool = true, graduationVenue: GraduationVenue = .uniswapV4, pairToken: Address = .zero, configId: BigUInt = 0, exemptions: [Address] = [], initialBuy: BigUInt = 0, minTokensOut: BigUInt = 0, expectedEconomics: Data = Data(repeating: 0, count: 32), salt: Data = LaunchInput.randomSalt()) {
        self.name = name
        self.symbol = symbol
        self.description = description
        self.logo = logo
        self.socials = socials
        self.creatorFeeRecipient = creatorFeeRecipient
        self.creatorTaxBps = creatorTaxBps
        self.holderFeeSharing = holderFeeSharing
        self.graduationVenue = graduationVenue
        self.pairToken = pairToken
        self.configId = configId
        self.exemptions = exemptions
        self.initialBuy = initialBuy
        self.minTokensOut = minTokensOut
        self.expectedEconomics = expectedEconomics
        self.salt = salt
    }

    public var pairIsNative: Bool { pairToken.isZero }

    public static func randomSalt() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// One row of the launchpad activity feed.
public struct ActivityItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case launch(token: Address, curve: Address, deployer: Address)
        /// `quoteAmount` is the buyer's gross input or the seller's net output, as the feed shows amounts.
        case trade(token: Address, curve: Address, trader: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt)
        case graduated(token: Address, poolId: Data)
    }

    /// `txHash-logIndex`.
    public let id: String
    public let block: UInt64
    public let logIndex: Int
    public let time: Int
    public let transactionHash: Data
    public let kind: Kind

    public init(id: String, block: UInt64, logIndex: Int, time: Int, transactionHash: Data, kind: Kind) {
        self.id = id
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.transactionHash = transactionHash
        self.kind = kind
    }

    public var token: Address {
        switch kind {
        case .launch(let token, _, _), .graduated(let token, _), .trade(let token, _, _, _, _, _): return token
        }
    }

    /// The wallet the row is about: the deployer of a launch or the trader of a trade.
    public var actor: Address? {
        switch kind {
        case .launch(_, _, let deployer): return deployer
        case .trade(_, _, let trader, _, _, _): return trader
        case .graduated: return nil
        }
    }
}

public enum LaunchpadError: Error, LocalizedError, Equatable {
    case notDeployed
    case unexpectedResponse(String)
    /// The factory's launch fee is no longer the one the screen showed (the new fee, in wei).
    case launchFeeChanged(BigUInt)
    /// The factory's launch terms (supply, fees, graduation, snipe tax, creator-tax cap) are no longer the ones the
    /// screen showed, or the screen had none to bind to.
    case termsChanged
    /// The factory would refuse the launch now (read when the plan was built).
    case launchBlocked(LaunchBlocker)
    /// `graduateFallback` is never sent from the app, on any stack: DyorHQ's keepers send it with the gas it needs.
    case graduateFallbackByKeepers
    /// A buy on a retired launchpad's curve (or a developer buy through a retired router): those curves take sells only.
    case retiredLaunchpad

    public var errorDescription: String? {
        switch self {
        case .notDeployed: return L10n.tr("The launchpad contracts are not deployed yet.")
        case .launchFeeChanged(let fee): return L10n.tr("The launch fee changed to \(NumberStyle.units(fee, decimals: 18)) MON since this screen loaded, so nothing was sent. Close this screen, refresh the Launchpad and review the new fee.")
        case .termsChanged: return L10n.tr("The launch terms changed since this screen loaded, so nothing was sent. Close this screen, refresh the Launchpad and review the new terms.")
        case .launchBlocked(let blocker): return L10n.string(LocalizedStringResource("\(blocker.message) Nothing was sent.", bundle: L10n.kit, comment: "The value is a sentence that says why; this one adds that no transaction was sent."))
        case .retiredLaunchpad: return L10n.string(LocalizedStringResource("\(RetiredLaunchpad.notice) Nothing was sent.", bundle: L10n.kit, comment: "The value is a sentence that says why; this one adds that no transaction was sent."))
        case .graduateFallbackByKeepers: return L10n.tr("DyorHQ's keepers will finish this graduation: they retry it with the gas it needs and, if Monday Trade still refuses it, move it to a locked Uniswap v4 pool. Nothing was sent.")
        case .unexpectedResponse(let what): return L10n.tr("The launchpad returned something the app could not read (\(what)).")
        }
    }
}

/// Pure arithmetic shared by the screens and the service.
public enum LaunchpadMath {
    public static let bps: BigUInt = 10_000

    public static func minimumOut(_ amount: BigUInt, slippageBps: Int) -> BigUInt {
        let keep = BigUInt(max(0, min(10_000, 10_000 - slippageBps)))
        return amount * keep / bps
    }

    public static func feeOf(_ amount: BigUInt, bps taxBps: Int) -> BigUInt {
        amount * BigUInt(max(0, taxBps)) / bps
    }

    /// Gross amount whose net after `totalBps` of fees is at least `net`, rounded up (`CurveMath.grossForNet`).
    public static func grossForNet(_ net: BigUInt, totalBps: Int) -> BigUInt {
        let keep = BigUInt(max(1, 10_000 - totalBps))
        return (net * bps + keep - 1) / keep
    }

    /// Mirrors `BondingCurve.quoteBuy` for the deployer (snipe-tax exempt) before the curve exists, which is what
    /// the create screen shows next to the developer buy.
    public static func estimateDevBuy(amount: BigUInt, pair: PairEconomics, protocol info: ProtocolInfo, creatorTaxBps: Int) -> (tokens: BigUInt, used: BigUInt, refund: BigUInt, sharePercent: Double) {
        let totalBps = info.curveFeeBps + creatorTaxBps
        func netOf(_ gross: BigUInt) -> BigUInt {
            let fees = feeOf(gross, bps: info.curveFeeBps) + feeOf(gross, bps: creatorTaxBps)
            return fees > gross ? 0 : gross - fees
        }
        var used = amount
        var net = netOf(used)
        if net > pair.graduationThreshold {
            used = grossForNet(pair.graduationThreshold, totalBps: totalBps)
            net = netOf(used)
        }
        let denominator = pair.phantomQuote + net
        let tokens = denominator == 0 ? 0 : net * info.supply / denominator
        let share = info.supply == 0 ? 0 : Double(tokens * bps / info.supply) / 100
        return (tokens, used, amount > used ? amount - used : 0, share)
    }
}
