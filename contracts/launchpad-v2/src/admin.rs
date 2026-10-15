//! Admin and guardian powers (DESIGN-stellar-contracts-v2 §5.4, §16).
//!
//! - The admin sets what applies to **future** launches only (fees, the launch fee, quotes, venues' availability, the
//!   pause and the whitelist) and proposes timelocked changes: a new treasury, a new venue and a new guardian. It hands
//!   its own role on in two steps. It can never touch reserves, booked fees, a live launch's terms or venue, or any
//!   duration (I-L4).
//! - The guardian can only cancel pending treasury and venue proposals, hand its role on in two steps
//!   (`transfer_guardian`, then `accept_guardian` by the new key) or renounce it (L8).
//! - Recovery of a lost or compromised guardian key (F16): the admin proposes a replacement (or none), anyone applies it
//!   inside the window after the timelock, and only the admin can cancel it. A guardian handoff leaves it pending.
//!
//! A timelocked proposal applies from `eta = now + timelock` until `eta + timelock_window` (both ends included).

use crate::events::{
    AdminProposed, AdminSet, ConfigSet, GuardianHandoffStarted, GuardianProposalCancelled, GuardianProposed,
    GuardianSet, LaunchFeeSet, QuoteSet, TreasuryProposalCancelled, TreasuryProposed, TreasurySet, VenueAdded,
    VenueEnabled, VenueProposalCancelled, VenueProposed, WhitelistSet,
};
use crate::storage::{
    config, find_venue, instance_get, items, proposal, set_config, set_venues, venues, Config, DataKey,
    PendingGuardian, PendingTreasury, PendingVenue, QuoteEconomics, VenueInfo, VenueInit,
};
use crate::{curve::MAX_TOTAL_BPS, Error, MAX_LAUNCH_FEE, MAX_SCHEDULE, MAX_SNIPE_STEP_SECS, MAX_VENUES};
use dyor_common::aquarius::AQUARIUS_FEE_TIERS;
use dyor_common::{VenueKind, VenueParams, BPS};
use soroban_sdk::{panic_with_error, Address, Env, Executable, Vec};

/// The config, once the admin has authorized the call.
pub(crate) fn require_admin(e: &Env) -> Config {
    let cfg = config(e);
    cfg.admin.require_auth();
    cfg
}

/// `caller`, who must be the admin or the guardian (L8), has authorized the call.
fn require_admin_or_guardian(e: &Env, caller: &Address) {
    let cfg = config(e);
    if *caller != cfg.admin && cfg.guardian.as_ref() != Some(caller) {
        panic_with_error!(e, Error::NotAuthorized);
    }
    caller.require_auth();
}

/// `(eta, expires)` of a proposal made now.
fn timelock(e: &Env, cfg: &Config) -> (u64, u64) {
    let eta = e.ledger().timestamp() + cfg.durations.timelock;
    (eta, eta + cfg.durations.timelock_window)
}

/// Refuses outside `[from, until]`.
pub(crate) fn check_window(e: &Env, from: u64, until: u64) {
    let now = e.ledger().timestamp();
    if now < from {
        panic_with_error!(e, Error::TimelockNotElapsed);
    }
    if now > until {
        panic_with_error!(e, Error::TimelockExpired);
    }
}

// ------------------------------------------------------------------------------------------------ admin handoff

pub(crate) fn propose_admin(e: &Env, new: Address) {
    require_admin(e);
    e.storage().instance().set(&DataKey::PendingAdmin, &new);
    AdminProposed { proposed: new }.publish(e);
}

pub(crate) fn accept_admin(e: &Env) {
    let new: Address = proposal(e, &DataKey::PendingAdmin);
    new.require_auth();
    let mut cfg = config(e);
    cfg.admin = new.clone();
    set_config(e, &cfg);
    e.storage().instance().remove(&DataKey::PendingAdmin);
    AdminSet { new }.publish(e);
}

// ------------------------------------------------------------------------------------------------ guardian (L8, F16)

