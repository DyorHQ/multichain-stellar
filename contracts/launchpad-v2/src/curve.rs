//! Constant-product bonding curve with a phantom (virtual) quote reserve: v1's maths (S:contracts/launchpad/src/
//! curve.rs, the same as Monad's `CurveMath.sol`) with Monad's clamp of the last buy (§5.5, A12). The curve holds the
//! whole supply; buying moves quote in and tokens out along x·y = k where x = phantom + real quote. When `threshold`
//! real quote has been raised, the token reserve left is supply · phantom / (phantom + threshold).
//!
//! A buy that would pass the threshold pulls only what takes the curve to it, and its net is clamped to what remains,
//! so completion leaves `real_quote == threshold` exactly; the snipe bucket absorbs the rounding
//! (M:contracts/src/BondingCurve.sol:258-274). v1's clamp could overshoot by up to 2 units.

use dyor_common::{mul_div, mul_div_up, BPS};
use soroban_sdk::contracttype;

/// Fees (curve fee + creator fee + snipe tax) never take more than 99% of a trade.
pub const MAX_TOTAL_BPS: u32 = 9_900;

/// Output for `amount_in` against reserves (reserve_in, reserve_out), rounded down.
pub fn amount_out(amount_in: i128, reserve_in: i128, reserve_out: i128) -> i128 {
    mul_div(amount_in, reserve_out, reserve_in + amount_in)
}

/// `bps` of `amount`, rounded down.
pub fn fee_of(amount: i128, bps: u32) -> i128 {
    mul_div(amount, bps as i128, BPS as i128)
}

/// A gross amount whose net after `total_bps` of fees is at least `net`: ceil(net · BPS / (BPS − total_bps)).
pub fn gross_for_net(net: i128, total_bps: u32) -> i128 {
    mul_div_up(net, BPS as i128, (BPS - total_bps) as i128)
}

/// Tokens that go to the pool at graduation so the pool opens at the curve's final price:
/// real_quote · token_reserve / quote_reserve (price-continuous).
pub fn pool_tokens(real_quote: i128, token_reserve: i128, quote_reserve: i128) -> i128 {
    mul_div(real_quote, token_reserve, quote_reserve)
}

// Breakdown of a buy. `used` is what is pulled from the buyer (≤ quote_in: the last buy is clamped at the
// threshold), `net` is what enters the curve, and `used = net + base_fee + creator_fee + snipe_fee`.
#[contracttype]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BuyQuote {
    pub used: i128,
    pub net: i128,
    pub base_fee: i128,
    pub creator_fee: i128,
    // The snipe tax plus the rounding of the total fee.
    pub snipe_fee: i128,
    pub tokens_out: i128,
}

/// Prices a buy of `quote_in` (> 0) against the curve. `remaining` is threshold − real quote (> 0).
pub fn quote_buy(
    quote_in: i128,
    quote_reserve: i128,
    token_reserve: i128,
    remaining: i128,
    fee_bps: u32,
    creator_fee_bps: u32,
    snipe_bps: u32,
) -> BuyQuote {
    // The snipe tax gives way first when the total is capped: fee_bps + creator_fee_bps < MAX_TOTAL_BPS always.
    let total = core::cmp::min(fee_bps + creator_fee_bps + snipe_bps, MAX_TOTAL_BPS);
    let mut used = quote_in;
    let mut net = used - fee_of(used, total);
    if net > remaining {
        // Monad's clamp: pull only what takes the curve to the threshold (the excess never leaves the buyer's
        // wallet), and never let the net pass it.
        used = core::cmp::min(gross_for_net(remaining, total), quote_in);
        net = core::cmp::min(used - fee_of(used, total), remaining);
    }
    let base_fee = fee_of(used, fee_bps);
    let creator_fee = fee_of(used, creator_fee_bps);
    let snipe_fee = used - net - base_fee - creator_fee;
    let tokens_out = if net > 0 { amount_out(net, quote_reserve, token_reserve) } else { 0 };
    BuyQuote { used, net, base_fee, creator_fee, snipe_fee, tokens_out }
}

// Breakdown of a sell: `gross` leaves the curve, `quote_out` reaches the seller.
#[contracttype]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SellQuote {
    pub gross: i128,
    pub base_fee: i128,
    pub creator_fee: i128,
    pub quote_out: i128,
}

