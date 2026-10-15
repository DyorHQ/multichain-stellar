//! Collecting, expiry and the pull ledgers (§9.2), ported from M:contracts/src/moments/MomentCollect.sol.
//!
//! - **collect** is Monad's `_prepare` / `_book` / `_deliver` (MomentCollect.sol:124-172) without the graduation
//!   attempt (L3): `price·qty` USDC split creator / platform / reserve (20/5/75) into pull ledgers, editions minted to
//!   the collector, and coins promised at the bundle rate. The collect that completes the reserve is clamped so the
//!   reserve lands exactly on the threshold (I-M1): only `ceil(remaining·BPS/reserve_bps)` is pulled, never the
//!   excess, and only the editions it pays for are minted. The Moment then waits for the keeper (GraduationPending).
//! - **expire** follows MomentCollect.sol:192-214, tightened (A6, F15, V11): a Collecting Moment once its deadline has
//!   passed; a GraduationPending one never before its deadline, and then only `stuck_expiry` after a recorded failed
//!   graduation (`stuck_since ≠ 0`, which only `graduate` sets) or, with no recorded failure, `pending_backstop` after
//!   completion (I-M7, I-M8). The reserve goes `expiry_creator_bps` (70%) to the creator and the rest to the
//!   treasury; collectors keep their editions and get no refund, Monad's rule.
//! - **withdraw_*** pay a Moment's snapshotted beneficiary whatever it is owed; anyone may call them.

use crate::events::{Collected, Completed, Expired, Withdrawn};
use crate::storage::{self, Ledger, Moment, State};
use crate::{Error, MomentsV2, MomentsV2Args, MomentsV2Client, MAX_BATCH};
use dyor_common::{mul_div, mul_div_u256, mul_div_up, MomentNftClient, BPS};
use soroban_sdk::{contractimpl, contracttype, panic_with_error, symbol_short, token::TokenClient, Address, Env};

/// What a collect did: editions `first_rank .. first_rank + editions`, `gross` USDC pulled, `entitlement` coins
/// promised.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectResult {
    pub first_rank: u32,
    pub editions: u32,
    pub gross: i128,
    pub entitlement: i128,
}

/// A collect priced exactly as it would settle now.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectQuote {
    /// USDC pulled from the collector (after the terminal clamp).
    pub gross: i128,
    /// Editions minted: `qty`, or on the terminal collect only those the clamped gross pays for.
    pub editions: u32,
    pub entitlement: i128,
    pub reserve_in: i128,
    pub creator_in: i128,
    pub platform_in: i128,
    /// What the terminal clamp leaves in the collector's wallet: `price·qty − gross`.
    pub excess: i128,
    /// This collect completes the Moment.
    pub terminal: bool,
}

/// Prices `qty` editions of `m` against its ledger at `now` (MomentCollect.sol:124-147). Panics `NotCollecting`,
/// `WindowClosed` or `BadQuantity` as a collect would.
pub(crate) fn quote_collect(e: &Env, m: &Moment, l: &Ledger, qty: u32, now: u64) -> CollectQuote {
    if l.state != State::Collecting {
        panic_with_error!(e, Error::NotCollecting);
    }
    if now >= m.deadline {
        panic_with_error!(e, Error::WindowClosed);
    }
    if qty == 0 || qty > MAX_BATCH {
        panic_with_error!(e, Error::BadQuantity);
    }
    let r = m.reserve_bps as i128;
    let bps = BPS as i128;
    let requested = m.price * qty as i128;
    // > 0 while Collecting: the collect that reaches the threshold ends Collecting.
    let remaining = m.threshold - l.reserve;
    let (mut gross, mut editions, mut reserve_in) = (requested, qty, mul_div(requested, r, bps));
    let terminal = reserve_in >= remaining;
    if terminal {
        // The smallest gross whose reserve share lands exactly on the threshold:
        // gross = ceil(remaining·BPS/r) ⇒ floor(gross·r/BPS) == remaining.
        gross = mul_div_up(remaining, bps, r);
        reserve_in = mul_div(gross, r, bps);
        // The editions it pays for, at most qty since gross ≤ requested.
        editions = mul_div_up(gross, 1, m.price) as u32;
    }
    let platform_in = mul_div(gross, m.platform_bps as i128, bps);
    CollectQuote {
        gross,
        editions,
        // gross·rate_num can exceed i128 for extreme prices; the result can't.
        entitlement: mul_div_u256(e, gross, m.rate_num, m.rate_den),
        reserve_in,
        // The creator absorbs the split's rounding (at most 2 units).
        creator_in: gross - reserve_in - platform_in,
        platform_in,
        excess: requested - gross,
        terminal,
    }
}

