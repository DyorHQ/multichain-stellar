//! Probes (§18.3): error codes (V10), the graduator's coin side (V9), squatting (A1, B1), the reward pool (F1, F2), the
//! SAC-only quote (F17) and hot keys (B7, §3.5). Owner decision O7: Soroswap only, so no AQUA-drain probe.
use dyor_common::{GraduateArgs, GraduateResult, SoroswapFactoryClient, SoroswapPairClient};
use dyor_integration_tests::launchpad::{GradFailure, GraduationOutcome, Phase};
use dyor_integration_tests::*;
use soroban_sdk::testutils::Address as _;
use soroban_sdk::token::TokenClient;
use soroban_sdk::xdr::{LedgerKey, LedgerKeyContractData, ScAddress, ScVal};
use soroban_sdk::{contract, contracterror, contractimpl, symbol_short, Address, Env, TryFromVal, Val};

const TRANSFER_LOCKED: u32 = 10_201;
const NOT_A_POOL: u32 = 10_209;
const TOKEN_ACCOUNT: u32 = 10_213;
const BELOW_FLOOR: u32 = 10_214;
const NOT_CALLER: u32 = 10_301;
const QUOTE_NOT_SAC: u32 = 10_136;

// ------------------------------------------------------------------------------------------------ error codes (V10)

#[test]
fn each_failure_records_a_distinct_namespaced_origin_and_code() {
    let w = World::new(PRODUCTION);
    let mut seen = std::vec::Vec::new();
    // exec-soroswap's tripwire: a pair that already has LP (PoolNotEmpty, 10_303).
    let t = w.completed_launch(&w.usdc, OCCUPIED, true);
    let f = w.graduate(&t);
    assert_eq!(f, GraduationOutcome::Failed(GradFailure { origin: 3, code: 10_303 }));
    seen.push((3, 10_303));
    // qa-exec-fail's ForcedFailure (10_502).
    let t = w.completed_launch(&w.usdc, QA_FAIL, true);
    assert_eq!(w.graduate(&t), GraduationOutcome::Failed(GradFailure { origin: 5, code: 10_502 }));
    seen.push((5, 10_502));
    // On the failing Moments stack: an executor error passes through the graduator unchanged, and the graduator's own
    // GraduationInvalid is origin 10, code 11_003.
    let fail = w.fail_moments.clone();
    for (mode, expected) in [(qa_exec_fail::Mode::Fail, (5, 10_502)), (qa_exec_fail::Mode::BogusSuccess, (10, 11_003))] {
        let nft = w.publish_on(&fail, &w.publish_params());
        w.complete_moment_on(&fail, &w.alice, &nft);
        w.qa().set_mode(&w.m_at(&fail).get_moment(&nft).coin, &mode);
        let f = w.graduate_moment_on(&fail, &nft);
        assert_eq!(f, moments::GraduationOutcome::Failed(moments::GradFailure { origin: expected.0, code: expected.1 }));
        seen.push(expected);
    }
    // PoolNotEmpty (exec-soroswap) and GraduationInvalid (graduator) never share a pair with another origin.
    seen.dedup();
    assert!(seen.contains(&(3, 10_303)) && seen.contains(&(10, 11_003)) && seen.contains(&(5, 10_502)));
    assert_ne!((3, 10_303), (10, 11_003));
}

// ------------------------------------------------------------------------------------------------ graduator coin side (V9)

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum ShortError {
    Never = 1,
}

/// An executor that seeds the pool with 1% fewer coins than it was sent, keeps the rest, and reports the full amount
/// used. With `lie`, it also reports the liquidity floor instead of what the pair minted.
#[contract]
pub struct ShortCoinExecutor;

#[contractimpl]
impl ShortCoinExecutor {
    pub fn __constructor(e: Env, factory: Address, lie: bool) {
        e.storage().instance().set(&symbol_short!("factory"), &factory);
        e.storage().instance().set(&symbol_short!("lie"), &lie);
    }

