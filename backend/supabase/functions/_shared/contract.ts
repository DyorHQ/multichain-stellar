// The Lite API's wire contract, as types: every request and response body of docs/API-lite.md. The phone decodes the
// same shapes (ios/Packages/StellarKit/Sources/LiteClient/Models*.swift), and backend/tests/fixtures/api/ holds an
// example of each. Types only: a route module annotates what it answers with these, so the compiler holds the server
// to the contract. A field marked "added" is new in the parity API: the phone also decodes payloads without it.

// ------------------------------------------------------------------------------------------------ conventions

/** Base units as a decimal-integer string: "12500000" is 1.25 of a 7-decimal asset. */
export type Units = string;
/** Stroops (1 XLM = 10,000,000), as a decimal-integer string. */
export type Stroops = string;
/** USD as a JSON number; null when unknown, never 0 for unknown. */
export type Usd = number | null;
/** A price in a quote asset, a decimal string in human units: "0.0000021". */
export type QuotePrice = string;
/** A change or a rate as a fraction: 0.0123 is +1.23%. */
export type Fraction = number;
/** ISO 8601, UTC, with milliseconds: "2026-10-14T09:41:00.000Z". */
export type IsoTime = string;
/** G… */
export type AccountAddress = string;
/** C… */
export type ContractAddress = string;
/** A registry asset id ("XLM", "USDC", "BUSDC") or a token's contract id. */
export type AssetId = string;
/** The app's VolumePeriod raw values. */
export type Period = "day" | "week" | "month" | "all";

export type NetworkName = "testnet" | "mainnet";
export type Section = "spot" | "earn" | "launch" | "moments" | "bridge" | "cash" | "account";
export type FeePayer = "user" | "sponsor" | "external";
export type SponsorReason = "setup" | "starter_swap";
export type LaunchPhase = "curve" | "completed" | "graduated";
export type MomentState = "collecting" | "sold_out" | "closed";
export type PartStatus = "ok" | "failed";
export type SwapVenue = "sdex" | "soroswap" | "aquarius";
export type BridgeDirection = "monad_to_stellar" | "stellar_to_monad";
/** A row's badges: a DyorHQ launch, a trustline outside the registry, a ticker that imitates another (never listed),
 *  a test-only asset (Blend's test USDC). */
export type Badge = "launch" | "unverified" | "lookAlike" | "testAsset";
/** Why a quote isn't the sponsored starter swap: the network doesn't sponsor (testnet), the swap doesn't buy XLM or
 *  doesn't sell a registry asset, the account already has XLM to spend, the output is too small, or the one starter
 *  swap is used. */
export type StarterSwapReason = "activation" | "buy_not_xlm" | "sell_not_registry" | "has_xlm" | "too_small" | "used";

/** Step kinds, as fees are estimated and transactions logged. */
export type StepKind =
  | "payment"
  | "payment_token"
  | "trust"
  | "activate"
  | "restore"
  | "swap_sdex"
  | "swap_soroswap"
  | "swap_aquarius"
  | "blend_submit_deposit"
  | "blend_submit_withdraw"
  | "launch_create"
  | "launch_buy"
  | "launch_sell"
  | "launch_graduate"
  | "launch_claim"
  | "moment_publish"
  | "moment_collect"
  | "token_approve"
  | "cctp_burn";

// ------------------------------------------------------------------------------------------------ errors

/** Codes the API answers with (HTTP status in docs/API-lite.md "Errors"). */
export type ErrorCode =
  // request and session
  | "bad_json"
  | "too_large"
  | "bad_arg"
  | "bad_amount"
  | "bad_address"
  | "rate_limited"
  | "unauthorized"
  | "not_invited"
  | "bad_invite"
  | "access_revoked"
  | "not_found"
  | "no_route"
  | "internal"
  // account, send, faucet
  | "bad_asset"
  | "bad_memo"
  | "too_small"
  | "testnet_only"
  | "no_friendbot"
  | "friendbot_failed"
  | "friendbot_slow"
  | "faucet_used"
  | "account_inactive"
  | "recipient_inactive"
  | "recipient_cannot_receive"
  // plans and transactions
  | "empty_plan"
  | "plan_expired"
  | "not_ready"
  | "not_built"
  | "already_sent"
  | "stale_step"
  | "unsigned"
  | "self_check_failed"
  | "bad_xdr"
  | "needs_restore"
  | "simulation_failed"
  | "tx_rejected"
  | "network_busy"
  | "rpc_unavailable"
  | "budget_exhausted"
  // swap, earn, launches, moments, media
  | "same_asset"
  | "bad_slippage"
  | "quote_expired"
  | "bad_pool"
  | "bad_action"
  | "bad_request_type"
  | "bad_side"
  | "bad_quote"
  | "bad_name"
  | "bad_symbol"
  | "bad_fee"
  | "bad_uri"
  | "bad_title"
  | "bad_media"
  | "bad_moment"
  | "bad_quantity"
  | "bad_editions"
  | "bad_window"
  | "bad_type"
  | "not_deployed"
  | "storage_unavailable"
  | "storage_error"
  // bridge and cash
  | "bad_direction"
  | "bad_hash"
  | "bad_spender"
  | "needs_usdc"
  | "mainnet_route"
  | "bridge_quote_failed"
  | "bad_anchor"
  | "bad_kind"
  // added: hybrid fees, sponsorship, recipients, launches, budgets (DESIGN-stellar-parity §6.13)
  | "not_enough_xlm_for_fee"
  | "not_enough_xlm_for_reserve"
  | "not_enough_xlm"
  | "fee_too_high"
  | "sponsor_limit"
  | "already_set_up"
  | "unsupported_asset"
  | "look_alike_symbol"
  | "muxed_unsupported"
  | "recipient_missing"
  | "recipient_no_trust"
  | "upload_budget"
  | "bridge_relay_limit";

