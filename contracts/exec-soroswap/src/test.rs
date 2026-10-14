//! exec-soroswap against the real Soroswap factory, pair and router WASMs (contracts/testdata), called the way
//! launchpad-v2 will call it (§5.5): from a harness contract that pre-authorizes exactly the two pulls with
//! `authorize_as_current_contract`, goes through `try_graduate` and applies the launchpad's result checks.
//!
//! Auth is enforced in every graduation below: `mock_all_auths` is on only while the tests fund accounts or play a
//! third party (`as_anyone`).
extern crate std;

use super::*;
use dyor_common::{
    grad_failure, isqrt_u128, mul_div, tag_of, ExecutorClient, GradFailure, VenueParams, BPS, ERR_MAX, ERR_MIN,
    GRAD_DUST_BPS, ORIGIN_HOST, SOROSWAP_MIN_LIQ,
};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::testutils::{Address as _, Events as _};
use soroban_sdk::token::StellarAssetClient;
use soroban_sdk::xdr::{self, Limited, Limits, ReadXdr, ScErrorCode, ScSpecEntry, WriteXdr};
use soroban_sdk::{contracterror, panic_with_error, vec, Bytes, Event as _, IntoVal, Symbol, TryIntoVal};
use std::rc::Rc;

mod soroswap_factory {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_factory.wasm");
}
mod soroswap_pair {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_pair.wasm");
}
// The router's own functions take up to 9 arguments (add_liquidity), and the generated client mirrors them.
#[allow(clippy::too_many_arguments)]
mod soroswap_router {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_router.wasm");
}

const ONE: i128 = 10_000_000; // 7 decimals
/// About what a launch graduates: ~200M launch tokens against the threshold of a 2,000 XLM phantom.
const POOL_TOKENS: i128 = 206_913_808 * ONE;
const POOL_QUOTE: i128 = 4_324_555 * ONE / 1_000;

// ------------------------------------------------------------------------------------------------ the harness

/// launchpad-v2's `GraduationInvalid` (10_134): one of its result checks failed (§5.5).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum HarnessError {
    GraduationInvalid = 10_134,
}

/// What one attempt came to, as launchpad-v2 records it.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Attempt {
    Graduated(GraduateResult),
    Failed(GradFailure),
}

/// Stands in for launchpad-v2's graduation attempt and for moments-graduator: the `source` of what it sends.
#[contract]
pub struct Harness;

#[contractimpl]
impl Harness {
    /// Pre-authorizes exactly `transfer(this, executor, amount)` on both assets, as §5.5 does.
    pub fn attempt(e: Env, executor: Address, factory: Address, a: GraduateArgs) -> Attempt {
        let (token_auth, quote_auth) = (a.token_amount, a.quote_amount);
        Self::attempt_authorizing(e, executor, factory, a, token_auth, quote_auth)
    }

    /// The same, pre-authorizing the given amounts instead (0: no entry for that asset).
    pub fn attempt_authorizing(
        e: Env,
        executor: Address,
        factory: Address,
        a: GraduateArgs,
        token_auth: i128,
        quote_auth: i128,
    ) -> Attempt {
        let this = e.current_contract_address();
        let token = TokenClient::new(&e, &a.token);
        let quote = TokenClient::new(&e, &a.quote);
        let (t0, q0) = (token.balance(&this), quote.balance(&this));

        let mut pulls = Vec::new(&e);
        for (asset, amount) in [(&a.token, token_auth), (&a.quote, quote_auth)] {
            if amount != 0 {
                pulls.push_back(transfer_entry(&e, asset, &this, &executor, amount));
            }
        }
        e.authorize_as_current_contract(pulls);

        match ExecutorClient::new(&e, &executor).try_graduate(&a) {
            Ok(Ok(r)) => {
                check_result(&e, &factory, &a, &r, t0 - token.balance(&this), q0 - quote.balance(&this));
                Attempt::Graduated(r)
            }
            Ok(Err(_)) => panic!("the executor's result doesn't decode"),
            Err(err) => Attempt::Failed(grad_failure(err)),
        }
    }
}

