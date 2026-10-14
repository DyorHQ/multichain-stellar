import BigInt
import Foundation

/* What a live passkey session signs without a prompt (MERA-PLAN §3 "Scope"). An action is prompt-free only when every
   check passes; anything else asks for Face ID — a forced pinned ceremony that signs that one action and opens a new
   session. Three independent layers:

     1. The sheet declares a session-OK `Intent`. `Intent.ask` is the default, so an untagged sheet fails closed.
     2. The wallet checks every transaction against that intent from the calldata alone, never trusting the sheet or an
        API: chain 143, the sender, the (to, selector) allowlist, ERC-20 and Permit2 approvals (spender, token, amount
        within the declared input, a Permit2 allowance that ends before the session does, no value), MON within the
        declared amount, the launchpad curve verified on-chain, Kuru Flow's recipient, fee and minimum out, and every
        Uniswap, Monday Trade and Perpl order payload read in full (`MeraCalldata`) — one it can't read in full asks.
     3. The dollar caps (`SpendingCaps`): $100 per action, $250 per session; an unpriced action asks.

   Moments, exactly: prompt-free are a USDC `approve` of the live (v2) collect contract for no more than the declared
   amount plus `collect(uint256,uint256)` on it; `claim` / `claimAll` on the v2 or a retired cohort's vesting; and
   `withdrawCreator` on the v2 or a retired cohort's collect or hook (each pays the caller, the creator only). While v2
   is not deployed its addresses are zero, so collecting asks and nothing matches address 0. Publishing (v2 `publish`,
   0xa270dccc) always asks: its sheet declares `AlwaysAsk.launch` and no `Intent.Kind` admits the selector. Nothing else
   on Moments is on the list — `collectWithPermit2`, `expire`, graduation, buybacks, platform / treasury withdrawals,
   policy and guardian calls — and neither is the launchpad's `graduate` / `graduateFallback`.

   Some things no Face ID makes acceptable, so they are refused outright, prompt-free or approved (`refusal`): on Monad,
   a network fee out of bounds (the RPC sets it and the caps don't count it: more than 5 MON, a gas limit over 15M, or a
   tip above the max fee), a declared swap or launchpad trade whose calldata pays someone else or trades another token,
   the launchpad's `graduateFallback` on any stack: DyorHQ's keepers send it with the gas it needs (v2's needs at
   least 22,062,500, so it fails the fee bound first), and the app never does; and a buy on a retired launchpad, whose
   curves take sells only (`RetiredLaunchpad`): a curve `buy` into a curve a retired factory recorded, an approval
   paying anything but the coin itself into one, and `launchAndBuy` on (or an approval to) a retired router. Both are
   owner decisions of 2026-09-28. Which curves a retired factory recorded is read on-chain before the check
   (`RetiredCurves`), and a curve `buy` whose curve couldn't be looked up is refused as unverified.

   Pure and synchronous: the app supplies what only the chain can answer (`Context.verifiedCurves`, `RetiredCurves`) and
   the session's caps. The only messages a session signs on its own are DyorHQ's wallet-auth sign-in for this account;
   the gas-drip template joins that list if a drip is ever built (this build sponsors no gas, MERA-PLAN §4). */
extension Mera {
    // MARK: Intent

