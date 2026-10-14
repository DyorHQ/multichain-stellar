//! Holder rewards (DESIGN-stellar-contracts-v2 §6.2): Monad's HolderFeeSharing (M:contracts/src/HolderFeeSharing.sol:
//! 97-207) moved inside the token, with two reward pools (L13, F1):
//! - `q`, the quote: the creator-or-holders part of curve fees (the launchpad) and the quote side of harvests (the
//!   locker);
//! - `t`, this token: the holders' half of a harvest's launch-token side, funded by the locker after graduation and
//!   held at the token's own address, which nothing can spend from (§6.1).
//!
//! Each pool is reward-per-share, `acc` scaled by `P` with U256 intermediates. Both pools share `eligible` (what every
//! account that isn't excluded holds) and `queued_ledger`: a notified amount waits in `queued` and is released to the
//! holders of a later ledger, so a balance held only within one ledger earns nothing of it (I-T3). A release that
//! finds fewer than `MIN_ELIGIBLE` units eligible goes to the protocol instead.
//!
//! Every balance change runs [`before_update`] first: it releases what is due and settles both sides at their old
//! balances. A `Holder` entry is written from the first release on (lazily), and its debts are rounded up, so what
//! holders are owed never exceeds what was funded (I-T2, B9). Rounding up costs a holder at most one unit per settle.
//!
//! Exclusion is one-way. An account is excluded when it is in `FixedExcluded` (the launchpad, the locker, the
//! executors and the token itself) or its `Holder` entry says so (DEX pools, the treasury and former treasuries).
//! What it had earned and not claimed goes to the protocol (L5), and `sweep_protocol` pays the protocol's share to the
//! launchpad's treasury, which is excluded before it is paid (V2, I-T10).

use crate::{
    DataKey, Error, Excluded, LaunchTokenV2, RewardAdded, RewardClaimed, RewardQueued, RewardSwept, RewardToProtocol,
};
use dyor_common::aquarius::{sorted_pair, AquariusPoolClient, AquariusRouterClient, AQUARIUS_POOL_LOOKUP_OK};
use dyor_common::{
    mul_div_u256, mul_div_up_u256, SoroswapFactoryClient, SoroswapPairClient, TreasurySourceClient, VenueKind,
};
use soroban_sdk::{contracttype, panic_with_error, token::TokenClient, Address, Env, Executable, IntoVal, Val, Vec};
use stellar_tokens::fungible::{emit_transfer, Base, FungibleTokenError, BALANCE_EXTEND_AMOUNT, BALANCE_TTL_THRESHOLD};

/// The reward-per-share scale. Monad's 1e36 would overflow i128 once divided back down (§0 P7).
pub const P: i128 = 1_000_000_000_000_000_000;
/// One token: below this many eligible units a release goes to the protocol. It bounds each `acc` step to
/// `queued · 1e11`.
pub const MIN_ELIGIBLE: i128 = 10_000_000;
/// `exclude_pool`'s floor in launch tokens: 1,000 tokens, 0.0001% of the supply (F2).
pub const EXCLUDE_MIN_BALANCE: i128 = 10_000_000_000;
/// `exclude_pool`'s floor in unclaimed quote rewards: 0.1 XLM or 0.1 USDC (F2).
pub const EXCLUDE_MIN_OWED: i128 = 1_000_000;

/// One reward asset's accounting. `funded − paid` is what the token owes in that asset: holders' owed and pending
/// rewards, the queue, the protocol's share and rounding dust.
#[contracttype]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RewardPool {
    /// Reward per eligible unit, scaled by `P`.
    pub acc: i128,
    /// Notified and not yet released.
    pub queued: i128,
    pub funded: i128,
    pub paid: i128,
    /// Released below `MIN_ELIGIBLE`, or stranded at an exclusion; `sweep_protocol` pays it.
    pub protocol_owed: i128,
}

