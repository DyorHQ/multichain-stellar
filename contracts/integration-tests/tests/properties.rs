//! Stateful property tests across contracts (§18.2), on the dist WASMs: random sequences of calls against a fresh
//! deployment per case, with the invariants of §5.8, §6.5, §8.2 and §9.5 checked after every step. Each test uses
//! proptest's default configuration, so `PROPTEST_CASES` sets the number of cases (1,000 in CI).
//!
//! | Test | Invariants |
//! |---|---|
//! | `curve_trades_keep_the_launchpad_solvent_and_refund_pro_rata` | I-L1, I-L2, I-L3, I-L4, I-L7, I-L8, I-L9 |
//! | `failed_graduations_change_nothing_and_the_fallback_waits` | I-L5, I-L12 |
//! | `holder_rewards_follow_the_pro_rata_model` | I-T1, I-T2, I-T3, I-T4, I-T5, I-T7, I-T8 |
//! | `locked_positions_keep_their_principal_and_compound_in_ratio` | I-K1, the compounding ratio (F7) |
//! | `moments_stay_solvent_mint_within_supply_and_vest_monotonically` | I-M1, I-M2, I-M3, I-M4, I-M5, I-M6 |
//! | `pending_moments_expire_only_by_the_rules` | I-M7, I-M8 |
//!
//! The other invariants are structural and have their tests elsewhere: I-L6 and I-L9's opening price (journeys and
//! the squat probe), I-L10 (the hot-key probe), I-L11 and I-T6 (the quote and squat probes), I-T9 (the reward-pool
//! probes), I-T10 (the launch journey). The rounding of each `try_` and panic is caught per call: no test replaces the
//! process-wide panic hook (lead ruling).
use dyor_common::{isqrt_u128, mul_div, mul_div_up, BPS as COMMON_BPS, MAX_HARVEST_ROUND_BPS};
use dyor_integration_tests::launchpad::{Curve, GraduationOutcome, Phase};
use dyor_integration_tests::*;
use proptest::prelude::*;
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{vec, Address};
use std::collections::BTreeMap;

const BPSI: i128 = COMMON_BPS as i128;

fn durations(qa: bool) -> Durations {
    if qa {
        TESTNET_QA
    } else {
        PRODUCTION
    }
}

// ================================================================================================ launches

#[derive(Clone, Debug)]
enum Trade {
    /// A buy of this many ‱ of the threshold by trader i.
    Buy(usize, i128),
    /// A sell of this many % of trader i's tokens.
    Sell(usize, u32),
    /// A buy followed by a sell of exactly what it bought (I-L3).
    RoundTrip(usize, i128),
    /// The admin changes the fees for future launches (I-L4).
    SetFees(u32, u32),
    Wait(u64),
}

fn trade() -> impl Strategy<Value = Trade> {
    prop_oneof![
        5 => (0..4usize, 1i128..=4_000).prop_map(|(i, a)| Trade::Buy(i, a)),
        3 => (0..4usize, 1u32..=100).prop_map(|(i, p)| Trade::Sell(i, p)),
        2 => (0..4usize, 1i128..=2_000).prop_map(|(i, a)| Trade::RoundTrip(i, a)),
        1 => (0u32..=500, 0u32..=10_000).prop_map(|(f, s)| Trade::SetFees(f, s)),
        1 => (0u64..=40).prop_map(Trade::Wait),
    ]
}

fn traders(w: &World) -> [Address; 4] {
    [w.alice.clone(), w.bob.clone(), w.carol.clone(), w.trader.clone()]
}

/// I-L1 for one launch: the launchpad's balance of each asset covers what the curve owes in it.
fn assert_solvent(w: &World, token: &Address, quote: &Address) {
    let c = w.curve(token);
    let owed = c.real_quote + c.refund_quote - c.refunded + c.creator_fees + c.protocol_fees;
    let xlm_owed = c.launch_fee_due + if *quote == w.xlm { owed } else { 0 };
    assert!(w.balance(quote, &w.pad) >= owed, "I-L1: {} < {owed}", w.balance(quote, &w.pad));
    assert!(w.balance(&w.xlm, &w.pad) >= xlm_owed, "I-L1 (XLM): {} < {xlm_owed}", w.balance(&w.xlm, &w.pad));
}

/// I-L2 and I-L7 while the curve is open or completed.
fn assert_curve(w: &World, token: &Address) {
    let c = w.curve(token);
    assert!(c.real_quote <= c.threshold, "I-L7");
    if c.phase == Phase::Completed {
        assert_eq!(c.real_quote, c.threshold, "I-L7: completion is exact");
    }
    if matches!(c.phase, Phase::Curve | Phase::Completed) {
        assert!(w.balance(token, &w.pad) >= c.token_reserve, "I-L2");
    }
}

