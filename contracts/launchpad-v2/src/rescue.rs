//! Rescue and pro-rata refunds (DESIGN-stellar-contracts-v2 §5.5, O2, L6).
//!
//! A launch that stays stuck can be rescued: by the admin from `stuck_since + rescue_admin` (7 d), by **anyone** from
//! `stuck_since + rescue_public` (30 d). Rescue burns what the launchpad holds of the token, unlocks it and snapshots
//! the raised quote (`refund_quote`) and the circulating supply (`refund_supply`). Then every holder burns tokens for
//! `floor(tokens · refund_quote / refund_supply)` of the quote, with no fees and in any order, so nobody gains by
//! refunding first and nobody who knows when `rescue` lands can front-run it (I-L8). Monad instead reopens fee-free
//! sells along the curve (M:contracts/src/BondingCurve.sol:140-158).
//!
//! Booked creator and protocol fees stay claimable. Tokens that never come back (held by a contract that can't call
//! `refund`, for example) leave their share in the launchpad; there is no sweep (§25 R16).

use crate::events::{Refunded, Rescued};
use crate::storage::{config, load_curve, load_launch, save_curve, Curve, Phase};
use crate::Error;
use dyor_common::{mul_div_u256, LaunchTokenV2Client};
use soroban_sdk::{panic_with_error, token::TokenClient, Address, Env};

pub(crate) fn rescue(e: &Env, token: &Address) {
    let mut curve = load_curve(e, token);
    if curve.phase != Phase::Completed {
        panic_with_error!(e, Error::WrongPhase);
    }
    if curve.stuck_since == 0 {
        panic_with_error!(e, Error::NotStuck);
    }
    let cfg = config(e);
    let now = e.ledger().timestamp();
    let by_admin = if now >= curve.stuck_since + cfg.durations.rescue_public {
        false
    } else if now >= curve.stuck_since + cfg.durations.rescue_admin {
        cfg.admin.require_auth();
        true
    } else {
        panic_with_error!(e, Error::NotStuck)
    };

    let this = e.current_contract_address();
    let sep41 = TokenClient::new(e, token);
    // The curve's tokens and any donations.
    let burned = sep41.balance(&this);
    if burned > 0 {
        sep41.burn(&this, &burned);
    }
    let ops = LaunchTokenV2Client::new(e, token);
    ops.unlock();
    curve.refund_quote = curve.real_quote;
    curve.refund_supply = ops.total_supply();
    curve.real_quote = 0;
    curve.token_reserve = 0;
    curve.burned = burned;
    curve.phase = Phase::Rescued;
    save_curve(e, token, &curve);
    Rescued {
        token: token.clone(),
        stuck_since: curve.stuck_since,
        by_admin,
        refund_quote: curve.refund_quote,
        refund_supply: curve.refund_supply,
        burned,
    }
    .publish(e);
}

/// Burns `tokens_in` of `holder`'s tokens (its auth covers the burn) and pays its pro-rata share of the quote.
pub(crate) fn refund(e: &Env, holder: &Address, token: &Address, tokens_in: i128) -> i128 {
    holder.require_auth();
    let launch = load_launch(e, token);
    let mut curve = load_curve(e, token);
    let out = refund_out(e, &curve, tokens_in);
    curve.refunded += out;
    save_curve(e, token, &curve);
    TokenClient::new(e, token).burn(holder, &tokens_in);
    TokenClient::new(e, &launch.quote).transfer(&e.current_contract_address(), holder, &out);
    Refunded { token: token.clone(), holder: holder.clone(), tokens_in, quote_out: out }.publish(e);
    out
}

/// floor(tokens_in · refund_quote / refund_supply): the same rate for every holder, whatever the order.
pub(crate) fn refund_out(e: &Env, curve: &Curve, tokens_in: i128) -> i128 {
    if curve.phase != Phase::Rescued {
        panic_with_error!(e, Error::WrongPhase);
    }
    if tokens_in <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
    let out = mul_div_u256(e, tokens_in, curve.refund_quote, curve.refund_supply);
    if out <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
    out
}