/** A contract's own refusal, named in `simulation_failed`'s detail. Stable across contract versions. */
export type ContractErrorCode =
  | "launch.slippage"
  | "launch.closed"
  | "launch.disabled"
  | "launch.nothing_to_claim"
  | "moment.closed"
  | "moment.sold_out"
  | "moment.price_too_low"
  | "trust.missing";

/** Facts an error carries. Informational except `contractCode`, which the phone words. */
export interface ErrorDetail {
  /** `simulation_failed` only, when a contract refused for a known reason. */
  contractCode?: ContractErrorCode;
  /** `simulation_failed` / `rpc_unavailable`: the start of the raw error, for logs. */
  raw?: string;
  /** `fee_too_high`: the declared fee and the cap, in stroops. */
  fee?: Stroops;
  max?: Stroops;
  /** `tx_rejected`: Stellar's result code. */
  code?: string;
  /** `not_enough_xlm*`: what the action needs and what the account can spend, in stroops. */
  need?: Stroops;
  spendable?: Stroops;
  /** `recipient_*`, `unsupported_asset`, `trust.missing`: the asset concerned. */
  asset?: AssetId;
  /** `moment.price_too_low`: the lowest price, in base units. */
  minPrice?: Units;
  [extra: string]: unknown;
}

export interface ErrorBody {
  /** `detail` is absent from errors raised outside a route (the last-resort `internal`). */
  error: { code: ErrorCode; message: string; detail?: ErrorDetail | null };
}

// ------------------------------------------------------------------------------------------------ auth (public)

export interface ChallengeRequest {
  address: AccountAddress;
}

export interface AuthChallenge {
  nonce: string;
  /** The exact text the phone signs (SEP-53): product, network, address, nonce and time, one per line. */
  message: string;
  expiresAt: IsoTime;
}

export interface VerifyRequest {
  address: AccountAddress;
  nonce: string;
  /** Base64 ed25519 signature of the SEP-53 digest of `message`. */
  signature: string;
  /** A first sign-in only. */
  inviteCode?: string;
}

export interface AuthResult {
  /** The Lite session token, sent as `authorization: Bearer …`. */
  token: string;
  expiresAt: IsoTime;
  tester: { address: AccountAddress; label: string | null };
}

// ------------------------------------------------------------------------------------------------ config (public)

export interface AssetInfo {
  id: AssetId;
  code: string;
  name: string;
  decimals: number;
  contract: ContractAddress;
  /** "native" or "CODE:ISSUER"; null for a Soroban-only token. */
  classic: string | null;
  note?: string;
  /** Added: the reference price this asset is valued at. */
  priceRef?: "XLM" | "USDC" | null;
  /** Added: a bundled logo key, or null. */
  logo?: "XLM" | "USDC" | null;
  /** Added: false for an asset that never shows in Top Tokens (BUSDC). */
  listed?: boolean;
}

export interface AnchorInfo {
  domain: string;
  name: string;
  assets: string[];
  countries: string[];
  kinds: ("deposit" | "withdraw")[];
}

export interface Pricing {
  kind: "reference" | "market";
  source: string;
  network: NetworkName;
  note: string | null;
}

export interface FeePolicy {
  payer: "user";
  maxFee: Stroops;
  maxInclusionPerOp: Stroops;
  starterInnerFeeMax: Stroops;
  starterSwap: boolean;
  fundingFloor: Stroops;
}

export interface Limits {
  momentMaxEditions: number;
  /** [shortest, longest] collect window, seconds. */
  momentWindowSecs: [number, number];
  collectMax: number;
  /** [least, most] UTF-8 bytes. */
  launchName: [number, number];
  /** [least, most] characters. */
  launchSymbol: [number, number];
  uriMax: number;
  uploadBytes: number;
}

export interface LiteConfig {
  network: NetworkName;
  passphrase: string;
  rpcUrl: string;
  horizonUrl: string;
  activation: "friendbot" | "sponsored";
  sponsor: AccountAddress;
  assets: AssetInfo[];
  contracts: {
    launchpad: ContractAddress | null;
    moments: ContractAddress | null;
    soroswapRouter: ContractAddress;
    soroswapFactory: ContractAddress;
    aquariusRouter: ContractAddress | null;
    blendPools: { id: ContractAddress; name: string }[];
    cctp: { tokenMessengerMinter: ContractAddress; messageTransmitter: ContractAddress; forwarder: ContractAddress; domain: number } | null;
  };
  /** Contract ids by role; the phone's pins win. */
  allowlist: Record<string, ContractAddress[]>;
  anchors: AnchorInfo[];
  bridge: { routes: ("cctp" | "oneclick")[]; monad: { chainId: number; usdc: string } | null };
  flags: { enabled: boolean; maintenance?: boolean };
  minBuild: number;
  /** Added. */
  deployment?: { id: string; launchpad: ContractAddress | null; moments: ContractAddress | null };
  /** Added: StellarExpert's base for this network (informational; the phone builds links from its pins). */
  explorer?: string;
  /** Added: informational; the caps the phone enforces are pinned in the app. */
  fees?: FeePolicy;
  /** Added: null off testnet. */
  faucet?: { amount: string } | null;
  /** Added. */
  limits?: Limits;
  /** Added. */
  pricing?: Pricing;
}