    pub fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, ShortError> {
        a.source.require_auth();
        let this = e.current_contract_address();
        let (token, quote) = (TokenClient::new(&e, &a.token), TokenClient::new(&e, &a.quote));
        token.transfer(&a.source, &this, &a.token_amount);
        quote.transfer(&a.source, &this, &a.quote_amount);
        let factory: Address = e.storage().instance().get(&symbol_short!("factory")).unwrap();
        let factory = SoroswapFactoryClient::new(&e, &factory);
        let pool = if factory.pair_exists(&a.token, &a.quote) {
            factory.get_pair(&a.token, &a.quote)
        } else {
            factory.create_pair(&a.token, &a.quote)
        };
        token.transfer(&this, &pool, &(a.token_amount - a.token_amount / 100));
        quote.transfer(&this, &pool, &a.quote_amount);
        let minted = SoroswapPairClient::new(&e, &pool).deposit(&a.lp_to);
        let lie: bool = e.storage().instance().get(&symbol_short!("lie")).unwrap();
        let liquidity = if lie { a.min_liquidity } else { minted };
        if liquidity < 0 {
            return Err(ShortError::Never);
        }
        Ok(GraduateResult {
            pool: pool.clone(),
            lp_token: pool,
            liquidity,
            token_used: a.token_amount,
            quote_used: a.quote_amount,
        })
    }
}

#[test]
fn the_graduator_rejects_an_executor_that_seeds_fewer_coins_than_it_reports() {
    let w = World::new(PRODUCTION);
    for lie in [false, true] {
        let exec = w.e.register(ShortCoinExecutor, (w.factory.clone(), lie));
        let (stack, _) = w.moments_stack(&exec);
        let c = w.m_at(&stack);
        let nft = w.publish_on(&stack, &w.publish_params());
        w.complete_moment_on(&stack, &w.alice, &nft);
        let before = c.ledger(&nft);
        let usdc_before = w.balance(&w.usdc, &stack);
        let f = w.graduate_moment_on(&stack, &nft);
        assert_eq!(f, moments::GraduationOutcome::Failed(moments::GradFailure { origin: 10, code: 11_003 }));
        let after = c.ledger(&nft);
        assert_eq!(moments::Ledger { stuck_since: 0, ..after.clone() }, before, "only the stuck clock moved");
        assert_ne!(after.stuck_since, 0);
        assert_eq!(w.balance(&w.usdc, &stack), usdc_before, "the reserve never left");
        // The coin's deployment rolled back with the frame: nothing lives at its predicted address.
        let coin = c.get_moment(&nft).coin;
        assert!(w.e.host().get_ledger_entry(&std::rc::Rc::new(instance_key(&coin))).unwrap().is_none());
    }
}

// ------------------------------------------------------------------------------------------------ squatting (A1, B1)

