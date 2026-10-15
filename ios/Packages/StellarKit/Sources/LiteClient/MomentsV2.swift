import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

// Moments v2 (docs/DESIGN-stellar-contracts-v2.md §9, §14.2–14.3, §20.2–20.3; the API's _shared/moments_v2.ts): one
// Moment is one NFT contract, and its address is the Moment's id. Collectors pay USDC only; the collect that reaches
// the threshold completes the Moment, the keeper graduates it into its coin and a Soroswap pool, and the coins
// collectors were promised vest from then. Amounts are base units as decimal strings (USDC and the coin: 7 decimals),
// durations seconds, times ISO 8601. v1's Moments (StellarMoment, SEP-50 editions without a coin) stay for the retired
// generation.
//
// The routes, as the API serves them for v2 (CT-18 wires them):
//   GET  /v1/economics               public    the Moments block (StellarEconomicsV2.moments)
//   GET  /v1/moments/:nft/status     public    a Moment's state, read live, with when it may expire
//   GET  /v1/moments/:nft/vesting    viewer    the account's coins in it: the session's, or the viewer's
//   POST /v1/moments/build           session   every v2 action, keyed by the NFT address (MomentRequestV2)
//   POST /v1/moments/metadata        session   as for v1 (LiteAPI.momentMetadata)

/// The economics a Moment published now snapshots (moments-v2 Policy).
public struct StellarMomentsPolicyV2: Codable, Equatable, Sendable {
    /// The reserve that completes a Moment, in USDC.
    public let threshold: String
    public let minPrice: String
    /// Each collect's split: creator, platform and reserve (20/5/75 on testnet).
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let maxCreatorAllocBps: Int
    /// An expired Moment's reserve: the creator's share (the treasury takes the rest).
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let platform: String
    public let treasury: String
}

/// moments-v2's durations, in seconds (dyor_common::MomentsDurations).
public struct StellarMomentsDurationsV2: Codable, Equatable, Sendable {
    public let vestPeriod: Int
    /// After a recorded failed graduation, when the Moment may expire.
    public let stuckExpiry: Int
    /// After completion, when a Moment still pending graduation may expire without a recorded failure (V11).
    public let pendingBackstop: Int
    public let timelock: Int
    public let timelockWindow: Int
    /// The collect window a publish may ask for.
    public let minWindow: Int
    public let maxWindow: Int
    public let harvestInterval: Int

    /// Whether these are the durations the app pins (`PinnedContracts.durations`): the verifier refuses a publish
    /// that binds others.
    public func matches(_ pinned: PinnedDurations.Moments) -> Bool {
        [vestPeriod, stuckExpiry, pendingBackstop, timelock, timelockWindow, minWindow, maxWindow, harvestInterval].map(UInt64.init(clamping:)) == [
            pinned.vestPeriod, pinned.stuckExpiry, pinned.pendingBackstop, pinned.timelock, pinned.timelockWindow, pinned.minWindow,
            pinned.maxWindow, pinned.harvestInterval,
        ]
    }
}

/// The post-graduation harvest as the terms state it (§9.1, §14.4, V3).
public struct StellarMomentsHarvestV2: Codable, Equatable, Sendable {
    public struct QuoteSide: Codable, Equatable, Sendable {
        public let creatorBps: Int
        public let platformBps: Int
    }

    public let intervalSecs: Int
    /// Of each round's fee growth: paid out, and left compounding in the locked position.
    public let harvestedBps: Int
    public let compoundedBps: Int
    /// compounded : harvested ("3,333 : 6,667").
    public let ratio: String
    /// The harvested USDC side, by payee.
    public let quoteSide: QuoteSide
    /// "burned".
    public let coinSide: String
}

/// What a publish binds by value (moments-v2 MomentsTerms).
public struct StellarMomentsTermsV2: Codable, Equatable, Sendable {
    public let policy: StellarMomentsPolicyV2
    /// An NFT's external URL is this followed by its address.
    public let externalBase: String
    /// Hex.
    public let nftWasmHash: String
    public let coinWasmHash: String
    public let graduator: String
    public let executor: String
    public let locker: String
    public let durations: StellarMomentsDurationsV2
    public let harvestBps: Int
    public let harvestCreatorBps: Int
    /// Not a field of the contract's terms: the harvest constants, stated for the phone.
    public let harvest: StellarMomentsHarvestV2
}

/// The Moments block of `GET /v1/economics` for v2 (§20.2): the main stack's only, read live. Governance and the
/// guardian are never served.
public struct StellarMomentsEconomicsV2: Codable, Equatable, Sendable {
    public struct Quote: Codable, Equatable, Sendable {
        /// "USDC", the only quote of v2 Moments.
        public let asset: String
        public let contract: String
    }