proptest! {
    /// Random trades on a launch (either quote, sharing on or off, a creator fee, inside or after the snipe window),
    /// then either a graduation on Soroswap or a forced failure, a rescue and pro-rata refunds in a random order and
    /// random parts.
    #[test]
    fn curve_trades_keep_the_launchpad_solvent_and_refund_pro_rata(
        usdc in any::<bool>(),
        sharing in any::<bool>(),
        creator_fee in 0u32..=1_000,
        start in 0u64..=25,
        trades in prop::collection::vec(trade(), 1..12),
        rescue in any::<bool>(),
        order in Just(std::vec![0usize, 1, 2, 3, 4]).prop_shuffle(),
        parts in prop::collection::vec(1u32..=100, 5),
    ) {
        let w = World::new(PRODUCTION);
        let pad = w.pad();
        let quote = if usdc { w.usdc.clone() } else { w.xlm.clone() };
        let venue = if rescue { QA_FAIL } else { SOROSWAP };
        let p = launchpad::LaunchParams { creator_fee_bps: creator_fee, ..w.params(&quote, venue, sharing) };
        let token = w.launch_with(&w.creator, &p);
        let pinned = pad.get_launch(&token);
        w.advance(start);
        let who = traders(&w);
        for t in &trades {
            let c = w.curve(&token);
            if c.phase != Phase::Curve {
                break;
            }
            match t {
                Trade::Buy(i, a) => {
                    w.buy(&who[*i], &token, c.threshold * a / 10_000 + 1);
                }
                Trade::Sell(i, pct) => {
                    let amount = w.balance(&token, &who[*i]) * *pct as i128 / 100;
                    // Only what the curve can pay: a sell above its real quote is refused, like its quote.
                    if amount > 0 && matches!(pad.try_quote_sell(&token, &amount), Ok(Ok(_))) {
                        w.sell(&who[*i], &token, amount);
                    }
                }
                Trade::RoundTrip(i, a) => {
                    let paid = c.threshold * a / 10_000 + 1;
                    let q0 = w.balance(&quote, &who[*i]);
                    let got = w.buy(&who[*i], &token, paid);
                    if w.curve(&token).phase == Phase::Curve && got > 0 {
                        w.sell(&who[*i], &token, got);
                        prop_assert!(w.balance(&quote, &who[*i]) <= q0, "I-L3: a buy then a sell returned more");
                    }
                }
                Trade::SetFees(fee, share) => {
                    pad.set_fees(fee, share, &1_000, &vec![&w.e, 9_800u32, 2_500, 300, 30], &5);
                    prop_assert_eq!(pad.get_launch(&token), pinned.clone(), "I-L4");
                }
                Trade::Wait(s) => w.advance(*s),
            }
            assert_solvent(&w, &token, &quote);
            assert_curve(&w, &token);
        }
        prop_assert_eq!(pad.get_launch(&token), pinned, "I-L4");
        if w.curve(&token).phase == Phase::Curve {
            w.complete(&w.carol, &token);
        }
        assert_curve(&w, &token);
        assert_solvent(&w, &token, &quote);

        if !rescue {
            let before = w.curve(&token);
            let pool = match w.graduate(&token) {
                GraduationOutcome::Graduated(p) => p,
                f => panic!("{f:?}"),
            };
            // I-L9.
            let c = w.curve(&token);
            prop_assert_eq!((c.phase, c.stuck_since), (Phase::Graduated, 0));
            prop_assert_eq!(w.pair(&pool).total_supply(), w.balance(&pool, &w.locker) + dyor_common::SOROSWAP_MIN_LIQ);
            prop_assert_eq!(w.reserves(&pool, &quote).0, before.real_quote);
            prop_assert_eq!(w.balance(&token, &w.pad), 0);
            assert_solvent(&w, &token, &quote);
            return Ok(());
        }

        // A recorded failure, then the rescue and pro-rata refunds (I-L8, I-L1).
        prop_assert!(matches!(w.graduate(&token), GraduationOutcome::Failed(_)));
        w.set_time(w.curve(&token).stuck_since + w.d.launch.rescue_admin);
        pad.rescue(&token);
        let c = w.curve(&token);
        prop_assert_eq!(c.phase, Phase::Rescued);
        assert_solvent(&w, &token, &quote);
        let mut everyone = who.to_vec();
        everyone.push(w.creator.clone());
        let mut refunded = 0;
        for (k, &i) in order.iter().enumerate() {
            let h = &everyone[i];
            let all = w.balance(&token, h);
            let first = all * parts[k] as i128 / 100;
            for tokens in [first, all - first] {
                if tokens == 0 {
                    continue;
                }
                let q0 = w.balance(&quote, h);
                let out = pad.refund(h, &token, &tokens);
                prop_assert_eq!(out, mul_div(tokens, c.refund_quote, c.refund_supply), "I-L8");
                prop_assert_eq!(w.balance(&quote, h) - q0, out);
                refunded += out;
                prop_assert!(w.curve(&token).refunded <= c.refund_quote, "I-L8");
                assert_solvent(&w, &token, &quote);
            }
        }
        prop_assert_eq!(w.supply(&token), 0);
        prop_assert_eq!(w.curve(&token).refunded, refunded);
    }
}

// ------------------------------------------------------------------------------------------------ graduation attempts

#[derive(Clone, Debug)]
enum Attempt {
    Graduate,
    Fallback,
    MarkStuck,
    Allow,
    Wait(u64),
}

fn attempt(d: Durations) -> impl Strategy<Value = Attempt> {
    let l = d.launch;
    let longest = l.locked_fallback.max(l.fallback_delay).max(l.grace) + 60;
    prop_oneof![
        3 => Just(Attempt::Graduate),
        3 => Just(Attempt::Fallback),
        1 => Just(Attempt::MarkStuck),
        1 => Just(Attempt::Allow),
        4 => (1u64..=longest / 2).prop_map(Attempt::Wait),
    ]
}

/// Everything a failed attempt must leave as it was (I-L5): the curve apart from `stuck_since`, the launchpad's
/// balances and the token's lock.
fn snapshot(w: &World, token: &Address, quote: &Address) -> (Curve, i128, i128, bool) {
    let c = Curve { stuck_since: 0, ..w.curve(token) };
    (c, w.balance(token, &w.pad), w.balance(quote, &w.pad), w.token(token).unlocked())
}

