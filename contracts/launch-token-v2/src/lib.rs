//! DyorHQ launch-token-v2 (DESIGN-stellar-contracts-v2 §6): one SEP-41 token per launch, deployed by launchpad-v2.
//!
//! - The whole supply is minted to the launchpad at construction.
//! - **Transfer lock** (§6.1, L4; [`lock`]): until the launchpad calls `unlock` (at graduation or at rescue, L6), a
//!   transfer needs `from == launchpad`, `from ∈ lock_from` (this launch's venue and fallback executors) or
//!   `to == launchpad`. Burns are always allowed. The locker is not exempt.
//! - **The token's own address** holds the launch-token rewards. Nothing transfers, burns or approves from it, before
//!   or after unlock (`TokenAccount`); only `claim` and `sweep_protocol` pay out of it (F1, I-T8). Transfers to it
//!   are allowed.
//! - **Holder rewards** (§6.2; [`rewards`]), when the launch opted in (`sharing_quote` is set): reward-per-share in two
//!   pools, the quote and the launch token itself, released on a later ledger than the one they were notified in.
//!   The launchpad, the locker, the executors, the token itself, the treasury and excluded DEX pools never earn.
//!
//! Built on OpenZeppelin `stellar-tokens` `Base` with the burnable extension. `transfer`, `transfer_from`, `burn`,
//! `burn_from` and `approve` are overridden the way the votes extension overrides them
//! (oz:src/fungible/extensions/votes/storage.rs:55-190): the lock and the reward hook run first, then OpenZeppelin's
//! own function. There is no admin and no upgrade, and no call extends the instance's TTL (DECISIONS
//! #10): the keeper keeps the instance alive.
#![no_std]

mod lock;
mod rewards;

pub use rewards::{Holder, RewardPool, Sharing, SharingView, EXCLUDE_MIN_BALANCE, EXCLUDE_MIN_OWED, MIN_ELIGIBLE, P};

use dyor_common::VenueKind;
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, Address, Env, MuxedAddress,
    String, Vec,
};
use stellar_tokens::fungible::{burnable::FungibleBurnable, Base, FungibleToken};

/// Every launch token has 7 decimals, like Stellar assets.
pub const DECIMALS: u32 = 7;
/// `lock_from` holds this launch's venue executor and its fallback executor.
pub const MAX_LOCK_FROM: u32 = 2;
/// `FixedExcluded`: the launchpad, the locker, the two executors and the token itself.
pub const MAX_FIXED_EXCLUDED: u32 = 5;

#[contracttype]
#[derive(Clone)]
enum DataKey {
    // instance (§6.3)
    Launchpad,
    Locker,
    LockFrom,
    FixedExcluded,
    Unlocked,
    SharingQuote,
    SoroswapFactory,
    AquariusRouter,
    // persistent, with sharing on only
    Sharing,
    Holder(Address),
}

/// The local codes of §6.4 in this contract's namespace: on chain `ERR_BASE + 2·100 + n` (§4, V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// A transfer before `unlock` that none of the §6.1 paths allows.
    TransferLocked = 10_201,
    /// `unlock` called twice.
    AlreadyUnlocked = 10_202,
    /// The supply must be positive.
    InvalidSupply = 10_203,
    /// Kept so the numbering stays as §6.4 lists it. The launchpad-only functions (`unlock`, `exclude`) check the
    /// launchpad's own auth, which fails with the host's auth error before any contract code could raise this.
    NotLaunchpad = 10_204,
    /// `notify_reward` from a notifier other than the launchpad or the locker.
    NotNotifier = 10_205,
    /// A rewards function on a launch without holder sharing.
    SharingOff = 10_206,
    /// `notify_reward` without the funds: the asset's balance here would not cover what is owed plus the amount.
    UnderFunded = 10_207,
    /// `claim` or `sweep_protocol` with nothing to pay in either asset.
    NothingToClaim = 10_208,
    /// `exclude_pool` on an address that isn't that venue's pool of (this token, `other`).
    NotAPool = 10_209,
    /// `notify_reward` of 0 or less.
    ZeroAmount = 10_210,
    /// `exclude_pool` for a venue kind it can't verify (Aquarius only when CT-03's check 4 failed).
    UnsupportedVenue = 10_211,
    /// `claim` by an excluded account.
    ExcludedAccount = 10_212,
    /// A transfer, burn or approval from the token's own address (F1).
    TokenAccount = 10_213,
    /// `exclude_pool` on a pool below the exclusion floor (F2).
    BelowFloor = 10_214,
    /// `notify_reward` of an asset other than the quote or this token.
    UnsupportedAsset = 10_215,
}
dyor_common::assert_err_codes!(
    dyor_common::TAG_LAUNCH_TOKEN_V2;
    Error::TransferLocked = 1,
    Error::AlreadyUnlocked = 2,
    Error::InvalidSupply = 3,
    Error::NotLaunchpad = 4,
    Error::NotNotifier = 5,
    Error::SharingOff = 6,
    Error::UnderFunded = 7,
    Error::NothingToClaim = 8,
    Error::NotAPool = 9,
    Error::ZeroAmount = 10,
    Error::UnsupportedVenue = 11,
    Error::ExcludedAccount = 12,
    Error::TokenAccount = 13,
    Error::BelowFloor = 14,
    Error::UnsupportedAsset = 15,
);