pub(crate) fn transfer_guardian(e: &Env, new: Address) {
    let guardian = config(e).guardian.unwrap_or_else(|| panic_with_error!(e, Error::NotAuthorized));
    guardian.require_auth();
    e.storage().instance().set(&DataKey::GuardianHandoff, &new);
    GuardianHandoffStarted { new }.publish(e);
}

/// The handoff's new key takes the role. A pending admin replacement stays pending.
pub(crate) fn accept_guardian(e: &Env) {
    let new: Address = proposal(e, &DataKey::GuardianHandoff);
    new.require_auth();
    e.storage().instance().remove(&DataKey::GuardianHandoff);
    set_guardian(e, Some(new));
}

/// The guardian gives the role up; a pending handoff goes with it.
pub(crate) fn renounce_guardian(e: &Env) {
    let guardian = config(e).guardian.unwrap_or_else(|| panic_with_error!(e, Error::NotAuthorized));
    guardian.require_auth();
    e.storage().instance().remove(&DataKey::GuardianHandoff);
    set_guardian(e, None);
}

pub(crate) fn propose_guardian(e: &Env, new: Option<Address>) {
    let cfg = require_admin(e);
    let (eta, expires) = timelock(e, &cfg);
    let p = PendingGuardian { new: new.clone(), eta, expires };
    e.storage().instance().set(&DataKey::PendingGuardian, &p);
    GuardianProposed { new, eta, expires }.publish(e);
}

/// Anyone, inside the window. The replacement also clears a pending handoff, so the old key can't pass the role on.
pub(crate) fn apply_guardian(e: &Env) {
    let p: PendingGuardian = proposal(e, &DataKey::PendingGuardian);
    check_window(e, p.eta, p.expires);
    e.storage().instance().remove(&DataKey::PendingGuardian);
    e.storage().instance().remove(&DataKey::GuardianHandoff);
    set_guardian(e, p.new);
}

/// The admin only: the guardian has no veto over its own replacement.
pub(crate) fn cancel_guardian(e: &Env) {
    require_admin(e);
    let p: PendingGuardian = proposal(e, &DataKey::PendingGuardian);
    e.storage().instance().remove(&DataKey::PendingGuardian);
    GuardianProposalCancelled { new: p.new }.publish(e);
}

fn set_guardian(e: &Env, new: Option<Address>) {
    let mut cfg = config(e);
    cfg.guardian = new.clone();
    set_config(e, &cfg);
    GuardianSet { new }.publish(e);
}

// ------------------------------------------------------------------------------------------------ treasury

pub(crate) fn propose_treasury(e: &Env, new: Address) {
    let cfg = require_admin(e);
    let (eta, expires) = timelock(e, &cfg);
    e.storage().instance().set(&DataKey::PendingTreasury, &PendingTreasury { addr: new.clone(), eta, expires });
    TreasuryProposed { new, eta, expires }.publish(e);
}

pub(crate) fn apply_treasury(e: &Env) {
    let p: PendingTreasury = proposal(e, &DataKey::PendingTreasury);
    check_window(e, p.eta, p.expires);
    e.storage().instance().remove(&DataKey::PendingTreasury);
    let mut cfg = config(e);
    cfg.treasury = p.addr.clone();
    set_config(e, &cfg);
    TreasurySet { new: p.addr }.publish(e);
}

pub(crate) fn cancel_treasury(e: &Env, caller: Address) {
    require_admin_or_guardian(e, &caller);
    let p: PendingTreasury = proposal(e, &DataKey::PendingTreasury);
    e.storage().instance().remove(&DataKey::PendingTreasury);
    TreasuryProposalCancelled { new: p.addr, by: caller }.publish(e);
}

// ------------------------------------------------------------------------------------------------ future launches

pub(crate) fn set_launch_fee(e: &Env, amount: i128) {
    let mut cfg = require_admin(e);
    if !launch_fee_ok(amount) {
        panic_with_error!(e, Error::InvalidConfig);
    }
    cfg.launch_fee = amount;
    set_config(e, &cfg);
    LaunchFeeSet { launch_fee: amount }.publish(e);
}

