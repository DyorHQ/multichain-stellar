//! qa-exec-fail called the way launchpad-v2 calls a venue (§5.5): from a harness contract that pre-authorizes the two
//! pulls with `authorize_as_current_contract` and goes through `try_graduate`. `attempt_checked` also applies the
//! launchpad's result checks, which mode `BogusSuccess` must fail.
//!
//! Auth is enforced in every graduation below: `mock_all_auths` is on only while the tests fund the callers.
extern crate std;

use super::*;
use dyor_common::{grad_failure, mul_div, tag_of, ExecutorClient, GradFailure, VenueParams, BPS, GRAD_DUST_BPS};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::testutils::{Address as _, MockAuth, MockAuthInvoke};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::xdr::ScErrorCode;
use soroban_sdk::{contracterror, panic_with_error, vec, IntoVal, InvokeError, Symbol, Val};
use std::panic::AssertUnwindSafe;

const ONE: i128 = 10_000_000; // 7 decimals
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

/// Stands in for launchpad-v2's graduation attempt: the `source` of what it sends.
#[contract]
pub struct Harness;

#[contractimpl]
impl Harness {
    /// Pre-authorizes both pulls and reports what the executor returned, without checking it.
    pub fn attempt(e: Env, executor: Address, a: GraduateArgs) -> Attempt {
        match call(&e, &executor, &a) {
            Ok(r) => Attempt::Graduated(r),
            Err(f) => Attempt::Failed(f),
        }
    }

    /// The same, with launchpad-v2's result checks for a venue of kind QaFail (§5.5: every check but the Soroswap pool
    /// lookup). A failed check aborts with `GraduationInvalid`, as the launchpad does.
    pub fn attempt_checked(e: Env, executor: Address, a: GraduateArgs) -> Attempt {
        let this = e.current_contract_address();
        let token = TokenClient::new(&e, &a.token);
        let quote = TokenClient::new(&e, &a.quote);
        let (t0, q0) = (token.balance(&this), quote.balance(&this));
        match call(&e, &executor, &a) {
            Ok(r) => {
                let within_dust = |used: i128, amount: i128| {
                    amount - mul_div(amount, GRAD_DUST_BPS as i128, BPS as i128) <= used && used <= amount
                };
                let ok = within_dust(r.token_used, a.token_amount)
                    && within_dust(r.quote_used, a.quote_amount)
                    && t0 - token.balance(&this) == r.token_used
                    && q0 - quote.balance(&this) == r.quote_used
                    && r.liquidity >= a.min_liquidity
                    && TokenClient::new(&e, &r.lp_token).balance(&a.lp_to) >= r.liquidity;
                if !ok {
                    panic_with_error!(&e, HarnessError::GraduationInvalid);
                }
                Attempt::Graduated(r)
            }
            Err(f) => Attempt::Failed(f),
        }
    }
}

/// Pre-authorizes exactly `transfer(this, executor, amount)` on both assets and calls the executor through `try_`.
fn call(e: &Env, executor: &Address, a: &GraduateArgs) -> Result<GraduateResult, GradFailure> {
    let this = e.current_contract_address();
    e.authorize_as_current_contract(vec![
        e,
        transfer_entry(e, &a.token, &this, executor, a.token_amount),
        transfer_entry(e, &a.quote, &this, executor, a.quote_amount),
    ]);
    match ExecutorClient::new(e, executor).try_graduate(a) {
        Ok(Ok(r)) => Ok(r),
        Ok(Err(_)) => panic!("the executor's result doesn't decode"),
        Err(err) => Err(grad_failure(err)),
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

// ------------------------------------------------------------------------------------------------ setup

struct T {
    e: Env,
    exec: Address,
    /// The callers: harnesses standing in for launchpad-v2 and the failing stack's graduator.
    pad: Address,
    grad: Address,
    qa_admin: Address,
    token: Address,
    quote: Address,
    locker: Address,
}

fn setup(default_mode: Mode) -> T {
    let e = Env::default();
    e.mock_all_auths();
    let pad = e.register(Harness, ());
    let grad = e.register(Harness, ());
    let qa_admin = Address::generate(&e);
    let exec = e.register(QaExecFail, (vec![&e, pad.clone(), grad.clone()], qa_admin.clone(), default_mode));
    let asset_admin = Address::generate(&e);
    let token = e.register_stellar_asset_contract_v2(asset_admin.clone()).address();
    let quote = e.register_stellar_asset_contract_v2(asset_admin).address();
    for caller in [&pad, &grad] {
        StellarAssetClient::new(&e, &token).mint(caller, &(1_000_000_000 * ONE));
        StellarAssetClient::new(&e, &quote).mint(caller, &(1_000_000 * ONE));
    }
    e.set_auths(&[]);
    T { exec, pad, grad, qa_admin, token, quote, locker: Address::generate(&e), e }
}

fn args(t: &T, source: &Address) -> GraduateArgs {
    GraduateArgs {
        source: source.clone(),
        token: t.token.clone(),
        quote: t.quote.clone(),
        token_amount: POOL_TOKENS,
        quote_amount: POOL_QUOTE,
        lp_to: t.locker.clone(),
        params: VenueParams { fee_fraction: 0 },
        min_liquidity: 1_000_000,
    }
}

fn client(t: &T) -> QaExecFailClient<'_> {
    QaExecFailClient::new(&t.e, &t.exec)
}

fn harness<'a>(t: &'a T, at: &Address) -> HarnessClient<'a> {
    HarnessClient::new(&t.e, at)
}

