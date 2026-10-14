// Minimal ABIs of the deployed contracts — only the functions and events the keepers use. They are written out by hand
// on purpose: the keepers must match the deployed bytecode of every stack they cover. The base ABIs are the v1 contracts
// (the retired stacks; every signature checked against the source at git commit 3fc1f47, their deployed state); the v2
// source (the live stacks since 2026-09-28) only adds functions, which are in the *V2Abi exports.
import { parseAbi } from "viem";

export const momentsFactoryAbi = parseAbi([
  "function momentCount() view returns (uint256)",
  "function publishingPaused() view returns (bool)",
  "function governance() view returns (address)",
  "function pendingGovernance() view returns (address)",
  "function pendingPolicyAt() view returns (uint64)",
  "function externalBaseURI() view returns (string)",
  "event GovernanceTransferStarted(address indexed from, address indexed to)",
  "event PolicyProposed((uint256 threshold, uint256 minPrice, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 maxCreatorAllocBps, uint16 expiryCreatorBps, uint16 royaltyBps, address platform, address treasury) policy, uint64 applicableAt)",
  "event PolicyApplied((uint256 threshold, uint256 minPrice, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 maxCreatorAllocBps, uint16 expiryCreatorBps, uint16 royaltyBps, address platform, address treasury) policy)",
  "event PolicyCancelled()",
  "event PublishingPaused(bool paused)",
  "event ExternalBaseURISet(string base)",
  "function getMoment(uint256 momentId) view returns ((address creator, address platform, address treasury, address coin, address nft, uint256 price, uint256 threshold, uint256 rateNum, uint256 rateDen, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 creatorAllocBps, uint16 expiryCreatorBps, uint16 royaltyBps, uint64 publishedAt, uint64 deadline))",
]);

// v2 only (cohort 4, 2026-09-28): the guardian, its own pause and their events. Absent on cohorts 1-3.
export const momentsFactoryV2Abi = parseAbi([
  "function guardian() view returns (address)",
  "function guardianPaused() view returns (bool)",
  "event GuardianSet(address indexed guardian)",
  "event GuardianPaused(bool paused)",
]);

// Cohort 0 ("v1") predates `royaltyBps`; its Moment struct has one field fewer. Used as a fallback decoder.
export const momentsFactoryV1Abi = parseAbi([
  "function getMoment(uint256 momentId) view returns ((address creator, address platform, address treasury, address coin, address nft, uint256 price, uint256 threshold, uint256 rateNum, uint256 rateDen, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 creatorAllocBps, uint16 expiryCreatorBps, uint64 publishedAt, uint64 deadline))",
  // Its Policy has no royaltyBps either, so its policy events have their own topics.
  "event PolicyProposed((uint256 threshold, uint256 minPrice, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 maxCreatorAllocBps, uint16 expiryCreatorBps, address platform, address treasury) policy, uint64 applicableAt)",
  "event PolicyApplied((uint256 threshold, uint256 minPrice, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 maxCreatorAllocBps, uint16 expiryCreatorBps, address platform, address treasury) policy)",
]);

export const momentCollectAbi = parseAbi([
  "function state(uint256 momentId) view returns (uint8)",
  "function ledger(uint256 momentId) view returns ((uint8 state, uint64 completedAt, uint64 stuckSince, uint64 endedAt, uint256 reserve, uint256 creatorClaimable, uint256 platformClaimable, uint256 treasuryClaimable, uint256 totalGross, uint256 collects))",
  "event GraduationFailed(uint256 indexed momentId)",
  "event Graduated(uint256 indexed momentId)",
]);

// Permissionless retry: MomentGraduation.graduate(id) (MomentCollect only calls it from the terminal collect).
export const momentGraduationAbi = parseAbi([
  "function graduate(uint256 momentId)",
  "function isGraduated(uint256 momentId) view returns (bool)",
]);

export const momentFeeHookAbi = parseAbi(["function buybackAccrued(uint256 momentId) view returns (uint256)"]);

// v2 only: the locker attributes its balances per Moment and adds at most MAX_INCREASE_BPS per round, so a Moment's
// remainder waits here between rounds. Reverts on every v1 locker.
export const momentLockerV2Abi = parseAbi(["function heldOf(uint256 momentId, address currency) view returns (uint256)"]);

// Permissionless: MomentBuyback.execute(id, minCoinOut). At most once per MIN_INTERVAL per Moment.
export const momentBuybackAbi = parseAbi([
  "function execute(uint256 momentId, uint256 minCoinOut) returns ((uint256 budget, uint256 usdcSpent, uint256 coinBought, uint256 usdcToPool, uint128 liquidityAdded, uint256 carried))",
  "function carry(uint256 momentId) view returns (uint256)",
  "function lastRun(uint256 momentId) view returns (uint64)",
  "function MIN_AMOUNT() view returns (uint256)",
  "function MIN_INTERVAL() view returns (uint256)",
]);

