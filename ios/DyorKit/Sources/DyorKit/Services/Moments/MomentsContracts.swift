import BigInt
import Foundation

/// ABI surface of the Moments contracts: signatures, tuple layouts, event topics, decoders and calldata builders.
/// Function selectors and event topics are pinned in `MomentsTests` against `cast sig` / `cast keccak`.
enum MomentsABI {
    // MARK: Tuple layouts (as the contracts return them)

    /// `MomentTypes.Moment`.
    static let momentTuple = "(address,address,address,address,address,uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint64,uint64)"
    /// `MomentTypes.Policy` (a public struct getter returns its members flat).
    static let policyFlat = "uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address"
    /// `MomentCollect.Ledger`.
    static let ledgerTuple = "(uint8,uint64,uint64,uint64,uint256,uint256,uint256,uint256,uint256,uint256)"
    /// `MomentCollect.Quote`.
    static let quoteTuple = "(uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
    /// `MomentTypes.Provenance`.
    static let provenanceTuple = "(string,bytes32,string,uint64,string)"
    static let poolKeyTuple = "(address,address,uint24,int24,address)"
    /// `MomentGraduation.Record`.
    static let recordTuple = "(\(poolKeyTuple),uint160,uint128,uint256,uint256,uint256,uint256,uint64)"
    /// `MomentsFactory.PublishParams`.
    static let publishParams = "(string,string,\(provenanceTuple),uint256,uint16,uint32,bytes32)"
    /// `IPermit2.PermitTransferFrom`.
    static let permitTuple = "((address,uint256),uint256,uint256)"

    enum Factory {
        static let policy = "policy()"
        static let pendingPolicy = "pendingPolicy()"
        static let pendingPolicyAt = "pendingPolicyAt()"
        static let momentCount = "momentCount()"
        static let publishingPaused = "publishingPaused()"
        static let externalBaseURI = "externalBaseURI()"
        static let getMoment = "getMoment(uint256)"
        static let momentIdByCoin = "momentIdByCoin(address)"
        /// v2: `publish(PublishParams, bytes32 expectedTermsHash)`, refused (`TermsChanged`) unless the hash equals
        /// `termsHash()`. It replaced v1's `publish(PublishParams)`, which no cohort the app serves still takes.
        static let publish = "publish(\(publishParams),bytes32)"
        // v2 only (never sent to a v1 factory: it has none of these).
        static let termsHash = "termsHash()"
        static let guardian = "guardian()"
        static let guardianPaused = "guardianPaused()"
        static let policyApplyWindow = "POLICY_APPLY_WINDOW()"
    }

    enum Collect {
        static let ledger = "ledger(uint256)"
        static let state = "state(uint256)"
        static let quote = "quote(uint256,uint256)"
        static let collect = "collect(uint256,uint256)"
        static let collectWithPermit2 = "collectWithPermit2(uint256,uint256,\(permitTuple),bytes)"
        static let supplyCheck = "supplyCheck(uint256)"
        static let expire = "expire(uint256)"
        static let withdrawCreator = "withdrawCreator(uint256)"
        static let withdrawPlatform = "withdrawPlatform(uint256)"
        static let withdrawTreasury = "withdrawTreasury(uint256)"
    }

    enum Vesting {
        static let claim = "claim(uint256)"
        static let claimAll = "claimAll(uint256[])"
        static let claimable = "claimable(uint256,address)"
        static let entitlement = "entitlement(uint256,address)"
        static let claimed = "claimed(uint256,address)"
        static let totalEntitlement = "totalEntitlement(uint256)"
        static let creatorClaimed = "creatorClaimed(uint256)"
        static let graduatedAt = "graduatedAt(uint256)"
    }

    enum Graduation {
        static let graduate = "graduate(uint256)"
        static let isGraduated = "isGraduated(uint256)"
        static let record = "record(uint256)"
        static let poolKeyOf = "poolKeyOf(uint256)"
    }

