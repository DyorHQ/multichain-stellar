//! Graduation (DESIGN-stellar-contracts-v2 §5.5): one attempt per call on one venue, through `try_` into the venue's
//! executor.
//!
//! - **The attempt.** The pool gets the curve's real quote and the price-continuous token amount. The launchpad
//!   pre-authorizes exactly `transfer(this, executor, amount)` on both assets; the executor pulls them inside the
//!   `try_` frame, so a recoverable failure rolls every transfer back (I-L5) and is recorded with its namespaced
//!   origin and code (`grad_fail`, `Failed`, V10). The first recorded failure starts `stuck_since`; retries never
//!   move it, and only a graduation resets it.
//! - **The result checks** (A5, B12): both used amounts within 1 bp below what was sent and never above it, the
//!   launchpad's balance deltas equal to them, the liquidity at least the minimum and held by the locker, and for
//!   Soroswap the factory's pair as the pool and its LP token. A failed check panics with `GraduationInvalid`, which
//!   aborts the whole transaction: nothing of the attempt is committed, the keeper's retry fails the same way, and
//!   `mark_stuck` follows.
//! - **After success:** the pool is excluded from holder rewards in the same transaction (sharing on), the token
//!   unlocks, the launchpad's whole remaining balance is burned (L7), the unused quote dust is booked as protocol
//!   fees, and the locker registers the LP with `LAUNCH_HARVEST_BPS`.
//! - **The fallback** (F14): `graduate_fallback` attempts only the fallback venue, never the launch's own, and only
//!   from `stuck_since + fallback_delay`. A venue-locked launch also waits `locked_fallback` unless the admin allowed the
//!   fallback. A primary that exhausts the budget can't block it.

use crate::admin::require_admin;
use crate::curve;
use crate::events::{FallbackAllowed, Graduated, GraduationFailed, MarkedStuck};
use crate::storage::{
    config, load_curve, load_launch, save_curve, Config, Curve, Launch, LaunchStatus, Phase, VenueInfo,
};
use crate::{Error, LAUNCH_HARVEST_BPS};
use dyor_common::{
    grad_failure, isqrt_u128, mul_div, ExecutorClient, GradFailure, GraduateArgs, GraduateResult, GraduationOutcome,
    LaunchDurations, LaunchTokenV2Client, LockerClient, PositionRef, SoroswapFactoryClient, VenueKind, BPS,
    GRAD_DUST_BPS, SOROSWAP_MIN_LIQ,
};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{panic_with_error, token::TokenClient, vec, Address, Env, IntoVal, Symbol, Vec};

/// `graduate` (the launch's venue) and `graduate_fallback` (the fallback venue only).
pub(crate) fn graduate(e: &Env, token: &Address, fallback: bool) -> GraduationOutcome {
    let launch = load_launch(e, token);
    let mut curve = load_curve(e, token);
    require_completed(e, &curve);
    let cfg = config(e);
    let venue = if fallback {
        require_fallback_open(e, &cfg.durations, &launch, &curve);
        &launch.fallback
    } else {
        &launch.venue
    };
    attempt(e, &cfg, &launch, &mut curve, venue, fallback)
}

/// `mark_stuck`: once the grace has passed without a graduation, the launch is stuck from `completed_at + grace`.
/// It covers the failures no `try_` can record (budget exhaustion, a `GraduationInvalid` abort).
pub(crate) fn mark_stuck(e: &Env, token: &Address) {
    let mut curve = load_curve(e, token);
    require_completed(e, &curve);
    if curve.stuck_since != 0 {
        panic_with_error!(e, Error::AlreadyStuck);
    }
    let at = curve.completed_at + config(e).durations.grace;
    if e.ledger().timestamp() < at {
        panic_with_error!(e, Error::GraceNotElapsed);
    }
    curve.stuck_since = at;
    save_curve(e, token, &curve);
    MarkedStuck { token: token.clone(), stuck_since: at }.publish(e);
}

/// `allow_fallback`: the admin lets a venue-locked launch fall back without waiting `locked_fallback`.
pub(crate) fn allow_fallback(e: &Env, token: &Address) {
    require_admin(e);
    let mut curve = load_curve(e, token);
    curve.fallback_allowed = true;
    save_curve(e, token, &curve);
    FallbackAllowed { token: token.clone() }.publish(e);
}

pub(crate) fn status(e: &Env, token: &Address) -> LaunchStatus {
    let launch = load_launch(e, token);
    let curve = load_curve(e, token);
    let d = config(e).durations;
    let completed = curve.phase == Phase::Completed;
    let stuck = completed && curve.stuck_since != 0;
    let after_stuck = |secs: u64| if stuck { curve.stuck_since + secs } else { 0 };
    LaunchStatus {
        phase: curve.phase,
        completed_at: curve.completed_at,
        stuck_since: curve.stuck_since,
        mark_stuck_at: if completed { curve.completed_at + d.grace } else { 0 },
        fallback_at: if stuck { fallback_at(&d, &launch, &curve) } else { 0 },
        rescue_admin_at: after_stuck(d.rescue_admin),
        rescue_public_at: after_stuck(d.rescue_public),
        refund_quote: curve.refund_quote,
        refund_supply: curve.refund_supply,
    }
}