// ------------------------------------------------------------------------------------------------ fees (public)

export interface Fees {
  network: NetworkName;
  baseReserve: Stroops;
  baseFee: Stroops;
  inclusionFee: { classic: Stroops; soroban: Stroops };
  /** p90 of the last 7 days' declared fee per step kind, × 5/4; never above the policy's maxFee. */
  estimates: Partial<Record<StepKind, Stroops>>;
  estimateBasis: Partial<Record<StepKind, "history" | "default">>;
  updatedAt: IsoTime | null;
}

// ------------------------------------------------------------------------------------------------ account

export interface BalanceRow {
  asset: AssetId;
  code: string;
  name: string;
  contract: ContractAddress;
  classic: string | null;
  decimals: number;
  balance: Units;
  /** Trustline present (classic), or always true (Soroban). */
  enabled: boolean;
  note?: string;
  /** Added. */
  kind?: "native" | "classic" | "sac" | "launch";
  /** Added. */
  verified?: boolean;
  /** Added. */
  logo?: string | null;
}

export interface XlmPosition {
  balance: Stroops;
  minBalance: Stroops;
  sellingLiabilities: Stroops;
  spendable: Stroops;
  baseReserve: Stroops;
  reserves: { base: number; subentries: number; sponsoring: number; sponsored: number };
}

export interface FirstFunding {
  needsXlm: boolean;
  suggestXlm: Stroops;
  starterSwap: "available" | "used" | "unavailable";
  /** Testnet only. */
  faucet: { amount: string; usedToday: boolean } | null;
}

export interface AccountView {
  address: AccountAddress;
  exists: boolean;
  network: NetworkName;
  activation: "friendbot" | "sponsored";
  balances: BalanceRow[];
  reserves: { subentries: number; sponsoredByDyorHQ: number } | null;
  sponsor: AccountAddress;
  /** Added: null when the account doesn't exist. */
  xlm?: XlmPosition | null;
  /** Added. */
  firstFunding?: FirstFunding;
}

/** POST /v1/account/activate: a plan to run, or the account when there is nothing to do. */
export type ActivationResult = PlanView | { status: "active"; account: AccountView };

export interface TrustRequest {
  asset: AssetId;
}

export interface FaucetResult {
  hash: string;
}

export interface SendRequest {
  asset: AssetId;
  to: AccountAddress | ContractAddress;
  amount: Units;
  memo?: string;
  memoType?: "text" | "id" | "hash";
}

export interface Recipient {
  kind: "account" | "contract";
  exists: boolean;
  /** Null where it doesn't apply (XLM, a contract). */
  trusts: boolean | null;
}

// ------------------------------------------------------------------------------------------------ plans and transactions

export type DisplayValue = string | number | boolean | null;

export interface Intent {
  kind: string;
  /** A plain-language hint; the phone words the review from the fields below. */
  summary: string;
  /** The most the user's account may send, per asset contract, base units. */
  spend: Record<ContractAddress, Units>;
  receive?: Record<ContractAddress, Units>;
  calls?: { contract: ContractAddress; fn: string }[];
  ops?: string[];
  trust?: string[];
  display?: Record<string, DisplayValue>;
  /** Added: the destination the user confirmed (G…, C…, or for bridge_out the Monad address as 0x-hex). */
  to?: string;
  /** Added: the memo the user confirmed. */
  memo?: { type: "text" | "id" | "hash"; value: string };
}

export type StepStatus = "pending" | "built" | "submitted" | "done" | "failed";

export interface PlanStep {
  id: string;
  label: string;
  status: StepStatus;
  intent?: Intent;
  xdr?: string;
  hash?: string;
  txHash?: string;
  builtAt?: IsoTime;
  error?: string;
  /** Added. */
  stepKind?: StepKind;
  /** Added: a built step's tx.fee; an unbuilt step's ceiling for its kind. */
  maxFee?: Stroops;
  /** Added. */
  feePayer?: "user" | "sponsor";
  /** Added: only when feePayer is "sponsor". */
  sponsorReason?: SponsorReason | null;
  /** Added: new base reserves the step holds back. */
  reserveDelta?: number;
}

export interface PlanView {
  planId: string;
  kind: string;
  expiresAt: IsoTime;
  steps: PlanStep[];
  /** Added. */
  fees?: { userMax: Stroops; sponsored: boolean; newReserves: number };
}

export interface SubmitRequest {
  planId: string;
  stepId: string;
  signedXdr: string;
}