    enum Locker {
        static let liquidityOf = "liquidityOf(uint256)"
        // v2 only.
        /// What the next add on one Moment could spend: its own balance plus the locker's untracked balance, which
        /// every Moment shares (the next add on any Moment takes it). Not a per-Moment balance: see `heldOf`.
        static let available = "available(uint256,address)"
        /// USDC (or coins) the locker holds for one Moment, spendable by its later buyback rounds.
        static let heldOf = "heldOf(uint256,address)"
        /// The most one `increase` adds, in bps of the position's liquidity (50).
        static let maxIncreaseBps = "MAX_INCREASE_BPS()"
    }

    enum Hook {
        static let creatorAccrued = "creatorAccrued(uint256)"
        static let platformAccrued = "platformAccrued(uint256)"
        static let buybackAccrued = "buybackAccrued(uint256)"
        static let withdrawCreator = "withdrawCreator(uint256)"
        static let withdrawPlatform = "withdrawPlatform(uint256)"
        /// v2 only: the pool price before the block's first swap, which a buyback round is checked against.
        static let blockOpenSqrtPrice = "blockOpenSqrtPrice(uint256)"
    }

    enum Buyback {
        static let carry = "carry(uint256)"
        static let lastRun = "lastRun(uint256)"
        static let minInterval = "MIN_INTERVAL()"
        static let minAmount = "MIN_AMOUNT()"
        static let execute = "execute(uint256,uint256)"
        /// v2 only: how far from the block-open price a round may run (200 bps), else `PriceMoved`.
        static let maxOpenDeviationBps = "MAX_OPEN_DEVIATION_BPS()"
    }

    enum NFT {
        static let totalMinted = "totalMinted()"
        static let closed = "closed()"
        static let provenance = "provenance()"
        static let balanceOf = "balanceOf(address)"
        static let ownerOf = "ownerOf(uint256)"
        static let tokensOfOwner = "tokensOfOwner(address,uint256,uint256)"
        /// v2 only: the link base the NFT was published with. A v1 NFT reads its factory's base live instead.
        static let externalBaseURI = "externalBaseURI()"
    }

    enum Coin {
        static let name = "name()"
        static let symbol = "symbol()"
        static let totalSupply = "totalSupply()"
        static let balanceOf = "balanceOf(address)"
    }

    enum PoolManager {
        static let extsload = "extsload(bytes32)"
        /// Uniswap v4 keeps `pools` at storage slot 6; slot0 (sqrtPriceX96 in the low 160 bits) is `keccak(poolId ‖ 6)`.
        static let poolsSlot: BigUInt = 6
    }

    // MARK: Events

    enum Events {
        static let published = "Published(uint256,address,address,address,uint256,uint16,uint256,uint256,uint64)"
        static let collected = "Collected(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        static let claimed = "Claimed(uint256,address,uint256,uint256)"
        static let withdrawn = "Withdrawn(uint256,address,uint256)"
        static let feesWithdrawn = "FeesWithdrawn(uint256,address,uint256)"
        static let graduated = "Graduated(uint256,bytes32,uint160,uint128,uint256,uint256,uint256,uint256)"
        static let expired = "Expired(uint256,uint256,uint256,uint256)"
        static let feeTaken = "FeeTaken(uint256,uint256,uint256,uint256,uint256)"
        static let buyback = "Buyback(uint256,uint256,uint256,uint256,uint256,uint128,uint256)"
        static let transfer = "Transfer(address,address,uint256)"

        static let publishedTopic = ABI.eventTopic(published)
        static let collectedTopic = ABI.eventTopic(collected)
        static let claimedTopic = ABI.eventTopic(claimed)
        static let withdrawnTopic = ABI.eventTopic(withdrawn)
        static let feesWithdrawnTopic = ABI.eventTopic(feesWithdrawn)
        static let graduatedTopic = ABI.eventTopic(graduated)
        static let expiredTopic = ABI.eventTopic(expired)
        static let feeTakenTopic = ABI.eventTopic(feeTaken)
        static let buybackTopic = ABI.eventTopic(buyback)
        static let transferTopic = ABI.eventTopic(transfer)
    }