fn transfer_entry(e: &Env, asset: &Address, from: &Address, to: &Address, amount: i128) -> InvokerContractAuthEntry {
    InvokerContractAuthEntry::Contract(SubContractInvocation {
        context: ContractContext {
            contract: asset.clone(),
            fn_name: Symbol::new(e, "transfer"),
            args: (from.clone(), to.clone(), amount).into_val(e),
        },
        sub_invocations: vec![e],
    })
}

/// launchpad-v2's result checks for a Soroswap venue (§5.5); the deltas are the drops in this contract's balances.
fn check_result(
    e: &Env,
    factory: &Address,
    a: &GraduateArgs,
    r: &GraduateResult,
    token_delta: i128,
    quote_delta: i128,
) {
    let within_dust = |used: i128, amount: i128| {
        amount - mul_div(amount, GRAD_DUST_BPS as i128, BPS as i128) <= used && used <= amount
    };
    let ok = within_dust(r.token_used, a.token_amount)
        && within_dust(r.quote_used, a.quote_amount)
        && token_delta == r.token_used
        && quote_delta == r.quote_used
        && r.liquidity >= a.min_liquidity
        && TokenClient::new(e, &r.lp_token).balance(&a.lp_to) >= r.liquidity
        && r.pool == SoroswapFactoryClient::new(e, factory).get_pair(&a.token, &a.quote)
        && r.lp_token == r.pool;
    if !ok {
        panic_with_error!(e, HarnessError::GraduationInvalid);
    }
}

// ------------------------------------------------------------------------------------------------ setup

struct T {
    e: Env,
    factory: Address,
    router: Address,
    exec: Address,
    /// The two callers: harnesses standing in for launchpad-v2 and moments-graduator.
    pad: Address,
    grad: Address,
    /// The native XLM asset contract, and an account that holds XLM to fund others.
    xlm: Address,
    whale: Address,
    /// Issued assets standing in for USDC, a launch token and a Moment coin. Unlike a real launch token they are
    /// never locked, so a test can also play the attacker who seeds a pool before graduation.
    usdc: Address,
    token: Address,
    coin: Address,
    /// Where the LP goes: the locker.
    locker: Address,
}

fn setup() -> T {
    let e = Env::default();
    e.cost_estimate().budget().reset_unlimited();
    e.mock_all_auths();

    let setter = Address::generate(&e);
    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(&e, &factory).initialize(&setter, &pair_hash);
    let router = e.register(soroswap_router::WASM, ());
    soroswap_router::Client::new(&e, &router).initialize(&factory);

    let pad = e.register(Harness, ());
    let grad = e.register(Harness, ());
    let exec = e.register(ExecSoroswap, (factory.clone(), vec![&e, pad.clone(), grad.clone()]));

    let asset_admin = Address::generate(&e);
    let xlm = native_asset(&e);
    let whale = funded_account(&e, 1, i64::MAX / 2);
    let t = T {
        factory,
        router,
        exec,
        pad,
        grad,
        xlm,
        whale,
        usdc: e.register_stellar_asset_contract_v2(asset_admin.clone()).address(),
        token: e.register_stellar_asset_contract_v2(asset_admin.clone()).address(),
        coin: e.register_stellar_asset_contract_v2(asset_admin).address(),
        locker: Address::generate(&e),
        e,
    };
    for caller in [&t.pad, &t.grad] {
        for asset in [&t.xlm, &t.usdc, &t.token, &t.coin] {
            give(&t, asset, caller, 1_000_000_000 * ONE);
        }
    }
    t.e.set_auths(&[]);
    t
}

/// The native asset's contract (what XLM is on chain).
fn native_asset(e: &Env) -> Address {
    let asset = xdr::Asset::Native.to_xdr(Limits::none()).unwrap();
    e.deployer().with_stellar_asset(Bytes::from_slice(e, &asset)).deploy()
}