export interface Submitted {
  hash: string;
  status: "pending";
}

export interface TxStatus {
  hash: string;
  status: "pending" | "success" | "failed";
  ledger?: number;
  error?: string;
  returnValue?: unknown;
  /** Added: once settled. */
  feeCharged?: Stroops;
  /** Added. */
  feePayer?: FeePayer;
  /** Added. */
  result?: { amountOut: Units | null };
}

// ------------------------------------------------------------------------------------------------ swap

export interface SwapQuoteRequest {
  sell: AssetId;
  buy: AssetId;
  amount: Units;
  slippageBps?: number;
}

export interface SwapRoute {
  venue: SwapVenue;
  amountOut: Units;
  path: string[];
  chainXdr?: string;
}

export interface QuoteRoute {
  venue: SwapVenue;
  amountOut: Units;
  minOut: Units;
  priceImpactBps: number | null;
  path: string[];
  best: boolean;
}

export interface SwapQuote {
  quoteId: string;
  sell: AssetId;
  buy: AssetId;
  amountIn: Units;
  slippageBps: number;
  /** Kept for older clients: `routes` carries every venue. */
  best: SwapRoute & { minOut: Units };
  alternatives: SwapRoute[];
  expiresAt: IsoTime;
  /** Added. */
  routes?: QuoteRoute[];
  /** Added: asset ids the user must enable first. */
  needsEnable?: AssetId[];
  /** Added. */
  starterSwap?: { eligible: boolean; reason: StarterSwapReason | null };
}

export interface SwapBuildRequest {
  quoteId: string;
  /** Added: one of the quote's routes; the best when absent. */
  venue?: SwapVenue;
}

// ------------------------------------------------------------------------------------------------ markets and assets (public)

export interface MarketRow {
  id: AssetId;
  kind: "registry" | "launch";
  contract: ContractAddress;
  classic: string | null;
  code: string;
  name: string;
  decimals: number;
  logo: string | null;
  /** A launch's image on DyorHQ's media storage. */
  image: string | null;
  verified: boolean;
  badges: Badge[];
  note: string | null;
  priceUsd: Usd;
  /** Null while `isNew`. */
  change24h: Fraction | null;
  isNew: boolean;
  volume24hUsd: Usd;
  marketCapUsd: Usd;
  priceSource:
    | { kind: "reference"; market: string; at: IsoTime | null }
    | { kind: "curve" | "pool"; quote: string; quotePrice: QuotePrice; at: IsoTime | null };
  stale: boolean;
  launch: { phase: LaunchPhase; progress: Fraction; pair: ContractAddress | null } | null;
}

export interface Markets {
  asOf: IsoTime;
  pricing: Pricing;
  rows: MarketRow[];
}

export interface MarketDetail {
  row: MarketRow;
  about: { contract: ContractAddress; classic: string | null; issuer: AccountAddress | null; decimals: number; homeDomain: string | null };
}

export interface PriceHistory {
  id: AssetId;
  range: Period;
  intervalS: number;
  /** The provider ("Kraken"), or "curve+pool" for a launch. */
  source: string;
  complete: boolean;
  points: { t: IsoTime; usd: number }[];
}

export interface AssetResult {
  id: AssetId;
  kind: "registry" | "launch" | "classic" | "contract";
  code: string;
  name: string | null;
  contract: ContractAddress;
  classic: string | null;
  verified: boolean;
  held: boolean;
}

export interface AssetSearch {
  results: AssetResult[];
}

/** GET /v1/prices: kept for older clients. */
export interface Prices {
  usd: Record<string, number>;
  reference: string;
  at: IsoTime;
}

// ------------------------------------------------------------------------------------------------ holdings and portfolio

export interface SpotHolding {
  id: AssetId;
  kind: "registry" | "classic";
  contract: ContractAddress;
  classic: string | null;
  code: string;
  name: string | null;
  decimals: number;
  balance: Units;
  enabled: boolean;
  verified: boolean;
  badges: Badge[];
  note: string | null;
  logo: string | null;
  priceUsd: Usd;
  valueUsd: Usd;
  change24h: Fraction | null;
}

export interface EarnPosition {
  pool: ContractAddress;
  asset: ContractAddress;
  code: string;
  supplied: Units;
  /** Older servers only. */
  bTokens?: Units;
  /** Added. */
  poolName?: string;
  /** Added. */
  deposited?: Units;
  /** Added. */
  withdrawn?: Units;
  /** Added. */
  earned?: Units;
  /** Added: false when deposits from before the server recorded them are missing. */
  earnedComplete?: boolean;
  /** Added. */
  supplyApy?: Fraction;
  /** Added. */
  valueUsd?: Usd;
}

export interface LaunchHolding {
  token: ContractAddress;
  symbol: string;
  name: string;
  image: string | null;
  balance: Units;
  priceUsd: Usd;
  valueUsd: Usd;
  change24h: Fraction | null;
  phase: LaunchPhase;
  progress: Fraction;
  costBasisUsd: Usd;
  pnlUsd: Usd;
  /** The live balance couldn't be read; this is the indexed one. */
  stale: boolean;
}