    struct PublishedEvent {
        let momentId: BigUInt
        let creator: Address
        let coin: Address
        let nft: Address
        let price: BigUInt
        let creatorAllocBps: Int
        let rateNum: BigUInt
        let rateDen: BigUInt
        let deadline: Int
    }

    struct CollectedEvent {
        let momentId: BigUInt
        let collector: Address
        let gross: BigUInt
        let editions: BigUInt
        let firstRank: BigUInt
        let entitlement: BigUInt
        let reserveIn: BigUInt
        let creatorIn: BigUInt
        let platformIn: BigUInt
        let excess: BigUInt
    }

    struct ClaimedEvent {
        let momentId: BigUInt
        let account: Address
        let collectorAmount: BigUInt
        let creatorAmount: BigUInt
    }

    /// `Withdrawn` (collect) and `FeesWithdrawn` (hook) share one shape.
    struct WithdrawnEvent {
        let momentId: BigUInt
        let beneficiary: Address
        let amount: BigUInt
    }

    /// `Published(uint256 indexed momentId, address indexed creator, address coin, address nft, uint256 price, uint16 creatorAllocBps, uint256 rateNum, uint256 rateDen, uint64 deadline)`.
    static func published(_ log: Log) -> PublishedEvent? {
        guard log.topics.count == 3, log.topics[0] == Events.publishedTopic, let creator = log.indexedAddress(1),
              let words = try? ABI.decode(log.data, "address,address,uint256,uint16,uint256,uint256,uint64"), words.count == 7
        else { return nil }
        return PublishedEvent(momentId: BigUInt(log.topics[1]), creator: creator, coin: words[0].address, nft: words[1].address, price: words[2].uint,
                              creatorAllocBps: Int(clamping: words[3].uint), rateNum: words[4].uint, rateDen: words[5].uint, deadline: Int(clamping: words[6].uint))
    }

    /// `Collected(uint256 indexed momentId, address indexed collector, uint256 gross, uint256 editions, uint256 firstRank, uint256 entitlement, uint256 reserveIn, uint256 creatorIn, uint256 platformIn, uint256 excess)`.
    static func collected(_ log: Log) -> CollectedEvent? {
        guard log.topics.count == 3, log.topics[0] == Events.collectedTopic, let collector = log.indexedAddress(1),
              let words = try? ABI.decode(log.data, "uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256"), words.count == 8
        else { return nil }
        return CollectedEvent(momentId: BigUInt(log.topics[1]), collector: collector, gross: words[0].uint, editions: words[1].uint, firstRank: words[2].uint,
                              entitlement: words[3].uint, reserveIn: words[4].uint, creatorIn: words[5].uint, platformIn: words[6].uint, excess: words[7].uint)
    }

    /// `Claimed(uint256 indexed momentId, address indexed account, uint256 collectorAmount, uint256 creatorAmount)`.
    static func claimed(_ log: Log) -> ClaimedEvent? {
        guard log.topics.count == 3, log.topics[0] == Events.claimedTopic, let account = log.indexedAddress(1),
              let words = try? ABI.decode(log.data, "uint256,uint256"), words.count == 2
        else { return nil }
        return ClaimedEvent(momentId: BigUInt(log.topics[1]), account: account, collectorAmount: words[0].uint, creatorAmount: words[1].uint)
    }

    /// `Withdrawn` / `FeesWithdrawn(uint256 indexed momentId, address indexed beneficiary, uint256 amount)`.
    static func withdrawn(_ log: Log) -> WithdrawnEvent? {
        guard log.topics.count == 3, log.topics[0] == Events.withdrawnTopic || log.topics[0] == Events.feesWithdrawnTopic,
              let beneficiary = log.indexedAddress(1), let words = try? ABI.decode(log.data, "uint256"), words.count == 1
        else { return nil }
        return WithdrawnEvent(momentId: BigUInt(log.topics[1]), beneficiary: beneficiary, amount: words[0].uint)
    }

    // MARK: Encoding helpers

    static func calldata(_ signature: String, _ args: [ABIValue] = []) -> Data {
        do { return try ABI.encodeCall(signature, args) } catch { preconditionFailure("Moments calldata \(signature) failed to encode: \(error)") }
    }

