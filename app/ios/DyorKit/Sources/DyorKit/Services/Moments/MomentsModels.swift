import BigInt
import Foundation

/* Moments: a per-moment NFT edition whose collects fund a coin that graduates into a locked Uniswap v4 pool.
   The clean-room contract set lives in `contracts/src/moments`; these models are the app-facing shape of what
   the contracts expose, ported from the web app's `app/lib/moments/reads.ts` so both clients agree to the wei. */

/// Where the Moments contracts live: the v2 set (`monadMainnet`, cohort 4) and the retired v1 cohorts
/// (`retiredMainnet`); `isDeployed` is what every read checks.
public struct MomentsAddresses: Sendable, Hashable {
    public var factory: Address
    public var collect: Address
    public var vesting: Address
    public var graduation: Address
    public var locker: Address
    public var hook: Address
    public var buyback: Address
    public var usdc: Address
    public var permit2: Address
    public var poolManager: Address
    public var platform: Address
    public var treasury: Address
    /// Block the factory was deployed in: no Moment coin has a Transfer before it, so history scans start here.
    public var deployBlock: UInt64
    /// The contract source the stack runs. v2-only getters (`termsHash`, `guardian`, the NFT's own link base, the
    /// locker's `available`…) are read from a `.v2` stack only.
    public var generation: ContractGeneration
    /// Why the cohort is retired; nil for the live one.
    public var retirement: MomentsRetirement?

    public init(factory: Address = .zero, collect: Address = .zero, vesting: Address = .zero, graduation: Address = .zero, locker: Address = .zero,
                hook: Address = .zero, buyback: Address = .zero, usdc: Address = Monad.usdc, permit2: Address = Uniswap.permit2,
                poolManager: Address = Uniswap.poolManager, platform: Address = .zero, treasury: Address = .zero, deployBlock: UInt64 = 0,
                generation: ContractGeneration = .v1, retirement: MomentsRetirement? = nil) {
        self.factory = factory
        self.collect = collect
        self.vesting = vesting
        self.graduation = graduation
        self.locker = locker
        self.hook = hook
        self.buyback = buyback
        self.usdc = usdc
        self.permit2 = permit2
        self.poolManager = poolManager
        self.platform = platform
        self.treasury = treasury
        self.deployBlock = deployBlock
        self.generation = generation
        self.retirement = retirement
    }

    public var isDeployed: Bool { !factory.isZero && !collect.isZero && !vesting.isZero && !graduation.isZero }

    public static let none = MomentsAddresses()

    /// The link base the v2 Moments are deployed with (`EXTERNAL_BASE_URI`), `https://dyorhq.fun/moments/c4/`: an NFT's
    /// `external_url` is this plus its id, which `MomentLink` reads as cohort c4. The base is part of the terms hash, and
    /// the app refuses to publish on a factory whose `externalBaseURI()` is anything else (`MomentPolicy.canPublish`).
    public static let expectedExternalBaseURI = "https://\(MomentLink.host)/moments/\(MomentLink.Cohort.c4.rawValue)/"

    // The only place the v2 Moments addresses live. Everything that serves the live cohort derives from this constant
    // (AppConfig, `MomentLink.Cohort.c4`, the passkey signing policy, swap routing).
    /// Moments v2 on Monad mainnet (chain 143), cohort 4: deployed 2026-09-28 with governance the Owner Safe 0x6D2A…,
    /// guardian 0x686C… and the link base `expectedExternalBaseURI`, Sourcify-verified. Every module from
    /// `contracts/deployments/moments-143.json`, platform and treasury from its policy, and `deployBlock` from the
    /// factory's creation receipt (added to the record by hand: the deploy script does not write it). `V2WiringTests`
    /// accepts only all-zero or fully wired, and fails a wired table that differs from the record or a release built
    /// while it is pending (`DYORHQ_RELEASE_GATE=1`).
    public static let monadMainnet = MomentsAddresses(
        factory: Address(literal: "0x95eb7F5A88B10D9dF32aC54F48C767927fa80840"),
        collect: Address(literal: "0xe6beb4A10827a2e50B155B7386b1369d504186Cc"),
        vesting: Address(literal: "0x6Eb483C1E1Be2b6700AD590ddE326B597a13649A"),
        graduation: Address(literal: "0x736dD4c4A09Ef41C508bb2175001eA038A3D5152"),
        locker: Address(literal: "0xe86557E2B44c119B05948c918C9Eb0c1cE5331a0"),
        hook: Address(literal: "0xDa7042CF42B26Be4d6816C9eeB1B0bee8e3Fe0cc"),
        buyback: Address(literal: "0xFAf9Ad081d43F6A1b949DB81A2d7145F19845613"),
        usdc: Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"),
        permit2: Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3"),
        poolManager: Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e"),
        platform: Address(literal: "0x15ED3bb488231213b141A2f78b62358D52235Cd7"),
        treasury: Address(literal: "0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371"),
        deployBlock: 108_859_966,
        generation: .v2
    )

    /// Retired Moments cohorts on Monad mainnet, newest first — CLAIM-ONLY. Publishing is paused on chain on cohorts 1
    /// and 2; cohort 3 stays open there (owner decision 2026-09-28: retired in the app only). The app never publishes,
    /// collects, expires, retries, buys back or trades on any of them: holders claim their vesting and creators withdraw
    /// their own proceeds and pool fees, through `RetiredMoments` and nothing else. Cohorts 1 and 2 snapshotted the
    /// retired beneficiaries (platform 0xf4D4…, treasury 0x5282… whose key leaked); cohort 3 pays the current fees wallet
    /// 0x15ED… and treasury 0x5aDb…, and is retired because the v2 contracts replaced it (`retirement` says which).
    /// Moment ids restart at 1 on every factory, so anything about a retired Moment is keyed by `MomentKey` (factory,
    /// id). Mirrors `moments-143-cohort3.json`, `moments-143-cohort2.json` and `moments-143-cohort1.json` (factory
    /// getters checked on chain);
    /// `MomentsRetiredTests` pins the table.
    public static let retiredMainnet: [MomentsAddresses] = [
        // Cohort 3 (2026-09-23, the $2,000-FDV policy, the rotated wallets): 1 Moment, "Nature". Retired for v2.
        MomentsAddresses(
            factory: Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26"),
            collect: Address(literal: "0xb53897A4C6280480c267351518D184C2E6591D30"),
            vesting: Address(literal: "0x05584910ab57d65723eB878D295b3353a4cbb021"),
            graduation: Address(literal: "0xA2231E39ce7AE4f7d5e56Beae2dD3a8a59F3b9aA"),
            locker: Address(literal: "0x37C5A2c15d99701CF698B146cdCD1853825Ef455"),
            hook: Address(literal: "0xD5BFff467FDAe04664357e75bF059986c41260CC"),
            buyback: Address(literal: "0x3B574312Bb4e1D36C9a1Ba698bf77BbD223ca913"),
            usdc: Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"),
            permit2: Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3"),
            poolManager: Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e"),
            platform: Address(literal: "0x15ED3bb488231213b141A2f78b62358D52235Cd7"),
            treasury: Address(literal: "0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371"),
            deployBlock: 107_311_600,
            retirement: .replaced
        ),
        // Cohort 2 (2026-09-22, the $2,000-FDV policy): 2 Moments.
        MomentsAddresses(
            factory: Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581"),
            collect: Address(literal: "0x8f65ea0236b5fa6351a45Bd48244c3525Fb92493"),
            vesting: Address(literal: "0xe087eff01C567F88a7cb6BDBDBF04B46Fee56C99"),
            graduation: Address(literal: "0x353F245A2458B994a65116A4c69643cf6608045b"),
            locker: Address(literal: "0x995735cF317656a10de52b73AB50A2aAdc069a8a"),
            hook: Address(literal: "0x501D703588c4feAbBeE5A9a77408c7FCbD3a20Cc"),
            buyback: Address(literal: "0xacae95377513C54DA9ff549DFE5cB77001F6c6F5"),
            usdc: Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"),
            permit2: Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3"),
            poolManager: Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e"),
            platform: Address(literal: "0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48"),
            treasury: Address(literal: "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045"),
            deployBlock: 106_984_957,
            retirement: .retiredWallets
        ),
        // Cohort 1 (2026-09-16, the $10 small-cap policy): 3 Moments; #2 graduated and vests to its holders into 2027.
        MomentsAddresses(
            factory: Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"),
            collect: Address(literal: "0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c"),
            vesting: Address(literal: "0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C"),
            graduation: Address(literal: "0x307De00950F039969855eFb859A6088d695e76b1"),
            locker: Address(literal: "0x832851A42Bf1FD1aF7a19c82cF132290c605E406"),
            hook: Address(literal: "0x8Aa322471Bef2996D3B50cB12F63C6A0054460Cc"),
            buyback: Address(literal: "0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2"),
            usdc: Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"),
            permit2: Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3"),
            poolManager: Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e"),
            platform: Address(literal: "0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48"),
            treasury: Address(literal: "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045"),
            deployBlock: 105_347_754,
            retirement: .retiredWallets
        ),
    ]