/// A classic account holding `stroops` of XLM.
fn funded_account(e: &Env, seed: u8, stroops: i64) -> Address {
    let id = xdr::AccountId(xdr::PublicKey::PublicKeyTypeEd25519(xdr::Uint256([seed; 32])));
    let key = Rc::new(xdr::LedgerKey::Account(xdr::LedgerKeyAccount { account_id: id.clone() }));
    let entry = Rc::new(xdr::LedgerEntry {
        data: xdr::LedgerEntryData::Account(xdr::AccountEntry {
            account_id: id.clone(),
            balance: stroops,
            flags: 0,
            home_domain: Default::default(),
            inflation_dest: None,
            num_sub_entries: 0,
            seq_num: xdr::SequenceNumber(0),
            thresholds: xdr::Thresholds([1, 0, 0, 0]),
            signers: Default::default(),
            ext: xdr::AccountEntryExt::V0,
        }),
        last_modified_ledger_seq: 0,
        ext: xdr::LedgerEntryExt::V0,
    });
    e.host().add_ledger_entry(&key, &entry, None).unwrap();
    xdr::ScAddress::Account(id).try_into_val(e).unwrap()
}

/// Funds `to`: XLM from the whale, the issued assets by minting. Call with auths mocked.
fn give(t: &T, asset: &Address, to: &Address, amount: i128) {
    if *asset == t.xlm {
        TokenClient::new(&t.e, asset).transfer(&t.whale, to, &amount);
    } else {
        StellarAssetClient::new(&t.e, asset).mint(to, &amount);
    }
}

/// Runs `f` as a third party whose signatures are all mocked, then enforces auth again.
fn as_anyone<R>(t: &T, f: impl FnOnce() -> R) -> R {
    t.e.mock_all_auths();
    let r = f();
    t.e.set_auths(&[]);
    r
}

fn args(
    t: &T,
    source: &Address,
    token: &Address,
    quote: &Address,
    token_amount: i128,
    quote_amount: i128,
) -> GraduateArgs {
    GraduateArgs {
        source: source.clone(),
        token: token.clone(),
        quote: quote.clone(),
        token_amount,
        quote_amount,
        lp_to: t.locker.clone(),
        params: VenueParams { fee_fraction: 0 },
        min_liquidity: min_liquidity(token_amount, quote_amount),
    }
}

/// What launchpad-v2 and the graduator pass: isqrt(t·q) − SOROSWAP_MIN_LIQ − 1 (§5.5, §12).
fn min_liquidity(token_amount: i128, quote_amount: i128) -> i128 {
    lp_minted(token_amount, quote_amount) - 1
}

/// What a first deposit of these amounts mints to its `to`, by the spec's reading of the pair.
fn lp_minted(token_amount: i128, quote_amount: i128) -> i128 {
    isqrt_u128((token_amount * quote_amount) as u128) as i128 - SOROSWAP_MIN_LIQ
}

fn harness<'a>(t: &'a T, at: &Address) -> HarnessClient<'a> {
    HarnessClient::new(&t.e, at)
}

fn graduate(t: &T, a: &GraduateArgs) -> Attempt {
    harness(t, &a.source).attempt(&t.exec, &t.factory, a)
}

fn graduated(t: &T, a: &GraduateArgs) -> GraduateResult {
    match graduate(t, a) {
        Attempt::Graduated(r) => r,
        Attempt::Failed(f) => panic!("graduation failed: {f:?}"),
    }
}

fn failure(t: &T, a: &GraduateArgs) -> GradFailure {
    match graduate(t, a) {
        Attempt::Failed(f) => f,
        Attempt::Graduated(r) => panic!("graduation succeeded: {r:?}"),
    }
}

fn exec_failure(e: Error) -> GradFailure {
    GradFailure { origin: TAG_EXEC_SOROSWAP, code: e as u32 }
}

fn balance(t: &T, asset: &Address, who: &Address) -> i128 {
    TokenClient::new(&t.e, asset).balance(who)
}

fn pair_of(t: &T, token: &Address, quote: &Address) -> Option<Address> {
    let f = soroswap_factory::Client::new(&t.e, &t.factory);
    f.pair_exists(token, quote).then(|| f.get_pair(token, quote))
}

/// The pair's reserves as (token side, quote side).
fn reserves(t: &T, pair: &Address, token: &Address) -> (i128, i128) {
    let p = soroswap_pair::Client::new(&t.e, pair);
    let (r0, r1) = p.get_reserves();
    if p.token_0() == *token {
        (r0, r1)
    } else {
        (r1, r0)
    }
}