    /// A proposed policy: it applies from `eta` until `expires`; after that it has lapsed, and stays visible until it is
    /// replaced or cancelled.
    public struct PendingPolicy: Codable, Equatable, Sendable {
        public let policy: StellarMomentsPolicyV2
        public let eta: String
        public let expires: String
        /// "waiting", "ready" or "lapsed", when the API answered.
        public let state: String

        /// The state at `now`: a policy is lapsed once `now` is past `expires`, though it stays visible until it is
        /// replaced or cancelled (moments-v2 as built).
        public func state(at now: Date) -> String {
            LiteWindow(from: eta, to: expires).map { $0.state(at: now, before: "waiting", inside: "ready") } ?? state
        }
    }

    /// The FDV at the pool's opening price for one creator allocation.
    public struct Fdv: Codable, Equatable, Sendable {
        public let allocationBps: Int
        public let fdv: String
        public let fdvUsd: Double?
    }

    /// 2.
    public let generation: Int
    public let contract: String
    public let quote: Quote
    /// Every Moment coin's supply.
    public let supply: String
    public let maxPerCollect: Int
    /// The most Moments one "Claim all" covers.
    public let maxClaimIds: Int
    public let policy: StellarMomentsPolicyV2
    public let pendingPolicy: PendingPolicy?
    public let terms: StellarMomentsTermsV2
    public let publishingPaused: Bool
    public let guardianPaused: Bool
    /// The gross that completes a Moment from empty; also the highest price a Moment may ask (`maxPrice`).
    public let completionGross: String
    public let maxPrice: String
    /// The FDV at open with the largest creator allocation the policy allows.
    public let fdvAtOpen: String
    public let fdvAtOpenUsd: Double?
    /// The same for each allocation from 0 in 1% steps: the publish form's choices.
    public let fdvByAllocation: [Fdv]
}

/// A failed graduation (V10): recorded as the indexer saw its grad_fail, or the failure an attempt records now.
public struct StellarMomentFailureV2: Codable, Equatable, Sendable {
    /// The contract's tag (0 for a contract outside DyorHQ, 99 for the host) and its namespaced code.
    public let origin: Int
    public let code: Int
    /// "GraduationInvalid"; nil for a pair the API's table doesn't know.
    public let name: String?
    /// The contract that raised it ("moments-graduator"); nil with `name`.
    public let source: String?
    /// "recorded" or "simulated".
    public let seen: String

    public var recorded: Bool { seen == "recorded" }
}

/// `GET /v1/moments/:nft/status`: a Moment's state, read live, with when it may expire (V11).
public struct StellarMomentStatusV2: Codable, Equatable, Sendable, Identifiable {
    public struct Rate: Codable, Equatable, Sendable {
        /// Coin units per USDC unit a collect promises: num / den.
        public let num: String
        public let den: String
    }

    /// USDC each beneficiary may withdraw now.
    public struct Proceeds: Codable, Equatable, Sendable {
        public let creator: String
        public let platform: String
        public let treasury: String
    }

    /// 2.
    public let generation: Int
    /// The Moment's NFT contract: its id.
    public let nft: String
    public let creator: String
    public let coin: String
    public let pool: String?
    /// "collecting", "graduation_pending", "graduated" or "expired".
    public let state: String
    public let price: String
    public let threshold: String
    public let reserve: String
    public let totalGross: String
    /// How far the Moment got to its threshold, 0 to 1: 1 once it completed, graduated or expired since.
    public let progress: Double
    public let collects: Int
    public let editions: Int
    /// Coins promised to collectors, in coin units.
    public let entitlements: String
    public let creatorAllocBps: Int
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let rate: Rate
    public let publishedAt: String
    public let deadline: String
    public let completedAt: String?
    /// When the first failed graduation was recorded.
    public let stuckSince: String?
    public let graduatedAt: String?
    public let endedAt: String?
    /// When `expire` will take it: a Collecting Moment's deadline; for one pending graduation the later of the deadline
    /// and the earlier of `failureExpiresAt` and `backstopAt`. Nil once Graduated or Expired.
    public let expiresAt: String?
    /// Which clock sets `expiresAt`: "deadline", "failure" or "backstop".
    public let expiresBy: String?
    /// Pending graduation: completion + pendingBackstop (V11).
    public let backstopAt: String?
    /// After a recorded failure: stuckSince + stuckExpiry.
    public let failureExpiresAt: String?
    /// `expire` would take it now.
    public let expirable: Bool
    /// Pending graduation: the keeper usually finishes within a minute, and anyone may call graduate.
    public let graduatable: Bool
    /// With a recorded failure: its origin, code and name.
    public let failure: StellarMomentFailureV2?
    public let proceeds: Proceeds

