//! Storage keys, the types launchpad-v2 stores and exchanges, and their accessors (DESIGN-stellar-contracts-v2 §5.2,
//! §5.3).
//!
//! - **Instance**: `Config`, the venue table and every pending proposal. Only admin and guardian calls write it; no
//!   launch, trade, refund or claim does, so concurrent launches never collide on it (§3.5, B6). The keeper keeps the
//!   instance alive; no call here extends it (DECISIONS #10).
//! - **Persistent**, keyed by launch token, account or asset: `Quote`, `Launch` (immutable), `Curve`, `Recipient`,
//!   `CreatorOwed` and `Whitelisted`, each bumped by the deployment's TTL policy when a call touches it (§13).
//! - **Temporary**: `Exempt` (read only while the snipe window is open) and `Takeover`. Both lapse on purpose.

use crate::Error;
use dyor_common::{bump_persistent, ledgers_for, LaunchDurations, TtlPolicy, VenueKind, VenueParams};
use soroban_sdk::{contracttype, panic_with_error, Address, BytesN, Env, IntoVal, String, TryFromVal, Val, Vec};

#[contracttype]
#[derive(Clone)]
pub(crate) enum DataKey {
    // instance (§5.2)
    Config,
    Venues,
    NextVenueId,
    PendingVenue(u32),
    PendingAdmin,
    PendingTreasury,
    PendingGuardian,
    GuardianHandoff,
    // persistent
    Quote(Address),
    Launch(Address),
    Curve(Address),
    Recipient(Address),
    CreatorOwed(Address, Address),
    Whitelisted(Address),
    // temporary
    Exempt(Address),
    Takeover(Address),
}

// ------------------------------------------------------------------------------------------------ types (§5.3)

// The launchpad's settings. Fees, the snipe schedule and the launch fee apply to launches created after they are
// set; `durations` and every peer address are fixed at construction.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub admin: Address,
    // Can only cancel pending treasury and venue changes, hand its role on or renounce it (L8, F16).
    pub guardian: Option<Address>,
    // Receives booked protocol and launch fees at sweep time, and the protocol's half of harvests. Changed only
    // through the timelock.
    pub treasury: Address,
    // The XLM Stellar Asset Contract: the launch fee's asset.
    pub xlm: Address,
    pub token_wasm_hash: BytesN<32>,
    pub locker: Address,
    pub soroswap_factory: Address,
    // Always set, and passed to every launch token for `exclude_pool` (F2).
    pub aquarius_router: Address,
    pub supply: i128,
    // Curve fee on every buy and sell (100 = 1%).
    pub fee_bps: u32,
    // The protocol's share of the curve fee, the snipe tax and every harvest; the rest goes to the creator side.
    pub protocol_share_bps: u32,
    pub max_creator_fee_bps: u32,
    // Snipe tax per step of `snipe_step_secs` since the launch (L11).
    pub snipe_schedule: Vec<u32>,
    pub snipe_step_secs: u32,
    // In XLM stroops, booked on each launch (O6).
    pub launch_fee: i128,
    pub launches_enabled: bool,
    pub whitelist_enabled: bool,
    pub durations: LaunchDurations,
    pub ttl: TtlPolicy,
}

// One entry of the constructor's venue table; its id is its position in the table (§3.4).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueInit {
    pub kind: VenueKind,
    pub executor: Address,
    pub params: VenueParams,
}

// A graduation venue. `enabled` governs future launches only: a launch keeps the venue it pinned.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueInfo {
    pub id: u32,
    pub kind: VenueKind,
    pub executor: Address,
    pub params: VenueParams,
    pub enabled: bool,
}

// Curve economics and venue rules for one quote asset, which is always a Stellar Asset Contract (F17). Applies to
// launches created after it is set.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuoteEconomics {
    pub phantom: i128,
    pub threshold: i128,
    pub enabled: bool,
    // The venues a launch may choose; empty means every enabled venue.
    pub venues_allowed: Vec<u32>,
    // Always of kind Soroswap.
    pub fallback_venue: u32,
}

// What a creator asks `launch` for.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchParams {
    pub quote: Address,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub creator_fee_bps: u32,
    pub venue: u32,
    pub holder_sharing: bool,
    // The creator when `None`.
    pub creator_fee_recipient: Option<Address>,
    // Buyers who pay no snipe tax, besides the creator and the recipient.
    pub snipe_exempt: Vec<Address>,
    pub initial_buy: i128,
    pub min_tokens_out: i128,
    // With the creator, it fixes the token's address (L15).
    pub nonce: u64,
}

