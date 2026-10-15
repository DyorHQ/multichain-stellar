//! What moments-v2 stores (DESIGN-stellar-contracts-v2 §9.1) and how long it keeps it (§13).
//!
//! - **Instance** (the keeper keeps it alive, DECISIONS #10): `Config`, `Policy`, `PendingPolicy` and
//!   `PendingGovernance`, written only by the constructor and governance actions. `publish` and `collect` only read
//!   them, so two publishes or collects never conflict on an instance key under parallel apply (§3.5, B6).
//! - **Persistent**, keyed by the Moment's NFT address (L15): `Moment(nft)` (immutable), `Ledger(nft)` and
//!   `Position(nft, account)`. There is no `MomentCount`; the indexer numbers Moments for display.
//! - **TTL.** `Moment` and `Ledger` are bumped by the deployment's policy whenever a call writes the ledger, so a
//!   Moment in use never archives. A vesting `Position` is extended to outlive its vesting: at accrue to
//!   `deadline − now + 2·vest_period + 7 d`, at a claim to the rest of the collectors' schedule plus 7 d, never below
//!   the policy's `extend_to` and never above the network's maximum (§13).

use crate::Error;
use dyor_common::{bump_persistent, ledgers_for, MomentsDurations, TtlPolicy};
use soroban_sdk::{contracttype, panic_with_error, Address, BytesN, Env, String};

/// One week, the margin a vesting position keeps beyond its schedule (§13).
const WEEK: u64 = 7 * 86_400;

#[contracttype]
#[derive(Clone)]
pub(crate) enum DataKey {
    // instance (§9.1)
    Config,
    Policy,
    PendingPolicy,
    PendingGovernance,
    // persistent, per Moment (keyed by its NFT address)
    Moment(Address),
    Ledger(Address),
    Position(Address, Address),
}

/// The deployment: peers, the governance and guardian keys with their pauses, and the immutable durations and TTL
/// policy. Every peer is a constructor argument; nothing re-points one later (§3.4).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub governance: Address,
    /// Can cancel a pending policy, pause publishing (a pause only it can lift) and hand its role on. `None` once
    /// renounced; nobody can replace a lost guardian (Monad's rule, §16).
    pub guardian: Option<Address>,
    /// Circle USDC's Stellar Asset Contract, the only quote (L9).
    pub usdc: Address,
    pub nft_wasm_hash: BytesN<32>,
    /// The coin code the graduator deploys, read from it once in the constructor so the terms can show it (§9.1).
    pub coin_wasm_hash: BytesN<32>,
    pub graduator: Address,
    pub locker: Address,
    /// The graduator's executor (exec-soroswap). moments-v2 never calls it; it is part of the terms.
    pub executor: Address,
    pub soroswap_factory: Address,
    /// Prefix of every new Moment NFT's `external_url` (`<base><nft address>`): https only, at most 256 bytes.
    pub external_base: String,
    pub publishing_paused: bool,
    pub guardian_paused: bool,
    pub durations: MomentsDurations,
    pub ttl: TtlPolicy,
}

/// The economics a Moment published now snapshots (§9.1). USDC amounts have 7 decimals.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Policy {
    /// The reserve that completes a Moment.
    pub threshold: i128,
    pub min_price: i128,
    /// Each collect's split; the three sum to `BPS` (20/5/75 on testnet, §14.2).
    pub creator_bps: u32,
    pub platform_bps: u32,
    pub reserve_bps: u32,
    /// The most coin allocation a creator may take, in bps of S.
    pub max_creator_alloc_bps: u32,
    /// The creator's share of an expired Moment's reserve; the treasury gets the rest.
    pub expiry_creator_bps: u32,
    /// The royalty every edition suggests to marketplaces, paid to the creator.
    pub royalty_bps: u32,
    pub platform: Address,
    pub treasury: Address,
}

/// A proposed policy: applicable from `eta`, lapsed after `expires` (§9.2).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingPolicy {
    pub policy: Policy,
    pub eta: u64,
    pub expires: u64,
}

/// A Moment's life (§9.1). On the wire it is the u32.
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum State {
    /// Editions mint, USDC and entitlements accrue.
    Collecting = 0,
    /// The reserve reached the threshold; the keeper (or anyone) graduates it in the following ledgers.
    GraduationPending = 1,
    /// The pool is live, the edition size fixed and the coins vesting.
    Graduated = 2,
    /// Wound down without graduation: the reserve went 70/30 to the creator and the treasury.
    Expired = 3,
}

/// Everything about a Moment that is fixed at publish, keyed by its NFT address. There is no setter (§9.1).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Moment {
    /// The Moment's id.
    pub nft: Address,
    pub creator: Address,
    /// The policy's beneficiaries when it was published: later policies never redirect them.
    pub platform: Address,
    pub treasury: Address,
    /// Where graduation will deploy the coin, predicted by the graduator at publish.
    pub coin: Address,
    pub price: i128,
    pub threshold: i128,
    /// The bundle rate: `entitlement = gross·rate_num/rate_den` coin units per USDC unit (§14.5).
    pub rate_num: i128,
    pub rate_den: i128,
    pub creator_bps: u32,
    pub platform_bps: u32,
    pub reserve_bps: u32,
    pub creator_alloc_bps: u32,
    pub expiry_creator_bps: u32,
    pub royalty_bps: u32,
    pub nonce: u64,
    pub published_at: u64,
    /// Collecting is possible strictly before it.
    pub deadline: u64,
}

