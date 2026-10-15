//! Launchpad journeys (§18.3) on Soroswap and qa-exec-fail, each run with the production and the testnet-qa
//! durations (§14.3). Owner decision O7: no Aquarius journey.
use dyor_common::{isqrt_u128, mul_div, SOROSWAP_MIN_LIQ};
use dyor_integration_tests::launchpad::{GradFailure, GraduationOutcome, Phase, PositionRef};
use dyor_integration_tests::*;
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{vec, Address};

const ERR_GRAD_INVALID: u32 = 10_134;
const ERR_FALLBACK_TOO_EARLY: u32 = 10_137;
const ERR_FALLBACK_NOT_ALLOWED: u32 = 10_120;
const ERR_GRACE: u32 = 10_121;
const ERR_NOT_STUCK: u32 = 10_119;
const ERR_WRONG_PHASE: u32 = 10_118;
const ERR_CURVE_CLOSED: u32 = 10_112;
const QA_FORCED: GradFailure = GradFailure { origin: 5, code: 10_502 };

fn graduated(o: &GraduationOutcome) -> Address {
    match o {
        GraduationOutcome::Graduated(p) => p.clone(),
        f => panic!("expected a graduation, got {f:?}"),
    }
}

/// I-L9 and I-L6 after a graduation: the locker holds every LP but Soroswap's minimum lock, the pool opens at the
/// curve's final price, nothing is stuck, and the launchpad holds no launch tokens.
fn assert_graduated(w: &World, token: &Address, before: &launchpad::Curve) {
    let c = w.curve(token);
    assert_eq!(c.phase, Phase::Graduated);
    assert_eq!((c.stuck_since, c.real_quote, c.token_reserve), (0, 0, 0));
    let pool = c.pool.clone().unwrap();
    let pair = w.pair(&pool);
    assert_eq!(pair.total_supply(), w.balance(&pool, &w.locker) + SOROSWAP_MIN_LIQ);
    let pos = w.locker().position(&pool).unwrap();
    assert_eq!((pos.lp, pos.harvest_bps), (w.balance(&pool, &w.locker), BPS));
    assert_eq!(w.balance(token, &w.pad), 0, "the excess is burned (L7)");
    assert!(w.token(token).unlocked());
    // The pool opens at the curve's final price (quote_reserve / token_reserve), within rounding.
    let (rt, rq) = w.reserves(&pool, token);
    assert_eq!(rq, before.real_quote);
    let lhs = rq * before.token_reserve;
    let rhs = before.quote_reserve * rt;
    assert!((lhs - rhs).abs() * 1_000_000 <= rhs, "pool price {rq}/{rt} vs curve {}/{}", before.quote_reserve, before.token_reserve);
}

// ------------------------------------------------------------------------------------------------ the happy path