// ------------------------------------------------------------------------------------------------ events (§6.4)

/// Transfers opened for everyone: graduation or rescue.
#[contractevent(topics = ["unlocked"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Unlocked {
    pub launchpad: Address,
}

/// `account` no longer earns rewards. What it had earned and not claimed went to the protocol (L5).
#[contractevent(topics = ["excluded"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Excluded {
    #[topic]
    pub account: Address,
    /// Excluded through `exclude_pool`.
    pub by_pool: bool,
    pub stranded_q: i128,
    pub stranded_t: i128,
}

/// A notifier funded `amount` of `asset`; holders share it from ledger `releasable_from` on.
#[contractevent(topics = ["rwd_queue"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RewardQueued {
    #[topic]
    pub asset: Address,
    pub notifier: Address,
    pub amount: i128,
    pub releasable_from: u32,
}

/// A released queue was shared among `eligible` token units; `acc` is the pool's new reward per share.
#[contractevent(topics = ["rwd_add"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RewardAdded {
    #[topic]
    pub asset: Address,
    pub amount: i128,
    pub eligible: i128,
    pub acc: i128,
}

/// A released queue went to the protocol: fewer than `MIN_ELIGIBLE` units were eligible.
#[contractevent(topics = ["rwd_proto"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RewardToProtocol {
    #[topic]
    pub asset: Address,
    pub amount: i128,
    pub eligible: i128,
}

#[contractevent(topics = ["rwd_claim"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RewardClaimed {
    #[topic]
    pub asset: Address,
    #[topic]
    pub holder: Address,
    pub amount: i128,
}

#[contractevent(topics = ["rwd_sweep"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RewardSwept {
    #[topic]
    pub asset: Address,
    #[topic]
    pub treasury: Address,
    pub amount: i128,
}

// ------------------------------------------------------------------------------------------------ the contract

#[contract]
pub struct LaunchTokenV2;