#[contractimpl]
impl MomentsV2 {
    /// Collects `qty` editions (1 to 20) of `nft` for at most `max_total` USDC. The collector's auth covers the USDC
    /// pull. Returns the first edition number, the editions minted, the gross paid and the coins promised.
    pub fn collect(e: Env, collector: Address, nft: Address, qty: u32, max_total: i128) -> CollectResult {
        collector.require_auth();
        let cfg = storage::config(&e);
        let m = storage::moment(&e, &nft);
        let mut l = storage::ledger(&e, &nft);
        let now = e.ledger().timestamp();
        let q = quote_collect(&e, &m, &l, qty, now);
        if q.gross > max_total {
            panic_with_error!(&e, Error::MaxTotalExceeded);
        }

        // Pull exactly the accepted gross; a terminal collect's excess never leaves the collector (I-M1).
        TokenClient::new(&e, &cfg.usdc).transfer(&collector, e.current_contract_address(), &q.gross);

        l.reserve += q.reserve_in;
        l.creator_claimable += q.creator_in;
        l.platform_claimable += q.platform_in;
        l.total_gross += q.gross;
        l.collects += 1;
        l.editions += q.editions;
        l.entitlements += q.entitlement;
        if q.terminal {
            l.state = State::GraduationPending;
            l.completed_at = now;
        }
        storage::save_ledger(&e, &nft, &l, &cfg.ttl);
        let mut p = storage::position(&e, &nft, &collector);
        p.entitlement += q.entitlement;
        // §13: alive through the deadline and the collectors' two vesting periods.
        let vesting_end = m.deadline - now + 2 * cfg.durations.vest_period;
        storage::save_position(&e, &nft, &collector, &p, &cfg.ttl, vesting_end);

        let first_rank = MomentNftClient::new(&e, &nft).mint(&collector, &q.editions);

        Collected {
            nft: nft.clone(),
            collector,
            gross: q.gross,
            editions: q.editions,
            first_rank,
            entitlement: q.entitlement,
            reserve_in: q.reserve_in,
            creator_in: q.creator_in,
            platform_in: q.platform_in,
            excess: q.excess,
            reserve: l.reserve,
        }
        .publish(&e);
        if q.terminal {
            Completed { nft, reserve: l.reserve, total_gross: l.total_gross, completed_at: now }.publish(&e);
        }
        CollectResult { first_rank, editions: q.editions, gross: q.gross, entitlement: q.entitlement }
    }

    /// Previews `collect(…, nft, qty, …)` exactly as it would settle now.
    pub fn quote(e: Env, nft: Address, qty: u32) -> CollectQuote {
        let m = storage::moment(&e, &nft);
        quote_collect(&e, &m, &storage::ledger(&e, &nft), qty, e.ledger().timestamp())
    }

    /// Winds down a Moment that didn't graduate. Anyone; nothing goes to the caller. `NotExpirable` until the rules
    /// above allow it; `WrongState` once Graduated or Expired.
    pub fn expire(e: Env, nft: Address) {
        let cfg = storage::config(&e);
        let m = storage::moment(&e, &nft);
        let mut l = storage::ledger(&e, &nft);
        let now = e.ledger().timestamp();
        let d = &cfg.durations;
        let backstop = match l.state {
            State::Collecting if now >= m.deadline => false,
            State::GraduationPending if now >= m.deadline => {
                if l.stuck_since != 0 && now >= l.stuck_since + d.stuck_expiry {
                    false
                } else if now >= l.completed_at + d.pending_backstop {
                    true
                } else {
                    panic_with_error!(&e, Error::NotExpirable)
                }
            }
            State::Collecting | State::GraduationPending => panic_with_error!(&e, Error::NotExpirable),
            State::Graduated | State::Expired => panic_with_error!(&e, Error::WrongState),
        };

        let reserve = l.reserve;
        let creator_share = mul_div(reserve, m.expiry_creator_bps as i128, BPS as i128);
        let treasury_share = reserve - creator_share;
        l.reserve = 0;
        l.creator_claimable += creator_share;
        l.treasury_claimable += treasury_share;
        l.state = State::Expired;
        l.ended_at = now;
        storage::save_ledger(&e, &nft, &l, &cfg.ttl);
        // Fixes the edition size; editions stay with their collectors.
        MomentNftClient::new(&e, &nft).close();
        Expired { nft, reserve, creator_share, treasury_share, backstop }.publish(&e);
    }

    /// Pays the Moment's creator its USDC: its share of every collect, and of the reserve if the Moment expired.
    pub fn withdraw_creator(e: Env, nft: Address) -> i128 {
        withdraw(&e, nft, Role::Creator)
    }

    /// Pays the Moment's snapshotted platform its share of every collect.
    pub fn withdraw_platform(e: Env, nft: Address) -> i128 {
        withdraw(&e, nft, Role::Platform)
    }

    /// Pays the Moment's snapshotted treasury: its share of an expired reserve, and any USDC graduation returned.
    pub fn withdraw_treasury(e: Env, nft: Address) -> i128 {
        withdraw(&e, nft, Role::Treasury)
    }
}

/// A beneficiary of a Moment's USDC.
#[derive(Clone, Copy)]
enum Role {
    Creator,
    Platform,
    Treasury,
}

/// Pays `role`'s whole claimable balance to the beneficiary the Moment snapshotted for it at publish.
fn withdraw(e: &Env, nft: Address, role: Role) -> i128 {
    let cfg = storage::config(e);
    let m = storage::moment(e, &nft);
    let mut l = storage::ledger(e, &nft);
    let (to, owed, name) = match role {
        Role::Creator => (m.creator, &mut l.creator_claimable, symbol_short!("creator")),
        Role::Platform => (m.platform, &mut l.platform_claimable, symbol_short!("platform")),
        Role::Treasury => (m.treasury, &mut l.treasury_claimable, symbol_short!("treasury")),
    };
    let amount = core::mem::take(owed);
    if amount == 0 {
        panic_with_error!(e, Error::NothingToWithdraw);
    }
    storage::save_ledger(e, &nft, &l, &cfg.ttl);
    TokenClient::new(e, &cfg.usdc).transfer(&e.current_contract_address(), to.clone(), &amount);
    Withdrawn { nft, role: name, to, amount }.publish(e);
    amount
}
