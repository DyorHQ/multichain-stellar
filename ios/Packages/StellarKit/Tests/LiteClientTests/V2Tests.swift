import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LiteClient
import StellarCore
import XCTest

// Contracts v2 on the phone (docs/DESIGN-stellar-contracts-v2.md §20.1–20.3, §18.4): the models of the v2 API decode
// what the API's launchpad_v2.ts and moments_v2.ts answer (V2Fixtures, captured from them), including every state only
// testnet-qa reaches (finding F4); the LiteAPI methods ask for their routes; and PlanRunner signs calls to the
// contracts v2 creates at runtime only when they run a pinned WASM.

/// Every v2 fixture decodes, keeps every field it carries, and reads as its state.
final class V2ModelTests: XCTestCase {
    /// Each fixture read as the client reads it.
    private static let codable: [(String, String, (Data) throws -> Data)] = [
        ("economics", V2Fixtures.economics, roundTrip(StellarEconomicsV2.self)),
        ("launchPreview", V2Fixtures.launchPreview, roundTrip(StellarLaunchPreviewV2.self)),
        ("launchPreviewShort", V2Fixtures.launchPreviewShort, roundTrip(StellarLaunchPreviewV2.self)),
        ("launchStateStuck", V2Fixtures.launchStateStuck, roundTrip(StellarLaunchStateV2.self)),
        ("launchStateVenueLocked", V2Fixtures.launchStateVenueLocked, roundTrip(StellarLaunchStateV2.self)),
        ("launchStateRescued", V2Fixtures.launchStateRescued, roundTrip(StellarLaunchStateV2.self)),
        ("launchStateGraduated", V2Fixtures.launchStateGraduated, roundTrip(StellarLaunchStateV2.self)),
        ("launchQuoteRefund", V2Fixtures.launchQuoteRefund, roundTrip(StellarTradeQuoteV2.self)),
        ("launchQuoteBuy", V2Fixtures.launchQuoteBuy, roundTrip(StellarTradeQuoteV2.self)),
        ("momentStatusCollecting", V2Fixtures.momentStatusCollecting, roundTrip(StellarMomentStatusV2.self)),
        ("momentStatusPending", V2Fixtures.momentStatusPending, roundTrip(StellarMomentStatusV2.self)),
        ("momentStatusFailed", V2Fixtures.momentStatusFailed, roundTrip(StellarMomentStatusV2.self)),
        ("momentStatusGraduated", V2Fixtures.momentStatusGraduated, roundTrip(StellarMomentStatusV2.self)),
        ("momentStatusExpired", V2Fixtures.momentStatusExpired, roundTrip(StellarMomentStatusV2.self)),
        ("momentVesting", V2Fixtures.momentVesting, roundTrip(StellarMomentVestingV2.self)),
        ("momentVestingFull", V2Fixtures.momentVestingFull, roundTrip(StellarMomentVestingV2.self)),
        ("momentPlanPublish", V2Fixtures.momentPlanPublish, roundTrip(PlanView.self)),
        ("momentPlanCollect", V2Fixtures.momentPlanCollect, roundTrip(PlanView.self)),
        ("momentPlanClaimAll", V2Fixtures.momentPlanClaimAll, roundTrip(PlanView.self)),
    ]

    private static func roundTrip<T: Codable>(_ type: T.Type) -> (Data) throws -> Data {
        { data in try JSONEncoder().encode(JSONDecoder().decode(T.self, from: data)) }
    }

    /// An optional whose name is misspelt would decode as nil without a word, so each model is encoded back and its
    /// fields compared with the fixture's.
    func testEveryFixtureDecodesAndKeepsEveryField() throws {
        for (name, json, read) in Self.codable {
            let data = Data(json.utf8)
            let encoded: Data
            do {
                encoded = try read(data)
            } catch {
                XCTFail("\(name) doesn't decode: \(error)")
                continue
            }
            XCTAssertEqual(try V2JSON.dropped(data, encoded), [], "\(name): fields the model drops")
        }
    }

    /// A launch plan is a PlanView, whose intents keep the fields every verifier reads; StellarLaunchPlanV2 keeps what
    /// v2 adds: the terms a create binds, and a recipient change's backlog.
    func testLaunchPlansKeepTheirTermsAndBacklog() throws {
        for json in [V2Fixtures.launchPlanCreate, V2Fixtures.launchPlanRecipient, V2Fixtures.launchPlanRefund] {
            let data = Data(json.utf8)
            let plan = try JSONDecoder().decode(StellarLaunchPlanV2.self, from: data)
            let dropped = try V2JSON.dropped(data, JSONEncoder().encode(plan.plan))
            let v2Only = ["steps[].builtAt", "harvestBacklog", "steps[].intent.terms", "steps[].intent.harvestBacklog"]
            XCTAssertEqual(dropped.filter { path in !v2Only.contains { path == $0 || path.hasPrefix($0 + ".") || path.hasPrefix($0 + "[]") } }, [])
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(try V2JSON.object(plan.harvestBacklog), wire["harvestBacklog"].flatMap { $0 is NSNull ? nil : $0 as? NSDictionary })
            for step in try XCTUnwrap(wire["steps"] as? [[String: Any]]) {
                let intent = step["intent"] as? [String: Any]
                let id = try XCTUnwrap(step["id"] as? String)
                XCTAssertEqual(try V2JSON.object(plan.intents[id]?.terms), intent?["terms"] as? NSDictionary, id)
                XCTAssertEqual(try V2JSON.object(plan.intents[id]?.harvestBacklog), intent?["harvestBacklog"] as? NSDictionary, id)
            }
        }
    }