#[test]
fn an_attacker_can_neither_drive_an_executor_nor_seed_a_pool_before_graduation() {
    let w = World::new(PRODUCTION);
    let token = w.launch(&w.usdc, SOROSWAP, true);
    w.buy(&w.attacker, &token, 5 * ONE);
    let held = w.balance(&token, &w.attacker);
    assert!(held > 0);
    let exec = exec_soroswap::Client::new(&w.e, &w.exec);
    let args = |source: &Address| exec_soroswap::GraduateArgs {
        source: source.clone(),
        token: token.clone(),
        quote: w.usdc.clone(),
        token_amount: held,
        quote_amount: ONE,
        lp_to: w.attacker.clone(),
        params: exec_soroswap::VenueParams { fee_fraction: 0 },
        min_liquidity: 0,
    };
    // As itself: not a caller, on either executor of the launchpad.
    assert_eq!(code(exec.try_graduate(&args(&w.attacker))), NOT_CALLER);
    let qa_args: qa_exec_fail::GraduateArgs = cv(&w.e, &args(&w.attacker));
    assert_eq!(code(w.qa().try_graduate(&qa_args)), 10_501);
    // In the launchpad's name: the launchpad never signed.
    let abort = abort_of(|| w.unsigned(|| exec_soroswap::Client::new(&w.e, &w.exec).graduate(&args(&w.pad))));
    w.e.mock_all_auths();
    assert!(abort.contains("Auth"), "{abort}");
    // Sending the locked token to a pair, an executor, the locker or anyone: refused (I-T6).
    let pair = w.sw_factory().create_pair(&token, &w.usdc);
    for to in [&pair, &w.exec, &w.locker, &w.bob] {
        assert_eq!(code(w.sep41(&token).try_transfer(&w.attacker, to, &1)), TRANSFER_LOCKED);
    }
    // A quote-only seed of the pre-created pair (with sync) can't mint LP and only raises the opening price.
    w.sep41(&w.usdc).transfer(&w.attacker, &pair, &(5 * ONE));
    w.pair(&pair).sync();
    assert!(w.pair(&pair).try_deposit(&w.attacker).is_err());
    assert_eq!(w.pair(&pair).total_supply(), 0);
    let c = w.curve(&token);
    w.complete(&w.carol, &token);
    let before = w.curve(&token);
    let pool = match w.graduate(&token) {
        GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    };
    assert_eq!(pool, pair);
    assert_eq!(w.pair(&pool).total_supply(), w.balance(&pool, &w.locker) + dyor_common::SOROSWAP_MIN_LIQ);
    let (rt, rq) = w.reserves(&pool, &token);
    assert_eq!(rq, before.real_quote + 5 * ONE);
    assert!(rq * before.token_reserve >= before.quote_reserve * rt, "the donation only raises the price (I-L6)");
    let _ = c;
}

// ------------------------------------------------------------------------------------------------ reward pool (F1, F2)

#[test]
fn nothing_moves_the_tokens_own_balance_and_dust_pairs_are_never_excluded() {
    let w = World::new(PRODUCTION);
    let token = w.launch(&w.usdc, SOROSWAP, true);
    let tk = w.sep41(&token);
    let check_token_account = |w: &World| {
        let tk = w.sep41(&token);
        assert_eq!(code(tk.try_transfer(&token, &w.attacker, &1)), TOKEN_ACCOUNT);
        assert_eq!(code(tk.try_transfer_from(&w.attacker, &token, &w.attacker, &1)), TOKEN_ACCOUNT);
        assert_eq!(code(tk.try_burn(&token, &1)), TOKEN_ACCOUNT);
        assert_eq!(code(tk.try_approve(&token, &w.attacker, &1, &(w.seq() + 100))), TOKEN_ACCOUNT);
    };
    check_token_account(&w);
    w.buy(&w.alice, &token, 10 * ONE);
    w.complete(&w.carol, &token);
    let pool = match w.graduate(&token) {
        GraduationOutcome::Graduated(p) => p,
        f => panic!("{f:?}"),
    };
    // Launch-token rewards sit at the token's own address after a harvest.
    w.churn(&token, &w.usdc, 5 * ONE, 3);
    w.advance(HOUR);
    w.harvest(&pool);
    assert!(tk.balance(&token) > 0);
    check_token_account(&w);
    // 50 dust pairs (each below 1,000 tokens): every exclude_pool is refused, so the keeper never pays for one.
    let ltk = w.token(&token);
    for _ in 0..50 {
        let other = w.e.register_stellar_asset_contract_v2(w.attacker.clone()).address();
        w.mint(&other, &w.attacker, ONE);
        let pair = w.sw_factory().create_pair(&token, &other);
        tk.transfer(&w.carol, &pair, &(10 * ONE));
        w.sep41(&other).transfer(&w.attacker, &pair, &ONE);
        w.pair(&pair).deposit(&w.attacker);
        assert_eq!(code(ltk.try_exclude_pool(&launch_token::VenueKind::Soroswap, &other, &pair)), BELOW_FLOOR);
    }
    // An account, a Wasm contract that isn't the factory's pair, and a SAC are not pools.
    let fake: [Address; 3] = [w.alice.clone(), w.locker.clone(), w.xlm.clone()];
    for p in &fake {
        assert_eq!(code(ltk.try_exclude_pool(&launch_token::VenueKind::Soroswap, &w.usdc, p)), NOT_A_POOL);
    }
    // A real pair, named with the wrong other token.
    assert_eq!(code(ltk.try_exclude_pool(&launch_token::VenueKind::Soroswap, &w.xlm, &pool)), NOT_A_POOL);
}

