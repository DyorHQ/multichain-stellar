//! DyorHQ lp-locker (DESIGN-stellar-contracts-v2 §8): holds every graduated LP position forever and harvests only its
//! fee growth.
//!
//! - **Owners** (launchpad-v2 and moments-v2, by the ids the deploy script precomputes) are fixed at construction with
//!   the Soroswap factory, the Aquarius router (if any) and `harvest_interval`. There is no admin, no setter, no
//!   upgrade and no path that moves principal LP anywhere.
//! - **register** (owners only) records a position whose LP the owner has already sent, with its principal in √k
//!   units: `isqrt(r_b·r_q)·lp/total`, the position's share of the pool's √k.
//! - **harvest** (anyone, the keeper) takes part of the fee growth above the principal, at most once per
//!   `harvest_interval` and at most `MAX_HARVEST_ROUND_BPS` (0.5%) of the position per round, withdraws that much LP
//!   from the venue and pays both sides out by the owner's `harvest_payees` (§8.2, [`harvest`]). Swaps never lower √k,
//!   so trading can't fake growth, and there is no price guard to block (L12, §8.3).
//! - **Compounding** (F7): of every round, `take` is paid out and `take·(BPS − hb)/hb` joins the principal, so
//!   compounded : harvested = (BPS − hb) : hb in every round, also when the cap binds. Launches use `hb = BPS` (all
//!   growth is split, the principal stays put); Moments 6,667, which is 3,333 : 6,667 (V3).
//! - **Payouts** go to each side's payee list, the last payee taking the remainder. A launch token on the base side
//!   (`notify`) first excludes the current treasury (V2), then receives its share with `notify_reward`; other payees
//!   are paid with `try_transfer`, and what can't be delivered (no trustline) is owed until `withdraw_owed`. An empty
//!   list burns that side (Moments' coin side).
//!
//! Errors are namespaced `ERR_BASE + 6·100 + n` (V10). Persistent entries are bumped when a call writes them; the
//! instance and code are the keeper's (DECISIONS #10).
#![no_std]

mod harvest;

use dyor_common::aquarius::AQUARIUS_VENUE_OK;
use dyor_common::{
    bump_persistent, harvest_interval_ok, mul_div_up_u256, PositionRef, TtlPolicy, VenueKind, BPS, TAG_LP_LOCKER,
    TESTNET_TTL_POLICY,
};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, token::TokenClient, Address, Env, Vec,
};

/// Bumps for `Position`, `Tracked` and `Owed` (§13): the testnet policy. Mainnet's is deferred (§23.2).
const TTL: TtlPolicy = TESTNET_TTL_POLICY;

#[contracttype]
#[derive(Clone)]
pub(crate) enum DataKey {
    // instance (§8.1)
    Owners,
    SoroswapFactory,
    AquariusRouter,
    HarvestInterval,
    // persistent
    Position(Address),
    Tracked(Address),
    Owed(Address, Address),
}

/// A locked position, keyed by its pool. `base` is the launch token or the Moment coin, `quote` the quote asset.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Position {
    pub owner: Address,
    pub kind: VenueKind,
    pub lp_token: Address,
    pub base: Address,
    pub quote: Address,
    pub reference: PositionRef,
    /// LP held for this position.
    pub lp: i128,
    /// √k units; it only grows. 0 for kinds the locker doesn't value (`HoldOnly`, `QaFail`).
    pub principal: i128,
    pub harvest_bps: u32,
    pub last_harvest: u64,
}

