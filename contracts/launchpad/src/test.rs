extern crate std;

use super::*;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    token::{StellarAssetClient, TokenClient},
    Address, Env, String,
};

mod soroswap_factory {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_factory.wasm");
}
mod soroswap_pair {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_pair.wasm");
}
mod soroswap_router {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_router.wasm");
}
/// The shaken WASM we deploy (`./build.sh` writes dist/ before the tests run).
mod launch_token {
    soroban_sdk::contractimport!(file = "../dist/dyor_launch_token.wasm");
}

const ONE: i128 = 10_000_000; // 7 decimals
const PHANTOM: i128 = 2_000 * ONE;

fn threshold() -> i128 {
    curve::mul_div(PHANTOM, 216_227_766, 100_000_000) // phantom · (√10 − 1)
}

struct T {
    e: Env,
    admin: Address,
    treasury: Address,
    creator: Address,
    alice: Address,
    bob: Address,
    quote: Address,
    factory: Address,
    pad: LaunchpadClient<'static>,
}

fn setup() -> T {
    let e = Env::default();
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    e.ledger().with_mut(|l| l.sequence_number = 1_000);
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);
    let creator = Address::generate(&e);
    let alice = Address::generate(&e);
    let bob = Address::generate(&e);

    let issuer = Address::generate(&e);
    let quote = e.register_stellar_asset_contract_v2(issuer).address();
    let sac = StellarAssetClient::new(&e, &quote);
    for who in [&creator, &alice, &bob] {
        sac.mint(who, &(100_000 * ONE));
    }

    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(&e, &factory).initialize(&admin, &pair_hash);

    let token_hash = e.deployer().upload_contract_wasm(launch_token::WASM);
    let pad_id = e.register(Launchpad, (admin.clone(), treasury.clone(), token_hash, factory.clone()));
    let pad = LaunchpadClient::new(&e, &pad_id);
    pad.set_quote(&quote, &PHANTOM, &threshold(), &true);
    T { e, admin, treasury, creator, alice, bob, quote, factory, pad }
}

fn launch(t: &T, initial_buy: i128) -> Address {
    t.pad.launch(
        &t.creator,
        &t.quote,
        &String::from_str(&t.e, "Dyor Cat"),
        &String::from_str(&t.e, "DCAT"),
        &String::from_str(&t.e, "https://lite.dyorhq.fun/m/dcat.json"),
        &0,
        &initial_buy,
        &0,
    )
}

/// Moves past the snipe window.
fn after_snipe(t: &T) {
    t.e.ledger().with_mut(|l| l.sequence_number += 10);
}

fn quote_balance(t: &T, who: &Address) -> i128 {
    TokenClient::new(&t.e, &t.quote).balance(who)
}

/// The launchpad's quote balance always equals what it owes: every curve's real quote + accrued creator fees +
/// accrued protocol fees.
fn assert_solvent(t: &T, tokens: &[Address]) {
    let mut owed = t.pad.protocol_fees(&t.quote);
    for tok in tokens {
        let c = t.pad.get_curve(tok);
        owed += c.real_quote + c.creator_fees;
    }
    assert_eq!(quote_balance(t, &t.pad.address), owed);
}

#[test]
fn launch_deploys_token_and_opens_curve() {
    let t = setup();
    let token = launch(&t, 0);
    let sep41 = TokenClient::new(&t.e, &token);
    let tok = launch_token::Client::new(&t.e, &token);
    assert_eq!(sep41.symbol(), String::from_str(&t.e, "DCAT"));
    assert_eq!(sep41.decimals(), 7);
    assert_eq!(sep41.balance(&t.pad.address), DEFAULT_SUPPLY);
    assert_eq!(tok.launchpad(), t.pad.address);
    assert!(!tok.unlocked());

    let l = t.pad.get_launch(&token);
    assert_eq!(l.creator, t.creator);
    assert_eq!(l.fee_bps, 100);
    assert_eq!(l.protocol_share_bps, 5_000);
    let c = t.pad.get_curve(&token);
    assert_eq!(c.quote_reserve, PHANTOM);
    assert_eq!(c.token_reserve, DEFAULT_SUPPLY);
    assert_eq!(t.pad.launch_count(), 1);
    assert_eq!(t.pad.launch_at(&0), token);
}