/// Every balance a graduation of `token`/`quote` can touch: the callers', the executor's, the locker's and, when it
/// exists, the pair's (both assets, its reserves and its LP supply).
fn snapshot(t: &T, token: &Address, quote: &Address) -> std::vec::Vec<i128> {
    let mut v = std::vec::Vec::new();
    for who in [&t.pad, &t.grad, &t.exec, &t.locker] {
        v.extend([balance(t, token, who), balance(t, quote, who)]);
    }
    if let Some(pair) = pair_of(t, token, quote) {
        let (rt, rq) = reserves(t, &pair, token);
        let lp = soroswap_pair::Client::new(&t.e, &pair).total_supply();
        v.extend([balance(t, token, &pair), balance(t, quote, &pair), rt, rq, lp, balance(t, &pair, &t.locker)]);
    }
    v
}

// ------------------------------------------------------------------------------------------------ success

#[test]
fn seeds_a_fresh_pair_at_the_given_ratio() {
    let t = setup();
    let a = args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
    let (t0, q0) = (balance(&t, &t.token, &t.pad), balance(&t, &t.xlm, &t.pad));
    assert_eq!(pair_of(&t, &t.token, &t.xlm), None);

    let r = graduated(&t, &a);
    let events = t.e.events().all().filter_by_contract(&t.exec);

    let pair = pair_of(&t, &t.token, &t.xlm).unwrap();
    assert_eq!((r.pool.clone(), r.lp_token.clone()), (pair.clone(), pair.clone()));
    assert_eq!((r.token_used, r.quote_used), (POOL_TOKENS, POOL_QUOTE));
    // The pool opens at exactly the given ratio, and the LP is at lp_to.
    assert_eq!(reserves(&t, &pair, &t.token), (POOL_TOKENS, POOL_QUOTE));
    assert_eq!(r.liquidity, lp_minted(POOL_TOKENS, POOL_QUOTE));
    assert_eq!(balance(&t, &pair, &t.locker), r.liquidity);
    // The source paid exactly what was used, and nothing stays in the executor.
    assert_eq!(balance(&t, &t.token, &t.pad), t0 - POOL_TOKENS);
    assert_eq!(balance(&t, &t.xlm, &t.pad), q0 - POOL_QUOTE);
    assert_eq!((balance(&t, &t.token, &t.exec), balance(&t, &t.xlm, &t.exec)), (0, 0));

    let event = ExecGraduated {
        source: t.pad.clone(),
        token: t.token.clone(),
        quote: t.xlm.clone(),
        pool: pair,
        liquidity: r.liquidity,
    };
    assert_eq!(events, [event.to_xdr(&t.e, &t.exec)]);
}

#[test]
fn both_callers_graduate() {
    let t = setup();
    let launch = graduated(&t, &args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE));
    // A Moment: 50M coins against 25,000 USDC.
    let moment = graduated(&t, &args(&t, &t.grad, &t.coin, &t.usdc, 50_000_000 * ONE, 25_000 * ONE));
    assert_ne!(launch.pool, moment.pool);
    assert_eq!(reserves(&t, &moment.pool, &t.coin), (50_000_000 * ONE, 25_000 * ONE));
    assert_eq!(balance(&t, &moment.pool, &t.locker), moment.liquidity);
}

#[test]
fn sac_pulls_need_exactly_the_sources_pre_authorization() {
    // XLM (the native asset contract) for launches, USDC for Moments: both pulls are SAC transfers that the source
    // pre-authorized from inside its own call.
    for quote in ["xlm", "usdc"] {
        let t = setup();
        let quote = if quote == "xlm" { t.xlm.clone() } else { t.usdc.clone() };
        let a = args(&t, &t.pad, &t.token, &quote, POOL_TOKENS, POOL_QUOTE);
        let h = harness(&t, &t.pad);
        let before = snapshot(&t, &t.token, &quote);

        // Without the entry for one asset, or with an entry for another amount, the pull fails the source's auth
        // check: a recoverable host error, so nothing moves.
        let auth_failure = GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 };
        for (token_auth, quote_auth) in [(0, 0), (POOL_TOKENS, 0), (0, POOL_QUOTE), (POOL_TOKENS, POOL_QUOTE - 1)] {
            let r = h.attempt_authorizing(&t.exec, &t.factory, &a, &token_auth, &quote_auth);
            assert_eq!(r, Attempt::Failed(auth_failure));
            assert_eq!(snapshot(&t, &t.token, &quote), before);
        }

        let r = graduated(&t, &a);
        assert_eq!(reserves(&t, &r.pool, &t.token), (POOL_TOKENS, POOL_QUOTE));
    }
}