/// The local codes of §8.2 in this contract's namespace: on chain `ERR_BASE + 6·100 + n` (§4, V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `register` from an address outside the owners fixed at construction.
    NotOwner = 10_601,
    /// The pool already has a position.
    PositionExists = 10_602,
    /// The locker doesn't hold `lp` more of the LP token than it already tracks (or `lp` isn't positive, or the LP
    /// token has no balance to read).
    LpNotReceived = 10_603,
    /// No position for this pool.
    UnknownPosition = 10_604,
    /// The position's kind isn't harvested: `HoldOnly`, `QaFail`, or Aquarius without the venue gate or a router.
    UnsupportedKind = 10_605,
    /// Less than `harvest_interval` since the last harvest (or the registration).
    TooSoon = 10_606,
    /// No fee growth above the principal, or too little to withdraw.
    NothingToHarvest = 10_607,
    /// `withdraw_owed` with nothing owed.
    NothingOwed = 10_608,
    /// `harvest_bps` is 0 or above `BPS`.
    InvalidHarvestBps = 10_609,
}
dyor_common::assert_err_codes!(
    TAG_LP_LOCKER;
    Error::NotOwner = 1,
    Error::PositionExists = 2,
    Error::LpNotReceived = 3,
    Error::UnknownPosition = 4,
    Error::UnsupportedKind = 5,
    Error::TooSoon = 6,
    Error::NothingToHarvest = 7,
    Error::NothingOwed = 8,
    Error::InvalidHarvestBps = 9,
);

// ------------------------------------------------------------------------------------------------ events (§20.5)

/// A position was registered; `principal` is its √k value at registration.
#[contractevent(topics = ["lock_reg"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Registered {
    #[topic]
    pub pool: Address,
    #[topic]
    pub owner: Address,
    pub kind: VenueKind,
    pub lp_token: Address,
    pub lp: i128,
    pub base: Address,
    pub quote: Address,
    pub reference: PositionRef,
    pub harvest_bps: u32,
    pub principal: i128,
}

/// One harvest round: `lp_burned` LP withdrew `base_out` and `quote_out`; of the √k `growth`, `take` was harvested
/// and `compounded` joined the principal, which is now `principal`.
#[contractevent(topics = ["harvested"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Harvested {
    #[topic]
    pub pool: Address,
    pub lp_burned: i128,
    pub base_out: i128,
    pub quote_out: i128,
    pub growth: i128,
    pub take: i128,
    pub compounded: i128,
    pub principal: i128,
}

/// A payout to `to` failed (no trustline, for example); `amount` is owed, `owed` in all.
#[contractevent(topics = ["owed_credit"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwedCredited {
    #[topic]
    pub to: Address,
    #[topic]
    pub asset: Address,
    pub amount: i128,
    pub owed: i128,
}

#[contractevent(topics = ["owed_paid"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwedPaid {
    #[topic]
    pub to: Address,
    #[topic]
    pub asset: Address,
    pub amount: i128,
}

// ------------------------------------------------------------------------------------------------ the contract

#[contract]
pub struct LpLocker;

#[contractimpl]
impl LpLocker {
    /// `owners` are launchpad-v2 and moments-v2; `aquarius_router` is `None` where Aquarius is no venue.
    /// `harvest_interval` must lie in [`MIN_DURATION`, `MAX_HARVEST_INTERVAL`] (60 s to 1 day; 3,600 in production,
    /// 60 on testnet-qa), and both owners require it to equal their own `durations.harvest_interval` (F6).
    ///
    /// [`MIN_DURATION`]: dyor_common::MIN_DURATION
    /// [`MAX_HARVEST_INTERVAL`]: dyor_common::MAX_HARVEST_INTERVAL
    pub fn __constructor(
        e: Env,
        owners: Vec<Address>,
        soroswap_factory: Address,
        aquarius_router: Option<Address>,
        harvest_interval: u64,
    ) {
        assert!(!owners.is_empty(), "the locker needs an owner");
        assert!(harvest_interval_ok(harvest_interval), "harvest_interval outside 60 s to 1 day");
        let s = e.storage().instance();
        s.set(&DataKey::Owners, &owners);
        s.set(&DataKey::SoroswapFactory, &soroswap_factory);
        s.set(&DataKey::AquariusRouter, &aquarius_router);
        s.set(&DataKey::HarvestInterval, &harvest_interval);
    }