#[test]
fn launch_rejects_bad_input() {
    let t = setup();
    let e = &t.e;
    let s = |v: &str| String::from_str(e, v);
    let long = s("abcdefghijklmnopqrstuvwxyz0123456789"); // 36 bytes
    assert_eq!(
        t.pad.try_launch(&t.creator, &t.quote, &long, &s("X"), &s(""), &0, &0, &0).unwrap_err().unwrap(),
        Error::InvalidName.into()
    );
    assert_eq!(
        t.pad.try_launch(&t.creator, &t.quote, &s("X"), &s("TOOLONGSYMBOL"), &s(""), &0, &0, &0).unwrap_err().unwrap(),
        Error::InvalidSymbol.into()
    );
    assert_eq!(
        t.pad.try_launch(&t.creator, &t.quote, &s("X"), &s("X"), &s(""), &1_001, &0, &0).unwrap_err().unwrap(),
        Error::CreatorFeeTooHigh.into()
    );
    let other = e.register_stellar_asset_contract_v2(Address::generate(e)).address();
    assert_eq!(
        t.pad.try_launch(&t.creator, &other, &s("X"), &s("X"), &s(""), &0, &0, &0).unwrap_err().unwrap(),
        Error::QuoteNotAllowed.into()
    );
    t.pad.set_launches_enabled(&false);
    assert_eq!(
        t.pad.try_launch(&t.creator, &t.quote, &s("X"), &s("X"), &s(""), &0, &0, &0).unwrap_err().unwrap(),
        Error::LaunchesDisabled.into()
    );
}

#[test]
fn buy_and_sell_move_the_curve_and_accrue_fees() {
    let t = setup();
    let token = launch(&t, 0);
    after_snipe(&t);
    let tok = TokenClient::new(&t.e, &token);

    let before = quote_balance(&t, &t.alice);
    let got = t.pad.buy(&t.alice, &token, &(100 * ONE), &0);
    assert_eq!(quote_balance(&t, &t.alice), before - 100 * ONE);
    assert_eq!(tok.balance(&t.alice), got);
    // 1% fee: 0.5 to protocol, 0.5 to creator; 99 enters the curve.
    let c = t.pad.get_curve(&token);
    assert_eq!(c.real_quote, 99 * ONE);
    assert_eq!(c.creator_fees, ONE / 2);
    assert_eq!(t.pad.protocol_fees(&t.quote), ONE / 2);
    // Expected tokens from x·y = k.
    assert_eq!(got, curve::amount_out(99 * ONE, PHANTOM, DEFAULT_SUPPLY));

    let back = t.pad.sell(&t.alice, &token, &(got / 2), &0);
    // The second half of a buy is the pricier half, so selling it back returns a bit more than half the net
    // quote, minus the 1% fee; never more than was paid.
    assert!(back > 49 * ONE && back < 51 * ONE, "{back}");
    assert_eq!(tok.balance(&t.alice), got - got / 2);
    assert_solvent(&t, &[token.clone()]);

    // Slippage guard.
    let q = t.pad.quote_buy(&token, &t.bob, &(10 * ONE));
    assert_eq!(
        t.pad.try_buy(&t.bob, &token, &(10 * ONE), &(q.tokens_out + 1)).unwrap_err().unwrap(),
        Error::SlippageExceeded.into()
    );
    assert_eq!(t.pad.buy(&t.bob, &token, &(10 * ONE), &q.tokens_out), q.tokens_out);
}

#[test]
fn snipe_tax_by_ledger_offset_and_creator_exemption() {
    let t = setup();
    let token = launch(&t, 0);
    let launched_at = t.e.ledger().sequence();
    let expect = [9_800u32, 2_500, 300, 30, 0];
    for (i, bps) in expect.iter().enumerate() {
        t.e.ledger().with_mut(|l| l.sequence_number = launched_at + i as u32);
        let q = t.pad.quote_buy(&token, &t.alice, &(100 * ONE));
        let capped = core::cmp::min(*bps, MAX_TOTAL_BPS - 100);
        assert_eq!(q.snipe_fee, curve::fee_of(100 * ONE, capped), "offset {i}");
        // The creator never pays it.
        assert_eq!(t.pad.quote_buy(&token, &t.creator, &(100 * ONE)).snipe_fee, 0);
    }
}

#[test]
fn creator_initial_buy_is_exempt_and_in_the_same_call() {
    let t = setup();
    let token = launch(&t, 50 * ONE);
    let tok = TokenClient::new(&t.e, &token);
    let expected = curve::amount_out(50 * ONE - curve::fee_of(50 * ONE, 100), PHANTOM, DEFAULT_SUPPLY);
    assert_eq!(tok.balance(&t.creator), expected);
}