/// A Moment's USDC and coin ledger (§9.1). Every payout from it is pull-only, to a snapshotted beneficiary.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ledger {
    pub state: State,
    /// When the reserve reached the threshold.
    pub completed_at: u64,
    /// The first recorded failed graduation; 0 until one, and again after a graduation (F15, I-M6, I-M7).
    pub stuck_since: u64,
    /// Graduation or expiry time.
    pub ended_at: u64,
    /// The vesting start.
    pub graduated_at: u64,
    /// USDC held for the pool.
    pub reserve: i128,
    pub creator_claimable: i128,
    pub platform_claimable: i128,
    pub treasury_claimable: i128,
    /// USDC accepted from collectors.
    pub total_gross: i128,
    pub collects: u32,
    pub editions: u32,
    /// Σ collector entitlements, in coin units.
    pub entitlements: i128,
    /// The creator allocation minted so far.
    pub creator_claimed: i128,
    /// Every coin vesting claims minted (collectors and creator); never above `alloc + entitlements` (I-M3).
    pub minted_by_vesting: i128,
    pub pool: Option<Address>,
    /// The LP the locker holds for the Moment.
    pub liquidity: i128,
}

impl Ledger {
    pub(crate) fn new() -> Self {
        Ledger {
            state: State::Collecting,
            completed_at: 0,
            stuck_since: 0,
            ended_at: 0,
            graduated_at: 0,
            reserve: 0,
            creator_claimable: 0,
            platform_claimable: 0,
            treasury_claimable: 0,
            total_gross: 0,
            collects: 0,
            editions: 0,
            entitlements: 0,
            creator_claimed: 0,
            minted_by_vesting: 0,
            pool: None,
            liquidity: 0,
        }
    }
}

/// A collector's coins for one Moment: promised at collect, minted by vesting claims.
#[contracttype]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Position {
    pub entitlement: i128,
    pub claimed: i128,
}

// ------------------------------------------------------------------------------------------------ instance

pub(crate) fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

pub(crate) fn set_config(e: &Env, cfg: &Config) {
    e.storage().instance().set(&DataKey::Config, cfg);
}

pub(crate) fn policy(e: &Env) -> Policy {
    e.storage().instance().get(&DataKey::Policy).unwrap()
}

pub(crate) fn set_policy(e: &Env, p: &Policy) {
    e.storage().instance().set(&DataKey::Policy, p);
}

pub(crate) fn pending_policy(e: &Env) -> Option<PendingPolicy> {
    e.storage().instance().get(&DataKey::PendingPolicy)
}

pub(crate) fn pending_governance(e: &Env) -> Option<Address> {
    e.storage().instance().get(&DataKey::PendingGovernance)
}

// ------------------------------------------------------------------------------------------------ persistent

pub(crate) fn has_moment(e: &Env, nft: &Address) -> bool {
    e.storage().persistent().has(&DataKey::Moment(nft.clone()))
}

pub(crate) fn try_moment(e: &Env, nft: &Address) -> Option<Moment> {
    e.storage().persistent().get(&DataKey::Moment(nft.clone()))
}

/// The Moment of `nft`, or `UnknownMoment`.
pub(crate) fn moment(e: &Env, nft: &Address) -> Moment {
    try_moment(e, nft).unwrap_or_else(|| panic_with_error!(e, Error::UnknownMoment))
}

/// The ledger of a Moment that exists.
pub(crate) fn ledger(e: &Env, nft: &Address) -> Ledger {
    e.storage()
        .persistent()
        .get(&DataKey::Ledger(nft.clone()))
        .unwrap_or_else(|| panic_with_error!(e, Error::UnknownMoment))
}

/// Writes a new Moment and its empty ledger (publish).
pub(crate) fn create_moment(e: &Env, m: &Moment, ttl: &TtlPolicy) {
    let key = DataKey::Moment(m.nft.clone());
    e.storage().persistent().set(&key, m);
    bump_persistent(e, &key, ttl);
    save_ledger(e, &m.nft, &Ledger::new(), ttl);
}

/// Writes a Moment's ledger and keeps the Moment alive with it.
pub(crate) fn save_ledger(e: &Env, nft: &Address, l: &Ledger, ttl: &TtlPolicy) {
    let key = DataKey::Ledger(nft.clone());
    e.storage().persistent().set(&key, l);
    bump_persistent(e, &key, ttl);
    bump_persistent(e, &DataKey::Moment(nft.clone()), ttl);
}

/// `account`'s position in a Moment; zero when it has none.
pub(crate) fn position(e: &Env, nft: &Address, account: &Address) -> Position {
    e.storage().persistent().get(&DataKey::Position(nft.clone(), account.clone())).unwrap_or_default()
}

/// Writes a position and extends it to live at least `secs` more seconds plus a week (§13).
pub(crate) fn save_position(e: &Env, nft: &Address, account: &Address, p: &Position, ttl: &TtlPolicy, secs: u64) {
    let key = DataKey::Position(nft.clone(), account.clone());
    e.storage().persistent().set(&key, p);
    let target = ledgers_for(secs.saturating_add(WEEK)).max(ttl.extend_to).min(e.storage().max_ttl());
    e.storage().persistent().extend_ttl(&key, target, target);
}