#[contractimpl]
impl LaunchTokenV2 {
    /// Mints `supply` to `launchpad`.
    ///
    /// - `lock_from`: this launch's venue and fallback executors, the only senders besides the launchpad before
    ///   unlock.
    /// - `fixed_excluded`: what never earns rewards. The token keeps the given set plus the launchpad, the locker,
    ///   `lock_from` and itself; launchpad-v2 passes the first four already, and adding them here keeps them out of
    ///   the rewards whatever a deployer passes (I-T10).
    /// - `sharing_quote`: the quote when the launch shares fees with its holders, else `None`.
    /// - `soroswap_factory` and `aquarius_router`: the venues `exclude_pool` checks a pool against (F2).
    /// - `treasury`: the launchpad's treasury of the moment; with sharing on it is excluded from birth (V2).
    #[allow(clippy::too_many_arguments)]
    pub fn __constructor(
        e: &Env,
        launchpad: Address,
        locker: Address,
        name: String,
        symbol: String,
        supply: i128,
        lock_from: Vec<Address>,
        fixed_excluded: Vec<Address>,
        sharing_quote: Option<Address>,
        soroswap_factory: Address,
        aquarius_router: Address,
        treasury: Address,
    ) {
        if supply <= 0 {
            panic_with_error!(e, Error::InvalidSupply);
        }
        let lock_from = dedup(e, lock_from);
        assert!(lock_from.len() <= MAX_LOCK_FROM, "lock_from holds at most 2 executors");
        let mut fixed = dedup(e, fixed_excluded);
        for a in [launchpad.clone(), locker.clone()].into_iter().chain(lock_from.iter()) {
            push_new(&mut fixed, a);
        }
        push_new(&mut fixed, e.current_contract_address());
        assert!(fixed.len() <= MAX_FIXED_EXCLUDED, "FixedExcluded holds at most 5 accounts");

        Base::set_metadata(e, DECIMALS, name, symbol);
        let s = e.storage().instance();
        s.set(&DataKey::Launchpad, &launchpad);
        s.set(&DataKey::Locker, &locker);
        s.set(&DataKey::LockFrom, &lock_from);
        s.set(&DataKey::FixedExcluded, &fixed);
        s.set(&DataKey::Unlocked, &false);
        s.set(&DataKey::SharingQuote, &sharing_quote);
        s.set(&DataKey::SoroswapFactory, &soroswap_factory);
        s.set(&DataKey::AquariusRouter, &aquarius_router);

        if sharing_quote.is_some() {
            rewards::init(e, &treasury);
        }
        rewards::before_update(e, None, Some(&launchpad), supply);
        Base::mint(e, &launchpad, supply);
    }

    /// Opens transfers for everyone. The launchpad only, once: at graduation or at rescue (L6).
    pub fn unlock(e: &Env) {
        let launchpad = Self::launchpad(e);
        launchpad.require_auth();
        if lock::unlocked(e) {
            panic_with_error!(e, Error::AlreadyUnlocked);
        }
        e.storage().instance().set(&DataKey::Unlocked, &true);
        Unlocked { launchpad }.publish(e);
    }

    /// Excludes `account` (the graduation pool) from holder rewards; what it had earned goes to the protocol. The
    /// launchpad only. False when it was already excluded, or with sharing off.
    pub fn exclude(e: &Env, account: Address) -> bool {
        Self::launchpad(e).require_auth();
        rewards::exclude(e, &account, false)
    }

    /// Excludes another DEX pool of this token, once it is verified against its venue (§6.2, L5, F2): a Wasm
    /// contract that the Soroswap factory or the Aquarius router names for (this token, `other`), whose own token
    /// list (and, for Aquarius, share token) matches, holding at least `EXCLUDE_MIN_BALANCE` tokens or that much in
    /// unclaimed rewards (`EXCLUDE_MIN_OWED` in the quote). Anyone may call it. False when the pool was already
    /// excluded.
    pub fn exclude_pool(e: &Env, kind: VenueKind, other: Address, pool: Address) -> bool {
        rewards::exclude_pool(e, kind, &other, &pool)
    }

    /// Queues `amount` of `asset` (the quote, or this token) for the holders, from the next ledger on. `notifier` is
    /// the launchpad or the locker, which transferred the funds here first.
    pub fn notify_reward(e: &Env, notifier: Address, asset: Address, amount: i128) {
        rewards::notify(e, &notifier, &asset, amount);
    }

    /// Pays `holder` its quote and launch-token rewards. Returns `(quote, token)`; either may be 0.
    pub fn claim(e: &Env, holder: Address) -> (i128, i128) {
        holder.require_auth();
        rewards::claim(e, &holder)
    }

    /// Excludes the launchpad's current treasury (V2). Anyone may call it: the locker before it pays a harvest's
    /// launch-token side, the keeper after a treasury change. False with sharing off, or when it was excluded
    /// already. Never called from inside a launchpad call: it reads `launchpad.treasury()`.
    pub fn exclude_treasury(e: &Env) -> bool {
        rewards::exclude_treasury(e)
    }