#[test]
fn tokens_are_curve_only_before_graduation() {
    let t = setup();
    let token = launch(&t, 0);
    after_snipe(&t);
    let got = t.pad.buy(&t.alice, &token, &(10 * ONE), &0);
    let tok = TokenClient::new(&t.e, &token);
    assert!(tok.try_transfer(&t.alice, &t.bob, &got).is_err());
}

#[test]
fn last_buy_is_clamped_and_completes_the_curve() {
    let t = setup();
    let token = launch(&t, 0);
    after_snipe(&t);
    let before = quote_balance(&t, &t.alice);
    // Far more than the threshold: only what completes the curve is pulled.
    t.pad.buy(&t.alice, &token, &(20_000 * ONE), &0);
    let paid = before - quote_balance(&t, &t.alice);
    let c = t.pad.get_curve(&token);
    assert!(c.completed);
    assert!(c.real_quote >= threshold() && c.real_quote <= threshold() + 2);
    assert!(paid < 20_000 * ONE);
    assert_eq!(paid, curve::gross_for_net(threshold(), 100));
    // About 31.6% of the supply is left for the pool + burn.
    let pct = curve::mul_div(c.token_reserve, 1_000, DEFAULT_SUPPLY);
    assert!((315..=317).contains(&pct), "{pct}");
    // Trading has stopped.
    assert_eq!(t.pad.try_buy(&t.bob, &token, &ONE, &0).unwrap_err().unwrap(), Error::CurveClosed.into());
    assert_eq!(t.pad.try_sell(&t.alice, &token, &ONE, &0).unwrap_err().unwrap(), Error::CurveClosed.into());
    assert_solvent(&t, &[token.clone()]);
}

fn complete(t: &T, token: &Address) {
    after_snipe(t);
    t.pad.buy(&t.alice, token, &(20_000 * ONE), &0);
    assert!(t.pad.get_curve(token).completed);
}

#[test]
fn graduation_seeds_soroswap_at_the_curve_price_and_locks_lp() {
    let t = setup();
    let token = launch(&t, 0);
    assert_eq!(t.pad.try_graduate(&token).unwrap_err().unwrap(), Error::NotCompleted.into());
    complete(&t, &token);
    let c = t.pad.get_curve(&token);
    let final_price_e9 = curve::mul_div(c.quote_reserve, 1_000_000_000, c.token_reserve);

    let pair = t.pad.graduate(&token);
    let p = soroswap_pair::Client::new(&t.e, &pair);
    let (r0, r1) = p.get_reserves();
    let (tok_r, quote_r) = if p.token_0() == token { (r0, r1) } else { (r1, r0) };
    assert_eq!(quote_r, c.real_quote);
    // Pool opens at the curve's final price (within rounding).
    let pool_price_e9 = curve::mul_div(quote_r, 1_000_000_000, tok_r);
    assert!((pool_price_e9 - final_price_e9).abs() <= 1, "{pool_price_e9} vs {final_price_e9}");
    // LP is held by the launchpad (locked: nothing can move it) and the minimum liquidity by the pair.
    let lp = TokenClient::new(&t.e, &pair);
    assert!(lp.balance(&t.pad.address) > 0);
    // Excess tokens burned, transfers open.
    let tok = TokenClient::new(&t.e, &token);
    let ops = launch_token::Client::new(&t.e, &token);
    assert!(ops.unlocked());
    assert_eq!(tok.balance(&t.pad.address), 0);
    assert_eq!(ops.total_supply(), DEFAULT_SUPPLY - (c.token_reserve - tok_r));
    let g = t.pad.get_curve(&token);
    assert!(g.graduated && g.pair == Some(pair.clone()));
    assert_eq!(t.pad.try_graduate(&token).unwrap_err().unwrap(), Error::AlreadyGraduated.into());
    // Holder transfers now work.
    let alice_tokens = tok.balance(&t.alice);
    tok.transfer(&t.alice, &t.bob, &(alice_tokens / 10));
    assert_solvent(&t, &[token.clone()]);
}

