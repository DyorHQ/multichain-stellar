//! Governance, the guardian and the dual pause, the policy timelock, and the terms a publish binds (§9.1, §9.2, §16).
//!
//! - **Governance** hands over in two steps (`propose_governance`, `accept_governance`), proposes policies, pauses
//!   publishing and sets the external-link base. It can't change a live Moment, move a reserve, redirect a
//!   beneficiary or change the post-graduation split (§16).
//! - **The guardian** can cancel a pending policy, set its own pause (which only it can lift) and hand its role on in
//!   one step or renounce it, never while its pause is on (`UnpauseFirst`), so a pause can't outlive the key that can
//!   lift it. Nobody can replace a lost guardian, as on Monad (M:contracts/src/moments/MomentsFactory.sol:142-152).
//! - **Pauses** stop `publish` only. Collect, claim, withdraw, graduate and expire never pause (I-M5).
//! - **Policies** follow M:contracts/src/moments/MomentsFactory.sol:176-201 with the deployment's durations: a proposal
//!   applies from `now + timelock`, by anyone, until `timelock_window` later; after that it has lapsed and can only be
//!   replaced or cancelled. Validation is Monad's (:292-301) adapted to 7 decimals ([`policy_ok`]).
//! - **Terms** ([`MomentsTerms`]) are what a creator's phone showed: the policy, the external base, both WASM hashes,
//!   the peers, the durations and the post-graduation constants. `publish` takes them by value and refuses any
//!   difference (`TermsChanged`), so applying a policy in front of a publish can't change a creator's terms.

use crate::events::{
    ExternalBaseSet, GovernanceProposed, GovernanceSet, GuardianPaused, GuardianSet, PolicyCancelled, PolicyProposed,
    PolicySet, PublishingPaused,
};
use crate::storage::{self, Config, DataKey, PendingPolicy, Policy};
use crate::{Error, MomentsV2, MomentsV2Args, MomentsV2Client, MOMENT_HARVEST_BPS, MOMENT_HARVEST_CREATOR_BPS};
use dyor_common::{mul_div_up, MomentsDurations, BPS};
use soroban_sdk::{contractimpl, contracttype, panic_with_error, Address, Bytes, BytesN, Env, String};

/// Policy bounds (§9.2): a threshold of 1 to 1,000,000 USDC (the upper bound keeps every product in i128), a minimum
/// price of at least 0.01 USDC.
pub const MIN_THRESHOLD: i128 = 10_000_000;
pub const MAX_THRESHOLD: i128 = 10_000_000_000_000;
pub const MIN_MIN_PRICE: i128 = 100_000;
/// Hard caps no policy can exceed: the creator's coin allocation and the royalty, 10% each (MomentTypes.sol:15-17).
pub const MAX_CREATOR_ALLOC_BPS: u32 = 1_000;
pub const MAX_ROYALTY_BPS: u32 = 1_000;
/// The external-link base: https only, at most 256 bytes (MomentsFactory.sol:28).
pub const MAX_EXTERNAL_BASE: u32 = 256;
const HTTPS: &[u8; 8] = b"https://";

/// What a Moment published now is bound to (§9.1). Every field is compared by value at `publish`.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MomentsTerms {
    pub policy: Policy,
    pub external_base: String,
    pub nft_wasm_hash: BytesN<32>,
    pub coin_wasm_hash: BytesN<32>,
    pub graduator: Address,
    pub executor: Address,
    pub locker: Address,
    pub durations: MomentsDurations,
    /// `MOMENT_HARVEST_BPS`: compounded : harvested = (BPS − 6,667) : 6,667 = 3,333 : 6,667 every round (V3).
    pub harvest_bps: u32,
    /// `MOMENT_HARVEST_CREATOR_BPS`: the creator's share of the harvested USDC side; the platform gets the rest.
    pub harvest_creator_bps: u32,
}