export interface Edition {
  tokenId: number;
  momentId: number;
  title: string | null;
  mediaUrl: string | null;
  /** Added. */
  posterUrl?: string | null;
  /** Added. */
  mediaType?: "image" | "video" | null;
  /** Added. */
  contract?: ContractAddress;
}

export interface Holdings {
  address: AccountAddress;
  exists: boolean;
  asOf: IsoTime;
  pricing: Pricing;
  xlm: XlmPosition | null;
  spot: SpotHolding[];
  earn: EarnPosition[];
  launch: LaunchHolding[];
  moments: { count: number; editions: Edition[] };
  /** A part is null, and complete false, when it couldn't be read. Moments are worth 0. */
  totals: { spot: Usd; earn: Usd; launch: Usd; moments: Usd; total: Usd; complete: boolean };
  change24h: { usd: Usd; pct: Fraction | null; complete: boolean };
  parts: { spot: PartStatus; earn: PartStatus; launch: PartStatus; moments: PartStatus };
}

export interface Stats {
  volume: number;
  fees: number;
  pnl: number;
  claimedFees: number;
  trades: number;
  pnlComplete: boolean;
  /** Network fees the user paid in the section; never part of `fees`. */
  networkFeesXlm: Stroops;
  networkFeesUsd: Usd;
}

export interface PortfolioItem {
  /** A transaction hash or a transfer's id. */
  id: string;
  section: Section;
  kind: string;
  title: string;
  subtitle: string | null;
  at: IsoTime;
  usd: Usd;
  hash: string | null;
}

export interface Portfolio {
  period: Period;
  /** Null for all time. */
  since: IsoTime | null;
  asOf: IsoTime;
  pricing: Pricing;
  totals: Stats;
  sections: { spot: Stats; earn: Stats; launch: Stats; moments: Stats; bridge: Stats };
  activity: PortfolioItem[];
  coverage: { from: IsoTime | null; note: string | null };
}

// ------------------------------------------------------------------------------------------------ launches

export interface LaunchRow {
  token: ContractAddress;
  creator: AccountAddress;
  quote: ContractAddress;
  name: string;
  symbol: string;
  uri: string;
  supply: Units;
  quoteReserve: Units;
  tokenReserve: Units;
  realQuote: Units;
  threshold: Units;
  progress: Fraction;
  completed: boolean;
  graduated: boolean;
  pair: ContractAddress | null;
  lastPrice: QuotePrice | null;
  /** All-time curve volume in the quote asset, base units. */
  volume: Units;
  trades: number;
  createdAt: IsoTime;
  // Added (DESIGN-stellar-parity §6.9):
  quoteCode?: string;
  image?: string | null;
  description?: string | null;
  links?: { website: string | null; x: string | null; telegram: string | null };
  burned?: Units;
  circulating?: Units;
  phase?: LaunchPhase;
  priceQuote?: QuotePrice;
  priceUsd?: Usd;
  change24h?: Fraction | null;
  isNew?: boolean;
  marketCapQuote?: QuotePrice;
  marketCapUsd?: Usd;
  volume24hQuote?: QuotePrice;
  volume24hUsd?: Usd;
  holders?: number;
  holdersComplete?: boolean;
  feeBps?: number;
  protocolShareBps?: number;
  creatorFeeBps?: number;
  poolFeeBps?: number | null;
  lookAlike?: boolean;
  graduatedAt?: IsoTime | null;
  lastTradeAt?: IsoTime | null;
}

export interface LaunchBoard {
  launches: LaunchRow[];
  /** Added. */
  nextCursor?: string | null;
  /** Added. */
  counts?: { explore: number; graduated: number };
}

export interface LaunchTrade {
  trader: AccountAddress;
  side: "buy" | "sell";
  quoteAmount: Units;
  tokenAmount: Units;
  price: QuotePrice;
  txHash: string | null;
  ts: IsoTime;
  /** Added. */
  venue?: "curve" | "soroswap";
}

export interface Candle {
  t: IsoTime;
  o: QuotePrice;
  h: QuotePrice;
  l: QuotePrice;
  c: QuotePrice;
  v: Units;
}

export interface CreatorFees {
  unclaimed: Units;
  claimed: Units;
  quote: AssetId;
  unclaimedUsd: Usd;
  claimedUsd: Usd;
}

export interface LaunchDetail {
  launch: LaunchRow;
  /** Read live; null when the RPC didn't answer. */
  curve: {
    quoteReserve: Units;
    tokenReserve: Units;
    realQuote: Units;
    threshold: Units;
    creatorFees: Units;
    completed: boolean;
    graduated: boolean;
    pair: ContractAddress | null;
  } | null;
  /** Newest 50, curve and pool merged. */
  trades: LaunchTrade[];
  candles: Candle[];
  /** Added. */
  stats?: {
    volume24hQuote: QuotePrice;
    volume24hUsd: Usd;
    holders: number;
    holdersComplete: boolean;
    marketCapQuote: QuotePrice;
    marketCapUsd: Usd;
    priceQuote: QuotePrice;
    priceUsd: Usd;
    change24h: Fraction | null;
  };
  /** Added. */
  creatorFees?: CreatorFees;
  /** Added. */
  you?: { balance: Units; costBasisQuote: Units | null; pnlQuote: Units | null; isCreator: boolean };
  /** Added. */
  economics?: { feeBps: number; protocolShareBps: number; creatorFeeBps: number; supply: Units; phantom: Units; threshold: Units };
  /** Added: at most 300. */
  pricePoints?: { t: IsoTime; price: QuotePrice }[];
}

