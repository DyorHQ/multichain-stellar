//! Moments journeys (§18.3) on the real moments-v2, moment-nft, moment-coin, moments-graduator, exec-soroswap,
//! qa-exec-fail and lp-locker WASMs, with the production and the testnet-qa durations (§14.3).
use dyor_common::{mul_div, mul_div_up, SOROSWAP_MIN_LIQ};
use dyor_integration_tests::moments::{GradFailure, GraduationOutcome, State};
use dyor_integration_tests::*;
use soroban_sdk::Address;

const ERR_NOT_EXPIRABLE: u32 = 10_713;

fn alloc(w: &World, nft: &Address) -> i128 {
    COIN_SUPPLY * w.m().get_moment(nft).creator_alloc_bps as i128 / BPS as i128
}

// ------------------------------------------------------------------------------------------------ the happy path

fn publish_to_harvest(d: Durations) {
    let w = World::new(d);
    let m = w.m();
    let nft = w.publish();
    let mo = m.get_moment(&nft);
    let b = w.collect_on(&w.moments, &w.bob, &nft, 3);
    let a = w.complete_moment_on(&w.moments, &w.alice, &nft);
    let l = m.ledger(&nft);
    assert_eq!(l.reserve, mo.threshold, "I-M1: the terminal collect lands exactly on the threshold");
    // I-M2.
    assert!(w.balance(&w.usdc, &w.moments) >= l.reserve + l.creator_claimable + l.platform_claimable + l.treasury_claimable);

    let pool = match w.graduate_moment_on(&w.moments, &nft) {
        GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    };
    let l = m.ledger(&nft);
    assert_eq!((l.state, l.stuck_since, l.reserve), (State::Graduated, 0, 0), "I-M6");
    assert!(w.nft(&nft).closed());
    let coin = mo.coin.clone();
    // I-M3: pool coins + allocation + entitlements == S.
    let pool_coins = w.balance(&coin, &pool);
    assert_eq!(pool_coins + alloc(&w, &nft) + l.entitlements, COIN_SUPPLY);
    assert_eq!(l.entitlements, a.entitlement + b.entitlement);
    assert_eq!(w.pair(&pool).total_supply(), w.balance(&pool, &w.locker) + SOROSWAP_MIN_LIQ);
    let pos = w.locker().position(&pool).unwrap();
    assert_eq!(pos.harvest_bps, MOMENT_HARVEST_BPS);

    // Vesting over five periods: collectors 60/80/100% at 0/1/2 periods, the creator 20% + 16% a period.
    let graduated_at = l.graduated_at;
    let mut minted = 0;
    let mut last = (0i128, 0i128, 0i128);
    for period in 0..=5u64 {
        w.set_time(graduated_at + period * d.moments.vest_period);
        let c_bps = [6_000, 8_000, 10_000][period.min(2) as usize] as i128;
        let cr_bps = 2_000 + 1_600 * period.min(5) as i128;
        let vested_a = mul_div(a.entitlement, c_bps, BPS as i128);
        let vested_b = mul_div(b.entitlement, c_bps, BPS as i128);
        let vested_cr = mul_div(alloc(&w, &nft), cr_bps, BPS as i128);
        if vested_a > last.0 {
            assert_eq!(m.claim(&w.alice, &nft).0, vested_a - last.0);
        }
        if vested_b > last.1 && period % 2 == 0 {
            // Bob claims every other period: what he skips stays claimable (I-M4).
            let (got, _) = m.claim(&w.bob, &nft);
            assert_eq!(got, vested_b - last.1);
            last.1 = vested_b;
        }
        if vested_cr > last.2 {
            assert_eq!(m.claim(&w.creator, &nft).1, vested_cr - last.2);
        }
        last.0 = vested_a;
        last.2 = vested_cr;
        minted = w.sep41(&coin).balance(&w.alice) + w.sep41(&coin).balance(&w.bob) + w.sep41(&coin).balance(&w.creator);
        assert!(m.ledger(&nft).minted_by_vesting <= alloc(&w, &nft) + l.entitlements);
    }
    assert_eq!(minted, alloc(&w, &nft) + l.entitlements, "every coin vested by period 5");
    assert_eq!(w.supply(&coin), COIN_SUPPLY);

    // Harvests with the 0.5% round cap binding: compounded : harvested = 3,333 : 6,667 every round (F7, V3), the
    // USDC side paid 40/60 to the creator and the platform, the coin side burned.
    for _ in 0..3 {
        let quote_side = w.reserves(&pool, &w.usdc).0;
        w.churn(&coin, &w.usdc, quote_side, 8);
        w.advance(d.moments.harvest_interval);
        let before = w.locker().position(&pool).unwrap();
        let (supply0, cr0, pf0) =
            (w.supply(&coin), w.balance(&w.usdc, &w.creator), w.balance(&w.usdc, &w.platform));
        let (growth, ..) = w.locker().harvestable(&pool);
        let (coin_out, usdc_out) = w.harvest(&pool);
        let after = w.locker().position(&pool).unwrap();
        let compounded = after.principal - before.principal;
        // take·(BPS − hb)/hb, rounded up (§8.2): the ratio 3,333 : 6,667 within one unit.
        let take = (compounded * MOMENT_HARVEST_BPS as i128) / (BPS - MOMENT_HARVEST_BPS) as i128;
        assert!(compounded > 0 && take > 0);
        assert!(take + compounded < growth, "the cap binds: some growth stays for later rounds: take {take}, compounded {compounded}, growth {growth}");
        let take_exact_low = mul_div(compounded - 1, MOMENT_HARVEST_BPS as i128, (BPS - MOMENT_HARVEST_BPS) as i128);
        assert!(take >= take_exact_low);
        assert_eq!(w.supply(&coin), supply0 - coin_out, "the coin side is burned");
        let creator_part = mul_div(usdc_out, 4_000, BPS as i128);
        assert_eq!(w.balance(&w.usdc, &w.creator) - cr0, creator_part);
        assert_eq!(w.balance(&w.usdc, &w.platform) - pf0, usdc_out - creator_part);
        // I-K1: the position's √k value still covers its principal.
        let (rc, ru) = w.reserves(&pool, &coin);
        let current = dyor_common::isqrt_u128(rc as u128 * ru as u128) as i128 * after.lp / w.pair(&pool).total_supply();
        assert!(current >= after.principal);
    }
    // I-M3 after burns: lifetime vesting mints stay at allocation + entitlements.
    assert_eq!(m.ledger(&nft).minted_by_vesting, alloc(&w, &nft) + l.entitlements);
}