#[test]
fn soroswap_min_liq_matches_the_pair_fixtures_first_deposit_lock() {
    for (token_amount, quote_amount) in [(POOL_TOKENS, POOL_QUOTE), (50_000_000 * ONE, 25_000 * ONE), (4_001, 1_000)] {
        let t = setup();
        let r = graduated(&t, &args(&t, &t.pad, &t.token, &t.usdc, token_amount, quote_amount));
        let pair = soroswap_pair::Client::new(&t.e, &r.pool);
        // The first deposit locks SOROSWAP_MIN_LIQ of LP in the pair itself and mints the rest to `to`.
        assert_eq!(pair.total_supply() - r.liquidity, SOROSWAP_MIN_LIQ);
        assert_eq!(pair.balance(&r.pool), SOROSWAP_MIN_LIQ);
        assert_eq!(r.liquidity, isqrt_u128((token_amount * quote_amount) as u128) as i128 - SOROSWAP_MIN_LIQ);
    }
}

#[test]
fn a_precreated_pair_with_quote_dust_still_graduates_in_the_lps_favour() {
    // The case of S:contracts/launchpad/src/test.rs:309: a griefer creates the pair early and donates quote dust,
    // synced into the reserves or left in the balance.
    for synced in [true, false] {
        let t = setup();
        let bob = Address::generate(&t.e);
        let pair = as_anyone(&t, || {
            give(&t, &t.xlm, &bob, 7);
            let pair = soroswap_factory::Client::new(&t.e, &t.factory).create_pair(&t.token, &t.xlm);
            TokenClient::new(&t.e, &t.xlm).transfer(&bob, &pair, &7);
            if synced {
                soroswap_pair::Client::new(&t.e, &pair).sync();
            }
            pair
        });
        assert_eq!(reserves(&t, &pair, &t.token), if synced { (0, 7) } else { (0, 0) });

        let r = graduated(&t, &args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE));
        assert_eq!(r.pool, pair);
        // The pool holds the donation on top of the given amounts, so it opens slightly above the given price.
        let (rt, rq) = reserves(&t, &pair, &t.token);
        assert_eq!((rt, rq), (POOL_TOKENS, POOL_QUOTE + 7));
        assert!(rq * POOL_TOKENS > POOL_QUOTE * rt);
        // The donation can't mint LP for anyone else: the locker holds every share but the pair's own lock.
        let lp = soroswap_pair::Client::new(&t.e, &pair);
        assert_eq!(balance(&t, &pair, &t.locker), r.liquidity);
        assert_eq!(lp.total_supply(), r.liquidity + SOROSWAP_MIN_LIQ);
        // Unsynced, the deposit counts the dust in, so the LP gets slightly more than for the amounts alone.
        let expected = if synced { lp_minted(POOL_TOKENS, POOL_QUOTE) } else { lp_minted(POOL_TOKENS, POOL_QUOTE + 7) };
        assert_eq!(r.liquidity, expected);
    }
}

#[test]
fn the_graduated_pair_trades_on_the_router() {
    let t = setup();
    let r = graduated(&t, &args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE));
    let bob = Address::generate(&t.e);
    let got = as_anyone(&t, || {
        give(&t, &t.xlm, &bob, 10 * ONE);
        let path = vec![&t.e, t.xlm.clone(), t.token.clone()];
        let deadline = t.e.ledger().timestamp() + 600;
        soroswap_router::Client::new(&t.e, &t.router).swap_exact_tokens_for_tokens(
            &(10 * ONE),
            &0,
            &path,
            &bob,
            &deadline,
        );
        balance(&t, &t.token, &bob)
    });
    assert!(got > 0);
    assert_eq!(reserves(&t, &r.pool, &t.token), (POOL_TOKENS - got, POOL_QUOTE + 10 * ONE));
}