pub(crate) fn set_fees(
    e: &Env,
    fee_bps: u32,
    protocol_share_bps: u32,
    max_creator_fee_bps: u32,
    snipe_schedule: Vec<u32>,
    snipe_step_secs: u32,
) {
    let mut cfg = require_admin(e);
    cfg.fee_bps = fee_bps;
    cfg.protocol_share_bps = protocol_share_bps;
    cfg.max_creator_fee_bps = max_creator_fee_bps;
    cfg.snipe_schedule = snipe_schedule;
    cfg.snipe_step_secs = snipe_step_secs;
    validate_fees(e, &cfg);
    save_and_publish(e, cfg);
}

pub(crate) fn set_launches_enabled(e: &Env, enabled: bool) {
    let mut cfg = require_admin(e);
    cfg.launches_enabled = enabled;
    save_and_publish(e, cfg);
}

pub(crate) fn set_whitelist_enabled(e: &Env, enabled: bool) {
    let mut cfg = require_admin(e);
    cfg.whitelist_enabled = enabled;
    save_and_publish(e, cfg);
}

pub(crate) fn set_whitelisted(e: &Env, account: Address, whitelisted: bool) {
    require_admin(e);
    let key = DataKey::Whitelisted(account.clone());
    if whitelisted {
        e.storage().persistent().set(&key, &true);
        crate::storage::bump(e, &key);
    } else {
        e.storage().persistent().remove(&key);
    }
    WhitelistSet { account, whitelisted }.publish(e);
}

/// Economics and venue rules for launches quoted in `asset`, which must be a Stellar Asset Contract (F17): a SAC
/// moves exactly what it is asked to, so every booked amount is what arrived (I-L11).
pub(crate) fn set_quote(
    e: &Env,
    asset: Address,
    phantom: i128,
    threshold: i128,
    enabled: bool,
    venues_allowed: Vec<u32>,
    fallback_venue: u32,
) {
    require_admin(e);
    if asset.executable() != Some(Executable::StellarAsset) {
        panic_with_error!(e, Error::QuoteNotSac);
    }
    let amounts_ok = phantom >= 0 && threshold >= 0 && (!enabled || (phantom > 0 && threshold > 0));
    if !amounts_ok || venues_allowed.len() > MAX_VENUES {
        panic_with_error!(e, Error::InvalidEconomics);
    }
    let table = venues(e);
    if items(&venues_allowed).any(|id| find_venue(&table, id).is_none()) {
        panic_with_error!(e, Error::UnknownVenue);
    }
    let fallback = find_venue(&table, fallback_venue).unwrap_or_else(|| panic_with_error!(e, Error::UnknownVenue));
    if fallback.kind != VenueKind::Soroswap {
        panic_with_error!(e, Error::InvalidEconomics);
    }
    let econ = QuoteEconomics { phantom, threshold, enabled, venues_allowed: venues_allowed.clone(), fallback_venue };
    let key = DataKey::Quote(asset.clone());
    e.storage().persistent().set(&key, &econ);
    crate::storage::bump(e, &key);
    QuoteSet { quote: asset, phantom, threshold, enabled, venues_allowed, fallback_venue }.publish(e);
}

fn save_and_publish(e: &Env, cfg: Config) {
    set_config(e, &cfg);
    ConfigSet { config: cfg }.publish(e);
}

// ------------------------------------------------------------------------------------------------ venues

/// Proposes a venue for the table and returns the id it will have. Ids are never reused.
pub(crate) fn propose_venue(e: &Env, kind: VenueKind, executor: Address, params: VenueParams) -> u32 {
    let cfg = require_admin(e);
    if !venue_params_ok(kind, &params) || venues(e).len() >= MAX_VENUES {
        panic_with_error!(e, Error::InvalidConfig);
    }
    let id: u32 = instance_get(e, &DataKey::NextVenueId).unwrap();
    e.storage().instance().set(&DataKey::NextVenueId, &(id + 1));
    let (eta, expires) = timelock(e, &cfg);
    let p = PendingVenue { id, kind, executor: executor.clone(), params, eta, expires };
    e.storage().instance().set(&DataKey::PendingVenue(id), &p);
    VenueProposed { id, kind, executor, params, eta, expires }.publish(e);
    id
}