/// `set_mode` signed by the QA admin.
fn set_mode(t: &T, token: &Address, mode: Mode) {
    t.e.mock_auths(&[MockAuth {
        address: &t.qa_admin,
        invoke: &MockAuthInvoke {
            contract: &t.exec,
            fn_name: "set_mode",
            args: (token.clone(), mode).into_val(&t.e),
            sub_invokes: &[],
        },
    }]);
    client(t).set_mode(token, &mode);
    t.e.set_auths(&[]);
}

fn qa_failure(e: Error) -> GradFailure {
    GradFailure { origin: TAG_QA_EXEC_FAIL, code: e as u32 }
}

/// Every balance a graduation could touch: both assets of both callers, the executor and the locker.
fn balances(t: &T) -> std::vec::Vec<i128> {
    let mut v = std::vec::Vec::new();
    for asset in [&t.token, &t.quote] {
        for who in [&t.pad, &t.grad, &t.exec, &t.locker] {
            v.push(TokenClient::new(&t.e, asset).balance(who));
        }
    }
    v
}

// ------------------------------------------------------------------------------------------------ modes

#[test]
fn mode_fail_returns_a_recoverable_error_without_moving_funds() {
    let t = setup(Mode::Fail);
    let before = balances(&t);
    let f = harness(&t, &t.pad).attempt(&t.exec, &args(&t, &t.pad));
    assert_eq!(f, Attempt::Failed(qa_failure(Error::ForcedFailure)));
    assert_eq!(qa_failure(Error::ForcedFailure).code, 10_502);
    // The harness frame went on after the failure (it returned the outcome), and nothing moved.
    assert_eq!(balances(&t), before);
    // The failing Moments stack's graduator gets the same.
    let f = harness(&t, &t.grad).attempt(&t.exec, &args(&t, &t.grad));
    assert_eq!(f, Attempt::Failed(qa_failure(Error::ForcedFailure)));
}

#[test]
fn mode_exhaust_budget_fails_the_whole_harness_call() {
    let t = setup(Mode::ExhaustBudget);
    let before = balances(&t);
    t.e.cost_estimate().budget().reset_default();
    // The budget's ExceededLimit can't be caught: not by the harness's try_ (it never gets to record a failure), and not
    // by this test's try_ around the harness either. The host aborts the whole call, as it aborts a transaction.
    let call = AssertUnwindSafe(|| harness(&t, &t.pad).try_attempt(&t.exec, &args(&t, &t.pad)));
    let panic = std::panic::catch_unwind(call).expect_err("the harness call should abort");
    let message =
        panic.downcast_ref::<std::string::String>().map(|s| s.as_str()).or(panic.downcast_ref::<&str>().copied());
    assert!(message.unwrap().contains("Error(Budget, ExceededLimit)"), "{message:?}");
    t.e.cost_estimate().budget().reset_unlimited();
    assert_eq!(balances(&t), before);
}

#[test]
fn mode_bogus_success_returns_ok_and_the_launchpads_checks_reject_it() {
    let t = setup(Mode::BogusSuccess);
    let before = balances(&t);
    let a = args(&t, &t.pad);

    // Through try_ the executor answers Ok, with the inputs as the used amounts and itself as the pool.
    let r = match harness(&t, &t.pad).attempt(&t.exec, &a) {
        Attempt::Graduated(r) => r,
        f => panic!("expected a bogus success, got {f:?}"),
    };
    let bogus = GraduateResult {
        pool: t.exec.clone(),
        lp_token: t.exec.clone(),
        liquidity: a.min_liquidity,
        token_used: POOL_TOKENS,
        quote_used: POOL_QUOTE,
    };
    assert_eq!(r, bogus);
    assert_eq!(balances(&t), before);

    // launchpad-v2's result checks see that no funds moved and abort with GraduationInvalid.
    let checked = harness(&t, &t.pad).try_attempt_checked(&t.exec, &a);
    assert_eq!(checked, Err(Ok(HarnessError::GraduationInvalid.into())));
    assert_eq!(balances(&t), before);
}

// ------------------------------------------------------------------------------------------------ modes per token

#[test]
fn an_unset_token_uses_the_default_mode() {
    for default_mode in [Mode::Fail, Mode::BogusSuccess] {
        let t = setup(default_mode);
        assert_eq!(client(&t).mode(&t.token), default_mode);
        let r = harness(&t, &t.pad).attempt(&t.exec, &args(&t, &t.pad));
        match default_mode {
            Mode::Fail => assert_eq!(r, Attempt::Failed(qa_failure(Error::ForcedFailure))),
            _ => assert!(matches!(r, Attempt::Graduated(_))),
        }
    }
}