fn attempts_case(qa: bool, bogus: bool, locked: bool, steps: std::vec::Vec<Attempt>) -> Result<(), TestCaseError> {
    let d = durations(qa);
    let l = d.launch;
    let w = World::new(d);
    let pad = w.pad();
    let quote = if locked { w.qa_asset.clone() } else { w.usdc.clone() };
    let token = w.completed_launch(&quote, QA_FAIL, true);
    if bogus {
        w.qa().set_mode(&token, &qa_exec_fail::Mode::BogusSuccess);
    }
    prop_assert_eq!(pad.get_launch(&token).venue_locked, locked);
    let mut before = snapshot(&w, &token, &quote);
    let completed_at = w.curve(&token).completed_at;
    for s in steps {
        let c = w.curve(&token);
        let now = w.now();
        match s {
            Attempt::Graduate => {
                let r = w.try_graduate(&token);
                if bogus {
                    // The result checks reject the bogus success: the whole call aborts.
                    prop_assert_eq!(r, Err(10_134));
                    prop_assert_eq!(w.curve(&token), c);
                } else {
                    prop_assert!(matches!(r, Ok(GraduationOutcome::Failed(_))), "{r:?}");
                    // stuck_since is set once, by the first recorded failure.
                    let expected = if c.stuck_since == 0 { now } else { c.stuck_since };
                    prop_assert_eq!(w.curve(&token).stuck_since, expected);
                }
                prop_assert_eq!(snapshot(&w, &token, &quote), before.clone(), "I-L5");
            }
            Attempt::MarkStuck => {
                let r = w.unsigned(|| pad.try_mark_stuck(&token));
                if c.stuck_since != 0 {
                    prop_assert_eq!(code(r), 10_122);
                } else if now < completed_at + l.grace {
                    prop_assert_eq!(code(r), 10_121);
                } else {
                    ok(r);
                    prop_assert_eq!(w.curve(&token).stuck_since, completed_at + l.grace);
                }
                prop_assert_eq!(snapshot(&w, &token, &quote), before.clone(), "I-L5");
            }
            // The one admin power over a live launch (I-L4): it changes only fallback_allowed.
            Attempt::Allow => {
                pad.allow_fallback(&token);
                before.0.fallback_allowed = true;
                prop_assert_eq!(snapshot(&w, &token, &quote), before.clone());
            }
            Attempt::Wait(s) => w.advance(s),
            Attempt::Fallback => {
                let r = w.try_graduate_fallback(&token);
                // I-L12: never before stuck_since + fallback_delay, and a venue-locked launch not yet allowed never
                // before stuck_since + locked_fallback.
                let open_at = if c.stuck_since == 0 {
                    None
                } else if locked && !c.fallback_allowed {
                    Some((c.stuck_since + l.fallback_delay).max(c.stuck_since + l.locked_fallback))
                } else {
                    Some(c.stuck_since + l.fallback_delay)
                };
                match open_at {
                    None => prop_assert_eq!(r, Err(10_119)),
                    Some(at) if now < at => {
                        prop_assert!(r == Err(10_137) || r == Err(10_120), "{r:?}");
                        prop_assert_eq!(snapshot(&w, &token, &quote), before.clone());
                    }
                    Some(_) => {
                        prop_assert!(matches!(r, Ok(GraduationOutcome::Graduated(_))), "{r:?}");
                        let g = w.curve(&token);
                        prop_assert_eq!((g.phase, g.stuck_since, g.graduated_venue), (Phase::Graduated, 0, Some(SOROSWAP)));
                        return Ok(());
                    }
                }
            }
        }
    }
    Ok(())
}

proptest! {
    /// A launch on qa-exec-fail (recorded failures, or bogus successes the result checks abort), on a free or a
    /// venue-locked quote, through random graduate, graduate_fallback, mark_stuck and allow_fallback calls at random
    /// times, with either duration set.
    #[test]
    fn failed_graduations_change_nothing_and_the_fallback_waits(
        qa in any::<bool>(),
        bogus in any::<bool>(),
        locked in any::<bool>(),
        steps in prop::collection::vec(attempt(PRODUCTION), 1..16),
        qa_steps in prop::collection::vec(attempt(TESTNET_QA), 1..16),
    ) {
        attempts_case(qa, bogus, locked, if qa { qa_steps } else { steps })?;
    }
}

// ================================================================================================ holder rewards

#[derive(Clone, Debug)]
enum Holding {
    Transfer(usize, usize, u32),
    SelfTransfer(usize, u32),
    Burn(usize, u32),
    /// The locker notifies this much quote (whole units of 0.01).
    NotifyQuote(i128),
    /// Holder i sends this % of its tokens to the token's own address, which the locker notifies.
    NotifyToken(usize, u32),
    /// A balance held only within one ledger, across a notify in that ledger (I-T3).
    Flash(u32),
    Claim(usize),
    Exclude(usize),
    Advance(u32),
}