export interface TradeQuoteRequest {
  side: "buy" | "sell";
  amount: Units;
}

export interface TradeQuote {
  side: "buy" | "sell";
  /** Buy: what the curve takes from the amount (a full curve refunds the rest). */
  used?: Units;
  tokensOut?: Units;
  quoteOut?: Units;
  /** Every fee together. */
  fees: Units;
  snipeFee?: Units;
  /** Added. */
  baseFee?: Units;
  /** Added. */
  creatorFee?: Units;
  /** Added. */
  refund?: Units;
}

export interface LaunchMetadataRequest {
  name: string;
  symbol: string;
  description?: string;
  /** Must start with `<media base>uploads/<user>/`. */
  imageUrl?: string;
  website?: string;
  x?: string;
  telegram?: string;
}

export interface MetadataUri {
  uri: string;
}

export interface LaunchBuildRequest {
  action: "create" | "buy" | "sell" | "graduate" | "claim";
  token?: ContractAddress;
  quote?: AssetId;
  name?: string;
  symbol?: string;
  uri?: string;
  creatorFeeBps?: number;
  amount?: Units;
  minOut?: Units;
}

export interface Economics {
  launchpad: {
    contract: ContractAddress;
    launchesEnabled: boolean;
    supply: Units;
    feeBps: number;
    protocolShareBps: number;
    maxCreatorFeeBps: number;
    /** Early-buy tax in bps by ledger offset from the launch ledger. */
    snipeSchedule: number[];
    quotes: { asset: AssetId; contract: ContractAddress; phantom: Units; threshold: Units; enabled: boolean }[];
  } | null;
  moments: {
    contract: ContractAddress;
    platformBps: number;
    royaltyBps: number;
    publishingEnabled: boolean;
    /** Shown in the publish review only. */
    treasury: AccountAddress;
    maxPerCollect: number;
    maxEditions: number;
    quotes: { asset: AssetId; minPrice: Units; enabled: boolean }[];
  } | null;
}

export interface MyLaunchpad {
  held: {
    token: ContractAddress;
    balance: Units;
    valueUsd: Usd;
    costBasisQuote: Units | null;
    pnlQuote: Units | null;
    pnlUsd: Usd;
    onCurve: boolean;
    launch: LaunchRow;
  }[];
  created: { launch: LaunchRow; creatorFees: CreatorFees }[];
  fees: { byQuote: { quote: AssetId; received: Units; claimable: Units; receivedUsd: Usd; claimableUsd: Usd }[] };
  activity: ActivityItem[];
}

// ------------------------------------------------------------------------------------------------ moments and media

export interface MomentRow {
  id: number;
  creator: AccountAddress;
  uri: string;
  title: string | null;
  mediaUrl: string | null;
  price: Units;
  quote: ContractAddress;
  /** 0 is an open edition. */
  maxEditions: number;
  minted: number;
  deadline: IsoTime;
  open: boolean;
  createdAt: IsoTime;
  // Added (DESIGN-stellar-parity §6.9):
  description?: string | null;
  place?: string | null;
  /** "2026-10-14". */
  takenOn?: string | null;
  mediaType?: "image" | "video";
  posterUrl?: string | null;
  quoteCode?: string;
  priceUsd?: Usd;
  collects?: number;
  collectors?: number;
  state?: MomentState;
  platformBps?: number;
  royaltyBps?: number;
  publishedAt?: IsoTime;
}

export interface MomentFeed {
  moments: MomentRow[];
}

export interface MomentDetail {
  moment: MomentRow;
  collectors: { collector: AccountAddress; quantity: number; firstTokenId: number; ts: IsoTime }[];
  /** Added. */
  collectorsSummary?: { count: number; largest: { address: AccountAddress; editions: number } | null };
  /** Added. */
  you?: { editions: number[]; spent: Units };
  /** Added: base units of the Moment's quote asset. */
  creatorEarned?: Units;
}

export interface OwnedEditions {
  editions: Edition[];
}

export interface MyMoments {
  created: (MomentRow & { proceeds: Units; proceedsUsd: Usd })[];
  collected: { tokenId: number; momentId: number; contract: ContractAddress; moment: MomentRow }[];
  totals: { editions: number; moments: number; spentByQuote: Record<AssetId, Units>; earnedByQuote: Record<AssetId, Units> };
}

export interface MomentMetadataRequest {
  title: string;
  description?: string;
  mediaUrl: string;
  mediaType: "image" | "video";
  /** Added: required for a video. */
  posterUrl?: string;
  /** Added. */
  place?: string;
  /** Added: "2026-10-14". */
  takenOn?: string;
}

export interface MomentMetadata {
  uri: string;
  /** Added: the photo, or the video's poster. */
  posterUrl?: string;
}

export type MomentBuildRequest =
  | { action: "publish"; uri: string; price: Units; quote: AssetId; maxEditions: number; windowSecs: number }
  | { action: "collect"; momentId: number; quantity: number };