    /// The states only testnet-qa reaches (F4): the screens' data is tested here though no tester can get to it.
    func testStatesOnlyTestnetQAReaches() throws {
        let lockedFallback = try XCTUnwrap(economics().launchpad?.durations.lockedFallback)
        let fallbackDelay = try XCTUnwrap(economics().launchpad?.durations.fallbackDelay)

        // Stuck, with fallback_at and a named failure (V10): the fallback opens fallbackDelay after stuck_since.
        let stuck = try decode(StellarLaunchStateV2.self, V2Fixtures.launchStateStuck).status
        XCTAssertEqual([stuck.phase, stuck.venue.name], ["completed", "Soroswap"])
        XCTAssertTrue(stuck.stuck)
        XCTAssertEqual(try seconds(stuck.stuckSince, stuck.fallbackAt), fallbackDelay)
        XCTAssertNotNil(stuck.rescueAdminAt)
        XCTAssertNotNil(stuck.rescuePublicAt)
        XCTAssertEqual(stuck.failure, StellarGraduationFailureV2(origin: 3, code: 10_304, name: "LiquidityTooLow", contract: "exec-soroswap", source: "recorded"))
        XCTAssertEqual(stuck.failure?.recorded, true)
        XCTAssertEqual([stuck.actions.graduate, stuck.actions.graduateFallback, stuck.actions.buy, stuck.actions.refund], [true, true, false, false])

        // Venue-locked: the fallback waits lockedFallback, not fallbackDelay; the failure is what graduate fails with now.
        let locked = try decode(StellarLaunchStateV2.self, V2Fixtures.launchStateVenueLocked)
        XCTAssertTrue(locked.status.venueLocked)
        XCTAssertFalse(locked.status.fallbackAllowed)
        XCTAssertEqual([locked.status.venue.kind, locked.status.fallback.kind, locked.quote.id], ["QaFail", "Soroswap", "USDC"])
        XCTAssertEqual(try seconds(locked.status.stuckSince, locked.status.fallbackAt), lockedFallback)
        XCTAssertFalse(locked.status.actions.graduateFallback)
        XCTAssertEqual(locked.status.failure?.name, "ForcedFailure")
        XCTAssertEqual([locked.status.failure?.origin, locked.status.failure?.code], [5, 10_502])
        XCTAssertEqual(locked.status.failure?.recorded, false)
        XCTAssertNil(locked.you, "no viewer")
        XCTAssertNil(locked.rewards.pendingQuote)

        // Rescued: refunds at one fixed rate, no fees, in any order (O2); the quote says the same rate.
        let rescued = try decode(StellarLaunchStateV2.self, V2Fixtures.launchStateRescued).status
        XCTAssertEqual(rescued.phase, "rescued")
        XCTAssertEqual(rescued.refund?.rate, "0.000000048050614666")
        XCTAssertEqual([rescued.actions.refund, rescued.actions.buy, rescued.actions.sell], [true, false, false])
        XCTAssertNil(rescued.failure)
        let refund = try decode(StellarTradeQuoteV2.self, V2Fixtures.launchQuoteRefund)
        XCTAssertEqual([refund.side.rawValue, refund.rate, refund.fees], ["refund", rescued.refund?.rate, "0"])
        XCTAssertNotNil(refund.quoteOut)
        let burn = try decode(PlanView.self, V2Fixtures.launchPlanRefund).steps[0].intent
        XCTAssertEqual(burn?.kind, "launch_refund")
        XCTAssertEqual(burn?.display?["rate"]?.text, rescued.refund?.rate)
        XCTAssertEqual(burn?.spend, [rescued.token: "1000000000000"], "the burned tokens are the outflow")

        // A failed Moment graduation, recorded and named: it expires stuck_expiry after the failure, before the backstop.
        let terms = try XCTUnwrap(economics().moments?.terms.durations)
        let failed = try decode(StellarMomentStatusV2.self, V2Fixtures.momentStatusFailed)
        XCTAssertEqual(failed.state, "graduation_pending")
        XCTAssertEqual(failed.failure, StellarMomentFailureV2(origin: 10, code: 11_003, name: "GraduationInvalid", source: "moments-graduator", seen: "recorded"))
        XCTAssertEqual(failed.failure?.recorded, true)
        XCTAssertEqual(failed.expiresBy, "failure")
        XCTAssertEqual(failed.expiresAt, failed.failureExpiresAt)
        XCTAssertEqual(try seconds(failed.stuckSince, failed.expiresAt), terms.stuckExpiry)
        XCTAssertEqual(try seconds(failed.completedAt, failed.backstopAt), terms.pendingBackstop)
        XCTAssertTrue(failed.graduatable)
        XCTAssertFalse(failed.expirable)

        // Pending with no recorded failure: the backstop date (V11), 30 days after completion.
        let pending = try decode(StellarMomentStatusV2.self, V2Fixtures.momentStatusPending)
        XCTAssertNil(pending.failure)
        XCTAssertNil(pending.stuckSince)
        XCTAssertEqual(pending.expiresBy, "backstop")
        XCTAssertEqual(pending.expiresAt, pending.backstopAt)
        XCTAssertEqual(try seconds(pending.completedAt, pending.backstopAt), terms.pendingBackstop)
        XCTAssertEqual(pending.progress, 1)

        // Full vesting: every tranche past on both sides, nothing left to come.
        let full = try decode(StellarMomentVestingV2.self, V2Fixtures.momentVestingFull)
        for side in [full.collector, full.creator] {
            let side = try XCTUnwrap(side)
            XCTAssertEqual(side.vested, side.total)
            XCTAssertEqual(side.tranches.last?.vestedBps, 10_000)
            XCTAssertNil(side.nextAt)
            XCTAssertEqual(Int64(side.claimed)! + Int64(side.claimable)!, Int64(side.total)!)
        }
        XCTAssertEqual(Int64(full.claimable.collector)! + Int64(full.claimable.creator)!, Int64(full.claimable.total)!)
        XCTAssertEqual(full.collector?.tranches.map(\.vestedBps), [6_000, 8_000, 10_000])
        XCTAssertEqual(full.creator?.tranches.map(\.vestedBps), [2_000, 3_600, 5_200, 6_800, 8_400, 10_000])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(full.periodsElapsed), 5)
        XCTAssertEqual(try seconds(full.startsAt, full.creator?.fullAt), 5 * full.vestPeriodSecs)
    }

    func testLaunchEconomicsPreviewAndPlans() throws {
        let launchpad = try XCTUnwrap(economics().launchpad)
        XCTAssertEqual(launchpad.generation, 2)
        XCTAssertEqual([launchpad.launchFee.asset, launchpad.launchFee.amount], ["XLM", "100000000"])
        XCTAssertTrue(launchpad.launchFee.booked)
        // Soroswap only (O7): no Aquarius venue, no float.
        XCTAssertFalse(launchpad.venues.contains { $0.kind == "Aquarius" })
        XCTAssertNil(launchpad.aquariusFloat)
        XCTAssertEqual([launchpad.durations.fallbackDelay, launchpad.durations.harvestInterval], [3_600, 3_600])
        XCTAssertEqual(launchpad.harvest.sides, ["quote", "token"])
        XCTAssertEqual(launchpad.harvest.holdersPaidIn, ["quote", "token"])
        XCTAssertEqual([launchpad.harvest.split.protocolBps, launchpad.harvest.split.creatorOrHoldersBps], [5_000, 5_000])
        XCTAssertEqual(launchpad.harvest.intervalSecs, launchpad.durations.harvestInterval)
        XCTAssertEqual(launchpad.exclusionFloor.minPendingQuote, "1000000")
        let xlm = try XCTUnwrap(launchpad.quotes.first { $0.asset == "XLM" })
        XCTAssertEqual([xlm.venueLocked, xlm.defaultVenue == 0], [false, true])
        XCTAssertEqual(xlm.terms?.launchFee, launchpad.launchFee.amount)
        XCTAssertEqual(xlm.terms?.durations, launchpad.durations)
        let usdc = try XCTUnwrap(launchpad.quotes.first { $0.asset == "USDC" })
        XCTAssertTrue(usdc.venueLocked)
        XCTAssertEqual(usdc.venuesAllowed, [2])
        XCTAssertEqual(usdc.terms?.venue.kind, "QaFail")
        XCTAssertEqual(usdc.terms?.fallback.name, "Soroswap")

        let pins = Self.durations(launchpad.durations)
        XCTAssertTrue(launchpad.durations.matches(pins))
        let other = PinnedDurations.Launch(
            grace: pins.grace, fallbackDelay: pins.fallbackDelay, rescueAdmin: pins.rescueAdmin, rescuePublic: pins.rescuePublic, lockedFallback: pins.lockedFallback,
            takeoverDelay: pins.takeoverDelay, takeoverWindow: pins.takeoverWindow, timelock: pins.timelock, timelockWindow: pins.timelockWindow, harvestInterval: 60
        )
        XCTAssertFalse(launchpad.durations.matches(other))

        let moments = try XCTUnwrap(economics().moments)
        XCTAssertEqual([moments.generation, moments.maxClaimIds], [2, 20])
        XCTAssertEqual(moments.quote.asset, "USDC")
        XCTAssertEqual(moments.terms.harvest.ratio, "3,333 : 6,667")
        XCTAssertEqual(moments.terms.harvest.coinSide, "burned")
        XCTAssertEqual(moments.pendingPolicy?.state, "waiting")
        XCTAssertEqual(moments.fdvByAllocation.map(\.allocationBps), Array(stride(from: 0, through: 1_000, by: 100)))
        XCTAssertEqual(moments.fdvAtOpen, moments.fdvByAllocation.last?.fdv)
        XCTAssertEqual(moments.terms.policy, moments.policy)
        let d = moments.terms.durations
        let momentPins = PinnedDurations.Moments(
            vestPeriod: UInt64(d.vestPeriod), stuckExpiry: UInt64(d.stuckExpiry), pendingBackstop: UInt64(d.pendingBackstop), timelock: UInt64(d.timelock),
            timelockWindow: UInt64(d.timelockWindow), minWindow: UInt64(d.minWindow), maxWindow: UInt64(d.maxWindow), harvestInterval: UInt64(d.harvestInterval)
        )
        XCTAssertTrue(d.matches(momentPins))

        // Max keeps back the minimum balance, the offers' XLM, the 10 XLM fee, the network fee and the buffer (F18, V12).
        let preview = try decode(StellarLaunchPreviewV2.self, V2Fixtures.launchPreview)
        let x = preview.xlm
        let kept = [x.minBalance, x.sellingLiabilities, x.launchFee, x.fees, x.buffer].compactMap { Int64($0) }.reduce(0, +)
        XCTAssertEqual(Int64(x.balance)! - kept, Int64(x.spendable)!)
        XCTAssertEqual(preview.maxInitialBuy, x.spendable)
        XCTAssertEqual([x.launchFee, preview.launchFee.amount, preview.terms.launchFee], ["100000000", "100000000", "100000000"])
        XCTAssertEqual(preview.launchFee.to, launchpad.contract)
        XCTAssertNil(preview.shortfall)
        XCTAssertNotEqual(x.sellingLiabilities, "0")
        let short = try decode(StellarLaunchPreviewV2.self, V2Fixtures.launchPreviewShort)
        XCTAssertEqual(short.maxInitialBuy, "0")
        XCTAssertEqual(short.shortfall.flatMap { Int64($0) }, Int64(short.xlm.spendable).map { -$0 })

        // Create binds the terms by value, with the durations, and pays the fee plus the XLM buy to the launchpad.
        let create = try decode(StellarLaunchPlanV2.self, V2Fixtures.launchPlanCreate)
        let bound = try XCTUnwrap(create.terms)
        XCTAssertEqual(bound, xlm.terms)
        XCTAssertEqual(bound.durations.fallbackDelay, 3_600)
        let intent = try XCTUnwrap(create.plan.steps.first?.intent)
        let display = try XCTUnwrap(intent.display)
        XCTAssertEqual(display["launchFeeTo"]?.text, launchpad.contract)
        XCTAssertEqual(display["harvestInterval"]?.text, "3600")
        let spent = try XCTUnwrap((display["initialBuy"]?.text).flatMap { Int64($0) }) + Int64(bound.launchFee)!
        XCTAssertEqual(intent.spend, [bound.feeAsset: String(spent)])
        XCTAssertNil(create.harvestBacklog)

        // A recipient change on a graduated launch without sharing: the harvest step first, then the backlog (V7).
        let change = try decode(StellarLaunchPlanV2.self, V2Fixtures.launchPlanRecipient)
        XCTAssertEqual(change.plan.steps.map(\.status), ["built", "pending"])
        XCTAssertEqual(change.plan.steps.first?.intent?.kind, "launch_harvest")
        XCTAssertEqual(change.plan.steps.first?.intent?.calls?.first?.contract, launchpad.locker)
        let backlog = try XCTUnwrap(change.harvestBacklog)
        XCTAssertEqual(backlog.roundsToDrain, 10)
        XCTAssertLessThan(Int64(backlog.residualQuote)!, Int64(backlog.growthQuote)!)
        XCTAssertEqual(try seconds(backlog.nextHarvestAt, backlog.drainedBy), (backlog.roundsToDrain - 1) * launchpad.harvest.intervalSecs)
        XCTAssertNil(change.terms)

        let graduated = try decode(StellarLaunchStateV2.self, V2Fixtures.launchStateGraduated)
        XCTAssertEqual(graduated.status.graduatedVenue?.name, "Soroswap")
        XCTAssertEqual([graduated.rewards.pendingQuote, graduated.rewards.pendingToken], ["250000", "7000000000"])
        XCTAssertEqual(graduated.pendingTakeover?.state, "open")
        XCTAssertEqual(graduated.you?.creatorOwed, "1200000")
        XCTAssertEqual(graduated.you?.isRecipient, false)
        let buy = try decode(StellarTradeQuoteV2.self, V2Fixtures.launchQuoteBuy)
        XCTAssertEqual(Int64(buy.fees), [buy.baseFee, buy.creatorFee, buy.snipeFee].compactMap { $0.flatMap { Int64($0) } }.reduce(0, +))
    }

    func testMomentPlansCarryWhatTheReviewShows() throws {
        let terms = try XCTUnwrap(economics().moments?.terms)
        let publish = try decode(PlanView.self, V2Fixtures.momentPlanPublish).steps[0].intent
        let shown = try XCTUnwrap(publish?.display)
        // The terms guard compares what the review showed with what publish binds (CT-14).
        XCTAssertEqual(shown["pendingBackstop"]?.text, String(terms.durations.pendingBackstop))
        XCTAssertEqual(shown["nftWasmHash"]?.text, terms.nftWasmHash)
        XCTAssertEqual(shown["royaltyBps"]?.text, String(terms.policy.royaltyBps))
        XCTAssertEqual(shown["symbol"]?.text, "DUSK")
        XCTAssertEqual(publish?.spend, [:])
        let collect = try decode(PlanView.self, V2Fixtures.momentPlanCollect).steps[0].intent
        XCTAssertEqual(collect?.spend, [try XCTUnwrap(economics().moments?.quote.contract): "30000000"], "max_total in USDC only")
        let claimAll = try decode(PlanView.self, V2Fixtures.momentPlanClaimAll).steps[0].intent
        XCTAssertEqual([claimAll?.kind, claimAll?.display?["moments"]?.text], ["moment_claim_all", "1"])
        let vesting = try decode(StellarMomentVestingV2.self, V2Fixtures.momentVesting)
        XCTAssertEqual(claimAll?.display?["total"]?.text, vesting.claimable.total)
        XCTAssertEqual(vesting.collector?.nextAt, vesting.collector?.tranches.last?.at)
        XCTAssertEqual(try seconds(vesting.startsAt, vesting.collector?.tranches[1].at), vesting.vestPeriodSecs)

        let collecting = try decode(StellarMomentStatusV2.self, V2Fixtures.momentStatusCollecting)
        XCTAssertEqual([collecting.expiresBy, collecting.expiresAt], ["deadline", collecting.deadline])
        XCTAssertEqual(collecting.id, collecting.nft)
        let graduated = try decode(StellarMomentStatusV2.self, V2Fixtures.momentStatusGraduated)
        XCTAssertNotNil(graduated.pool)
        XCTAssertNil(graduated.expiresAt)
        let expired = try decode(StellarMomentStatusV2.self, V2Fixtures.momentStatusExpired)
        XCTAssertEqual(expired.state, "expired")
        XCTAssertFalse(expired.graduatable)
    }

    /// A v1 server's economics read as "not deployed"; a v2 block that doesn't decode is an error, not nil.
    func testEconomicsV2ReadsV2BlocksOnly() throws {
        let v1 = try JSONDecoder().decode(StellarEconomicsV2.self, from: ApiFixtures.data("economics"))
        XCTAssertNil(v1.launchpad)
        XCTAssertNil(v1.moments)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(V2Fixtures.economics.utf8)) as? [String: Any])
        let v1Wire = try XCTUnwrap(JSONSerialization.jsonObject(with: ApiFixtures.data("economics")) as? [String: Any])
        let mixed = try JSONSerialization.data(withJSONObject: ["launchpad": wire["launchpad"]!, "moments": v1Wire["moments"]!])
        let read = try JSONDecoder().decode(StellarEconomicsV2.self, from: mixed)
        XCTAssertNotNil(read.launchpad)
        XCTAssertNil(read.moments)
        var broken = try XCTUnwrap(wire["launchpad"] as? [String: Any])
        broken["launchFee"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(StellarEconomicsV2.self, from: JSONSerialization.data(withJSONObject: ["launchpad": broken])))
    }

    /// A takeover and a pending policy keep their window's state on screen as time passes: past the window's end they
    /// read as lapsed, whatever the API said when it answered (lead note after CT-09).
    func testWindowsReadAtTheTimeTheyAreShown() throws {
        let takeover = try XCTUnwrap(decode(StellarLaunchStateV2.self, V2Fixtures.launchStateGraduated).pendingTakeover)
        let opens = try XCTUnwrap(ISO8601DateFormatter.lite.date(from: takeover.effectiveAt))
        let closes = try XCTUnwrap(ISO8601DateFormatter.lite.date(from: takeover.expiresAt))
        XCTAssertEqual(takeover.state, "open")
        XCTAssertEqual(
            [opens - 1, opens, closes, closes + 0.999, closes + 1].map(takeover.state(at:)),
            ["waiting", "open", "open", "open", "lapsed"]
        )
        let policy = try XCTUnwrap(economics().moments?.pendingPolicy)
        let eta = try XCTUnwrap(ISO8601DateFormatter.lite.date(from: policy.eta))
        let expires = try XCTUnwrap(ISO8601DateFormatter.lite.date(from: policy.expires))
        XCTAssertEqual(policy.state, "waiting")
        XCTAssertEqual([eta - 1, eta, expires, expires + 1].map(policy.state(at:)), ["waiting", "ready", "ready", "lapsed"])
    }

    func testTickersAreTwoToTenASCIILettersOrDigits() {
        XCTAssertEqual(StellarTickerV2.normalized("ecat"), "ECAT")
        XCTAssertEqual(StellarTickerV2.normalized(" Ecat9 "), "ECAT9")
        XCTAssertEqual(StellarTickerV2.normalized("AB"), "AB")
        XCTAssertEqual(StellarTickerV2.normalized("ABCDEFGHIJ"), "ABCDEFGHIJ")
        for refused in ["", "E", "ABCDEFGHIJK", "ÉCAT", "e\u{301}cat", "E CAT", "E-CAT", "E_CAT", "ＥＣＡＴ", "CAT🐈", "$CAT"] {
            XCTAssertNil(StellarTickerV2.normalized(refused), refused)
        }
        XCTAssertEqual(StellarTickerV2.refusal.code, "bad_symbol")
    }

    // ------------------------------------------------------------------------------------------------------ helpers

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func economics() throws -> StellarEconomicsV2 { try decode(StellarEconomicsV2.self, V2Fixtures.economics) }

    /// Seconds from one ISO time to another.
    private func seconds(_ from: String?, _ to: String?) throws -> Int {
        let a = try XCTUnwrap(from.flatMap(ISO8601DateFormatter.lite.date(from:)), "\(from ?? "nil")")
        let b = try XCTUnwrap(to.flatMap(ISO8601DateFormatter.lite.date(from:)), "\(to ?? "nil")")
        return Int(b.timeIntervalSince(a))
    }

    static func durations(_ d: StellarLaunchDurationsV2) -> PinnedDurations.Launch {
        PinnedDurations.Launch(
            grace: UInt64(d.grace), fallbackDelay: UInt64(d.fallbackDelay), rescueAdmin: UInt64(d.rescueAdmin), rescuePublic: UInt64(d.rescuePublic),
            lockedFallback: UInt64(d.lockedFallback), takeoverDelay: UInt64(d.takeoverDelay), takeoverWindow: UInt64(d.takeoverWindow), timelock: UInt64(d.timelock),
            timelockWindow: UInt64(d.timelockWindow), harvestInterval: UInt64(d.harvestInterval)
        )
    }
}