    /// The retired cohort whose factory is `factory`, or nil when it is not a retired one.
    public static func retired(factory: Address) -> MomentsAddresses? {
        retiredMainnet.first { $0.factory == factory }
    }

    /// Every coin the retired cohorts minted, by (factory, id) — read on chain (`getMoment` / `momentIdByCoin`).
    /// The counts are pinned (`MomentLink.Cohort.finalMomentCount`), so the set is final for the app and needs no read
    /// (cohort 3 is not paused on chain; the release gate checks the set against it, `check-launchpad-addresses.py --release`): a coin
    /// here is never offered a trade in the app, even when its cohort cannot be read (the app trades no past cohort's coin; cohorts 1 and 2's pools also pay
    /// the retired platform wallet).
    public static let retiredMainnetCoins: [Address: MomentKey] = [
        // Cohort 3 ("Nature", still collecting when the cohort was retired)
        Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF"): MomentKey(factory: Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26"), id: 1),
        // Cohort 2
        Address(literal: "0xC18941ca9fBaa613841c3d31a7Dd1D262a47a2E5"): MomentKey(factory: Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581"), id: 1),
        Address(literal: "0x01D2c48E3cd38804a643E391421289933ed3D4a7"): MomentKey(factory: Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581"), id: 2),
        // Cohort 1 (#2 graduated: its pool exists)
        Address(literal: "0xDc1bC41b7C197DE19f17C7832bec3Bb748D92297"): MomentKey(factory: Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"), id: 1),
        Address(literal: "0xd6c17E083b53fa1c46b71120D6959303Ae4B8e1F"): MomentKey(factory: Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"), id: 2),
        Address(literal: "0x8D2AEc229b5A4Fd4D4aB1725c92B6B7f53fBc50f"): MomentKey(factory: Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"), id: 3),
    ]

    /// Whether `token` is a retired cohort's Moment coin (see `retiredMainnetCoins`): never trade it in the app.
    public static func isRetiredCoin(_ token: Address) -> Bool {
        retiredMainnetCoins[token] != nil
    }

    /// Protocol addresses that hold Moment coins without being "holders" (the pool, the locker, vesting, …).
    public var protocolHolders: Set<Address> { [poolManager, locker, vesting, buyback, hook, graduation] }
}

/// Why a Moments cohort was retired. Either way it is claim-only in the app; the reason is what its pages say.
public enum MomentsRetirement: Sendable, Hashable {
    /// Cohorts 1 and 2: every Moment snapshotted the retired beneficiaries (platform 0xf4D4…, treasury 0x5282…).
    case retiredWallets
    /// Cohort 3: its Moments pay the current fees and treasury wallets; the v2 contracts replaced it.
    case replaced
}

/// `MomentTypes` constants, the same numbers the contracts hard-code.
public enum MomentsConstants {
    public static let bps = 10_000
    /// Fixed coin supply per Moment: 100,000,000 coins at 18 decimals.
    public static let supply = BigUInt(100_000_000) * BigUInt(10).power(18)
    public static let coinDecimals = 18
    public static let usdcDecimals = 6
    /// A vesting "month" is a fixed 30-day cliff.
    public static let monthSeconds = 30 * 86_400
    /// A completed Moment whose graduation keeps failing can be wound down this long after the first failure.
    public static let stuckGraceSeconds = 7 * 86_400
    /// v2: a proposed policy can be applied from `pendingPolicyAt` until this long after it; later it lapses
    /// (`MomentsFactory.POLICY_APPLY_WINDOW`).
    public static let policyApplyWindowSeconds = 7 * 86_400
    /// Upper bound on editions per collect.
    public static let maxBatch = 20
    public static let minCollectWindowSeconds = 3_600
    public static let maxCollectWindowSeconds = 30 * 86_400
    /// Hard cap on the creator's coin allocation, whatever the policy says.
    public static let maxCreatorAllocBps = 1_000
    /// The hook's Moments fee on every pool trade (1% of the USDC side) and how it is split.
    public static let hookFeeBps = 100
    public static let hookCreatorShareBps = 2_000
    public static let hookPlatformShareBps = 3_000
    public static let hookBuybackShareBps = 5_000
    /// The pool's LP fee in hundredths of a bip (0.5%); it accrues to the locked full-range position.
    public static let lpFee = 5_000
    public static let tickSpacing = 60
    /// Total trading fee a swapper pays on a Moment pool: LP 0.5% + hook 1%.
    public static let totalTradeFeeBps = 150
}

/// `MomentTypes.State`.
public enum MomentState: Int, Sendable, Hashable, Codable, CaseIterable {
    case collecting = 0
    case graduationPending
    case graduated
    case expired

    public var title: String {
        switch self {
        case .collecting: return L10n.string(LocalizedStringResource("Collecting", bundle: L10n.kit, comment: "[tight] A Moment's state: its editions can be collected."))
        case .graduationPending: return L10n.string(LocalizedStringResource("Graduation pending", bundle: L10n.kit, comment: "[tight] A status: a launch's coin or a Moment waits to graduate into its pool."))
        case .graduated: return L10n.string(LocalizedStringResource("Graduated", bundle: L10n.kit, comment: "[tight] A status: a launch's coin or a Moment has graduated, and trades in its pool."))
        case .expired: return L10n.string(LocalizedStringResource("Expired", bundle: L10n.kit, comment: "[tight] A Moment's state: its collect window closed before it graduated."))
        }
    }

    init(raw: BigUInt) { self = MomentState(rawValue: Int(clamping: raw)) ?? .collecting }
}

/// The factory policy that applies to Moments published from now on (existing Moments keep their snapshot). On v2 the
/// policy, the link base and `termsHash()` are read in one multicall, at one block (`MomentsService.policy`), so the
/// hash a publish carries is the hash of exactly the terms the review screen shows.
public struct MomentPolicy: Sendable, Hashable {
    public let threshold: BigUInt
    public let minPrice: BigUInt
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let maxCreatorAllocBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let platform: Address
    public let treasury: Address
    public let momentCount: Int
    public let publishingPaused: Bool
    public let externalBaseURI: String
    /// v2: the factory's `termsHash()` = keccak256(abi.encode(policy, externalBaseURI)), what `publish` must carry. Nil on
    /// a v1 factory, which has none (and on which the app no longer publishes).
    public let termsHash: Data?
    /// v2: the guardian key, which can cancel a proposal and pause publishing. Nil on v1.
    public let guardian: Address?
    /// v2: the guardian's pause. Governance cannot lift it; publishing is off while it or `publishingPaused` is on.
    public let guardianPaused: Bool
    /// A policy proposed and not applied yet, if any (`MomentsFactory.pendingPolicy`).
    public var pending: PendingMomentPolicy?

    public init(threshold: BigUInt, minPrice: BigUInt, creatorBps: Int, platformBps: Int, reserveBps: Int, maxCreatorAllocBps: Int, expiryCreatorBps: Int, royaltyBps: Int, platform: Address, treasury: Address, momentCount: Int, publishingPaused: Bool, externalBaseURI: String,
                termsHash: Data? = nil, guardian: Address? = nil, guardianPaused: Bool = false) {
        self.threshold = threshold
        self.minPrice = minPrice
        self.creatorBps = creatorBps
        self.platformBps = platformBps
        self.reserveBps = reserveBps
        self.maxCreatorAllocBps = maxCreatorAllocBps
        self.expiryCreatorBps = expiryCreatorBps
        self.royaltyBps = royaltyBps
        self.platform = platform
        self.treasury = treasury
        self.momentCount = momentCount
        self.publishingPaused = publishingPaused
        self.externalBaseURI = externalBaseURI
        self.termsHash = termsHash
        self.guardian = guardian
        self.guardianPaused = guardianPaused
    }

    /// The hash of the terms held here, computed as the factory computes `termsHash()`.
    public var localTermsHash: Data { MomentsABI.termsHash(policy: self, base: externalBaseURI) }

    /// Why a publish can't be built on these terms.
    public enum PublishBlock: Sendable, Hashable {
        /// Governance paused publishing.
        case publishingPaused
        /// The guardian paused publishing (governance cannot lift it).
        case guardianPaused
        /// The factory would give the new NFTs a link base other than DyorHQ's v2 one.
        case unexpectedLinkBase
        /// No `termsHash()` was read (a v1 factory), or it isn't the hash of the terms read with it.
        case unverifiedTerms

        public var message: String {
            switch self {
            case .publishingPaused: return L10n.tr("Publishing is paused by governance; collecting continues.")
            case .guardianPaused: return L10n.tr("Publishing is paused by the Moments guardian; collecting continues.")
            case .unexpectedLinkBase: return L10n.tr("Publishing is off: the Moments contract would link new Moments somewhere other than dyorhq.fun.")
            case .unverifiedTerms: return L10n.tr("Publishing is off: the Moments terms couldn't be verified.")
            }
        }
    }

    /// Nil when a publish may be built on these terms: neither pause is on, the link base is exactly
    /// `MomentsAddresses.expectedExternalBaseURI`, and the on-chain `termsHash()` is the hash of the terms read with it
    /// (so the hash a publish carries binds what the screen shows).
    public var publishBlock: PublishBlock? {
        if publishingPaused { return .publishingPaused }
        if guardianPaused { return .guardianPaused }
        if externalBaseURI != MomentsAddresses.expectedExternalBaseURI { return .unexpectedLinkBase }
        guard let termsHash, termsHash == localTermsHash else { return .unverifiedTerms }
        return nil
    }

    public var canPublish: Bool { publishBlock == nil }
}

/// A policy governance proposed for Moments published from then on, not applied yet. Once `applicableAt` passes,
/// anyone can apply it (`applyPolicy` is permissionless) at any moment, also between a creator's review and their
/// publish landing. On v2 the publish carries the hash of the reviewed terms, so it is then refused (`TermsChanged`)
/// and the creator reviews again: the terms never change silently. A v2 proposal nobody applied within
/// `MomentsConstants.policyApplyWindowSeconds` lapses (security audit 2026-09-26, MO-4).
public struct PendingMomentPolicy: Sendable, Hashable {
    public let threshold: BigUInt
    public let minPrice: BigUInt
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let maxCreatorAllocBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let platform: Address
    public let treasury: Address
    /// The earliest time it can be applied.
    public let applicableAt: Date
    /// v2: the last moment it can be applied (`applicableAt` + `POLICY_APPLY_WINDOW`); after it the proposal has lapsed.
    /// Nil on v1, where a proposal stays applicable until it is applied or cancelled.
    public let lapsesAt: Date?

    public init(threshold: BigUInt, minPrice: BigUInt, creatorBps: Int, platformBps: Int, reserveBps: Int, maxCreatorAllocBps: Int, expiryCreatorBps: Int, royaltyBps: Int, platform: Address, treasury: Address, applicableAt: Date, lapsesAt: Date? = nil) {
        self.threshold = threshold
        self.minPrice = minPrice
        self.creatorBps = creatorBps
        self.platformBps = platformBps
        self.reserveBps = reserveBps
        self.maxCreatorAllocBps = maxCreatorAllocBps
        self.expiryCreatorBps = expiryCreatorBps
        self.royaltyBps = royaltyBps
        self.platform = platform
        self.treasury = treasury
        self.applicableAt = applicableAt
        self.lapsesAt = lapsesAt
    }

    /// The terms a pending policy changes.
    public enum Field: String, Sendable, CaseIterable {
        case threshold, minPrice, split, maxCreatorAlloc, royalty, expiryShare, platform, treasury
    }

    /// Which terms differ from `current`, in `Field` order; empty when the proposal repeats the live policy.
    public func changes(from current: MomentPolicy) -> [Field] {
        Field.allCases.filter { field in
            switch field {
            case .threshold: return threshold != current.threshold
            case .minPrice: return minPrice != current.minPrice
            case .split: return creatorBps != current.creatorBps || platformBps != current.platformBps || reserveBps != current.reserveBps
            case .maxCreatorAlloc: return maxCreatorAllocBps != current.maxCreatorAllocBps
            case .royalty: return royaltyBps != current.royaltyBps
            case .expiryShare: return expiryCreatorBps != current.expiryCreatorBps
            case .platform: return platform != current.platform
            case .treasury: return treasury != current.treasury
            }
        }
    }

    /// Whether anyone can apply it at `now`: from `applicableAt` and, on v2, until `lapsesAt` inclusive (`applyPolicy`
    /// reverts `PolicyLapsed` only once the time is past it).
    public func isApplicable(at now: Date) -> Bool {
        guard now >= applicableAt else { return false }
        if let lapsesAt { return now <= lapsesAt }
        return true
    }

    /// Whether it lapsed unapplied (v2 only): nobody can apply it any more, so it changes nothing.
    public func hasLapsed(at now: Date) -> Bool { lapsesAt.map { now > $0 } ?? false }
}

/// What the Moments tab reads: the newest Moments (`MomentsService.moments(limit:)`), and the terms
/// (`MomentsService.policy()`) or why they couldn't be read, each read apart and shown as it lands (`MomentsModel.load`).
/// A policy that can't be read — a link base that isn't text is refused (`ABI.StringDecoding.strict`), since it is
/// compared with DyorHQ's and hashed into `termsHash()` — leaves Publish unavailable (`policyUnread`) while the Moments
/// still show.
public struct MomentsBoard: Sendable {
    public let moments: [MomentInfo]
    public let policy: Result<MomentPolicy?, any Error>

    public init(moments: [MomentInfo], policy: Result<MomentPolicy?, any Error>) {
        self.moments = moments
        self.policy = policy
    }

    /// Why Publish is unavailable when the policy couldn't be read; nil when it was.
    public var policyUnread: String? {
        guard case .failure = policy else { return nil }
        return L10n.tr("Publishing is unavailable right now: the Moments terms couldn't be read. Pull to refresh.")
    }
}

/// `MomentTypes.Provenance`: what the NFT records about the moment itself.
public struct MomentProvenance: Sendable, Hashable, Codable {
    public let mediaURI: String
    public let mediaHash: Data
    public let place: String
    /// Unix timestamp of the moment.
    public let date: Int
    public let animationURI: String

    public init(mediaURI: String, mediaHash: Data, place: String, date: Int, animationURI: String) {
        self.mediaURI = mediaURI
        self.mediaHash = mediaHash
        self.place = place
        self.date = date
        self.animationURI = animationURI
    }

    /// The media link as a URL the app can load: `ipfs://` is served through a public gateway.
    public var mediaURL: URL? { MomentsMath.url(mediaURI) }
    public var animationURL: URL? { MomentsMath.url(animationURI) }
}

/// A Moment's identity across cohorts. Ids restart at 1 on every factory, so wherever more than one cohort is in
/// play — dictionaries, list identities, navigation, history lookups — the key is (factory, id), never the id alone.
public struct MomentKey: Sendable, Hashable, CustomStringConvertible {
    public let factory: Address
    public let id: BigUInt

    public init(factory: Address, id: BigUInt) {
        self.factory = factory
        self.id = id
    }

    public var description: String { "\(factory.hex)/\(id)" }
}

/// `MomentTypes.Moment`: everything fixed at publish. There is no setter on chain.
public struct Moment: Sendable, Hashable, Codable, Identifiable {
    public let id: BigUInt
    public let creator: Address
    public let platform: Address
    public let treasury: Address
    public let coin: Address
    public let nft: Address
    /// Collect price in USDC units (6 dp).
    public let price: BigUInt
    /// Reserve that graduates the Moment, in USDC units.
    public let threshold: BigUInt
    /// entitlement = floor(gross · rateNum / rateDen), in coin wei per USDC unit.
    public let rateNum: BigUInt
    public let rateDen: BigUInt
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let creatorAllocBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let publishedAt: Int
    /// Collecting is possible strictly before this timestamp.
    public let deadline: Int
    /// The factory (cohort) that published it — not part of the on-chain struct; the service that read it fills it in.
    public let factory: Address

    public init(id: BigUInt, creator: Address, platform: Address, treasury: Address, coin: Address, nft: Address, price: BigUInt, threshold: BigUInt, rateNum: BigUInt, rateDen: BigUInt, creatorBps: Int, platformBps: Int, reserveBps: Int, creatorAllocBps: Int, expiryCreatorBps: Int, royaltyBps: Int, publishedAt: Int, deadline: Int, factory: Address = .zero) {
        self.id = id
        self.creator = creator
        self.platform = platform
        self.treasury = treasury
        self.coin = coin
        self.nft = nft
        self.price = price
        self.threshold = threshold
        self.rateNum = rateNum
        self.rateDen = rateDen
        self.creatorBps = creatorBps
        self.platformBps = platformBps
        self.reserveBps = reserveBps
        self.creatorAllocBps = creatorAllocBps
        self.expiryCreatorBps = expiryCreatorBps
        self.royaltyBps = royaltyBps
        self.publishedAt = publishedAt
        self.deadline = deadline
        self.factory = factory
    }

    /// The creator's coin allocation in wei (`SUPPLY · creatorAllocBps / BPS`).
    public var creatorAllocation: BigUInt { MomentsConstants.supply * BigUInt(creatorAllocBps) / BigUInt(MomentsConstants.bps) }
    public var key: MomentKey { MomentKey(factory: factory, id: id) }
}

/// `MomentCollect.Ledger`: the live money state of a Moment.
public struct MomentLedger: Sendable, Hashable, Codable {
    public let state: MomentState
    public let completedAt: Int
    public let stuckSince: Int
    public let endedAt: Int
    public let reserve: BigUInt
    public let creatorClaimable: BigUInt
    public let platformClaimable: BigUInt
    public let treasuryClaimable: BigUInt
    public let totalGross: BigUInt
    public let collects: Int

    public init(state: MomentState, completedAt: Int, stuckSince: Int, endedAt: Int, reserve: BigUInt, creatorClaimable: BigUInt, platformClaimable: BigUInt, treasuryClaimable: BigUInt, totalGross: BigUInt, collects: Int) {
        self.state = state
        self.completedAt = completedAt
        self.stuckSince = stuckSince
        self.endedAt = endedAt
        self.reserve = reserve
        self.creatorClaimable = creatorClaimable
        self.platformClaimable = platformClaimable
        self.treasuryClaimable = treasuryClaimable
        self.totalGross = totalGross
        self.collects = collects
    }
}

/// A graduated Moment's pool: the locked v4 position, its live price and the hook fees waiting to be pulled.
public struct MomentPool: Sendable, Hashable, Codable {
    public let key: PoolKey
    public let poolId: Data
    public let usdcIs0: Bool
    public let sqrtPriceX96: BigUInt
    public let openingSqrtPriceX96: BigUInt
    public let liquidity: BigUInt
    public let seedLiquidity: BigUInt
    public let reserveSeed: BigUInt
    public let poolCoins: BigUInt
    public let graduatedAt: Int
    /// Whole USDC per whole coin at the live price: at the opening price when the live one couldn't be read
    /// (`livePriceRead` false).
    public let usdcPerCoin: Double
    /// Whether `sqrtPriceX96` and `usdcPerCoin` are the pool's live price. False when that read failed and they stand at
    /// the opening price: a value that must be current (a wallet's holdings) is then unknown, not that.
    public let livePriceRead: Bool
    public let creatorFees: BigUInt
    public let platformFees: BigUInt
    public let buybackFees: BigUInt
    public let buybackCarry: BigUInt
    public let lastBuyback: Int
    public let buybackInterval: Int
    public let buybackMin: BigUInt
    /// v2: USDC the locker holds for this Moment (`heldOf(id, USDC)`). A buyback round adds at most 0.5% of the
    /// position, so the rest waits here for later rounds. Not `available(id, USDC)`: that adds the locker's untracked
    /// USDC, which every Moment shares and the next add on any Moment takes. Nil on v1, whose locker has no per-Moment
    /// balance.
    public let heldForLaterRounds: BigUInt?

    public init(key: PoolKey, poolId: Data, usdcIs0: Bool, sqrtPriceX96: BigUInt, openingSqrtPriceX96: BigUInt, liquidity: BigUInt, seedLiquidity: BigUInt, reserveSeed: BigUInt, poolCoins: BigUInt, graduatedAt: Int, usdcPerCoin: Double, creatorFees: BigUInt, platformFees: BigUInt, buybackFees: BigUInt, buybackCarry: BigUInt, lastBuyback: Int, buybackInterval: Int, buybackMin: BigUInt, heldForLaterRounds: BigUInt? = nil, livePriceRead: Bool = true) {
        self.key = key
        self.poolId = poolId
        self.usdcIs0 = usdcIs0
        self.sqrtPriceX96 = sqrtPriceX96
        self.openingSqrtPriceX96 = openingSqrtPriceX96
        self.liquidity = liquidity
        self.seedLiquidity = seedLiquidity
        self.reserveSeed = reserveSeed
        self.poolCoins = poolCoins
        self.graduatedAt = graduatedAt
        self.usdcPerCoin = usdcPerCoin
        self.livePriceRead = livePriceRead
        self.creatorFees = creatorFees
        self.platformFees = platformFees
        self.buybackFees = buybackFees
        self.buybackCarry = buybackCarry
        self.lastBuyback = lastBuyback
        self.buybackInterval = buybackInterval
        self.buybackMin = buybackMin
        self.heldForLaterRounds = heldForLaterRounds
    }

    /// Fully diluted value in USD at the live price (the whole 100M supply).
    public var fdvUSD: Double { usdcPerCoin * 1e8 }
    /// Price change since the pool opened, in percent.
    public var changeSinceOpen: Double? {
        let opening = MomentsMath.usdcPerCoin(sqrtPriceX96: openingSqrtPriceX96, usdcIs0: usdcIs0)
        guard opening > 0 else { return nil }
        return (usdcPerCoin / opening - 1) * 100
    }
    /// USDC the buyback can spend on its next round (accrued + carried), and whether a round can run now.
    public var buybackBudget: BigUInt { buybackFees + buybackCarry }
    public func buybackReady(at now: Int) -> Bool { buybackBudget >= buybackMin && now >= lastBuyback + buybackInterval }
}

/// A Moment as the board and the detail page show it. Codable, so the screens that list it can keep what they last showed
/// (`SavedScreens`); its media is still checked against `provenance.mediaHash` wherever it loads.
public struct MomentInfo: Sendable, Hashable, Codable, Identifiable {
    public let moment: Moment
    public let name: String
    public let symbol: String
    public let provenance: MomentProvenance
    public let ledger: MomentLedger
    /// Editions minted so far (the NFT's `totalMinted`).
    public let editions: Int
    public let closed: Bool
    /// Σ coin entitlements promised to collectors.
    public let entitlements: BigUInt
    public let graduated: Bool
    /// Reserve progress toward the threshold, 10 000 = graduated.
    public let progressBps: Int
    public let pool: MomentPool?

    public var id: BigUInt { moment.id }
    /// (factory, id): the identity to key on whenever Moments of more than one cohort meet.
    public var key: MomentKey { moment.key }
    public var state: MomentState { ledger.state }

    public init(moment: Moment, name: String, symbol: String, provenance: MomentProvenance, ledger: MomentLedger, editions: Int, closed: Bool, entitlements: BigUInt, graduated: Bool, progressBps: Int, pool: MomentPool?) {
        self.moment = moment
        self.name = name
        self.symbol = symbol
        self.provenance = provenance
        self.ledger = ledger
        self.editions = editions
        self.closed = closed
        self.entitlements = entitlements
        self.graduated = graduated
        self.progressBps = progressBps
        self.pool = pool
    }

    /// Whether a collect would be accepted right now (state and deadline), before the terminal clamp.
    public func isCollecting(at now: Int) -> Bool { ledger.state == .collecting && now < moment.deadline }
    /// Its coin has no market yet: the Moment is still collecting, or waiting to graduate, so there is no pool to price
    /// it from (`DyorListing.Venue.collecting`). A screen says "Not trading yet" in place of a price or a value. False
    /// once it graduated, and for one that expired, whose coin will never trade.
    public var isNotTradingYet: Bool { !graduated && ledger.state != .expired && ledger.state != .graduated }
    /// Seconds until the collect window closes (0 once closed).
    public func secondsLeft(at now: Int) -> Int { max(0, moment.deadline - now) }
    /// Whether anyone may call `expire` now: collecting past the deadline, or stuck in graduation for the grace period.
    public func isExpirable(at now: Int) -> Bool {
        switch ledger.state {
        case .collecting: return now >= moment.deadline
        case .graduationPending: return now >= moment.deadline && ledger.stuckSince > 0 && now >= ledger.stuckSince + MomentsConstants.stuckGraceSeconds
        default: return false
        }
    }
    /// Whether its coins can never vest: it expired, or it is still collecting past its deadline (collects are refused
    /// from then on, so it cannot reach its threshold, and only `expire` is left). A stuck graduation is not: a retry may
    /// still land it.
    public func missedGraduation(at now: Int) -> Bool {
        !graduated && (ledger.state == .expired || (ledger.state == .collecting && now >= moment.deadline))
    }
    /// Whether a permissionless graduation retry makes sense.
    public var isRetriable: Bool { ledger.state == .graduationPending }
    /// USDC still needed in the reserve to graduate (0 once reached).
    public var reserveRemaining: BigUInt { ledger.reserve >= moment.threshold ? 0 : moment.threshold - ledger.reserve }
    /// How many more single-edition collects at the current price would fill the reserve (upper bound).
    public var collectsToGraduate: Int {
        guard reserveRemaining > 0, moment.price > 0, moment.reserveBps > 0 else { return 0 }
        let reservePerCollect = moment.price * BigUInt(moment.reserveBps) / BigUInt(MomentsConstants.bps)
        guard reservePerCollect > 0 else { return 0 }
        let n = (reserveRemaining + reservePerCollect - 1) / reservePerCollect
        return Int(clamping: n)
    }
    /// The coin as a swap-able token, its logo the Moment's picture as `ImageSourcePolicy.dyorhq` allows it: DyorHQ's
    /// bucket as it is, or IPFS on DyorHQ's own gateway — never the creator's host (pick 6), which a stored snapshot of
    /// this token would otherwise keep and a screen load. Nil when the picture is anywhere else.
    public var coinToken: Token { coinToken(policy: .dyorhq) }

    /// `coinToken`, its logo as `policy` allows it (a build pointed at another Supabase project).
    public func coinToken(policy: ImageSourcePolicy) -> Token {
        Token(address: moment.coin, symbol: symbol, name: name, decimals: MomentsConstants.coinDecimals, logoURL: policy.creatorSources(provenance.mediaURI).first)
    }
}

/// The detail page's extras: the supply identity and the coin's minted total.
public struct MomentDetail: Sendable, Hashable, Identifiable {
    public struct Supply: Sendable, Hashable {
        public let entitlements: BigUInt
        public let creatorAlloc: BigUInt
        public let remainderPool: BigUInt
        public let impliedPool: BigUInt
        public let collects: Int
        public init(entitlements: BigUInt, creatorAlloc: BigUInt, remainderPool: BigUInt, impliedPool: BigUInt, collects: Int) {
            self.entitlements = entitlements
            self.creatorAlloc = creatorAlloc
            self.remainderPool = remainderPool
            self.impliedPool = impliedPool
            self.collects = collects
        }
    }

    public let info: MomentInfo
    public let supply: Supply
    public let coinTotalSupply: BigUInt
    public let externalURL: String
    public var id: BigUInt { info.id }

    public init(info: MomentInfo, supply: Supply, coinTotalSupply: BigUInt, externalURL: String) {
        self.info = info
        self.supply = supply
        self.coinTotalSupply = coinTotalSupply
        self.externalURL = externalURL
    }
}

/// `MomentCollect.Quote`: exactly what a collect would settle.
public struct CollectQuote: Sendable, Hashable {
    /// USDC accepted (after the terminal clamp); this is all that is ever pulled.
    public let gross: BigUInt
    public let editions: BigUInt
    public let entitlement: BigUInt
    public let reserveIn: BigUInt
    public let creatorIn: BigUInt
    public let platformIn: BigUInt
    /// USDC of the request that is NOT pulled (terminal clamp only) — never a transfer.
    public let excess: BigUInt
    /// This collect completes the Moment and triggers graduation.
    public let terminal: Bool

    public init(gross: BigUInt, editions: BigUInt, entitlement: BigUInt, reserveIn: BigUInt, creatorIn: BigUInt, platformIn: BigUInt, excess: BigUInt, terminal: Bool) {
        self.gross = gross
        self.editions = editions
        self.entitlement = entitlement
        self.reserveIn = reserveIn
        self.creatorIn = creatorIn
        self.platformIn = platformIn
        self.excess = excess
        self.terminal = terminal
    }
}

/// Everything about one account's stake in one Moment.
public struct MomentAccountView: Sendable, Hashable {
    public let usdcBalance: BigUInt
    public let monBalance: BigUInt
    /// USDC → Permit2 allowance (the one-time approval behind signature collects).
    public let permit2Allowance: BigUInt
    /// USDC → collect contract allowance (the plain-approval path).
    public let collectAllowance: BigUInt
    public let entitlement: BigUInt
    public let claimed: BigUInt
    public let claimableCollector: BigUInt
    public let claimableCreator: BigUInt
    public let coinBalance: BigUInt
    public let nftBalance: Int
    public let nftIds: [BigUInt]
    /// Collect-time creator share still to pull (non-zero only for the creator).
    public let creatorProceeds: BigUInt
    /// Hook fees still to pull (non-zero only for the creator).
    public let creatorFees: BigUInt
    public let platformProceeds: BigUInt
    public let platformFees: BigUInt
    public let treasuryProceeds: BigUInt

    public init(usdcBalance: BigUInt, monBalance: BigUInt, permit2Allowance: BigUInt, collectAllowance: BigUInt, entitlement: BigUInt, claimed: BigUInt, claimableCollector: BigUInt, claimableCreator: BigUInt, coinBalance: BigUInt, nftBalance: Int, nftIds: [BigUInt], creatorProceeds: BigUInt, creatorFees: BigUInt, platformProceeds: BigUInt, platformFees: BigUInt, treasuryProceeds: BigUInt) {
        self.usdcBalance = usdcBalance
        self.monBalance = monBalance
        self.permit2Allowance = permit2Allowance
        self.collectAllowance = collectAllowance
        self.entitlement = entitlement
        self.claimed = claimed
        self.claimableCollector = claimableCollector
        self.claimableCreator = claimableCreator
        self.coinBalance = coinBalance
        self.nftBalance = nftBalance
        self.nftIds = nftIds
        self.creatorProceeds = creatorProceeds
        self.creatorFees = creatorFees
        self.platformProceeds = platformProceeds
        self.platformFees = platformFees
        self.treasuryProceeds = treasuryProceeds
    }

    public var claimable: BigUInt { claimableCollector + claimableCreator }
}

/// One Moment the account has a stake in.
public struct MomentPortfolioRow: Sendable, Hashable, Codable, Identifiable {
    public let moment: MomentInfo
    /// Everything this account will be able to claim in total: its collects plus, for the creator, the allocation.
    public let entitlement: BigUInt
    public let claimed: BigUInt
    public let claimableCollector: BigUInt
    public let claimableCreator: BigUInt
    public let nftBalance: Int
    public let coinBalance: BigUInt
    public let isCreator: Bool
    public var id: BigUInt { moment.id }
    public var claimable: BigUInt { claimableCollector + claimableCreator }
    /// Still locked behind the monthly cliffs (only meaningful once graduated).
    public var vesting: BigUInt {
        let out = claimed + claimable
        return entitlement > out ? entitlement - out : 0
    }

    public init(moment: MomentInfo, entitlement: BigUInt, claimed: BigUInt, claimableCollector: BigUInt, claimableCreator: BigUInt, nftBalance: Int, coinBalance: BigUInt, isCreator: Bool) {
        self.moment = moment
        self.entitlement = entitlement
        self.claimed = claimed
        self.claimableCollector = claimableCollector
        self.claimableCreator = claimableCreator
        self.nftBalance = nftBalance
        self.coinBalance = coinBalance
        self.isCreator = isCreator
    }
}

/// Every Moment the account has a stake in, with the coin totals: pending (not graduated), claimable now, still
/// vesting, claimed.
public struct MomentPortfolio: Sendable, Hashable {
    public let rows: [MomentPortfolioRow]
    public let pending: BigUInt
    public let claimable: BigUInt
    public let vesting: BigUInt
    public let claimed: BigUInt

    public init(rows: [MomentPortfolioRow], pending: BigUInt, claimable: BigUInt, vesting: BigUInt, claimed: BigUInt) {
        self.rows = rows
        self.pending = pending
        self.claimable = claimable
        self.vesting = vesting
        self.claimed = claimed
    }

    public static let empty = MomentPortfolio(rows: [], pending: 0, claimable: 0, vesting: 0, claimed: 0)
    /// Ids of graduated Moments with something claimable, for `claimAll`.
    public var claimableIds: [BigUInt] { rows.filter { $0.moment.graduated && $0.claimable > 0 }.map(\.id) }
}

/// What `publish` needs. Amounts are raw: `price` in USDC units, `collectWindow` in seconds.
public struct MomentPublishInput: Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var mediaURI: String
    public var mediaHash: Data
    public var animationURI: String
    public var place: String
    public var date: Int
    public var price: BigUInt
    public var creatorAllocBps: Int
    public var collectWindow: Int

    public init(name: String, symbol: String, mediaURI: String, mediaHash: Data, animationURI: String = "", place: String, date: Int, price: BigUInt, creatorAllocBps: Int, collectWindow: Int) {
        self.name = name
        self.symbol = symbol
        self.mediaURI = mediaURI
        self.mediaHash = mediaHash
        self.animationURI = animationURI
        self.place = place
        self.date = date
        self.price = price
        self.creatorAllocBps = creatorAllocBps
        self.collectWindow = collectWindow
    }
}

/// The `Published` event of a publish transaction.
public struct MomentPublishResult: Sendable, Hashable {
    public let momentId: BigUInt
    public let creator: Address
    public let coin: Address
    public let nft: Address
    public init(momentId: BigUInt, creator: Address, coin: Address, nft: Address) {
        self.momentId = momentId
        self.creator = creator
        self.coin = coin
        self.nft = nft
    }
}

/// Holder statistics for a Moment coin, rebuilt from `Transfer` logs (there is no indexer). Protocol addresses
/// (the pool, the locker, vesting…) are reported apart from wallets.
public struct MomentHolderStats: Sendable, Hashable {
    /// Wallets with a non-zero balance (protocol addresses excluded): their number when `complete`, else a minimum.
    public let holders: Int
    public let topHolder: Address?
    /// Share of the circulating supply held by the largest wallet.
    public let topHolderBps: Int
    /// Whole coins outside the protocol addresses.
    public let circulatingCoins: Double
    /// Share of the minted supply sitting in the pool.
    public let poolBps: Int
    public let mintedCoins: Double
    public let scannedTo: UInt64
    /// Every transfer from before the publish to `scannedTo` was read. False: the read stopped short of the publish
    /// (`MomentsService.holderStats` reads newest first), so `holders` is a minimum — every wallet counted holds coins, as
    /// its transfers since where the read stopped leave it more in than out — and the rest (the top wallet and its share,
    /// the circulating and minted coins, the pool's share) are of the transfers read only, which no screen shows.
    public let complete: Bool

    public init(holders: Int, topHolder: Address?, topHolderBps: Int, circulatingCoins: Double, poolBps: Int, mintedCoins: Double, scannedTo: UInt64, complete: Bool = true) {
        self.holders = holders
        self.topHolder = topHolder
        self.topHolderBps = topHolderBps
        self.circulatingCoins = circulatingCoins
        self.poolBps = poolBps
        self.mintedCoins = mintedCoins
        self.scannedTo = scannedTo
        self.complete = complete
    }
}

/// A Moment's edition holders (`MomentsService.editionHolders`): the wallets holding its editions, from each edition's
/// owner as read.
public struct MomentEditionHolders: Sendable, Hashable {
    /// Distinct wallets holding an edition: their number when `complete`, else a minimum.
    public let holders: Int
    /// The wallet holding the most editions (of equal counts, the lowest address, so two reads name the same one), and
    /// how many it holds.
    public let topHolder: Address?
    public let topCount: Int
    /// Every edition's owner was read. False: the Moment has more editions than one read counts
    /// (`MomentsService.maxEditionsRead`), so `holders` is a minimum and the largest holder is of the editions read only,
    /// which the page doesn't show.
    public let complete: Bool

    /// From each edition's owner, as read (`owners`, one per edition).
    public init(owners: [Address], complete: Bool) {
        var counts: [Address: Int] = [:]
        for owner in owners { counts[owner, default: 0] += 1 }
        let top = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key.hex > b.key.hex }
        holders = counts.count
        topHolder = top?.key
        topCount = top?.value ?? 0
        self.complete = complete
    }
}

// MARK: - Account history (portfolio)

/// One collect the wallet made (`Collected`), with the exact USDC split the contract booked.
public struct MomentCollectRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let collector: Address
    public let gross: BigUInt
    public let editions: Int
    public let firstRank: Int
    public let entitlement: BigUInt
    public let reserveIn: BigUInt
    public let creatorIn: BigUInt
    public let platformIn: BigUInt
    /// The cohort's factory: `momentId` alone is ambiguous across cohorts.
    public let factory: Address
    public var id: String { "\(hash.hexString)-\(factory.hex)-\(momentId)-\(firstRank)" }
    public var key: MomentKey { MomentKey(factory: factory, id: momentId) }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, collector: Address, gross: BigUInt, editions: Int, firstRank: Int, entitlement: BigUInt, reserveIn: BigUInt, creatorIn: BigUInt, platformIn: BigUInt, factory: Address = .zero) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.collector = collector
        self.gross = gross
        self.editions = editions
        self.firstRank = firstRank
        self.entitlement = entitlement
        self.reserveIn = reserveIn
        self.creatorIn = creatorIn
        self.platformIn = platformIn
        self.factory = factory
    }
}