    /// Pays both pools' protocol share to the launchpad's current treasury, excluding it first. Anyone may call it,
    /// from the top level. Returns `(quote, token)`.
    pub fn sweep_protocol(e: &Env) -> (i128, i128) {
        rewards::sweep_protocol(e)
    }

    // -------------------------------------------------------------------------------------------- views

    /// The launchpad that deployed this token.
    pub fn launchpad(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Launchpad).unwrap()
    }

    pub fn locker(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Locker).unwrap()
    }

    /// Whether transfers are open to everyone (after graduation or rescue).
    pub fn unlocked(e: &Env) -> bool {
        lock::unlocked(e)
    }

    /// The executors that may send before unlock.
    pub fn lock_from(e: &Env) -> Vec<Address> {
        lock::lock_from(e)
    }

    pub fn is_excluded(e: &Env, account: Address) -> bool {
        rewards::is_excluded(e, &account)
    }

    /// The sharing state, or `None` when the launch doesn't share fees with its holders.
    pub fn sharing(e: &Env) -> Option<SharingView> {
        rewards::view(e)
    }

    /// What `account` could claim now, as `(quote, token)`, including a queue that is releasable in this ledger.
    pub fn pending_rewards(e: &Env, account: Address) -> (i128, i128) {
        rewards::pending_rewards(e, &account)
    }

    /// The queued, not yet released rewards and the first ledger that releases them: `(quote, token, ledger)`.
    pub fn queued_rewards(e: &Env) -> (i128, i128, u32) {
        rewards::queued_rewards(e)
    }

    /// `exclude_pool`'s floor: `(min_balance, min_owed)` (§6.2).
    pub fn exclusion_floor(_e: &Env) -> (i128, i128) {
        (EXCLUDE_MIN_BALANCE, EXCLUDE_MIN_OWED)
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_LAUNCH_TOKEN_V2
    }
}

// OpenZeppelin's `Base` with this token's rules, in the votes extension's style: each override runs the lock (§6.1)
// and the reward hook (§6.2) on the balances before the change, then OpenZeppelin's own function, which checks auth,
// allowance and balance, moves the tokens and emits the SEP-41 event. The overrides sit in the trait impls because
// stellar-tokens 0.7.2 keeps the fungible `BurnableOverrides` trait private to the crate.
#[contractimpl(contracttrait)]
impl FungibleToken for LaunchTokenV2 {
    type ContractType = Base;

    fn transfer(e: &Env, from: Address, to: MuxedAddress, amount: i128) {
        let to_address = to.address();
        lock::check_transfer(e, &from, &to_address);
        rewards::before_update(e, Some(&from), Some(&to_address), amount);
        Base::transfer(e, &from, &to, amount);
    }

    fn transfer_from(e: &Env, spender: Address, from: Address, to: Address, amount: i128) {
        lock::check_transfer(e, &from, &to);
        rewards::before_update(e, Some(&from), Some(&to), amount);
        Base::transfer_from(e, &spender, &from, &to, amount);
    }

    fn approve(e: &Env, owner: Address, spender: Address, amount: i128, live_until_ledger: u32) {
        lock::check_not_token_account(e, &owner);
        Base::approve(e, &owner, &spender, amount, live_until_ledger);
    }
}

#[contractimpl(contracttrait)]
impl FungibleBurnable for LaunchTokenV2 {
    fn burn(e: &Env, from: Address, amount: i128) {
        lock::check_not_token_account(e, &from);
        rewards::before_update(e, Some(&from), None, amount);
        Base::burn(e, &from, amount);
    }

    fn burn_from(e: &Env, spender: Address, from: Address, amount: i128) {
        lock::check_not_token_account(e, &from);
        rewards::before_update(e, Some(&from), None, amount);
        Base::burn_from(e, &spender, &from, amount);
    }
}

/// `list` without repeats, in its order.
fn dedup(e: &Env, list: Vec<Address>) -> Vec<Address> {
    let mut out = Vec::new(e);
    for a in list.iter() {
        push_new(&mut out, a);
    }
    out
}

fn push_new(list: &mut Vec<Address>, a: Address) {
    if !list.contains(&a) {
        list.push_back(a);
    }
}

#[cfg(test)]
mod test;