    /// Records the position of `pool`, whose `lp` LP the owner has already sent. Owners only, with their auth.
    /// `harvest_bps` is the share of each round's growth that is paid out: 10,000 for launches, 6,667 for Moments.
    #[allow(clippy::too_many_arguments)]
    pub fn register(
        e: Env,
        owner: Address,
        pool: Address,
        kind: VenueKind,
        lp_token: Address,
        lp: i128,
        base: Address,
        quote: Address,
        reference: PositionRef,
        harvest_bps: u32,
    ) -> Result<(), Error> {
        if !owners(&e).contains(&owner) {
            return Err(Error::NotOwner);
        }
        owner.require_auth();
        if harvest_bps == 0 || harvest_bps > BPS {
            return Err(Error::InvalidHarvestBps);
        }
        let key = DataKey::Position(pool.clone());
        if e.storage().persistent().has(&key) {
            return Err(Error::PositionExists);
        }
        // A failing balance call (a bogus LP token, as qa-exec-fail's mode 2 returns) is a refusal, never a trap.
        let tracked = tracked(&e, &lp_token);
        let held = match TokenClient::new(&e, &lp_token).try_balance(&e.current_contract_address()) {
            Ok(Ok(held)) => held,
            _ => return Err(Error::LpNotReceived),
        };
        if lp <= 0 || held - tracked < lp {
            return Err(Error::LpNotReceived);
        }

        let mut pos = Position {
            owner,
            kind,
            lp_token,
            base,
            quote,
            reference,
            lp,
            principal: 0,
            harvest_bps,
            last_harvest: e.ledger().timestamp(),
        };
        if harvest::valued(kind) {
            pos.principal = harvest::read_pool(&e, &pos, &pool).value(&e, lp);
        }
        set_tracked(&e, &pos.lp_token, tracked + lp);
        e.storage().persistent().set(&key, &pos);
        bump_persistent(&e, &key, &TTL);

        Registered {
            pool,
            owner: pos.owner,
            kind,
            lp_token: pos.lp_token,
            lp,
            base: pos.base,
            quote: pos.quote,
            reference: pos.reference,
            harvest_bps,
            principal: pos.principal,
        }
        .publish(&e);
        Ok(())
    }

    /// Harvests one round of `pool`'s fee growth and pays it out. Anyone may call it, once per `harvest_interval`.
    /// Returns `(base_out, quote_out)`, what the venue paid for the LP withdrawn.
    pub fn harvest(e: Env, pool: Address) -> Result<(i128, i128), Error> {
        let key = DataKey::Position(pool.clone());
        let mut pos = position(&e, &key)?;
        let router = aquarius_router(&e);
        if !harvest::harvestable_kind(pos.kind, AQUARIUS_VENUE_OK, router.is_some()) {
            return Err(Error::UnsupportedKind);
        }
        let now = e.ledger().timestamp();
        if now < next_at(&e, &pos) {
            return Err(Error::TooSoon);
        }
        let state = harvest::read_pool(&e, &pos, &pool);
        let round = state.round(&e, &pos);
        if round.lp_to_burn == 0 {
            return Err(Error::NothingToHarvest);
        }

        let (base_out, quote_out) = state.withdraw(&e, &pos, &pool, router, round.lp_to_burn);

        // F7: what joins the principal is proportional to what was taken; the `min` keeps the principal at or below
        // what the position still holds after rounding (I-K1).
        let hb = pos.harvest_bps as i128;
        let ratchet = mul_div_up_u256(&e, round.take, BPS as i128 - hb, hb);
        let principal = (pos.principal + ratchet).min(round.current - round.take);
        let compounded = principal - pos.principal;
        pos.lp -= round.lp_to_burn;
        pos.principal = principal;
        pos.last_harvest = now;
        set_tracked(&e, &pos.lp_token, tracked(&e, &pos.lp_token) - round.lp_to_burn);
        e.storage().persistent().set(&key, &pos);
        bump_persistent(&e, &key, &TTL);

        harvest::pay(&e, &pos, base_out, quote_out);

        Harvested {
            pool,
            lp_burned: round.lp_to_burn,
            base_out,
            quote_out,
            growth: round.growth,
            take: round.take,
            compounded,
            principal,
        }
        .publish(&e);
        Ok((base_out, quote_out))
    }