/// A vesting claim the wallet made (`Claimed`): coins minted to it.
public struct MomentClaimRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let collectorAmount: BigUInt
    public let creatorAmount: BigUInt
    public let factory: Address
    public var id: String { "\(hash.hexString)-\(factory.hex)-\(momentId)-claim" }
    public var key: MomentKey { MomentKey(factory: factory, id: momentId) }
    public var total: BigUInt { collectorAmount + creatorAmount }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, collectorAmount: BigUInt, creatorAmount: BigUInt, factory: Address = .zero) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.collectorAmount = collectorAmount
        self.creatorAmount = creatorAmount
        self.factory = factory
    }
}

/// USDC the wallet pulled out: collect-time proceeds (`Withdrawn`) or pool fees (`FeesWithdrawn`).
public struct MomentWithdrawalRecord: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case proceeds, poolFees }
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let kind: Kind
    public let amount: BigUInt
    public let factory: Address
    public var id: String { "\(hash.hexString)-\(factory.hex)-\(momentId)-\(kind)" }
    public var key: MomentKey { MomentKey(factory: factory, id: momentId) }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, kind: Kind, amount: BigUInt, factory: Address = .zero) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.kind = kind
        self.amount = amount
        self.factory = factory
    }
}

/// A Moment the wallet published (`Published`).
public struct MomentPublishRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let coin: Address
    public let factory: Address
    public var id: String { "\(hash.hexString)-\(factory.hex)-publish-\(momentId)" }
    public var key: MomentKey { MomentKey(factory: factory, id: momentId) }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, coin: Address, factory: Address = .zero) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.coin = coin
        self.factory = factory
    }
}