fn happy_path(d: Durations) {
    let w = World::new(d);
    let pad = w.pad();
    for sharing in [true, false] {
        let token = w.launch(&w.usdc, SOROSWAP, sharing);
        let c0 = w.curve(&token);
        w.buy(&w.alice, &token, (c0.threshold) / 3);
        w.buy(&w.bob, &token, c0.threshold / 4);
        // A sell during the curve, then the completing buy (clamped exactly to the threshold, I-L7).
        let bob_tokens = w.balance(&token, &w.bob);
        w.sell(&w.bob, &token, bob_tokens / 2);
        w.complete(&w.carol, &token);
        let before = w.curve(&token);
        assert_eq!(before.real_quote, before.threshold);
        // Buys and sells are closed once completed.
        assert_eq!(code(pad.try_buy(&w.alice, &token, &ONE, &0)), ERR_CURVE_CLOSED);
        let pool = graduated(&w.graduate(&token));
        assert_graduated(&w, &token, &before);
        if sharing {
            assert!(w.token(&token).is_excluded(&pool));
            assert!(w.token(&token).is_excluded(&w.treasury), "the treasury is excluded from birth (V2)");
        }

        // Volume on the router, then the keeper's harvest after one interval.
        w.churn(&token, &w.usdc, 5 * ONE, 4);
        assert!(w.try_harvest(&pool).is_err(), "harvest before the interval");
        w.advance(d.launch.harvest_interval);
        let (t_before, q_before) = (w.balance(&token, &w.treasury), w.balance(&w.usdc, &w.treasury));
        let (rt_before, rq_before) = (w.balance(&token, &w.creator), w.balance(&w.usdc, &w.creator));
        let (tok_t, tok_q) = (w.balance(&token, &token), w.balance(&w.usdc, &token));
        let (base_out, quote_out) = w.harvest(&pool);
        assert!(base_out > 0 && quote_out > 0, "both sides are harvested");
        // Both sides split 50/50 by the launch's pinned protocol share (O1, F1): the treasury first, the
        // remainder to the holders (sharing on) or the recipient (sharing off).
        assert_eq!(w.balance(&token, &w.treasury) - t_before, base_out / 2);
        assert_eq!(w.balance(&w.usdc, &w.treasury) - q_before, quote_out / 2);
        if sharing {
            assert_eq!(w.balance(&token, &token) - tok_t, base_out - base_out / 2);
            assert_eq!(w.balance(&w.usdc, &token) - tok_q, quote_out - quote_out / 2);
            let s = w.token(&token).sharing().unwrap();
            assert!(s.q.queued + s.q.acc > 0 && s.t.queued + s.t.acc > 0);
            // Holders claim both rewards from the next ledger on; the treasury earns nothing (V2).
            w.advance(5);
            let (pq, pt) = w.token(&token).pending_rewards(&w.alice);
            assert!(pq > 0 && pt > 0, "alice's pending rewards {pq} {pt}");
            assert_eq!(w.token(&token).pending_rewards(&w.treasury), (0, 0));
            let (q_alice, t_alice) = (w.balance(&w.usdc, &w.alice), w.balance(&token, &w.alice));
            let (cq, ct) = w.token(&token).claim(&w.alice);
            assert_eq!((cq, ct), (pq, pt));
            assert_eq!(w.balance(&w.usdc, &w.alice) - q_alice, cq);
            assert_eq!(w.balance(&token, &w.alice) - t_alice, ct);
            // What every holder can claim never exceeds what was funded (I-T2).
            let s = w.token(&token).sharing().unwrap();
            let mut owed_q = s.q.queued + s.q.protocol_owed;
            let mut owed_t = s.t.queued + s.t.protocol_owed;
            for h in [&w.alice, &w.bob, &w.carol, &w.trader, &w.creator] {
                let (q, t) = w.token(&token).pending_rewards(h);
                owed_q += q;
                owed_t += t;
            }
            assert!(owed_q <= s.q.funded - s.q.paid && owed_t <= s.t.funded - s.t.paid);
        } else {
            assert_eq!(w.balance(&token, &w.creator) - rt_before, base_out - base_out / 2);
            assert_eq!(w.balance(&w.usdc, &w.creator) - rq_before, quote_out - quote_out / 2);
        }

        // V1: a set_fees after graduation changes neither harvest_payees nor the next harvest's split.
        let payees = pad.harvest_payees(&PositionRef::Launch(token.clone()));
        pad.set_fees(&100, &3_000, &1_000, &vec![&w.e, 9_800u32, 2_500, 300, 30], &5);
        assert_eq!(pad.harvest_payees(&PositionRef::Launch(token.clone())), payees);
        assert_eq!(payees.quote.get_unchecked(0).bps, 5_000);
        w.churn(&token, &w.usdc, 5 * ONE, 4);
        w.advance(d.launch.harvest_interval);
        let (t_before, q_before) = (w.balance(&token, &w.treasury), w.balance(&w.usdc, &w.treasury));
        let (b, q) = w.harvest(&pool);
        assert_eq!(w.balance(&token, &w.treasury) - t_before, b / 2);
        assert_eq!(w.balance(&w.usdc, &w.treasury) - q_before, q / 2);
        pad.set_fees(&100, &5_000, &1_000, &vec![&w.e, 9_800u32, 2_500, 300, 30], &5);

        // V2: a treasury change. The next harvest excludes the new treasury before it pays it launch tokens; the old
        // treasury stays excluded.
        if sharing {
            let new_treasury = Address::generate(&w.e);
            pad.propose_treasury(&new_treasury);
            w.advance(d.launch.timelock);
            pad.apply_treasury();
            assert!(!w.token(&token).is_excluded(&new_treasury));
            w.churn(&token, &w.usdc, 5 * ONE, 4);
            w.advance(d.launch.harvest_interval);
            let (b, _) = w.harvest(&pool);
            assert!(w.token(&token).is_excluded(&new_treasury));
            assert!(w.token(&token).is_excluded(&w.treasury), "a former treasury stays excluded");
            assert_eq!(w.balance(&token, &new_treasury), b / 2);
            w.churn(&token, &w.usdc, 5 * ONE, 4);
            w.advance(d.launch.harvest_interval);
            w.harvest(&pool);
            w.advance(5);
            assert_eq!(w.token(&token).pending_rewards(&new_treasury), (0, 0), "the treasury earns no holder rewards");
            // Booked protocol and launch fees go to the treasury current at the claim.
            let booked = w.curve(&token);
            let (xlm0, q0) = (w.balance(&w.xlm, &new_treasury), w.balance(&w.usdc, &new_treasury));
            pad.claim_protocol_fees(&vec![&w.e, token.clone()]);
            assert_eq!(w.balance(&w.xlm, &new_treasury) - xlm0, booked.launch_fee_due);
            assert_eq!(w.balance(&w.usdc, &new_treasury) - q0, booked.protocol_fees);
            // The protocol's swept rewards (if any) also go to the current treasury.
            match w.token(&token).try_sweep_protocol() {
                Ok(Ok((sq, st))) => assert!(sq >= 0 && st >= 0),
                r => assert_eq!(code(r), 10_208, "NothingToClaim when nothing is owed"),
            }
            // Back to the first treasury for the next round of the loop.
            pad.propose_treasury(&w.treasury);
            w.advance(d.launch.timelock);
            pad.apply_treasury();
        } else {
            // The creator collects the booked creator fees of the curve.
            let fees = w.curve(&token).creator_fees;
            assert!(fees > 0);
            assert_eq!(pad.claim_creator_fees(&token), fees);
        }
    }
}