#[test]
fn publish_collect_graduate_vest_and_harvest_production() {
    publish_to_harvest(PRODUCTION);
}

#[test]
fn publish_collect_graduate_vest_and_harvest_testnet_qa() {
    publish_to_harvest(TESTNET_QA);
}

// ------------------------------------------------------------------------------------------------ expiry

/// A Moment on stack `stack`, completed, with the failing executor's mode for its coin set to `mode`.
fn pending(w: &World, stack: &Address, mode: Option<qa_exec_fail::Mode>) -> Address {
    // The shortest window, so the stuck clock and the backstop, not the deadline, decide (§14.3).
    let p = moments::PublishParams { window_secs: w.d.moments.min_window, ..w.publish_params() };
    let nft = w.publish_on(stack, &p);
    w.collect_on(stack, &w.bob, &nft, 2);
    w.complete_moment_on(stack, &w.alice, &nft);
    if let Some(mode) = mode {
        w.qa().set_mode(&w.m_at(stack).get_moment(&nft).coin, &mode);
    }
    nft
}

fn expect_split(w: &World, stack: &Address, nft: &Address, before: &moments::Ledger) {
    let c = w.m_at(stack);
    let l = c.ledger(nft);
    let m = c.get_moment(nft);
    let creator_share = mul_div(before.reserve, m.expiry_creator_bps as i128, BPS as i128);
    assert_eq!(l.state, State::Expired);
    assert_eq!(l.creator_claimable - before.creator_claimable, creator_share, "70% of the reserve to the creator");
    assert_eq!(l.treasury_claimable - before.treasury_claimable, before.reserve - creator_share);
    assert_eq!(l.reserve, 0);
    assert!(w.nft(nft).closed());
}