/// Everything a wallet did on Moments (collects, claims, withdrawals, publishes), for the portfolio.
public struct MomentsAccountHistory: Sendable, Hashable {
    public let collects: [MomentCollectRecord]
    public let claims: [MomentClaimRecord]
    public let withdrawals: [MomentWithdrawalRecord]
    public let publishes: [MomentPublishRecord]

    public init(collects: [MomentCollectRecord], claims: [MomentClaimRecord], withdrawals: [MomentWithdrawalRecord], publishes: [MomentPublishRecord]) {
        self.collects = collects
        self.claims = claims
        self.withdrawals = withdrawals
        self.publishes = publishes
    }

    public static let empty = MomentsAccountHistory(collects: [], claims: [], withdrawals: [], publishes: [])

    /// Several cohorts' histories as one, newest first. Every record keeps its factory, so equal Moment ids from
    /// different cohorts stay apart — look Moments up by `key`, never by `momentId`.
    public static func merged(_ histories: [MomentsAccountHistory]) -> MomentsAccountHistory {
        MomentsAccountHistory(
            collects: histories.flatMap(\.collects).sorted { $0.block > $1.block },
            claims: histories.flatMap(\.claims).sorted { $0.block > $1.block },
            withdrawals: histories.flatMap(\.withdrawals).sorted { $0.block > $1.block },
            publishes: histories.flatMap(\.publishes).sorted { $0.block > $1.block }
        )
    }
}