#[test]
fn launch_buy_complete_graduate_harvest_and_claim_production() {
    happy_path(PRODUCTION);
}

#[test]
fn launch_buy_complete_graduate_harvest_and_claim_testnet_qa() {
    happy_path(TESTNET_QA);
}

// ------------------------------------------------------------------------------------------------ stuck and fallback

fn stuck_and_fallback(d: Durations) {
    let w = World::new(d);
    let pad = w.pad();
    let l = d.launch;

    // Mode 0: a recorded failure, the fallback refused until fallback_delay, then Soroswap.
    let token = w.completed_launch(&w.usdc, QA_FAIL, true);
    let before = w.curve(&token);
    let state = (w.balance(&token, &w.pad), w.balance(&w.usdc, &w.pad), w.token(&token).unlocked());
    assert_eq!(w.graduate(&token), GraduationOutcome::Failed(QA_FORCED));
    let stuck = w.curve(&token).stuck_since;
    assert_eq!(stuck, w.now());
    // I-L5: a recoverable failure changes nothing but stuck_since.
    assert_eq!(launchpad::Curve { stuck_since: 0, ..w.curve(&token) }, before);
    assert_eq!(state, (w.balance(&token, &w.pad), w.balance(&w.usdc, &w.pad), w.token(&token).unlocked()));
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_TOO_EARLY));
    w.advance(l.fallback_delay - 5);
    // A retry keeps stuck_since (B13a).
    assert_eq!(w.graduate(&token), GraduationOutcome::Failed(QA_FORCED));
    assert_eq!(w.curve(&token).stuck_since, stuck);
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_TOO_EARLY));
    w.set_time(stuck + l.fallback_delay);
    let before = w.curve(&token);
    graduated(&w.graduate_fallback(&token));
    assert_graduated(&w, &token, &before);
    assert_eq!(w.curve(&token).graduated_venue, Some(SOROSWAP));

    // Mode 1: budget exhaustion can't be recorded; mark_stuck after grace, then the fallback.
    let token = w.completed_launch(&w.usdc, QA_FAIL, false);
    w.qa().set_mode(&token, &qa_exec_fail::Mode::ExhaustBudget);
    let before = w.curve(&token);
    w.e.cost_estimate().budget().reset_default();
    let abort = abort_of(|| w.unsigned(|| w.pad().graduate(&token)));
    w.e.mock_all_auths();
    w.e.cost_estimate().budget().reset_unlimited();
    assert!(abort.contains("Budget") && abort.contains("ExceededLimit"), "{abort}");
    assert_eq!(w.curve(&token), before, "nothing of the aborted attempt is committed");
    assert_eq!(code(w.unsigned(|| pad.try_mark_stuck(&token))), ERR_GRACE);
    w.set_time(before.completed_at + l.grace);
    w.unsigned(|| pad.mark_stuck(&token));
    let stuck = w.curve(&token).stuck_since;
    assert_eq!(stuck, before.completed_at + l.grace);
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_TOO_EARLY));
    w.set_time(stuck + l.fallback_delay);
    graduated(&w.graduate_fallback(&token));
    assert_graduated(&w, &token, &before);

    // Mode 2: a bogus success aborts with GraduationInvalid; mark_stuck; the fallback.
    let token = w.completed_launch(&w.usdc, QA_FAIL, true);
    w.qa().set_mode(&token, &qa_exec_fail::Mode::BogusSuccess);
    let before = w.curve(&token);
    assert_eq!(w.try_graduate(&token), Err(ERR_GRAD_INVALID));
    assert_eq!(w.curve(&token), before);
    w.set_time(before.completed_at + l.grace);
    w.unsigned(|| pad.mark_stuck(&token));
    w.advance(l.fallback_delay);
    graduated(&w.graduate_fallback(&token));
    assert_graduated(&w, &token, &before);

    // A venue-locked quote: the fallback only after locked_fallback, or after fallback_delay once allowed.
    let token = w.completed_launch(&w.qa_asset, QA_FAIL, true);
    assert!(pad.get_launch(&token).venue_locked);
    assert_eq!(w.graduate(&token), GraduationOutcome::Failed(QA_FORCED));
    let stuck = w.curve(&token).stuck_since;
    w.set_time(stuck + l.fallback_delay);
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_NOT_ALLOWED));
    w.set_time(stuck + l.locked_fallback - 1);
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_NOT_ALLOWED));
    w.set_time(stuck + l.locked_fallback);
    let before = w.curve(&token);
    graduated(&w.graduate_fallback(&token));
    assert_graduated(&w, &token, &before);

    let token = w.completed_launch(&w.qa_asset, QA_FAIL, false);
    assert_eq!(w.graduate(&token), GraduationOutcome::Failed(QA_FORCED));
    pad.allow_fallback(&token);
    assert_eq!(w.try_graduate_fallback(&token), Err(ERR_FALLBACK_TOO_EARLY));
    w.advance(l.fallback_delay);
    graduated(&w.graduate_fallback(&token));
}