    /// Pays `to` what a failed harvest payout left owed to it in `asset`. Anyone may call it; the payment always
    /// goes to `to`.
    pub fn withdraw_owed(e: Env, to: Address, asset: Address) -> Result<i128, Error> {
        let key = DataKey::Owed(to.clone(), asset.clone());
        let amount: i128 = e.storage().persistent().get(&key).unwrap_or(0);
        if amount == 0 {
            return Err(Error::NothingOwed);
        }
        e.storage().persistent().remove(&key);
        TokenClient::new(&e, &asset).transfer(&e.current_contract_address(), &to, &amount);
        OwedPaid { to, asset, amount }.publish(&e);
        Ok(amount)
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn position(e: Env, pool: Address) -> Option<Position> {
        e.storage().persistent().get(&DataKey::Position(pool))
    }

    /// What a harvest would do now: `(growth, lp_to_burn, est_base, est_quote, next_at)`. `growth` is the √k value
    /// above the principal (0 when there is none) and `lp_to_burn` 0 when nothing can be harvested; the estimates
    /// use the reserves, so the venue pays at least that much. `next_at` is the first time a harvest is allowed.
    pub fn harvestable(e: Env, pool: Address) -> Result<(i128, i128, i128, i128, u64), Error> {
        let pos = position(&e, &DataKey::Position(pool.clone()))?;
        if !harvest::harvestable_kind(pos.kind, AQUARIUS_VENUE_OK, aquarius_router(&e).is_some()) {
            return Err(Error::UnsupportedKind);
        }
        let r = harvest::read_pool(&e, &pos, &pool).round(&e, &pos);
        Ok((r.growth, r.lp_to_burn, r.est_base, r.est_quote, next_at(&e, &pos)))
    }

    pub fn owed(e: Env, to: Address, asset: Address) -> i128 {
        e.storage().persistent().get(&DataKey::Owed(to, asset)).unwrap_or(0)
    }

    /// LP of `lp_token` held for positions.
    pub fn tracked(e: Env, lp_token: Address) -> i128 {
        tracked(&e, &lp_token)
    }

    /// Seconds between two harvests of one position.
    pub fn harvest_interval(e: Env) -> u64 {
        harvest_interval(&e)
    }

    pub fn owners(e: Env) -> Vec<Address> {
        owners(&e)
    }

    /// The Soroswap factory of this deployment (§8.1). The owners check a pool against it before they register it
    /// (§5.5, §9.3); the locker trusts its owners and calls the pair directly.
    pub fn soroswap_factory(e: Env) -> Address {
        e.storage().instance().get(&DataKey::SoroswapFactory).unwrap()
    }

    pub fn aquarius_router(e: Env) -> Option<Address> {
        aquarius_router(&e)
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_LP_LOCKER
    }
}

fn owners(e: &Env) -> Vec<Address> {
    e.storage().instance().get(&DataKey::Owners).unwrap()
}

fn aquarius_router(e: &Env) -> Option<Address> {
    e.storage().instance().get(&DataKey::AquariusRouter).unwrap()
}

fn harvest_interval(e: &Env) -> u64 {
    e.storage().instance().get(&DataKey::HarvestInterval).unwrap()
}

fn position(e: &Env, key: &DataKey) -> Result<Position, Error> {
    e.storage().persistent().get(key).ok_or(Error::UnknownPosition)
}

fn next_at(e: &Env, pos: &Position) -> u64 {
    pos.last_harvest.saturating_add(harvest_interval(e))
}

fn tracked(e: &Env, lp_token: &Address) -> i128 {
    e.storage().persistent().get(&DataKey::Tracked(lp_token.clone())).unwrap_or(0)
}

fn set_tracked(e: &Env, lp_token: &Address, amount: i128) {
    let key = DataKey::Tracked(lp_token.clone());
    e.storage().persistent().set(&key, &amount);
    bump_persistent(e, &key, &TTL);
}

/// Records `amount` of `asset` as owed to `to`, after a payout to it failed.
pub(crate) fn credit_owed(e: &Env, to: &Address, asset: &Address, amount: i128) {
    let key = DataKey::Owed(to.clone(), asset.clone());
    let owed = e.storage().persistent().get::<_, i128>(&key).unwrap_or(0) + amount;
    e.storage().persistent().set(&key, &owed);
    bump_persistent(e, &key, &TTL);
    OwedCredited { to: to.clone(), asset: asset.clone(), amount, owed }.publish(e);
}

#[cfg(test)]
mod test;