// MARK: - Time on screen

/* What the Moments screens show that changes with the time alone (speed work, build 23). Until build 22 the board and a
   Moment's page each kept a clock ticking every second and drew their whole screen again on every tick — every card,
   every section and some fifteen formatters — to move a countdown that changes once a minute. Now a countdown is drawn
   again alone, at the instants its text changes (`MomentCountdown`), and a screen as a whole only when one of the values
   below changes (`Clock.run(showing:)` in the app). */

/// When a Moment's countdown ("2d 3h left", "45m left", "1m left", then closed) reads differently. It shows the whole
/// minutes left (at least one) in the largest units that fit, so its text is a function of `shownMinutes` alone.
public enum MomentCountdown {
    /// The whole minutes the countdown shows `secondsLeft` before the deadline: at least 1 while open, 0 once closed.
    public static func shownMinutes(secondsLeft: Int) -> Int {
        secondsLeft > 0 ? max(1, secondsLeft / 60) : 0
    }

    /// The first second after `now` at which the countdown to `deadline` reads differently (`shownMinutes` changes), the
    /// deadline itself last; nil once it has passed.
    public static func nextChange(after now: Int, deadline: Int) -> Int? {
        let left = deadline - now
        guard left > 0 else { return nil }
        let minutes = left / 60
        return minutes >= 2 ? deadline - 60 * minutes + 1 : deadline
    }
}