#[test]
fn qa_failures_go_stuck_and_graduate_on_the_fallback_production() {
    stuck_and_fallback(PRODUCTION);
}

#[test]
fn qa_failures_go_stuck_and_graduate_on_the_fallback_testnet_qa() {
    stuck_and_fallback(TESTNET_QA);
}

// ------------------------------------------------------------------------------------------------ rescue and refunds

fn rescue_and_refunds(d: Durations) {
    let w = World::new(d);
    let pad = w.pad();
    let l = d.launch;
    let holders = [w.alice.clone(), w.bob.clone(), w.carol.clone(), w.trader.clone(), w.attacker.clone()];

    for by_admin in [true, false] {
        let token = w.launch(&w.usdc, QA_FAIL, by_admin);
        let c = w.curve(&token);
        for (i, h) in holders.iter().enumerate() {
            w.buy(h, &token, c.threshold / (7 + i as i128));
        }
        w.complete(&w.creator, &token);
        assert_eq!(w.graduate(&token), GraduationOutcome::Failed(QA_FORCED));
        let stuck = w.curve(&token).stuck_since;
        assert_eq!(code(w.unsigned(|| pad.try_rescue(&token))), ERR_NOT_STUCK);
        w.set_time(stuck + l.rescue_admin);
        if by_admin {
            // From rescue_admin the admin's signature is needed until rescue_public.
            let abort = abort_of(|| w.unsigned(|| w.pad().rescue(&token)));
            w.e.mock_all_auths();
            assert!(abort.contains("Auth"), "{abort}");
            pad.rescue(&token);
        } else {
            w.set_time(stuck + l.rescue_public);
            w.unsigned(|| pad.rescue(&token));
        }
        let c = w.curve(&token);
        assert_eq!(c.phase, Phase::Rescued);
        assert!(w.token(&token).unlocked());
        assert_eq!(w.balance(&token, &w.pad), 0);
        assert_eq!(c.refund_supply, w.supply(&token));
        assert_eq!(w.try_graduate(&token), Err(ERR_WRONG_PHASE));
        assert_eq!(code(pad.try_buy(&w.alice, &token, &ONE, &0)), ERR_CURVE_CLOSED);

        // Pro-rata refunds in a shuffled order (I-L8): the same rate for everyone, floor.
        let mut everyone: std::vec::Vec<Address> = holders.to_vec();
        everyone.push(w.creator.clone());
        let order = [3usize, 0, 5, 2, 4, 1];
        let mut refunded = 0;
        for &i in &order {
            let h = &everyone[i];
            let tokens = w.balance(&token, h);
            if tokens == 0 {
                continue;
            }
            let q0 = w.balance(&w.usdc, h);
            let out = pad.refund(h, &token, &tokens);
            assert_eq!(out, mul_div(tokens, c.refund_quote, c.refund_supply));
            assert_eq!(w.balance(&w.usdc, h) - q0, out);
            refunded += out;
            assert!(w.curve(&token).refunded <= c.refund_quote);
        }
        // Full exit: every token burned, at most one unit of dust per holder left in the launchpad.
        assert_eq!(w.supply(&token), 0);
        assert_eq!(w.curve(&token).refunded, refunded);
        assert!(c.refund_quote - refunded < everyone.len() as i128);
        // I-L1: what remains covers the booked fees.
        let c = w.curve(&token);
        assert!(w.balance(&w.usdc, &w.pad) >= c.refund_quote - c.refunded + c.creator_fees + c.protocol_fees);
    }
}