/// The v2 LiteAPI methods ask for their routes, send the session token only where the route takes it, send their
/// bodies typed as the API reads them, and refuse a ticker the contracts would refuse before sending anything.
final class V2RouteTests: XCTestCase {
    private let base = "https://lite.test/functions/v1/lite"
    private let viewer = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
    private var api: LiteAPI!

    override func setUp() async throws {
        api = LiteAPI(baseURL: URL(string: base)!, session: V2Stub.session)
        await api.restore(token: "fixture-session-token", expiresAt: Date().addingTimeInterval(3600))
    }

    func testLaunchRoutes() async throws {
        try await expect("GET", "/v1/economics", token: true, answer: V2Fixtures.economics) {
            let e = try await $0.economicsV2()
            XCTAssertEqual(e.launchpad?.launchFee.amount, "100000000")
        }
        let preview = try await expect("POST", "/v1/launches/preview", token: true, answer: V2Fixtures.launchPreview) {
            let r = LiteAPI.LaunchRequestV2(action: .create, quote: "XLM", venue: 0, name: "E2E Cat", symbol: "ecat", holderSharing: false, exempt: ["GB"])
            _ = try await $0.launchPreviewV2(r)
        }
        XCTAssertEqual(preview?["venue"] as? Int, 0)
        XCTAssertEqual(preview?["holderSharing"] as? Bool, false, "a bool, which the API reads as such")
        XCTAssertEqual(preview?["exempt"] as? [String], ["GB"])
        XCTAssertNil(preview?["token"], "nil fields are left out")
        XCTAssertEqual(preview?["symbol"] as? String, "ECAT")
        // A ticker the contracts wouldn't take yet is left out of the preview: the API prices the longest one.
        let unfinished = try await expect("POST", "/v1/launches/preview", token: true, answer: V2Fixtures.launchPreview) {
            _ = try await $0.launchPreviewV2(.init(action: .create, quote: "XLM", symbol: "É"))
        }
        XCTAssertNil(unfinished?["symbol"])
        try await expect("GET", "/v1/launches/CTOKEN/state", token: true, answer: V2Fixtures.launchStateGraduated) {
            _ = try await $0.launchStateV2("CTOKEN")
        }
        let quote = try await expect("POST", "/v1/launches/CTOKEN/quote", token: true, answer: V2Fixtures.launchQuoteRefund) {
            let q = try await $0.quoteTradeV2(token: "CTOKEN", side: .refund, amount: 1_000_000_000_000)
            XCTAssertEqual(q.side, .refund)
        }
        XCTAssertEqual(quote as? [String: String], ["side": "refund", "amount": "1000000000000"])
        let create = try await expect("POST", "/v1/launches/build", token: true, answer: V2Fixtures.launchPlanCreate) {
            let plan = try await $0.buildLaunchV2(.init(action: .create, quote: "XLM", name: "E2E Cat", symbol: " ecat ", creatorFeeBps: 100, amount: "500000000"))
            XCTAssertNotNil(plan.terms)
        }
        XCTAssertEqual([create?["action"] as? String, create?["symbol"] as? String], ["create", "ECAT"])
        XCTAssertEqual(create?["creatorFeeBps"] as? Int, 100)
        let change = try await expect("POST", "/v1/launches/build", token: true, answer: V2Fixtures.launchPlanRecipient) {
            let plan = try await $0.buildLaunchV2(.init(action: .recipientTransfer, token: "CTOKEN", to: "GNEXT"))
            XCTAssertEqual(plan.harvestBacklog?.roundsToDrain, 10)
        }
        XCTAssertEqual(change as? [String: String], ["action": "recipient_transfer", "token": "CTOKEN", "to": "GNEXT"])
        let owed = try await expect("POST", "/v1/launches/build", token: true, answer: V2Fixtures.launchPlanRefund) {
            _ = try await $0.buildLaunchV2(.init(action: .claimOwed, asset: "USDC"))
        }
        XCTAssertEqual(owed as? [String: String], ["action": "claim_owed", "asset": "USDC"])
    }

    func testMomentRoutes() async throws {
        try await expect("GET", "/v1/moments/CNFT/status", token: false, answer: V2Fixtures.momentStatusFailed) {
            let s = try await $0.momentStatusV2("CNFT")
            XCTAssertEqual(s.failure?.name, "GraduationInvalid")
        }
        try await expect("GET", "/v1/moments/CNFT/vesting", token: true, answer: V2Fixtures.momentVestingFull) { _ = try await $0.momentVestingV2("CNFT") }
        let publish = try await expect("POST", "/v1/moments/build", token: true, answer: V2Fixtures.momentPlanPublish) {
            let r = LiteAPI.MomentRequestV2(action: .publish, uri: "https://m/u.json", name: "Dusk", symbol: "dusk", price: "10000000", allocationBps: 1_000, windowSecs: 86_400)
            _ = try await $0.buildMomentV2(r)
        }
        XCTAssertEqual([publish?["action"] as? String, publish?["symbol"] as? String, publish?["price"] as? String], ["publish", "DUSK", "10000000"])
        XCTAssertEqual([publish?["allocationBps"] as? Int, publish?["windowSecs"] as? Int], [1_000, 86_400])
        let collect = try await expect("POST", "/v1/moments/build", token: true, answer: V2Fixtures.momentPlanCollect) {
            _ = try await $0.buildMomentV2(.init(action: .collect, nft: "CNFT", quantity: 3))
        }
        XCTAssertEqual([collect?["nft"] as? String, collect?["quantity"].map { "\($0)" }], ["CNFT", "3"])
        let claimAll = try await expect("POST", "/v1/moments/build", token: true, answer: V2Fixtures.momentPlanClaimAll) {
            _ = try await $0.buildMomentV2(.init(action: .claimAll, nfts: ["CA", "CB"]))
        }
        XCTAssertEqual([claimAll?["action"] as? String], ["claim_all"])
        XCTAssertEqual(claimAll?["nfts"] as? [String], ["CA", "CB"])
    }

    /// Without a session: the launch page and a Moment's vesting ask for the viewer's public view, a Moment's status
    /// asks as it is, and the session routes ask nothing.
    func testWithoutASession() async throws {
        api = LiteAPI(baseURL: URL(string: base)!, session: V2Stub.session)
        try await expect("GET", "/v1/launches/CTOKEN/state", token: false, answer: V2Fixtures.launchStateVenueLocked) { _ = try await $0.launchStateV2("CTOKEN") }
        try await expect("GET", "/v1/moments/CNFT/status", token: false, answer: V2Fixtures.momentStatusPending) { _ = try await $0.momentStatusV2("CNFT") }
        try await expect("GET", "/v1/economics", token: false, answer: V2Fixtures.economics) { _ = try await $0.economicsV2() }
        try await refusedUnsent(.notSignedIn) { _ = try await $0.momentVestingV2("CNFT") }
        try await refusedUnsent(.notSignedIn) { _ = try await $0.buildLaunchV2(.init(action: .buy, token: "CTOKEN", amount: "1", minOut: "1")) }
        try await refusedUnsent(.notSignedIn) { _ = try await $0.launchPreviewV2(.init(action: .create, quote: "XLM")) }
        await api.setViewer(address: viewer)
        try await expect("GET", "/v1/launches/CTOKEN/state?address=\(viewer)", token: false, answer: V2Fixtures.launchStateGraduated) {
            _ = try await $0.launchStateV2("CTOKEN")
        }
        try await expect("GET", "/v1/moments/CNFT/vesting?address=\(viewer)", token: false, answer: V2Fixtures.momentVesting) {
            _ = try await $0.momentVestingV2("CNFT")
        }
        try await expect("GET", "/v1/moments/CNFT/status", token: false, answer: V2Fixtures.momentStatusPending) { _ = try await $0.momentStatusV2("CNFT") }
    }

    /// A ticker the contracts would refuse is refused before anything is sent, with the API's own code and words.
    func testTickersAreRefusedBeforeAnythingIsSent() async throws {
        for symbol in [nil, "", "E", "ABCDEFGHIJK", "ÉCAT", "E CAT", "E-CAT"] as [String?] {
            try await refusedUnsent(StellarTickerV2.refusal) { _ = try await $0.buildLaunchV2(.init(action: .create, quote: "XLM", name: "Cat", symbol: symbol)) }
            try await refusedUnsent(StellarTickerV2.refusal) { _ = try await $0.buildMomentV2(.init(action: .publish, uri: "https://m/u.json", symbol: symbol, price: "10000000")) }
        }
        // Only create and publish name a ticker.
        try await expect("POST", "/v1/launches/build", token: true, answer: V2Fixtures.launchPlanRefund) {
            _ = try await $0.buildLaunchV2(.init(action: .refund, token: "CTOKEN", amount: "1"))
        }
    }

    func testPathValuesAreEscaped() async throws {
        try await expect("GET", "/v1/launches/C%3Faddress%3DG/state", token: true, answer: V2Fixtures.launchStateGraduated) {
            _ = try await $0.launchStateV2("C?address=G")
        }
        try await expect("GET", "/v1/moments/C%2F..%2Fmine/status", token: false, answer: V2Fixtures.momentStatusPending) {
            _ = try await $0.momentStatusV2("C/../mine")
        }
        for nft in ["", ".", ".."] {
            V2Stub.answer(V2Fixtures.momentStatusPending)
            do {
                _ = try await api.momentStatusV2(nft)
                XCTFail("\"\(nft)\" didn't throw")
            } catch LiteAPIError.decoding {}
            XCTAssertEqual(V2Stub.requests().count, 0, "\"\(nft)\" was sent")
        }
    }

    /// Answers `answer`, runs `call`, and checks the one request it made; returns the request's JSON body.
    @discardableResult
    private func expect(_ method: String, _ route: String, token: Bool, answer: String, file: StaticString = #filePath, line: UInt = #line,
                        _ call: (LiteAPI) async throws -> Void) async throws -> [String: Any]? {
        V2Stub.answer(answer)
        try await call(api)
        let taken = V2Stub.requests()
        XCTAssertEqual(taken.count, 1, "\(route): requests", file: file, line: line)
        let (request, body) = try XCTUnwrap(taken.first, "no request", file: file, line: line)
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.url?.absoluteString, base + route, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization") != nil, token, "\(route): token sent", file: file, line: line)
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func refusedUnsent(_ expected: LiteAPIError, file: StaticString = #filePath, line: UInt = #line, _ call: (LiteAPI) async throws -> Void) async throws {
        V2Stub.answer(V2Fixtures.launchPlanRefund)
        do {
            try await call(api)
            XCTFail("not refused", file: file, line: line)
        } catch let error as LiteAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
        XCTAssertEqual(V2Stub.requests().count, 0, "sent", file: file, line: line)
    }
}

/// PlanRunner's runtime-contract check (§20.1): a contract outside the pins counts only by the WASM it runs: a v2
/// launch token, Moment NFT or Moment coin by its pinned hash. Any other WASM, or none, and the step isn't signed.
final class V2RuntimeContractTests: XCTestCase {
    func testAcceptsLaunchTokenV2MomentNftAndMomentCoinInstancesByHash() async throws {
        let claim = try V2Vector.named("v2 claim rewards ok")
        let token = try XCTUnwrap(claim.intent.calls?.first?.contract)
        let pinned = try claim.pinned()
        XCTAssertEqual(Set(pinned.runtimeWasmHashes.keys), ["launchTokenV2", "momentNft", "momentCoin"])
        for (role, hash) in pinned.runtimeWasmHashes {
            let chain = ChainCode([token: hash])
            let results = try await run(claim, chain)
            XCTAssertEqual(results.map(\.status), ["success"], role)
            let read = await chain.read
            XCTAssertEqual(read, [token], "\(role): read once, by the pinned RPC")
        }
        // A Moment coin's transfer, and a restore of a Moment NFT's data with the code it runs.
        let transfer = try V2Vector.named("v2 moment coin transfer ok")
        let coin = try XCTUnwrap(transfer.intent.calls?.first?.contract)
        let coinHash = try XCTUnwrap(transfer.pinned().runtimeWasmHashes["momentCoin"])
        let sent = try await run(transfer, ChainCode([coin: coinHash.uppercased()]))
        XCTAssertEqual(sent.count, 1, "hashes compare as hex, whatever the case")
        let restore = try V2Vector.named("v2 restore of a launch token's data and code ok")
        let restored = try XCTUnwrap(restore.runtime?.keys.first)
        let nftHash = try XCTUnwrap(restore.pinned().runtimeWasmHashes["momentNft"])
        let restoredNft = try await run(restore, ChainCode([restored: nftHash]))
        XCTAssertEqual(restoredNft.count, 1)
    }