/// §9.2's policy rules, in an order that keeps every product in range: the threshold's bounds and a positive reserve
/// share are checked before the price ceiling is computed.
pub(crate) fn policy_ok(p: &Policy) -> bool {
    let split = p.creator_bps as u64 + p.platform_bps as u64 + p.reserve_bps as u64;
    (MIN_THRESHOLD..=MAX_THRESHOLD).contains(&p.threshold)
        && p.min_price >= MIN_MIN_PRICE
        && p.reserve_bps > 0
        && split == BPS as u64
        && p.min_price <= price_ceiling(p.threshold, p.reserve_bps)
        && p.max_creator_alloc_bps <= MAX_CREATOR_ALLOC_BPS
        && p.expiry_creator_bps <= BPS
        && p.royalty_bps <= MAX_ROYALTY_BPS
}

/// The highest price a Moment may list: the gross that completes the reserve from empty, `ceil(T·BPS/reserve_bps)`
/// (MomentsFactory.sol:242). A higher price would never be charged, because the first collect is clamped to it.
pub(crate) fn price_ceiling(threshold: i128, reserve_bps: u32) -> i128 {
    mul_div_up(threshold, BPS as i128, reserve_bps as i128)
}

/// An external base is `https://…` and at most 256 bytes.
pub(crate) fn base_ok(e: &Env, base: &String) -> bool {
    let len = base.len();
    len >= HTTPS.len() as u32
        && len <= MAX_EXTERNAL_BASE
        && base.to_bytes().slice(0..HTTPS.len() as u32) == Bytes::from_array(e, HTTPS)
}

/// The terms a Moment published now would snapshot.
pub(crate) fn terms(e: &Env, cfg: &Config) -> MomentsTerms {
    MomentsTerms {
        policy: storage::policy(e),
        external_base: cfg.external_base.clone(),
        nft_wasm_hash: cfg.nft_wasm_hash.clone(),
        coin_wasm_hash: cfg.coin_wasm_hash.clone(),
        graduator: cfg.graduator.clone(),
        executor: cfg.executor.clone(),
        locker: cfg.locker.clone(),
        durations: cfg.durations,
        harvest_bps: MOMENT_HARVEST_BPS,
        harvest_creator_bps: MOMENT_HARVEST_CREATOR_BPS,
    }
}

/// The guardian, or `NotGuardian` once there is none.
fn guardian(e: &Env, cfg: &Config) -> Address {
    cfg.guardian.clone().unwrap_or_else(|| panic_with_error!(e, Error::NotGuardian))
}

#[contractimpl]
impl MomentsV2 {
    // -------------------------------------------------------------------------------------------- governance

    /// Starts a governance handoff to `new`, which must accept. Governance only; a new proposal replaces the last.
    pub fn propose_governance(e: Env, new: Address) {
        let cfg = storage::config(&e);
        cfg.governance.require_auth();
        e.storage().instance().set(&DataKey::PendingGovernance, &new);
        GovernanceProposed { governance: cfg.governance, new }.publish(&e);
    }

    /// Completes the handoff. The proposed governance only.
    pub fn accept_governance(e: Env) {
        let new = storage::pending_governance(&e).unwrap_or_else(|| panic_with_error!(&e, Error::NoProposal));
        new.require_auth();
        let mut cfg = storage::config(&e);
        let old = cfg.governance.clone();
        cfg.governance = new.clone();
        storage::set_config(&e, &cfg);
        e.storage().instance().remove(&DataKey::PendingGovernance);
        GovernanceSet { old, new }.publish(&e);
    }

    /// Hands the guardian role to `new` at once, or renounces it with `None`. The guardian only, and never while its
    /// pause is on (`UnpauseFirst`): a wrong or absent successor could never lift it.
    pub fn transfer_guardian(e: Env, new: Option<Address>) {
        let mut cfg = storage::config(&e);
        let old = guardian(&e, &cfg);
        old.require_auth();
        if cfg.guardian_paused {
            panic_with_error!(&e, Error::UnpauseFirst);
        }
        cfg.guardian = new.clone();
        storage::set_config(&e, &cfg);
        GuardianSet { old, new }.publish(&e);
    }