export interface UploadRequest {
  contentType: "image/jpeg" | "image/png" | "image/webp" | "image/gif" | "video/mp4" | "video/quicktime";
  bytes: number;
}

export interface UploadTicket {
  /** A one-time signed URL: PUT the file there. */
  uploadUrl: string;
  publicUrl: string;
  path: string;
}

// ------------------------------------------------------------------------------------------------ earn

export interface EarnMarket {
  pool: ContractAddress;
  poolName: string;
  asset: ContractAddress;
  code: string;
  decimals: number;
  supplyApy: Fraction;
  borrowApy: Fraction;
  utilization: Fraction;
  totalSupplied: number;
  note?: string;
  /** Added. */
  totalSuppliedUsd?: Usd;
  /** Added: supplied less borrowed. */
  freeLiquidityUsd?: Usd;
  /** Added. */
  priceUsd?: Usd;
  /** Added: Blend's pool status 0–1 active, 2–3 on ice, 4–5 and setup frozen. */
  poolStatus?: "active" | "on_ice" | "frozen";
}

export interface EarnMarkets {
  markets: EarnMarket[];
  note: string | null;
}

export interface EarnPositions {
  positions: EarnPosition[];
}

export interface EarnHistory {
  points: { t: IsoTime; supplyApy: Fraction; utilization: Fraction }[];
}

export interface EarnBuildRequest {
  action: "deposit" | "withdraw";
  pool: ContractAddress;
  asset: ContractAddress;
  amount: Units;
}

// ------------------------------------------------------------------------------------------------ activity

export interface ActivityItem {
  type: "tx" | "bridge" | "cash";
  id: string;
  kind: string;
  /** The server's English words; the phone words known kinds itself. */
  summary: string;
  status: string;
  at: IsoTime;
  /** Bridge: base units of the sending side's USDC; cash: the anchor's amount as written. */
  amount?: string | null;
  display?: Record<string, DisplayValue> | null;
  /** Added. */
  section?: Section;
  /** Added. */
  hash?: string | null;
  /** Added. */
  feeCharged?: Stroops | null;
  /** Added. */
  feePayer?: FeePayer | null;
  /** Added. */
  result?: { amountOut: Units | null } | null;
  /** Added. */
  ref?: { token?: ContractAddress; momentId?: number; market?: string } | null;
  /** Added. */
  symbol?: string | null;
  /** Added. */
  name?: string | null;
  /** Added. */
  title?: string | null;
  /** Added. */
  subtitle?: string | null;
  /** Added. */
  usd?: Usd;
}

export interface Activity {
  items: ActivityItem[];
}

// ------------------------------------------------------------------------------------------------ bridge and cash

export interface BridgeQuoteRequest {
  direction: BridgeDirection;
  /** The sending side's base units (6 decimals on Monad, 7 on Stellar). */
  amount: Units;
}

export interface BridgeQuote {
  route: "cctp" | "oneclick";
  direction: BridgeDirection;
  amountIn: Units;
  amountOut: Units;
  /** The bridge's own fee, in the sending side's base units. */
  fee?: Units;
  /** Added. */
  feeSource?: "circle-iris";
  /** The median of the last 20 completed transfers this way; null with fewer than 3. */
  etaSeconds: number | null;
  /** Added: how many transfers the median is over. */
  etaBasis?: number;
  note?: string;
  /** 1Click (mainnet) only. */
  depositAddress?: string | null;
  depositMemo?: string | null;
}

export interface BridgeStartRequest {
  direction: BridgeDirection;
  amount: Units;
  /** 0x… */
  monadAddress: string;
}

export interface EvmStep {
  kind: "evm";
  chainId: number;
  label: string;
  to: string;
  data: string;
  value: string;
}

export interface BridgeTransfer {
  id: string;
  status: string;
  direction: BridgeDirection;
}

export interface BridgeStart {
  transfer: BridgeTransfer;
  /** Stellar → Monad: approve, then burn. */
  plan?: PlanView;
  /** Monad → Stellar: the steps the Monad wallet signs. */
  evmSteps?: EvmStep[];
}

export interface BridgeTxRequest {
  txHash: string;
}

export interface BridgeStatus {
  id: string;
  direction: BridgeDirection;
  route: "cctp" | "oneclick";
  amount: Units;
  recipient: string;
  status: string;
  sourceTx: string | null;
  destTx: string | null;
  error: string | null;
  /** Stellar → Monad, once attested: the Monad step that claims it. */
  claim?: EvmStep;
}

export interface CashAnchors {
  anchors: AnchorInfo[];
}

export interface CashTrackRequest {
  anchor: string;
  kind: "deposit" | "withdraw";
  asset: string;
  amount?: string;
  anchorTxId: string;
  status?: string;
}

export interface CashTracked {
  id: string;
}

// ------------------------------------------------------------------------------------------------ routes

