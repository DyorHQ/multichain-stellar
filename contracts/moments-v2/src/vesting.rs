//! Vesting claims and the supply identity (§9.2, I-M3, I-M4), ported from M:contracts/src/moments/MomentVesting.sol
//! with the period from the durations (`vest_period`: 30 d; 10 min on testnet-qa).
//!
//! - Collect promises a collector coins (`Position.entitlement`); nothing is minted before graduation. From
//!   `graduated_at`, a collector may claim 60% of it, 80% after one period and all of it after two (:108-116).
//! - The creator's allocation (`S·creator_alloc_bps/BPS`) vests 20% at graduation and 16% more per period, all of it
//!   after five periods (:118-125).
//! - `claim` mints exactly the vested, unclaimed part to the account with `coin.mint`: moments-v2 is every coin's
//!   minter. Claimed amounts only grow and never exceed what has vested (I-M4).
//! - The coin's cap counts coins in circulation, and the harvest burns the coin side, so the cap alone doesn't bound
//!   lifetime mints. The ledger does: every claim checks `minted_by_vesting ≤ alloc + Σ entitlements`
//!   (`SupplyInvariant`), so the coins ever minted stay within `pool_coins + alloc + Σ entitlements == S` (I-M3).

use crate::events::VestingClaimed;
use crate::graduation::pool_coins;
use crate::storage::{self, Config, Ledger, Moment, Position, State};
use crate::{Error, MomentsV2, MomentsV2Args, MomentsV2Client, MAX_CLAIM_IDS, SUPPLY};
use dyor_common::{mul_div, mul_div_u256, MomentCoinClient, BPS};
use soroban_sdk::{contractimpl, contracttype, panic_with_error, Address, Env, Vec};

/// A collector's vested share after 0, 1 and 2 or more periods.
pub const COLLECTOR_VESTED_BPS: [u32; 3] = [6_000, 8_000, 10_000];
/// The creator's allocation vests `CREATOR_BASE_BPS` at graduation and `CREATOR_STEP_BPS` per period for
/// `CREATOR_PERIODS` periods.
pub const CREATOR_BASE_BPS: u32 = 2_000;
pub const CREATOR_STEP_BPS: u32 = 1_600;
pub const CREATOR_PERIODS: u64 = 5;

/// The supply picture of a Moment (MomentCollect.sol:284-301). `pool_coins` is exactly what graduation seeds, so
/// `pool_coins + creator_alloc + entitlements == S` by construction. `implied_pool` is what the current reserve would
/// seed at the bundle rate: before graduation it exceeds `pool_coins` only by the rounding of each collect, and it is
/// 0 once the reserve has left.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SupplyCheck {
    pub entitlements: i128,
    pub creator_alloc: i128,
    pub pool_coins: i128,
    pub implied_pool: i128,
    pub collects: u32,
    pub minted_by_vesting: i128,
}

/// The creator's coin allocation.
pub(crate) fn creator_allocation(m: &Moment) -> i128 {
    mul_div(SUPPLY, m.creator_alloc_bps as i128, BPS as i128)
}

/// A collector's vested share after `periods` whole periods.
pub fn collector_vested_bps(periods: u64) -> u32 {
    COLLECTOR_VESTED_BPS[periods.min(2) as usize]
}

/// The creator's vested share of its allocation after `periods` whole periods.
pub fn creator_vested_bps(periods: u64) -> u32 {
    CREATOR_BASE_BPS + CREATOR_STEP_BPS * periods.min(CREATOR_PERIODS) as u32
}

/// What `account` can claim now: `(collector_due, creator_due)`. The creator part is only the Moment's creator's.
pub(crate) fn due(m: &Moment, l: &Ledger, p: &Position, account: &Address, now: u64, vest_period: u64) -> (i128, i128) {
    let periods = (now - l.graduated_at) / vest_period;
    let bps = BPS as i128;
    let collector = mul_div(p.entitlement, collector_vested_bps(periods) as i128, bps) - p.claimed;
    let creator = if *account == m.creator {
        mul_div(creator_allocation(m), creator_vested_bps(periods) as i128, bps) - l.creator_claimed
    } else {
        0
    };
    (collector, creator)
}