fn holding() -> impl Strategy<Value = Holding> {
    prop_oneof![
        4 => (0..4usize, 0..4usize, 1u32..=100).prop_map(|(a, b, p)| Holding::Transfer(a, b, p)),
        1 => (0..4usize, 1u32..=100).prop_map(|(a, p)| Holding::SelfTransfer(a, p)),
        1 => (0..4usize, 1u32..=50).prop_map(|(a, p)| Holding::Burn(a, p)),
        3 => (1i128..=1_000_000).prop_map(Holding::NotifyQuote),
        2 => (0..4usize, 1u32..=20).prop_map(|(a, p)| Holding::NotifyToken(a, p)),
        1 => (1u32..=50).prop_map(Holding::Flash),
        3 => (0..4usize).prop_map(Holding::Claim),
        1 => (0..4usize).prop_map(Holding::Exclude),
        3 => (1u32..=3).prop_map(Holding::Advance),
    ]
}

/// The reference model of §6.2 in plain integers: a notified amount waits until a later ledger, then goes to the
/// eligible balances of that moment pro rata (floored), or to the protocol below one token eligible.
#[derive(Default)]
struct Model {
    bal: BTreeMap<usize, i128>,
    excluded: BTreeMap<usize, bool>,
    eligible: i128,
    /// (quote, token) queued, and the ledger of the last notify.
    queued: (i128, i128),
    queued_ledger: u32,
    /// What each holder has earned since the start, per asset.
    earned: BTreeMap<usize, (i128, i128)>,
    claimed: BTreeMap<usize, (i128, i128)>,
    releases: i128,
}

const MIN_ELIGIBLE: i128 = ONE;

impl Model {
    /// The release a call in ledger `seq` makes first (or a view previews): `(to holders, to the protocol)`.
    fn release(&mut self, seq: u32) {
        if seq <= self.queued_ledger || self.queued == (0, 0) {
            return;
        }
        let (q, t) = core::mem::take(&mut self.queued);
        if self.eligible >= MIN_ELIGIBLE {
            self.releases += 1;
            for (h, b) in &self.bal {
                if !self.excluded.get(h).copied().unwrap_or(false) {
                    let e = self.earned.entry(*h).or_default();
                    e.0 += q * b / self.eligible;
                    e.1 += t * b / self.eligible;
                }
            }
        }
    }

    fn moved(&mut self, h: usize, delta: i128) {
        *self.bal.entry(h).or_default() += delta;
        if !self.excluded.get(&h).copied().unwrap_or(false) {
            self.eligible += delta;
        }
    }
}

struct Sharing<'a> {
    w: &'a World,
    token: Address,
    who: [Address; 4],
}

impl Sharing<'_> {
    fn pending(&self, i: usize) -> (i128, i128) {
        self.w.token(&self.token).pending_rewards(&self.who[i])
    }

    /// I-T1, I-T2, I-T5 and the model, after every step.
    fn check(&self, m: &Model) -> Result<(), TestCaseError> {
        let w = self.w;
        let tk = w.token(&self.token);
        let s = tk.sharing().unwrap();
        // I-T1.
        prop_assert!(w.balance(&w.usdc, &self.token) >= s.q.funded - s.q.paid, "I-T1 quote");
        prop_assert!(w.balance(&self.token, &self.token) >= s.t.funded - s.t.paid, "I-T1 token");
        // I-T5: every eligible unit is a tracked holder's (the pool, the treasury, the launchpad, the locker and the
        // token itself are excluded), and the balances are the model's.
        let mut eligible = 0;
        for i in 0..4 {
            let b = w.balance(&self.token, &self.who[i]);
            prop_assert_eq!(b, m.bal[&i]);
            if !m.excluded.get(&i).copied().unwrap_or(false) {
                eligible += b;
            }
        }
        prop_assert_eq!(s.eligible, eligible, "I-T5");
        prop_assert_eq!(s.eligible, m.eligible);
        // I-T2, with the views previewing a release this ledger would make.
        let due = w.seq() > s.queued_ledger;
        let pending: std::vec::Vec<(i128, i128)> = (0..4).map(|i| self.pending(i)).collect();
        let pq: i128 = pending.iter().map(|p| p.0).sum();
        let pt: i128 = pending.iter().map(|p| p.1).sum();
        let in_pending = due && s.eligible >= MIN_ELIGIBLE;
        let lhs_q = pq + s.q.protocol_owed + if in_pending { 0 } else { s.q.queued };
        let lhs_t = pt + s.t.protocol_owed + if in_pending { 0 } else { s.t.queued };
        prop_assert!(lhs_q <= s.q.funded - s.q.paid, "I-T2 quote: {lhs_q} > {}", s.q.funded - s.q.paid);
        prop_assert!(lhs_t <= s.t.funded - s.t.paid, "I-T2 token: {lhs_t} > {}", s.t.funded - s.t.paid);
        // Each holder's rewards equal the model's pro-rata share within 2 units per release, +1 (§18.2, lead ruling
        // after CT-01..03).
        let mut preview = Model { bal: m.bal.clone(), excluded: m.excluded.clone(), ..Model::default() };
        preview.eligible = m.eligible;
        preview.queued = m.queued;
        preview.queued_ledger = m.queued_ledger;
        preview.earned = m.earned.clone();
        preview.releases = m.releases;
        preview.release(w.seq());
        let tol = 2 * preview.releases + 1;
        for (i, &(q, t)) in pending.iter().enumerate() {
            if m.excluded.get(&i).copied().unwrap_or(false) {
                continue;
            }
            let (cq, ct) = m.claimed.get(&i).copied().unwrap_or_default();
            let (eq, et) = preview.earned.get(&i).copied().unwrap_or_default();
            prop_assert!((q + cq - eq).abs() <= tol, "holder {i} quote: {} vs model {eq} (±{tol})", q + cq);
            prop_assert!((t + ct - et).abs() <= tol, "holder {i} token: {} vs model {et} (±{tol})", t + ct);
        }
        Ok(())
    }
}