/// What the board shows that changes with the time alone: which Moments are still collecting (the Collecting filter),
/// and whether the queued terms lapsed (the header's notice). The board is drawn again when it changes.
public struct MomentBoardTimes: Hashable, Sendable {
    public let collecting: [Bool]
    public let pendingLapsed: Bool

    public init(moments: [MomentInfo], policy: MomentPolicy?, at now: Int) {
        collecting = moments.map { $0.isCollecting(at: now) }
        pendingLapsed = policy?.pending?.hasLapsed(at: Date(timeIntervalSince1970: TimeInterval(now))) ?? false
    }
}

/// What a Moment's page (live or past cohort) shows that changes with the time alone: whether it is collecting and its
/// window open (the collect ticket, the progress rows), whether it can be expired, whether it missed graduation, the
/// vested shares (at the monthly cliffs) and whether a buyback can run. The page is drawn again when one changes; its
/// badge's countdown moves on its own (`MomentCountdown`).
public struct MomentPageTimes: Hashable, Sendable {
    public let collecting: Bool
    public let windowOpen: Bool
    public let expirable: Bool
    public let missedGraduation: Bool
    public let collectorVestedBps: Int
    public let creatorVestedBps: Int
    public let buybackReady: Bool

    public init(_ info: MomentInfo, at now: Int) {
        collecting = info.isCollecting(at: now)
        windowOpen = now < info.moment.deadline
        expirable = info.isExpirable(at: now)
        missedGraduation = info.missedGraduation(at: now)
        let graduatedAt = info.pool?.graduatedAt ?? 0
        collectorVestedBps = MomentsMath.collectorVestedBps(graduatedAt: graduatedAt, now: now)
        creatorVestedBps = MomentsMath.creatorVestedBps(graduatedAt: graduatedAt, now: now)
        buybackReady = info.pool?.buybackReady(at: now) ?? false
    }
}

