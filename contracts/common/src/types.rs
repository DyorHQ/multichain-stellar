//! The types that cross contract boundaries (DESIGN-stellar-contracts-v2 §4, §12). Every v2 contract encodes them
//! the same way because they are defined once, here.

use soroban_sdk::{contracttype, Address, String, Vec};

/// A graduation venue's kind. The launchpad's venue table maps venue ids to a kind and an executor (§5.3).
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum VenueKind {
    Soroswap = 0,
    Aquarius = 1,
    /// A position the locker holds without harvesting.
    HoldOnly = 2,
    /// testnet-qa's `qa-exec-fail` venue (§7.3).
    QaFail = 3,
}

/// Per-venue executor parameters.
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VenueParams {
    /// Aquarius fee tier: 10, 30 or 100 (testnet: 30). 0 for every other kind.
    pub fee_fraction: u32,
}

/// What a launch (or the Moments graduator) asks an executor to seed. The executor pulls `token_amount` and
/// `quote_amount` from `source`, which pre-authorized both transfers, and sends the LP to `lp_to`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraduateArgs {
    pub source: Address,
    pub token: Address,
    pub quote: Address,
    pub token_amount: i128,
    pub quote_amount: i128,
    pub lp_to: Address,
    pub params: VenueParams,
    pub min_liquidity: i128,
}

/// An executor's report. Leftovers (`token_amount − token_used`, `quote_amount − quote_used`) go back to `source`;
/// the caller checks every field against its own balances before it trusts any of them (§5.5).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraduateResult {
    pub pool: Address,
    pub lp_token: Address,
    pub liquidity: i128,
    pub token_used: i128,
    pub quote_used: i128,
}

/// What moments-v2 asks the graduator to do for one Moment (§9.3, §12).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MomentGradArgs {
    pub nft: Address,
    pub usdc: Address,
    pub reserve: i128,
    pub pool_coins: i128,
    pub name: String,
    pub symbol: String,
    pub expected_coin: Address,
}

/// The graduator's report, checked inside its own frame and again by moments-v2 (§12).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MomentGradResult {
    pub coin: Address,
    pub pool: Address,
    pub lp_token: Address,
    pub liquidity: i128,
    pub coin_used: i128,
    pub usdc_used: i128,
    pub usdc_returned: i128,
}

/// One recipient of a harvested side. `notify` marks a launch token: the locker transfers the asset to it and then
/// calls `notify_reward(locker, asset, amount)`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Payee {
    pub to: Address,
    pub bps: u32,
    pub notify: bool,
}

/// Who receives each side of a harvest. Every non-empty list's bps sum to `BPS`; an empty `base` list means the
/// base side is burned (Moments).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HarvestPayees {
    pub quote: Vec<Payee>,
    pub base: Vec<Payee>,
}

/// What a locked position belongs to: a launch (its token's address) or a Moment (its NFT's address).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PositionRef {
    Launch(Address),
    Moment(Address),
}

/// TTL extension for persistent entries, in ledgers. A constructor argument, validated with
/// [`crate::validate_ttl_policy`] against `e.storage().max_ttl()`.
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TtlPolicy {
    pub threshold: u32,
    pub extend_to: u32,
}

/// A recorded graduation failure (finding V10). `origin` is the raising contract's tag (`TAG_*`), `ORIGIN_FOREIGN`
/// (0) for a contract outside DyorHQ (a DEX, a SAC, an OpenZeppelin check) or `ORIGIN_HOST` (99) for a host error;
/// `code` is the code as raised. Built by [`crate::grad_failure`].
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GradFailure {
    pub origin: u32,
    pub code: u32,
}

/// What `graduate` and `graduate_fallback` return: the pool, or the recoverable failure they recorded.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GraduationOutcome {
    Graduated(Address),
    Failed(GradFailure),
}

/// launchpad-v2's durations in seconds: constructor arguments, immutable and part of the terms (§14.3, O3).
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LaunchDurations {
    /// Completed → `mark_stuck` allowed.
    pub grace: u64,
    /// `stuck_since` → `graduate_fallback` allowed (F14).
    pub fallback_delay: u64,
    /// `stuck_since` → the admin may `rescue`.
    pub rescue_admin: u64,
    /// `stuck_since` → anyone may `rescue`.
    pub rescue_public: u64,
    /// `stuck_since` → the fallback of a venue-locked launch, without `allow_fallback`.
    pub locked_fallback: u64,
    /// Creator-fee-recipient takeover: wait, then the window in which it can execute.
    pub takeover_delay: u64,
    pub takeover_window: u64,
    /// Treasury, guardian and venue proposals: wait, then the window in which they can apply.
    pub timelock: u64,
    pub timelock_window: u64,
    /// Must equal the locker's `harvest_interval()` (F6).
    pub harvest_interval: u64,
}

/// moments-v2's durations in seconds (§14.3). There is no grace: Moments have no `mark_stuck` (F15).
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MomentsDurations {
    /// One vesting period.
    pub vest_period: u64,
    /// A recorded failed graduation (`stuck_since`) → expiry.
    pub stuck_expiry: u64,
    /// `completed_at` → expiry of a Moment still GraduationPending with no recorded failure (V11).
    pub pending_backstop: u64,
    /// Policy proposals: wait, then the window in which they can apply.
    pub timelock: u64,
    pub timelock_window: u64,
    /// Bounds of a Moment's collect window.
    pub min_window: u64,
    pub max_window: u64,
    /// Must equal the locker's `harvest_interval()` (F6).
    pub harvest_interval: u64,
}
