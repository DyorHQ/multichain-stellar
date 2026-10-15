//! Differential vectors against Monad (§18.2), on the dist WASMs through their public views and calls, scaled to 7
//! decimals:
//! - the curve against a line-by-line port of Monad's `BondingCurve._buyBreakdown`, `quoteSell` and `_distributeFees`
//!   (M:contracts/src/BondingCurve.sol:248-319, CurveMath.sol) over random curves, fee mixes, snipe taxes and buy sizes
//!   from dust to 100× the remaining gap, the clamp included (property test; `PROPTEST_CASES` sets the count);
//! - Monad's `Launchpad.t.sol` vectors (M:contracts/test/LaunchpadBase.sol: supply 1e9, phantom 4,000, threshold
//!   16,000, curve fee 100 bps, protocol share 5,000): every amount is a whole number of units, so they scale exactly;
//! - Monad's Moments `Economics.t.sol` vectors (S = 1e26 coin wei, USDC at 6 dp) and economics.py's model shares.
//!
//! Ported from the CT-19 R1 review tests, which ran them against the crates' internal functions.
use dyor_common::mul_div_up;
use dyor_integration_tests::launchpad::{Curve, Phase};
use dyor_integration_tests::*;
use proptest::prelude::*;
use soroban_sdk::{vec, Address};

// ------------------------------------------------------------------------------------------------ Monad, ported

/// BondingCurve._buyBreakdown + CurveMath, in u128 (amounts at 7 dp never need FullMath's 512-bit product here).
/// Returns (used, net, fee, tax, snipe, tokens_out, refund).
fn monad_buy(
    quote_in: u128,
    quote_reserve: u128,
    token_reserve: u128,
    remaining: u128,
    fee_bps: u128,
    tax_bps: u128,
    snipe_bps: u128,
) -> (u128, u128, u128, u128, u128, u128, u128) {
    const BPS: u128 = 10_000;
    const MAX: u128 = 9_900;
    let fee_of = |a: u128, b: u128| a * b / BPS;
    let base_bps = fee_bps + tax_bps;
    let mut snipe_bps = snipe_bps;
    if base_bps + snipe_bps > MAX {
        snipe_bps = MAX.saturating_sub(base_bps);
    }
    let total_bps = base_bps + snipe_bps;
    let mut used = quote_in;
    let mut net = quote_in - fee_of(quote_in, total_bps);
    let mut refund = 0;
    if net > remaining {
        // CurveMath.grossForNet: mulDivRoundingUp(net, BPS, BPS - totalBps)
        used = (remaining * BPS).div_ceil(BPS - total_bps);
        if used > quote_in {
            used = quote_in;
        }
        net = used - fee_of(used, total_bps);
        if net > remaining {
            net = remaining;
        }
        refund = quote_in - used;
    }
    let fee = fee_of(used, fee_bps);
    let tax = fee_of(used, tax_bps);
    let snipe = used - net - fee - tax;
    let tokens_out = net * token_reserve / (quote_reserve + net);
    (used, net, fee, tax, snipe, tokens_out, refund)
}

/// BondingCurve.quoteSell (not rescued): (gross, fee, tax, quote_out).
fn monad_sell(tokens_in: u128, quote_reserve: u128, token_reserve: u128, fee_bps: u128, tax_bps: u128) -> [u128; 4] {
    let gross = tokens_in * quote_reserve / (token_reserve + tokens_in);
    let fee = gross * fee_bps / 10_000;
    let tax = gross * tax_bps / 10_000;
    [gross, fee, tax, gross - fee - tax]
}

/// BondingCurve._distributeFees: (protocol_cut, creator_cut).
fn monad_split(base_fee: u128, tax: u128, protocol_share_bps: u128) -> (u128, u128) {
    let protocol = base_fee * protocol_share_bps / 10_000;
    (protocol, base_fee - protocol + tax)
}

/// What a curve booked for the creator side: the creator's fees, or with sharing on what went to the holders.
fn creator_side(c: &Curve) -> i128 {
    c.creator_fees + c.holder_fees_total
}