#[test]
fn rescue_and_pro_rata_refunds_production() {
    rescue_and_refunds(PRODUCTION);
}

#[test]
fn rescue_and_pro_rata_refunds_testnet_qa() {
    rescue_and_refunds(TESTNET_QA);
}

// ------------------------------------------------------------------------------------------------ third-party pools

fn third_party_pool(d: Durations) {
    let w = World::new(d);
    let (token, pool) = w.graduated_launch(&w.usdc, true);
    let tk = w.token(&token);
    let other = w.xlm.clone();
    // A third party opens a Soroswap pair of the launch token with XLM and seeds it with dust.
    let pair = w.sw_factory().create_pair(&token, &other);
    w.sep41(&token).transfer(&w.alice, &pair, &(100 * ONE));
    w.sep41(&other).transfer(&w.alice, &pair, &ONE);
    w.pair(&pair).deposit(&w.alice);
    assert_eq!(code(tk.try_exclude_pool(&launch_token::VenueKind::Soroswap, &other, &pair)), 10_214);
    // It grows above the floor and earns rewards of both assets before anyone excludes it.
    let big = w.balance(&token, &w.alice) / 2;
    w.sep41(&token).transfer(&w.alice, &pair, &big);
    w.sep41(&other).transfer(&w.alice, &pair, &(100 * ONE));
    w.pair(&pair).deposit(&w.alice);
    w.churn(&token, &w.usdc, 5 * ONE, 4);
    w.advance(d.launch.harvest_interval);
    w.harvest(&pool);
    w.advance(5);
    let (sq, st) = tk.pending_rewards(&pair);
    assert!(sq > 0 && st > 0, "the pair earned {sq} {st}");
    let before = tk.sharing().unwrap();
    assert!(tk.exclude_pool(&launch_token::VenueKind::Soroswap, &other, &pair));
    assert!(tk.is_excluded(&pair));
    let after = tk.sharing().unwrap();
    assert_eq!(after.q.protocol_owed - before.q.protocol_owed, sq);
    assert_eq!(after.t.protocol_owed - before.t.protocol_owed, st);
    assert_eq!(tk.pending_rewards(&pair), (0, 0));
    // The stranded rewards go to the treasury with sweep_protocol.
    let (q0, t0) = (w.balance(&w.usdc, &w.treasury), w.balance(&token, &w.treasury));
    let (pq, pt) = tk.sweep_protocol();
    assert!(pq >= sq && pt >= st);
    assert_eq!(w.balance(&w.usdc, &w.treasury) - q0, pq);
    assert_eq!(w.balance(&token, &w.treasury) - t0, pt);
    // No DEX pool outside the excluded set holds launch tokens above the floor.
    for p in [&pool, &pair] {
        assert!(tk.is_excluded(p));
    }
    // Excluding it again is a no-op.
    assert!(!tk.exclude_pool(&launch_token::VenueKind::Soroswap, &other, &pair));
}