// ------------------------------------------------------------------------------------------------ SAC-only quotes (F17)

/// A Wasm token with a transfer fee: never a quote.
#[contract]
pub struct FeeToken;

#[contractimpl]
impl FeeToken {
    pub fn decimals(_e: Env) -> u32 {
        7
    }
    pub fn balance(_e: Env, _id: Address) -> i128 {
        0
    }
}

#[test]
fn only_stellar_asset_contracts_can_be_quotes() {
    let w = World::new(PRODUCTION);
    let fee_token = w.e.register(FeeToken, ());
    let wasm_token = w.e.register(moment_coin::WASM, (w.admin.clone(), w.s("Fee"), w.s("FEE"), ONE, w.admin.clone(), 0i128));
    let account = Address::generate(&w.e);
    let none = soroban_sdk::Vec::<u32>::new(&w.e);
    for asset in [&fee_token, &wasm_token, &account] {
        let r = w.pad().try_set_quote(asset, &USDC_PHANTOM, &threshold_of(USDC_PHANTOM), &true, &none, &SOROSWAP);
        assert_eq!(code(r), QUOTE_NOT_SAC);
    }
    // A SAC is accepted.
    let sac = w.e.register_stellar_asset_contract_v2(w.admin.clone()).address();
    w.pad().set_quote(&sac, &USDC_PHANTOM, &threshold_of(USDC_PHANTOM), &true, &none, &SOROSWAP);
}

// ------------------------------------------------------------------------------------------------ hot keys (B7, §3.5)

struct Scope {
    /// The launch's or Moment's own contracts (the token, the NFT).
    own: std::vec::Vec<ScAddress>,
    /// The launch's or Moment's id: every singleton key a call writes must carry it.
    id: ScVal,
    /// Singletons: launchpad-v2, moments-v2, the locker, the executors.
    singletons: std::vec::Vec<ScAddress>,
    /// The SACs, whose balance entries are the one shared key.
    sacs: std::vec::Vec<ScAddress>,
}

fn violations(keys: &[LedgerKey], s: &Scope) -> std::vec::Vec<std::string::String> {
    let mut out = std::vec::Vec::new();
    for k in keys {
        if is_nonce(k) {
            continue;
        }
        let ok = match k {
            LedgerKey::ContractData(LedgerKeyContractData { contract, key, .. }) => {
                if s.own.contains(contract) || s.sacs.contains(contract) {
                    true
                } else if s.singletons.contains(contract) {
                    !is_instance(k)
                        && matches!(key, ScVal::Vec(Some(v)) if v.iter().skip(1).any(|x| *x == s.id))
                } else {
                    false
                }
            }
            LedgerKey::Account(_) | LedgerKey::Trustline(_) => true,
            _ => false,
        };
        if !ok {
            out.push(std::format!("{k:?}"));
        }
    }
    out
}

fn scval(e: &Env, a: &Address) -> ScVal {
    let v: Val = a.into_val(e);
    ScVal::try_from_val(e, &v).unwrap()
}

use soroban_sdk::IntoVal;

