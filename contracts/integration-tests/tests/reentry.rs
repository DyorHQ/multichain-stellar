//! Re-entry probes (§3.3): every path of the re-entry map runs on the real WASMs. The host refuses any call into a
//! contract already on the stack, at run time (§2), so each path completing proves it never re-enters; the control
//! test shows the refusal is live in this host: a venue that calls back into the launchpad can't graduate a launch.
//!
//! Permissionless paths run with auth enforced and nobody's signature, as a keeper sends them, so the
//! pre-authorizations of §2 (launchpad and graduator transfers to executors) are exercised too.
use dyor_integration_tests::launchpad::{GraduationOutcome, Phase, PositionRef};
use dyor_integration_tests::*;
use soroban_sdk::{contract, contractimpl, symbol_short, vec, Address, Env, Val};

fn pool(o: GraduationOutcome) -> Address {
    match o {
        GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    }
}

#[test]
fn row_1_launch_buy_and_sell_call_the_sac_and_the_token_which_never_calls_out() {
    let w = World::new(PRODUCTION);
    let mut p = w.params(&w.usdc, SOROSWAP, true);
    p.creator_fee_bps = 500;
    p.initial_buy = 2 * ONE;
    let token = w.launch_with(&w.creator, &p);
    w.advance(30);
    w.buy(&w.alice, &token, 3 * ONE);
    let held = w.balance(&token, &w.alice);
    w.sell(&w.alice, &token, held / 2);
    // Fees reached the holders through notify_reward (the token read the quote SAC's balance, nothing else).
    assert!(w.curve(&token).holder_fees_total > 0);
}

#[test]
fn row_2_refund_burns_through_the_token_hook() {
    let w = World::new(PRODUCTION);
    let token = w.completed_launch(&w.usdc, QA_FAIL, true);
    w.graduate(&token);
    w.set_time(w.curve(&token).stuck_since + w.d.launch.rescue_public);
    w.unsigned(|| w.pad().rescue(&token));
    let held = w.balance(&token, &w.bob);
    assert!(w.pad().refund(&w.bob, &token, &held) > 0);
}

#[test]
fn row_3_rescue_reads_burns_and_unlocks_the_token() {
    let w = World::new(PRODUCTION);
    let token = w.completed_launch(&w.usdc, QA_FAIL, false);
    w.graduate(&token);
    w.set_time(w.curve(&token).stuck_since + w.d.launch.rescue_admin);
    w.pad().rescue(&token);
    assert_eq!(w.curve(&token).phase, Phase::Rescued);
}

#[test]
fn row_4_graduate_and_graduate_fallback_go_through_the_executor_and_back() {
    let w = World::new(PRODUCTION);
    let (_, p) = w.graduated_launch(&w.usdc, true);
    assert!(w.locker().position(&p).is_some());
    let token = w.completed_launch(&w.usdc, QA_FAIL, true);
    w.graduate(&token);
    w.advance(w.d.launch.fallback_delay);
    pool(w.graduate_fallback(&token));
}

#[test]
fn row_5_a_harvest_calls_the_launchpad_view_then_the_token_which_calls_the_launchpad_view() {
    let w = World::new(PRODUCTION);
    let (token, p) = w.graduated_launch(&w.usdc, true);
    w.churn(&token, &w.usdc, 5 * ONE, 3);
    w.advance(w.d.launch.harvest_interval);
    let (b, q) = w.harvest(&p);
    assert!(b > 0 && q > 0);
    assert_eq!(
        w.pad().harvest_payees(&PositionRef::Launch(token.clone())).base.get_unchecked(1).to,
        token,
        "the holders' half went to the token, which excluded the treasury first (exclude_treasury)"
    );
}

#[test]
fn row_6_sweep_protocol_and_exclude_treasury_read_the_launchpad_from_the_top_level() {
    let w = World::new(PRODUCTION);
    let (token, _) = w.graduated_launch(&w.usdc, true);
    let tk = w.token(&token);
    // Idempotent for the treasury excluded at construction.
    assert!(!w.unsigned(|| tk.exclude_treasury()));
    let r = w.unsigned(|| tk.try_sweep_protocol());
    assert_eq!(code(r), 10_208, "nothing owed yet, but the call ran through launchpad.treasury()");
}