    /// What a sheet says its plan does. A plan may combine parts (swap MON → AUSD, then deposit it); every transaction
    /// must fit one of them. The dollar value is the whole action's, from the app's price sources.
    public struct Intent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A spot swap on a venue; `.wrap` is wrapping MON or unwrapping WMON.
            case swap(Venue)
            case launchpadBuy, launchpadSell
            /// Moments: collect editions, claim vested coins, withdraw creator proceeds and pool fees (paid to the caller).
            case momentsCollect, momentsClaim, momentsWithdraw
            /// Perpl: deposit into the caller's own account, withdraw to the caller, open orders.
            case perplDeposit, perplWithdraw, perplOrder
        }

        /// A token amount. `Monad.native` (the zero address) is MON.
        public struct TokenAmount: Sendable, Equatable {
            public let token: Address
            public let amount: BigUInt
            public init(token: Address, amount: BigUInt) {
                self.token = token
                self.amount = amount
            }
            public var isNative: Bool { token.isZero }
        }

        public struct Part: Sendable, Equatable {
            public let kind: Kind
            /// The most that may leave the account in this part: approvals and MON are checked against it.
            public let input: TokenAmount?
            /// Swaps: the token out and the quoted amount (Kuru Flow's minimum is checked against it).
            public let output: TokenAmount?
            /// Launchpad: the launch whose curve is verified on-chain.
            public let launchToken: Address?
            /// Perpl: the order the sheet shows. An order part without it always asks.
            public let order: OrderTerms?

            public init(kind: Kind, input: TokenAmount? = nil, output: TokenAmount? = nil, launchToken: Address? = nil, order: OrderTerms? = nil) {
                self.kind = kind
                self.input = input
                self.output = output
                self.launchToken = launchToken
                self.order = order
            }

            /// The MON a call in this part may send.
            var nativeAllowance: BigUInt { input.map { $0.isNative ? $0.amount : 0 } ?? 0 }
        }

        /// Empty for an action that always asks.
        public let parts: [Part]
        /// The action's dollar value for the caps; nil when it can't be priced (which asks).
        public let usd: Double?
        /// Why an action with no parts asks, for "Face ID required: <reason>".
        public let asks: AlwaysAsk

        public init(parts: [Part], usd: Double?, asks: AlwaysAsk = .unlisted) {
            self.parts = parts
            self.usd = usd
            self.asks = asks
        }

        /// Whether the action can be prompt-free at all (the other checks still apply).
        public var isSessionScoped: Bool { !parts.isEmpty }

        /// The default: every sheet that declares nothing asks.
        public static let ask = Intent(parts: [], usd: nil)
        public static func alwaysAsks(_ what: AlwaysAsk) -> Intent { Intent(parts: [], usd: nil, asks: what) }

        public static func swap(venue: Venue, pay: TokenAmount, receive: TokenAmount, usd: Double?) -> Intent {
            Intent(parts: [Part(kind: .swap(venue), input: pay, output: receive)], usd: usd)
        }

        public static func launchpadBuy(token: Address, pay: TokenAmount, usd: Double?) -> Intent {
            Intent(parts: [Part(kind: .launchpadBuy, input: pay, launchToken: token)], usd: usd)
        }

        public static func launchpadSell(token: Address, amount: BigUInt, usd: Double?) -> Intent {
            Intent(parts: [Part(kind: .launchpadSell, input: TokenAmount(token: token, amount: amount), launchToken: token)], usd: usd)
        }

        /// Collecting Moment editions for `pay` (USDC), through the exact-approval path.
        public static func momentsCollect(pay: TokenAmount, usd: Double?) -> Intent {
            Intent(parts: [Part(kind: .momentsCollect, input: pay)], usd: usd)
        }

        /// Nothing leaves the account: the contracts pay the caller.
        public static let momentsClaim = Intent(parts: [Part(kind: .momentsClaim)], usd: 0)
        public static let momentsWithdraw = Intent(parts: [Part(kind: .momentsWithdraw)], usd: 0)
        public static let perplWithdraw = Intent(parts: [Part(kind: .perplWithdraw)], usd: 0)

        /// AUSD (6 decimals, a dollar each) into the caller's own Perpl account.
        public static func perplDeposit(amount: BigUInt) -> Intent {
            Intent(parts: [Part(kind: .perplDeposit, input: TokenAmount(token: Perpl.collateral, amount: amount))], usd: DyorKit.Amount.units(amount, decimals: Perpl.collateralDecimals))
        }

        /// An opening order sent on-chain: `order` is the order the sheet shows, and `usd` its worst-case notional
        /// (`SpendingCaps.notionalUSD`).
        public static func perplOrder(usd: Double?, order: OrderTerms) -> Intent {
            Intent(parts: [Part(kind: .perplOrder, order: order)], usd: usd)
        }

        /// A Perpl order as its `execOrders` desc encodes it: the market, the side, the size, the leverage, the price
        /// bound and how it rests (post-only, immediate-or-cancel).
        public struct OrderTerms: Sendable, Equatable {
            public let perpId: BigUInt
            /// `PerpOrderType.openLong` or `.openShort`.
            public let orderType: BigUInt
            public let lotLNS: BigUInt
            public let leverageHdths: BigUInt
            /// The desc's price, in the market's price units: the most a long pays, the least a short sells at — for a
            /// market order the mark moved by the slippage allowance.
            public let price: BigUInt
            public let postOnly: Bool
            public let immediateOrCancel: Bool

            public init(perpId: BigUInt, orderType: BigUInt, lotLNS: BigUInt, leverageHdths: BigUInt, price: BigUInt, postOnly: Bool, immediateOrCancel: Bool) {
                self.perpId = perpId
                self.orderType = orderType
                self.lotLNS = lotLNS
                self.leverageHdths = leverageHdths
                self.price = price
                self.postOnly = postOnly
                self.immediateOrCancel = immediateOrCancel
            }

            /// The terms `PerplExchange.orderDesc` encodes for `order`.
            public init(_ order: OrderInput) {
                let desc = PerplExchange.orderDesc(order, descId: 0)
                self.init(perpId: desc[1].uint, orderType: desc[2].uint, lotLNS: desc[5].uint, leverageHdths: desc[11].uint,
                          price: desc[4].uint, postOnly: desc[7].bool, immediateOrCancel: desc[9].bool)
            }

            /// Whether a signed order stays within these: the same market, side and way of resting, no higher leverage,
            /// no more than 2% over the size, and a price no more than 2% worse — above the one shown for a long, below
            /// it for a short. The tolerances cover the mark moving between the sheet building the order and the tap (a
            /// market order's price and a dollar-sized order's size both come from it); the per-action cap is priced
            /// at the order shown, so a price well past it asks.
            func admits(_ signed: OrderTerms) -> Bool {
                guard signed.perpId == perpId, signed.orderType == orderType, signed.leverageHdths <= leverageHdths, signed.lotLNS * 100 <= lotLNS * 102,
                      signed.postOnly == postOnly, signed.immediateOrCancel == immediateOrCancel else { return false }
                if orderType == BigUInt(PerpOrderType.openLong.rawValue) { return signed.price * 100 <= price * 102 }
                return signed.price * 100 >= price * 98
            }
        }

        /// One action made of several intents, valued as a whole (`usd`), e.g. a swap whose output is then deposited.
        /// If any of them always asks, so does the combination.
        public static func combining(_ intents: [Intent], usd: Double?) -> Intent {
            if let asking = intents.first(where: { !$0.isSessionScoped }) { return asking }
            return Intent(parts: intents.flatMap(\.parts), usd: usd)
        }
    }

    /// The classes that always ask, whatever the session (MERA-PLAN §3 "Always asks").
    public enum AlwaysAsk: String, Sendable, CaseIterable {
        case send, bridge, launch, withdrawElsewhere, export, deletion, lengthenSession, rawDigest, message
        /// Perpl cancels and reduce-only closes: allowed only after a step-up.
        case cancelOrder, closePosition
        /// Anything no sheet declared as session-OK.
        case unlisted

        /// The "<reason>" in "Face ID required: <reason>", in the app's language.
        public var summary: String {
            switch self {
            case .send: return L10n.string(LocalizedStringResource("sending to another address", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .bridge: return L10n.string(LocalizedStringResource("bridging to another chain", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .launch: return L10n.string(LocalizedStringResource("launching or creating", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .withdrawElsewhere: return L10n.string(LocalizedStringResource("withdrawing to another address", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .export: return L10n.string(LocalizedStringResource("showing your recovery phrase", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .deletion: return L10n.string(LocalizedStringResource("deleting your account", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .lengthenSession: return L10n.string(LocalizedStringResource("making sessions longer", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .rawDigest: return L10n.string(LocalizedStringResource("signing raw data", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .message: return L10n.string(LocalizedStringResource("signing a message", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .cancelOrder: return L10n.string(LocalizedStringResource("cancelling an order", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .closePosition: return L10n.string(LocalizedStringResource("closing a position", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            case .unlisted: return L10n.string(LocalizedStringResource("this action always asks", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
            }
        }
    }

    // MARK: Policy

    public enum SigningPolicy {
        public enum ApprovalProblem: String, Sendable, Equatable {
            case token, spender, amount, expiration, value
        }

        public enum Reason: Sendable, Equatable {
            case locked
            case alwaysAsks(AlwaysAsk)
            case wrongChain
            case wrongSender
            case notAllowlisted
            case approval(ApprovalProblem)
            case valueOverDeclared
            case amountOverDeclared
            case differentToken
            case unverifiedCurve
            case recipient
            case minimumOut
            /// A Kuru Flow swap whose fee tuple takes basis points (`KuruFlowSwap.takesNoFee`).
            case fee
            case networkFee
            /// The launchpad's `graduateFallback`, on any stack: only DyorHQ's keepers send it.
            case graduateFallback
            /// A buy on a retired launchpad, whose curves take sells only.
            case retiredLaunchpad
            case unpriced, overActionCap, overSessionCap

            /// The "<reason>" in "Face ID required: <reason>", in the app's language.
            public var summary: String {
                switch self {
                case .locked: return L10n.string(LocalizedStringResource("your session is locked", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .alwaysAsks(let what): return what.summary
                case .wrongChain: return L10n.string(LocalizedStringResource("a transaction on another chain", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .wrongSender: return L10n.string(LocalizedStringResource("a transaction from another account", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .notAllowlisted: return L10n.string(LocalizedStringResource("a contract call DyorHQ doesn’t sign on its own", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .approval(.token): return L10n.string(LocalizedStringResource("an approval for a token not shown", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .approval(.spender): return L10n.string(LocalizedStringResource("an approval for an unknown spender", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .approval(.amount): return L10n.string(LocalizedStringResource("an approval above the amount shown", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .approval(.expiration): return L10n.string(LocalizedStringResource("an allowance that outlasts this session", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .approval(.value): return L10n.string(LocalizedStringResource("MON sent with an approval", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .valueOverDeclared: return L10n.string(LocalizedStringResource("more MON than shown", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .amountOverDeclared: return L10n.string(LocalizedStringResource("more than the amount shown", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .differentToken: return L10n.string(LocalizedStringResource("a different token than shown", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .unverifiedCurve: return L10n.string(LocalizedStringResource("a launchpad curve DyorHQ can’t verify", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .recipient: return L10n.string(LocalizedStringResource("the output going to another address", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .minimumOut: return L10n.string(LocalizedStringResource("a minimum received below 99% of the quote", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .fee: return L10n.string(LocalizedStringResource("a swap that pays a fee to someone else", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .networkFee: return L10n.string(LocalizedStringResource("an unusually high network fee", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .graduateFallback: return L10n.string(LocalizedStringResource("a graduation fallback, which only DyorHQ’s keepers send", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .retiredLaunchpad: return L10n.string(LocalizedStringResource("a buy on a retired launchpad, which only takes sells", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .unpriced: return L10n.string(LocalizedStringResource("this can’t be priced", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.”"))
                case .overActionCap:
                    // The cap in the app's one style for dollars, whatever the language ("$100").
                    let cap = PriceFormat.usdValue(SpendingCaps.perActionUSD, fractionDigits: 0...0)
                    return L10n.string(LocalizedStringResource("over the \(cap) limit per action", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.” The value is an amount in US dollars ($100)."))
                case .overSessionCap:
                    let cap = PriceFormat.usdValue(SpendingCaps.perSessionUSD, fractionDigits: 0...0)
                    return L10n.string(LocalizedStringResource("over this session’s \(cap) limit", bundle: L10n.kit, comment: "Why a passkey prompt or a refusal appears, completing “Face ID required: <this>.” and “Blocked for your safety: <this>. This transaction wasn’t signed.” The value is an amount in US dollars ($250)."))
                }
            }
        }

        public enum Verdict: Sendable, Equatable {
            case allowed
            case ask(Reason)
        }

        /// The most gas fee any Monad transaction a passkey account signs may commit to: 5 MON (gas limit × max fee per
        /// gas, the most Monad can charge, since it bills the gas limit). A normal swap pays about 0.07 MON; the largest
        /// transaction the app sends, a launch with its first buy (~5.2M gas used on mainnet, ~6.2M limit), about 1.3 MON.
        /// The same bound every wallet's transactions get (`NetworkFeeLimits.monad`).
        public static let maxNetworkFee = NetworkFeeLimits.monad.maxNetworkFee
        /// The highest gas limit such a transaction may carry: half Monad's per-transaction limit, over twice the largest
        /// the app sends. A graduating Moment collect (`MomentCollect.GRADUATION_GAS` reserves 3M) sits well inside it.
        public static let maxGasLimit = NetworkFeeLimits.monad.maxGasLimit

        /// One transaction as the wallet sees it.
        public struct Call: Sendable, Equatable {
            public let from: Address
            public let to: Address
            public let data: Data
            public let value: BigUInt
            public let chainId: Int
            /// The fee fields, all set once the transaction is prepared (`init(_:)`); all nil for a preview of a plan step,
            /// whose fee isn't known yet (the check runs again on the prepared transaction when it is signed).
            public let gasLimit: BigUInt?
            public let maxFeePerGas: BigUInt?
            public let maxPriorityFeePerGas: BigUInt?

            public init(from: Address, to: Address, data: Data, value: BigUInt = 0, chainId: Int = Monad.chainId,
                        gasLimit: BigUInt? = nil, maxFeePerGas: BigUInt? = nil, maxPriorityFeePerGas: BigUInt? = nil) {
                self.from = from
                self.to = to
                self.data = Data(data)
                self.value = value
                self.chainId = chainId
                self.gasLimit = gasLimit
                self.maxFeePerGas = maxFeePerGas
                self.maxPriorityFeePerGas = maxPriorityFeePerGas
            }

            /// The transaction about to be signed, fee included.
            public init(_ transaction: PreparedTransaction) {
                self.init(from: transaction.from, to: transaction.to, data: transaction.data, value: transaction.value, chainId: transaction.chainId,
                          gasLimit: transaction.gasLimit, maxFeePerGas: transaction.maxFeePerGas, maxPriorityFeePerGas: transaction.maxPriorityFeePerGas)
            }

            /// What a plan step will send, for a preview before it is prepared (see `TransactionStep.request(at:)`).
            public init?(step: TransactionStep, from: Address, chainId: Int = Monad.chainId, now: Date = Date()) {
                guard let request = try? step.request(at: now) else { return nil }
                self.init(from: from, to: request.to, data: request.data, value: request.value, chainId: chainId)
            }
        }

        /// The contracts the app is configured with that no sheet can change.
        public struct Contracts: Sendable, Equatable {
            /// The live Moments cohort (v2): the only one that collects. All zero while v2 is pending, and then nothing
            /// collects prompt-free.
            public var moments: MomentsAddresses
            /// Every deployed cohort whose claims and creator withdrawals pay the caller: the live one, then the retired
            /// ones newest first (cohorts 3, 2, 1).
            public var momentsCohorts: [MomentsAddresses]

            public init(moments: MomentsAddresses, retiredMoments: [MomentsAddresses] = MomentsAddresses.retiredMainnet) {
                self.moments = moments
                momentsCohorts = ([moments] + retiredMoments.filter { $0.factory != moments.factory }).filter(\.isDeployed)
            }

            public static let monadMainnet = Contracts(moments: .monadMainnet)
        }

        /// The launchpad curves a plan pays into that a retired factory recorded, read on-chain before `refusal` runs
        /// (`RetiredLaunchpad.curves`, from `curveCandidates`): the curve a `buy` goes to and the spender of an approval.
        public enum RetiredCurves: Sendable, Equatable {
            /// Each candidate a retired factory recorded as a launch's curve → that launch's coin. Empty when none is, or
            /// when there was nothing to look up.
            case known([Address: Address])
            /// The lookup failed: no curve can be ruled out, so a curve `buy` is refused as unverified.
            case unknown

            /// Nothing to look up: no call pays into a curve.
            public static let none = RetiredCurves.known([:])
        }

        /// Everything the check needs besides the call and the intent.
        public struct Context: Sendable {
            public var account: Address
            /// The live session's end: a Permit2 allowance must end no later.
            public var expiresAt: Date
            public var contracts: Contracts
            /// Launch token → the curve a known factory recorded for it, read on-chain (`LaunchpadService.knownCurve`).
            public var verifiedCurves: [Address: Address]

            public init(account: Address, expiresAt: Date, contracts: Contracts = .monadMainnet, verifiedCurves: [Address: Address] = [:]) {
                self.account = account
                self.expiresAt = expiresAt
                self.contracts = contracts
                self.verifiedCurves = verifiedCurves
            }
        }

        // MARK: Transactions

        /// A whole plan before anything is signed, for the sheet's badge: every call, then the caps (not charged).
        public static func review(_ calls: [Call], intent: Intent, context: Context, caps: SpendingCaps) -> Verdict {
            guard intent.isSessionScoped else { return .ask(.alwaysAsks(intent.asks)) }
            for call in calls {
                if case .ask(let reason) = check(call, intent: intent, context: context) { return .ask(reason) }
            }
            return verdict(caps.verdict(for: intent.usd))
        }

        /// The caps' answer as a verdict.
        public static func verdict(_ caps: SpendingCaps.Verdict) -> Verdict {
            switch caps {
            case .allowed: return .allowed
            case .unpriced: return .ask(.unpriced)
            case .overActionCap: return .ask(.overActionCap)
            case .overSessionCap: return .ask(.overSessionCap)
            }
        }

        /// The wallet's own check of one transaction against the declared intent (checks 1 and 2; the caps are charged
        /// separately, once per action, and `refusal` runs before either).
        public static func check(_ call: Call, intent: Intent, context: Context) -> Verdict {
            guard intent.isSessionScoped else { return .ask(.alwaysAsks(intent.asks)) }
            guard call.chainId == Monad.chainId else { return .ask(.wrongChain) }
            guard call.from == context.account else { return .ask(.wrongSender) }
            var reason: Reason?
            for part in intent.parts {
                switch check(call, part: part, context: context) {
                case .allowed: return .allowed
                // The most telling reason: the first part that recognised the call, else "not on the list".
                case .ask(let r): if reason == nil || reason == .notAllowlisted { reason = r }
                }
            }
            return .ask(reason ?? .notAllowlisted)
        }

        /// What no Face ID can make acceptable, checked on every transaction a passkey account signs — prompt-free or
        /// approved by a step-up — before anything else: nil when none applies. The signer throws instead of asking.
        ///
        /// - `.networkFee`, on Monad: a fee outside `feeWithinLimits`. The fee comes from the RPC and neither the sheet
        ///   nor the caps show it, so an approval can't vouch for it. (Other chains, for a bridge, have their own fee
        ///   markets and aren't bounded here.)
        /// - `.recipient`: a Kuru Flow swap paying its output to another address, whatever the intent, or a launchpad
        ///   trade the sheet declared doing so. DyorHQ never builds either.
        /// - `.fee`: a Kuru Flow swap whose fee tuple takes basis points. The quote client blocks one too (IOST-7).
        /// - `.differentToken`: a Kuru Flow swap the sheet declared, trading tokens other than the ones shown.
        /// - `.graduateFallback`: the launchpad's `graduateFallback`, to any contract. The app never sends it, on any stack.
        /// - `.retiredLaunchpad`: a buy on a retired launchpad (`retiredLaunchpadRefusal`), whatever the sheet declared;
        ///   `.unverifiedCurve` for a curve `buy` whose curve couldn't be looked up (`retiredCurves` is `.unknown`).
        ///   `retiredCurves` is what the chain says about the curves `curveCandidates` names for this call.
        public static func refusal(_ call: Call, intent: Intent, account: Address, retiredCurves: RetiredCurves = .none) -> Reason? {
            if call.chainId == Monad.chainId, !feeWithinLimits(call) { return .networkFee }
            if call.data.prefix(4) == Selector.graduateFallback { return .graduateFallback }
            if let reason = retiredLaunchpadRefusal(call, retiredCurves: retiredCurves) { return reason }
            if call.to == Kuru.entrypoint, let swap = KuruFlowSwap(calldata: call.data) {
                if (swap.recipient ?? account) != account { return .recipient }
                if !swap.takesNoFee { return .fee }
                let declared = intent.parts.filter { $0.kind == .swap(.kuru) }
                if !declared.isEmpty, !declared.contains(where: { $0.input?.token == swap.tokenIn && $0.output?.token == swap.tokenOut }) { return .differentToken }
            }
            let selector = call.data.prefix(4)
            for part in intent.parts where isLaunchpad(part.kind) {
                let expected = part.kind == .launchpadBuy ? Selector.curveBuy : Selector.curveSell
                if selector == expected, let recipient = ABIWords(call.data.dropFirst(4)).address(2), recipient != account { return .recipient }
            }
            return nil
        }

        /// A buy on a retired launchpad, whose curves take sells only (owner decision 2026-09-28), or nil:
        ///
        /// - `launchAndBuy` on a retired stack's router, or an approval naming one as spender (a developer buy);
        /// - a curve `buy` into a curve a retired factory recorded, or — when that couldn't be looked up — any curve `buy`,
        ///   as unverified;
        /// - an approval that pays anything but the coin itself into such a curve: only a buy spends it. Approving the coin
        ///   for its own curve is a sell's first step, and stays open.
        static func retiredLaunchpadRefusal(_ call: Call, retiredCurves: RetiredCurves) -> Reason? {
            guard call.data.count >= 4 else { return nil }
            let selector = call.data.prefix(4)
            let args = ABIWords(call.data.dropFirst(4))
            let routers = LaunchpadAddresses.retiredRouters
            if selector == Selector.launchAndBuy, routers.contains(call.to) { return .retiredLaunchpad }
            if selector == Selector.curveBuy {
                switch retiredCurves {
                case .unknown: return .unverifiedCurve
                case .known(let curves): if curves[call.to] != nil { return .retiredLaunchpad }
                }
            }
            if selector == Selector.approve, let spender = args.address(0) {
                if routers.contains(spender) { return .retiredLaunchpad }
                if case .known(let curves) = retiredCurves, let coin = curves[spender], call.to != coin { return .retiredLaunchpad }
            }
            return nil
        }

        /// What must be looked up on-chain before `refusal` (`RetiredCurves`): the target of every curve `buy` and the
        /// spender of every ERC-20 approval, leaving out the swap routers, Permit2 and Perpl, which are no curve.
        public static func curveCandidates(_ calls: [Call]) -> Set<Address> {
            var out = Set<Address>()
            for call in calls where call.data.count >= 4 {
                let selector = call.data.prefix(4)
                if selector == Selector.curveBuy { out.insert(call.to) }
                if selector == Selector.approve, let spender = ABIWords(call.data.dropFirst(4)).address(0), !notCurves.contains(spender) { out.insert(spender) }
            }
            return out
        }

        /// Spenders the app approves that are no launchpad curve.
        static let notCurves: Set<Address> = [Uniswap.permit2, Uniswap.swapRouter02, Uniswap.universalRouter, MondayTrade.swapRouter, Kuru.entrypoint, Perpl.exchange]

        /// The fee comes from the RPC (`eth_estimateGas`, the base fee, `eth_maxPriorityFeePerGas`), so a buggy or hostile
        /// node could otherwise have a transaction commit the whole balance to gas. It must stay within Monad's
        /// `NetworkFeeLimits` (`maxNetworkFee`, `maxGasLimit`, the fee-per-gas ceiling), with a tip no higher than the
        /// max fee — what `TransactionSender.prepare` already enforced, checked again by the wallet. A preview carries no
        /// fee and passes here; a fee given only in part fails closed.
        static func feeWithinLimits(_ call: Call) -> Bool {
            switch (call.gasLimit, call.maxFeePerGas, call.maxPriorityFeePerGas) {
            case (nil, nil, nil): return true
            case let (gasLimit?, maxFee?, tip?):
                return NetworkFeeLimits.violation(gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, baseFee: nil, chainId: Monad.chainId) == nil
            default: return false
            }
        }

        static func check(_ call: Call, part: Intent.Part, context: Context) -> Verdict {
            // No selector: a plain MON transfer, which is a send.
            guard call.data.count >= 4 else { return .ask(.notAllowlisted) }
            let selector = call.data.prefix(4)
            let args = ABIWords(call.data.dropFirst(4))
            if selector == Selector.approve { return checkApproval(call, args, part: part, context: context) }
            if call.to == Uniswap.permit2, selector == Selector.permit2Approve { return checkPermit2(call, args, part: part, context: context) }
            let verdict = checkCall(call, selector: selector, args: args, part: part, context: context)
            guard verdict == .allowed else { return verdict }
            return call.value <= part.nativeAllowance ? .allowed : .ask(.valueOverDeclared)
        }

        /// ERC-20 `approve(spender, amount)`: of the declared input token, to a spender this kind of action uses, for no
        /// more than the declared input, with no value.
        private static func checkApproval(_ call: Call, _ args: ABIWords, part: Intent.Part, context: Context) -> Verdict {
            guard call.value == 0 else { return .ask(.approval(.value)) }
            guard let spender = args.address(0), let amount = args.uint(1) else { return .ask(.notAllowlisted) }
            guard let input = part.input, !input.isNative, call.to == input.token else { return .ask(.approval(.token)) }
            if isLaunchpad(part.kind), curve(for: part, context) == nil { return .ask(.unverifiedCurve) }
            guard spenders(for: part, context: context).contains(spender) else { return .ask(.approval(.spender)) }
            guard amount <= input.amount else { return .ask(.approval(.amount)) }
            return .allowed
        }

        /// Permit2 `approve(token, spender, amount, expiration)`: Uniswap swaps only, the declared input token, the
        /// Universal Router, no more than the declared input, ending no later than the session, with no value.
        private static func checkPermit2(_ call: Call, _ args: ABIWords, part: Intent.Part, context: Context) -> Verdict {
            guard part.kind == .swap(.uniswap) else { return .ask(.notAllowlisted) }
            guard call.value == 0 else { return .ask(.approval(.value)) }
            guard let token = args.address(0), let spender = args.address(1), let amount = args.uint(2), let expiration = args.uint(3) else { return .ask(.notAllowlisted) }
            guard let input = part.input, !input.isNative, token == input.token else { return .ask(.approval(.token)) }
            guard spender == Uniswap.universalRouter else { return .ask(.approval(.spender)) }
            guard amount <= input.amount else { return .ask(.approval(.amount)) }
            let sessionEnd = BigUInt(max(0, Int(context.expiresAt.timeIntervalSince1970.rounded(.down))))
            guard expiration <= sessionEnd else { return .ask(.approval(.expiration)) }
            return .allowed
        }

        /// Everything that isn't an approval: the (to, selector) allowlist for the part's kind, plus what the calldata
        /// says about amounts and recipients where the app can read it.
        private static func checkCall(_ call: Call, selector: Data, args: ABIWords, part: Intent.Part, context: Context) -> Verdict {
            let contracts = context.contracts
            func allow(_ ok: Bool) -> Verdict { ok ? .allowed : .ask(.notAllowlisted) }
            switch part.kind {
            case .swap(.uniswap):
                // Read in full (`MeraCalldata`): a payload that isn't exactly the swap the app builds asks (IOSK-10).
                if call.to == Uniswap.universalRouter { return checkSwap(universalRouterSwap(call.data, value: call.value), part: part) }
                if call.to == Uniswap.swapRouter02 { return checkSwap(swapRouter02Swap(call.data, account: context.account, value: call.value), part: part) }
                return .ask(.notAllowlisted)
            case .swap(.monday):
                guard call.to == MondayTrade.swapRouter else { return .ask(.notAllowlisted) }
                return checkSwap(mondaySwap(call.data, account: context.account, value: call.value), part: part)
            case .swap(.kuru):
                guard call.to == Kuru.entrypoint else { return .ask(.notAllowlisted) }
                return checkKuru(call, part: part, context: context)
            case .swap(.wrap):
                guard call.to == Monad.wmon, let input = part.input else { return .ask(.notAllowlisted) }
                if selector == Selector.wmonDeposit, input.isNative { return .allowed }
                if selector == Selector.wmonWithdraw, input.token == Monad.wmon, let amount = args.uint(0) {
                    return amount <= input.amount ? .allowed : .ask(.amountOverDeclared)
                }
                return .ask(.notAllowlisted)
            case .launchpadBuy, .launchpadSell:
                guard let curve = curve(for: part, context), call.to == curve else { return .ask(.unverifiedCurve) }
                // `buy(quoteIn, minTokensOut, recipient)` / `sell(tokensIn, minQuoteOut, recipient)`.
                let expected = part.kind == .launchpadBuy ? Selector.curveBuy : Selector.curveSell
                guard selector == expected, let amount = args.uint(0), let recipient = args.address(2) else { return .ask(.notAllowlisted) }
                guard recipient == context.account else { return .ask(.recipient) }
                guard let input = part.input, amount <= input.amount else { return .ask(.amountOverDeclared) }
                return .allowed
            case .momentsCollect:
                return allow(!contracts.moments.collect.isZero && call.to == contracts.moments.collect && selector == Selector.momentsCollect)
            case .momentsClaim:
                return allow(contracts.momentsCohorts.contains { $0.vesting == call.to } && (selector == Selector.vestingClaim || selector == Selector.vestingClaimAll))
            case .momentsWithdraw:
                // The collect contract's and the hook's `withdrawCreator(momentId)` pay `msg.sender`, and only its creator.
                return allow(contracts.momentsCohorts.contains { $0.collect == call.to || (!$0.hook.isZero && $0.hook == call.to) } && selector == Selector.withdrawCreator)
            case .perplDeposit:
                guard call.to == Perpl.exchange, selector == Selector.perplCreateAccount || selector == Selector.perplDeposit, let amount = args.uint(0) else { return .ask(.notAllowlisted) }
                guard let input = part.input, input.token == Perpl.collateral, amount <= input.amount else { return .ask(.amountOverDeclared) }
                return .allowed
            case .perplWithdraw:
                return allow(call.to == Perpl.exchange && selector == Selector.perplWithdraw)
            case .perplOrder:
                guard call.to == Perpl.exchange, let declared = part.order, let signed = perplOpenOrder(call.data) else { return .ask(.notAllowlisted) }
                return declared.admits(signed) ? .allowed : .ask(.amountOverDeclared)
            }
        }

        /// A decoded swap against the part: the tokens shown, no more than the declared input, and a minimum of at least
        /// 99% of the quote, as for Kuru Flow. Nil — a payload the decoder doesn't read in full — asks.
        private static func checkSwap(_ terms: SwapTerms?, part: Intent.Part) -> Verdict {
            guard let terms else { return .ask(.notAllowlisted) }
            guard let input = part.input, let output = part.output, terms.tokenIn == input.token, terms.tokenOut == output.token else { return .ask(.differentToken) }
            guard terms.amountIn <= input.amount else { return .ask(.amountOverDeclared) }
            guard terms.minOut >= SwapMath.minAfterSlippage(output.amount, bps: 100) else { return .ask(.minimumOut) }
            return .allowed
        }

        /// Kuru Flow's ready-made calldata: the tokens shown, no more than the declared input, the output to this account,
        /// and a minimum of at least 99% of the quote, rounded down as Kuru and `SwapMath.minAfterSlippage` round it (so a
        /// 1% slippage setting is prompt-free whatever the quote's last digits).
        private static func checkKuru(_ call: Call, part: Intent.Part, context: Context) -> Verdict {
            guard let swap = KuruFlowSwap(calldata: call.data) else { return .ask(.notAllowlisted) }
            guard (swap.recipient ?? call.from) == context.account else { return .ask(.recipient) }
            guard swap.takesNoFee else { return .ask(.fee) }
            guard let input = part.input, let output = part.output, swap.tokenIn == input.token, swap.tokenOut == output.token else { return .ask(.differentToken) }
            guard swap.amountIn <= input.amount else { return .ask(.amountOverDeclared) }
            guard swap.minAmountOut >= SwapMath.minAfterSlippage(output.amount, bps: 100) else { return .ask(.minimumOut) }
            return .allowed
        }

        private static func isLaunchpad(_ kind: Intent.Kind) -> Bool { kind == .launchpadBuy || kind == .launchpadSell }

        private static func curve(for part: Intent.Part, _ context: Context) -> Address? {
            part.launchToken.flatMap { context.verifiedCurves[$0] }
        }

        /// Who an approval may name for this kind of action.
        private static func spenders(for part: Intent.Part, context: Context) -> [Address] {
            switch part.kind {
            case .swap(.uniswap): return [Uniswap.permit2, Uniswap.swapRouter02]
            case .swap(.monday): return [MondayTrade.swapRouter]
            case .swap(.kuru): return [Kuru.entrypoint]
            case .launchpadBuy, .launchpadSell: return curve(for: part, context).map { [$0] } ?? []
            case .momentsCollect: return context.contracts.moments.collect.isZero ? [] : [context.contracts.moments.collect]
            case .perplDeposit: return [Perpl.exchange]
            case .swap(.wrap), .momentsClaim, .momentsWithdraw, .perplWithdraw, .perplOrder: return []
            }
        }

        // MARK: Messages

        /// A message is prompt-free only when it is, byte for byte, DyorHQ's EIP-4361 wallet-auth sign-in for this
        /// account (`SupabaseClient.signInMessage`: this wallet's checksummed address, dyorhq.fun, chain 143), issued
        /// within five minutes of `now`. Everything else asks, the old "DyorHQ Sign-In" template included: this app no
        /// longer signs it.
        public static func check(message: Data, account: Address, now: Date = Date()) -> Verdict {
            guard let text = String(data: message, encoding: .utf8) else { return .ask(.alwaysAsks(.message)) }
            // not localized: the sign-in message's own fields (EIP-4361), compared as written
            let lines = text.components(separatedBy: "\n")
            guard lines.count == 11, lines[8].hasPrefix("Nonce: "), lines[9].hasPrefix("Issued At: ") else { return .ask(.alwaysAsks(.message)) }
            let nonce = String(lines[8].dropFirst("Nonce: ".count))
            let hex = Set("0123456789abcdef")
            guard nonce.count == 64, nonce.allSatisfy(hex.contains),
                  let millis = SupabaseClient.millis(iso8601: String(lines[9].dropFirst("Issued At: ".count))),
                  abs(Double(millis) / 1000 - now.timeIntervalSince1970) <= 5 * 60,
                  SupabaseClient.signInMessage(address: account.checksummed, nonce: nonce, issuedAt: millis) == text else { return .ask(.alwaysAsks(.message)) }
            return .allowed
        }

        // MARK: Selectors

        enum Selector {
            static let approve = ABI.selector("approve(address,uint256)")
            static let permit2Approve = ABI.selector("approve(address,address,uint160,uint48)")
            static let universalRouterExecute = ABI.selector("execute(bytes,bytes[],uint256)")
            static let swapRouter02Multicall = ABI.selector("multicall(uint256,bytes[])")
            static let swapRouter02ExactInputSingle = ABI.selector("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")
            static let swapRouter02ExactInput = ABI.selector("exactInput((bytes,address,uint256,uint256))")
            static let mondayMulticall = ABI.selector("multicall(bytes[])")
            static let mondayExactInputSingle = ABI.selector("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")
            static let mondayExactInput = ABI.selector("exactInput((bytes,address,uint256,uint256,uint256))")
            static let unwrapWETH9 = ABI.selector("unwrapWETH9(uint256,address)")
            static let refundETH = ABI.selector("refundETH()")
            static let wmonDeposit = ABI.selector("deposit()")
            static let wmonWithdraw = ABI.selector("withdraw(uint256)")
            static let curveBuy = ABI.selector(LaunchpadABI.Curve.buy)
            static let curveSell = ABI.selector(LaunchpadABI.Curve.sell)
            static let graduateFallback = ABI.selector(LaunchpadABI.Factory.graduateFallback)
            static let launchAndBuy = ABI.selector(LaunchpadABI.Router.launchAndBuy)
            static let momentsCollect = ABI.selector(MomentsABI.Collect.collect)
            static let vestingClaim = ABI.selector(MomentsABI.Vesting.claim)
            static let vestingClaimAll = ABI.selector(MomentsABI.Vesting.claimAll)
            static let withdrawCreator = ABI.selector(MomentsABI.Collect.withdrawCreator)
            static let perplCreateAccount = ABI.selector(PerplExchange.Signature.createAccount)
            static let perplDeposit = ABI.selector(PerplExchange.Signature.depositCollateral)
            static let perplWithdraw = ABI.selector(PerplExchange.Signature.withdrawCollateral)
            static let perplExecOrders = ABI.selector(PerplExchange.Signature.execOrders)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