/// Anyone, inside the window. The venue joins the table disabled.
pub(crate) fn apply_venue(e: &Env, id: u32) {
    let key = DataKey::PendingVenue(id);
    let p: PendingVenue = proposal(e, &key);
    check_window(e, p.eta, p.expires);
    let mut table = venues(e);
    if table.len() >= MAX_VENUES {
        panic_with_error!(e, Error::InvalidConfig);
    }
    table.push_back(VenueInfo { id, kind: p.kind, executor: p.executor.clone(), params: p.params, enabled: false });
    set_venues(e, &table);
    e.storage().instance().remove(&key);
    VenueAdded { id, kind: p.kind, executor: p.executor, params: p.params }.publish(e);
}

pub(crate) fn cancel_venue(e: &Env, caller: Address, id: u32) {
    require_admin_or_guardian(e, &caller);
    let key = DataKey::PendingVenue(id);
    let _: PendingVenue = proposal(e, &key);
    e.storage().instance().remove(&key);
    VenueProposalCancelled { id, by: caller }.publish(e);
}

/// Future launches only: a launch keeps the venue and fallback it pinned.
pub(crate) fn set_venue_enabled(e: &Env, id: u32, enabled: bool) {
    require_admin(e);
    let mut table = venues(e);
    let i = items(&table).position(|v| v.id == id).unwrap_or_else(|| panic_with_error!(e, Error::UnknownVenue));
    let mut venue = table.get_unchecked(i as u32);
    venue.enabled = enabled;
    table.set(i as u32, venue);
    set_venues(e, &table);
    VenueEnabled { id, enabled }.publish(e);
}

// ------------------------------------------------------------------------------------------------ validation

/// The fee rules of v1 (S:contracts/launchpad/src/lib.rs:688-697), plus `1 ≤ snipe_step_secs ≤ 60`.
pub(crate) fn validate_fees(e: &Env, cfg: &Config) {
    let ok = cfg.fee_bps + cfg.max_creator_fee_bps < MAX_TOTAL_BPS
        && cfg.protocol_share_bps <= BPS
        && cfg.supply > 0
        && cfg.snipe_schedule.len() <= MAX_SCHEDULE
        && items(&cfg.snipe_schedule).all(|b| b <= BPS)
        && (1..=MAX_SNIPE_STEP_SECS).contains(&cfg.snipe_step_secs);
    if !ok {
        panic_with_error!(e, Error::InvalidConfig);
    }
}

pub(crate) fn launch_fee_ok(amount: i128) -> bool {
    (0..=MAX_LAUNCH_FEE).contains(&amount)
}

/// An Aquarius venue's fee tier is one the router offers (10, 30 or 100).
fn venue_params_ok(kind: VenueKind, params: &VenueParams) -> bool {
    kind != VenueKind::Aquarius || AQUARIUS_FEE_TIERS.contains(&params.fee_fraction)
}

/// The constructor's table (§3.4): 1 to 8 venues, at least one Soroswap venue (every quote's fallback is one), and
/// valid Aquarius tiers. Ids follow the table's order and every venue starts enabled.
pub(crate) fn initial_venues(e: &Env, init: &Vec<VenueInit>) -> Vec<VenueInfo> {
    let ok = !init.is_empty()
        && init.len() <= MAX_VENUES
        && items(init).any(|v| v.kind == VenueKind::Soroswap)
        && items(init).all(|v| venue_params_ok(v.kind, &v.params));
    if !ok {
        panic_with_error!(e, Error::InvalidConfig);
    }
    let mut table = Vec::new(e);
    for (id, v) in items(init).enumerate() {
        table.push_back(VenueInfo {
            id: id as u32,
            kind: v.kind,
            executor: v.executor,
            params: v.params,
            enabled: true,
        });
    }
    table
}
