import BigInt
import Foundation

/* Where a DyorHQ coin trades, as its own factory's record says, and nothing else: a DyorHQ coin is never priced from any
   other pool, so a thin pool anyone plants beside it can't move its price. `PriceService` reads the record (re-read every
   30 minutes, and every minute while a curve or a collecting Moment can still graduate), then the venue, and turns the
   price into dollars at the same block:

     | Venue           | When                               | Read                                              |
     |-----------------|------------------------------------|---------------------------------------------------|
     | Curve           | bonding, migrating or refund       | the curve's `getReserves()` (unchanged by `sweep`) |
     | Monday pool     | graduated on Monday Trade          | the pool's own `slot0()`                           |
     | Uniswap v4 pool | graduated on Uniswap v4            | the stack's PoolManager `extsload(slot0(poolId))`  |
     | Moment pool     | a graduated Moment                 | the cohort's PoolManager `extsload` of its pool    |
     | none            | a Moment still collecting          | no price: "Not trading yet"                       |

   Its pair asset becomes dollars at the same block: MON (and WMON) through MON's own price, USDC and AUSD at $1, aBIL
   through its own pool. The 24h change resolves the venue again at the true day-ago block (`BlockClock`): a coin its
   factory hadn't recorded then is "New". */

/// One DyorHQ coin's market, from its factory's record at one block.
struct DyorListing: Hashable, Sendable {
    /// Which factory recorded the coin.
    enum Origin: Hashable, Sendable {
        /// A launchpad stack's coin.
        case launch(LaunchpadAddresses)
        /// A cohort's Moment `id`.
        case moment(MomentsAddresses, id: BigUInt)
    }

    /// Where it trades.
    enum Venue: Hashable, Sendable {
        /// Its bonding curve (bonding, migrating or refund).
        case curve(Address)
        /// Its Monday Trade pool, paired with WMON for a MON launch.
        case monday(pool: Address)
        /// Its Uniswap v4 pool in `poolManager`, paired with native MON (address 0) or its pair token.
        case v4(poolManager: Address, poolId: Data)
        /// A graduated Moment's v4 pool against its cohort's USDC.
        case moment(poolManager: Address, poolId: Data, usdcIs0: Bool)
        /// A Moment still collecting, or waiting to graduate: no pool yet.
        case collecting
        /// No market the app can price: a Moment that expired, a graduated launch with no pool recorded, or a pair asset
        /// the app can't value.
        case closed
    }

    let coin: Address
    let origin: Origin
    let venue: Venue
    /// What it trades against: address 0 for MON.
    let pair: Address
    /// When it graduated (seconds since 1970); nil while it hasn't. A chart's earlier samples read a launch's curve.
    let graduatedAt: Int?
    /// A launch's curve, which priced it before it graduated; nil for a Moment.
    let curve: Address?

    /// The label a price from this venue carries (`PriceInfo.source`).
    var label: String {
        switch venue {
        case .curve: return DyorListing.curveLabel
        case .monday: return DyorListing.mondayLabel
        case .v4: return DyorListing.v4Label
        case .moment: return DyorListing.momentLabel
        case .collecting, .closed: return "DyorHQ"
        }
    }

    // not localized: identifiers (`PriceInfo.source`), never shown; `PriceInfo.sourceLine` names the venue
    static let curveLabel = "DyorHQ curve"
    static let mondayLabel = "Monday Trade"
    static let v4Label = "Uniswap v4"
    static let momentLabel = "DyorHQ Moment pool"

    /// Whether its market is final: a pool, or none ever (`closed`). A curve graduates into a pool, and a collecting
    /// Moment graduates or expires, so `PriceService` reads their records again within a minute
    /// (`PoolLookupCache.unsettledTTL`) rather than after 30.
    var isSettled: Bool {
        switch venue {
        case .monday, .v4, .moment, .closed: return true
        case .curve, .collecting: return false
        }
    }

    /// Whether the venue has a price to read.
    var isPriced: Bool {
        switch venue {
        case .curve, .monday, .v4, .moment: return true
        case .collecting, .closed: return false
        }
    }

    // MARK: Pair assets