    static func call(_ to: Address, _ signature: String, _ args: [ABIValue] = [], returns: String, strings: ABI.StringDecoding = .lossy) -> ContractCall {
        do { return try ContractCall(to: to, signature, args, returns: returns, strings: strings) } catch { preconditionFailure("Moments call \(signature) failed to encode: \(error)") }
    }

    static func int(_ value: ABIValue) -> Int { Int(clamping: value.uint) }

    /// The `PublishParams` tuple for `publish`.
    static func publishParams(_ input: MomentPublishInput, salt: Data) -> ABIValue {
        .tuple([
            .string(input.name),
            .string(input.symbol),
            .tuple([.string(input.mediaURI), .bytes(input.mediaHash), .string(input.place), .uint(BigUInt(input.date)), .string(input.animationURI)]),
            .uint(input.price),
            .uint(input.creatorAllocBps),
            .uint(input.collectWindow),
            .bytes(salt),
        ])
    }

    /// `MomentTypes.Policy` as a tuple, in its declared order.
    static func policyTuple(_ p: MomentPolicy) -> ABIValue {
        .tuple([.uint(p.threshold), .uint(p.minPrice), .uint(p.creatorBps), .uint(p.platformBps), .uint(p.reserveBps), .uint(p.maxCreatorAllocBps),
                .uint(p.expiryCreatorBps), .uint(p.royaltyBps), .address(p.platform), .address(p.treasury)])
    }

    /// v2 `MomentsFactory.termsHash()` computed locally: keccak256(abi.encode(policy, base)). Pinned in `MomentsTests`
    /// against `cast abi-encode | cast keccak`.
    static func termsHash(policy: MomentPolicy, base: String) -> Data {
        do {
            return Keccak.hash256(try ABI.encode([policyTuple(policy), .string(base)], "(\(policyFlat)),string"))
        } catch {
            preconditionFailure("Moments terms failed to encode: \(error)")
        }
    }

    /// The `PermitTransferFrom` tuple for `collectWithPermit2`.
    static func permit(token: Address, amount: BigUInt, nonce: BigUInt, deadline: BigUInt) -> ABIValue {
        .tuple([.tuple([.address(token), .uint(amount)]), .uint(nonce), .uint(deadline)])
    }

    /// The storage slot of a pool's slot0 in the PoolManager (`keccak256(abi.encode(poolId, 6))`).
    static func slot0(of poolId: Data) -> Data {
        Keccak.hash256(poolId.leftPadded(to: 32) + PoolManager.poolsSlot.word)
    }

    // MARK: Decoding

    /// `factory` is the cohort the tuple was read from (it is not part of the tuple).
    static func moment(id: BigUInt, _ tuple: ABIValue, factory: Address) -> Moment {
        let m = tuple.elements
        return Moment(
            id: id, creator: m[0].address, platform: m[1].address, treasury: m[2].address, coin: m[3].address, nft: m[4].address,
            price: m[5].uint, threshold: m[6].uint, rateNum: m[7].uint, rateDen: m[8].uint,
            creatorBps: int(m[9]), platformBps: int(m[10]), reserveBps: int(m[11]), creatorAllocBps: int(m[12]), expiryCreatorBps: int(m[13]), royaltyBps: int(m[14]),
            publishedAt: int(m[15]), deadline: int(m[16]), factory: factory
        )
    }

    static func ledger(_ tuple: ABIValue) -> MomentLedger {
        let l = tuple.elements
        return MomentLedger(
            state: MomentState(raw: l[0].uint), completedAt: int(l[1]), stuckSince: int(l[2]), endedAt: int(l[3]),
            reserve: l[4].uint, creatorClaimable: l[5].uint, platformClaimable: l[6].uint, treasuryClaimable: l[7].uint, totalGross: l[8].uint, collects: int(l[9])
        )
    }