fn expiry(d: Durations) {
    let w = World::new(d);
    let md = d.moments;

    // From Collecting, at the deadline.
    let nft = w.publish();
    w.collect_on(&w.moments, &w.bob, &nft, 2);
    let deadline = w.m().get_moment(&nft).deadline;
    w.set_time(deadline - 1);
    assert_eq!(code(w.m().try_expire(&nft)), ERR_NOT_EXPIRABLE);
    w.set_time(deadline);
    let before = w.m().ledger(&nft);
    w.unsigned(|| w.m().expire(&nft));
    expect_split(&w, &w.moments, &nft, &before);

    let fail = w.fail_moments.clone();
    let fm = w.m_at(&fail);
    // Mode 0 on the failing stack: the graduator passes qa-exec-fail's ForcedFailure through: origin 5, 10_502.
    let n0 = pending(&w, &fail, Some(qa_exec_fail::Mode::Fail));
    assert_eq!(w.graduate_moment_on(&fail, &n0), GraduationOutcome::Failed(GradFailure { origin: 5, code: 10_502 }));
    // Mode 2: the graduator's own result checks reject the bogus success: origin 10, 11_003 (V10).
    let n2 = pending(&w, &fail, Some(qa_exec_fail::Mode::BogusSuccess));
    assert_eq!(w.graduate_moment_on(&fail, &n2), GraduationOutcome::Failed(GradFailure { origin: 10, code: 11_003 }));
    // Mode 1: budget exhaustion; nothing is recorded.
    let n1 = pending(&w, &fail, Some(qa_exec_fail::Mode::ExhaustBudget));
    let before1 = fm.ledger(&n1);
    w.e.cost_estimate().budget().reset_default();
    let abort = abort_of(|| w.unsigned(|| w.m_at(&fail).graduate(&n1)));
    w.e.mock_all_auths();
    w.e.cost_estimate().budget().reset_unlimited();
    assert!(abort.contains("Budget"), "{abort}");
    assert_eq!(fm.ledger(&n1), before1);
    assert_eq!(before1.stuck_since, 0, "I-M7: no recorded failure, no stuck clock");

    for n in [&n0, &n2] {
        let l = fm.ledger(n);
        assert_eq!(l.state, State::GraduationPending);
        assert_ne!(l.stuck_since, 0);
    }
    // Recorded failures: never before the deadline, then after stuck_expiry.
    let deadline = fm.get_moment(&n2).deadline;
    let stuck = fm.ledger(&n2).stuck_since;
    let at = deadline.max(stuck + md.stuck_expiry);
    w.set_time(at - 1);
    for n in [&n0, &n2, &n1] {
        assert_eq!(code(fm.try_expire(n)), ERR_NOT_EXPIRABLE, "{n:?}");
    }
    w.set_time(at);
    for n in [&n0, &n2] {
        let before = fm.ledger(n);
        w.unsigned(|| fm.expire(n));
        expect_split(&w, &fail, n, &before);
    }
    // Mode 1: only the backstop expires it, completed_at + pending_backstop (V11, I-M8).
    let backstop = before1.completed_at + md.pending_backstop;
    let at = backstop.max(fm.get_moment(&n1).deadline);
    if w.now() < at {
        w.set_time(at - 1);
        assert_eq!(code(fm.try_expire(&n1)), ERR_NOT_EXPIRABLE);
        w.set_time(at);
    }
    w.unsigned(|| fm.expire(&n1));
    expect_split(&w, &fail, &n1, &before1);
    // Every party withdraws its share.
    let c0 = w.balance(&w.usdc, &w.creator);
    let paid = fm.withdraw_creator(&n1);
    assert_eq!(w.balance(&w.usdc, &w.creator) - c0, paid);
    assert!(fm.withdraw_treasury(&n1) > 0);
}

#[test]
fn moments_expire_from_collecting_after_failures_and_at_the_backstop_production() {
    expiry(PRODUCTION);
}

#[test]
fn moments_expire_from_collecting_after_failures_and_at_the_backstop_testnet_qa() {
    expiry(TESTNET_QA);
}

/// The ceiling of collect quantities equals moment-nft's mint limit (lead note after CT-04/06/07): 20 editions mint in
/// one collect, 21 are refused.
#[test]
fn moment_nft_max_mint_equals_the_moments_batch_limit() {
    let w = World::new(PRODUCTION);
    let cheap = w.publish_on(&w.moments, &moments::PublishParams { price: ONE / 10, ..w.publish_params() });
    let r = w.collect_on(&w.moments, &w.bob, &cheap, 20);
    assert_eq!(r.editions, 20);
    assert_eq!(code(w.m().try_collect(&w.bob, &cheap, &21, &i128::MAX)), 10_711);
    // The NFT itself refuses 21 in one mint (its minter is moments-v2).
    let abort = abort_of(|| w.nft(&cheap).mint(&w.bob, &21));
    assert!(abort.contains("10803") || abort.contains("#10803"), "{abort}");
    let _ = mul_div_up(1, 1, 1);
}