    /// The pair assets the app can turn into dollars, with their symbols and decimals: MON (address 0, and WMON), USDC,
    /// AUSD and aBIL. Nil for any other.
    static func pairAsset(_ pair: Address) -> (symbol: String, decimals: Int)? {
        if pair.isZero || pair == Monad.wmon { return (Monad.nativeSymbol, 18) }
        guard pair == Monad.usdc || pair == Monad.ausd || pair == Token.abil.address, let token = Token.core(pair) else { return nil }
        return (token.symbol, token.decimals)
    }

    /// The pair asset's dollar price at the block read: MON and WMON at `mon`, USDC and AUSD at 1, aBIL at `abil`.
    static func pairUSD(_ pair: Address, mon: Double?, abil: Double?) -> Double? {
        if pair.isZero || pair == Monad.wmon { return mon }
        if pair == Monad.usdc || pair == Monad.ausd { return 1 }
        if pair == Token.abil.address { return abil }
        return nil
    }

    // MARK: Reads

    /// The read that prices it now, or at a chart sample taken at `time` (seconds since 1970): before a launch graduated,
    /// its curve; before a Moment graduated, nothing. Nil when there is no price to read.
    func priceCall(at time: Int? = nil) -> ContractCall? {
        if let time, let graduatedAt, time < graduatedAt {
            guard let curve else { return nil }
            return LaunchpadABI.call(curve, LaunchpadABI.Curve.getReserves, returns: "uint256,uint256")
        }
        return Self.priceCall(venue)
    }

    static func priceCall(_ venue: Venue) -> ContractCall? {
        switch venue {
        case .curve(let curve):
            return LaunchpadABI.call(curve, LaunchpadABI.Curve.getReserves, returns: "uint256,uint256")
        case .monday(let pool):
            return LaunchpadABI.call(pool, "slot0()", returns: "bytes32")
        case .v4(let poolManager, let poolId):
            return LaunchpadABI.call(poolManager, LaunchpadABI.PoolManager.extsload, [.bytes(LaunchpadABI.slot0(of: poolId))], returns: "bytes32")
        case .moment(let poolManager, let poolId, _):
            return MomentsABI.call(poolManager, MomentsABI.PoolManager.extsload, [.bytes(MomentsABI.slot0(of: poolId))], returns: "bytes32")
        case .collecting, .closed:
            return nil
        }
    }

    /// The price in pair units per whole coin from `priceCall(at:)`'s answer, in floating point so a tiny price keeps
    /// its digits (a USDC curve's `price()` rounds to whole micro-dollars per 1e18 units); nil for an empty curve or an
    /// uninitialised pool.
    func pairPrice(_ values: [ABIValue], at time: Int? = nil) -> Double? {
        guard let pairAsset = Self.pairAsset(pair) else { return nil }
        if let time, let graduatedAt, time < graduatedAt { return Self.curvePrice(values, pairDecimals: pairAsset.decimals) }
        switch venue {
        case .curve:
            return Self.curvePrice(values, pairDecimals: pairAsset.decimals)
        case .monday:
            // Monday pairs a MON launch with WMON; token0 is the lower address.
            let quote = pair.isZero ? Monad.wmon : pair
            return Self.poolPrice(values, coin: coin, quote: quote, pairDecimals: pairAsset.decimals)
        case .v4:
            return Self.poolPrice(values, coin: coin, quote: pair, pairDecimals: pairAsset.decimals)
        case .moment(_, _, let usdcIs0):
            guard let sqrt = Self.sqrtPrice(values) else { return nil }
            return MomentsMath.usdcPerCoin(sqrtPriceX96: sqrt, usdcIs0: usdcIs0)
        case .collecting, .closed:
            return nil
        }
    }

    /// `getReserves()` (quote, tokens) as pair units per whole coin.
    static func curvePrice(_ values: [ABIValue], pairDecimals: Int) -> Double? {
        guard values.count >= 2, let quote = values[0].uintOrNil, let tokens = values[1].uintOrNil, tokens > 0 else { return nil }
        return Double(quote) / Double(tokens) * pow(10, Double(18 - pairDecimals))
    }

