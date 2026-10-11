//! Constant-product bonding curve with a phantom (virtual) quote reserve, the same math as the Monad launchpad
//! (`CurveMath.sol`). The curve holds the whole supply; buying moves quote in and tokens out along x·y = k where
//! x = phantom + real quote. When `threshold` real quote has been raised the token reserve left is
//! supply · phantom / (phantom + threshold).

use soroban_sdk::contracttype;

pub const BPS: i128 = 10_000;
/// Fees (curve fee + creator fee + snipe tax) never take more than 99% of a trade.
pub const MAX_TOTAL_BPS: u32 = 9_900;

/// floor(a · b / c). Overflow traps (overflow-checks are on in every profile).
pub fn mul_div(a: i128, b: i128, c: i128) -> i128 {
    a.checked_mul(b).expect("mul overflow") / c
}

/// ceil(a · b / c) for non-negative inputs.
pub fn mul_div_up(a: i128, b: i128, c: i128) -> i128 {
    let p = a.checked_mul(b).expect("mul overflow");
    (p + c - 1) / c
}

/// Output for `amount_in` against reserves (reserve_in, reserve_out), rounded down.
pub fn amount_out(amount_in: i128, reserve_in: i128, reserve_out: i128) -> i128 {
    mul_div(amount_in, reserve_out, reserve_in + amount_in)
}

/// `bps` of `amount`, rounded down.
pub fn fee_of(amount: i128, bps: u32) -> i128 {
    mul_div(amount, bps as i128, BPS)
}

/// Smallest gross amount whose net after `total_bps` of fees is at least `net`.
pub fn gross_for_net(net: i128, total_bps: u32) -> i128 {
    mul_div_up(net, BPS, BPS - total_bps as i128)
}

/// Token reserve left in the curve when `threshold` has been raised: supply · phantom / (phantom + threshold).
/// (Documents the economics; the contract reads the live reserve instead.)
#[allow(dead_code)]
pub fn reserved_supply(supply: i128, phantom: i128, threshold: i128) -> i128 {
    mul_div(supply, phantom, phantom + threshold)
}

/// Tokens that go to the pool at graduation so the pool opens at the curve's final price:
/// real_quote · token_reserve / quote_reserve.
pub fn pool_tokens(real_quote: i128, token_reserve: i128, quote_reserve: i128) -> i128 {
    mul_div(real_quote, token_reserve, quote_reserve)
}

/// Breakdown of a buy. `used` is what is pulled from the buyer (≤ quote_in: the last buy is clamped at the
/// threshold), `net` is what enters the curve.
#[contracttype]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BuyQuote {
    pub used: i128,
    pub net: i128,
    pub base_fee: i128,
    pub creator_fee: i128,
    pub snipe_fee: i128,
    pub tokens_out: i128,
}

/// Prices a buy of `quote_in` against the curve. `remaining` is threshold − real quote (> 0).
pub fn quote_buy(
    quote_in: i128,
    quote_reserve: i128,
    token_reserve: i128,
    remaining: i128,
    fee_bps: u32,
    creator_fee_bps: u32,
    snipe_bps: u32,
) -> BuyQuote {
    let total = core::cmp::min(fee_bps + creator_fee_bps + snipe_bps, MAX_TOTAL_BPS);
    // The snipe tax gives way first when the total is capped.
    let snipe = total - fee_bps - creator_fee_bps;
    let fees = |amount: i128| (fee_of(amount, fee_bps), fee_of(amount, creator_fee_bps), fee_of(amount, snipe));
    let (mut b, mut c, mut s) = fees(quote_in);
    let mut used = quote_in;
    let mut net = quote_in - b - c - s;
    if net > remaining {
        // Clamp: pull only what takes the curve to the threshold (Monad behaviour: no refund transfer, the excess
        // never leaves the buyer's wallet).
        used = core::cmp::min(gross_for_net(remaining, total), quote_in);
        let f = fees(used);
        b = f.0;
        c = f.1;
        s = f.2;
        net = used - b - c - s;
    }
    let tokens_out = if net > 0 { amount_out(net, quote_reserve, token_reserve) } else { 0 };
    BuyQuote { used, net, base_fee: b, creator_fee: c, snipe_fee: s, tokens_out }
}

/// Breakdown of a sell.
#[contracttype]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SellQuote {
    pub gross: i128,
    pub base_fee: i128,
    pub creator_fee: i128,
    pub quote_out: i128,
}

pub fn quote_sell(tokens_in: i128, quote_reserve: i128, token_reserve: i128, fee_bps: u32, creator_fee_bps: u32) -> SellQuote {
    let gross = amount_out(tokens_in, token_reserve, quote_reserve);
    let base_fee = fee_of(gross, fee_bps);
    let creator_fee = fee_of(gross, creator_fee_bps);
    SellQuote { gross, base_fee, creator_fee, quote_out: gross - base_fee - creator_fee }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUPPLY: i128 = 1_000_000_000_0000000;

    #[test]
    fn graduation_leaves_about_31_6_percent_for_10x() {
        // threshold = phantom · (√10 − 1)
        let phantom = 2_000_0000000i128;
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
        let q = quote_buy(1_000_0000000, 2_000_0000000, SUPPLY, 10_0000000, 100, 0, 0);
        assert!(q.used < 1_000_0000000);
        assert!(q.net >= 10_0000000 && q.net <= 10_0000000 + 2);
        assert_eq!(q.used, q.net + q.base_fee + q.creator_fee + q.snipe_fee);
    }

    #[test]
    fn snipe_is_capped_so_fees_never_exceed_99_percent() {
        let q = quote_buy(100_0000000, 2_000_0000000, SUPPLY, i128::MAX / 4, 100, 1_000, 9_800);
        assert_eq!(q.base_fee, 1_0000000);
        assert_eq!(q.creator_fee, 10_0000000);
        assert_eq!(q.snipe_fee, 88_0000000); // 9900 − 100 − 1000
        assert_eq!(q.net, 1_0000000);
    }

    #[test]
    fn round_trip_never_returns_more_than_paid() {
        let (mut qr, mut tr) = (2_000_0000000i128, SUPPLY);
        let b = quote_buy(500_0000000, qr, tr, i128::MAX / 4, 100, 0, 0);
        qr += b.net;
        tr -= b.tokens_out;
        let s = quote_sell(b.tokens_out, qr, tr, 100, 0);
        assert!(s.gross <= b.net);
        assert!(s.quote_out < b.used);
    }
}