/// What graduating now would put in the pool and burn: `(pool_tokens, pool_quote, burn)`. Zeros once graduated or
/// rescued.
pub(crate) fn preview(e: &Env, token: &Address) -> (i128, i128, i128) {
    let curve = load_curve(e, token);
    if curve.phase != Phase::Curve && curve.phase != Phase::Completed {
        return (0, 0, 0);
    }
    let pool_tokens = curve::pool_tokens(curve.real_quote, curve.token_reserve, curve.quote_reserve);
    let held = TokenClient::new(e, token).balance(&e.current_contract_address());
    (pool_tokens, curve.real_quote, (held - pool_tokens).max(0))
}

/// Refuses a launch that isn't waiting for graduation.
pub(crate) fn require_completed(e: &Env, curve: &Curve) {
    match curve.phase {
        Phase::Curve => panic_with_error!(e, Error::NotCompleted),
        Phase::Completed => {}
        Phase::Graduated => panic_with_error!(e, Error::AlreadyGraduated),
        Phase::Rescued => panic_with_error!(e, Error::WrongPhase),
    }
}

/// When `graduate_fallback` opens (0 while not stuck): `stuck_since + fallback_delay`, and for a venue-locked launch
/// not yet allowed, no earlier than `stuck_since + locked_fallback` (I-L12).
pub(crate) fn fallback_at(d: &LaunchDurations, launch: &Launch, curve: &Curve) -> u64 {
    if curve.stuck_since == 0 {
        return 0;
    }
    let at = curve.stuck_since + d.fallback_delay;
    if launch.venue_locked && !curve.fallback_allowed {
        at.max(curve.stuck_since + d.locked_fallback)
    } else {
        at
    }
}

fn require_fallback_open(e: &Env, d: &LaunchDurations, launch: &Launch, curve: &Curve) {
    if curve.stuck_since == 0 {
        panic_with_error!(e, Error::NotStuck);
    }
    let now = e.ledger().timestamp();
    if now < curve.stuck_since + d.fallback_delay {
        panic_with_error!(e, Error::FallbackTooEarly);
    }
    if launch.venue_locked && !curve.fallback_allowed && now < curve.stuck_since + d.locked_fallback {
        panic_with_error!(e, Error::FallbackNotAllowed);
    }
}

// ------------------------------------------------------------------------------------------------ the attempt

fn attempt(
    e: &Env,
    cfg: &Config,
    launch: &Launch,
    curve: &mut Curve,
    v: &VenueInfo,
    fallback: bool,
) -> GraduationOutcome {
    let this = e.current_contract_address();
    let token = TokenClient::new(e, &launch.token);
    let quote = TokenClient::new(e, &launch.quote);
    let pool_quote = curve.real_quote;
    let pool_tokens = curve::pool_tokens(curve.real_quote, curve.token_reserve, curve.quote_reserve);
    let args = GraduateArgs {
        source: this.clone(),
        token: launch.token.clone(),
        quote: launch.quote.clone(),
        token_amount: pool_tokens,
        quote_amount: pool_quote,
        lp_to: cfg.locker.clone(),
        params: v.params,
        min_liquidity: min_liquidity(v.kind, pool_tokens, pool_quote),
    };
    let (t0, q0) = (token.balance(&this), quote.balance(&this));
    // Exactly the executor's two pulls (§2). They run inside the try_ frame, so a failure rolls them back.
    e.authorize_as_current_contract(vec![
        e,
        transfer_entry(e, &launch.token, &this, &v.executor, pool_tokens),
        transfer_entry(e, &launch.quote, &this, &v.executor, pool_quote),
    ]);
    match ExecutorClient::new(e, &v.executor).try_graduate(&args) {
        Ok(Ok(r)) => {
            let deltas = (t0 - token.balance(&this), q0 - quote.balance(&this));
            if !result_ok(e, cfg, v, &args, &r, deltas) {
                panic_with_error!(e, Error::GraduationInvalid);
            }
            settle(e, cfg, launch, curve, v, r, fallback)
        }
        // A success whose result doesn't even decode is as invalid as a wrong one.
        Ok(Err(_)) => panic_with_error!(e, Error::GraduationInvalid),
        Err(err) => record_failure(e, &cfg.durations, launch, curve, v, grad_failure(err)),
    }
}