proptest! {
    /// A graduated sharing launch whose four holders transfer, self-transfer, burn and claim while the locker notifies
    /// quote and launch-token rewards and holders are excluded, across random ledgers.
    #[test]
    fn holder_rewards_follow_the_pro_rata_model(
        buys in prop::collection::vec(1i128..=3_000, 4),
        steps in prop::collection::vec(holding(), 1..16),
    ) {
        let w = World::new(PRODUCTION);
        let who = traders(&w);
        let token = w.launch(&w.usdc, SOROSWAP, true);
        let c = w.curve(&token);
        for (i, a) in buys.iter().enumerate() {
            w.buy(&who[i], &token, c.threshold * a / 10_000 + 1);
        }
        if w.curve(&token).phase == Phase::Curve {
            w.complete(&w.carol, &token);
        }
        prop_assert!(matches!(w.graduate(&token), GraduationOutcome::Graduated(_)));
        let tk = w.token(&token);
        // A clean start: every queue released and every reward claimed.
        w.advance(5);
        for h in &who {
            let _ = tk.try_claim(h);
        }
        let mut m = Model::default();
        for (i, h) in who.iter().enumerate() {
            m.bal.insert(i, w.balance(&token, h));
        }
        m.eligible = tk.sharing().unwrap().eligible;
        m.queued_ledger = w.seq();
        let sh = Sharing { w: &w, token: token.clone(), who: who.clone() };
        sh.check(&m)?;
        let locker = w.locker.clone();
        let mut excluded = 0;
        for s in steps {
            let own = w.balance(&token, &token);
            let mut claimed = false;
            match s {
                Holding::Transfer(a, b, pct) => {
                    let x = m.bal[&a] * pct as i128 / 100;
                    if x > 0 {
                        m.release(w.seq());
                        w.sep41(&token).transfer(&who[a], &who[b], &x);
                        m.moved(a, -x);
                        m.moved(b, x);
                    }
                }
                Holding::SelfTransfer(a, pct) => {
                    let x = (m.bal[&a] * pct as i128 / 100).max(1).min(m.bal[&a]);
                    let before: std::vec::Vec<_> = (0..4).map(|i| sh.pending(i)).collect();
                    m.release(w.seq());
                    w.sep41(&token).transfer(&who[a], &who[a], &x);
                    let after: std::vec::Vec<_> = (0..4).map(|i| sh.pending(i)).collect();
                    prop_assert_eq!(before, after, "I-T4: a self-transfer changed what someone is owed");
                }
                Holding::Burn(a, pct) => {
                    let x = m.bal[&a] * pct as i128 / 100;
                    if x > 0 {
                        m.release(w.seq());
                        w.sep41(&token).burn(&who[a], &x);
                        m.moved(a, -x);
                    }
                }
                Holding::NotifyQuote(cents) => {
                    let x = cents * ONE / 100;
                    m.release(w.seq());
                    w.mint(&w.usdc, &token, x);
                    tk.notify_reward(&locker, &w.usdc, &x);
                    m.queued.0 += x;
                    m.queued_ledger = w.seq();
                }
                Holding::NotifyToken(a, pct) => {
                    let x = m.bal[&a] * pct as i128 / 100;
                    if x > 0 {
                        m.release(w.seq());
                        w.sep41(&token).transfer(&who[a], &token, &x);
                        m.moved(a, -x);
                        tk.notify_reward(&locker, &token, &x);
                        m.queued.1 += x;
                        m.queued_ledger = w.seq();
                    }
                }
                Holding::Flash(pct) => {
                    // A notify, then a fresh account holds tokens only within this ledger.
                    let x = m.bal[&0] * pct as i128 / 100;
                    let flash = Address::generate(&w.e);
                    m.release(w.seq());
                    w.mint(&w.usdc, &token, ONE);
                    tk.notify_reward(&locker, &w.usdc, &ONE);
                    m.queued.0 += ONE;
                    m.queued_ledger = w.seq();
                    if x > 0 {
                        w.sep41(&token).transfer(&who[0], &flash, &x);
                        w.sep41(&token).transfer(&flash, &who[0], &x);
                    }
                    w.advance(5);
                    prop_assert_eq!(tk.pending_rewards(&flash), (0, 0), "I-T3: a one-ledger balance earned");
                }
                Holding::Claim(a) => {
                    let (q, t) = sh.pending(a);
                    m.release(w.seq());
                    if m.excluded.get(&a).copied().unwrap_or(false) {
                        prop_assert_eq!(code(tk.try_claim(&who[a])), 10_212);
                    } else if q == 0 && t == 0 {
                        prop_assert_eq!(code(tk.try_claim(&who[a])), 10_208);
                    } else {
                        prop_assert_eq!(tk.claim(&who[a]), (q, t));
                        let c = m.claimed.entry(a).or_default();
                        c.0 += q;
                        c.1 += t;
                        m.moved(a, t);
                        claimed = true;
                    }
                }
                Holding::Exclude(a) => {
                    if excluded < 2 && !m.excluded.get(&a).copied().unwrap_or(false) {
                        let s0 = tk.sharing().unwrap();
                        let (q, t) = sh.pending(a);
                        let due = w.seq() > s0.queued_ledger && s0.eligible < MIN_ELIGIBLE;
                        let extra = if due { (s0.q.queued, s0.t.queued) } else { (0, 0) };
                        m.release(w.seq());
                        // The launchpad's exclusion: the path exclude_pool takes once a pool is verified.
                        prop_assert!(tk.exclude(&who[a]));
                        prop_assert!(tk.is_excluded(&who[a]));
                        let s1 = tk.sharing().unwrap();
                        prop_assert_eq!(sh.pending(a), (0, 0), "I-T7");
                        prop_assert_eq!(s1.q.protocol_owed - s0.q.protocol_owed, q + extra.0, "I-T7 quote");
                        prop_assert_eq!(s1.t.protocol_owed - s0.t.protocol_owed, t + extra.1, "I-T7 token");
                        m.eligible -= m.bal[&a];
                        m.excluded.insert(a, true);
                        excluded += 1;
                    }
                }
                Holding::Advance(n) => w.advance(5 * n as u64),
            }
            // I-T8: only a claim (or the protocol's sweep) lowers the token's own balance.
            if !claimed {
                prop_assert!(w.balance(&token, &token) >= own, "I-T8");
            }
            sh.check(&m)?;
        }
    }
}