// ------------------------------------------------------------------------------------------------ differential

/// A fresh quote asset on `w`'s launchpad with `phantom` and the 10× threshold, minted to the traders.
fn quote_with(w: &World, phantom: i128, threshold: i128) -> Address {
    let q = w.e.register_stellar_asset_contract_v2(w.admin.clone()).address();
    w.pad().set_quote(&q, &phantom, &threshold, &true, &vec![&w.e], &SOROSWAP);
    q
}

proptest! {
    /// Random curves (phantom 1 to 10^6 whole quote units, any reached point below the threshold), fee mixes within
    /// set_fees' bounds, snipe taxes and buy sizes from dust to 100× the remaining gap: the dist launchpad's
    /// `quote_buy` equals Monad's breakdown to the unit, the buy books Monad's fee split, completion lands exactly on
    /// the threshold, and the sell of what was bought equals Monad's `quoteSell` and never returns more (I-L3).
    #[test]
    fn the_curve_matches_monads_breakdown_split_and_clamp_to_the_unit(
        phantom_units in 1i128..=1_000_000,
        along in 0u32..=9_999,
        fee in 0u32..=1_000,
        creator in 0u32..=1_000,
        snipe in prop_oneof![Just(0u32), Just(30u32), Just(300u32), Just(2_500u32), Just(9_800u32), 0u32..=10_000],
        sniped in any::<bool>(),
        quote_in in prop_oneof![100i128..=1_000, 100i128..=1_000_000_000, 100i128..=100_000_000_000_000],
        share in 0u32..=10_000,
        sharing in any::<bool>(),
    ) {
        let w = World::new(PRODUCTION);
        let pad = w.pad();
        pad.set_fees(&fee, &share, &creator, &vec![&w.e, snipe], &5);
        let phantom = phantom_units * ONE;
        let threshold = threshold_of(phantom);
        let q = quote_with(&w, phantom, threshold);
        let p = launchpad::LaunchParams { creator_fee_bps: creator, ..w.params(&q, SOROSWAP, sharing) };
        w.mint(&q, &w.creator, threshold * 2 + ONE);
        let token = w.launch_with(&w.creator, &p);
        // The creator (exempt from the snipe tax) takes the curve to `along` ‱ of the threshold.
        let target = threshold * along as i128 / 10_000;
        if target > 0 {
            let gross = mul_div_up(target, 10_000, (10_000 - fee - creator) as i128);
            w.mint(&q, &w.creator, gross);
            w.buy(&w.creator, &token, gross);
        }
        if !sniped {
            w.advance(5);
        }
        let c = w.curve(&token);
        prop_assume!(c.phase == Phase::Curve);
        let remaining = c.threshold - c.real_quote;
        let quote_in = quote_in.min(remaining * 100 + 7);
        let snipe_now = if sniped { snipe } else { 0 };

        let v2 = pad.quote_buy(&token, &w.alice, &quote_in);
        let m = monad_buy(
            quote_in as u128,
            c.quote_reserve as u128,
            c.token_reserve as u128,
            remaining as u128,
            fee as u128,
            creator as u128,
            snipe_now as u128,
        );
        prop_assert_eq!(
            (v2.used, v2.net, v2.base_fee, v2.creator_fee, v2.snipe_fee, v2.tokens_out),
            (m.0 as i128, m.1 as i128, m.2 as i128, m.3 as i128, m.4 as i128, m.5 as i128)
        );
        // What v2 never pulls is exactly what Monad refunds; never past the threshold (I-L7).
        prop_assert_eq!((quote_in - v2.used) as u128, m.6);
        prop_assert!(v2.net <= remaining);
        if m.6 > 0 {
            prop_assert_eq!(v2.net, remaining);
        }
        prop_assume!(v2.tokens_out > 0);

        // The buy itself: what it pulls, what it books, Monad's fee split.
        w.mint(&q, &w.alice, quote_in);
        let before = w.balance(&q, &w.alice);
        let out = w.buy(&w.alice, &token, quote_in);
        prop_assert_eq!(out, v2.tokens_out);
        prop_assert_eq!(before - w.balance(&q, &w.alice), v2.used);
        let after = w.curve(&token);
        prop_assert_eq!(after.real_quote, c.real_quote + v2.net);
        let (mp, mc) = monad_split((v2.base_fee + v2.snipe_fee) as u128, v2.creator_fee as u128, share as u128);
        prop_assert_eq!((after.protocol_fees - c.protocol_fees) as u128, mp);
        prop_assert_eq!((creator_side(&after) - creator_side(&c)) as u128, mc);
        if v2.net == remaining {
            prop_assert_eq!(after.phase, Phase::Completed);
            prop_assert_eq!(after.real_quote, after.threshold);
            return Ok(());
        }

        // The sell of what was bought, against the curve after the buy.
        let s = pad.quote_sell(&token, &out);
        let ms = monad_sell(out as u128, after.quote_reserve as u128, after.token_reserve as u128, fee as u128, creator as u128);
        prop_assert_eq!([s.gross as u128, s.base_fee as u128, s.creator_fee as u128, s.quote_out as u128], ms);
        prop_assert!(s.gross <= v2.net && s.quote_out <= v2.used, "I-L3");
        let got = w.sell(&w.alice, &token, out);
        prop_assert_eq!(got, s.quote_out);
        let sold = w.curve(&token);
        let (mp, mc) = monad_split(s.base_fee as u128, s.creator_fee as u128, share as u128);
        prop_assert_eq!((sold.protocol_fees - after.protocol_fees) as u128, mp);
        prop_assert_eq!((creator_side(&sold) - creator_side(&after)) as u128, mc);
    }
}