#[test]
fn row_7_exclude_pool_calls_only_soroswap_views() {
    let w = World::new(PRODUCTION);
    let (token, _) = w.graduated_launch(&w.usdc, true);
    let pair = w.sw_factory().create_pair(&token, &w.xlm);
    let stake = w.balance(&token, &w.alice) / 2;
    w.sep41(&token).transfer(&w.alice, &pair, &stake);
    w.sep41(&w.xlm).transfer(&w.alice, &pair, &ONE);
    w.pair(&pair).deposit(&w.alice);
    assert!(w.unsigned(|| w.token(&token).exclude_pool(&launch_token::VenueKind::Soroswap, &w.xlm, &pair)));
}

#[test]
fn row_8_constructors_read_the_lockers_interval() {
    // World::new deployed launchpad-v2 and both moments-v2 stacks, whose constructors call locker.harvest_interval().
    let w = World::new(TESTNET_QA);
    assert_eq!(w.locker().harvest_interval(), w.d.launch.harvest_interval);
    assert_eq!(w.pad().config().durations.harvest_interval, w.d.launch.harvest_interval);
    assert_eq!(w.m().config().durations.harvest_interval, w.d.moments.harvest_interval);
    // moments-v2's constructor read coin_wasm_hash from the real graduator (lead note after CT-09): the terms carry
    // the hash of the dist moment-coin, and a graduation deploys the coin at the address the graduator predicts.
    let coin_hash = w.e.deployer().upload_contract_wasm(moment_coin::WASM);
    assert_eq!(graduator::Client::new(&w.e, &w.graduator).coin_wasm_hash(), coin_hash);
    assert_eq!(w.m().terms().coin_wasm_hash, coin_hash);
    assert_eq!(w.m_at(&w.fail_moments).terms().coin_wasm_hash, coin_hash);
    let (nft, _) = w.graduated_moment();
    let coin = w.m().get_moment(&nft).coin;
    assert_eq!(graduator::Client::new(&w.e, &w.graduator).coin_address(&nft), coin);
    assert_eq!(w.coin(&coin).minter(), w.moments);
}

#[test]
fn row_9_collect_calls_the_sac_and_the_nft() {
    let w = World::new(PRODUCTION);
    let nft = w.publish();
    let r = w.collect_on(&w.moments, &w.bob, &nft, 5);
    assert_eq!(w.nft(&nft).minted(), r.editions);
}

#[test]
fn row_10_moments_graduation_goes_through_the_graduator_and_the_executor() {
    let w = World::new(PRODUCTION);
    let (nft, p) = w.graduated_moment();
    assert!(w.locker().position(&p).is_some());
    assert!(w.nft(&nft).closed());
}

#[test]
fn row_11_a_moment_harvest_calls_moments_view_then_burns_coins() {
    let w = World::new(PRODUCTION);
    let (nft, p) = w.graduated_moment();
    let coin = w.m().get_moment(&nft).coin;
    w.churn(&coin, &w.usdc, ONE, 3);
    w.advance(w.d.moments.harvest_interval);
    let supply = w.supply(&coin);
    let (burned, paid) = w.harvest(&p);
    assert!(burned > 0 && paid > 0);
    assert_eq!(w.supply(&coin), supply - burned);
}

// ------------------------------------------------------------------------------------------------ control

/// A venue that calls back into its caller (the launchpad, `a.source`) from inside `graduate`.
#[contract]
pub struct ReenteringExecutor;

#[contractimpl]
impl ReenteringExecutor {
    pub fn graduate(e: Env, a: dyor_common::GraduateArgs) -> dyor_common::GraduateResult {
        let _: Val = e.invoke_contract(&a.source, &symbol_short!("config"), vec![&e]);
        panic!("re-entry was allowed")
    }
}

#[test]
fn control_the_host_refuses_a_venue_that_re_enters_the_launchpad() {
    let e = new_env(TESTNET);
    let reenter = e.register(ReenteringExecutor, ());
    let w = World::build(e, PRODUCTION, TESTNET, &[(launchpad::VenueKind::Soroswap, reenter)]);
    let token = w.completed_launch(&w.usdc, 3, true);
    let before = w.curve(&token);
    match w.unsigned(|| w.pad().try_graduate(&token)) {
        // The refusal is recoverable: recorded as a host error (origin 99), the launch goes stuck.
        Ok(Ok(GraduationOutcome::Failed(f))) => {
            assert_eq!(f.origin, 99, "{f:?}");
            assert_eq!(launchpad::Curve { stuck_since: 0, ..w.curve(&token) }, before);
        }
        // Or the whole call aborts; either way nothing graduates.
        other => {
            assert!(other.is_err(), "{other:?}");
            assert_eq!(w.curve(&token), before);
        }
    }
}