    /// Queues `p` for Moments published after `now + timelock`; it must be applied within `timelock_window` of that.
    /// Governance only. A new proposal replaces the pending one.
    pub fn propose_policy(e: Env, p: Policy) {
        let cfg = storage::config(&e);
        cfg.governance.require_auth();
        if !policy_ok(&p) {
            panic_with_error!(&e, Error::InvalidPolicy);
        }
        let eta = e.ledger().timestamp() + cfg.durations.timelock;
        let expires = eta + cfg.durations.timelock_window;
        e.storage().instance().set(&DataKey::PendingPolicy, &PendingPolicy { policy: p.clone(), eta, expires });
        PolicyProposed { policy: p, eta, expires }.publish(&e);
    }

    /// Applies the pending policy. Anyone, from its `eta` until it `expires`; after that it has lapsed.
    pub fn apply_policy(e: Env) {
        let pending = storage::pending_policy(&e).unwrap_or_else(|| panic_with_error!(&e, Error::NoPendingPolicy));
        let now = e.ledger().timestamp();
        if now < pending.eta {
            panic_with_error!(&e, Error::PolicyNotReady);
        }
        if now > pending.expires {
            panic_with_error!(&e, Error::PolicyLapsed);
        }
        storage::set_policy(&e, &pending.policy);
        e.storage().instance().remove(&DataKey::PendingPolicy);
        PolicySet { policy: pending.policy }.publish(&e);
    }

    /// Cancels the pending policy (or a lapsed one). `caller` must be governance or the guardian, with its auth.
    pub fn cancel_policy(e: Env, caller: Address) {
        caller.require_auth();
        let cfg = storage::config(&e);
        if caller != cfg.governance && Some(&caller) != cfg.guardian.as_ref() {
            panic_with_error!(&e, Error::NotAuthorized);
        }
        if storage::pending_policy(&e).is_none() {
            panic_with_error!(&e, Error::NoPendingPolicy);
        }
        e.storage().instance().remove(&DataKey::PendingPolicy);
        PolicyCancelled { by: caller }.publish(&e);
    }

    /// Governance's pause of `publish`; nothing else pauses (I-M5).
    pub fn set_publishing_paused(e: Env, paused: bool) {
        let mut cfg = storage::config(&e);
        cfg.governance.require_auth();
        cfg.publishing_paused = paused;
        storage::set_config(&e, &cfg);
        PublishingPaused { paused }.publish(&e);
    }

    /// The guardian's own pause of `publish`: only the guardian sets or lifts it.
    pub fn set_guardian_paused(e: Env, paused: bool) {
        let mut cfg = storage::config(&e);
        guardian(&e, &cfg).require_auth();
        cfg.guardian_paused = paused;
        storage::set_config(&e, &cfg);
        GuardianPaused { paused }.publish(&e);
    }

    /// The external-link base of Moments published from now on (existing NFTs keep theirs). Governance only; it is
    /// part of the terms. `InvalidBase` unless https and at most 256 bytes.
    pub fn set_external_base(e: Env, base: String) {
        let mut cfg = storage::config(&e);
        cfg.governance.require_auth();
        if !base_ok(&e, &base) {
            panic_with_error!(&e, Error::InvalidBase);
        }
        cfg.external_base = base.clone();
        storage::set_config(&e, &cfg);
        ExternalBaseSet { base }.publish(&e);
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn config(e: Env) -> Config {
        storage::config(&e)
    }

    pub fn policy(e: Env) -> Policy {
        storage::policy(&e)
    }

    /// The pending policy with its `eta` and `expires`; a lapsed one stays visible until it is replaced or cancelled.
    pub fn pending_policy(e: Env) -> Option<PendingPolicy> {
        storage::pending_policy(&e)
    }

    pub fn pending_governance(e: Env) -> Option<Address> {
        storage::pending_governance(&e)
    }

    /// The terms a Moment published now would be bound to; the phone passes them back to `publish`.
    pub fn terms(e: Env) -> MomentsTerms {
        terms(&e, &storage::config(&e))
    }
}