/// The `Sharing` entry: persistent, so a transfer doesn't rewrite the instance (§6.3).
#[contracttype]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Sharing {
    pub eligible: i128,
    /// The ledger of the last notify; the queue is released in any later ledger.
    pub queued_ledger: u32,
    pub q: RewardPool,
    pub t: RewardPool,
}

/// A holder's position in both pools, or the flag that excludes it.
#[contracttype]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Holder {
    pub q_debt: i128,
    pub q_owed: i128,
    pub t_debt: i128,
    pub t_owed: i128,
    pub excluded: bool,
}

/// `sharing()`: the stored state and the quote it pays in.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SharingView {
    pub quote: Address,
    pub eligible: i128,
    pub queued_ledger: u32,
    pub q: RewardPool,
    pub t: RewardPool,
}

// ------------------------------------------------------------------------------------------------ the hook

/// Runs before every balance change: `transfer`, `transfer_from`, `burn`, `burn_from`, the mint at construction and
/// the payouts of `claim` and `sweep_protocol` (`None` is a mint or a burn). It releases what is due, then settles
/// each side that isn't excluded at its balance before the change and moves `amount` into or out of `eligible` when
/// it crosses the excluded line. Nothing to do with sharing off.
pub(crate) fn before_update(e: &Env, from: Option<&Address>, to: Option<&Address>, amount: i128) {
    let Some(quote) = sharing_quote(e) else {
        return;
    };
    // OpenZeppelin's own checks (Base::update), made first so the settle below never sees a negative balance.
    if amount < 0 {
        panic_with_error!(e, FungibleTokenError::LessThanZero);
    }
    if from.is_some_and(|a| Base::balance(e, a) < amount) {
        panic_with_error!(e, FungibleTokenError::InsufficientBalance);
    }
    let mut s = read_sharing(e);
    let mut dirty = release(e, &mut s, Some(&quote));
    // A self-transfer settles nothing and mints nothing (HolderFeeSharing.sol:104-107, I-T4).
    if from != to {
        let fixed = fixed_excluded(e);
        let from_eligible = from.is_some_and(|a| settle_if_eligible(e, &s, &fixed, a, -amount));
        let to_eligible = to.is_some_and(|a| settle_if_eligible(e, &s, &fixed, a, amount));
        match (from_eligible, to_eligible) {
            (true, false) => s.eligible -= amount,
            (false, true) => s.eligible += amount,
            _ => {}
        }
        dirty |= from_eligible != to_eligible;
    }
    if dirty {
        write_sharing(e, &s);
    }
}

/// Settles `a` before its balance moves by `delta`, unless it is excluded. Returns whether it is eligible.
fn settle_if_eligible(e: &Env, s: &Sharing, fixed: &Vec<Address>, a: &Address, delta: i128) -> bool {
    let (excluded, h) = lookup(e, fixed, a);
    if !excluded {
        let old = Base::balance(e, a);
        if let Some(h) = settled(e, s, h, old, old + delta) {
            write_holder(e, a, &h);
        }
    }
    !excluded
}

/// `h` with what it earned at balance `old` added to its owed amounts and its debts set for balance `new`. `None`
/// while no pool has released anything and there is no entry: entries are written lazily.
fn settled(e: &Env, s: &Sharing, h: Option<Holder>, old: i128, new: i128) -> Option<Holder> {
    if h.is_none() && s.q.acc == 0 && s.t.acc == 0 {
        return None;
    }
    let mut h = h.unwrap_or_default();
    accrue(e, s.q.acc, &mut h.q_debt, &mut h.q_owed, old, new);
    accrue(e, s.t.acc, &mut h.t_debt, &mut h.t_owed, old, new);
    Some(h)
}