#[test]
fn graduated_token_trades_on_the_soroswap_router() {
    let t = setup();
    let token = launch(&t, 0);
    complete(&t, &token);
    t.pad.graduate(&token);
    let router = t.e.register(soroswap_router::WASM, ());
    let r = soroswap_router::Client::new(&t.e, &router);
    r.initialize(&t.factory);
    let path = soroban_sdk::vec![&t.e, t.quote.clone(), token.clone()];
    let before = TokenClient::new(&t.e, &token).balance(&t.bob);
    let deadline = t.e.ledger().timestamp() + 600;
    r.swap_exact_tokens_for_tokens(&(10 * ONE), &0, &path, &t.bob, &deadline);
    assert!(TokenClient::new(&t.e, &token).balance(&t.bob) > before);
}

#[test]
fn graduation_survives_a_precreated_pair_with_dust_and_sync() {
    let t = setup();
    let token = launch(&t, 0);
    // Griefer creates the pair early, donates quote dust and syncs so reserves read (0, dust).
    let f = soroswap_factory::Client::new(&t.e, &t.factory);
    let pair = f.create_pair(&token, &t.quote);
    TokenClient::new(&t.e, &t.quote).transfer(&t.bob, &pair, &7);
    soroswap_pair::Client::new(&t.e, &pair).sync();
    complete(&t, &token);
    assert_eq!(t.pad.graduate(&token), pair);
    assert!(TokenClient::new(&t.e, &pair).balance(&t.pad.address) > 0);
}

#[test]
fn fees_are_claimed_by_their_owners_only() {
    let t = setup();
    let token = launch(&t, 0);
    after_snipe(&t);
    t.pad.buy(&t.alice, &token, &(1_000 * ONE), &0);
    let c = t.pad.get_curve(&token);
    let creator_before = quote_balance(&t, &t.creator);
    assert_eq!(t.pad.claim_creator_fees(&token), c.creator_fees);
    assert_eq!(quote_balance(&t, &t.creator), creator_before + c.creator_fees);
    assert_eq!(t.pad.try_claim_creator_fees(&token).unwrap_err().unwrap(), Error::NothingToClaim.into());

    let pf = t.pad.protocol_fees(&t.quote);
    assert_eq!(t.pad.claim_protocol_fees(&t.quote), pf);
    assert_eq!(quote_balance(&t, &t.treasury), pf);
    assert_solvent(&t, &[token]);
}

#[test]
fn admin_changes_never_touch_a_live_launch() {
    let t = setup();
    let token = launch(&t, 0);
    t.pad.set_quote(&t.quote, &(PHANTOM * 2), &(threshold() * 2), &true);
    t.pad.set_fees(&300, &10_000, &500, &soroban_sdk::vec![&t.e]);
    let l = t.pad.get_launch(&token);
    let c = t.pad.get_curve(&token);
    assert_eq!(l.fee_bps, 100);
    assert_eq!(l.protocol_share_bps, 5_000);
    assert_eq!(l.snipe_schedule.len(), 4);
    assert_eq!(c.phantom, PHANTOM);
    assert_eq!(c.threshold, threshold());
    // Invalid config is refused.
    assert_eq!(
        t.pad.try_set_fees(&9_000, &5_000, &1_000, &soroban_sdk::vec![&t.e]).unwrap_err().unwrap(),
        Error::InvalidConfig.into()
    );
    let _ = &t.admin;
}

#[test]
fn trading_requires_the_traders_signature() {
    let e = Env::default();
    let t = setup();
    let token = launch(&t, 0);
    // A fresh env without mocked auth cannot call buy for alice: re-register to drop mock_all_auths.
    t.e.set_auths(&[]);
    assert!(t.pad.try_buy(&t.alice, &token, &ONE, &0).is_err());
    let _ = e;
}

#[test]
fn many_trades_keep_the_launchpad_solvent() {
    let t = setup();
    let a = launch(&t, 0);
    let b = t.pad.launch(
        &t.creator,
        &t.quote,
        &String::from_str(&t.e, "Second"),
        &String::from_str(&t.e, "TWO"),
        &String::from_str(&t.e, ""),
        &1_000,
        &0,
        &0,
    );
    after_snipe(&t);
    for i in 1..20i128 {
        let amt = (i * 37 % 97 + 1) * ONE;
        let ga = t.pad.buy(&t.alice, &a, &amt, &0);
        let gb = t.pad.buy(&t.bob, &b, &(amt * 2), &0);
        if i % 3 == 0 {
            t.pad.sell(&t.alice, &a, &(ga / 2), &0);
            t.pad.sell(&t.bob, &b, &(gb / 3), &0);
        }
        assert_solvent(&t, &[a.clone(), b.clone()]);
    }
}