pub fn quote_sell(
    tokens_in: i128,
    quote_reserve: i128,
    token_reserve: i128,
    fee_bps: u32,
    creator_fee_bps: u32,
) -> SellQuote {
    let gross = amount_out(tokens_in, token_reserve, quote_reserve);
    let base_fee = fee_of(gross, fee_bps);
    let creator_fee = fee_of(gross, creator_fee_bps);
    SellQuote { gross, base_fee, creator_fee, quote_out: gross - base_fee - creator_fee }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUPPLY: i128 = 1_000_000_000 * 10_000_000;

    /// Token reserve left in the curve when `threshold` has been raised: supply · phantom / (phantom + threshold).
    fn reserved_supply(supply: i128, phantom: i128, threshold: i128) -> i128 {
        mul_div(supply, phantom, phantom + threshold)
    }

    #[test]
    fn graduation_leaves_about_31_6_percent_for_10x() {
        // threshold = phantom · (√10 − 1)
        let phantom = 2_000 * 10_000_000i128;
        let threshold = mul_div(phantom, 216_227_766, 100_000_000);
        let reserved = reserved_supply(SUPPLY, phantom, threshold);
        let pct = mul_div(reserved, 1_000_000, SUPPLY); // ppm
        assert!((316_200..=316_300).contains(&pct), "{pct}");
        // price ratio end/start = ((phantom + threshold) / reserved) / (phantom / supply) ≈ 10
        let ratio_ppm = mul_div(mul_div(phantom + threshold, SUPPLY, reserved), 1_000_000, phantom);
        assert!((9_999_000..=10_001_000).contains(&ratio_ppm), "{ratio_ppm}");
    }

    #[test]
    fn buy_clamps_at_threshold() {
        let remaining = 10 * 10_000_000;
        let q = quote_buy(1_000 * 10_000_000, 2_000 * 10_000_000, SUPPLY, remaining, 100, 0, 0);
        assert!(q.used < 1_000 * 10_000_000);
        // Monad's clamp: the net lands on the threshold exactly (v1 allowed up to +2).
        assert_eq!(q.net, remaining);
        assert_eq!(q.used, q.net + q.base_fee + q.creator_fee + q.snipe_fee);
        assert_eq!(q.used, gross_for_net(remaining, 100));
        // Exact for every remainder, fee mix and amount that passes it.
        for remaining in [1i128, 2, 3, 99, 100, 101, 9_999, 43_245_553_200] {
            for (fee, creator, snipe) in [(100, 0, 0), (100, 1_000, 0), (100, 1_000, 9_800), (100, 37, 300), (0, 0, 0)]
            {
                for quote_in in [remaining + remaining / 2 + 3, 10 * remaining + 7, i128::MAX / 1_000_000_000_000] {
                    let q = quote_buy(quote_in, 2_000 * 10_000_000, SUPPLY, remaining, fee, creator, snipe);
                    if q.used < quote_in
                        || quote_in - fee_of(quote_in, (fee + creator + snipe).min(MAX_TOTAL_BPS)) > remaining
                    {
                        assert_eq!(
                            q.net, remaining,
                            "remaining {remaining} fees {fee}/{creator}/{snipe} in {quote_in}"
                        );
                    }
                    assert!(q.net <= remaining && q.used <= quote_in && q.snipe_fee >= 0);
                    assert_eq!(q.used, q.net + q.base_fee + q.creator_fee + q.snipe_fee);
                }
            }
        }
    }

    #[test]
    fn snipe_is_capped_so_fees_never_exceed_99_percent() {
        let q = quote_buy(100 * 10_000_000, 2_000 * 10_000_000, SUPPLY, i128::MAX / 4, 100, 1_000, 9_800);
        assert_eq!(q.base_fee, 10_000_000);
        assert_eq!(q.creator_fee, 100_000_000);
        assert_eq!(q.snipe_fee, 880_000_000); // 9900 − 100 − 1000
        assert_eq!(q.net, 10_000_000);
    }

    #[test]
    fn round_trip_never_returns_more_than_paid() {
        let (mut qr, mut tr) = (2_000 * 10_000_000i128, SUPPLY);
        let b = quote_buy(500 * 10_000_000, qr, tr, i128::MAX / 4, 100, 0, 0);
        qr += b.net;
        tr -= b.tokens_out;
        let s = quote_sell(b.tokens_out, qr, tr, 100, 0);
        assert!(s.gross <= b.net);
        assert!(s.quote_out < b.used);
    }
}