    func testRejectsAnyOtherWasm() async throws {
        let claim = try V2Vector.named("v2 claim rewards ok")
        let token = try XCTUnwrap(claim.intent.calls?.first?.contract)
        let notOnTheAllowlist = PlanRunner.Failure.refused(step: claim.name, reason: "Contract \(token) is not on the allowlist.")
        for code in [[token: String(repeating: "ee", count: 32)], [:]] {
            let backend = try await refused(claim, ChainCode(code), notOnTheAllowlist)
            let submitted = await backend.submitted
            XCTAssertEqual(submitted, [], "\(code): nothing was sent")
        }
        let transfer = try V2Vector.named("v2 moment coin transfer ok")
        let coin = try XCTUnwrap(transfer.intent.calls?.first?.contract)
        try await refused(transfer, ChainCode([coin: String(repeating: "ab", count: 32)]), .refused(step: transfer.name, reason: "Contract \(coin) is not on the allowlist."))
        let restore = try V2Vector.named("v2 restore of a launch token's data and code ok")
        let restored = try XCTUnwrap(restore.runtime?.keys.first)
        try await refused(restore, ChainCode([restored: String(repeating: "ee", count: 32)]), .refused(step: restore.name, reason: "The restore touches data outside the allowlist."))
    }

    /// v1's launch tokens still count by v1's hash, and inspectors that only know v1 keep working.
    func testV1LaunchTokensStillCount() async throws {
        let restore = try SharedVectors.named("restore ok")
        let v1 = FakeInspector(launchTokens: Set(restore.launchTokens))
        let hashes = try await v1.wasmHashes(among: restore.launchTokens + ["CUNKNOWN"], pinned: restore.pinned)
        XCTAssertEqual(hashes, Dictionary(uniqueKeysWithValues: restore.launchTokens.map { ($0, restore.launchTokenWasmHash) }))
        let split = PlanRunner.runtimeContracts(hashes, pinned: restore.pinned)
        XCTAssertEqual(split.launchTokens, Set(restore.launchTokens))
        XCTAssertEqual(split.v2, [:], "no v2 pins")
    }

    func testTheCheckSplitsV1AndV2AndDropsTheRest() throws {
        let pinned = PinnedContracts(
            network: .testnet, sponsor: Self.account(9), launchTokenWasmHash: Self.hash(0xc7), roles: [:],
            runtimeWasmHashes: ["launchTokenV2": Self.hash(0xa1), "momentNft": Self.hash(0xa2), "momentCoin": Self.hash(0xa3)]
        )
        let read = ["CV1": Self.hash(0xc7), "CTOKEN": Self.hash(0xa1), "CNFT": Self.hash(0xa2).uppercased(), "CCOIN": Self.hash(0xa3), "COTHER": Self.hash(0xee)]
        let split = PlanRunner.runtimeContracts(read, pinned: pinned)
        XCTAssertEqual(split.launchTokens, ["CV1"])
        XCTAssertEqual(split.v2, ["CTOKEN": Self.hash(0xa1), "CNFT": Self.hash(0xa2), "CCOIN": Self.hash(0xa3)])
        let v1Only = PinnedContracts(network: .testnet, sponsor: Self.account(9), launchTokenWasmHash: Self.hash(0xc7), roles: [:])
        XCTAssertEqual(PlanRunner.runtimeContracts(read, pinned: v1Only).v2, [:])
    }

    /// ContractInspector reads each instance's code from the pinned RPC: a WASM's hash, nothing for a Stellar Asset
    /// Contract or a missing one, no read of a pinned contract, and no read at all while no runtime WASM is pinned.
    func testContractInspectorReadsEachInstancesCode() async throws {
        let (pad, v1, nft, coin, other, sac, missing) = (Self.contract(1), Self.contract(2), Self.contract(3), Self.contract(4), Self.contract(5), Self.contract(6), Self.contract(7))
        let pinned = PinnedContracts(
            network: .testnet, sponsor: Self.account(9), launchTokenWasmHash: Self.hash(0xc7), roles: ["launchpadV2": [pad]],
            runtimeWasmHashes: ["launchTokenV2": Self.hash(0xa1), "momentNft": Self.hash(0xa2), "momentCoin": Self.hash(0xa3)]
        )
        let code: [String: [UInt8]?] = [v1: Self.bytes(0xc7), nft: Self.bytes(0xa2), coin: Self.bytes(0xa3), other: Self.bytes(0xee), sac: nil, pad: Self.bytes(0x01)]
        var entries: [String: String] = [:]
        for (contract, wasm) in code { entries[try ContractInspector.instanceKey(contract)] = try Self.instanceEntry(contract, wasm: wasm) }
        V2Stub.rpc(entries)
        let inspector = ContractInspector(rpcURL: URL(string: "https://rpc.test")!, session: V2Stub.session)
        let hashes = try await inspector.wasmHashes(among: [pad, v1, nft, coin, other, sac, missing, nft], pinned: pinned)
        XCTAssertEqual(hashes, [v1: Self.hash(0xc7), nft: Self.hash(0xa2), coin: Self.hash(0xa3), other: Self.hash(0xee)])
        let asked = V2Stub.requests().compactMap { $0.body.flatMap(Self.ledgerKey) }
        XCTAssertEqual(Set(asked), Set(try [v1, nft, coin, other, sac, missing].map(ContractInspector.instanceKey)), "the pinned launchpad isn't read")
        XCTAssertEqual(asked.count, 6, "each contract read once")
        XCTAssertEqual(V2Stub.requests().first?.request.url?.absoluteString, "https://rpc.test")
        let launchTokens = try await inspector.launchTokens(among: [v1, nft, coin], pinned: pinned)
        XCTAssertEqual(launchTokens, [v1])

        V2Stub.rpc(entries)
        let nothingPinned = PinnedContracts(network: .testnet, sponsor: Self.account(9), launchTokenWasmHash: "", roles: [:])
        let unpinned = try await inspector.wasmHashes(among: [v1, nft], pinned: nothingPinned)
        XCTAssertEqual(unpinned, [:])
        XCTAssertEqual(V2Stub.requests().count, 0)
    }

    // ------------------------------------------------------------------------------------------------------ helpers

    /// Runs `vector` as a one-step plan, built for the review, on the vector's clock and pins, with the chain's code.
    @discardableResult
    private func run(_ vector: V2Vector, _ chain: ChainCode, backend: FakePlanBackend? = nil) async throws -> [TxStatus] {
        let plan = TestPlan.view([TestPlan.step("s1", vector.name, xdr: vector.envelope, intent: vector.intent)])
        let pinned = try vector.pinned()
        var runner = PlanRunner(api: backend ?? FakePlanBackend(plan: plan), user: vector.user, pinned: pinned, inspector: chain)
        let now = vector.now
        runner.now = { Date(timeIntervalSince1970: now) }
        let key = try SharedVectors.user()
        let limits = vector.intent.spend.compactMapValues(TxVerifier.units)
        return try await runner.run(plan, limits: limits, fees: try PlanFees(plan: plan, pinned: pinned), signer: { key })
    }

    @discardableResult
    private func refused(_ vector: V2Vector, _ chain: ChainCode, _ expected: PlanRunner.Failure, file: StaticString = #filePath, line: UInt = #line) async throws -> FakePlanBackend {
        let plan = TestPlan.view([TestPlan.step("s1", vector.name, xdr: vector.envelope, intent: vector.intent)])
        let backend = FakePlanBackend(plan: plan)
        do {
            try await run(vector, chain, backend: backend)
            XCTFail("\(vector.name): signed", file: file, line: line)
        } catch let failure as PlanRunner.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        }
        return backend
    }

    private static func bytes(_ b: UInt8) -> [UInt8] { [UInt8](repeating: b, count: 32) }
    private static func hash(_ b: UInt8) -> String { String(repeating: String(format: "%02x", b), count: 32) }
    private static func contract(_ b: UInt8) -> String { StrKey.contractID(bytes(b)) }
    private static func account(_ b: UInt8) -> String { StrKey.accountID(bytes(b)) }

    /// LedgerEntryData::ContractData { contract, the instance key, persistent, ContractInstance { executable } }, base64:
    /// the WASM `wasm`, or the Stellar Asset Contract's executable when nil.
    private static func instanceEntry(_ contract: String, wasm: [UInt8]?) throws -> String {
        var w = XDRWriter()
        w.uint32(6) // CONTRACT_DATA
        w.uint32(0) // ext
        w.uint32(1) // SC_ADDRESS_TYPE_CONTRACT
        w.raw(try StrKey.decode(.contract, contract))
        w.uint32(20) // SCV_LEDGER_KEY_CONTRACT_INSTANCE
        w.uint32(1) // PERSISTENT
        w.uint32(19) // SCV_CONTRACT_INSTANCE
        if let wasm {
            w.uint32(0) // CONTRACT_EXECUTABLE_WASM
            w.raw(wasm)
        } else {
            w.uint32(1) // CONTRACT_EXECUTABLE_STELLAR_ASSET
        }
        w.uint32(0) // no storage
        return Data(w.bytes).base64EncodedString()
    }

    /// The one ledger key a getLedgerEntries request asks for.
    private static func ledgerKey(_ body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], json["method"] as? String == "getLedgerEntries",
              let keys = (json["params"] as? [String: Any])?["keys"] as? [String], keys.count == 1 else { return nil }
        return keys[0]
    }
}

// ------------------------------------------------------------------------------------------------------ fakes

/// The code the chain runs, by contract, as the pinned RPC would answer it. Each contract outside the pins the runner
/// asks about is kept in `read`.
actor ChainCode: LaunchTokenInspecting {
    private let code: [String: String]
    private(set) var read: Set<String> = []

    init(_ code: [String: String]) { self.code = code }

    func launchTokens(among contracts: [String], pinned: PinnedContracts) async throws -> Set<String> {
        Set(try await wasmHashes(among: contracts, pinned: pinned).filter { $0.value == pinned.launchTokenWasmHash }.keys)
    }

    func wasmHashes(among contracts: [String], pinned: PinnedContracts) async throws -> [String: String] {
        let asked = Set(contracts).subtracting(pinned.allContracts)
        read.formUnion(asked)
        return code.filter { asked.contains($0.key) }
    }
}