fn accrue(e: &Env, acc: i128, debt: &mut i128, owed: &mut i128, old: i128, new: i128) {
    // acc never falls, and a debt is only set once it is positive: with acc 0 the debt is 0 and nothing accrues.
    if acc == 0 {
        return;
    }
    let accrued = mul_div_u256(e, old, acc, P);
    if accrued > *debt {
        *owed += accrued - *debt;
    }
    // Rounded up, so the holders' owed amounts never sum past the funds (B9).
    *debt = mul_div_up_u256(e, new, acc, P);
}

/// Releases the queue when this ledger is later than the last notify's (§6.2): to the holders when at least
/// `MIN_ELIGIBLE` units are eligible, else to the protocol. With `quote`, publishes an event per released pool;
/// without, it only previews the state for a view. Returns whether anything was released.
fn release(e: &Env, s: &mut Sharing, quote: Option<&Address>) -> bool {
    if e.ledger().sequence() <= s.queued_ledger || (s.q.queued == 0 && s.t.queued == 0) {
        return false;
    }
    let eligible = s.eligible;
    let this = e.current_contract_address();
    release_pool(e, &mut s.q, eligible, quote);
    release_pool(e, &mut s.t, eligible, quote.map(|_| &this));
    true
}

fn release_pool(e: &Env, pool: &mut RewardPool, eligible: i128, asset: Option<&Address>) {
    let amount = core::mem::take(&mut pool.queued);
    if amount == 0 {
        return;
    }
    if eligible >= MIN_ELIGIBLE {
        pool.acc += mul_div_u256(e, amount, P, eligible);
        if let Some(asset) = asset {
            RewardAdded { asset: asset.clone(), amount, eligible, acc: pool.acc }.publish(e);
        }
    } else {
        pool.protocol_owed += amount;
        if let Some(asset) = asset {
            RewardToProtocol { asset: asset.clone(), amount, eligible }.publish(e);
        }
    }
}

// ------------------------------------------------------------------------------------------------ entry points

/// Sharing on: the `Sharing` entry, with `treasury` excluded from birth (V2). All the supply goes to the launchpad,
/// which is excluded, so nothing is eligible yet.
pub(crate) fn init(e: &Env, treasury: &Address) {
    let mut s = Sharing::default();
    exclude_account(e, &mut s, treasury, false);
    write_sharing(e, &s);
}

/// `notify_reward`: the launchpad or the locker queues `amount` of `asset` (the quote, or this token), which it has
/// already transferred here. The funding check makes sure nothing is notified without its funds.
pub(crate) fn notify(e: &Env, notifier: &Address, asset: &Address, amount: i128) {
    let quote = require_sharing(e);
    if *notifier != LaunchTokenV2::launchpad(e) && *notifier != LaunchTokenV2::locker(e) {
        panic_with_error!(e, Error::NotNotifier);
    }
    notifier.require_auth();
    if amount <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
    let this = e.current_contract_address();
    let is_quote = *asset == quote;
    if !is_quote && *asset != this {
        panic_with_error!(e, Error::UnsupportedAsset);
    }
    let mut s = read_sharing(e);
    release(e, &mut s, Some(&quote));
    let (pool, balance) = if is_quote {
        (&mut s.q, TokenClient::new(e, &quote).balance(&this))
    } else {
        (&mut s.t, Base::balance(e, &this))
    };
    if balance < pool.funded - pool.paid + amount {
        panic_with_error!(e, Error::UnderFunded);
    }
    pool.funded += amount;
    pool.queued += amount;
    s.queued_ledger = e.ledger().sequence();
    write_sharing(e, &s);
    RewardQueued { asset: asset.clone(), notifier: notifier.clone(), amount, releasable_from: s.queued_ledger + 1 }
        .publish(e);
}