#[test]
fn a_third_party_pool_is_excluded_above_the_floor_and_its_rewards_go_to_the_treasury_production() {
    third_party_pool(PRODUCTION);
}

#[test]
fn a_third_party_pool_is_excluded_above_the_floor_and_its_rewards_go_to_the_treasury_testnet_qa() {
    third_party_pool(TESTNET_QA);
}

// ------------------------------------------------------------------------------------------------ recipient change

/// The model of §8.2 for a position: (current, growth, take, rounds to drain the growth) at the pair's reserves.
fn model(w: &World, pool: &Address) -> (i128, i128, i128, i128) {
    let p = w.locker().position(pool).unwrap();
    let pair = w.pair(pool);
    let (r0, r1) = pair.get_reserves();
    let total = pair.total_supply();
    let current = isqrt_u128(r0 as u128 * r1 as u128) as i128 * p.lp / total;
    let growth = current - p.principal;
    let cap = current * 50 / BPS as i128;
    let take = growth.min(cap);
    let rounds = if cap > 0 { (growth + cap - 1) / cap } else { 0 };
    (current, growth, take, rounds)
}

fn recipient_change(d: Durations) {
    let w = World::new(d);
    let pad = w.pad();
    let (token, pool) = w.graduated_launch(&w.usdc, false);
    let new = Address::generate(&w.e);
    // Growth earned before the change but harvested after it goes to the new recipient (F3, the declared exception).
    w.churn(&token, &w.usdc, 5 * ONE, 4);
    pad.transfer_creator_fee_recipient(&token, &new);
    w.advance(d.launch.harvest_interval);
    let (c_t, c_q) = (w.balance(&token, &w.creator), w.balance(&w.usdc, &w.creator));
    let (b, q) = w.harvest(&pool);
    assert_eq!(w.balance(&token, &new), b - b / 2);
    assert_eq!(w.balance(&w.usdc, &new), q - q / 2);
    assert_eq!((w.balance(&token, &w.creator), w.balance(&w.usdc, &w.creator)), (c_t, c_q));

    // V7: volume above the round cap for several intervals leaves a backlog that one harvest can't take; what is
    // left after the harvest is the residual the backend reports (growth beyond one round, drained 0.5% a round).
    let quote_side = w.reserves(&pool, &w.usdc).0;
    for _ in 0..3 {
        w.churn(&token, &w.usdc, quote_side, 8);
        w.advance(d.launch.harvest_interval);
        let (current, growth, take, _) = model(&w, &pool);
        assert!(growth > current * 50 / BPS as i128, "the round cap binds: growth {growth}, current {current}");
        w.harvest(&pool);
        let (_, residual, _, rounds) = model(&w, &pool);
        assert!(residual > 0 && rounds >= 1);
        // The locker's own view reports the same backlog.
        let (g, _, _, _, next_at) = w.locker().harvestable(&pool);
        assert_eq!(g, residual);
        assert_eq!(next_at, w.now() + d.launch.harvest_interval);
        assert!(residual >= growth - take - 2, "{residual} vs {growth} − {take}");
    }
    // At zero volume the backlog drains by at most one round per interval.
    let (_, mut residual, _, mut rounds) = model(&w, &pool);
    while residual > 0 && rounds > 0 {
        w.advance(d.launch.harvest_interval);
        if w.try_harvest(&pool).is_err() {
            break;
        }
        let (_, r, _, n) = model(&w, &pool);
        assert!(n <= rounds && r < residual);
        residual = r;
        rounds = n;
    }
}

#[test]
fn a_recipient_change_between_harvests_pays_the_new_recipient_and_the_backlog_drains_production() {
    recipient_change(PRODUCTION);
}

#[test]
fn a_recipient_change_between_harvests_pays_the_new_recipient_and_the_backlog_drains_testnet_qa() {
    recipient_change(TESTNET_QA);
}