// ------------------------------------------------------------------------------------------------ Launchpad.t.sol

const M_PHANTOM: i128 = 4_000 * ONE;
const M_THRESHOLD: i128 = 16_000 * ONE;

#[test]
fn monads_launchpad_t_sol_vectors_at_7_decimals() {
    let w = World::new(PRODUCTION);
    let pad = w.pad();
    let q = quote_with(&w, M_PHANTOM, M_THRESHOLD);
    for who in [&w.alice, &w.bob] {
        w.mint(&q, who, 100_000 * ONE);
    }
    let launch = |creator_fee_bps: u32| {
        let p = launchpad::LaunchParams { creator_fee_bps, ..w.params(&q, SOROSWAP, false) };
        w.launch_with(&w.creator, &p)
    };

    // test_buy_and_sell_fees_and_reserves: 100 in, fee 1, net 99, out = 99·S/(P + 99); protocol 0.5, creator 0.5.
    let token = launch(0);
    w.advance(30);
    let b = pad.quote_buy(&token, &w.alice, &(100 * ONE));
    assert_eq!((b.used, b.base_fee, b.creator_fee, b.snipe_fee, b.net), (100 * ONE, ONE, 0, 0, 99 * ONE));
    assert_eq!(b.tokens_out, 99 * ONE * SUPPLY / (M_PHANTOM + 99 * ONE));
    let c0 = w.curve(&token);
    assert_eq!(w.buy(&w.alice, &token, 100 * ONE), b.tokens_out);
    let c1 = w.curve(&token);
    assert_eq!((c1.protocol_fees - c0.protocol_fees, c1.creator_fees - c0.creator_fees), (ONE / 2, ONE / 2));
    assert_eq!((c1.quote_reserve, c1.token_reserve), (M_PHANTOM + 99 * ONE, SUPPLY - b.tokens_out));
    // Its sell of half: the creator's half of the sell fee rounds up (`sellFee - sellFee / 2`).
    let s = pad.quote_sell(&token, &(b.tokens_out / 2));
    let ms = monad_sell((b.tokens_out / 2) as u128, c1.quote_reserve as u128, c1.token_reserve as u128, 100, 0);
    assert_eq!([s.gross as u128, s.base_fee as u128, s.creator_fee as u128, s.quote_out as u128], ms);
    w.sell(&w.alice, &token, b.tokens_out / 2);
    let c2 = w.curve(&token);
    assert_eq!(c2.creator_fees - c1.creator_fees, s.base_fee - s.base_fee / 2);
    assert_eq!(c2.protocol_fees - c1.protocol_fees, s.base_fee / 2);

    // test_snipe_tax_schedule: 100 at 9,800 bps → snipe 98, and the protocol gets 49.5 (the snipe joins the base
    // split). The buy lands in the launch's own ledger second.
    let token = launch(0);
    let b = pad.quote_buy(&token, &w.alice, &(100 * ONE));
    assert_eq!(b.snipe_fee, 98 * ONE);
    let c0 = w.curve(&token);
    w.buy(&w.alice, &token, 100 * ONE);
    let c1 = w.curve(&token);
    assert_eq!(c1.protocol_fees - c0.protocol_fees, 495 * ONE / 10);
    assert_eq!(c1.creator_fees - c0.creator_fees, 495 * ONE / 10);

    // test_creator_tax: 500 bps → the creator gets 0.5 + 5, the real reserve 94.
    let token = launch(500);
    w.advance(30);
    w.buy(&w.alice, &token, 100 * ONE);
    let c = w.curve(&token);
    assert_eq!((c.creator_fees, c.protocol_fees, c.real_quote), (ONE / 2 + 5 * ONE, ONE / 2, 94 * ONE));

    // test_final_buy_is_clamped_and_refunded: 15,000 in → real 14,850; then 5,000 offered: used =
    // ceil(remaining·10,000/9,900), the rest never leaves the buyer, and the curve completes exactly.
    let token = launch(0);
    w.advance(30);
    w.buy(&w.alice, &token, 15_000 * ONE);
    assert_eq!(w.curve(&token).real_quote, 14_850 * ONE);
    let remaining = M_THRESHOLD - 14_850 * ONE;
    let before = w.balance(&q, &w.bob);
    w.buy(&w.bob, &token, 5_000 * ONE);
    assert_eq!(before - w.balance(&q, &w.bob), (remaining * 10_000 + 9_899) / 9_900);
    let c = w.curve(&token);
    assert_eq!((c.real_quote, c.phase), (M_THRESHOLD, Phase::Completed));
    // test_launch_setsUpTokenAndCurve: reservedTokens = S·P/(P + T); the completed curve holds that, plus at most one
    // unit per buy from the floors (which only ever leave more tokens in the curve).
    let reserved = SUPPLY * M_PHANTOM / (M_PHANTOM + M_THRESHOLD);
    assert!(c.token_reserve >= reserved && c.token_reserve - reserved <= 2, "{} vs {reserved}", c.token_reserve);

    // test_router_launchAndBuy_over_threshold_refunds_and_graduates: 20,000 from empty → used = ⌈T·10,000/9,900⌉.
    let token = launch(0);
    w.advance(30);
    let b = pad.quote_buy(&token, &w.alice, &(20_000 * ONE));
    assert_eq!((b.used, b.net), ((M_THRESHOLD * 10_000 + 9_899) / 9_900, M_THRESHOLD));
    assert!(SUPPLY - b.tokens_out >= reserved && SUPPLY - b.tokens_out - reserved <= 1);
    let before = w.balance(&q, &w.alice);
    w.buy(&w.alice, &token, 20_000 * ONE);
    assert_eq!(before - w.balance(&q, &w.alice), b.used);
    assert_eq!(w.curve(&token).phase, Phase::Completed);
}