// MARK: - Math

/// The derivations the contracts and the web app share; kept pure so they are unit-testable.
public enum MomentsMath {
    /// `MomentsFactory.bundleRate`: coin wei per USDC unit as an exact fraction.
    public static func bundleRate(threshold: BigUInt, reserveBps: Int, creatorAllocBps: Int) -> (num: BigUInt, den: BigUInt) {
        let bps = BigUInt(MomentsConstants.bps)
        let num = MomentsConstants.supply * (bps - BigUInt(creatorAllocBps)) * BigUInt(reserveBps)
        let den = bps * threshold * (bps + BigUInt(reserveBps))
        return (num, den)
    }

    /// Coin wei owed for `gross` USDC units at a Moment's rate (floor, like `Math.mulDiv`).
    public static func entitlement(gross: BigUInt, rateNum: BigUInt, rateDen: BigUInt) -> BigUInt {
        guard rateDen > 0 else { return 0 }
        return gross * rateNum / rateDen
    }

    /// Whole USDC per whole coin from a v4 sqrt price (USDC 6 dp, coin 18 dp).
    public static func usdcPerCoin(sqrtPriceX96: BigUInt, usdcIs0: Bool) -> Double {
        let sp = Double(sqrtPriceX96) / pow(2, 96)
        let ratio = sp * sp // currency1 units per currency0 unit
        guard ratio > 0 else { return 0 }
        return usdcIs0 ? 1e12 / ratio : ratio * 1e12
    }