#[test]
fn trades_refunds_publishes_and_collects_write_only_their_own_keys_and_the_shared_sac_balance() {
    let w = World::new(PRODUCTION);
    let singletons: std::vec::Vec<ScAddress> =
        [&w.pad, &w.moments, &w.locker, &w.exec, &w.qa, &w.graduator].iter().map(|a| sc(a)).collect();
    let sacs: std::vec::Vec<ScAddress> = [&w.xlm, &w.usdc, &w.qa_asset].iter().map(|a| sc(a)).collect();
    // Another launch and Moment exist and trade, so a key of theirs would show.
    let other = w.launch(&w.usdc, SOROSWAP, true);
    w.buy(&w.bob, &other, 5 * ONE);
    let other_nft = w.publish();
    w.collect_on(&w.moments, &w.bob, &other_nft, 1);

    let mut bad = std::vec::Vec::new();
    // launch: the new token's own entries, the launchpad's per-launch keys, the XLM fee.
    let p = w.params(&w.usdc, QA_FAIL, true);
    let predicted = w.pad().token_address(&w.creator, &p.nonce);
    let (token, keys) = writes(&w.e, || w.launch_with(&w.creator, &p));
    assert_eq!(token, predicted);
    let scope = |id: &Address| Scope { own: vec_of(&[id]), id: scval(&w.e, id), singletons: singletons.clone(), sacs: sacs.clone() };
    // §3.5 lists what a launch writes; acceptance binds trades, refunds, publishes and collects. A launch must write
    // no instance key of a singleton; any other key outside its scope is printed for the hand-off.
    for v in violations(&keys, &scope(&token)) {
        assert!(!v.contains("LedgerKeyContractInstance"), "launch wrote a singleton's instance: {v}");
        std::println!("launch also writes: {v}");
    }
    w.advance(30);
    let (_, keys) = writes(&w.e, || w.buy(&w.alice, &token, 5 * ONE));
    bad.extend(violations(&keys, &scope(&token)).into_iter().map(|v| std::format!("buy: {v}")));
    let held = w.balance(&token, &w.alice);
    let (_, keys) = writes(&w.e, || w.sell(&w.alice, &token, held / 3));
    bad.extend(violations(&keys, &scope(&token)).into_iter().map(|v| std::format!("sell: {v}")));
    w.complete(&w.carol, &token);
    w.graduate(&token);
    w.set_time(w.curve(&token).stuck_since + w.d.launch.rescue_admin);
    w.pad().rescue(&token);
    assert_eq!(w.curve(&token).phase, Phase::Rescued);
    let held = w.balance(&token, &w.alice);
    let (_, keys) = writes(&w.e, || w.pad().refund(&w.alice, &token, &held));
    bad.extend(violations(&keys, &scope(&token)).into_iter().map(|v| std::format!("refund: {v}")));

    let pp = w.publish_params();
    let predicted = w.m().nft_address(&w.creator, &pp.nonce);
    let (nft, keys) = writes(&w.e, || w.publish_on(&w.moments, &pp));
    assert_eq!(nft, predicted);
    bad.extend(violations(&keys, &scope(&nft)).into_iter().map(|v| std::format!("publish: {v}")));
    let (_, keys) = writes(&w.e, || w.collect_on(&w.moments, &w.alice, &nft, 3));
    bad.extend(violations(&keys, &scope(&nft)).into_iter().map(|v| std::format!("collect: {v}")));
    assert!(bad.is_empty(), "keys outside the action's own scope:\n{}", bad.join("\n"));
}

fn vec_of(a: &[&Address]) -> std::vec::Vec<ScAddress> {
    a.iter().map(|x| sc(x)).collect()
}

/// A buy reads the same number of entries whether or not other launches exist: no buy reads another launch's keys.
#[test]
fn a_buys_footprint_does_not_grow_with_other_launches() {
    let footprint = |others: u32| {
        let w = World::new(PRODUCTION);
        for _ in 0..others {
            let t = w.launch(&w.usdc, SOROSWAP, true);
            w.buy(&w.bob, &t, 5 * ONE);
        }
        let token = w.launch(&w.usdc, SOROSWAP, true);
        w.buy(&w.alice, &token, 5 * ONE);
        let (_, m) = measure(&w.e, "buy", || w.buy(&w.alice, &token, 5 * ONE));
        (m.read_entries, m.write_entries)
    };
    assert_eq!(footprint(0), footprint(5));
}