/// `claim`: pays `holder` what it is owed in both assets. The owed amounts are zeroed before the payout, and the
/// launch-token payout goes through the hook, so the holder is settled at its old balance and earns nothing on what
/// it claims.
pub(crate) fn claim(e: &Env, holder: &Address) -> (i128, i128) {
    let quote = require_sharing(e);
    let mut s = read_sharing(e);
    release(e, &mut s, Some(&quote));
    let (excluded, h) = lookup(e, &fixed_excluded(e), holder);
    if excluded {
        panic_with_error!(e, Error::ExcludedAccount);
    }
    let balance = Base::balance(e, holder);
    let mut h = settled(e, &s, h, balance, balance).unwrap_or_default();
    let (q, t) = (h.q_owed, h.t_owed);
    if q == 0 && t == 0 {
        panic_with_error!(e, Error::NothingToClaim);
    }
    h.q_owed = 0;
    h.t_owed = 0;
    write_holder(e, holder, &h);
    s.q.paid += q;
    s.t.paid += t;
    write_sharing(e, &s);
    pay(e, &quote, holder, q, t, |asset, amount| RewardClaimed { asset, holder: holder.clone(), amount }.publish(e));
    (q, t)
}

/// `exclude` (the launchpad) and `exclude_treasury`. False when `account` was excluded already, or with sharing off.
pub(crate) fn exclude(e: &Env, account: &Address, by_pool: bool) -> bool {
    let Some(quote) = sharing_quote(e) else {
        return false;
    };
    let mut s = read_sharing(e);
    let released = release(e, &mut s, Some(&quote));
    let excluded = exclude_account(e, &mut s, account, by_pool);
    if released || excluded {
        write_sharing(e, &s);
    }
    excluded
}

/// `exclude_treasury`: excludes the launchpad's current treasury (V2).
pub(crate) fn exclude_treasury(e: &Env) -> bool {
    if sharing_quote(e).is_none() {
        return false;
    }
    exclude(e, &treasury(e), false)
}

/// `exclude_pool`: anyone may exclude a verified DEX pool of this token above the floor (§6.2, L5, F2).
pub(crate) fn exclude_pool(e: &Env, kind: VenueKind, other: &Address, pool: &Address) -> bool {
    let quote = require_sharing(e);
    check_pool(e, kind, other, pool, AQUARIUS_POOL_LOOKUP_OK);
    let mut s = read_sharing(e);
    let released = release(e, &mut s, Some(&quote));
    let (excluded, h) = lookup(e, &fixed_excluded(e), pool);
    if excluded {
        if released {
            write_sharing(e, &s);
        }
        return false;
    }
    // The floor keeps dust pools from making the keeper pay for their exclusion.
    let balance = Base::balance(e, pool);
    let (q, t) = pending(e, &s, h, balance);
    if balance < EXCLUDE_MIN_BALANCE && q < EXCLUDE_MIN_OWED && t < EXCLUDE_MIN_BALANCE {
        panic_with_error!(e, Error::BelowFloor);
    }
    exclude_account(e, &mut s, pool, true);
    write_sharing(e, &s);
    true
}

/// `sweep_protocol`: pays both pools' protocol share to the launchpad's current treasury, which it excludes first
/// (V2).
pub(crate) fn sweep_protocol(e: &Env) -> (i128, i128) {
    let quote = require_sharing(e);
    let treasury = treasury(e);
    let mut s = read_sharing(e);
    release(e, &mut s, Some(&quote));
    exclude_account(e, &mut s, &treasury, false);
    let (q, t) = (s.q.protocol_owed, s.t.protocol_owed);
    if q == 0 && t == 0 {
        panic_with_error!(e, Error::NothingToClaim);
    }
    s.q.protocol_owed = 0;
    s.t.protocol_owed = 0;
    s.q.paid += q;
    s.t.paid += t;
    write_sharing(e, &s);
    pay(e, &quote, &treasury, q, t, |asset, amount| {
        RewardSwept { asset, treasury: treasury.clone(), amount }.publish(e)
    });
    (q, t)
}