    /// A pool slot's word as pair units per whole coin; the lower address of `coin` and `quote` is currency0.
    static func poolPrice(_ values: [ABIValue], coin: Address, quote: Address, pairDecimals: Int) -> Double? {
        guard let sqrt = sqrtPrice(values) else { return nil }
        let token0 = BigUInt(coin.data) < BigUInt(quote.data) ? coin : quote
        return PriceService.price(sqrtPriceX96: sqrt, token: coin, token0: token0, tokenDecimals: 18, quoteDecimals: pairDecimals)
    }

    /// The sqrt price in a slot0 word's low 160 bits; nil for an uninitialised pool.
    static func sqrtPrice(_ values: [ABIValue]) -> BigUInt? {
        guard case .bytes(let word)? = values.first else { return nil }
        let sqrt = BigUInt(word) & ((BigUInt(1) << 160) - 1)
        return sqrt > 0 ? sqrt : nil
    }

    // MARK: Records

    /// What a factory's records say of a coin at one block.
    enum Record: Hashable, Sendable {
        /// Its market then.
        case listed(DyorListing)
        /// Its factory hadn't recorded it yet: a coin younger than that block ("New").
        case notYet
        /// No DyorHQ factory recorded it: every factory answered, none naming it.
        case notDyor
        /// A read that failed, or a record that disagrees with itself: nothing is known.
        case unread
    }