/// Mints what `account` can claim of one graduated Moment now and books it. `(0, 0)` when nothing is due.
fn claim_one(e: &Env, cfg: &Config, m: &Moment, mut l: Ledger, account: &Address) -> (i128, i128) {
    let now = e.ledger().timestamp();
    let vest_period = cfg.durations.vest_period;
    let mut p = storage::position(e, &m.nft, account);
    let (collector_due, creator_due) = due(m, &l, &p, account, now, vest_period);
    let amount = collector_due + creator_due;
    if amount == 0 {
        return (0, 0);
    }
    if collector_due > 0 {
        p.claimed += collector_due;
        // §13: alive through the rest of the collectors' schedule.
        let rest = (l.graduated_at + 2 * vest_period).saturating_sub(now);
        storage::save_position(e, &m.nft, account, &p, &cfg.ttl, rest);
    }
    l.creator_claimed += creator_due;
    l.minted_by_vesting += amount;
    if l.minted_by_vesting > creator_allocation(m) + l.entitlements {
        panic_with_error!(e, Error::SupplyInvariant);
    }
    storage::save_ledger(e, &m.nft, &l, &cfg.ttl);
    MomentCoinClient::new(e, &m.coin).mint(account, &amount);
    VestingClaimed {
        nft: m.nft.clone(),
        account: account.clone(),
        collector_amount: collector_due,
        creator_amount: creator_due,
    }
    .publish(e);
    (collector_due, creator_due)
}

#[contractimpl]
impl MomentsV2 {
    /// Mints `account`'s vested, unclaimed coins of a graduated Moment to it: its collector tranche, plus the creator
    /// tranche when it is the creator. Returns `(collector_amount, creator_amount)`. `WrongState` before graduation,
    /// `NothingToClaim` when nothing is due.
    pub fn claim(e: Env, account: Address, nft: Address) -> (i128, i128) {
        account.require_auth();
        let cfg = storage::config(&e);
        let m = storage::moment(&e, &nft);
        let l = storage::ledger(&e, &nft);
        if l.state != State::Graduated {
            panic_with_error!(&e, Error::WrongState);
        }
        let claimed = claim_one(&e, &cfg, &m, l, &account);
        if claimed == (0, 0) {
            panic_with_error!(&e, Error::NothingToClaim);
        }
        claimed
    }

    /// Claims across up to 20 Moments in one call, skipping those with nothing due (unknown and ungraduated Moments
    /// included). Returns the coins minted in all. `TooManyIds` above 20; `NothingToClaim` when none was due.
    pub fn claim_all(e: Env, account: Address, nfts: Vec<Address>) -> i128 {
        account.require_auth();
        if nfts.len() > MAX_CLAIM_IDS {
            panic_with_error!(&e, Error::TooManyIds);
        }
        let cfg = storage::config(&e);
        let mut total = 0;
        for nft in nfts.iter() {
            let Some(m) = storage::try_moment(&e, &nft) else { continue };
            let l = storage::ledger(&e, &nft);
            if l.state == State::Graduated {
                let (collector, creator) = claim_one(&e, &cfg, &m, l, &account);
                total += collector + creator;
            }
        }
        if total == 0 {
            panic_with_error!(&e, Error::NothingToClaim);
        }
        total
    }

    /// What `account` could claim of `nft` now: `(collector_amount, creator_amount)`; `(0, 0)` before graduation.
    pub fn claimable(e: Env, nft: Address, account: Address) -> (i128, i128) {
        let m = storage::moment(&e, &nft);
        let l = storage::ledger(&e, &nft);
        if l.state != State::Graduated {
            return (0, 0);
        }
        let p = storage::position(&e, &nft, &account);
        due(&m, &l, &p, &account, e.ledger().timestamp(), storage::config(&e).durations.vest_period)
    }

    pub fn supply_check(e: Env, nft: Address) -> SupplyCheck {
        let m = storage::moment(&e, &nft);
        let l = storage::ledger(&e, &nft);
        SupplyCheck {
            entitlements: l.entitlements,
            creator_alloc: creator_allocation(&m),
            pool_coins: pool_coins(&m, &l),
            implied_pool: mul_div_u256(&e, l.reserve, m.rate_num, m.rate_den),
            collects: l.collects,
            minted_by_vesting: l.minted_by_vesting,
        }
    }
}