#[test]
fn stray_balances_of_the_executor_stay_put() {
    // Anyone can send assets to the executor. It only moves what it pulled in the same call, so the source's balance
    // drops by exactly what the result reports, which the caller's checks require.
    let t = setup();
    as_anyone(&t, || {
        give(&t, &t.xlm, &t.exec, 3 * ONE);
        give(&t, &t.token, &t.exec, 5 * ONE);
    });
    let r = graduated(&t, &args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE));
    assert_eq!((balance(&t, &t.token, &t.exec), balance(&t, &t.xlm, &t.exec)), (5 * ONE, 3 * ONE));
    assert_eq!(reserves(&t, &r.pool, &t.token), (POOL_TOKENS, POOL_QUOTE));
}

// ------------------------------------------------------------------------------------------------ refusals

#[test]
fn a_source_outside_callers_fails_not_caller() {
    let t = setup();
    let before = snapshot(&t, &t.token, &t.xlm);

    // The squat attempt of reviews A1 and B1: a contract that holds both assets and signs for itself.
    let attacker = t.e.register(Harness, ());
    as_anyone(&t, || {
        give(&t, &t.token, &attacker, POOL_TOKENS);
        give(&t, &t.xlm, &attacker, POOL_QUOTE);
    });
    let a = args(&t, &attacker, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
    assert_eq!(failure(&t, &a), exec_failure(Error::NotCaller));
    assert_eq!((balance(&t, &t.token, &attacker), balance(&t, &t.xlm, &attacker)), (POOL_TOKENS, POOL_QUOTE));
    assert_eq!(snapshot(&t, &t.token, &t.xlm), before);

    // Even with every signature mocked, an account outside the callers is refused.
    let account = Address::generate(&t.e);
    let exec = ExecSoroswapClient::new(&t.e, &t.exec);
    let a = args(&t, &account, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
    assert_eq!(as_anyone(&t, || exec.try_graduate(&a)), Err(Ok(Error::NotCaller)));

    // Naming a real caller as the source doesn't help: the executor requires that caller's own authorization.
    let a = args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
    let auth_failure = GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 };
    assert_eq!(harness(&t, &attacker).attempt(&t.exec, &t.factory, &a), Attempt::Failed(auth_failure));

    assert_eq!(pair_of(&t, &t.token, &t.xlm), None);
    assert_eq!(snapshot(&t, &t.token, &t.xlm), before);
}

#[test]
fn a_pair_with_lp_supply_fails_pool_not_empty() {
    // Seeded through the router with two unlocked test assets; a real launch token is locked until graduation.
    let t = setup();
    let bob = Address::generate(&t.e);
    let pair = as_anyone(&t, || {
        give(&t, &t.token, &bob, 1_000 * ONE);
        give(&t, &t.xlm, &bob, 10 * ONE);
        let deadline = t.e.ledger().timestamp() + 600;
        soroswap_router::Client::new(&t.e, &t.router).add_liquidity(
            &t.token,
            &t.xlm,
            &(1_000 * ONE),
            &(10 * ONE),
            &0,
            &0,
            &bob,
            &deadline,
        );
        pair_of(&t, &t.token, &t.xlm).unwrap()
    });
    let bob_lp = balance(&t, &pair, &bob);
    assert!(bob_lp > 0);
    let before = snapshot(&t, &t.token, &t.xlm);

    let f = failure(&t, &args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE));
    assert_eq!(f, exec_failure(Error::PoolNotEmpty));
    assert_eq!(f.code, 10_303);
    assert_eq!(snapshot(&t, &t.token, &t.xlm), before);
    assert_eq!(balance(&t, &pair, &bob), bob_lp);
}

#[test]
fn a_failure_after_the_pull_rolls_every_balance_back() {
    // min_liquidity one above what the pair can mint: the executor has pulled both assets, created the pair and
    // deposited when it fails, and the caller's try_ frame undoes all of it.
    for precreated in [false, true] {
        let t = setup();
        if precreated {
            as_anyone(&t, || soroswap_factory::Client::new(&t.e, &t.factory).create_pair(&t.token, &t.xlm));
        }
        let before = snapshot(&t, &t.token, &t.xlm);
        let mut a = args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
        a.min_liquidity = lp_minted(POOL_TOKENS, POOL_QUOTE) + 1;

        assert_eq!(failure(&t, &a), exec_failure(Error::LiquidityTooLow));
        assert_eq!(snapshot(&t, &t.token, &t.xlm), before);
        assert_eq!(pair_of(&t, &t.token, &t.xlm).is_some(), precreated);
        if let Some(pair) = pair_of(&t, &t.token, &t.xlm) {
            assert_eq!(soroswap_pair::Client::new(&t.e, &pair).total_supply(), 0);
        }
        assert_eq!(t.e.events().all().filter_by_contract(&t.exec), []);

        // Exactly what the pair mints is enough.
        a.min_liquidity -= 1;
        assert_eq!(graduated(&t, &a).liquidity, a.min_liquidity);
    }
}