#[test]
fn set_mode_sets_one_tokens_mode() {
    let t = setup(Mode::Fail);
    let other = Address::generate(&t.e);
    set_mode(&t, &t.token, Mode::BogusSuccess);
    assert_eq!(client(&t).mode(&t.token), Mode::BogusSuccess);
    assert_eq!(client(&t).mode(&other), Mode::Fail);
    assert!(matches!(harness(&t, &t.pad).attempt(&t.exec, &args(&t, &t.pad)), Attempt::Graduated(_)));

    // Back to Fail, and the entry survives the testnet TTL policy's threshold.
    set_mode(&t, &t.token, Mode::Fail);
    assert_eq!(client(&t).mode(&t.token), Mode::Fail);
    let ttl = t.e.as_contract(&t.exec, || {
        use soroban_sdk::testutils::storage::Persistent as _;
        t.e.storage().persistent().get_ttl(&DataKey::Mode(t.token.clone()))
    });
    assert_eq!(ttl, TESTNET_TTL_POLICY.extend_to);
}

#[test]
fn set_mode_needs_the_qa_admins_signature() {
    let t = setup(Mode::Fail);
    let mode = Mode::BogusSuccess;

    // Nobody signed.
    assert!(client(&t).try_set_mode(&t.token, &mode).is_err());
    // Someone else signed.
    let intruder = Address::generate(&t.e);
    t.e.mock_auths(&[MockAuth {
        address: &intruder,
        invoke: &MockAuthInvoke {
            contract: &t.exec,
            fn_name: "set_mode",
            args: (t.token.clone(), mode).into_val(&t.e),
            sub_invokes: &[],
        },
    }]);
    assert!(client(&t).try_set_mode(&t.token, &mode).is_err());
    t.e.set_auths(&[]);
    // A caller of graduate has no say either.
    assert!(client(&t).try_set_mode(&t.token, &mode).is_err());
    assert_eq!(client(&t).mode(&t.token), Mode::Fail);

    // The QA admin.
    set_mode(&t, &t.token, mode);
    assert_eq!(client(&t).mode(&t.token), mode);
}

#[test]
fn a_mode_outside_0_to_2_is_refused() {
    let t = setup(Mode::Fail);
    t.e.mock_all_auths();
    for raw in [3u32, 99, u32::MAX] {
        let args = vec![&t.e, t.token.into_val(&t.e), raw.into_val(&t.e)];
        let r = t.e.try_invoke_contract::<Val, InvokeError>(&t.exec, &Symbol::new(&t.e, "set_mode"), args);
        assert!(r.is_err(), "mode {raw} accepted");
    }
    for (raw, mode) in [(0u32, Mode::Fail), (1, Mode::ExhaustBudget), (2, Mode::BogusSuccess)] {
        let args = vec![&t.e, t.token.into_val(&t.e), raw.into_val(&t.e)];
        t.e.invoke_contract::<()>(&t.exec, &Symbol::new(&t.e, "set_mode"), args);
        assert_eq!(client(&t).mode(&t.token), mode);
    }
}

// ------------------------------------------------------------------------------------------------ caller rule

#[test]
fn a_source_outside_callers_fails_not_caller_in_every_mode() {
    let t = setup(Mode::BogusSuccess);
    let attacker = t.e.register(Harness, ());
    for mode in [Mode::Fail, Mode::ExhaustBudget, Mode::BogusSuccess] {
        set_mode(&t, &t.token, mode);
        let f = harness(&t, &attacker).attempt(&t.exec, &args(&t, &attacker));
        assert_eq!(f, Attempt::Failed(qa_failure(Error::NotCaller)));
    }
    // An account, even with every signature mocked.
    let account = Address::generate(&t.e);
    t.e.mock_all_auths();
    assert_eq!(client(&t).try_graduate(&args(&t, &account)), Err(Ok(Error::NotCaller)));
}

#[test]
fn a_caller_named_as_source_must_authorize_the_call() {
    let t = setup(Mode::BogusSuccess);
    let attacker = t.e.register(Harness, ());
    let f = harness(&t, &attacker).attempt(&t.exec, &args(&t, &t.pad));
    let auth_failure = GradFailure { origin: dyor_common::ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 };
    assert_eq!(f, Attempt::Failed(auth_failure));
}

// ------------------------------------------------------------------------------------------------ errors and views

#[test]
fn error_values_lie_in_the_qa_exec_fail_range() {
    for (n, err) in (1..).zip([Error::NotCaller, Error::ForcedFailure, Error::NotQaAdmin]) {
        assert_eq!(err as u32, dyor_common::err_code(TAG_QA_EXEC_FAIL, n));
        assert!((10_501..=10_503).contains(&(err as u32)));
        assert_eq!(tag_of(err as u32), Some(TAG_QA_EXEC_FAIL));
    }
}

#[test]
fn views_return_the_constructor_arguments() {
    let t = setup(Mode::Fail);
    assert_eq!(client(&t).callers(), vec![&t.e, t.pad.clone(), t.grad.clone()]);
    assert_eq!(client(&t).qa_admin(), t.qa_admin);
    assert_eq!(client(&t).error_tag(), TAG_QA_EXEC_FAIL);
}