    public var id: String { nft }
}

/// `GET /v1/moments/:nft/vesting`: an account's coins in one Moment (§9.2), as a collector and, for the creator, its
/// allocation.
public struct StellarMomentVestingV2: Codable, Equatable, Sendable {
    /// From `at` (nil until the Moment graduates), `vestedBps` of the total has vested.
    public struct Tranche: Codable, Equatable, Sendable, Identifiable {
        public let period: Int
        public let at: String?
        public let vestedBps: Int
        public let vested: String
        public var id: Int { period }
    }

    /// One side's schedule: collectors 60/80/100% at 0/1/2 periods, the creator 20% + 16% a period to 100% after 5.
    public struct Side: Codable, Equatable, Sendable {
        public let total: String
        public let claimed: String
        /// What the contract's claimable says can be minted now.
        public let claimable: String
        /// claimed + claimable.
        public let vested: String
        public let tranches: [Tranche]
        /// The next tranche; nil once all have vested, and before graduation.
        public let nextAt: String?
        public let fullAt: String?
    }

    public struct Claimable: Codable, Equatable, Sendable {
        public let collector: String
        public let creator: String
        public let total: String
    }

    /// 2.
    public let generation: Int
    public let nft: String
    public let account: String
    public let coin: String
    public let state: String
    /// False for an expired Moment: its coins never exist.
    public let vests: Bool
    public let vestPeriodSecs: Int
    /// Graduation; nil before it.
    public let startsAt: String?
    public let periodsElapsed: Int?
    public let claimable: Claimable
    /// Nil when the account was promised nothing as a collector, or as the creator.
    public let collector: Side?
    public let creator: Side?
}

extension LiteAPI {
    /// A v2 Moments action (`POST /v1/moments/build`), keyed by the Moment's NFT address.
    public struct MomentRequestV2: Encodable, Sendable {
        public enum Action: String, Encodable, Sendable {
            case publish, collect, claim
            /// Up to `maxClaimIds` Moments at once.
            case claimAll = "claim_all"
            /// The creator's proceeds (anyone may send them).
            case withdraw
            case graduate, expire
        }

        public let action: Action
        /// Publish: the metadata URI `momentMetadata` returned.
        public var uri: String?
        /// Publish: the coin's name (the metadata's title when nil).
        public var name: String?
        /// Publish: refused here unless `StellarTickerV2` takes it.
        public var symbol: String?
        /// Publish: per edition, in USDC base units.
        public var price: String?
        /// Publish: the creator's allocation, 0 to the policy's maximum in 1% steps.
        public var allocationBps: Int?
        /// Publish: the collect window.
        public var windowSecs: Int?
        /// Every action but publish and claim_all.
        public var nft: String?
        /// Collect: 1 to `maxPerCollect`.
        public var quantity: Int?
        /// Claim all.
        public var nfts: [String]?

        public init(
            action: Action, uri: String? = nil, name: String? = nil, symbol: String? = nil, price: String? = nil, allocationBps: Int? = nil,
            windowSecs: Int? = nil, nft: String? = nil, quantity: Int? = nil, nfts: [String]? = nil
        ) {
            self.action = action
            self.uri = uri
            self.name = name
            self.symbol = symbol
            self.price = price
            self.allocationBps = allocationBps
            self.windowSecs = windowSecs
            self.nft = nft
            self.quantity = quantity
            self.nfts = nfts
        }
    }

    /// A v2 Moment's state. Public: it reads nothing about the viewer.
    public func momentStatusV2(_ nft: String) async throws -> StellarMomentStatusV2 {
        try await request("GET", "moments/\(Self.segment(nft))/status", access: .public)
    }

    /// The account's coins in a v2 Moment. A viewer read about the account: the session's, or the viewer's.
    public func momentVestingV2(_ nft: String) async throws -> StellarMomentVestingV2 {
        try await request("GET", "moments/\(Self.segment(nft))/vesting", access: .viewer(aboutAccount: true))
    }

    /// A v2 Moments action's plan. A publish's ticker is refused here as the API refuses it (`StellarTickerV2.refusal`),
    /// before anything is sent, and goes out upper-cased.
    public func buildMomentV2(_ r: MomentRequestV2) async throws -> PlanView {
        var r = r
        if r.action == .publish {
            guard let ticker = r.symbol.flatMap(StellarTickerV2.normalized) else { throw StellarTickerV2.refusal }
            r.symbol = ticker
        }
        return try await request("POST", "moments/build", body: r)
    }
}