// ================================================================================================ the locker

#[derive(Clone, Debug)]
enum Market {
    /// A swap of this many % of the pool's reserve, buying the base (true) or selling it.
    Swap(bool, u32),
    Wait(u64),
    Harvest,
}

fn market() -> impl Strategy<Value = Market> {
    prop_oneof![
        5 => (any::<bool>(), 1u32..=120).prop_map(|(b, p)| Market::Swap(b, p)),
        2 => (1u64..=7_200).prop_map(Market::Wait),
        3 => Just(Market::Harvest),
    ]
}

/// The position's √k value at the pool's reserves now.
fn value(w: &World, pool: &Address, lp: i128) -> (i128, i128, i128) {
    let pair = w.pair(pool);
    let (r0, r1) = pair.get_reserves();
    let total = pair.total_supply();
    let root = isqrt_u128(r0 as u128 * r1 as u128) as i128;
    (dyor_common::mul_div_u256(&w.e, root, lp, total), root, total)
}

proptest! {
    /// A graduated launch (sharing on or off, harvest_bps 10,000) or a graduated Moment (6,667) under random swaps in
    /// both directions, random waits and harvests: every harvest takes min(growth·hb/BPS, 0.5% of the value), compounds
    /// exactly ⌈take·(BPS − hb)/hb⌉ (capped by what the position still holds), and the position's value never falls
    /// below its principal (I-K1).
    #[test]
    fn locked_positions_keep_their_principal_and_compound_in_ratio(
        moment in any::<bool>(),
        sharing in any::<bool>(),
        steps in prop::collection::vec(market(), 1..24),
    ) {
        let w = World::new(PRODUCTION);
        let (base, pool) = if moment {
            let (nft, pool) = w.graduated_moment();
            (w.m().get_moment(&nft).coin, pool)
        } else {
            let (token, pool) = w.graduated_launch(&w.usdc, sharing);
            (token, pool)
        };
        let hb = if moment { MOMENT_HARVEST_BPS } else { BPS } as i128;
        w.mint(&w.usdc, &w.trader, 10_000_000 * ONE);
        for s in steps {
            let p = w.locker().position(&pool).unwrap();
            match s {
                Market::Swap(buy, pct) => {
                    let (rb, rq) = w.reserves(&pool, &base);
                    // A swap the router refuses (an output of zero) changes nothing.
                    if buy {
                        let x = rq * pct as i128 / 100 + 1;
                        w.try_swap(&w.trader, &w.usdc, &base, x);
                    } else {
                        let x = (rb * pct as i128 / 100).min(w.balance(&base, &w.trader));
                        if x > 0 {
                            w.try_swap(&w.trader, &base, &w.usdc, x);
                        }
                    }
                }
                Market::Wait(s) => w.advance(s),
                Market::Harvest => {
                    let (current, root, total) = value(&w, &pool, p.lp);
                    let growth = (current - p.principal).max(0);
                    let take = mul_div(growth, hb, BPSI).min(mul_div(current, MAX_HARVEST_ROUND_BPS as i128, BPSI));
                    let lp_to_burn = if growth > 0 { dyor_common::mul_div_u256(&w.e, take, total, root + 1) } else { 0 };
                    let (rb, rq) = w.reserves(&pool, &base);
                    let pays = lp_to_burn * rb / total > 0 && lp_to_burn * rq / total > 0;
                    let r = w.try_harvest(&pool);
                    if w.now() < p.last_harvest + w.d.launch.harvest_interval {
                        prop_assert_eq!(r, Err(10_606));
                    } else if !pays {
                        prop_assert_eq!(r, Err(10_607));
                    } else {
                        prop_assert!(r.is_ok(), "{r:?}");
                        let a = w.locker().position(&pool).unwrap();
                        prop_assert_eq!(a.lp, p.lp - lp_to_burn);
                        // F7: the principal grows by ⌈take·(BPS − hb)/hb⌉, capped by what stays in the position.
                        let ratchet = mul_div_up(take, BPSI - hb, hb);
                        prop_assert_eq!(a.principal, (p.principal + ratchet).min(current - take));
                        // The burned LP carried at most `take` of value.
                        prop_assert!(dyor_common::mul_div_u256(&w.e, lp_to_burn, root, total) <= take);
                    }
                }
            }
            // I-K1.
            let a = w.locker().position(&pool).unwrap();
            let (current, _, _) = value(&w, &pool, a.lp);
            prop_assert!(current >= a.principal, "I-K1: value {current} < principal {}", a.principal);
        }
    }
}