    /// The calls that find which factory recorded `coin`, when nothing says so yet: each launchpad's `getLaunchedToken`,
    /// in its own layout, then each cohort's `momentIdByCoin`.
    static func originCalls(_ coin: Address, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses]) -> [ContractCall] {
        launchpads.map { launchRecordCall(coin, stack: $0) }
            + cohorts.map { MomentsABI.call($0.factory, MomentsABI.Factory.momentIdByCoin, [.address(coin)], returns: "uint256") }
    }

    /// What `originCalls`' answers say: a launch's record decides at once (`record`), as does every factory answering
    /// without naming the coin (`notDyor`); a Moment id names the cohort and Moment whose records are read next (`moment`).
    enum Origins: Hashable, Sendable {
        case record(Record)
        case moment(MomentsAddresses, id: BigUInt)
    }

    static func origins(_ coin: Address, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses], answers: [Result<[ABIValue], Error>]) -> Origins {
        guard answers.count == launchpads.count + cohorts.count else { return .record(.unread) }
        let records = Array(answers.prefix(launchpads.count))
        var complete = records.allSatisfy { if case .success(let values) = $0 { return !values.isEmpty } else { return false } }
        if let hit = LaunchpadService.firstRecord(stacks: launchpads, records: records) {
            // A record naming another coin is a node behind, or a factory answering wrongly: never this coin's market.
            return .record(hit.record.token == coin ? launch(coin, stack: hit.stack, record: hit.record) : .unread)
        }
        for (cohort, answer) in zip(cohorts, answers.dropFirst(launchpads.count)) {
            guard case .success(let values) = answer, let id = values.first?.uintOrNil else { complete = false; continue }
            if id > 0 { return .moment(cohort, id: id) }
        }
        return .record(complete ? .notDyor : .unread)
    }

    /// The calls that read `coin`'s record at one block, its factory known: a launch's `getLaunchedToken`; a Moment's
    /// cohort count, `getMoment`, `isGraduated`, graduation `record` and `ledger`.
    static func recordCalls(_ coin: Address, origin: Origin) -> [ContractCall] {
        switch origin {
        case .launch(let stack):
            return [launchRecordCall(coin, stack: stack)]
        case .moment(let cohort, let id):
            return [
                MomentsABI.call(cohort.factory, MomentsABI.Factory.momentCount, returns: "uint256"),
                MomentsABI.call(cohort.factory, MomentsABI.Factory.getMoment, [.uint(id)], returns: MomentsABI.momentTuple),
                MomentsABI.call(cohort.graduation, MomentsABI.Graduation.isGraduated, [.uint(id)], returns: "bool"),
                MomentsABI.call(cohort.graduation, MomentsABI.Graduation.record, [.uint(id)], returns: MomentsABI.recordTuple),
                MomentsABI.call(cohort.collect, MomentsABI.Collect.ledger, [.uint(id)], returns: MomentsABI.ledgerTuple),
            ]
        }
    }

    /// What `recordCalls`' answers say.
    static func record(_ coin: Address, origin: Origin, answers: [Result<[ABIValue], Error>]) -> Record {
        switch origin {
        case .launch(let stack):
            guard answers.count == 1, case .success(let values) = answers[0], let tuple = values.first else { return .unread }
            let record = LaunchpadABI.LaunchRecord(tuple, legacy: stack.generation.legacyRecord)
            guard record.exists else { return .notYet }
            return record.token == coin ? launch(coin, stack: stack, record: record) : .unread
        case .moment(let cohort, let id):
            return moment(coin, cohort: cohort, id: id, answers: answers)
        }
    }

    /// The market a launch record names: its curve until it graduates, then the pool its venue recorded.
    static func launch(_ coin: Address, stack: LaunchpadAddresses, record: LaunchpadABI.LaunchRecord) -> Record {
        guard record.exists, record.token == coin, !record.curve.isZero else { return .unread }
        var venue: Venue
        var graduatedAt: Int?
        switch record.phase {
        case .graduated:
            graduatedAt = record.sweptAt > 0 ? record.sweptAt : nil
            if record.graduationVenue == .monday {
                let pool = Address(data: record.poolId.suffix(20)) ?? .zero
                venue = pool.isZero ? .closed : .monday(pool: pool)
            } else {
                venue = stack.poolManager.isZero ? .closed : .v4(poolManager: stack.poolManager, poolId: record.poolId)
            }
        case .bonding, .migrating, .refund:
            venue = .curve(record.curve)
        }
        if pairAsset(record.pairToken) == nil { venue = .closed }
        return .listed(DyorListing(coin: coin, origin: .launch(stack), venue: venue, pair: record.pairToken, graduatedAt: graduatedAt, curve: record.curve))
    }

    /// The market a Moment's records name: its pool once graduated (a key that isn't this coin's and the cohort's USDC is
    /// refused), none while it collects, none ever once it expired.
    static func moment(_ coin: Address, cohort: MomentsAddresses, id: BigUInt, answers: [Result<[ABIValue], Error>]) -> Record {
        guard answers.count == 5, case .success(let countValues) = answers[0], let count = countValues.first?.uintOrNil else { return .unread }
        guard count >= id else { return .notYet }
        guard case .success(let momentValues) = answers[1], let tuple = momentValues.first,
              case .success(let graduatedValues) = answers[2], case .bool(let graduated)? = graduatedValues.first else { return .unread }
        guard MomentsABI.moment(id: id, tuple, factory: cohort.factory).coin == coin else { return .notDyor }
        let venue: Venue
        var graduatedAt: Int?
        if graduated {
            guard case .success(let recordValues) = answers[3], let recordTuple = recordValues.first else { return .unread }
            let record = MomentsABI.record(recordTuple)
            let key = record.key
            guard Set([key.currency0, key.currency1]) == Set([coin, cohort.usdc]) else { return .listed(DyorListing(coin: coin, origin: .moment(cohort, id: id), venue: .closed, pair: cohort.usdc, graduatedAt: nil, curve: nil)) }
            venue = .moment(poolManager: cohort.poolManager, poolId: key.id, usdcIs0: key.currency0 == cohort.usdc)
            graduatedAt = record.at > 0 ? record.at : nil
        } else {
            guard case .success(let ledgerValues) = answers[4], let ledgerTuple = ledgerValues.first else { return .unread }
            venue = MomentsABI.ledger(ledgerTuple).state == .expired ? .closed : .collecting
        }
        return .listed(DyorListing(coin: coin, origin: .moment(cohort, id: id), venue: venue, pair: cohort.usdc, graduatedAt: graduatedAt, curve: nil))
    }

    private static func launchRecordCall(_ coin: Address, stack: LaunchpadAddresses) -> ContractCall {
        LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(coin)], returns: LaunchpadABI.launchedTokenReturns(legacy: stack.generation.legacyRecord))
    }
}