/// Refuses `pool` unless it is `kind`'s pool of (this token, `other`) (§6.2, F2): always a Wasm contract, never this
/// token or `other`. `aquarius_lookup_ok` is CT-03's check 4 (`AQUARIUS_POOL_LOOKUP_OK`). The overall Aquarius venue
/// decision never matters here: anyone can open an Aquarius pool once the token is unlocked.
pub(crate) fn check_pool(e: &Env, kind: VenueKind, other: &Address, pool: &Address, aquarius_lookup_ok: bool) {
    let this = e.current_contract_address();
    if *pool == this || pool == other || *other == this || !is_wasm(pool) {
        panic_with_error!(e, Error::NotAPool);
    }
    let verified = match kind {
        VenueKind::Soroswap => is_soroswap_pair(e, &this, other, pool),
        VenueKind::Aquarius if aquarius_lookup_ok => is_aquarius_pool(e, &this, other, pool),
        VenueKind::Aquarius | VenueKind::HoldOnly | VenueKind::QaFail => {
            panic_with_error!(e, Error::UnsupportedVenue)
        }
    };
    if !verified {
        panic_with_error!(e, Error::NotAPool);
    }
}

/// The factory names `pool` for the pair, and the pair's own tokens are the pair.
fn is_soroswap_pair(e: &Env, this: &Address, other: &Address, pool: &Address) -> bool {
    let factory = SoroswapFactoryClient::new(e, &instance_address(e, DataKey::SoroswapFactory));
    if !factory.pair_exists(this, other) || factory.get_pair(this, other) != *pool {
        return false;
    }
    let pair = SoroswapPairClient::new(e, pool);
    let (t0, t1) = (pair.token_0(), pair.token_1());
    (t0 == *this && t1 == *other) || (t0 == *other && t1 == *this)
}

/// The router's pool lookup for the sorted pair holds `pool`, the pool's token list is that pair, and its share token
/// is a separate Wasm contract.
fn is_aquarius_pool(e: &Env, this: &Address, other: &Address, pool: &Address) -> bool {
    let tokens = sorted_pair(e, this, other);
    let router = AquariusRouterClient::new(e, &instance_address(e, DataKey::AquariusRouter));
    if !router.get_pools(&tokens).values().contains(pool) {
        return false;
    }
    let p = AquariusPoolClient::new(e, pool);
    if p.get_tokens() != tokens {
        return false;
    }
    let share = p.share_id();
    is_wasm(&share) && share != *pool && share != *this && share != *other
}

fn is_wasm(a: &Address) -> bool {
    matches!(a.executable(), Some(Executable::Wasm(_)))
}

// ------------------------------------------------------------------------------------------------ views

pub(crate) fn is_excluded(e: &Env, account: &Address) -> bool {
    lookup(e, &fixed_excluded(e), account).0
}

pub(crate) fn view(e: &Env) -> Option<SharingView> {
    let quote = sharing_quote(e)?;
    let s = read_sharing(e);
    Some(SharingView { quote, eligible: s.eligible, queued_ledger: s.queued_ledger, q: s.q, t: s.t })
}

/// What `account` could claim now, counting a queue that this ledger would release.
pub(crate) fn pending_rewards(e: &Env, account: &Address) -> (i128, i128) {
    if sharing_quote(e).is_none() {
        return (0, 0);
    }
    let mut s = read_sharing(e);
    release(e, &mut s, None);
    let (excluded, h) = lookup(e, &fixed_excluded(e), account);
    if excluded {
        return (0, 0);
    }
    pending(e, &s, h, Base::balance(e, account))
}

pub(crate) fn queued_rewards(e: &Env) -> (i128, i128, u32) {
    if sharing_quote(e).is_none() {
        return (0, 0, 0);
    }
    let s = read_sharing(e);
    (s.q.queued, s.t.queued, s.queued_ledger + 1)
}

// ------------------------------------------------------------------------------------------------ internals