// Everything a launch binds, passed by value and compared field by field (P2): the phone shows and signs these.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchTerms {
    pub supply: i128,
    pub fee_bps: u32,
    pub protocol_share_bps: u32,
    pub max_creator_fee_bps: u32,
    pub snipe_schedule: Vec<u32>,
    pub snipe_step_secs: u32,
    pub launch_fee: i128,
    // The XLM Stellar Asset Contract.
    pub fee_asset: Address,
    pub quote: Address,
    pub phantom: i128,
    pub threshold: i128,
    pub venue: VenueInfo,
    pub fallback: VenueInfo,
    pub venue_locked: bool,
    pub locker: Address,
    pub token_wasm_hash: BytesN<32>,
    pub durations: LaunchDurations,
}

// What never changes about a launch. Trades, the harvest split and graduation read the fees, the split and the snipe
// values pinned here, never `Config` (V1).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launch {
    pub token: Address,
    pub creator: Address,
    pub quote: Address,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub nonce: u64,
    pub created_ledger: u32,
    pub created_at: u64,
    pub fee_bps: u32,
    pub protocol_share_bps: u32,
    pub creator_fee_bps: u32,
    pub snipe_schedule: Vec<u32>,
    pub snipe_step_secs: u32,
    pub venue: VenueInfo,
    pub fallback: VenueInfo,
    // The quote's allowlist excludes the fallback: the fallback waits `locked_fallback` or `allow_fallback`.
    pub venue_locked: bool,
    pub holder_sharing: bool,
    pub launch_fee_paid: i128,
}

// Where a launch is in its life (§5.1).
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Phase {
    Curve = 0,
    Completed = 1,
    Graduated = 2,
    Rescued = 3,
}

// A launch's moving state, including everything it has booked.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Curve {
    pub phantom: i128,
    pub threshold: i128,
    // Virtual quote reserve: phantom + real quote.
    pub quote_reserve: i128,
    pub token_reserve: i128,
    // Quote actually raised (net of fees), backing the curve.
    pub real_quote: i128,
    // Booked for the current recipient (sharing off), in the quote.
    pub creator_fees: i128,
    // Booked for the treasury, in the quote.
    pub protocol_fees: i128,
    // The launch fee not yet swept, in XLM.
    pub launch_fee_due: i128,
    // Quote sent to the token for its holders (sharing on).
    pub holder_fees_total: i128,
    pub phase: Phase,
    pub completed_at: u64,
    // The first recorded failure or `mark_stuck`; 0 when not stuck. Only a graduation resets it.
    pub stuck_since: u64,
    pub fallback_allowed: bool,
    pub pool: Option<Address>,
    pub graduated_venue: Option<u32>,
    // Launch tokens burned at graduation or rescue.
    pub burned: i128,
    // The quote and the circulating supply that refunds share pro rata (Rescued only).
    pub refund_quote: i128,
    pub refund_supply: i128,
    pub refunded: i128,
}

// `status(token)`: when each path opens. A time is 0 where it doesn't apply.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchStatus {
    pub phase: Phase,
    pub completed_at: u64,
    pub stuck_since: u64,
    pub mark_stuck_at: u64,
    // `stuck_since + fallback_delay`; for a venue-locked launch the later of that and
    // `stuck_since + locked_fallback`, unless the fallback was allowed.
    pub fallback_at: u64,
    pub rescue_admin_at: u64,
    pub rescue_public_at: u64,
    pub refund_quote: i128,
    pub refund_supply: i128,
}

// A timelocked treasury change.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingTreasury {
    pub addr: Address,
    pub eta: u64,
    pub expires: u64,
}

// The admin's timelocked replacement of the guardian (`None` removes it, F16).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingGuardian {
    pub new: Option<Address>,
    pub eta: u64,
    pub expires: u64,
}

// A timelocked new venue; its id is fixed when it is proposed.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingVenue {
    pub id: u32,
    pub kind: VenueKind,
    pub executor: Address,
    pub params: VenueParams,
    pub eta: u64,
    pub expires: u64,
}

// The admin's takeover of a launch's creator-fee recipient: it executes from `effective_at` to `expires_at`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Takeover {
    pub new: Address,
    pub effective_at: u64,
    pub expires_at: u64,
}

// ------------------------------------------------------------------------------------------------ instance

pub(crate) fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

pub(crate) fn set_config(e: &Env, cfg: &Config) {
    e.storage().instance().set(&DataKey::Config, cfg);
}

pub(crate) fn venues(e: &Env) -> Vec<VenueInfo> {
    e.storage().instance().get(&DataKey::Venues).unwrap()
}

pub(crate) fn set_venues(e: &Env, venues: &Vec<VenueInfo>) {
    e.storage().instance().set(&DataKey::Venues, venues);
}

/// The venue with `id`, if the table has it.
pub(crate) fn find_venue(venues: &Vec<VenueInfo>, id: u32) -> Option<VenueInfo> {
    items(venues).find(|v| v.id == id)
}