/// One answer for every request, or a fake RPC's ledger entries, and every request taken with its body.
final class V2Stub: URLProtocol {
    private static let lock = NSLock()
    private static var respond: (Data?) -> Data = { _ in Data() }
    private static var taken: [(request: URLRequest, body: Data?)] = []

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [V2Stub.self]
        return URLSession(configuration: config)
    }()

    /// Answers `json` to every request.
    static func answer(_ json: String) {
        set { _ in Data(json.utf8) }
    }

    /// Answers getLedgerEntries with the entry each key has in `entries`, and none for another.
    static func rpc(_ entries: [String: String]) {
        set { body in
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let keys = ((json?["params"] as? [String: Any])?["keys"] as? [String]) ?? []
            let found = keys.compactMap { key in entries[key].map { ["key": key, "xdr": $0, "lastModifiedLedgerSeq": 1] as [String: Any] } }
            let answer: [String: Any] = ["jsonrpc": "2.0", "id": json?["id"] ?? 1, "result": ["entries": found, "latestLedger": 1]]
            return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        }
    }

    static func requests() -> [(request: URLRequest, body: Data?)] {
        lock.lock(); defer { lock.unlock() }
        return taken
    }

    private static func set(_ answer: @escaping (Data?) -> Data) {
        lock.lock(); defer { lock.unlock() }
        respond = answer
        taken = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.read(request)
        Self.lock.lock()
        Self.taken.append((request, body))
        let answer = Self.respond(body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The body as sent: URLSession hands it to a protocol as a stream.
    private static func read(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A v2 case of the shared verifier vectors (Tests/StellarCoreTests/Vectors/verifier.json, gen-vectors.ts), with the
/// pins it was judged with: its contracts, and v2's roles, runtime WASM hashes, durations and launch-fee bound as
/// gen-pinned.ts writes them into PinnedContracts.
struct V2Vector: Decodable {
    struct Fees: Decodable { let maxFee: String; let maxInclusionPerOp: String; let starterInnerFeeMax: String }
    struct V2: Decodable {
        struct Contracts: Decodable {
            let launchpadV2: String
            let momentsV2: String
            let lpLocker: String
            let execSoroswap: String
            let execAquarius: String?
            let momentsGraduator: String
        }
        struct Durations: Decodable { let launch: [String: UInt64]; let moments: [String: UInt64] }
        let contracts: Contracts
        let runtimeWasmHashes: [String: String]
        let durations: Durations
        let maxLaunchFeeStroops: String
    }

    let name: String
    let envelope: String
    let intent: Intent
    let user: String
    let sponsor: String
    let allowed: [String]
    let launchTokenWasmHash: String
    let monadDomain: UInt32
    let feePolicy: Fees
    let v2: V2?
    let runtime: [String: String]?
    let now: Double

    static func named(_ name: String) throws -> V2Vector {
        let all = try JSONDecoder().decode([V2Vector].self, from: Data(contentsOf: SharedVectors.directory.appendingPathComponent("verifier.json")))
        let vector = try XCTUnwrap(all.first { $0.name == name }, name)
        XCTAssertNotNil(vector.v2, "\(name) has v2's pins")
        return vector
    }

    func pinned() throws -> PinnedContracts {
        let fees = FeePolicy(maxFee: Int64(feePolicy.maxFee)!, maxInclusionFeePerOp: Int64(feePolicy.maxInclusionPerOp)!, starterInnerFeeMax: Int64(feePolicy.starterInnerFeeMax)!)
        let v2 = try XCTUnwrap(self.v2, name)
        let c = v2.contracts
        var roles = ["all": allowed, "launchpadV2": [c.launchpadV2], "momentsV2": [c.momentsV2], "lpLocker": [c.lpLocker], "execSoroswap": [c.execSoroswap]]
        roles["momentsGraduator"] = [c.momentsGraduator]
        if let aquarius = c.execAquarius { roles["execAquarius"] = [aquarius] }
        func secs(_ set: [String: UInt64], _ key: String) throws -> UInt64 { try XCTUnwrap(set[key], "\(name): durations.\(key)") }
        let l = v2.durations.launch, m = v2.durations.moments
        let durations = PinnedDurations(
            launch: .init(
                grace: try secs(l, "grace"), fallbackDelay: try secs(l, "fallback_delay"), rescueAdmin: try secs(l, "rescue_admin"),
                rescuePublic: try secs(l, "rescue_public"), lockedFallback: try secs(l, "locked_fallback"), takeoverDelay: try secs(l, "takeover_delay"),
                takeoverWindow: try secs(l, "takeover_window"), timelock: try secs(l, "timelock"), timelockWindow: try secs(l, "timelock_window"),
                harvestInterval: try secs(l, "harvest_interval")
            ),
            moments: .init(
                vestPeriod: try secs(m, "vest_period"), stuckExpiry: try secs(m, "stuck_expiry"), pendingBackstop: try secs(m, "pending_backstop"),
                timelock: try secs(m, "timelock"), timelockWindow: try secs(m, "timelock_window"), minWindow: try secs(m, "min_window"),
                maxWindow: try secs(m, "max_window"), harvestInterval: try secs(m, "harvest_interval")
            )
        )
        return PinnedContracts(
            network: .testnet, sponsor: sponsor, launchTokenWasmHash: launchTokenWasmHash, roles: roles, feePolicy: fees, monadDomain: monadDomain,
            runtimeWasmHashes: v2.runtimeWasmHashes, durations: durations, maxLaunchFeeStroops: try XCTUnwrap(Int64(v2.maxLaunchFeeStroops))
        )
    }
}

/// JSON as the fixtures compare it.
enum V2JSON {
    /// The key paths `original` holds a value at and `encoded` doesn't ("steps[].builtAt"); nulls hold none.
    static func dropped(_ original: Data, _ encoded: Data) throws -> [String] {
        try paths(JSONSerialization.jsonObject(with: original)).subtracting(paths(JSONSerialization.jsonObject(with: encoded))).sorted()
    }

    /// `value` encoded and read back as a JSON object; nil for nil.
    static func object<T: Encodable>(_ value: T?) throws -> NSDictionary? {
        guard let value else { return nil }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
    }

    private static func paths(_ json: Any, _ prefix: String = "") -> Set<String> {
        var out = Set<String>()
        if let object = json as? [String: Any] {
            for (key, value) in object where !(value is NSNull) {
                let path = prefix.isEmpty ? key : prefix + "." + key
                out.insert(path)
                out.formUnion(paths(value, path))
            }
        } else if let array = json as? [Any] {
            for element in array { out.formUnion(paths(element, prefix + "[]")) }
        }
        return out
    }
}

/// The v2 API's answers, captured from backend/supabase/functions/_shared/launchpad_v2.ts (CT-13) and moments_v2.ts
/// (CT-14) against their unit tests' fake chains (backend/tests/unit/launchpad_v2.test.ts, moments_v2.test.ts): each
/// function's return value as the API's json() writes it. The Moment plans wrap the steps the builders made in the plan
/// view createPlan answers with. Addresses and WASM hashes are the fakes' own.
enum V2Fixtures {
    /// Both v2 blocks of /v1/economics: a QA venue that USDC is locked to, and a pending Moments policy.
    static let economics = #"""
        {
          "launchpad": {
            "contract": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW",
            "generation": 2,
            "launchesEnabled": true,
            "whitelistEnabled": false,
            "supply": "10000000000000000",
            "feeBps": 100,
            "protocolShareBps": 5000,
            "maxCreatorFeeBps": 1000,
            "snipeSchedule": [9800, 2500, 300, 30],
            "snipeStepSecs": 5,
            "launchFee": {
              "asset": "XLM",
              "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
              "amount": "100000000",
              "booked": true
            },
            "treasury": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
            "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
            "venues": [
              {
                "id": 0,
                "kind": "Soroswap",
                "name": "Soroswap",
                "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                "enabled": true,
                "feeFraction": 0
              },
              {
                "id": 2,
                "kind": "QaFail",
                "name": "the QA test venue",
                "executor": "CADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMSST",
                "enabled": true,
                "feeFraction": 0
              }
            ],
            "quotes": [
              {
                "asset": "XLM",
                "code": "XLM",
                "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                "phantom": "20000000000",
                "threshold": "43245553200",
                "enabled": true,
                "venuesAllowed": [],
                "fallbackVenue": 0,
                "venueLocked": false,
                "defaultVenue": 0,
                "terms": {
                  "supply": "10000000000000000",
                  "feeBps": 100,
                  "protocolShareBps": 5000,
                  "maxCreatorFeeBps": 1000,
                  "snipeSchedule": [9800, 2500, 300, 30],
                  "snipeStepSecs": 5,
                  "launchFee": "100000000",
                  "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "phantom": "20000000000",
                  "threshold": "43245553200",
                  "venue": {
                    "id": 0,
                    "kind": "Soroswap",
                    "name": "Soroswap",
                    "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "fallback": {
                    "id": 0,
                    "kind": "Soroswap",
                    "name": "Soroswap",
                    "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "venueLocked": false,
                  "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
                  "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
                  "durations": {
                    "grace": 3600,
                    "fallbackDelay": 3600,
                    "rescueAdmin": 604800,
                    "rescuePublic": 2592000,
                    "lockedFallback": 86400,
                    "takeoverDelay": 259200,
                    "takeoverWindow": 259200,
                    "timelock": 172800,
                    "timelockWindow": 604800,
                    "harvestInterval": 3600
                  }
                }
              },
              {
                "asset": "USDC",
                "code": "USDC",
                "contract": "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA",
                "phantom": "200000000",
                "threshold": "432455532",
                "enabled": true,
                "venuesAllowed": [2],
                "fallbackVenue": 0,
                "venueLocked": true,
                "defaultVenue": 2,
                "terms": {
                  "supply": "10000000000000000",
                  "feeBps": 100,
                  "protocolShareBps": 5000,
                  "maxCreatorFeeBps": 1000,
                  "snipeSchedule": [9800, 2500, 300, 30],
                  "snipeStepSecs": 5,
                  "launchFee": "100000000",
                  "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "quote": "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA",
                  "phantom": "200000000",
                  "threshold": "432455532",
                  "venue": {
                    "id": 2,
                    "kind": "QaFail",
                    "name": "the QA test venue",
                    "executor": "CADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMSST",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "fallback": {
                    "id": 0,
                    "kind": "Soroswap",
                    "name": "Soroswap",
                    "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "venueLocked": true,
                  "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
                  "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
                  "durations": {
                    "grace": 3600,
                    "fallbackDelay": 3600,
                    "rescueAdmin": 604800,
                    "rescuePublic": 2592000,
                    "lockedFallback": 86400,
                    "takeoverDelay": 259200,
                    "takeoverWindow": 259200,
                    "timelock": 172800,
                    "timelockWindow": 604800,
                    "harvestInterval": 3600
                  }
                }
              }
            ],
            "durations": {
              "grace": 3600,
              "fallbackDelay": 3600,
              "rescueAdmin": 604800,
              "rescuePublic": 2592000,
              "lockedFallback": 86400,
              "takeoverDelay": 259200,
              "takeoverWindow": 259200,
              "timelock": 172800,
              "timelockWindow": 604800,
              "harvestInterval": 3600
            },
            "harvest": {
              "intervalSecs": 3600,
              "roundCapBps": 50,
              "harvestBps": 10000,
              "split": {"protocolBps": 5000, "creatorOrHoldersBps": 5000},
              "splitPinnedPerLaunch": true,
              "sides": ["quote", "token"],
              "holdersPaidIn": ["quote", "token"],
              "treasuryLaunchTokens": "held"
            },
            "exclusionFloor": {"minPoolTokens": "10000000000", "minPendingQuote": "1000000", "minPendingTokens": "10000000000"},
            "aquariusFloat": null
          },
          "moments": {
            "generation": 2,
            "contract": "CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U",
            "quote": {"asset": "USDC", "contract": "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"},
            "supply": "1000000000000000",
            "maxPerCollect": 20,
            "maxClaimIds": 20,
            "policy": {
              "threshold": "100000000",
              "minPrice": "1000000",
              "creatorBps": 2000,
              "platformBps": 500,
              "reserveBps": 7500,
              "maxCreatorAllocBps": 1000,
              "expiryCreatorBps": 7000,
              "royaltyBps": 500,
              "platform": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
              "treasury": "GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK"
            },
            "pendingPolicy": {
              "policy": {
                "threshold": "100000000",
                "minPrice": "1000000",
                "creatorBps": 2000,
                "platformBps": 500,
                "reserveBps": 7500,
                "maxCreatorAllocBps": 1000,
                "expiryCreatorBps": 7000,
                "royaltyBps": 300,
                "platform": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
                "treasury": "GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK"
              },
              "eta": "2026-10-17T12:00:00.000Z",
              "expires": "2026-10-24T12:00:00.000Z",
              "state": "waiting"
            },
            "terms": {
              "policy": {
                "threshold": "100000000",
                "minPrice": "1000000",
                "creatorBps": 2000,
                "platformBps": 500,
                "reserveBps": 7500,
                "maxCreatorAllocBps": 1000,
                "expiryCreatorBps": 7000,
                "royaltyBps": 500,
                "platform": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
                "treasury": "GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK"
              },
              "externalBase": "https://dyorhq.fun/moments/",
              "nftWasmHash": "0606060606060606060606060606060606060606060606060606060606060606",
              "coinWasmHash": "0707070707070707070707070707070707070707070707070707070707070707",
              "graduator": "CABQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGCK3",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
              "durations": {
                "vestPeriod": 2592000,
                "stuckExpiry": 604800,
                "pendingBackstop": 2592000,
                "timelock": 172800,
                "timelockWindow": 604800,
                "minWindow": 3600,
                "maxWindow": 2592000,
                "harvestInterval": 3600
              },
              "harvestBps": 6667,
              "harvestCreatorBps": 4000,
              "harvest": {
                "intervalSecs": 3600,
                "harvestedBps": 6667,
                "compoundedBps": 3333,
                "ratio": "3,333 : 6,667",
                "quoteSide": {"creatorBps": 4000, "platformBps": 6000},
                "coinSide": "burned"
              }
            },
            "publishingPaused": false,
            "guardianPaused": false,
            "completionGross": "133333334",
            "maxPrice": "133333334",
            "fdvAtOpen": "259259259",
            "fdvAtOpenUsd": 25.93,
            "fdvByAllocation": [
              {"allocationBps": 0, "fdv": "233333333", "fdvUsd": 23.33},
              {"allocationBps": 100, "fdv": "235690235", "fdvUsd": 23.57},
              {"allocationBps": 200, "fdv": "238095238", "fdvUsd": 23.81},
              {"allocationBps": 300, "fdv": "240549828", "fdvUsd": 24.05},
              {"allocationBps": 400, "fdv": "243055555", "fdvUsd": 24.31},
              {"allocationBps": 500, "fdv": "245614035", "fdvUsd": 24.56},
              {"allocationBps": 600, "fdv": "248226950", "fdvUsd": 24.82},
              {"allocationBps": 700, "fdv": "250896057", "fdvUsd": 25.09},
              {"allocationBps": 800, "fdv": "253623188", "fdvUsd": 25.36},
              {"allocationBps": 900, "fdv": "256410256", "fdvUsd": 25.64},
              {"allocationBps": 1000, "fdv": "259259259", "fdvUsd": 25.93}
            ]
          }
        }
        """#

    /// The preview of an XLM launch from an account with subentries and an open offer selling XLM (V12).
    static let launchPreview = #"""
        {
          "quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},
          "venue": {
            "id": 0,
            "kind": "Soroswap",
            "name": "Soroswap",
            "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
            "enabled": true,
            "feeFraction": 0
          },
          "terms": {
            "supply": "10000000000000000",
            "feeBps": 100,
            "protocolShareBps": 5000,
            "maxCreatorFeeBps": 1000,
            "snipeSchedule": [9800, 2500, 300, 30],
            "snipeStepSecs": 5,
            "launchFee": "100000000",
            "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
            "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
            "phantom": "20000000000",
            "threshold": "43245553200",
            "venue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": false,
            "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
            "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
            "durations": {
              "grace": 3600,
              "fallbackDelay": 3600,
              "rescueAdmin": 604800,
              "rescuePublic": 2592000,
              "lockedFallback": 86400,
              "takeoverDelay": 259200,
              "takeoverWindow": 259200,
              "timelock": 172800,
              "timelockWindow": 604800,
              "harvestInterval": 3600
            }
          },
          "launchFee": {
            "asset": "XLM",
            "amount": "100000000",
            "booked": true,
            "to": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW"
          },
          "xlm": {
            "balance": "1000000000",
            "minBalance": "30000000",
            "sellingLiabilities": "250000000",
            "launchFee": "100000000",
            "fees": "4650100",
            "buffer": "5000000",
            "spendable": "610349900"
          },
          "quoteBalance": "1000000000",
          "maxInitialBuy": "610349900",
          "shortfall": null
        }
        """#

    /// The preview from 5 XLM: short before any buy.
    static let launchPreviewShort = #"""
        {
          "quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},
          "venue": {
            "id": 0,
            "kind": "Soroswap",
            "name": "Soroswap",
            "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
            "enabled": true,
            "feeFraction": 0
          },
          "terms": {
            "supply": "10000000000000000",
            "feeBps": 100,
            "protocolShareBps": 5000,
            "maxCreatorFeeBps": 1000,
            "snipeSchedule": [9800, 2500, 300, 30],
            "snipeStepSecs": 5,
            "launchFee": "100000000",
            "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
            "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
            "phantom": "20000000000",
            "threshold": "43245553200",
            "venue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": false,
            "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
            "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
            "durations": {
              "grace": 3600,
              "fallbackDelay": 3600,
              "rescueAdmin": 604800,
              "rescuePublic": 2592000,
              "lockedFallback": 86400,
              "takeoverDelay": 259200,
              "takeoverWindow": 259200,
              "timelock": 172800,
              "timelockWindow": 604800,
              "harvestInterval": 3600
            }
          },
          "launchFee": {
            "asset": "XLM",
            "amount": "100000000",
            "booked": true,
            "to": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW"
          },
          "xlm": {
            "balance": "50000000",
            "minBalance": "10000000",
            "sellingLiabilities": "0",
            "launchFee": "100000000",
            "fees": "4650100",
            "buffer": "5000000",
            "spendable": "-69650100"
          },
          "quoteBalance": "50000000",
          "maxInitialBuy": "0",
          "shortfall": "69650100"
        }
        """#

    /// Stuck two hours after a recorded LiquidityTooLow: the fallback open from fallbackAt (testnet-qa).
    static let launchStateStuck = #"""
        {
          "status": {
            "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
            "phase": "completed",
            "completedAt": "2026-10-15T11:32:36.000Z",
            "stuck": true,
            "stuckSince": "2026-10-15T12:32:36.000Z",
            "markStuckAt": "2026-10-15T12:32:36.000Z",
            "fallbackAt": "2026-10-15T13:32:36.000Z",
            "rescueAdminAt": "2026-10-22T12:32:36.000Z",
            "rescuePublicAt": "2026-11-14T12:32:36.000Z",
            "venue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": false,
            "fallbackAllowed": false,
            "pool": null,
            "graduatedVenue": null,
            "refund": null,
            "failure": {"origin": 3, "code": 10304, "name": "LiquidityTooLow", "contract": "exec-soroswap", "source": "recorded"},
            "actions": {
              "buy": false,
              "sell": false,
              "graduate": true,
              "graduateFallback": true,
              "markStuck": false,
              "rescue": false,
              "refund": false
            }
          },
          "quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},
          "recipient": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "pendingTakeover": null,
          "creatorFees": "3900000",
          "rewards": {
            "sharing": true,
            "eligible": "5000000000000000",
            "queuedQuote": "10000",
            "queuedToken": "0",
            "releasableFromLedger": 5300200,
            "pendingQuote": "0",
            "pendingToken": "0"
          },
          "you": {"isRecipient": true, "creatorOwed": "0"}
        }
        """#

    /// A venue-locked launch stuck on the QA venue: the fallback waits for lockedFallback (testnet-qa).
    static let launchStateVenueLocked = #"""
        {
          "status": {
            "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
            "phase": "completed",
            "completedAt": "2026-10-15T11:32:36.000Z",
            "stuck": true,
            "stuckSince": "2026-10-15T12:32:36.000Z",
            "markStuckAt": "2026-10-15T12:32:36.000Z",
            "fallbackAt": "2026-10-16T12:32:36.000Z",
            "rescueAdminAt": "2026-10-22T12:32:36.000Z",
            "rescuePublicAt": "2026-11-14T12:32:36.000Z",
            "venue": {
              "id": 2,
              "kind": "QaFail",
              "name": "the QA test venue",
              "executor": "CADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMSST",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": true,
            "fallbackAllowed": false,
            "pool": null,
            "graduatedVenue": null,
            "refund": null,
            "failure": {"origin": 5, "code": 10502, "name": "ForcedFailure", "contract": "qa-exec-fail", "source": "simulated"},
            "actions": {
              "buy": false,
              "sell": false,
              "graduate": true,
              "graduateFallback": false,
              "markStuck": false,
              "rescue": false,
              "refund": false
            }
          },
          "quote": {"id": "USDC", "code": "USDC", "contract": "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"},
          "recipient": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "pendingTakeover": null,
          "creatorFees": "0",
          "rewards": {
            "sharing": true,
            "eligible": "5000000000000000",
            "queuedQuote": "0",
            "queuedToken": "0",
            "releasableFromLedger": null,
            "pendingQuote": null,
            "pendingToken": null
          },
          "you": null
        }
        """#

    /// Rescued: refunds at one fixed rate (testnet-qa).
    static let launchStateRescued = #"""
        {
          "status": {
            "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
            "phase": "rescued",
            "completedAt": "2026-09-13T14:32:36.000Z",
            "stuck": false,
            "stuckSince": "2026-09-14T14:32:36.000Z",
            "markStuckAt": null,
            "fallbackAt": null,
            "rescueAdminAt": null,
            "rescuePublicAt": null,
            "venue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": false,
            "fallbackAllowed": false,
            "pool": null,
            "graduatedVenue": null,
            "refund": {"quote": "432455532", "supply": "9000000000000000", "refunded": "1000", "rate": "0.000000048050614666"},
            "failure": null,
            "actions": {
              "buy": false,
              "sell": false,
              "graduate": false,
              "graduateFallback": false,
              "markStuck": false,
              "rescue": false,
              "refund": true
            }
          },
          "quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},
          "recipient": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "pendingTakeover": null,
          "creatorFees": "0",
          "rewards": {
            "sharing": true,
            "eligible": "5000000000000000",
            "queuedQuote": "0",
            "queuedToken": "0",
            "releasableFromLedger": null,
            "pendingQuote": "0",
            "pendingToken": "0"
          },
          "you": {"isRecipient": true, "creatorOwed": "0"}
        }
        """#

    /// Graduated, with rewards in both assets, an open takeover and owed fees.
    static let launchStateGraduated = #"""
        {
          "status": {
            "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
            "phase": "graduated",
            "completedAt": "2026-10-15T12:32:36.000Z",
            "stuck": false,
            "stuckSince": null,
            "markStuckAt": null,
            "fallbackAt": null,
            "rescueAdminAt": null,
            "rescuePublicAt": null,
            "venue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "fallback": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "venueLocked": false,
            "fallbackAllowed": false,
            "pool": "CAKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRK637",
            "graduatedVenue": {
              "id": 0,
              "kind": "Soroswap",
              "name": "Soroswap",
              "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
              "enabled": true,
              "feeFraction": 0
            },
            "refund": null,
            "failure": null,
            "actions": {
              "buy": false,
              "sell": false,
              "graduate": false,
              "graduateFallback": false,
              "markStuck": false,
              "rescue": false,
              "refund": false
            }
          },
          "quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},
          "recipient": "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
          "pendingTakeover": {
            "new": "GAFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWYPX",
            "effectiveAt": "2026-10-15T14:31:36.000Z",
            "expiresAt": "2026-10-15T15:32:36.000Z",
            "state": "open"
          },
          "creatorFees": "3900000",
          "rewards": {
            "sharing": true,
            "eligible": "5000000000000000",
            "queuedQuote": "10000",
            "queuedToken": "0",
            "releasableFromLedger": 5300200,
            "pendingQuote": "250000",
            "pendingToken": "7000000000"
          },
          "you": {"isRecipient": false, "creatorOwed": "1200000"}
        }
        """#

    /// A rescued launch's refund quote.
    static let launchQuoteRefund = #"""
        {"side": "refund", "quoteOut": "48050", "fees": "0", "rate": "0.000000048050614666"}
        """#

    /// A curve buy's quote.
    static let launchQuoteBuy = #"""
        {
          "side": "buy",
          "used": "500000000",
          "tokensOut": "11952000000000",
          "fees": "2000000",
          "baseFee": "1000000",
          "creatorFee": "1000000",
          "snipeFee": "0",
          "refund": "0"
        }
        """#

    /// Create: the 10 XLM fee and the first buy, the terms by value in the intent.
    static let launchPlanCreate = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000013",
          "kind": "launch_create",
          "expiresAt": "2026-10-15T14:47:36.511Z",
          "steps": [
            {
              "id": "s1",
              "label": "Launch ECAT on Soroswap",
              "status": "built",
              "intent": {
                "kind": "launch_create",
                "summary": "Launch ECAT on Soroswap for a 10 XLM fee and buy with 50 XLM",
                "spend": {"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC": "600000000"},
                "receive": {"CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY": "11880000000000"},
                "calls": [{"contract": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW", "fn": "launch"}],
                "display": {
                  "generation": 2,
                  "token": "CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY",
                  "name": "E2E Cat",
                  "symbol": "ECAT",
                  "quote": "XLM",
                  "quoteContract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "initialBuy": "500000000",
                  "minOut": "11880000000000",
                  "launchFee": "100000000",
                  "launchFeeAsset": "XLM",
                  "launchFeeTo": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW",
                  "launchFeeBooked": true,
                  "venue": "Soroswap",
                  "venueId": 0,
                  "venueKind": "Soroswap",
                  "fallbackVenue": "Soroswap",
                  "fallbackVenueId": 0,
                  "venueLocked": false,
                  "holderSharing": true,
                  "recipient": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
                  "exemptCount": 1,
                  "creatorFeeBps": 100,
                  "feeBps": 100,
                  "protocolShareBps": 5000,
                  "maxCreatorFeeBps": 1000,
                  "supply": "10000000000000000",
                  "phantom": "20000000000",
                  "threshold": "43245553200",
                  "snipeSchedule": "9800,2500,300,30",
                  "snipeStepSecs": 5,
                  "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
                  "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
                  "grace": 3600,
                  "fallbackDelay": 3600,
                  "rescueAdmin": 604800,
                  "rescuePublic": 2592000,
                  "lockedFallback": 86400,
                  "takeoverDelay": 259200,
                  "takeoverWindow": 259200,
                  "timelock": 172800,
                  "timelockWindow": 604800,
                  "harvestInterval": 3600
                },
                "terms": {
                  "supply": "10000000000000000",
                  "feeBps": 100,
                  "protocolShareBps": 5000,
                  "maxCreatorFeeBps": 1000,
                  "snipeSchedule": [9800, 2500, 300, 30],
                  "snipeStepSecs": 5,
                  "launchFee": "100000000",
                  "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
                  "phantom": "20000000000",
                  "threshold": "43245553200",
                  "venue": {
                    "id": 0,
                    "kind": "Soroswap",
                    "name": "Soroswap",
                    "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "fallback": {
                    "id": 0,
                    "kind": "Soroswap",
                    "name": "Soroswap",
                    "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                    "enabled": true,
                    "feeFraction": 0
                  },
                  "venueLocked": false,
                  "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
                  "tokenWasmHash": "0202020202020202020202020202020202020202020202020202020202020202",
                  "durations": {
                    "grace": 3600,
                    "fallbackDelay": 3600,
                    "rescueAdmin": 604800,
                    "rescuePublic": 2592000,
                    "lockedFallback": 86400,
                    "takeoverDelay": 259200,
                    "takeoverWindow": 259200,
                    "timelock": 172800,
                    "timelockWindow": 604800,
                    "harvestInterval": 3600
                  }
                }
              },
              "xdr": "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",
              "hash": "10167abbe06722d58c5bc018c7971b4760a4e1767e5f0a0b13d087d786167783",
              "builtAt": "2026-10-15T14:32:36.511Z",
              "stepKind": "launch_create",
              "maxFee": "4650100",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0
            }
          ],
          "fees": {"userMax": "4650100", "sponsored": false, "newReserves": 0}
        }
        """#

    /// A recipient change on a graduated launch without sharing: the harvest first, and the backlog (V7).
    static let launchPlanRecipient = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000013",
          "kind": "launch_recipient_transfer",
          "expiresAt": "2026-10-15T14:47:36.537Z",
          "steps": [
            {
              "id": "s1",
              "label": "Collect ECAT's pool fees first",
              "status": "built",
              "intent": {
                "kind": "launch_harvest",
                "summary": "Collect ECAT's pool fees before its fee recipient changes",
                "spend": {},
                "calls": [{"contract": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ", "fn": "harvest"}],
                "display": {
                  "generation": 2,
                  "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
                  "symbol": "ECAT",
                  "quote": "XLM",
                  "pool": "CAKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRK637",
                  "estQuote": "4997",
                  "estToken": "19988",
                  "protocolShareBps": 5000,
                  "holderSharing": false
                }
              },
              "xdr": "AAAAAgAAAACKiOPddAnxlf1S2y08ul1yymcJvx2UEhvzdIgBtA9vXABG9HQAToEGAAAAAwAAAAEAAAAAAAAAAAAAAABq0OZcAAAAAAAAAAEAAAAAAAAAGAAAAAAAAAABAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAAAAHaGFydmVzdAAAAAABAAAAEgAAAAEVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFQAAAAAAAAABAAAAAAAAAAAAAAAAABSZcAAACJgAAAiYAAAAAABG9BAAAAAA",
              "hash": "0479f629166f65e4eb0ebb6f473180f3772273cb0579b42e7134c50cadd32890",
              "builtAt": "2026-10-15T14:32:36.537Z",
              "maxFee": "4650100",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0
            },
            {
              "id": "s2",
              "label": "Hand ECAT's creator fees to GDWU…DIAG",
              "status": "pending",
              "maxFee": "30000000",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0
            }
          ],
          "fees": {"userMax": "34650100", "sponsored": false, "newReserves": 0},
          "harvestBacklog": {
            "residualQuote": "22251",
            "residualToken": "89005",
            "growthQuote": "44502",
            "growthToken": "178010",
            "roundsToDrain": 10,
            "nextHarvestAt": "2026-10-15T15:32:36.000Z",
            "drainedBy": "2026-10-16T00:32:36.000Z"
          }
        }
        """#

    /// A refund: the tokens burned at the fixed rate.
    static let launchPlanRefund = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000013",
          "kind": "launch_refund",
          "expiresAt": "2026-10-15T14:47:36.468Z",
          "steps": [
            {
              "id": "s1",
              "label": "Refund ECAT",
              "status": "built",
              "intent": {
                "kind": "launch_refund",
                "summary": "Refund: 0.004805 XLM for 100000 ECAT, no fees",
                "spend": {"CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5": "1000000000000"},
                "calls": [{"contract": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW", "fn": "refund"}],
                "display": {
                  "generation": 2,
                  "token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
                  "symbol": "ECAT",
                  "quote": "XLM",
                  "amount": "1000000000000",
                  "quoteOut": "48050",
                  "rate": "0.000000048050614666",
                  "burned": true,
                  "fees": "0"
                }
              },
              "xdr": "AAAAAgAAAACKiOPddAnxlf1S2y08ul1yymcJvx2UEhvzdIgBtA9vXABG9HQAToEGAAAAAwAAAAEAAAAAAAAAAAAAAABq0OZcAAAAAAAAAAEAAAAAAAAAGAAAAAAAAAABBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQAAAAGcmVmdW5kAAAAAAADAAAAEgAAAAAAAAAAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1wAAAASAAAAARQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUAAAACgAAAAAAAAAAAAAA6NSlEAAAAAABAAAAAAAAAAAAAAABBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQAAAAGcmVmdW5kAAAAAAADAAAAEgAAAAAAAAAAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1wAAAASAAAAARQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUAAAACgAAAAAAAAAAAAAA6NSlEAAAAAABAAAAAAAAAAEUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFAAAAARidXJuAAAAAgAAABIAAAAAAAAAAIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29cAAAACgAAAAAAAAAAAAAA6NSlEAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAUmXAAAAiYAAAImAAAAAAARvQQAAAAAA==",
              "hash": "34f9c3c75769f810ba0e4600e24934c7efb2ff3a98b1a1f4a57c0a318fca470f",
              "builtAt": "2026-10-15T14:32:36.467Z",
              "maxFee": "4650100",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0
            }
          ],
          "fees": {"userMax": "4650100", "sponsored": false, "newReserves": 0}
        }
        """#

    /// Collecting until its deadline.
    static let momentStatusCollecting = #"""
        {
          "generation": 2,
          "nft": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
          "creator": "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "pool": null,
          "state": "collecting",
          "price": "10000000",
          "threshold": "100000000",
          "reserve": "7500000",
          "totalGross": "10000000",
          "progress": 0.075,
          "collects": 1,
          "editions": 1,
          "entitlements": "2000000000",
          "creatorAllocBps": 0,
          "creatorBps": 2000,
          "platformBps": 500,
          "reserveBps": 7500,
          "expiryCreatorBps": 7000,
          "royaltyBps": 500,
          "rate": {"num": "75000000000000000000000", "den": "17500000000000000"},
          "publishedAt": "2026-10-14T12:00:00.000Z",
          "deadline": "2026-10-16T12:00:00.000Z",
          "completedAt": null,
          "stuckSince": null,
          "graduatedAt": null,
          "endedAt": null,
          "expiresAt": "2026-10-16T12:00:00.000Z",
          "expiresBy": "deadline",
          "backstopAt": null,
          "failureExpiresAt": null,
          "expirable": false,
          "graduatable": false,
          "failure": null,
          "proceeds": {"creator": "0", "platform": "0", "treasury": "0"}
        }
        """#

    /// Pending graduation with no recorded failure: it expires at the backstop (V11, testnet-qa).
    static let momentStatusPending = #"""
        {
          "generation": 2,
          "nft": "CAKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRK637",
          "creator": "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "pool": null,
          "state": "graduation_pending",
          "price": "10000000",
          "threshold": "100000000",
          "reserve": "100000000",
          "totalGross": "133333334",
          "progress": 1,
          "collects": 4,
          "editions": 14,
          "entitlements": "0",
          "creatorAllocBps": 1000,
          "creatorBps": 2000,
          "platformBps": 500,
          "reserveBps": 7500,
          "expiryCreatorBps": 7000,
          "royaltyBps": 500,
          "rate": {"num": "67500000000000000000000", "den": "17500000000000000"},
          "publishedAt": "2026-10-13T11:00:00.000Z",
          "deadline": "2026-10-15T11:00:00.000Z",
          "completedAt": "2026-10-15T10:00:00.000Z",
          "stuckSince": null,
          "graduatedAt": null,
          "endedAt": null,
          "expiresAt": "2026-11-14T10:00:00.000Z",
          "expiresBy": "backstop",
          "backstopAt": "2026-11-14T10:00:00.000Z",
          "failureExpiresAt": null,
          "expirable": false,
          "graduatable": true,
          "failure": null,
          "proceeds": {"creator": "0", "platform": "0", "treasury": "0"}
        }
        """#

    /// A recorded failed graduation, named: it expires 7 days after it (V10, testnet-qa).
    static let momentStatusFailed = #"""
        {
          "generation": 2,
          "nft": "CAKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRKFIVCUKRK637",
          "creator": "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "pool": null,
          "state": "graduation_pending",
          "price": "10000000",
          "threshold": "100000000",
          "reserve": "100000000",
          "totalGross": "133333334",
          "progress": 1,
          "collects": 4,
          "editions": 14,
          "entitlements": "0",
          "creatorAllocBps": 1000,
          "creatorBps": 2000,
          "platformBps": 500,
          "reserveBps": 7500,
          "expiryCreatorBps": 7000,
          "royaltyBps": 500,
          "rate": {"num": "67500000000000000000000", "den": "17500000000000000"},
          "publishedAt": "2026-10-13T11:00:00.000Z",
          "deadline": "2026-10-15T11:00:00.000Z",
          "completedAt": "2026-10-15T10:00:00.000Z",
          "stuckSince": "2026-10-15T11:00:00.000Z",
          "graduatedAt": null,
          "endedAt": null,
          "expiresAt": "2026-10-22T11:00:00.000Z",
          "expiresBy": "failure",
          "backstopAt": "2026-11-14T10:00:00.000Z",
          "failureExpiresAt": "2026-10-22T11:00:00.000Z",
          "expirable": false,
          "graduatable": true,
          "failure": {"origin": 10, "code": 11003, "name": "GraduationInvalid", "source": "moments-graduator", "seen": "recorded"},
          "proceeds": {"creator": "0", "platform": "0", "treasury": "0"}
        }
        """#

    /// Graduated, with its pool and the creator's proceeds.
    static let momentStatusGraduated = #"""
        {
          "generation": 2,
          "nft": "CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY",
          "creator": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "pool": "CAPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4QTN",
          "state": "graduated",
          "price": "10000000",
          "threshold": "100000000",
          "reserve": "0",
          "totalGross": "0",
          "progress": 1,
          "collects": 0,
          "editions": 0,
          "entitlements": "0",
          "creatorAllocBps": 1000,
          "creatorBps": 2000,
          "platformBps": 500,
          "reserveBps": 7500,
          "expiryCreatorBps": 7000,
          "royaltyBps": 500,
          "rate": {"num": "67500000000000000000000", "den": "17500000000000000"},
          "publishedAt": "2026-09-03T12:00:00.000Z",
          "deadline": "2026-09-05T12:00:00.000Z",
          "completedAt": "2026-09-14T11:59:00.000Z",
          "stuckSince": null,
          "graduatedAt": "2026-09-14T12:00:00.000Z",
          "endedAt": "2026-09-14T12:00:00.000Z",
          "expiresAt": null,
          "expiresBy": null,
          "backstopAt": null,
          "failureExpiresAt": null,
          "expirable": false,
          "graduatable": false,
          "failure": null,
          "proceeds": {"creator": "5000000", "platform": "0", "treasury": "0"}
        }
        """#

    /// Expired while collecting.
    static let momentStatusExpired = #"""
        {
          "generation": 2,
          "nft": "CALROFYXC4LROFYXC4LROFYXC4LROFYXC4LROFYXC4LROFYXC4LROBL2",
          "creator": "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "pool": null,
          "state": "expired",
          "price": "10000000",
          "threshold": "100000000",
          "reserve": "0",
          "totalGross": "0",
          "progress": 0,
          "collects": 0,
          "editions": 0,
          "entitlements": "0",
          "creatorAllocBps": 0,
          "creatorBps": 2000,
          "platformBps": 500,
          "reserveBps": 7500,
          "expiryCreatorBps": 7000,
          "royaltyBps": 500,
          "rate": {"num": "75000000000000000000000", "den": "17500000000000000"},
          "publishedAt": "2026-10-03T12:00:00.000Z",
          "deadline": "2026-10-05T12:00:00.000Z",
          "completedAt": null,
          "stuckSince": null,
          "graduatedAt": null,
          "endedAt": "2026-10-06T12:00:00.000Z",
          "expiresAt": null,
          "expiresBy": null,
          "backstopAt": null,
          "failureExpiresAt": null,
          "expirable": false,
          "graduatable": false,
          "failure": null,
          "proceeds": {"creator": "0", "platform": "0", "treasury": "0"}
        }
        """#

    /// The creator's and a collector's coins one period after graduation.
    static let momentVesting = #"""
        {
          "generation": 2,
          "nft": "CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY",
          "account": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "state": "graduated",
          "vests": true,
          "vestPeriodSecs": 2592000,
          "startsAt": "2026-09-14T12:00:00.000Z",
          "periodsElapsed": 1,
          "claimable": {"collector": "200000000", "creator": "16000000000000", "total": "16000200000000"},
          "collector": {
            "total": "1000000000",
            "claimed": "600000000",
            "claimable": "200000000",
            "vested": "800000000",
            "tranches": [
              {"period": 0, "at": "2026-09-14T12:00:00.000Z", "vestedBps": 6000, "vested": "600000000"},
              {"period": 1, "at": "2026-10-14T12:00:00.000Z", "vestedBps": 8000, "vested": "800000000"},
              {"period": 2, "at": "2026-11-13T12:00:00.000Z", "vestedBps": 10000, "vested": "1000000000"}
            ],
            "nextAt": "2026-11-13T12:00:00.000Z",
            "fullAt": "2026-11-13T12:00:00.000Z"
          },
          "creator": {
            "total": "100000000000000",
            "claimed": "20000000000000",
            "claimable": "16000000000000",
            "vested": "36000000000000",
            "tranches": [
              {"period": 0, "at": "2026-09-14T12:00:00.000Z", "vestedBps": 2000, "vested": "20000000000000"},
              {"period": 1, "at": "2026-10-14T12:00:00.000Z", "vestedBps": 3600, "vested": "36000000000000"},
              {"period": 2, "at": "2026-11-13T12:00:00.000Z", "vestedBps": 5200, "vested": "52000000000000"},
              {"period": 3, "at": "2026-12-13T12:00:00.000Z", "vestedBps": 6800, "vested": "68000000000000"},
              {"period": 4, "at": "2027-01-12T12:00:00.000Z", "vestedBps": 8400, "vested": "84000000000000"},
              {"period": 5, "at": "2027-02-11T12:00:00.000Z", "vestedBps": 10000, "vested": "100000000000000"}
            ],
            "nextAt": "2026-11-13T12:00:00.000Z",
            "fullAt": "2027-02-11T12:00:00.000Z"
          }
        }
        """#

    /// Every tranche vested, both sides (testnet-qa's 10-minute periods reach it).
    static let momentVestingFull = #"""
        {
          "generation": 2,
          "nft": "CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY",
          "account": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
          "coin": "CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6",
          "state": "graduated",
          "vests": true,
          "vestPeriodSecs": 2592000,
          "startsAt": "2026-09-14T12:00:00.000Z",
          "periodsElapsed": 5,
          "claimable": {"collector": "400000000", "creator": "80000000000000", "total": "80000400000000"},
          "collector": {
            "total": "1000000000",
            "claimed": "600000000",
            "claimable": "400000000",
            "vested": "1000000000",
            "tranches": [
              {"period": 0, "at": "2026-09-14T12:00:00.000Z", "vestedBps": 6000, "vested": "600000000"},
              {"period": 1, "at": "2026-10-14T12:00:00.000Z", "vestedBps": 8000, "vested": "800000000"},
              {"period": 2, "at": "2026-11-13T12:00:00.000Z", "vestedBps": 10000, "vested": "1000000000"}
            ],
            "nextAt": null,
            "fullAt": "2026-11-13T12:00:00.000Z"
          },
          "creator": {
            "total": "100000000000000",
            "claimed": "20000000000000",
            "claimable": "80000000000000",
            "vested": "100000000000000",
            "tranches": [
              {"period": 0, "at": "2026-09-14T12:00:00.000Z", "vestedBps": 2000, "vested": "20000000000000"},
              {"period": 1, "at": "2026-10-14T12:00:00.000Z", "vestedBps": 3600, "vested": "36000000000000"},
              {"period": 2, "at": "2026-11-13T12:00:00.000Z", "vestedBps": 5200, "vested": "52000000000000"},
              {"period": 3, "at": "2026-12-13T12:00:00.000Z", "vestedBps": 6800, "vested": "68000000000000"},
              {"period": 4, "at": "2027-01-12T12:00:00.000Z", "vestedBps": 8400, "vested": "84000000000000"},
              {"period": 5, "at": "2027-02-11T12:00:00.000Z", "vestedBps": 10000, "vested": "100000000000000"}
            ],
            "nextAt": null,
            "fullAt": "2027-02-11T12:00:00.000Z"
          }
        }
        """#

    /// Publish: every term the phone's guard compares, on display.
    static let momentPlanPublish = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000014",
          "kind": "moment_publish",
          "expiresAt": "2026-10-15T12:15:00.000Z",
          "steps": [
            {
              "id": "s1",
              "label": "Publish DUSK",
              "status": "built",
              "intent": {
                "kind": "moment_publish",
                "summary": "Publish Dusk ($DUSK) at 1 USDC an edition",
                "spend": {},
                "calls": [{"contract": "CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U", "fn": "publish"}],
                "display": {
                  "generation": 2,
                  "nft": "CACB5AH45XMW4BHBYUUPEEZDMXGX5LBBBMSZRBS7YUUXGGQLZVM7FN7Z",
                  "coin": "CBEEYJQJF3KCSHZISRFMHPZIGYPBINQKBCKMSUNJOLUGUWTRGRLZ3YD2",
                  "name": "Dusk",
                  "symbol": "DUSK",
                  "uri": "https://example.supabase.co/storage/v1/object/public/lite-media/moments/GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR/41019444-f54f-4a9e-ac88-2667a92257fa.json",
                  "mediaHash": "4b0a20386788fafe8088bf8010e58af8721da412042aa8a8a9f43ca4d02a3b0f",
                  "place": "Accra",
                  "date": "2026-10-14",
                  "price": "10000000",
                  "quote": "USDC",
                  "allocationBps": 1000,
                  "windowSecs": 86400,
                  "nonce": "14036073244315995067",
                  "completionGross": "133333334",
                  "fdvAtOpen": "259259259",
                  "threshold": "100000000",
                  "minPrice": "1000000",
                  "creatorBps": 2000,
                  "platformBps": 500,
                  "reserveBps": 7500,
                  "maxCreatorAllocBps": 1000,
                  "expiryCreatorBps": 7000,
                  "royaltyBps": 500,
                  "platform": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
                  "treasury": "GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK",
                  "externalBase": "https://dyorhq.fun/moments/",
                  "nftWasmHash": "0606060606060606060606060606060606060606060606060606060606060606",
                  "coinWasmHash": "0707070707070707070707070707070707070707070707070707070707070707",
                  "graduator": "CABQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGCK3",
                  "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
                  "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
                  "vestPeriod": 2592000,
                  "stuckExpiry": 604800,
                  "pendingBackstop": 2592000,
                  "timelock": 172800,
                  "timelockWindow": 604800,
                  "minWindow": 3600,
                  "maxWindow": 2592000,
                  "harvestInterval": 3600,
                  "harvestBps": 6667,
                  "harvestCreatorBps": 4000
                }
              },
              "xdr": "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",
              "hash": "2e6a1093d46d8ed0f036b93ff1d19a2cd1092ce648f525486b48dd452490e656",
              "maxFee": "51250",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0,
              "stepKind": "moment_publish"
            }
          ],
          "fees": {"userMax": "0", "sponsored": false, "newReserves": 0}
        }
        """#

    /// Collect: max_total in USDC.
    static let momentPlanCollect = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000014",
          "kind": "moment_collect",
          "expiresAt": "2026-10-15T12:15:00.000Z",
          "steps": [
            {
              "id": "s1",
              "label": "Collect 3",
              "status": "built",
              "intent": {
                "kind": "moment_collect",
                "summary": "Collect 3 for 3 USDC",
                "spend": {"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA": "30000000"},
                "calls": [{"contract": "CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U", "fn": "collect"}],
                "display": {
                  "generation": 2,
                  "nft": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5",
                  "quantity": 3,
                  "editions": 3,
                  "total": "30000000",
                  "quote": "USDC",
                  "entitlement": "6000000000",
                  "terminal": false
                }
              },
              "xdr": "AAAAAgAAAACKiOPddAnxlf1S2y08ul1yymcJvx2UEhvzdIgBtA9vXAAAyDIAToEGAAAAAwAAAAEAAAAAAAAAAAAAAABq0OZ9AAAAAAAAAAEAAAAAAAAAGAAAAAAAAAABBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUAAAAHY29sbGVjdAAAAAAEAAAAEgAAAAAAAAAAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1wAAAASAAAAARQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUAAAAAwAAAAMAAAAKAAAAAAAAAAAAAAAAAcnDgAAAAAEAAAAAAAAAAAAAAAEFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQAAAAdjb2xsZWN0AAAAAAQAAAASAAAAAAAAAACKiOPddAnxlf1S2y08ul1yymcJvx2UEhvzdIgBtA9vXAAAABIAAAABFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQAAAADAAAAAwAAAAoAAAAAAAAAAAAAAAABycOAAAAAAQAAAAAAAAABUEXNXsBymnaP1a0CUFhS308Cjc6DDlrFIgm6SEg7LwEAAAAIdHJhbnNmZXIAAAADAAAAEgAAAAAAAAAAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1wAAAASAAAAAQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFAAAACgAAAAAAAAAAAAAAAAHJw4AAAAAAAAAAAQAAAAAAAAAAAAAAAAAUmXAAAAiYAAAImAAAAAAAAMfOAAAAAA==",
              "hash": "00108b5c3b6be4c8fe879a459abc493c0a7ab2106121ed165da8e0240bf0429d",
              "maxFee": "51250",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0,
              "stepKind": "moment_collect"
            }
          ],
          "fees": {"userMax": "0", "sponsored": false, "newReserves": 0}
        }
        """#

    /// Claim all: Moments with nothing due left out.
    static let momentPlanClaimAll = #"""
        {
          "planId": "5b0d7f8e-1c2a-4e3b-9f6d-000000000014",
          "kind": "moment_claim_all",
          "expiresAt": "2026-10-15T12:15:00.000Z",
          "steps": [
            {
              "id": "s1",
              "label": "Claim coins from 1 Moment",
              "status": "built",
              "intent": {
                "kind": "moment_claim_all",
                "summary": "Claim 1600020 vested coins from 1 Moment",
                "spend": {},
                "calls": [{"contract": "CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U", "fn": "claim_all"}],
                "display": {
                  "generation": 2,
                  "moments": 1,
                  "nfts": "CALBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBMFQWCYLBNOTY",
                  "total": "16000200000000"
                }
              },
              "xdr": "AAAAAgAAAACKiOPddAnxlf1S2y08ul1yymcJvx2UEhvzdIgBtA9vXAAAyDIAToEGAAAAAwAAAAEAAAAAAAAAAAAAAABq0OZ9AAAAAAAAAAEAAAAAAAAAGAAAAAAAAAABBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUAAAAJY2xhaW1fYWxsAAAAAAAAAgAAABIAAAAAAAAAAIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29cAAAAEAAAAAEAAAABAAAAEgAAAAEWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFgAAAAEAAAAAAAAAAAAAAAEFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQAAAAljbGFpbV9hbGwAAAAAAAACAAAAEgAAAAAAAAAAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1wAAAAQAAAAAQAAAAEAAAASAAAAARYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWAAAAAAAAAAEAAAAAAAAAAAAAAAAAFJlwAAAImAAACJgAAAAAAADHzgAAAAA=",
              "hash": "742146dc3f390cd5d8e492e08926cce277ef4b5c15a3562e0c0b763b24d0eb8b",
              "maxFee": "51250",
              "feePayer": "user",
              "sponsorReason": null,
              "reserveDelta": 0
            }
          ],
          "fees": {"userMax": "0", "sponsored": false, "newReserves": 0}
        }
        """#
}