/// Excludes `a` for good: settles it, takes its balance out of `eligible` and moves what it was owed in both pools to
/// the protocol (L5, I-T7). False when it was excluded already.
fn exclude_account(e: &Env, s: &mut Sharing, a: &Address, by_pool: bool) -> bool {
    let (excluded, h) = lookup(e, &fixed_excluded(e), a);
    if excluded {
        return false;
    }
    let balance = Base::balance(e, a);
    let (stranded_q, stranded_t) = pending(e, s, h, balance);
    s.eligible -= balance;
    s.q.protocol_owed += stranded_q;
    s.t.protocol_owed += stranded_t;
    write_holder(e, a, &Holder { excluded: true, ..Holder::default() });
    Excluded { account: a.clone(), by_pool, stranded_q, stranded_t }.publish(e);
    true
}

/// What an eligible account with entry `h` and `balance` is owed in both pools once settled.
fn pending(e: &Env, s: &Sharing, h: Option<Holder>, balance: i128) -> (i128, i128) {
    settled(e, s, h, balance, balance).map_or((0, 0), |h| (h.q_owed, h.t_owed))
}

/// Pays `q` of the quote and `t` launch tokens from the token's own address to `to`, calling `paid` per asset paid.
/// The launch tokens move through the hook: the token itself is excluded, so `to` is settled at its old balance
/// before it grows (§6.2).
fn pay(e: &Env, quote: &Address, to: &Address, q: i128, t: i128, paid: impl Fn(Address, i128)) {
    let this = e.current_contract_address();
    if q > 0 {
        TokenClient::new(e, quote).transfer(&this, to, &q);
        paid(quote.clone(), q);
    }
    if t > 0 {
        before_update(e, Some(&this), Some(to), t);
        Base::update(e, Some(&this), Some(to), t);
        emit_transfer(e, &this, to, None, t);
        paid(this, t);
    }
}

/// Whether `a` is excluded, and its `Holder` entry.
fn lookup(e: &Env, fixed: &Vec<Address>, a: &Address) -> (bool, Option<Holder>) {
    if fixed.contains(a) {
        return (true, None);
    }
    let h = read_holder(e, a);
    (h.as_ref().is_some_and(|h| h.excluded), h)
}

fn treasury(e: &Env) -> Address {
    TreasurySourceClient::new(e, &LaunchTokenV2::launchpad(e)).treasury()
}

fn sharing_quote(e: &Env) -> Option<Address> {
    e.storage().instance().get::<_, Option<Address>>(&DataKey::SharingQuote).flatten()
}

fn require_sharing(e: &Env) -> Address {
    sharing_quote(e).unwrap_or_else(|| panic_with_error!(e, Error::SharingOff))
}

fn fixed_excluded(e: &Env) -> Vec<Address> {
    e.storage().instance().get(&DataKey::FixedExcluded).unwrap()
}

fn instance_address(e: &Env, key: DataKey) -> Address {
    e.storage().instance().get(&key).unwrap()
}

// Persistent entries are bumped whenever they are touched, as OpenZeppelin bumps balances (§13).

fn read_sharing(e: &Env) -> Sharing {
    let key = DataKey::Sharing;
    let s = e.storage().persistent().get(&key).unwrap();
    bump(e, &key);
    s
}

fn write_sharing(e: &Env, s: &Sharing) {
    let key = DataKey::Sharing;
    e.storage().persistent().set(&key, s);
    bump(e, &key);
}

fn read_holder(e: &Env, a: &Address) -> Option<Holder> {
    let key = DataKey::Holder(a.clone());
    let h = e.storage().persistent().get(&key);
    if h.is_some() {
        bump(e, &key);
    }
    h
}

fn write_holder(e: &Env, a: &Address, h: &Holder) {
    let key = DataKey::Holder(a.clone());
    e.storage().persistent().set(&key, h);
    bump(e, &key);
}

fn bump<K: IntoVal<Env, Val>>(e: &Env, key: &K) {
    e.storage().persistent().extend_ttl(key, BALANCE_TTL_THRESHOLD, BALANCE_EXTEND_AMOUNT);
}