/// `v`'s items, by index. `Vec::iter` unwraps each item with `Result::unwrap`, which links the panic message
/// formatting code: several KB of this contract's size budget. `get_unchecked` traps without it.
pub(crate) fn items<T: IntoVal<Env, Val> + TryFromVal<Env, Val>>(v: &Vec<T>) -> impl Iterator<Item = T> + '_ {
    (0..v.len()).map(move |i| v.get_unchecked(i))
}

pub(crate) fn instance_get<V: TryFromVal<Env, Val>>(e: &Env, key: &DataKey) -> Option<V> {
    e.storage().instance().get(key)
}

/// Reads an instance proposal, or fails `NoProposal`.
pub(crate) fn proposal<V: TryFromVal<Env, Val>>(e: &Env, key: &DataKey) -> V {
    instance_get(e, key).unwrap_or_else(|| panic_with_error!(e, Error::NoProposal))
}

// ------------------------------------------------------------------------------------------------ persistent

/// Extends a persistent entry by the deployment's TTL policy.
pub(crate) fn bump<K: IntoVal<Env, Val>>(e: &Env, key: &K) {
    bump_persistent(e, key, &ttl(e));
}

fn ttl(e: &Env) -> TtlPolicy {
    config(e).ttl
}

pub(crate) fn quote_economics(e: &Env, asset: &Address) -> Option<QuoteEconomics> {
    e.storage().persistent().get(&DataKey::Quote(asset.clone()))
}

/// The launch of `token`, bumped on every read (as v1, S:contracts/launchpad/src/lib.rs:703-712).
pub(crate) fn load_launch(e: &Env, token: &Address) -> Launch {
    let key = DataKey::Launch(token.clone());
    let launch = e.storage().persistent().get(&key).unwrap_or_else(|| panic_with_error!(e, Error::UnknownLaunch));
    bump(e, &key);
    launch
}

pub(crate) fn load_curve(e: &Env, token: &Address) -> Curve {
    e.storage()
        .persistent()
        .get(&DataKey::Curve(token.clone()))
        .unwrap_or_else(|| panic_with_error!(e, Error::UnknownLaunch))
}

pub(crate) fn save_curve(e: &Env, token: &Address, curve: &Curve) {
    let key = DataKey::Curve(token.clone());
    e.storage().persistent().set(&key, curve);
    bump(e, &key);
}

/// The current creator-fee recipient of `token`.
pub(crate) fn recipient(e: &Env, token: &Address) -> Address {
    let key = DataKey::Recipient(token.clone());
    let to = e.storage().persistent().get(&key).unwrap_or_else(|| panic_with_error!(e, Error::UnknownLaunch));
    bump(e, &key);
    to
}

pub(crate) fn set_recipient(e: &Env, token: &Address, to: &Address) {
    let key = DataKey::Recipient(token.clone());
    e.storage().persistent().set(&key, to);
    bump(e, &key);
}

pub(crate) fn creator_owed(e: &Env, account: &Address, asset: &Address) -> i128 {
    e.storage().persistent().get(&DataKey::CreatorOwed(account.clone(), asset.clone())).unwrap_or(0)
}

/// Sets `CreatorOwed(account, asset)`; 0 removes the entry.
pub(crate) fn set_creator_owed(e: &Env, account: &Address, asset: &Address, amount: i128) {
    let key = DataKey::CreatorOwed(account.clone(), asset.clone());
    if amount == 0 {
        e.storage().persistent().remove(&key);
    } else {
        e.storage().persistent().set(&key, &amount);
        bump(e, &key);
    }
}

pub(crate) fn whitelisted(e: &Env, account: &Address) -> bool {
    let key = DataKey::Whitelisted(account.clone());
    let listed = e.storage().persistent().get(&key).unwrap_or(false);
    if listed {
        bump(e, &key);
    }
    listed
}

// ------------------------------------------------------------------------------------------------ temporary

/// Writes a temporary entry that lives at least `secs` seconds from now (capped at the network's maximum TTL).
pub(crate) fn set_temporary<V: IntoVal<Env, Val>>(e: &Env, key: &DataKey, value: &V, secs: u64) {
    let ledgers = ledgers_for(secs).min(e.storage().max_ttl());
    let temporary = e.storage().temporary();
    temporary.set(key, value);
    temporary.extend_ttl(key, ledgers, ledgers);
}

/// The snipe-exempt buyers of `token` (empty once the entry has lapsed, long after the window closed).
pub(crate) fn exempt(e: &Env, token: &Address) -> Vec<Address> {
    e.storage().temporary().get(&DataKey::Exempt(token.clone())).unwrap_or_else(|| Vec::new(e))
}

pub(crate) fn takeover(e: &Env, token: &Address) -> Option<Takeover> {
    e.storage().temporary().get(&DataKey::Takeover(token.clone()))
}