// ------------------------------------------------------------------------------------------------ Economics.t.sol

/// 18-dp coin amounts of M:contracts/test/moments/Economics.t.sol (S = 1e26 coin wei, USDC at 6 dp) in 7-dp coin
/// units: the coin side scales by 1e11.
const SCALE: i128 = 100_000_000_000;
const ENT_10C: i128 = 385_714_285_714_285_714_285_714;
const ENT_1USD: i128 = 3_857_142_857_142_857_142_857_142;
const ENT_10USD: i128 = 38_571_428_571_428_571_428_571_428;
const SUM_ENT_10USD: i128 = 51_428_573_999_999_999_999_999_988;
const POOL_10USD: i128 = 38_571_426_000_000_000_000_000_012;

/// Monad's exact-value vectors at 7 dp on the testnet policy (T = 10 USDC, 20/5/75, 10% allocation): the entitlements
/// of $0.10, $1 and $10 collects equal Monad's to the 7-dp unit (floor), the 20/5/75 split is Monad's ×10, the terminal
/// clamp after 13 × $1 lands on the threshold with Monad's shape, and the graduation identity holds exactly. The
/// totals differ from Monad's only by the terminal gross's finer rounding (3,333,334 at 7 dp against 333,334 at 6 dp).
#[test]
fn monads_economics_t_sol_vectors_at_7_decimals() {
    let w = World::new(PRODUCTION);
    let m = w.m();
    let nft = w.publish_on(&w.moments, &moments::PublishParams { price: ONE / 10, ..w.publish_params() });
    let q = m.quote(&nft, &1);
    assert_eq!(q.entitlement, ENT_10C / SCALE);
    assert_eq!((q.reserve_in, q.platform_in, q.creator_in), (750_000, 50_000, 200_000));
    let q = m.quote(&nft, &10);
    assert_eq!(q.entitlement, ENT_1USD / SCALE);
    assert_eq!((q.reserve_in, q.platform_in, q.creator_in), (7_500_000, 500_000, 2_000_000));
    let nft10 = w.publish_on(&w.moments, &moments::PublishParams { price: 10 * ONE, ..w.publish_params() });
    assert_eq!(m.quote(&nft10, &1).entitlement, ENT_10USD / SCALE);

    let nft = w.publish_on(&w.moments, &moments::PublishParams { price: ONE, ..w.publish_params() });
    for _ in 0..13 {
        let r = w.collect_on(&w.moments, &w.alice, &nft, 1);
        assert_eq!(r.entitlement, ENT_1USD / SCALE);
    }
    assert_eq!(m.ledger(&nft).reserve, 97_500_000);
    let q = m.quote(&nft, &1);
    assert!(q.terminal);
    // Monad (6 dp): gross 333,334, reserve 250,000, platform 16,666, creator 66,668, 1 edition, excess 666,666.
    assert_eq!(
        (q.gross, q.reserve_in, q.platform_in, q.creator_in, q.editions, q.excess),
        (3_333_334, 2_500_000, 166_666, 666_668, 1, 6_666_666)
    );
    w.collect_on(&w.moments, &w.bob, &nft, 1);
    assert_eq!(m.ledger(&nft).reserve, T10);
    let sc = m.supply_check(&nft);
    assert_eq!(sc.pool_coins + sc.creator_alloc + sc.entitlements, COIN_SUPPLY);
    assert_eq!(sc.creator_alloc, 10_000_000 * ONE);
    let mo = m.get_moment(&nft);
    let rate_up = mul_div_up(1, mo.rate_num, mo.rate_den);
    // Plus one unit per collect for v2's 14 floors and one for the scaling.
    let tol = 6 * rate_up + 16;
    std::println!(
        "entitlements {} vs Monad {}; pool {} vs Monad {} (tolerance {tol})",
        sc.entitlements,
        SUM_ENT_10USD / SCALE,
        sc.pool_coins,
        POOL_10USD / SCALE
    );
    assert!((sc.entitlements - SUM_ENT_10USD / SCALE).abs() <= tol);
    assert!((sc.pool_coins - POOL_10USD / SCALE).abs() <= tol);
    // economics.py's model shares: collectors 51,428,571.429 and the pool 38,571,428.571 coins, within 3 coins.
    assert!((sc.entitlements - 514_285_714_290_000).abs() <= 3 * ONE);
    assert!((sc.pool_coins - 385_714_285_710_000).abs() <= 3 * ONE);
    // It graduates with exactly those pool coins and the reserve exactly T.
    let pool = match w.graduate_moment_on(&w.moments, &nft) {
        moments::GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    };
    assert_eq!(w.balance(&mo.coin, &pool), sc.pool_coins);
    assert_eq!(w.balance(&w.usdc, &pool), T10);
    let l = m.ledger(&nft);
    assert_eq!((l.state, l.reserve), (moments::State::Graduated, 0));
}