/// The result checks of §5.5. `deltas` are the drops in the launchpad's token and quote balances over the attempt.
fn result_ok(
    e: &Env,
    cfg: &Config,
    v: &VenueInfo,
    a: &GraduateArgs,
    r: &GraduateResult,
    (token_delta, quote_delta): (i128, i128),
) -> bool {
    let within_dust = |used: i128, amount: i128| {
        amount - mul_div(amount, GRAD_DUST_BPS as i128, BPS as i128) <= used && used <= amount
    };
    within_dust(r.token_used, a.token_amount)
        && within_dust(r.quote_used, a.quote_amount)
        && token_delta == r.token_used
        && quote_delta == r.quote_used
        && r.liquidity >= a.min_liquidity
        && balance_of(e, &r.lp_token, &a.lp_to).is_some_and(|held| held >= r.liquidity)
        && (v.kind != VenueKind::Soroswap || (r.lp_token == r.pool && soroswap_pair(e, cfg, a) == Some(r.pool.clone())))
}

/// The post-steps of a checked success.
fn settle(
    e: &Env,
    cfg: &Config,
    launch: &Launch,
    curve: &mut Curve,
    v: &VenueInfo,
    r: GraduateResult,
    fallback: bool,
) -> GraduationOutcome {
    let this = e.current_contract_address();
    let ops = LaunchTokenV2Client::new(e, &launch.token);
    // In this transaction, so the pool never shares a later-ledger release.
    if launch.holder_sharing {
        ops.exclude(&r.pool);
    }
    ops.unlock();
    // L7: the excess supply, plus anything sent to the launchpad.
    let token = TokenClient::new(e, &launch.token);
    let burned = token.balance(&this);
    if burned > 0 {
        token.burn(&this, &burned);
    }
    LockerClient::new(e, &cfg.locker).register(
        &this,
        &r.pool,
        &v.kind,
        &r.lp_token,
        &r.liquidity,
        &launch.token,
        &launch.quote,
        &PositionRef::Launch(launch.token.clone()),
        &LAUNCH_HARVEST_BPS,
    );
    // At most 1 bp of the pool's quote came back unused.
    curve.protocol_fees += curve.real_quote - r.quote_used;
    curve.phase = Phase::Graduated;
    curve.stuck_since = 0;
    curve.real_quote = 0;
    curve.token_reserve = 0;
    curve.pool = Some(r.pool.clone());
    curve.graduated_venue = Some(v.id);
    curve.burned = burned;
    save_curve(e, &launch.token, curve);
    Graduated {
        token: launch.token.clone(),
        venue: v.id,
        pool: r.pool.clone(),
        pool_tokens: r.token_used,
        pool_quote: r.quote_used,
        liquidity: r.liquidity,
        burned,
        fallback,
    }
    .publish(e);
    GraduationOutcome::Graduated(r.pool)
}

/// A recoverable failure: nothing moved (the frame rolled back), `stuck_since` starts on the first one.
fn record_failure(
    e: &Env,
    d: &LaunchDurations,
    launch: &Launch,
    curve: &mut Curve,
    v: &VenueInfo,
    f: GradFailure,
) -> GraduationOutcome {
    if curve.stuck_since == 0 {
        curve.stuck_since = e.ledger().timestamp();
        save_curve(e, &launch.token, curve);
    }
    GraduationFailed {
        token: launch.token.clone(),
        venue: v.id,
        origin: f.origin,
        code: f.code,
        stuck_since: curve.stuck_since,
        fallback_at: fallback_at(d, launch, curve),
    }
    .publish(e);
    GraduationOutcome::Failed(f)
}

/// Soroswap mints `isqrt(x·y) − SOROSWAP_MIN_LIQ` LP for a fresh pair; 1 below that absorbs rounding. Other kinds
/// only need some LP.
fn min_liquidity(kind: VenueKind, pool_tokens: i128, pool_quote: i128) -> i128 {
    if kind != VenueKind::Soroswap {
        return 1;
    }
    let product = (pool_tokens as u128).checked_mul(pool_quote as u128).expect("pool amounts overflow");
    (isqrt_u128(product) as i128 - SOROSWAP_MIN_LIQ - 1).max(1)
}

/// `holder`'s balance of `asset`, or `None` when `asset` doesn't answer like a token (a bogus LP token).
fn balance_of(e: &Env, asset: &Address, holder: &Address) -> Option<i128> {
    match TokenClient::new(e, asset).try_balance(holder) {
        Ok(Ok(balance)) => Some(balance),
        _ => None,
    }
}

/// The Soroswap factory's pair of the launch, if it has one.
fn soroswap_pair(e: &Env, cfg: &Config, a: &GraduateArgs) -> Option<Address> {
    match SoroswapFactoryClient::new(e, &cfg.soroswap_factory).try_get_pair(&a.token, &a.quote) {
        Ok(Ok(pair)) => Some(pair),
        _ => None,
    }
}

/// The auth node of `asset.transfer(from, to, amount)`.
fn transfer_entry(e: &Env, asset: &Address, from: &Address, to: &Address, amount: i128) -> InvokerContractAuthEntry {
    InvokerContractAuthEntry::Contract(SubContractInvocation {
        context: ContractContext {
            contract: asset.clone(),
            fn_name: Symbol::new(e, "transfer"),
            args: (from.clone(), to.clone(), amount).into_val(e),
        },
        sub_invocations: Vec::new(e),
    })
}