    /// Vested share of a collector's entitlement, in bps: 6000 at graduation, 8000 after month 1, 10000 after month 2.
    public static func collectorVestedBps(graduatedAt: Int, now: Int) -> Int {
        guard graduatedAt > 0, now >= graduatedAt else { return 0 }
        let months = (now - graduatedAt) / MomentsConstants.monthSeconds
        if months == 0 { return 6_000 }
        if months == 1 { return 8_000 }
        return MomentsConstants.bps
    }

    /// Vested share of the creator allocation, in bps: 2000 at graduation, +1600 per month, 10000 at month 5.
    public static func creatorVestedBps(graduatedAt: Int, now: Int) -> Int {
        guard graduatedAt > 0, now >= graduatedAt else { return 0 }
        let months = min(5, (now - graduatedAt) / MomentsConstants.monthSeconds)
        return 2_000 + 1_600 * months
    }

    /// Progress toward graduation in bps (10 000 once graduated or pending).
    public static func progressBps(reserve: BigUInt, threshold: BigUInt, state: MomentState) -> Int {
        if state == .graduated || state == .graduationPending { return MomentsConstants.bps }
        guard threshold > 0 else { return 0 }
        return Int(clamping: reserve * BigUInt(MomentsConstants.bps) / threshold)
    }

    /// The coin's fully diluted value when it graduates, in USD. The pool opens at the collect price (price
    /// continuity), so FDV = threshold · (1 + 1/reserveFrac) / (1 − creatorAlloc): a $771.43 reserve at a 75% reserve
    /// share and the default 10% creator allocation opens at $2,000; an allocation the creator leaves untaken goes
    /// to the pool at the same rate instead, which lowers the FDV (to $1,800 at 0%).
    public static func graduationFDV(threshold: BigUInt, reserveBps: Int, creatorAllocBps: Int) -> Double {
        guard reserveBps > 0, creatorAllocBps < MomentsConstants.bps else { return 0 }
        let reserve = Amount.units(threshold, decimals: MomentsConstants.usdcDecimals)
        return reserve * Double(MomentsConstants.bps + reserveBps) / Double(reserveBps) * Double(MomentsConstants.bps) / Double(MomentsConstants.bps - creatorAllocBps)
    }

    /// The highest collect price that is ever charged: the gross that completes the reserve, ceil(threshold · 10 000 /
    /// reserveBps). The first collect at or above it graduates the Moment and is charged only this (`MomentCollect`
    /// clamps it), so a higher listed price is never paid; the v2 factory refuses one (`PriceTooHigh`). Nil when
    /// `reserveBps` is not positive.
    public static func maxCollectPrice(threshold: BigUInt, reserveBps: Int) -> BigUInt? {
        guard reserveBps > 0 else { return nil }
        let r = BigUInt(reserveBps)
        return (threshold * BigUInt(MomentsConstants.bps) + r - 1) / r
    }

    /// Whole coins as a display number.
    public static func coins(_ wei: BigUInt) -> Double { Amount.units(wei, decimals: MomentsConstants.coinDecimals) }
    /// Whole USDC as a display number.
    public static func usdc(_ units: BigUInt) -> Double { Amount.units(units, decimals: MomentsConstants.usdcDecimals) }

    /// IPFS gateways in the order the app tries them: DyorHQ's dedicated Pinata gateway first (every Moment pin lives
    /// on Pinata, so it serves a fresh CID within a second and is not throttled like the public gateways), then
    /// Pinata's public gateway, then the general public gateways — which rate-limit aggressively (ipfs.io and
    /// dweb.link answer 429 under modest load), so they are last resorts, never the only path.
    public static let ipfsGateways = [
        "https://scarlet-secure-kangaroo-820.mypinata.cloud/ipfs/",
        "https://gateway.pinata.cloud/ipfs/",
        "https://ipfs.io/ipfs/",
        "https://dweb.link/ipfs/",
    ]

    /// A media link the app can load: `ipfs://` is rewritten to the primary gateway; `https://` passes through.
    public static func url(_ uri: String) -> URL? { gatewayURLs(uri).first }

    /// Every URL worth trying for a media link, in order: an `ipfs://` URI through each of `ipfsGateways` (a path
    /// after the CID, e.g. `ipfs://<cid>/photo.jpg`, is kept); an https link is just itself. Empty for anything else.
    public static func gatewayURLs(_ uri: String) -> [URL] {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.lowercased().hasPrefix("ipfs://"), let path = IPFS.path(trimmed) {
            return ipfsGateways.compactMap { URL(string: $0 + path) }
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return [] }
        return [url]
    }

    /// The bucket object name for Moment media, derived from the keccak-256 of the bytes (`moment-<64 hex>`), so the
    /// public mirror of a Moment's image can be found again from its on-chain provenance alone — see `mirrorURL`.
    public static func mediaName(hash: Data) -> String { "moment-" + hash.map { String(format: "%02x", $0) }.joined() }

    /// The longest side, in pixels, a new Moment photo is encoded at (as JPEG, at `photoJPEGQuality`) before anything
    /// else happens to it: those bytes are its provenance file — their keccak-256 is the on-chain media hash, names the
    /// mirror (`mediaName`) and is what gets pinned. A phone photo comes to about 0.4–0.9 MB and still covers a 3× phone's
    /// full width; 4096 px at 0.92 made files of up to 4.8 MB, which every viewer downloads whole to check the hash, and
    /// over the 2 MB a coin's logo may be (`RemoteMedia.caps`). The size of a video's poster frame. A Moment already
    /// published keeps the file its hash names.
    public static let photoMaxPixels = 2048
    /// The JPEG quality of a new Moment photo (`photoMaxPixels`).
    public static let photoJPEGQuality = 0.85

    /// The Supabase public mirror of a Moment's image, derivable from on-chain data alone: the creator's folder in the
    /// public `launch-media` bucket holds `moment-<mediaHash>.jpg` (the photo, or a video's poster frame — both are
    /// named after the provenance hash at upload). Nil unless the hash is a keccak-256 digest. The mirror is the
    /// app's first choice for display because it is infrastructure DyorHQ controls; the IPFS gateways come after.
    public static func mirrorURL(creator: Address, mediaHash: Data, supabaseURL: URL) -> URL? {
        guard mediaHash.count == 32 else { return nil }
        return supabaseURL.appending(path: "storage/v1/object/public/launch-media/\(creator.hex)/\(mediaName(hash: mediaHash)).jpg")
    }
}