    static func quote(_ tuple: ABIValue) -> CollectQuote {
        let q = tuple.elements
        return CollectQuote(gross: q[0].uint, editions: q[1].uint, entitlement: q[2].uint, reserveIn: q[3].uint, creatorIn: q[4].uint, platformIn: q[5].uint, excess: q[6].uint, terminal: q[7].bool)
    }

    static func provenance(_ tuple: ABIValue) -> MomentProvenance {
        let p = tuple.elements
        return MomentProvenance(mediaURI: p[0].string, mediaHash: p[1].bytes, place: p[2].string, date: int(p[3]), animationURI: p[4].string)
    }

    static func poolKey(_ tuple: ABIValue) -> PoolKey {
        let k = tuple.elements
        // Clamped, never trapping: an out-of-range word from a hostile RPC makes a key that matches no pool.
        return PoolKey(currency0: k[0].address, currency1: k[1].address, fee: Int(clamping: k[2].uint), tickSpacing: Int(clamping: k[3].int), hooks: k[4].address)
    }

    /// `(key, sqrtPriceX96, liquidity, reserve, poolCoins, usedUsdc, usedCoin, at)`.
    struct GraduationRecord {
        let key: PoolKey
        let sqrtPriceX96: BigUInt
        let liquidity: BigUInt
        let reserve: BigUInt
        let poolCoins: BigUInt
        let usedUsdc: BigUInt
        let usedCoin: BigUInt
        let at: Int
    }

    static func record(_ tuple: ABIValue) -> GraduationRecord {
        let r = tuple.elements
        return GraduationRecord(key: poolKey(r[0]), sqrtPriceX96: r[1].uint, liquidity: r[2].uint, reserve: r[3].uint, poolCoins: r[4].uint, usedUsdc: r[5].uint, usedCoin: r[6].uint, at: int(r[7]))
    }
}

// MARK: - Permit2 typed data

/// Uniswap Permit2 `SignatureTransfer`: a collect pays USDC with a one-time approval of Permit2 and then one
/// EIP-712 signature per collect. The digest here matches viem's `hashTypedData` for the same message (pinned in
/// the tests), which is what the web app signs.
public enum Permit2Signature {
    public struct Permit: Sendable, Hashable {
        public let token: Address
        public let amount: BigUInt
        public let nonce: BigUInt
        public let deadline: BigUInt
        public init(token: Address, amount: BigUInt, nonce: BigUInt, deadline: BigUInt) {
            self.token = token
            self.amount = amount
            self.nonce = nonce
            self.deadline = deadline
        }
    }

    public static func typedData(permit: Permit, spender: Address, permit2: Address, chainId: Int) -> EIP712.TypedData {
        EIP712.TypedData(
            domain: ["name": "Permit2", "chainId": chainId, "verifyingContract": permit2.checksummed],
            types: [
                "EIP712Domain": [.init(name: "name", type: "string"), .init(name: "chainId", type: "uint256"), .init(name: "verifyingContract", type: "address")],
                "PermitTransferFrom": [.init(name: "permitted", type: "TokenPermissions"), .init(name: "spender", type: "address"), .init(name: "nonce", type: "uint256"), .init(name: "deadline", type: "uint256")],
                "TokenPermissions": [.init(name: "token", type: "address"), .init(name: "amount", type: "uint256")],
            ],
            primaryType: "PermitTransferFrom",
            message: [
                "permitted": ["token": permit.token.checksummed, "amount": String(permit.amount)],
                "spender": spender.checksummed,
                "nonce": String(permit.nonce),
                "deadline": String(permit.deadline),
            ]
        )
    }

    /// The 32-byte digest the wallet signs (`keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(PermitTransferFrom))`).
    public static func digest(permit: Permit, spender: Address, permit2: Address, chainId: Int) throws -> Data {
        try EIP712.digest(typedData(permit: permit, spender: spender, permit2: permit2, chainId: chainId))
    }

    /// A fresh unordered nonce: Permit2's `SignatureTransfer` marks nonces in a bitmap, so any never-used random
    /// 256-bit value works and no on-chain read is needed.
    public static func randomNonce() -> BigUInt {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return BigUInt(Data(bytes))
    }
}