/** Every route: its auth ("public" routes take no token and are cacheable), query, body and answer. */
export interface Routes {
  "POST /v1/auth/challenge": { auth: "public"; body: ChallengeRequest; response: AuthChallenge };
  "POST /v1/auth/verify": { auth: "public"; body: VerifyRequest; response: AuthResult };
  "GET /v1/config": { auth: "public"; response: LiteConfig };
  "GET /v1/fees": { auth: "public"; response: Fees };
  "GET /v1/markets": { auth: "public"; response: Markets };
  "GET /v1/markets/:id": { auth: "public"; response: MarketDetail };
  "GET /v1/markets/:id/history": { auth: "public"; query: { range: Period }; response: PriceHistory };
  "GET /v1/assets": { auth: "jwt"; query: { q: string }; response: AssetSearch };
  "GET /v1/prices": { auth: "jwt"; response: Prices };
  "GET /v1/account": { auth: "jwt"; response: AccountView };
  "POST /v1/account/activate": { auth: "jwt"; response: ActivationResult };
  "POST /v1/account/trust": { auth: "jwt"; body: TrustRequest; response: PlanView };
  "POST /v1/account/faucet": { auth: "jwt"; response: FaucetResult };
  "GET /v1/recipient/:address": { auth: "jwt"; query: { asset: AssetId }; response: Recipient };
  "POST /v1/send": { auth: "jwt"; body: SendRequest; response: PlanView };
  "GET /v1/holdings": { auth: "jwt"; response: Holdings };
  "GET /v1/portfolio": { auth: "jwt"; query: { period: Period }; response: Portfolio };
  "POST /v1/plans/:plan/steps/:step/build": { auth: "jwt"; response: PlanView };
  "POST /v1/tx/submit": { auth: "jwt"; body: SubmitRequest; response: Submitted };
  "GET /v1/tx/:hash": { auth: "jwt"; response: TxStatus };
  "POST /v1/swap/quote": { auth: "jwt"; body: SwapQuoteRequest; response: SwapQuote };
  "POST /v1/swap/build": { auth: "jwt"; body: SwapBuildRequest; response: PlanView };
  "GET /v1/earn/markets": { auth: "jwt"; response: EarnMarkets };
  "GET /v1/earn/positions": { auth: "jwt"; response: EarnPositions };
  "GET /v1/earn/history": { auth: "jwt"; query: { pool: ContractAddress; asset: ContractAddress; range: "week" | "month" }; response: EarnHistory };
  "POST /v1/earn/build": { auth: "jwt"; body: EarnBuildRequest; response: PlanView };
  "GET /v1/launches": {
    auth: "jwt";
    query: {
      section?: "explore" | "graduated";
      sort?: "newest" | "market_cap" | "near_graduation" | "new" | "hot" | "graduated";
      q?: string;
      limit?: number;
      cursor?: string;
    };
    response: LaunchBoard;
  };
  "GET /v1/launches/:token": { auth: "jwt"; query: { candles?: "1m" | "5m" | "1h" | "1d" }; response: LaunchDetail };
  "POST /v1/launches/:token/quote": { auth: "jwt"; body: TradeQuoteRequest; response: TradeQuote };
  "POST /v1/launches/metadata": { auth: "jwt"; body: LaunchMetadataRequest; response: MetadataUri };
  "POST /v1/launches/build": { auth: "jwt"; body: LaunchBuildRequest; response: PlanView };
  "GET /v1/economics": { auth: "jwt"; response: Economics };
  "GET /v1/launchpad/me": { auth: "jwt"; response: MyLaunchpad };
  "GET /v1/moments": { auth: "jwt"; query: { filter?: "all" | "collecting" | "closed"; limit?: number }; response: MomentFeed };
  "GET /v1/moments/owned": { auth: "jwt"; response: OwnedEditions };
  "GET /v1/moments/mine": { auth: "jwt"; response: MyMoments };
  "GET /v1/moments/:id": { auth: "jwt"; response: MomentDetail };
  "POST /v1/moments/metadata": { auth: "jwt"; body: MomentMetadataRequest; response: MomentMetadata };
  "POST /v1/moments/build": { auth: "jwt"; body: MomentBuildRequest; response: PlanView };
  "POST /v1/media/upload-url": { auth: "jwt"; body: UploadRequest; response: UploadTicket };
  "GET /v1/activity": {
    auth: "jwt";
    query: { section?: Section; kind?: string; period?: Period; market?: string; limit?: number };
    response: Activity;
  };
  "POST /v1/bridge/quote": { auth: "jwt"; body: BridgeQuoteRequest; response: BridgeQuote };
  "POST /v1/bridge/start": { auth: "jwt"; body: BridgeStartRequest; response: BridgeStart };
  "POST /v1/bridge/:id/source": { auth: "jwt"; body: BridgeTxRequest; response: { id: string; status: string } };
  "POST /v1/bridge/:id/claimed": { auth: "jwt"; body: BridgeTxRequest; response: { id: string; status: "completed" } };
  "GET /v1/bridge/:id": { auth: "jwt"; response: BridgeStatus };
  "GET /v1/cash/anchors": { auth: "jwt"; query: { country?: string }; response: CashAnchors };
  "POST /v1/cash/track": { auth: "jwt"; body: CashTrackRequest; response: CashTracked };
}

export type RouteKey = keyof Routes;
export type ResponseOf<K extends RouteKey> = Routes[K]["response"];
/** The routes that take no token. */
export type PublicRoute = { [K in RouteKey]: Routes[K]["auth"] extends "public" ? K : never }[RouteKey];