// ================================================================================================ Moments

#[derive(Clone, Debug)]
enum Collecting {
    Collect(usize, u32),
    Wait(u64),
    Pause(bool, bool),
}

fn collecting() -> impl Strategy<Value = Collecting> {
    prop_oneof![
        6 => (0..4usize, 1u32..=20).prop_map(|(i, q)| Collecting::Collect(i, q)),
        1 => (1u64..=3_600).prop_map(Collecting::Wait),
        1 => (any::<bool>(), any::<bool>()).prop_map(|(a, b)| Collecting::Pause(a, b)),
    ]
}

/// I-M2 for stack `m`, which holds one Moment, `nft`.
fn assert_moments_solvent(w: &World, m: &Address, nft: &Address) {
    let l = w.m_at(m).ledger(nft);
    let owed = l.reserve + l.creator_claimable + l.platform_claimable + l.treasury_claimable;
    assert!(w.balance(&w.usdc, m) >= owed, "I-M2: {} < {owed}", w.balance(&w.usdc, m));
}

proptest! {
    /// A Moment at a random price and allocation, random collects (including over the terminal edition), waits and
    /// pauses; then its graduation, vesting claims at random times over six periods, and the withdrawals; or its
    /// expiry when the window closes first.
    #[test]
    fn moments_stay_solvent_mint_within_supply_and_vest_monotonically(
        qa in any::<bool>(),
        price in prop_oneof![Just(ONE / 10), Just(ONE / 2), Just(ONE), Just(5 * ONE / 2)],
        alloc in 0u32..=1_000,
        steps in prop::collection::vec(collecting(), 1..16),
        claims in prop::collection::vec((0..5usize, 0u64..=20_000), 1..12),
    ) {
        let d = durations(qa);
        let w = World::new(d);
        let m = w.m();
        let nft = w.publish_on(&w.moments, &moments::PublishParams { price, creator_alloc_bps: alloc, window_secs: DAY, ..w.publish_params() });
        let who = traders(&w);
        let deadline = m.get_moment(&nft).deadline;
        for s in steps {
            if m.ledger(&nft).state != moments::State::Collecting || w.now() >= deadline {
                break;
            }
            match s {
                Collecting::Collect(i, qty) => {
                    let r = m.collect(&who[i], &nft, &qty, &i128::MAX);
                    prop_assert!(r.editions >= 1 && r.editions <= qty);
                }
                Collecting::Wait(s) => w.advance(s.min(deadline - w.now() - 1)),
                // I-M5: no pause stops collect, claim, withdraw, graduate or expire.
                Collecting::Pause(publishing, guardian) => {
                    m.set_publishing_paused(&publishing);
                    m.set_guardian_paused(&guardian);
                }
            }
            assert_moments_solvent(&w, &w.moments, &nft);
        }
        let l = m.ledger(&nft);
        if l.state == moments::State::Collecting {
            // Expiry after the deadline: 70% of the reserve to the creator.
            w.set_time(deadline);
            w.unsigned(|| m.expire(&nft));
            let e = m.ledger(&nft);
            prop_assert_eq!(e.state, moments::State::Expired);
            prop_assert_eq!(e.creator_claimable - l.creator_claimable, mul_div(l.reserve, 7_000, BPSI));
            assert_moments_solvent(&w, &w.moments, &nft);
            return Ok(());
        }
        // I-M1.
        prop_assert_eq!(l.reserve, m.get_moment(&nft).threshold);
        let sc = m.supply_check(&nft);
        prop_assert_eq!(sc.pool_coins + sc.creator_alloc + sc.entitlements, COIN_SUPPLY, "I-M3");
        prop_assert!(matches!(w.graduate_moment_on(&w.moments, &nft), moments::GraduationOutcome::Graduated(_)));
        let l = m.ledger(&nft);
        prop_assert_eq!((l.state, l.stuck_since, l.reserve), (moments::State::Graduated, 0, 0), "I-M6");
        let coin = m.get_moment(&nft).coin;
        prop_assert_eq!(w.balance(&coin, &l.pool.clone().unwrap()), sc.pool_coins);
        assert_moments_solvent(&w, &w.moments, &nft);

        // Vesting claims (I-M4, I-M3 after it).
        let mut accounts = who.to_vec();
        accounts.push(w.creator.clone());
        let mut claimed = std::vec![0i128; 5];
        for (i, wait) in claims {
            w.advance(wait * d.moments.vest_period / 10_000);
            let a = &accounts[i];
            let periods = (w.now() - l.graduated_at) / d.moments.vest_period;
            let c_bps = [6_000, 8_000, 10_000][periods.min(2) as usize] as i128;
            let cr_bps = 2_000 + 1_600 * periods.min(5) as i128;
            let pos = m.position(&nft, a);
            let vested = mul_div(pos.entitlement, c_bps, BPSI)
                + if *a == w.creator { mul_div(sc.creator_alloc, cr_bps, BPSI) } else { 0 };
            let before = w.balance(&coin, a);
            match m.try_claim(a, &nft) {
                Ok(Ok((x, y))) => {
                    prop_assert!(x + y > 0);
                    prop_assert_eq!(w.balance(&coin, a) - before, x + y);
                    claimed[i] += x + y;
                }
                r => prop_assert_eq!(code(r), 10_715),
            }
            prop_assert!(claimed[i] <= vested, "I-M4: claimed {} > vested {vested}", claimed[i]);
            let l = m.ledger(&nft);
            prop_assert!(l.minted_by_vesting <= sc.creator_alloc + sc.entitlements, "I-M3");
            prop_assert!(w.supply(&coin) <= COIN_SUPPLY, "I-M3");
        }
        // After five periods everything has vested: what is left to claim mints exactly the rest.
        w.advance(5 * d.moments.vest_period);
        for (i, a) in accounts.iter().enumerate() {
            if let Ok(Ok((x, y))) = m.try_claim(a, &nft) {
                claimed[i] += x + y;
            }
        }
        prop_assert_eq!(m.ledger(&nft).minted_by_vesting, sc.creator_alloc + sc.entitlements, "I-M3");
        prop_assert_eq!(w.supply(&coin), COIN_SUPPLY);
        // Withdrawals pay what was booked; I-M2 after them.
        for r in [m.try_withdraw_creator(&nft), m.try_withdraw_platform(&nft), m.try_withdraw_treasury(&nft)] {
            if r.is_err() {
                prop_assert_eq!(code(r), 10_716);
            }
        }
        assert_moments_solvent(&w, &w.moments, &nft);
    }
}