#[test]
fn amounts_must_be_positive() {
    let t = setup();
    let before = snapshot(&t, &t.token, &t.xlm);
    for (token_amount, quote_amount) in [(0, POOL_QUOTE), (POOL_TOKENS, 0), (-1, POOL_QUOTE), (POOL_TOKENS, -1)] {
        let mut a = args(&t, &t.pad, &t.token, &t.xlm, POOL_TOKENS, POOL_QUOTE);
        (a.token_amount, a.quote_amount) = (token_amount, quote_amount);
        assert_eq!(failure(&t, &a), exec_failure(Error::InvalidAmounts));
    }
    assert_eq!(snapshot(&t, &t.token, &t.xlm), before);
}

// ------------------------------------------------------------------------------------------------ errors and views

#[test]
fn error_values_lie_in_the_exec_soroswap_range() {
    let errors = [Error::NotCaller, Error::InvalidAmounts, Error::PoolNotEmpty, Error::LiquidityTooLow];
    for (n, err) in (1..).zip(errors) {
        assert_eq!(err as u32, dyor_common::err_code(TAG_EXEC_SOROSWAP, n));
        assert!((10_301..=10_304).contains(&(err as u32)));
        assert_eq!(tag_of(err as u32), Some(TAG_EXEC_SOROSWAP));
    }
}

#[test]
fn soroswap_fixture_error_codes_lie_outside_the_namespace() {
    // Finding V10: a code a Soroswap contract raises must never read as a DyorHQ contract's error.
    let mut codes = std::vec::Vec::new();
    for wasm in [soroswap_factory::WASM, soroswap_pair::WASM, soroswap_router::WASM] {
        for entry in spec_entries(wasm) {
            if let ScSpecEntry::UdtErrorEnumV0(errors) = entry {
                codes.extend(errors.cases.iter().map(|c| c.value));
            }
        }
    }
    // The pair's 101–118, the factory's 201–206 and 901, the library's 301–306 and the router's 401–409 and 501–515.
    for expected in [101, 118, 201, 206, 301, 306, 401, 409, 501, 515, 901] {
        assert!(codes.contains(&expected), "{expected} missing from the specs");
    }
    for code in codes {
        assert!(!(ERR_MIN..=ERR_MAX).contains(&code), "Soroswap code {code} inside 10_100–11_099");
        assert_eq!(tag_of(code), None);
    }
}

#[test]
fn views_return_the_constructor_arguments() {
    let t = setup();
    let exec = ExecSoroswapClient::new(&t.e, &t.exec);
    assert_eq!(exec.factory(), t.factory);
    assert_eq!(exec.callers(), vec![&t.e, t.pad.clone(), t.grad.clone()]);
    assert_eq!(exec.error_tag(), TAG_EXEC_SOROSWAP);
}

/// The spec entries in a WASM's `contractspecv0` custom section.
fn spec_entries(wasm: &[u8]) -> std::vec::Vec<ScSpecEntry> {
    fn leb128(b: &[u8], i: &mut usize) -> usize {
        let (mut v, mut shift) = (0usize, 0);
        loop {
            let byte = b[*i];
            *i += 1;
            v |= ((byte & 0x7f) as usize) << shift;
            if byte & 0x80 == 0 {
                return v;
            }
            shift += 7;
        }
    }
    assert_eq!(&wasm[..4], b"\0asm");
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let size = leb128(wasm, &mut i);
        let end = i + size;
        if id == 0 {
            let name_len = leb128(wasm, &mut i);
            if &wasm[i..i + name_len] == b"contractspecv0" {
                let mut r = Limited::new(std::io::Cursor::new(&wasm[i + name_len..end]), Limits::none());
                return ScSpecEntry::read_xdr_iter(&mut r).collect::<Result<_, _>>().unwrap();
            }
        }
        i = end;
    }
    panic!("no contractspecv0 section");
}