export const launchpadFactoryAbi = parseAbi([
  "function launchCount() view returns (uint256)",
  "function getLaunches(uint256 offset, uint256 limit) view returns (address[])",
  "function getLaunchedToken(address token) view returns ((address token, address curve, address deployer, address creatorFeeRecipient, address pairToken, uint256 graduationThreshold, uint16 creatorTaxBps, uint16 poolFeeBps, int24 tickSpacing, bool holderFeeSharing, uint8 graduationVenue, uint8 phase, uint256 sweptQuote, uint256 sweptTokens, uint256 sweptAt, bytes32 poolId, bool exists))",
  "function stuckSince(address token) view returns (uint256)",
  "function mondayExecutor() view returns (address)",
  "function hook() view returns (address)",
  "function graduationExecutor() view returns (address)",
  "function locker() view returns (address)",
  "function escrow() view returns (address)",
  "function holderFeeSharing() view returns (address)",
  "function router() view returns (address)",
  "function launchDeployer() view returns (address)",
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function protocolFeeRecipient() view returns (address)",
  "function pairMondayOnly(address pairToken) view returns (bool)",
  "function v4FallbackAllowed(address token) view returns (bool)",
  "function graduate(address token)",
  "function graduateFallback(address token)",
  "event AutoGraduationFailed(address indexed token)",
  "event ModulesSet(address hook, address executor, address locker, address escrow, address sharing, address router, address deployer)",
  "event MondayExecutorSet(address executor)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event FeePolicySet(address recipient, uint16 protocolShareBps)",
  "event LaunchFeeSet(uint256 fee)",
  "event PairEconomicsSet(address indexed pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals, bool approved)",
  "event PairMondayOnlySet(address indexed pairToken, bool mondayOnly)",
  "event WhitelistSet(bool enabled)",
  "event LaunchConfigEnabled(uint256 indexed id, bool enabled)",
  "event CreatorFeeRecipientChangeProposed(address indexed token, address newRecipient, uint256 effectiveAt, uint256 expiresAt)",
  "event V4FallbackAllowed(address indexed token)",
  "event LaunchRescued(address indexed token)",
  "event LaunchConfigAdded(uint256 indexed id)",
  "event MaxCreatorTaxSet(uint16 bps)",
  "event WhitelistedSet(address indexed account, bool allowed)",
]);

// The retired 0xad3d factory predates the graduation-venue choice: its launch record has no `graduationVenue`
// (16 fields), every launch graduates on Monday Trade, and it has no mondayExecutor()/graduateFallback().
export const launchpadFactoryLegacyAbi = parseAbi([
  "function getLaunchedToken(address token) view returns ((address token, address curve, address deployer, address creatorFeeRecipient, address pairToken, uint256 graduationThreshold, uint16 creatorTaxBps, uint16 poolFeeBps, int24 tickSpacing, bool holderFeeSharing, uint8 phase, uint256 sweptQuote, uint256 sweptTokens, uint256 sweptAt, bytes32 poolId, bool exists))",
]);

// v2 only: sealing the modules before the first launch. Absent on every v1 factory.
// Also v2 only: the Monday-only rule snapshotted per launch, and the delay after which its v4 fallback is public.
export const launchpadFactoryV2Abi = parseAbi([
  "function modulesSealed() view returns (bool)",
  "function launchMondayOnly(address token) view returns (bool)",
  "function MONDAY_ONLY_FALLBACK_DELAY() view returns (uint256)",
  "event ModulesSealed()",
]);

export const mondayFeeVaultAbi = parseAbi([
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function lpFeeRecipient() view returns (address)",
  "event LpFeeRecipientSet(address indexed recipient)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
]);

export const bondingCurveAbi = parseAbi([
  "function completed() view returns (bool)",
  "function rescued() view returns (bool)",
  "function reservedTokens() view returns (uint256)",
  "function phantomQuote() view returns (uint256)",
  "function graduationThreshold() view returns (uint256)",
  "function realQuoteReserve() view returns (uint256)",
]);

export const mondayExecutorAbi = parseAbi([
  "function factory() view returns (address)",
  "function wmon() view returns (address)",
  "function FEE() view returns (uint24)",
]);

export const mondayFactoryAbi = parseAbi([
  "function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)",
  "function feeAmountTickSpacing(uint24 fee) view returns (int24)",
]);

export const mondayPoolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function liquidity() view returns (uint128)",
  "function tickBitmap(int16 wordPosition) view returns (uint256)",
]);

// Permissionless: MemeHook.sweepPoolFees(poolId, currency) ("Anyone may call it").
export const memeHookAbi = parseAbi([
  "function pendingFees(bytes32 poolId, address currency) view returns (uint256)",
  "function pendingCreatorTax(bytes32 poolId, address currency) view returns (uint256)",
  "function sweepPoolFees(bytes32 poolId, address currency)",
]);

// v2 only (LP-2): the protocol's cut of holder-sharing pools waits here, not in pendingFees. Reverts on every v1 hook,
// where the keeper treats it as 0.
export const memeHookV2Abi = parseAbi(["function pendingProtocolFees(bytes32 poolId, address currency) view returns (uint256)"]);

export const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"]);