// ------------------------------------------------------------------------------------------------ pending expiry

#[derive(Clone, Debug)]
enum Pending {
    Graduate,
    Expire,
    Wait(u64),
}

fn pending_step(d: Durations) -> impl Strategy<Value = Pending> {
    let m = d.moments;
    prop_oneof![
        2 => Just(Pending::Graduate),
        3 => Just(Pending::Expire),
        4 => (1u64..=m.pending_backstop / 3).prop_map(Pending::Wait),
    ]
}

fn pending_case(
    qa: bool,
    mode: Option<qa_exec_fail::Mode>,
    window: u64,
    steps: std::vec::Vec<Pending>,
) -> Result<(), TestCaseError> {
    let d = durations(qa);
    let md = d.moments;
    let w = World::new(d);
    let fail = w.fail_moments.clone();
    let fm = w.m_at(&fail);
    let window = window.clamp(md.min_window, md.max_window);
    let nft = w.publish_on(&fail, &moments::PublishParams { window_secs: window, ..w.publish_params() });
    w.collect_on(&fail, &w.bob, &nft, 2);
    w.complete_moment_on(&fail, &w.alice, &nft);
    let coin = fm.get_moment(&nft).coin;
    let deadline = fm.get_moment(&nft).deadline;
    let completed_at = fm.ledger(&nft).completed_at;
    if let Some(mode) = &mode {
        w.qa().set_mode(&coin, mode);
    }
    for s in steps {
        let l = fm.ledger(&nft);
        if l.state == moments::State::Expired {
            break;
        }
        let now = w.now();
        match s {
            Pending::Wait(s) => w.advance(s),
            // A mode-1 Moment (budget exhaustion) never records a failure: no graduate reaches it here.
            Pending::Graduate if mode.is_none() => {}
            Pending::Graduate => {
                prop_assert!(matches!(w.graduate_moment_on(&fail, &nft), moments::GraduationOutcome::Failed(_)));
                let expected = if l.stuck_since == 0 { now } else { l.stuck_since };
                prop_assert_eq!(fm.ledger(&nft).stuck_since, expected, "I-M7");
            }
            Pending::Expire => {
                // I-M7 and I-M8: never before the deadline; with a recorded failure from stuck_since + stuck_expiry;
                // always from completed_at + pending_backstop.
                let allowed = now >= deadline
                    && ((l.stuck_since != 0 && now >= l.stuck_since + md.stuck_expiry)
                        || now >= completed_at + md.pending_backstop);
                let r = w.unsigned(|| fm.try_expire(&nft));
                if allowed {
                    prop_assert!(r.is_ok(), "{r:?}");
                    let e = fm.ledger(&nft);
                    prop_assert_eq!(e.state, moments::State::Expired);
                    prop_assert_eq!(e.creator_claimable - l.creator_claimable, mul_div(l.reserve, 7_000, BPSI));
                    prop_assert_eq!(e.treasury_claimable - l.treasury_claimable, l.reserve - mul_div(l.reserve, 7_000, BPSI));
                } else {
                    prop_assert_eq!(code(r), 10_713);
                }
            }
        }
        assert_moments_solvent(&w, &fail, &nft);
    }
    // I-M8: whatever happened, it can expire once now ≥ max(deadline, completed_at + pending_backstop).
    if fm.ledger(&nft).state != moments::State::Expired {
        let at = deadline.max(completed_at + md.pending_backstop);
        if w.now() < at {
            w.set_time(at);
        }
        w.unsigned(|| fm.expire(&nft));
        prop_assert_eq!(fm.ledger(&nft).state, moments::State::Expired, "I-M8");
    }
    Ok(())
}

proptest! {
    /// A completed Moment on the failing stack (recorded failures, rejected bogus successes, or a mode-1 Moment that
    /// never records one), with a random window and random graduate, expire and wait steps, either duration set.
    #[test]
    fn pending_moments_expire_only_by_the_rules(
        qa in any::<bool>(),
        mode in prop_oneof![
            Just(Some(qa_exec_fail::Mode::Fail)),
            Just(Some(qa_exec_fail::Mode::BogusSuccess)),
            Just(None),
        ],
        window in 0u64..=2 * DAY,
        steps in prop::collection::vec(pending_step(PRODUCTION), 1..16),
        qa_steps in prop::collection::vec(pending_step(TESTNET_QA), 1..16),
    ) {
        pending_case(qa, mode, window, if qa { qa_steps } else { steps })?;
    }
}
