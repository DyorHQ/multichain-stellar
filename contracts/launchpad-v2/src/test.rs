//! launchpad-v2 (§5, §18.1) against the WASMs it works with: launch-token-v2, lp-locker, exec-soroswap, exec-aquarius
//! and qa-exec-fail as built into dist/ (./build.sh writes it before the tests run), and the Soroswap and Aquarius
//! fixtures (contracts/testdata). Two test contracts stand in for venues that misbehave: a scripted executor that fails
//! once, panics if it is called again or lies about its result, and a factory that hands exec-soroswap a pair that
//! already has LP.
//!
//! Every auth is mocked unless a test says otherwise: the auth tests sign each call with one address (`mock_auths`).
extern crate std;

use super::*;
use crate::curve::{amount_out, fee_of, gross_for_net};
use dyor_common::{
    err_code, isqrt_u128, mul_div, tag_of, GradFailure, GraduateArgs, GraduateResult, SoroswapFactoryClient,
    SoroswapPairClient, ORIGIN_FOREIGN, PRODUCTION_LAUNCH_DURATIONS, SOROSWAP_MIN_LIQ, TESTNET_QA_LAUNCH_DURATIONS,
    TESTNET_TTL_POLICY,
};
use soroban_sdk::testutils::{Address as _, EnvTestConfig, Events as _, Ledger as _, MockAuth, MockAuthInvoke};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::xdr::{self, Limits, WriteXdr};
use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, IntoVal, String, Symbol, TryFromVal, TryIntoVal, Val,
};
use std::cell::Cell;
use std::panic::{catch_unwind, AssertUnwindSafe};
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
/// The shaken WASMs we deploy.
#[allow(clippy::too_many_arguments)]
mod launch_token {
    soroban_sdk::contractimport!(file = "../dist/dyor_launch_token_v2.wasm");
}
#[allow(clippy::too_many_arguments)]
mod lp_locker {
    soroban_sdk::contractimport!(file = "../dist/dyor_lp_locker.wasm");
}
mod exec_soroswap {
    soroban_sdk::contractimport!(file = "../dist/dyor_exec_soroswap.wasm");
}
mod qa_exec_fail {
    soroban_sdk::contractimport!(file = "../dist/dyor_qa_exec_fail.wasm");
}
mod exec_aquarius {
    soroban_sdk::contractimport!(file = "../dist/dyor_exec_aquarius.wasm");
}
#[allow(clippy::too_many_arguments)]
mod aquarius_router {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_router.wasm");
}
#[allow(clippy::too_many_arguments)]
mod aquarius_pool {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_pool.wasm");
}
mod aquarius_share {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_token_share.wasm");
}

const ONE: i128 = 10_000_000; // 7 decimals
const PHANTOM: i128 = 2_000 * ONE;
const START: u64 = 1_760_000_000;
const MINUTE: u64 = 60;
const HOUR: u64 = 3_600;
const DAY: u64 = 24 * HOUR;
/// O6: 10 XLM, in stroops.
const LAUNCH_FEE: i128 = 100_000_000;
/// The venue table of `setup`.
const SOROSWAP: u32 = 0;
const QA_FAIL: u32 = 1;
const SCRIPTED: u32 = 2;
const OCCUPIED: u32 = 3;
/// Far past any threshold here: a buy this big completes the curve.
const WHALE: i128 = 20_000 * ONE;

/// phantom · (√10 − 1): graduation FDV is 10× launch FDV.
fn threshold() -> i128 {
    mul_div(PHANTOM, 216_227_766, 100_000_000)
}

fn err(e: Error) -> soroban_sdk::Error {
    e.into()
}

// ------------------------------------------------------------------------------------------------ test venues

std::thread_local! {
    /// Calls of the scripted executor in this test's thread. A Rust counter, not contract storage: a failed call's
    /// storage is rolled back by the launchpad's `try_`, a counter outside the host is not.
    static CALLS: Cell<u32> = const { Cell::new(0) };
}

fn calls() -> u32 {
    CALLS.with(|c| c.get())
}

/// What the scripted executor does on `graduate`.
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Script {
    /// Seeds the Soroswap pair as exec-soroswap does and reports it truthfully.
    Honest = 0,
    /// A recoverable failure on the first call, then honest.
    FailFirst = 1,
    /// A recoverable failure on the first call, then a panic on any later one.
    FailThenPanic = 2,
    /// Seeds honestly, reports one more token used than it was sent.
    OverReport = 3,
    /// Seeds honestly, reports one quote unit less than it used.
    UnderReport = 4,
    /// Uses more than 1 bp less of the token than it was sent, returns the rest and reports that truthfully.
    ShortUse = 5,
    /// Seeds honestly, reports itself as the pool.
    WrongPool = 6,
    /// Seeds the pair but keeps the LP.
    LpElsewhere = 7,
    /// Seeds honestly, reports itself, which has no `balance`, as the LP token (as qa-exec-fail's mode 2 does): the
    /// failing balance call must be a `GraduationInvalid`, never a trap (lead ruling after CT-01..03).
    BogusLpToken = 8,
    /// Pulls one token more than the launchpad pre-authorized: the host's auth check fails inside the executor.
    PullsTooMuch = 9,
    // The lies below each pass every result check but one, so each check is needed on its own.
    /// Seeds honestly, reports one token less than it used: within the dust bound, off the balance delta.
    TokenDeltaLie = 10,
    /// Seeds honestly, then sends more than 1 bp of the quote back from its own pocket and reports it unused: the
    /// balance delta agrees, the dust bound doesn't.
    QuoteRebate = 11,
    /// Seeds honestly, reports one LP unit below the floor a fresh Soroswap pair's mint sets (§5.5).
    LowLiquidity = 12,
    /// Seeds honestly, reports the quote SAC as the LP token (which the locker holds plenty of in that test).
    LpTokenIsQuote = 13,
    /// Seeds honestly, reports the quote SAC as both the pool and the LP token.
    PoolAndLpAreQuote = 14,
    /// Leaves one unit of the quote unused, returns it and reports that truthfully: within the dust bound.
    QuoteDust = 15,
}

/// A contract error outside DyorHQ's namespace: recorded with origin 0 and code 7.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum ScriptError {
    Transient = 7,
}

#[contracttype]
#[derive(Clone)]
enum ScriptKey {
    Factory,
    Script,
}

#[contract]
pub struct ScriptedExecutor;

#[contractimpl]
impl ScriptedExecutor {
    pub fn __constructor(e: Env, factory: Address) {
        e.storage().instance().set(&ScriptKey::Factory, &factory);
        e.storage().instance().set(&ScriptKey::Script, &Script::Honest);
    }

    pub fn set_script(e: Env, script: Script) {
        e.storage().instance().set(&ScriptKey::Script, &script);
    }

    pub fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, ScriptError> {
        let call = CALLS.with(|c| {
            c.set(c.get() + 1);
            c.get()
        });
        let script: Script = e.storage().instance().get(&ScriptKey::Script).unwrap();
        match script {
            Script::FailFirst | Script::FailThenPanic if call == 1 => return Err(ScriptError::Transient),
            Script::FailThenPanic => panic!("the primary executor ran again"),
            _ => {}
        }
        a.source.require_auth();
        let this = e.current_contract_address();
        let (token, quote) = (TokenClient::new(&e, &a.token), TokenClient::new(&e, &a.quote));
        let pull = if script == Script::PullsTooMuch { a.token_amount + 1 } else { a.token_amount };
        token.transfer(&a.source, &this, &pull);
        quote.transfer(&a.source, &this, &a.quote_amount);
        let factory: Address = e.storage().instance().get(&ScriptKey::Factory).unwrap();
        let factory = SoroswapFactoryClient::new(&e, &factory);
        let pool = if factory.pair_exists(&a.token, &a.quote) {
            factory.get_pair(&a.token, &a.quote)
        } else {
            factory.create_pair(&a.token, &a.quote)
        };
        let tokens_in = match script {
            Script::ShortUse => a.token_amount - a.token_amount / 10_000 - 1,
            _ => a.token_amount,
        };
        let quote_in = if script == Script::QuoteDust { a.quote_amount - 1 } else { a.quote_amount };
        token.transfer(&this, &pool, &tokens_in);
        quote.transfer(&this, &pool, &quote_in);
        let lp_to = if script == Script::LpElsewhere { this.clone() } else { a.lp_to.clone() };
        let liquidity = SoroswapPairClient::new(&e, &pool).deposit(&lp_to);
        // What it didn't use goes back to the launchpad.
        if tokens_in < a.token_amount {
            token.transfer(&this, &a.source, &(a.token_amount - tokens_in));
        }
        if quote_in < a.quote_amount {
            quote.transfer(&this, &a.source, &(a.quote_amount - quote_in));
        }
        let mut r = GraduateResult {
            pool: pool.clone(),
            lp_token: pool,
            liquidity,
            token_used: tokens_in,
            quote_used: quote_in,
        };
        match script {
            Script::OverReport => r.token_used += 1,
            Script::UnderReport => r.quote_used -= 1,
            Script::WrongPool => r.pool = this,
            Script::BogusLpToken => r.lp_token = this,
            Script::TokenDeltaLie => r.token_used -= 1,
            Script::QuoteRebate => {
                let rebate = a.quote_amount / 10_000 + 1;
                quote.transfer(&this, &a.source, &rebate);
                r.quote_used -= rebate;
            }
            Script::LowLiquidity => {
                let fresh = isqrt_u128(a.token_amount as u128 * a.quote_amount as u128) as i128 - SOROSWAP_MIN_LIQ;
                r.liquidity = fresh - 2;
            }
            Script::LpTokenIsQuote => r.lp_token = a.quote.clone(),
            Script::PoolAndLpAreQuote => {
                r.pool = a.quote.clone();
                r.lp_token = a.quote.clone();
            }
            _ => {}
        }
        Ok(r)
    }
}

/// An executor whose success isn't a `GraduateResult`.
#[contract]
pub struct GarbledExecutor;

#[contractimpl]
impl GarbledExecutor {
    pub fn graduate(_e: Env, _a: GraduateArgs) -> u32 {
        7
    }
}

/// A factory that names one pair, which already has LP, for every token pair: exec-soroswap over it fails
/// `PoolNotEmpty`.
#[contract]
pub struct StubFactory;

#[contractimpl]
impl StubFactory {
    pub fn __constructor(e: Env, pair: Address) {
        e.storage().instance().set(&ScriptKey::Factory, &pair);
    }

    pub fn pair_exists(_e: Env, _token_a: Address, _token_b: Address) -> bool {
        true
    }

    pub fn get_pair(e: Env, _token_a: Address, _token_b: Address) -> Address {
        e.storage().instance().get(&ScriptKey::Factory).unwrap()
    }
}

/// launch-token-v2's instance keys, to read what the launchpad passed its constructor (the token has no view for the
/// venues it checks pools against).
#[contracttype]
#[derive(Clone)]
enum TokenKey {
    LockFrom,
    FixedExcluded,
    SoroswapFactory,
    AquariusRouter,
}

// ------------------------------------------------------------------------------------------------ harness

struct T {
    e: Env,
    admin: Address,
    guardian: Address,
    treasury: Address,
    creator: Address,
    alice: Address,
    bob: Address,
    xlm: Address,
    /// The XLM stand-in's classic asset, to give accounts a trustline to it.
    xlm_asset: xdr::Asset,
    quote: Address,
    factory: Address,
    router: Address,
    aquarius: Address,
    locker: Address,
    /// Venue executors, in table order.
    exec: Address,
    qa: Address,
    scripted: Address,
    occupied: Address,
    token_hash: BytesN<32>,
    pad: LaunchpadV2Client<'static>,
    nonce: Cell<u64>,
}

fn setup() -> T {
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    e.ledger().with_mut(|l| {
        l.timestamp = START;
        l.sequence_number = 1_000;
    });
    CALLS.with(|c| c.set(0));
    let g = || Address::generate(&e);
    let (admin, guardian, treasury, creator, alice, bob, qa_admin) = (g(), g(), g(), g(), g(), g(), g());
    let xlm_sac = e.register_stellar_asset_contract_v2(admin.clone());
    let xlm = xlm_sac.address();
    let quote = e.register_stellar_asset_contract_v2(admin.clone()).address();
    for who in [&creator, &alice, &bob] {
        StellarAssetClient::new(&e, &xlm).mint(who, &(100_000 * ONE));
        StellarAssetClient::new(&e, &quote).mint(who, &(1_000_000 * ONE));
    }

    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(&e, &factory).initialize(&admin, &pair_hash);
    let router = e.register(soroswap_router::WASM, ());
    soroswap_router::Client::new(&e, &router).initialize(&factory);

    // Peers name each other by precomputed ids, as deploy-contracts-v2.ts does (§3.4).
    let pad_id = g();
    let callers = vec![&e, pad_id.clone()];
    let locker = e.register(lp_locker::WASM, (callers.clone(), factory.clone(), None::<Address>, HOUR));
    let exec = e.register(exec_soroswap::WASM, (factory.clone(), callers.clone()));
    let qa = e.register(qa_exec_fail::WASM, (callers.clone(), qa_admin, qa_exec_fail::Mode::Fail));
    let scripted = e.register(ScriptedExecutor, (factory.clone(),));
    let occupied = occupied_executor(&e, &admin, &factory, &callers);
    let token_hash = e.deployer().upload_contract_wasm(launch_token::WASM);
    let aquarius = g();
    let venues = vec![
        &e,
        venue_init(VenueKind::Soroswap, &exec),
        venue_init(VenueKind::QaFail, &qa),
        venue_init(VenueKind::Soroswap, &scripted),
        venue_init(VenueKind::Soroswap, &occupied),
    ];
    e.register_at(
        &pad_id,
        LaunchpadV2,
        (
            admin.clone(),
            Some(guardian.clone()),
            treasury.clone(),
            xlm.clone(),
            token_hash.clone(),
            locker.clone(),
            factory.clone(),
            aquarius.clone(),
            LAUNCH_FEE,
            venues,
            PRODUCTION_LAUNCH_DURATIONS,
            TESTNET_TTL_POLICY,
        ),
    );
    let pad = LaunchpadV2Client::new(&e, &pad_id);
    pad.set_quote(&quote, &PHANTOM, &threshold(), &true, &vec![&e], &SOROSWAP);
    T {
        xlm_asset: xlm_sac.asset(),
        admin,
        guardian,
        treasury,
        creator,
        alice,
        bob,
        xlm,
        quote,
        factory,
        router,
        aquarius,
        locker,
        exec,
        qa,
        scripted,
        occupied,
        token_hash,
        pad,
        nonce: Cell::new(1),
        e,
    }
}

fn venue_init(kind: VenueKind, executor: &Address) -> VenueInit {
    VenueInit { kind, executor: executor.clone(), params: VenueParams { fee_fraction: 0 } }
}

/// exec-soroswap over a factory that always names a pair of two other assets that already has LP.
fn occupied_executor(e: &Env, admin: &Address, factory: &Address, callers: &Vec<Address>) -> Address {
    let (a, b) = (
        e.register_stellar_asset_contract_v2(admin.clone()).address(),
        e.register_stellar_asset_contract_v2(admin.clone()).address(),
    );
    let pair = soroswap_factory::Client::new(e, factory).create_pair(&a, &b);
    StellarAssetClient::new(e, &a).mint(&pair, &(1_000 * ONE));
    StellarAssetClient::new(e, &b).mint(&pair, &(1_000 * ONE));
    soroswap_pair::Client::new(e, &pair).deposit(admin);
    let stub = e.register(StubFactory, (pair,));
    e.register(exec_soroswap::WASM, (stub, callers.clone()))
}

/// What a test compares across a call that must change nothing.
#[derive(Debug, PartialEq)]
struct State {
    curve: Curve,
    pad_tokens: i128,
    pad_quote: i128,
    unlocked: bool,
    supply: i128,
}

impl T {
    fn params_on(&self, quote: &Address, venue: u32, sharing: bool) -> LaunchParams {
        let nonce = self.nonce.get();
        self.nonce.set(nonce + 1);
        LaunchParams {
            quote: quote.clone(),
            name: String::from_str(&self.e, "Dyor Cat"),
            symbol: String::from_str(&self.e, "DCAT"),
            uri: String::from_str(&self.e, "https://lite.dyorhq.fun/m/dcat.json"),
            creator_fee_bps: 0,
            venue,
            holder_sharing: sharing,
            creator_fee_recipient: None,
            snipe_exempt: Vec::new(&self.e),
            initial_buy: 0,
            min_tokens_out: 0,
            nonce,
        }
    }

    fn params(&self, venue: u32, sharing: bool) -> LaunchParams {
        self.params_on(&self.quote, venue, sharing)
    }

    fn terms(&self, quote: &Address, venue: u32) -> LaunchTerms {
        self.pad.preview_launch_terms(quote, &venue)
    }

    /// `p` launched by `creator` against the terms in force.
    fn launch_p(&self, creator: &Address, p: &LaunchParams) -> Address {
        self.pad.launch(creator, p, &self.terms(&p.quote, p.venue))
    }

    fn launch_on(&self, venue: u32, sharing: bool) -> Address {
        self.launch_p(&self.creator, &self.params(venue, sharing))
    }

    fn launch(&self) -> Address {
        self.launch_on(SOROSWAP, false)
    }

    /// A new quote SAC, enabled like the default one, that the traders hold.
    fn new_quote(&self) -> Address {
        let quote = self.e.register_stellar_asset_contract_v2(self.admin.clone()).address();
        for who in [&self.creator, &self.alice, &self.bob] {
            StellarAssetClient::new(&self.e, &quote).mint(who, &(1_000_000 * ONE));
        }
        self.pad.set_quote(&quote, &PHANTOM, &threshold(), &true, &vec![&self.e], &SOROSWAP);
        quote
    }

    /// A venue added through the timelock and enabled for launches; returns its id.
    fn add_venue(&self, kind: VenueKind, executor: &Address, fee_fraction: u32) -> u32 {
        let id = self.pad.propose_venue(&kind, executor, &VenueParams { fee_fraction });
        self.advance(PRODUCTION_LAUNCH_DURATIONS.timelock);
        self.pad.apply_venue(&id);
        self.pad.set_venue_enabled(&id, &true);
        id
    }

    /// `secs` later, in a later ledger.
    fn advance(&self, secs: u64) {
        self.e.ledger().with_mut(|l| {
            l.timestamp += secs;
            l.sequence_number += 1;
        });
    }

    fn now(&self) -> u64 {
        self.e.ledger().timestamp()
    }

    /// Past every snipe step.
    fn after_snipe(&self) {
        self.advance(30);
    }

    fn buy(&self, who: &Address, token: &Address, quote_in: i128) -> i128 {
        self.pad.buy(who, token, &quote_in, &0)
    }

    /// Runs `call` with auth enforced and nothing signed, then mocks every auth again. The keeper's calls need no
    /// signature, and only enforced auth proves the launchpad's exact pre-authorization of an executor's pulls.
    fn unsigned<R>(&self, call: impl FnOnce() -> R) -> R {
        self.e.set_auths(&[]);
        let r = call();
        self.e.mock_all_auths();
        r
    }

    fn graduate(&self, token: &Address) -> GraduationOutcome {
        self.unsigned(|| self.pad.graduate(token))
    }

    fn graduate_fallback(&self, token: &Address) -> GraduationOutcome {
        self.unsigned(|| self.pad.graduate_fallback(token))
    }

    /// Alice completes the curve after the snipe window.
    fn complete(&self, token: &Address) {
        self.after_snipe();
        self.buy(&self.alice, token, WHALE);
        assert_eq!(self.curve(token).phase, Phase::Completed);
    }

    fn curve(&self, token: &Address) -> Curve {
        self.pad.get_curve(token)
    }

    fn quote_of(&self, token: &Address) -> Address {
        self.pad.get_launch(token).quote
    }

    fn balance(&self, asset: &Address, who: &Address) -> i128 {
        TokenClient::new(&self.e, asset).balance(who)
    }

    fn token(&self, token: &Address) -> launch_token::Client<'_> {
        launch_token::Client::new(&self.e, token)
    }

    fn locker(&self) -> lp_locker::Client<'_> {
        lp_locker::Client::new(&self.e, &self.locker)
    }

    fn script(&self, script: Script) {
        ScriptedExecutorClient::new(&self.e, &self.scripted).set_script(&script);
    }

    fn state(&self, token: &Address) -> State {
        let quote = self.quote_of(token);
        State {
            curve: self.curve(token),
            pad_tokens: self.balance(token, &self.pad.address),
            pad_quote: self.balance(&quote, &self.pad.address),
            unlocked: self.token(token).unlocked(),
            supply: self.token(token).total_supply(),
        }
    }

    fn pair_of(&self, token: &Address) -> Option<Address> {
        let f = soroswap_factory::Client::new(&self.e, &self.factory);
        let quote = self.quote_of(token);
        f.pair_exists(token, &quote).then(|| f.get_pair(token, &quote))
    }

    /// The launchpad's instance entry as the host stores it. The host writes an instance back only when the call
    /// modified it, and a write stores a new entry, so `Rc::ptr_eq` on two reads says whether anything wrote it in
    /// between.
    fn instance_entry(&self) -> Rc<xdr::LedgerEntry> {
        let key = Rc::new(xdr::LedgerKey::ContractData(xdr::LedgerKeyContractData {
            contract: (&self.pad.address).into(),
            key: xdr::ScVal::LedgerKeyContractInstance,
            durability: xdr::ContractDataDurability::Persistent,
        }));
        self.e.host().get_ledger_entry(&key).unwrap().unwrap().0
    }

    /// A launchpad instance entry without a view: the pending admin and a guardian handoff.
    fn instance<V: TryFromVal<Env, Val>>(&self, key: DataKey) -> Option<V> {
        self.e.as_contract(&self.pad.address, || self.e.storage().instance().get(&key))
    }

    fn whitelisted(&self, account: &Address) -> bool {
        let key = DataKey::Whitelisted(account.clone());
        self.e.as_contract(&self.pad.address, || self.e.storage().persistent().get(&key).unwrap_or(false))
    }

    /// A value the launchpad passed a token's constructor, read from the token's instance.
    fn token_instance<V: TryFromVal<Env, Val>>(&self, token: &Address, key: TokenKey) -> V {
        self.e.as_contract(token, || self.e.storage().instance().get(&key).unwrap())
    }

    /// The launchpad's events in the last top-level invocation. The test host clears its event buffer whenever an
    /// invocation starts, views and token reads included, so a test takes them right after the call it checks.
    fn pad_events(&self) -> std::vec::Vec<xdr::ContractEvent> {
        self.e.events().all().filter_by_contract(&self.pad.address).events().to_vec()
    }

    fn xdr_of(&self, event: &impl soroban_sdk::Event) -> xdr::ContractEvent {
        event.to_xdr(&self.e, &self.pad.address)
    }

    /// The launchpad's events in the last top-level invocation contain `event`.
    fn emitted(&self, event: &impl soroban_sdk::Event) -> bool {
        self.pad_events().contains(&self.xdr_of(event))
    }

    /// I-L1 for `tokens`: per asset (each launch's quote, and XLM for the launch fees, which may be one asset), the
    /// launchpad holds exactly what they owe, plus `owed` of the default quote (`CreatorOwed`).
    fn assert_solvent(&self, tokens: &[Address], owed: i128) {
        let mut totals = std::vec![(self.quote.clone(), owed), (self.xlm.clone(), 0)];
        let mut add = |asset: Address, amount: i128| match totals.iter_mut().find(|(a, _)| *a == asset) {
            Some((_, sum)) => *sum += amount,
            None => totals.push((asset, amount)),
        };
        for token in tokens {
            let c = self.curve(token);
            add(self.quote_of(token), c.real_quote + c.refund_quote - c.refunded + c.creator_fees + c.protocol_fees);
            add(self.xlm.clone(), c.launch_fee_due);
        }
        for (asset, owed) in totals {
            assert_eq!(self.balance(&asset, &self.pad.address), owed, "solvency in {asset:?} (I-L1)");
        }
    }
}

/// A classic account with some XLM, and its trustlines.
fn account_id(seed: u8) -> xdr::AccountId {
    xdr::AccountId(xdr::PublicKey::PublicKeyTypeEd25519(xdr::Uint256([seed; 32])))
}

fn add_account(e: &Env, seed: u8) -> Address {
    let id = account_id(seed);
    let key = Rc::new(xdr::LedgerKey::Account(xdr::LedgerKeyAccount { account_id: id.clone() }));
    let entry = Rc::new(xdr::LedgerEntry {
        data: xdr::LedgerEntryData::Account(xdr::AccountEntry {
            account_id: id.clone(),
            balance: 1_000 * ONE as i64,
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

fn credit(code: &[u8; 4], issuer: u8) -> xdr::Asset {
    xdr::Asset::CreditAlphanum4(xdr::AlphaNum4 { asset_code: xdr::AssetCode4(*code), issuer: account_id(issuer) })
}

/// The SAC of a classic asset whose issuer account is created too.
fn classic_asset(e: &Env, code: &[u8; 4], issuer: u8) -> Address {
    add_account(e, issuer);
    let asset = credit(code, issuer).to_xdr(Limits::none()).unwrap();
    e.deployer().with_stellar_asset(Bytes::from_slice(e, &asset)).deploy()
}

/// An authorized trustline from account `holder` to `asset`.
fn add_trustline(e: &Env, holder: u8, asset: &xdr::Asset) {
    let asset = match asset {
        xdr::Asset::CreditAlphanum4(a) => xdr::TrustLineAsset::CreditAlphanum4(a.clone()),
        xdr::Asset::CreditAlphanum12(a) => xdr::TrustLineAsset::CreditAlphanum12(a.clone()),
        xdr::Asset::Native => panic!("a credit asset"),
    };
    let key = Rc::new(xdr::LedgerKey::Trustline(xdr::LedgerKeyTrustLine {
        account_id: account_id(holder),
        asset: asset.clone(),
    }));
    let entry = Rc::new(xdr::LedgerEntry {
        data: xdr::LedgerEntryData::Trustline(xdr::TrustLineEntry {
            account_id: account_id(holder),
            asset,
            balance: 0,
            limit: i64::MAX,
            flags: xdr::TrustLineFlags::AuthorizedFlag as u32,
            ext: xdr::TrustLineEntryExt::V0,
        }),
        last_modified_ledger_seq: 0,
        ext: xdr::LedgerEntryExt::V0,
    });
    e.host().add_ledger_entry(&key, &entry, None).unwrap();
}

/// A launchpad call to sign: its name, its arguments and the `try_` call, which says whether it succeeded.
type Signed<'a> = (&'a str, Vec<Val>, &'a dyn Fn() -> bool);
/// The same with the address that may sign it.
type SignedBy<'a> = (&'a str, Address, Vec<Val>, std::boxed::Box<dyn Fn() -> bool + 'a>);

/// Runs `call` with only `signer`'s signature on the launchpad call `fn_name(args)`, then mocks every auth again.
/// Returns whether the call succeeded.
fn signed_by(t: &T, signer: &Address, fn_name: &str, args: Vec<Val>, call: impl FnOnce() -> bool) -> bool {
    t.e.mock_auths(&[MockAuth {
        address: signer,
        invoke: &MockAuthInvoke { contract: &t.pad.address, fn_name, args, sub_invokes: &[] },
    }]);
    let ok = call();
    t.e.mock_all_auths();
    ok
}

/// The panic message of `call`, or `None` when it returns.
fn panic_of<R>(call: impl FnOnce() -> R) -> Option<std::string::String> {
    let hook = std::panic::take_hook();
    std::panic::set_hook(std::boxed::Box::new(|_| {}));
    let r = catch_unwind(AssertUnwindSafe(call));
    std::panic::set_hook(hook);
    r.err().map(|p| {
        p.downcast_ref::<std::string::String>()
            .cloned()
            .or(p.downcast_ref::<&str>().map(|s| std::string::String::from(*s)))
            .unwrap()
    })
}

// ------------------------------------------------------------------------------------------------ construction

#[test]
fn construction_starts_at_the_14_1_values_with_the_venue_table_in_order() {
    let t = setup();
    let c = t.pad.config();
    assert_eq!(
        (c.admin, c.guardian, c.treasury.clone()),
        (t.admin.clone(), Some(t.guardian.clone()), t.treasury.clone())
    );
    assert_eq!((c.xlm, c.token_wasm_hash, c.locker), (t.xlm.clone(), t.token_hash.clone(), t.locker.clone()));
    assert_eq!((c.soroswap_factory, c.aquarius_router), (t.factory.clone(), t.aquarius.clone()));
    assert_eq!(
        (c.supply, c.fee_bps, c.protocol_share_bps, c.max_creator_fee_bps),
        (1_000_000_000 * ONE, 100, 5_000, 1_000)
    );
    assert_eq!((c.snipe_schedule, c.snipe_step_secs), (vec![&t.e, 9_800u32, 2_500, 300, 30], 5));
    assert_eq!(c.launch_fee, 100_000_000);
    assert!(c.launches_enabled && !c.whitelist_enabled);
    assert_eq!((c.durations, c.ttl), (PRODUCTION_LAUNCH_DURATIONS, TESTNET_TTL_POLICY));
    assert_eq!(DEFAULT_SUPPLY, 1_000_000_000 * ONE);

    // Ids follow the table's order and every initial venue is enabled.
    let venues = t.pad.venues();
    let expected = [
        (VenueKind::Soroswap, &t.exec),
        (VenueKind::QaFail, &t.qa),
        (VenueKind::Soroswap, &t.scripted),
        (VenueKind::Soroswap, &t.occupied),
    ];
    assert_eq!(venues.len(), 4);
    for (id, (kind, executor)) in expected.into_iter().enumerate() {
        let v = venues.get_unchecked(id as u32);
        assert_eq!((v.id, v.kind, v.executor, v.enabled), (id as u32, kind, executor.clone(), true));
    }
    // A proposed venue takes the next id.
    assert_eq!(t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 }), 4);
    assert_eq!((t.pad.treasury(), t.pad.guardian()), (t.treasury.clone(), Some(t.guardian.clone())));
    assert_eq!(t.pad.error_tag(), dyor_common::TAG_LAUNCHPAD_V2);
}

#[derive(Clone)]
struct Ctor {
    xlm: Address,
    locker: Address,
    launch_fee: i128,
    venues: Vec<VenueInit>,
    durations: LaunchDurations,
    ttl: TtlPolicy,
}

/// Constructs a launchpad with `t`'s peers and `c`. `Err` holds the constructor's abort.
fn construct(t: &T, c: Ctor) -> Result<Address, std::string::String> {
    let args = (
        t.admin.clone(),
        None::<Address>,
        t.treasury.clone(),
        c.xlm,
        t.token_hash.clone(),
        c.locker,
        t.factory.clone(),
        t.aquarius.clone(),
        c.launch_fee,
        c.venues,
        c.durations,
        c.ttl,
    );
    let mut out = None;
    match panic_of(|| out = Some(t.e.register(LaunchpadV2, args))) {
        None => Ok(out.unwrap()),
        Some(message) => Err(message),
    }
}

#[test]
fn construction_refuses_an_invalid_config() {
    let t = setup();
    let e = &t.e;
    let base = Ctor {
        xlm: t.xlm.clone(),
        locker: t.locker.clone(),
        launch_fee: LAUNCH_FEE,
        venues: vec![e, venue_init(VenueKind::Soroswap, &t.exec)],
        durations: PRODUCTION_LAUNCH_DURATIONS,
        ttl: TESTNET_TTL_POLICY,
    };
    let account = e.register_stellar_asset_contract_v2(t.admin.clone()).issuer().address();
    let wasm_token = t.launch();
    // F6: a locker whose harvest interval differs from the durations'.
    let minute_locker =
        e.register(lp_locker::WASM, (vec![e, Address::generate(e)], t.factory.clone(), None::<Address>, MINUTE));
    let aquarius = |fee_fraction| VenueInit {
        kind: VenueKind::Aquarius,
        executor: t.exec.clone(),
        params: VenueParams { fee_fraction },
    };
    let nine = Vec::from_array(e, [(); 9].map(|_| venue_init(VenueKind::Soroswap, &t.exec)));

    let tiered = |kind| VenueInit { kind, executor: t.exec.clone(), params: VenueParams { fee_fraction: 30 } };

    let cases: [(&str, Ctor); 17] = [
        ("xlm is a Wasm token", Ctor { xlm: wasm_token, ..base.clone() }),
        ("xlm is an account", Ctor { xlm: account, ..base.clone() }),
        ("xlm is nothing", Ctor { xlm: Address::generate(e), ..base.clone() }),
        ("the locker's interval differs", Ctor { locker: minute_locker.clone(), ..base.clone() }),
        ("the locker isn't a locker", Ctor { locker: t.exec.clone(), ..base.clone() }),
        (
            "invalid durations",
            Ctor { durations: LaunchDurations { grace: 0, ..PRODUCTION_LAUNCH_DURATIONS }, ..base.clone() },
        ),
        (
            "public rescue before the admin's",
            Ctor { durations: LaunchDurations { rescue_public: DAY, ..PRODUCTION_LAUNCH_DURATIONS }, ..base.clone() },
        ),
        ("invalid TTL policy", Ctor { ttl: TtlPolicy { threshold: 0, extend_to: 10 }, ..base.clone() }),
        ("an empty venue table", Ctor { venues: Vec::new(e), ..base.clone() }),
        ("more than 8 venues", Ctor { venues: nine, ..base.clone() }),
        ("no Soroswap venue", Ctor { venues: vec![e, venue_init(VenueKind::QaFail, &t.qa)], ..base.clone() }),
        (
            "an Aquarius tier outside 10/30/100",
            Ctor { venues: vec![e, venue_init(VenueKind::Soroswap, &t.exec), aquarius(31)], ..base.clone() },
        ),
        ("a negative launch fee", Ctor { launch_fee: -1, ..base.clone() }),
        ("a launch fee above the cap", Ctor { launch_fee: MAX_LAUNCH_FEE + 1, ..base.clone() }),
        (
            "an Aquarius tier of 0",
            Ctor { venues: vec![e, venue_init(VenueKind::Soroswap, &t.exec), aquarius(0)], ..base.clone() },
        ),
        ("a tier on a Soroswap venue", Ctor { venues: vec![e, tiered(VenueKind::Soroswap)], ..base.clone() }),
        (
            "a tier on a qa-exec-fail venue",
            Ctor {
                venues: vec![e, venue_init(VenueKind::Soroswap, &t.exec), tiered(VenueKind::QaFail)],
                ..base.clone()
            },
        ),
    ];
    for (name, c) in cases {
        let refusal = construct(&t, c).expect_err(name);
        assert!(refusal.contains("Error(Contract, #10129)"), "{name}: {refusal}");
    }

    // The bounds themselves, the testnet-qa durations with a matching locker, 8 venues and the Aquarius tiers.
    construct(&t, Ctor { launch_fee: 0, ..base.clone() }).unwrap();
    construct(&t, Ctor { launch_fee: MAX_LAUNCH_FEE, ..base.clone() }).unwrap();
    construct(&t, Ctor { locker: minute_locker, durations: TESTNET_QA_LAUNCH_DURATIONS, ..base.clone() }).unwrap();
    let eight = Vec::from_array(e, [(); 8].map(|_| venue_init(VenueKind::Soroswap, &t.exec)));
    construct(&t, Ctor { venues: eight, ..base.clone() }).unwrap();
    for tier in [10, 30, 100] {
        construct(
            &t,
            Ctor { venues: vec![e, venue_init(VenueKind::Soroswap, &t.exec), aquarius(tier)], ..base.clone() },
        )
        .unwrap();
    }
    assert_eq!(MAX_LAUNCH_FEE, 1_000 * ONE);
}

// ------------------------------------------------------------------------------------------------ quotes

#[test]
fn set_quote_takes_stellar_asset_contracts_only() {
    let t = setup();
    let e = &t.e;
    let none = vec![e];
    let wasm_token = t.launch();
    let account = e.register_stellar_asset_contract_v2(t.admin.clone()).issuer().address();
    for not_a_sac in [wasm_token, account, Address::generate(e), t.exec.clone()] {
        let r = t.pad.try_set_quote(&not_a_sac, &PHANTOM, &threshold(), &true, &none, &SOROSWAP);
        assert_eq!(r.unwrap_err().unwrap(), err(Error::QuoteNotSac));
        assert_eq!(t.pad.quote_economics(&not_a_sac), None);
    }
    // A Stellar Asset Contract is accepted (I-L11).
    let sac = e.register_stellar_asset_contract_v2(t.admin.clone()).address();
    t.pad.set_quote(&sac, &PHANTOM, &threshold(), &true, &vec![e, QA_FAIL], &SOROSWAP);
    let set = QuoteSet {
        quote: sac.clone(),
        phantom: PHANTOM,
        threshold: threshold(),
        enabled: true,
        venues_allowed: vec![e, QA_FAIL],
        fallback_venue: SOROSWAP,
    };
    assert!(t.emitted(&set));
    let econ = QuoteEconomics {
        phantom: PHANTOM,
        threshold: threshold(),
        enabled: true,
        venues_allowed: vec![e, QA_FAIL],
        fallback_venue: SOROSWAP,
    };
    assert_eq!(t.pad.quote_economics(&sac), Some(econ));
}

#[test]
fn set_quote_checks_the_economics_and_the_venues() {
    let t = setup();
    let e = &t.e;
    let q = e.register_stellar_asset_contract_v2(t.admin.clone()).address();
    let none = vec![e];
    let fails = |phantom: i128, threshold: i128, enabled: bool, allowed: &Vec<u32>, fallback: u32| {
        t.pad.try_set_quote(&q, &phantom, &threshold, &enabled, allowed, &fallback).unwrap_err().unwrap()
    };
    assert_eq!(fails(0, threshold(), true, &none, SOROSWAP), err(Error::InvalidEconomics));
    assert_eq!(fails(PHANTOM, 0, true, &none, SOROSWAP), err(Error::InvalidEconomics));
    assert_eq!(fails(-1, threshold(), false, &none, SOROSWAP), err(Error::InvalidEconomics));
    assert_eq!(fails(PHANTOM, threshold(), true, &vec![e, 9], SOROSWAP), err(Error::UnknownVenue));
    assert_eq!(fails(PHANTOM, threshold(), true, &none, 9), err(Error::UnknownVenue));
    // The fallback must be a Soroswap venue.
    assert_eq!(fails(PHANTOM, threshold(), true, &none, QA_FAIL), err(Error::InvalidEconomics));
    assert_eq!(
        fails(PHANTOM, threshold(), true, &Vec::from_array(e, [0u32; 9]), SOROSWAP),
        err(Error::InvalidEconomics)
    );
    // A disabled quote may carry zeros.
    t.pad.set_quote(&q, &0, &0, &false, &none, &SCRIPTED);
    let p = t.params_on(&q, SOROSWAP, false);
    assert_eq!(t.pad.try_preview_launch_terms(&q, &SOROSWAP).unwrap_err().unwrap(), err(Error::QuoteNotAllowed));
    assert_eq!(
        t.pad.try_launch(&t.creator, &p, &t.terms(&t.quote, SOROSWAP)).unwrap_err().unwrap(),
        err(Error::QuoteNotAllowed)
    );
}

// ------------------------------------------------------------------------------------------------ launch

#[test]
fn launch_deploys_token_and_opens_curve() {
    let t = setup();
    let p = t.params(SOROSWAP, false);
    let token = t.launch_p(&t.creator, &p);
    let events = t.pad_events();
    let sep41 = TokenClient::new(&t.e, &token);
    let tok = t.token(&token);
    assert_eq!(sep41.symbol(), String::from_str(&t.e, "DCAT"));
    assert_eq!(sep41.name(), String::from_str(&t.e, "Dyor Cat"));
    assert_eq!(sep41.decimals(), 7);
    assert_eq!(sep41.balance(&t.pad.address), DEFAULT_SUPPLY);
    assert_eq!((tok.launchpad(), tok.locker()), (t.pad.address.clone(), t.locker.clone()));
    assert!(!tok.unlocked());
    assert_eq!(tok.sharing(), None);

    let l = t.pad.get_launch(&token);
    let venue = t.pad.venues().get_unchecked(SOROSWAP);
    assert_eq!((l.token, l.creator, l.quote), (token.clone(), t.creator.clone(), t.quote.clone()));
    assert_eq!((l.name, l.symbol, l.uri), (p.name.clone(), p.symbol.clone(), p.uri.clone()));
    assert_eq!((l.nonce, l.created_at, l.created_ledger), (p.nonce, START, 1_000));
    assert_eq!((l.fee_bps, l.protocol_share_bps, l.creator_fee_bps), (100, 5_000, 0));
    assert_eq!((l.snipe_schedule, l.snipe_step_secs), (vec![&t.e, 9_800u32, 2_500, 300, 30], 5));
    assert_eq!((l.venue, l.fallback.clone()), (venue.clone(), venue));
    assert!(!l.venue_locked && !l.holder_sharing);
    assert_eq!(l.launch_fee_paid, LAUNCH_FEE);

    let c = t.curve(&token);
    assert_eq!((c.phantom, c.threshold), (PHANTOM, threshold()));
    assert_eq!((c.quote_reserve, c.token_reserve, c.real_quote), (PHANTOM, DEFAULT_SUPPLY, 0));
    assert_eq!((c.creator_fees, c.protocol_fees, c.launch_fee_due), (0, 0, LAUNCH_FEE));
    assert_eq!((c.phase, c.completed_at, c.stuck_since, c.pool, c.graduated_venue), (Phase::Curve, 0, 0, None, None));
    assert_eq!(t.pad.creator_fee_recipient(&token), t.creator);

    let s = t.pad.status(&token);
    assert_eq!(
        (s.phase, s.mark_stuck_at, s.fallback_at, s.rescue_admin_at, s.rescue_public_at),
        (Phase::Curve, 0, 0, 0, 0)
    );

    let launched = Launched {
        token: token.clone(),
        creator: t.creator.clone(),
        quote: t.quote.clone(),
        name: p.name,
        symbol: p.symbol,
        uri: p.uri,
        nonce: p.nonce,
        supply: DEFAULT_SUPPLY,
        phantom: PHANTOM,
        threshold: threshold(),
        fee_bps: 100,
        protocol_share_bps: 5_000,
        creator_fee_bps: 0,
        venue: SOROSWAP,
        fallback_venue: SOROSWAP,
        venue_locked: false,
        holder_sharing: false,
        recipient: t.creator.clone(),
        launch_fee: LAUNCH_FEE,
    };
    // The launch event first, then the booked fee.
    let booked = LaunchFeeBooked { token, payer: t.creator.clone(), asset: t.xlm.clone(), amount: LAUNCH_FEE };
    assert_eq!(events, [t.xdr_of(&launched), t.xdr_of(&booked)]);
}

#[test]
fn launch_rejects_bad_input() {
    let t = setup();
    let e = &t.e;
    let s = |v: &str| String::from_str(e, v);
    let terms = t.terms(&t.quote, SOROSWAP);
    let refused = |edit: &dyn Fn(&mut LaunchParams)| {
        let mut p = t.params(SOROSWAP, false);
        edit(&mut p);
        t.pad.try_launch(&t.creator, &p, &terms).unwrap_err().unwrap()
    };
    assert_eq!(refused(&|p| p.name = s("")), err(Error::InvalidName));
    assert_eq!(refused(&|p| p.name = s("abcdefghijklmnopqrstuvwxyz0123456")), err(Error::InvalidName)); // 33 bytes
    assert_eq!(refused(&|p| p.symbol = s("")), err(Error::InvalidSymbol));
    assert_eq!(refused(&|p| p.symbol = s("TOOLONGSYMBOL")), err(Error::InvalidSymbol));
    let long_uri = std::string::String::from_utf8(std::vec![b'u'; 257]).unwrap();
    assert_eq!(refused(&|p| p.uri = s(&long_uri)), err(Error::InvalidUri));
    assert_eq!(refused(&|p| p.creator_fee_bps = 1_001), err(Error::CreatorFeeTooHigh));
    assert_eq!(refused(&|p| p.initial_buy = -1), err(Error::ZeroAmount));
    let exempt_33 = Vec::from_array(e, [(); 33].map(|_| Address::generate(e)));
    assert_eq!(refused(&|p| p.snipe_exempt = exempt_33.clone()), err(Error::TooManyExemptions));
    assert_eq!(refused(&|p| p.venue = 9), err(Error::VenueNotAllowed));
    let other = e.register_stellar_asset_contract_v2(t.admin.clone()).address();
    assert_eq!(refused(&|p| p.quote = other.clone()), err(Error::QuoteNotAllowed));

    // The limits themselves are fine: 32-byte name, 12-byte symbol, 256-byte URI, the cap, 32 exemptions.
    let long_uri = std::string::String::from_utf8(std::vec![b'u'; 256]).unwrap();
    let mut p = t.params(SOROSWAP, false);
    p.name = s("abcdefghijklmnopqrstuvwxyz012345");
    p.symbol = s("TWELVECHARSS");
    p.uri = s(&long_uri);
    p.creator_fee_bps = 1_000;
    p.snipe_exempt = Vec::from_array(e, [(); 32].map(|_| Address::generate(e)));
    t.pad.launch(&t.creator, &p, &terms);

    t.pad.set_launches_enabled(&false);
    assert_eq!(refused(&|_| {}), err(Error::LaunchesDisabled));
    t.pad.set_launches_enabled(&true);
    t.launch();
}

#[test]
fn a_terms_mismatch_in_any_field_fails_terms_changed() {
    let t = setup();
    let e = &t.e;
    let good = t.terms(&t.quote, SOROSWAP);
    let other = Address::generate(e);
    type Edit = fn(&mut LaunchTerms, &Env, &Address);
    let edits: [(&str, Edit); 33] = [
        ("supply", |x, _, _| x.supply -= 1),
        ("fee_bps", |x, _, _| x.fee_bps += 1),
        ("protocol_share_bps", |x, _, _| x.protocol_share_bps -= 1),
        ("max_creator_fee_bps", |x, _, _| x.max_creator_fee_bps += 1),
        ("snipe_schedule", |x, e, _| x.snipe_schedule = vec![e, 9_800u32, 2_500, 300]),
        ("snipe_step_secs", |x, _, _| x.snipe_step_secs = 1),
        ("launch_fee", |x, _, _| x.launch_fee -= 1),
        ("fee_asset", |x, _, a| x.fee_asset = a.clone()),
        ("quote", |x, _, a| x.quote = a.clone()),
        ("phantom", |x, _, _| x.phantom += 1),
        ("threshold", |x, _, _| x.threshold -= 1),
        ("venue.id", |x, _, _| x.venue.id = SCRIPTED),
        ("venue.kind", |x, _, _| x.venue.kind = VenueKind::Aquarius),
        ("venue.executor", |x, _, a| x.venue.executor = a.clone()),
        ("venue.params", |x, _, _| x.venue.params.fee_fraction = 30),
        ("venue.enabled", |x, _, _| x.venue.enabled = false),
        ("fallback.id", |x, _, _| x.fallback.id = SCRIPTED),
        ("fallback.executor", |x, _, a| x.fallback.executor = a.clone()),
        ("venue_locked", |x, _, _| x.venue_locked = true),
        ("locker", |x, _, a| x.locker = a.clone()),
        ("token_wasm_hash", |x, e, _| x.token_wasm_hash = BytesN::from_array(e, &[7; 32])),
        ("durations.grace", |x, _, _| x.durations.grace += 1),
        ("durations.fallback_delay", |x, _, _| x.durations.fallback_delay += 1),
        ("durations.rescue_admin", |x, _, _| x.durations.rescue_admin += 1),
        ("durations.rescue_public", |x, _, _| x.durations.rescue_public += 1),
        ("durations.locked_fallback", |x, _, _| x.durations.locked_fallback += 1),
        ("durations.takeover_delay", |x, _, _| x.durations.takeover_delay += 1),
        ("durations.takeover_window", |x, _, _| x.durations.takeover_window += 1),
        ("durations.timelock", |x, _, _| x.durations.timelock += 1),
        ("durations.timelock_window", |x, _, _| x.durations.timelock_window += 1),
        ("durations.harvest_interval", |x, _, _| x.durations.harvest_interval = MINUTE),
        ("durations (testnet-qa set)", |x, _, _| x.durations = TESTNET_QA_LAUNCH_DURATIONS),
        ("fallback.kind", |x, _, _| x.fallback.kind = VenueKind::QaFail),
    ];
    let p = t.params(SOROSWAP, false);
    for (field, edit) in edits {
        let mut bad = good.clone();
        edit(&mut bad, e, &other);
        assert_ne!(bad, good, "{field}");
        assert_eq!(t.pad.try_launch(&t.creator, &p, &bad).unwrap_err().unwrap(), err(Error::TermsChanged), "{field}");
    }
    t.pad.launch(&t.creator, &p, &good);

    // Terms read before an admin change are stale after it.
    let stale = t.terms(&t.quote, SOROSWAP);
    t.pad.set_launch_fee(&(5 * ONE));
    let p = t.params(SOROSWAP, false);
    assert_eq!(t.pad.try_launch(&t.creator, &p, &stale).unwrap_err().unwrap(), err(Error::TermsChanged));
    t.pad.launch(&t.creator, &p, &t.terms(&t.quote, SOROSWAP));
}

#[test]
fn the_launch_fee_moves_only_from_the_creator_to_the_launchpad_and_is_booked() {
    let t = setup();
    assert_eq!(LAUNCH_FEE, 100_000_000);
    let xlm = |who: &Address| t.balance(&t.xlm, who);
    let (creator0, pad0, treasury0) = (xlm(&t.creator), xlm(&t.pad.address), xlm(&t.treasury));
    let token = t.launch();
    assert_eq!(xlm(&t.creator), creator0 - LAUNCH_FEE);
    assert_eq!(xlm(&t.pad.address), pad0 + LAUNCH_FEE);
    // Booked, never pushed to the treasury inside launch (B10).
    assert_eq!(xlm(&t.treasury), treasury0);
    assert_eq!(t.curve(&token).launch_fee_due, LAUNCH_FEE);
    assert_eq!(t.pad.get_launch(&token).launch_fee_paid, LAUNCH_FEE);

    // Without the creator's signature nothing happens.
    let p = t.params(SOROSWAP, false);
    let terms = t.terms(&t.quote, SOROSWAP);
    t.e.set_auths(&[]);
    assert!(t.pad.try_launch(&t.creator, &p, &terms).is_err());
    // Signed by someone else, neither.
    let ok = signed_by(&t, &t.alice, "launch", (t.creator.clone(), p.clone(), terms.clone()).into_val(&t.e), || {
        t.pad.try_launch(&t.creator, &p, &terms).is_ok()
    });
    assert!(!ok);
    assert_eq!((xlm(&t.creator), xlm(&t.pad.address)), (creator0 - LAUNCH_FEE, pad0 + LAUNCH_FEE));
    let unlaunched = t.pad.token_address(&t.creator, &p.nonce);
    assert!(t.e.as_contract(&t.pad.address, || !t.e.storage().persistent().has(&DataKey::Launch(unlaunched))));

    // A zero fee books and moves nothing.
    t.pad.set_launch_fee(&0);
    let free = t.launch();
    assert_eq!(t.pad_events().len(), 1, "launch only, no fee_booked");
    assert_eq!(t.curve(&free).launch_fee_due, 0);
    assert_eq!(xlm(&t.creator), creator0 - LAUNCH_FEE);
    t.assert_solvent(&[token, free], 0);
}

#[test]
fn the_creator_and_the_nonce_fix_the_address_and_a_nonce_is_used_once() {
    let t = setup();
    let p = t.params(SOROSWAP, false);
    let terms = t.terms(&t.quote, SOROSWAP);
    let predicted = t.pad.token_address(&t.creator, &p.nonce);
    let token = t.pad.launch(&t.creator, &p, &terms);
    assert_eq!(token, predicted);
    // Reused: refused, and nothing moves.
    let before = t.balance(&t.xlm, &t.creator);
    assert_eq!(t.pad.try_launch(&t.creator, &p, &terms).unwrap_err().unwrap(), err(Error::NonceUsed));
    assert_eq!(t.balance(&t.xlm, &t.creator), before);
    // The same nonce is another address for another creator.
    let other = t.pad.launch(&t.alice, &p, &terms);
    assert_ne!(other, token);
    assert_eq!(other, t.pad.token_address(&t.alice, &p.nonce));
    assert_eq!(t.pad.get_launch(&other).creator, t.alice);
}

#[test]
fn two_launches_built_on_the_same_state_both_apply_and_launch_writes_no_instance_key() {
    let t = setup();
    // Both plans read the same state: the same terms, each its own predicted address.
    let terms = t.terms(&t.quote, SOROSWAP);
    let (pa, pb) = (t.params(SOROSWAP, true), t.params(SOROSWAP, false));
    let (a_at, b_at) = (t.pad.token_address(&t.creator, &pa.nonce), t.pad.token_address(&t.alice, &pb.nonce));
    let instance = t.instance_entry();
    let a = t.pad.launch(&t.creator, &pa, &terms);
    assert!(Rc::ptr_eq(&t.instance_entry(), &instance), "launch wrote the launchpad's instance");
    let b = t.pad.launch(&t.alice, &pb, &terms);
    assert_eq!((a, b), (a_at, b_at));
    // With an initial buy, then plain trades and claims: still no instance write (§3.5, B6).
    let mut pc = t.params(SOROSWAP, false);
    pc.initial_buy = 10 * ONE;
    let c = t.pad.launch(&t.bob, &pc, &terms);
    t.after_snipe();
    let got = t.buy(&t.alice, &c, 50 * ONE);
    t.pad.sell(&t.alice, &c, &(got / 2), &0);
    t.pad.claim_creator_fees(&c);
    t.pad.claim_protocol_fees(&vec![&t.e, c]);
    assert!(Rc::ptr_eq(&t.instance_entry(), &instance), "a trade or a claim wrote the launchpad's instance");
    // The check sees a write: an admin setter does write the instance.
    t.pad.set_launches_enabled(&true);
    assert!(!Rc::ptr_eq(&t.instance_entry(), &instance));
}

#[test]
fn the_whitelist_gates_launches_when_it_is_on() {
    let t = setup();
    t.pad.set_whitelist_enabled(&true);
    let p = t.params(SOROSWAP, false);
    let terms = t.terms(&t.quote, SOROSWAP);
    assert_eq!(t.pad.try_launch(&t.creator, &p, &terms).unwrap_err().unwrap(), err(Error::NotWhitelisted));
    t.pad.set_whitelisted(&t.creator, &true);
    assert!(t.whitelisted(&t.creator));
    t.pad.launch(&t.creator, &p, &terms);
    t.pad.set_whitelisted(&t.creator, &false);
    assert!(!t.whitelisted(&t.creator));
    let p = t.params(SOROSWAP, false);
    assert_eq!(t.pad.try_launch(&t.creator, &p, &terms).unwrap_err().unwrap(), err(Error::NotWhitelisted));
    t.pad.set_whitelist_enabled(&false);
    t.pad.launch(&t.creator, &p, &terms);
}

#[test]
fn the_venue_allowlist_and_the_venue_locked_flag() {
    let t = setup();
    let e = &t.e;
    // A quote allowed only on the failing venue, with Soroswap as its fallback: venue-locked (the Monday-only analogue).
    let qa_quote = t.new_quote();
    t.pad.set_quote(&qa_quote, &PHANTOM, &threshold(), &true, &vec![e, QA_FAIL], &SOROSWAP);
    let terms = t.terms(&qa_quote, QA_FAIL);
    assert!(terms.venue_locked);
    assert_eq!((terms.venue.id, terms.fallback.id), (QA_FAIL, SOROSWAP));
    assert_eq!(t.pad.try_preview_launch_terms(&qa_quote, &SOROSWAP).unwrap_err().unwrap(), err(Error::VenueNotAllowed));
    let token = t.launch_p(&t.creator, &t.params_on(&qa_quote, QA_FAIL, false));
    assert!(t.pad.get_launch(&token).venue_locked);
    assert_eq!(t.token(&token).lock_from(), vec![e, t.qa.clone(), t.exec.clone()]);

    // An allowlist that names the fallback isn't locked; neither is an empty one.
    t.pad.set_quote(&qa_quote, &PHANTOM, &threshold(), &true, &vec![e, QA_FAIL, SOROSWAP], &SOROSWAP);
    assert!(!t.terms(&qa_quote, QA_FAIL).venue_locked);
    assert!(!t.terms(&t.quote, QA_FAIL).venue_locked);

    // A disabled venue is closed to new launches; a disabled fallback closes its quote.
    t.pad.set_venue_enabled(&SCRIPTED, &false);
    assert_eq!(t.pad.try_preview_launch_terms(&t.quote, &SCRIPTED).unwrap_err().unwrap(), err(Error::VenueNotAllowed));
    t.pad.set_venue_enabled(&SOROSWAP, &false);
    assert_eq!(t.pad.try_preview_launch_terms(&t.quote, &QA_FAIL).unwrap_err().unwrap(), err(Error::VenueNotAllowed));
    assert_eq!(t.pad.try_set_venue_enabled(&9, &true).unwrap_err().unwrap(), err(Error::UnknownVenue));
    // The live launch keeps the venue and the fallback it pinned (I-L4).
    let l = t.pad.get_launch(&token);
    assert!(l.venue.enabled && l.fallback.enabled);
    t.pad.set_venue_enabled(&SOROSWAP, &true);
    assert!(t.terms(&t.quote, QA_FAIL).fallback.enabled);
}

#[test]
fn every_token_gets_the_aquarius_router_its_executors_and_the_treasury_excluded() {
    let t = setup();
    for (venue, executor, sharing) in [(SOROSWAP, &t.exec, false), (SCRIPTED, &t.scripted, true)] {
        let token = t.launch_on(venue, sharing);
        let tok = t.token(&token);
        assert_eq!(t.token_instance::<Address>(&token, TokenKey::AquariusRouter), t.aquarius, "F2");
        assert_eq!(t.token_instance::<Address>(&token, TokenKey::SoroswapFactory), t.factory);
        // lock_from = dedup[venue executor, fallback executor]; fixed_excluded = dedup[launchpad, locker, both].
        let mut lock_from = vec![&t.e, executor.clone()];
        if *executor != t.exec {
            lock_from.push_back(t.exec.clone());
        }
        assert_eq!(t.token_instance::<Vec<Address>>(&token, TokenKey::LockFrom), lock_from);
        assert_eq!(tok.lock_from(), lock_from);
        let fixed: Vec<Address> = t.token_instance(&token, TokenKey::FixedExcluded);
        let mut expected = vec![&t.e, t.pad.address.clone(), t.locker.clone()];
        expected.append(&lock_from);
        expected.push_back(token.clone());
        assert_eq!(fixed, expected);
        for a in expected.iter() {
            assert!(tok.is_excluded(&a));
        }
        // With sharing on, the treasury of the moment is excluded from birth (V2).
        assert_eq!(tok.is_excluded(&t.treasury), sharing);
        assert_eq!(tok.sharing().map(|s| s.quote), sharing.then(|| t.quote.clone()));
    }
}

// ------------------------------------------------------------------------------------------------ snipe tax (L11)

#[test]
fn snipe_tax_by_5_second_steps_and_creator_exemption() {
    let t = setup();
    let token = t.launch();
    let launched = t.now();
    let amount = 100 * ONE;
    for (offset, bps) in
        [(0, 9_800), (4, 9_800), (5, 2_500), (9, 2_500), (10, 300), (14, 300), (15, 30), (19, 30), (20, 0), (HOUR, 0)]
    {
        t.e.ledger().with_mut(|l| l.timestamp = launched + offset);
        let q = t.pad.quote_buy(&token, &t.alice, &amount);
        // The snipe tax gives way first under the 99% cap; the snipe bucket also absorbs the total's rounding.
        let total = core::cmp::min(100 + bps, MAX_TOTAL_BPS);
        assert_eq!(q.snipe_fee, fee_of(amount, total) - fee_of(amount, 100), "offset {offset}");
        assert_eq!(q.net, amount - fee_of(amount, total), "offset {offset}");
        // The creator never pays it.
        assert_eq!(t.pad.quote_buy(&token, &t.creator, &amount).snipe_fee, 0);
    }
    // A buy in the second step pays 25%, split like the curve fee (§5.5).
    t.e.ledger().with_mut(|l| l.timestamp = launched + 7);
    t.buy(&t.bob, &token, amount);
    let c = t.curve(&token);
    let shared = fee_of(amount, 100) + fee_of(amount, 2_500);
    assert_eq!((c.protocol_fees, c.creator_fees), (shared / 2, shared - shared / 2));
}

#[test]
fn exempt_buyers_the_creator_and_the_initial_recipient_pay_no_snipe_tax() {
    let t = setup();
    let (friend, recipient, stranger) = (Address::generate(&t.e), Address::generate(&t.e), Address::generate(&t.e));
    let mut p = t.params(SOROSWAP, false);
    p.snipe_exempt = vec![&t.e, friend.clone()];
    p.creator_fee_recipient = Some(recipient.clone());
    let token = t.launch_p(&t.creator, &p);
    for who in [&friend, &t.creator, &recipient] {
        assert_eq!(t.pad.quote_buy(&token, who, &(100 * ONE)).snipe_fee, 0);
    }
    assert_eq!(t.pad.quote_buy(&token, &stranger, &(100 * ONE)).snipe_fee, fee_of(100 * ONE, 9_800));
    // The friend buys in the launch ledger and pays the curve fee only.
    StellarAssetClient::new(&t.e, &t.quote).mint(&friend, &(100 * ONE));
    let got = t.buy(&friend, &token, 100 * ONE);
    assert_eq!(got, amount_out(99 * ONE, PHANTOM, DEFAULT_SUPPLY));
    assert_eq!(t.curve(&token).protocol_fees, ONE / 2);
}

#[test]
fn creator_initial_buy_is_exempt_and_in_the_same_call() {
    let t = setup();
    let mut p = t.params(SOROSWAP, false);
    p.initial_buy = 50 * ONE;
    let expected = amount_out(50 * ONE - fee_of(50 * ONE, 100), PHANTOM, DEFAULT_SUPPLY);
    p.min_tokens_out = expected + 1;
    let terms = t.terms(&t.quote, SOROSWAP);
    assert_eq!(t.pad.try_launch(&t.creator, &p, &terms).unwrap_err().unwrap(), err(Error::SlippageExceeded));
    p.min_tokens_out = expected;
    let token = t.pad.launch(&t.creator, &p, &terms);
    // The launch, the booked fee, then the trade.
    assert_eq!(t.pad_events().len(), 3);
    assert_eq!(t.balance(&token, &t.creator), expected);
}

// ------------------------------------------------------------------------------------------------ trading

#[test]
fn buy_and_sell_move_the_curve_and_accrue_fees() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    let before = t.balance(&t.quote, &t.alice);
    let got = t.buy(&t.alice, &token, 100 * ONE);
    let events = t.pad_events();
    assert_eq!(t.balance(&t.quote, &t.alice), before - 100 * ONE);
    assert_eq!(t.balance(&token, &t.alice), got);
    // 1% fee: 0.5 booked for the protocol and 0.5 for the creator, on the launch itself; 99 enter the curve.
    let c = t.curve(&token);
    assert_eq!(c.real_quote, 99 * ONE);
    assert_eq!((c.creator_fees, c.protocol_fees), (ONE / 2, ONE / 2));
    assert_eq!(got, amount_out(99 * ONE, PHANTOM, DEFAULT_SUPPLY));
    let trade = Trade {
        token: token.clone(),
        trader: t.alice.clone(),
        is_buy: true,
        quote_amount: 100 * ONE,
        token_amount: got,
        base_fee: ONE,
        snipe_fee: 0,
        creator_fee: 0,
        protocol_part: ONE / 2,
        creator_part: ONE / 2,
        holder_part: 0,
        quote_reserve: PHANTOM + 99 * ONE,
        token_reserve: DEFAULT_SUPPLY - got,
        real_quote: 99 * ONE,
    };
    assert_eq!(events, [t.xdr_of(&trade)]);

    let back = t.pad.sell(&t.alice, &token, &(got / 2), &0);
    // The second half of a buy is the pricier half, so selling it back returns a bit more than half the net
    // quote, minus the 1% fee; never more than was paid.
    assert!(back > 49 * ONE && back < 51 * ONE, "{back}");
    assert_eq!(t.balance(&token, &t.alice), got - got / 2);
    t.assert_solvent(std::slice::from_ref(&token), 0);

    // Slippage guards and zero amounts.
    let q = t.pad.quote_buy(&token, &t.bob, &(10 * ONE));
    assert_eq!(
        t.pad.try_buy(&t.bob, &token, &(10 * ONE), &(q.tokens_out + 1)).unwrap_err().unwrap(),
        err(Error::SlippageExceeded)
    );
    assert_eq!(t.pad.buy(&t.bob, &token, &(10 * ONE), &q.tokens_out), q.tokens_out);
    let s = t.pad.quote_sell(&token, &(q.tokens_out / 2));
    assert_eq!(
        t.pad.try_sell(&t.bob, &token, &(q.tokens_out / 2), &(s.quote_out + 1)).unwrap_err().unwrap(),
        err(Error::SlippageExceeded)
    );
    assert_eq!(t.pad.sell(&t.bob, &token, &(q.tokens_out / 2), &s.quote_out), s.quote_out);
    assert_eq!(t.pad.try_buy(&t.bob, &token, &0, &0).unwrap_err().unwrap(), err(Error::ZeroAmount));
    assert_eq!(t.pad.try_sell(&t.bob, &token, &0, &0).unwrap_err().unwrap(), err(Error::ZeroAmount));
    assert_eq!(t.pad.try_quote_buy(&token, &t.bob, &0).unwrap_err().unwrap(), err(Error::ZeroAmount));
    assert_eq!(t.pad.try_quote_sell(&token, &-1).unwrap_err().unwrap(), err(Error::ZeroAmount));
    // A sell can't take more than the curve's real quote: tokens from outside the curve don't count.
    assert_eq!(
        t.pad.try_sell(&t.alice, &token, &(DEFAULT_SUPPLY / 2), &0).unwrap_err().unwrap(),
        err(Error::InsufficientLiquidity)
    );
    assert_eq!(
        t.pad.try_quote_sell(&token, &(DEFAULT_SUPPLY / 2)).unwrap_err().unwrap(),
        err(Error::InsufficientLiquidity)
    );
    assert_eq!(
        t.pad.try_buy(&t.bob, &Address::generate(&t.e), &ONE, &0).unwrap_err().unwrap(),
        err(Error::UnknownLaunch)
    );
    t.assert_solvent(&[token], 0);
}

#[test]
fn tokens_are_curve_only_before_graduation() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    let got = t.buy(&t.alice, &token, 10 * ONE);
    let tok = TokenClient::new(&t.e, &token);
    assert!(tok.try_transfer(&t.alice, &t.bob, &got).is_err());
    // To the launchpad is allowed (L4): it only adds to what graduation burns.
    tok.transfer(&t.alice, &t.pad.address, &1);
}

#[test]
fn last_buy_is_clamped_and_completes_the_curve() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    let before = t.balance(&t.quote, &t.alice);
    t.buy(&t.alice, &token, WHALE);
    assert!(t.emitted(&Completed { token: token.clone(), real_quote: threshold(), completed_at: t.now() }));
    let paid = before - t.balance(&t.quote, &t.alice);
    let c = t.curve(&token);
    assert_eq!(c.phase, Phase::Completed);
    // Monad's clamp (I-L7): exactly the threshold, never past it.
    assert_eq!(c.real_quote, threshold());
    assert_eq!((c.completed_at, c.stuck_since), (t.now(), 0));
    assert!(paid < WHALE);
    assert_eq!(paid, gross_for_net(threshold(), 100));
    // About 31.6% of the supply is left for the pool and the burn.
    let pct = mul_div(c.token_reserve, 1_000, DEFAULT_SUPPLY);
    assert!((315..=317).contains(&pct), "{pct}");
    // Trading has stopped; graduation is a later call (L3).
    assert_eq!(t.pad.try_buy(&t.bob, &token, &ONE, &0).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert_eq!(t.pad.try_sell(&t.alice, &token, &ONE, &0).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert_eq!(t.pad.try_quote_buy(&token, &t.bob, &ONE).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert_eq!(t.pad.try_quote_sell(&token, &ONE).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert!(t.pair_of(&token).is_none());
    t.assert_solvent(&[token], 0);
}

/// The quote views refuse wherever the trades do. A graduated or rescued curve has no token reserve left, so a sell
/// quote would price one token at the whole virtual quote reserve.
#[test]
fn quotes_refuse_every_closed_curve_as_the_trades_do() {
    let t = setup();
    let graduated = t.launch();
    let rescued = stuck_launch(&t);
    t.buy(&t.alice, &graduated, WHALE);
    let refused = |token: &Address, phase: Phase| {
        assert_eq!(t.curve(token).phase, phase);
        let closed = err(Error::CurveClosed);
        assert_eq!(t.pad.try_quote_sell(token, &ONE).unwrap_err().unwrap(), closed, "{phase:?}");
        assert_eq!(t.pad.try_quote_buy(token, &t.bob, &ONE).unwrap_err().unwrap(), closed, "{phase:?}");
        assert_eq!(t.pad.try_sell(&t.alice, token, &ONE, &0).unwrap_err().unwrap(), closed, "{phase:?}");
        assert_eq!(t.pad.try_buy(&t.bob, token, &ONE, &0).unwrap_err().unwrap(), closed, "{phase:?}");
    };
    refused(&graduated, Phase::Completed);
    t.graduate(&graduated);
    refused(&graduated, Phase::Graduated);
    assert_eq!(t.curve(&graduated).token_reserve, 0);
    t.advance(PRODUCTION_LAUNCH_DURATIONS.rescue_public);
    t.pad.rescue(&rescued);
    refused(&rescued, Phase::Rescued);
}

#[test]
fn a_buy_that_lands_on_the_threshold_by_accident_completes_too() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    // A gross amount whose net is exactly what remains.
    let remaining = threshold();
    let mut gross = gross_for_net(remaining, 100);
    while gross - fee_of(gross, 100) > remaining {
        gross -= 1;
    }
    assert_eq!(gross - fee_of(gross, 100), remaining);
    t.buy(&t.alice, &token, gross);
    assert_eq!(t.curve(&token).phase, Phase::Completed);
    assert_eq!(t.curve(&token).real_quote, threshold());
}

#[test]
fn trading_requires_the_traders_signature() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    let got = t.buy(&t.alice, &token, 10 * ONE);
    t.e.set_auths(&[]);
    assert!(t.pad.try_buy(&t.alice, &token, &ONE, &0).is_err());
    assert!(t.pad.try_sell(&t.alice, &token, &got, &0).is_err());
    // Signed by bob, alice's buy doesn't happen.
    let args = (t.alice.clone(), token.clone(), ONE, 0i128).into_val(&t.e);
    assert!(!signed_by(&t, &t.bob, "buy", args, || t.pad.try_buy(&t.alice, &token, &ONE, &0).is_ok()));
    assert_eq!(t.balance(&token, &t.alice), got);
}

#[test]
fn many_trades_keep_the_launchpad_solvent() {
    let t = setup();
    let a = t.launch();
    let mut p = t.params(SOROSWAP, false);
    p.creator_fee_bps = 1_000;
    p.name = String::from_str(&t.e, "Second");
    let b = t.launch_p(&t.creator, &p);
    t.after_snipe();
    for i in 1..20i128 {
        let amt = (i * 37 % 97 + 1) * ONE;
        let ga = t.buy(&t.alice, &a, amt);
        let gb = t.buy(&t.bob, &b, amt * 2);
        if i % 3 == 0 {
            t.pad.sell(&t.alice, &a, &(ga / 2), &0);
            t.pad.sell(&t.bob, &b, &(gb / 3), &0);
        }
        t.assert_solvent(&[a.clone(), b.clone()], 0);
    }
    // The creator fee is booked whole for the recipient (sharing off).
    let c = t.curve(&b);
    assert!(c.creator_fees > c.protocol_fees);
}

#[test]
fn fees_are_claimed_by_their_owners_only() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    t.buy(&t.alice, &token, 1_000 * ONE);
    let c = t.curve(&token);
    // Anyone can pay the creator fees out; they always go to the recipient.
    t.e.set_auths(&[]);
    let creator_before = t.balance(&t.quote, &t.creator);
    assert_eq!(t.pad.claim_creator_fees(&token), c.creator_fees);
    assert!(t.emitted(&CreatorFeesClaimed {
        token: token.clone(),
        recipient: t.creator.clone(),
        amount: c.creator_fees
    }));
    assert_eq!(t.balance(&t.quote, &t.creator), creator_before + c.creator_fees);
    assert_eq!(t.pad.try_claim_creator_fees(&token).unwrap_err().unwrap(), err(Error::NothingToClaim));

    // Protocol and launch fees go to the treasury, also swept by anyone.
    let totals = t.pad.claim_protocol_fees(&vec![&t.e, token.clone()]);
    let claimed = ProtocolFeesClaimed {
        token: token.clone(),
        treasury: t.treasury.clone(),
        quote_amount: c.protocol_fees,
        launch_fee_amount: LAUNCH_FEE,
    };
    assert!(t.emitted(&claimed));
    assert_eq!(totals, vec![&t.e, (t.quote.clone(), c.protocol_fees), (t.xlm.clone(), LAUNCH_FEE)]);
    assert_eq!((t.balance(&t.quote, &t.treasury), t.balance(&t.xlm, &t.treasury)), (c.protocol_fees, LAUNCH_FEE));
    assert_eq!(
        t.pad.try_claim_protocol_fees(&vec![&t.e, token.clone()]).unwrap_err().unwrap(),
        err(Error::NothingToClaim)
    );
    t.e.mock_all_auths();
    t.assert_solvent(&[token], 0);
}

#[test]
fn with_sharing_on_the_creator_part_goes_to_the_holders_from_the_next_ledger() {
    let t = setup();
    let token = t.launch_on(SOROSWAP, true);
    t.after_snipe();
    let got = t.buy(&t.alice, &token, 100 * ONE);
    let events = t.pad_events();
    // 1% fee: 0.5 booked for the protocol, 0.5 sent to the token for its holders, nothing booked for the creator.
    let c = t.curve(&token);
    assert_eq!((c.protocol_fees, c.creator_fees, c.holder_fees_total), (ONE / 2, 0, ONE / 2));
    assert_eq!(t.balance(&t.quote, &token), ONE / 2);
    let trade = Trade {
        token: token.clone(),
        trader: t.alice.clone(),
        is_buy: true,
        quote_amount: 100 * ONE,
        token_amount: got,
        base_fee: ONE,
        snipe_fee: 0,
        creator_fee: 0,
        protocol_part: ONE / 2,
        creator_part: 0,
        holder_part: ONE / 2,
        quote_reserve: c.quote_reserve,
        token_reserve: c.token_reserve,
        real_quote: c.real_quote,
    };
    assert_eq!(events, [t.xdr_of(&trade)]);
    let tok = t.token(&token);
    let seq = t.e.ledger().sequence();
    assert_eq!(tok.queued_rewards(), (ONE / 2, 0, seq + 1));
    // Not in the ledger of the notify (I-T3)...
    assert_eq!(tok.pending_rewards(&t.alice), (0, 0));
    // ...but from the next one alice, the only eligible holder, can claim it all (to within rounding).
    t.advance(5);
    let (q, tokens) = tok.claim(&t.alice);
    assert!((ONE / 2 - 1..=ONE / 2).contains(&q), "{q}");
    assert_eq!(tokens, 0);
    assert_eq!(t.pad.try_claim_creator_fees(&token).unwrap_err().unwrap(), err(Error::NothingToClaim));
    // A sell routes the same way.
    t.pad.sell(&t.alice, &token, &(got / 2), &0);
    assert_eq!(t.curve(&token).creator_fees, 0);
    assert!(t.curve(&token).holder_fees_total > ONE / 2);
    t.assert_solvent(&[token], 0);
}

#[test]
fn set_fees_during_the_curve_leaves_the_launchs_split_and_schedule_unchanged() {
    let t = setup();
    let token = t.launch();
    t.pad.set_fees(&300, &2_000, &500, &vec![&t.e, 100u32], &10);
    // The live launch trades on its pinned 1% fee, 50/50 split and snipe schedule (V1).
    assert_eq!(t.pad.quote_buy(&token, &t.alice, &(100 * ONE)).snipe_fee, fee_of(100 * ONE, 9_800));
    t.after_snipe();
    t.buy(&t.alice, &token, 100 * ONE);
    let c = t.curve(&token);
    assert_eq!((c.protocol_fees, c.creator_fees), (ONE / 2, ONE / 2));
    // The next launch takes the new values.
    let next = t.launch();
    let l = t.pad.get_launch(&next);
    assert_eq!((l.fee_bps, l.protocol_share_bps, l.snipe_step_secs), (300, 2_000, 10));
}

// ------------------------------------------------------------------------------------------------ the recipient (L14)

#[test]
fn a_recipient_change_leaves_the_fees_booked_before_it_with_the_old_recipient() {
    let t = setup();
    let token = t.launch();
    t.after_snipe();
    t.buy(&t.alice, &token, 1_000 * ONE);
    let early = t.curve(&token).creator_fees;
    let new = Address::generate(&t.e);
    t.pad.transfer_creator_fee_recipient(&token, &new);
    let owed = CreatorFeesOwed { token: token.clone(), old_recipient: t.creator.clone(), amount: early };
    let set = RecipientSet { token: token.clone(), old: t.creator.clone(), new: new.clone(), by_takeover: false };
    assert_eq!(t.pad_events(), [t.xdr_of(&owed), t.xdr_of(&set)]);
    assert_eq!(t.pad.creator_fee_recipient(&token), new);
    assert_eq!(t.pad.creator_owed(&t.creator, &t.quote), early);
    assert_eq!(t.curve(&token).creator_fees, 0);
    t.assert_solvent(std::slice::from_ref(&token), early);

    // Fees booked after the change are the new recipient's.
    t.buy(&t.bob, &token, 100 * ONE);
    let late = t.curve(&token).creator_fees;
    assert_eq!(t.pad.claim_creator_fees(&token), late);
    assert_eq!(t.balance(&t.quote, &new), late);
    // The earlier fees go to the old recipient only, through claim_owed, which anyone may call.
    assert_eq!(t.pad.try_claim_owed(&new, &t.quote).unwrap_err().unwrap(), err(Error::NothingToClaim));
    t.e.set_auths(&[]);
    let before = t.balance(&t.quote, &t.creator);
    assert_eq!(t.pad.claim_owed(&t.creator, &t.quote), early);
    assert!(t.emitted(&OwedClaimed { account: t.creator.clone(), asset: t.quote.clone(), amount: early }));
    assert_eq!(t.balance(&t.quote, &t.creator), before + early);
    assert_eq!(t.pad.creator_owed(&t.creator, &t.quote), 0);
    assert_eq!(t.pad.try_claim_owed(&t.creator, &t.quote).unwrap_err().unwrap(), err(Error::NothingToClaim));
    t.e.mock_all_auths();
    t.assert_solvent(std::slice::from_ref(&token), 0);

    // Only the current recipient can hand the role on.
    let args = (token.clone(), t.alice.clone()).into_val(&t.e);
    let by_creator = || t.pad.try_transfer_creator_fee_recipient(&token, &t.alice).is_ok();
    assert!(!signed_by(&t, &t.creator, "transfer_creator_fee_recipient", args, by_creator));
    let args = (token.clone(), t.alice.clone()).into_val(&t.e);
    assert!(signed_by(&t, &new, "transfer_creator_fee_recipient", args, by_creator));
    assert_eq!(t.pad.creator_fee_recipient(&token), t.alice);
}

#[test]
fn a_takeover_waits_runs_inside_its_window_and_the_recipient_can_veto_it() {
    let t = setup();
    let d = PRODUCTION_LAUNCH_DURATIONS;
    let token = t.launch();
    let (new, stranger) = (Address::generate(&t.e), Address::generate(&t.e));
    assert_eq!(t.pad.try_execute_recipient_change(&token).unwrap_err().unwrap(), err(Error::NoProposal));
    assert_eq!(t.pad.try_cancel_recipient_change(&token, &t.admin).unwrap_err().unwrap(), err(Error::NoProposal));
    assert_eq!(
        t.pad.try_propose_creator_fee_recipient(&Address::generate(&t.e), &new).unwrap_err().unwrap(),
        err(Error::UnknownLaunch)
    );

    // Proposed, too early, then vetoed by the recipient; a stranger can't cancel.
    t.pad.propose_creator_fee_recipient(&token, &new);
    let (effective_at, expires_at) = (START + d.takeover_delay, START + d.takeover_delay + d.takeover_window);
    assert!(t.emitted(&RecipientProposed { token: token.clone(), new: new.clone(), effective_at, expires_at }));
    assert_eq!(t.pad.pending_recipient_change(&token), Some(Takeover { new: new.clone(), effective_at, expires_at }));
    t.advance(d.takeover_delay - 1);
    assert_eq!(t.pad.try_execute_recipient_change(&token).unwrap_err().unwrap(), err(Error::TimelockNotElapsed));
    assert_eq!(t.pad.try_cancel_recipient_change(&token, &stranger).unwrap_err().unwrap(), err(Error::NotAuthorized));
    let args = (token.clone(), t.creator.clone()).into_val(&t.e);
    assert!(!signed_by(&t, &stranger, "cancel_recipient_change", args, || t
        .pad
        .try_cancel_recipient_change(&token, &t.creator)
        .is_ok()));
    let args = (token.clone(), t.creator.clone()).into_val(&t.e);
    assert!(signed_by(&t, &t.creator, "cancel_recipient_change", args, || t
        .pad
        .try_cancel_recipient_change(&token, &t.creator)
        .is_ok()));
    assert!(t.emitted(&RecipientChangeCancelled { token: token.clone(), by: t.creator.clone() }));
    assert_eq!(t.pad.pending_recipient_change(&token), None);
    t.advance(1);
    assert_eq!(t.pad.try_execute_recipient_change(&token).unwrap_err().unwrap(), err(Error::NoProposal));

    // Proposed again and cancelled by the admin.
    t.pad.propose_creator_fee_recipient(&token, &new);
    t.pad.cancel_recipient_change(&token, &t.admin);
    assert_eq!(t.pad.pending_recipient_change(&token), None);

    // Proposed again and executed inside the window, by anyone; fees booked before it stay with the old recipient.
    t.after_snipe();
    t.buy(&t.alice, &token, 100 * ONE);
    let early = t.curve(&token).creator_fees;
    t.pad.propose_creator_fee_recipient(&token, &new);
    t.advance(d.takeover_delay);
    t.e.set_auths(&[]);
    t.pad.execute_recipient_change(&token);
    assert!(t.emitted(&RecipientSet {
        token: token.clone(),
        old: t.creator.clone(),
        new: new.clone(),
        by_takeover: true
    }));
    t.e.mock_all_auths();
    assert_eq!(t.pad.creator_fee_recipient(&token), new);
    assert_eq!(t.pad.creator_owed(&t.creator, &t.quote), early);
    assert_eq!(t.pad.pending_recipient_change(&token), None);

    // A takeover lapses: after its window it fails TimelockExpired, and a day later its entry is gone.
    t.pad.propose_creator_fee_recipient(&token, &stranger);
    t.advance(d.takeover_delay + d.takeover_window + 1);
    assert_eq!(t.pad.try_execute_recipient_change(&token).unwrap_err().unwrap(), err(Error::TimelockExpired));
    assert!(t.pad.pending_recipient_change(&token).is_some());
    t.e.ledger().with_mut(|l| {
        l.timestamp += 2 * DAY;
        l.sequence_number += dyor_common::ledgers_for(d.takeover_delay + d.takeover_window + DAY) + 1;
    });
    assert_eq!(t.pad.pending_recipient_change(&token), None);
    assert_eq!(t.pad.try_execute_recipient_change(&token).unwrap_err().unwrap(), err(Error::NoProposal));
    assert_eq!(t.pad.creator_fee_recipient(&token), new);
}

// ------------------------------------------------------------------------------------------------ graduation

#[test]
fn graduation_seeds_soroswap_at_the_curve_price_and_locks_lp() {
    let t = setup();
    let token = t.launch();
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&token)).unwrap_err().unwrap(), err(Error::NotCompleted));
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::NotCompleted));
    t.complete(&token);
    let c = t.curve(&token);
    let final_price_e9 = mul_div(c.quote_reserve, 1_000_000_000, c.token_reserve);
    let (pool_tokens, pool_quote, burn) = t.pad.graduation_preview(&token);
    assert_eq!((pool_quote, pool_tokens + burn), (c.real_quote, c.token_reserve));

    // The keeper's call, in a later transaction (L3), signed by nobody: the launchpad's own pre-authorization of
    // exactly the two pulls is what lets the executor take the funds.
    let outcome = t.graduate(&token);
    let events = t.pad_events();
    let used = t.e.cost_estimate().resources();
    std::println!("Soroswap graduation: {} instructions, {} memory bytes", used.instructions, used.mem_bytes);
    let pair = t.pair_of(&token).unwrap();
    assert_eq!(outcome, GraduationOutcome::Graduated(pair.clone()));
    let p = soroswap_pair::Client::new(&t.e, &pair);
    let (r0, r1) = p.get_reserves();
    let (tok_r, quote_r) = if p.token_0() == token { (r0, r1) } else { (r1, r0) };
    assert_eq!((tok_r, quote_r), (pool_tokens, pool_quote));
    // The pool opens at the curve's final price, within rounding (I-L6).
    let pool_price_e9 = mul_div(quote_r, 1_000_000_000, tok_r);
    assert!((pool_price_e9 - final_price_e9).abs() <= 1, "{pool_price_e9} vs {final_price_e9}");

    // The locker holds every LP unit but Soroswap's minimum-liquidity lock, registered for this launch (I-L9).
    let liquidity = t.balance(&pair, &t.locker);
    assert_eq!(p.total_supply() - liquidity, SOROSWAP_MIN_LIQ);
    let pos = t.locker().position(&pair).unwrap();
    assert_eq!((pos.owner, pos.lp_token, pos.lp), (t.pad.address.clone(), pair.clone(), liquidity));
    assert_eq!((pos.base, pos.quote, pos.harvest_bps), (token.clone(), t.quote.clone(), LAUNCH_HARVEST_BPS));
    assert_eq!(pos.kind, lp_locker::VenueKind::Soroswap);
    assert_eq!(pos.reference, lp_locker::PositionRef::Launch(token.clone()));
    assert_eq!(LAUNCH_HARVEST_BPS, 10_000);

    // The excess is burned and transfers open.
    let tok = t.token(&token);
    assert!(tok.unlocked());
    assert_eq!(t.balance(&token, &t.pad.address), 0);
    assert_eq!(tok.total_supply(), DEFAULT_SUPPLY - burn);
    let g = t.curve(&token);
    assert_eq!((g.phase, g.stuck_since, g.real_quote, g.token_reserve), (Phase::Graduated, 0, 0, 0));
    assert_eq!((g.pool, g.graduated_venue, g.burned), (Some(pair.clone()), Some(SOROSWAP), burn));
    let ok = Graduated {
        token: token.clone(),
        venue: SOROSWAP,
        pool: pair.clone(),
        pool_tokens,
        pool_quote,
        liquidity,
        burned: burn,
        fallback: false,
    };
    assert!(events.contains(&t.xdr_of(&ok)));
    assert_eq!(t.pad.status(&token).phase, Phase::Graduated);
    assert_eq!(t.pad.graduation_preview(&token), (0, 0, 0));

    // Done once.
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&token)).unwrap_err().unwrap(), err(Error::AlreadyGraduated));
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::AlreadyGraduated));
    assert_eq!(t.pad.try_mark_stuck(&token).unwrap_err().unwrap(), err(Error::AlreadyGraduated));
    assert_eq!(t.pad.try_rescue(&token).unwrap_err().unwrap(), err(Error::WrongPhase));
    // Holder transfers work.
    let alice_tokens = t.balance(&token, &t.alice);
    TokenClient::new(&t.e, &token).transfer(&t.alice, &t.bob, &(alice_tokens / 10));
    t.assert_solvent(&[token], 0);
}

#[test]
fn graduated_token_trades_on_the_soroswap_router() {
    let t = setup();
    let token = t.launch();
    t.complete(&token);
    t.graduate(&token);
    let path = vec![&t.e, t.quote.clone(), token.clone()];
    let before = t.balance(&token, &t.bob);
    let deadline = t.now() + 600;
    soroswap_router::Client::new(&t.e, &t.router).swap_exact_tokens_for_tokens(
        &(10 * ONE),
        &0,
        &path,
        &t.bob,
        &deadline,
    );
    assert!(t.balance(&token, &t.bob) > before);
}

#[test]
fn graduation_survives_a_precreated_pair_with_dust_and_sync() {
    let t = setup();
    let token = t.launch();
    // A griefer creates the pair early, donates quote dust and syncs, so the reserves read (0, dust).
    let pair = soroswap_factory::Client::new(&t.e, &t.factory).create_pair(&token, &t.quote);
    TokenClient::new(&t.e, &t.quote).transfer(&t.bob, &pair, &7);
    soroswap_pair::Client::new(&t.e, &pair).sync();
    t.complete(&token);
    assert_eq!(t.graduate(&token), GraduationOutcome::Graduated(pair.clone()));
    assert!(t.balance(&pair, &t.locker) > 0);
    assert_eq!(t.locker().position(&pair).unwrap().lp, t.balance(&pair, &t.locker));
}

#[test]
fn with_sharing_on_the_pool_is_excluded_in_the_graduation_transaction() {
    let t = setup();
    let token = t.launch_on(SOROSWAP, true);
    // The completing buy queues holder rewards in its own ledger.
    t.complete(&token);
    let tok = t.token(&token);
    assert!(tok.queued_rewards().0 > 0);
    let pair = match t.graduate(&token) {
        GraduationOutcome::Graduated(pair) => pair,
        f => panic!("{f:?}"),
    };
    assert!(tok.is_excluded(&pair));
    // Released in a later ledger, to the holders only: the pool never shares it.
    t.advance(5);
    assert_eq!(tok.pending_rewards(&pair), (0, 0));
    assert!(tok.pending_rewards(&t.alice).0 > 0);
    let sharing = tok.sharing().unwrap();
    assert_eq!(sharing.eligible, t.balance(&token, &t.alice));
}

#[test]
fn a_recoverable_failure_records_its_origin_and_code_and_changes_nothing_else() {
    let t = setup();
    let token = t.launch_on(QA_FAIL, false);
    t.complete(&token);
    let before = t.state(&token);
    let failed_at = t.now();
    let outcome = t.graduate(&token);
    let events = t.pad_events();
    // qa-exec-fail's ForcedFailure, namespaced (V10): origin 5, code 10_502.
    let forced = GradFailure { origin: dyor_common::TAG_QA_EXEC_FAIL, code: 10_502 };
    assert_eq!(outcome, GraduationOutcome::Failed(forced));
    let fail = GraduationFailed {
        token: token.clone(),
        venue: QA_FAIL,
        origin: 5,
        code: 10_502,
        stuck_since: failed_at,
        fallback_at: failed_at + HOUR,
    };
    assert_eq!(events, [t.xdr_of(&fail)]);
    // Reserves, balances and the lock are as before; only stuck_since moved (I-L5).
    let mut expected = before;
    expected.curve.stuck_since = failed_at;
    assert_eq!(t.state(&token), expected);
    assert!(t.pair_of(&token).is_none());

    // Retries record again and never move stuck_since (B13a).
    t.advance(10 * MINUTE);
    assert_eq!(t.graduate(&token), GraduationOutcome::Failed(forced));
    assert_eq!(t.state(&token), expected);
    let s = t.pad.status(&token);
    assert_eq!((s.phase, s.stuck_since, s.fallback_at), (Phase::Completed, failed_at, failed_at + HOUR));
    assert_eq!((s.rescue_admin_at, s.rescue_public_at), (failed_at + 7 * DAY, failed_at + 30 * DAY));
    assert_eq!(s.mark_stuck_at, expected.curve.completed_at + HOUR);
    assert_eq!(t.pad.try_mark_stuck(&token).unwrap_err().unwrap(), err(Error::AlreadyStuck));
}

#[test]
fn exec_soroswaps_pool_not_empty_is_recorded_as_origin_3_code_10_303() {
    let t = setup();
    let token = t.launch_on(OCCUPIED, false);
    t.complete(&token);
    let before = t.state(&token);
    let outcome = t.graduate(&token);
    // Not to be confused with qa-exec-fail's 10_502 or exec-aquarius's 10_404 (V10).
    assert_eq!(
        outcome,
        GraduationOutcome::Failed(GradFailure { origin: dyor_common::TAG_EXEC_SOROSWAP, code: 10_303 })
    );
    let mut expected = before;
    expected.curve.stuck_since = t.now();
    assert_eq!(t.state(&token), expected);
}

#[test]
fn after_one_transient_failure_the_fallback_waits_and_a_primary_retry_graduates_on_the_creators_venue() {
    let t = setup();
    let token = t.launch_on(SCRIPTED, false);
    t.script(Script::FailFirst);
    t.complete(&token);
    let failed_at = t.now();
    let transient = GradFailure { origin: ORIGIN_FOREIGN, code: ScriptError::Transient as u32 };
    assert_eq!(t.graduate(&token), GraduationOutcome::Failed(transient));
    // The fallback stays shut for fallback_delay, right after a single transient failure too (F14, I-L12).
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::FallbackTooEarly));
    t.advance(HOUR - 1);
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::FallbackTooEarly));
    // Meanwhile the keeper's retry on the creator's venue graduates the launch there.
    let outcome = t.graduate(&token);
    let events = t.pad_events();
    let pair = t.pair_of(&token).unwrap();
    assert_eq!(outcome, GraduationOutcome::Graduated(pair.clone()));
    let g = t.curve(&token);
    assert_eq!((g.phase, g.graduated_venue, g.stuck_since), (Phase::Graduated, Some(SCRIPTED), 0));
    let ok = Graduated {
        token: token.clone(),
        venue: SCRIPTED,
        pool: pair.clone(),
        pool_tokens: t.balance(&token, &pair),
        pool_quote: threshold(),
        liquidity: t.balance(&pair, &t.locker),
        burned: g.burned,
        fallback: false,
    };
    assert!(events.contains(&t.xdr_of(&ok)));
    assert_eq!(calls(), 2);
    assert!(t.now() < failed_at + HOUR);
}

#[test]
fn graduate_fallback_attempts_only_the_fallback_venue() {
    let t = setup();
    let token = t.launch_on(SCRIPTED, false);
    // The primary fails once, and panics if it is ever called again.
    t.script(Script::FailThenPanic);
    t.complete(&token);
    assert!(matches!(t.graduate(&token), GraduationOutcome::Failed(_)));
    assert_eq!(calls(), 1);
    let stuck_since = t.curve(&token).stuck_since;
    t.advance(HOUR);
    let outcome = t.graduate_fallback(&token);
    let events = t.pad_events();
    assert_eq!(calls(), 1, "graduate_fallback ran the primary executor");
    let pair = t.pair_of(&token).unwrap();
    assert_eq!(outcome, GraduationOutcome::Graduated(pair.clone()));
    let g = t.curve(&token);
    assert_eq!((g.phase, g.graduated_venue, g.stuck_since), (Phase::Graduated, Some(SOROSWAP), 0));
    assert!(stuck_since > 0);
    let ok = Graduated {
        token: token.clone(),
        venue: SOROSWAP,
        pool: pair.clone(),
        pool_tokens: t.balance(&token, &pair),
        pool_quote: threshold(),
        liquidity: t.balance(&pair, &t.locker),
        burned: g.burned,
        fallback: true,
    };
    assert!(events.contains(&t.xdr_of(&ok)));
    assert_eq!(t.locker().position(&pair).unwrap().reference, lp_locker::PositionRef::Launch(token));
}

#[test]
fn mark_stuck_opens_after_the_grace_and_starts_the_clocks() {
    let t = setup();
    let (token, late) = (t.launch_on(QA_FAIL, false), t.launch_on(QA_FAIL, false));
    assert_eq!(t.pad.try_mark_stuck(&token).unwrap_err().unwrap(), err(Error::NotCompleted));
    t.complete(&late);
    let late_completed_at = t.curve(&late).completed_at;
    t.complete(&token);
    let completed_at = t.curve(&token).completed_at;
    assert_eq!(t.pad.status(&token).mark_stuck_at, completed_at + HOUR);
    t.advance(HOUR - 1);
    assert_eq!(t.pad.try_mark_stuck(&token).unwrap_err().unwrap(), err(Error::GraceNotElapsed));
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::NotStuck));
    assert_eq!(t.pad.try_rescue(&token).unwrap_err().unwrap(), err(Error::NotStuck));
    t.advance(1);
    t.e.set_auths(&[]);
    t.pad.mark_stuck(&token);
    let stuck_since = completed_at + HOUR;
    assert!(t.emitted(&MarkedStuck { token: token.clone(), stuck_since }));
    t.e.mock_all_auths();
    assert_eq!(t.curve(&token).stuck_since, stuck_since);
    assert_eq!(t.pad.try_mark_stuck(&token).unwrap_err().unwrap(), err(Error::AlreadyStuck));
    let s = t.pad.status(&token);
    assert_eq!(
        (s.fallback_at, s.rescue_admin_at, s.rescue_public_at),
        (stuck_since + HOUR, stuck_since + 7 * DAY, stuck_since + 30 * DAY)
    );
    // The fallback opens an hour after stuck_since: not a second before.
    t.advance(HOUR - 1);
    assert_eq!(t.now(), stuck_since + HOUR - 1);
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&token)).unwrap_err().unwrap(), err(Error::FallbackTooEarly));
    t.advance(1);
    assert!(matches!(t.graduate_fallback(&token), GraduationOutcome::Graduated(_)));
    assert_eq!(t.curve(&token).graduated_venue, Some(SOROSWAP));
    // Marked an hour late, a launch is still stuck from completed_at + grace, not from the call.
    t.pad.mark_stuck(&late);
    assert_eq!(t.curve(&late).stuck_since, late_completed_at + HOUR);
}

#[test]
fn a_bogus_success_or_an_exhausted_budget_aborts_and_mark_stuck_then_the_fallback_follow() {
    let t = setup();
    let qa = qa_exec_fail::Client::new(&t.e, &t.qa);
    // Mode 2: a success without any transfer. The result checks abort with GraduationInvalid (§7.3).
    let bogus = t.launch_on(QA_FAIL, false);
    qa.set_mode(&bogus, &qa_exec_fail::Mode::BogusSuccess);
    t.complete(&bogus);
    let before = t.state(&bogus);
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&bogus)).unwrap_err().unwrap(), err(Error::GraduationInvalid));
    assert_eq!(t.state(&bogus), before);

    // Mode 1: the executor runs the budget out. Nothing catches that, and nothing of the call is committed.
    let starved = t.launch_on(QA_FAIL, false);
    qa.set_mode(&starved, &qa_exec_fail::Mode::ExhaustBudget);
    t.complete(&starved);
    let before = t.state(&starved);
    t.e.cost_estimate().budget().reset_default();
    let abort = panic_of(|| t.unsigned(|| t.pad.try_graduate(&starved))).expect("the budget abort");
    t.e.cost_estimate().budget().reset_unlimited();
    t.e.mock_all_auths();
    assert!(abort.contains("Error(Budget, ExceededLimit)"), "{abort}");
    assert_eq!(t.state(&starved), before);

    // Neither failure can be recorded, so mark_stuck starts the clock, and the fallback graduates both.
    t.advance(HOUR);
    for token in [&bogus, &starved] {
        t.pad.mark_stuck(token);
    }
    t.advance(HOUR);
    for token in [&bogus, &starved] {
        assert!(matches!(t.graduate_fallback(token), GraduationOutcome::Graduated(_)));
        assert_eq!(t.curve(token).graduated_venue, Some(SOROSWAP));
    }
}

#[test]
fn a_venue_locked_launch_falls_back_after_locked_fallback_or_allow_fallback() {
    let t = setup();
    let qa_quote = t.new_quote();
    t.pad.set_quote(&qa_quote, &PHANTOM, &threshold(), &true, &vec![&t.e, QA_FAIL], &SOROSWAP);
    let (waits, allowed) = (
        t.launch_p(&t.creator, &t.params_on(&qa_quote, QA_FAIL, false)),
        t.launch_p(&t.creator, &t.params_on(&qa_quote, QA_FAIL, false)),
    );
    t.after_snipe();
    for token in [&waits, &allowed] {
        t.buy(&t.alice, token, WHALE);
        assert!(matches!(t.graduate(token), GraduationOutcome::Failed(_)));
    }
    let stuck_since = t.curve(&waits).stuck_since;
    assert_eq!(t.pad.status(&waits).fallback_at, stuck_since + DAY);
    t.advance(HOUR);
    assert_eq!(
        t.unsigned(|| t.pad.try_graduate_fallback(&waits)).unwrap_err().unwrap(),
        err(Error::FallbackNotAllowed)
    );
    // The admin lets one fall back now.
    assert_eq!(t.pad.try_allow_fallback(&Address::generate(&t.e)).unwrap_err().unwrap(), err(Error::UnknownLaunch));
    t.pad.allow_fallback(&allowed);
    assert!(t.emitted(&FallbackAllowed { token: allowed.clone() }));
    assert!(t.curve(&allowed).fallback_allowed);
    assert_eq!(t.pad.status(&allowed).fallback_at, stuck_since + HOUR);
    assert!(matches!(t.graduate_fallback(&allowed), GraduationOutcome::Graduated(_)));
    // The other waits for locked_fallback (I-L12).
    t.e.ledger().with_mut(|l| l.timestamp = stuck_since + DAY - 1);
    assert_eq!(
        t.unsigned(|| t.pad.try_graduate_fallback(&waits)).unwrap_err().unwrap(),
        err(Error::FallbackNotAllowed)
    );
    t.advance(1);
    assert!(matches!(t.graduate_fallback(&waits), GraduationOutcome::Graduated(_)));
    assert_eq!(t.curve(&waits).graduated_venue, Some(SOROSWAP));
}

#[test]
fn executors_that_lie_about_their_result_abort_with_graduation_invalid_and_change_nothing() {
    let t = setup();
    // So that a quote SAC passed off as the LP token passes the locker's balance check, and the rebate has a source.
    StellarAssetClient::new(&t.e, &t.quote).mint(&t.locker, &(1_000_000_000 * ONE));
    StellarAssetClient::new(&t.e, &t.quote).mint(&t.scripted, &(1_000 * ONE));
    let lies = [
        Script::OverReport,
        Script::UnderReport,
        Script::ShortUse,
        Script::WrongPool,
        Script::LpElsewhere,
        Script::BogusLpToken,
        Script::TokenDeltaLie,
        Script::QuoteRebate,
        Script::LowLiquidity,
        Script::LpTokenIsQuote,
        Script::PoolAndLpAreQuote,
    ];
    for script in lies {
        let token = t.launch_on(SCRIPTED, false);
        t.script(script);
        t.complete(&token);
        let before = t.state(&token);
        assert_eq!(
            t.unsigned(|| t.pad.try_graduate(&token)).unwrap_err().unwrap(),
            err(Error::GraduationInvalid),
            "{script:?}"
        );
        assert_eq!(t.state(&token), before, "{script:?}");
        assert!(t.pair_of(&token).is_none(), "{script:?}");
        // The honest venue is still there for it.
        t.script(Script::Honest);
        assert!(matches!(t.graduate(&token), GraduationOutcome::Graduated(_)), "{script:?}");
    }
}

#[test]
fn an_executor_that_pulls_more_than_was_authorized_is_a_recorded_host_auth_failure() {
    let t = setup();
    let token = t.launch_on(SCRIPTED, false);
    t.script(Script::PullsTooMuch);
    t.complete(&token);
    let before = t.state(&token);
    // The launchpad pre-authorized exactly the pool amounts: one unit more fails the host's auth check inside the
    // executor's frame, which reaches the launchpad as a host error (origin 99, InvalidAction; ruling after CT-01..03).
    let auth = GradFailure { origin: dyor_common::ORIGIN_HOST, code: xdr::ScErrorCode::InvalidAction as u32 };
    assert_eq!(t.graduate(&token), GraduationOutcome::Failed(auth));
    let mut expected = before;
    expected.curve.stuck_since = t.now();
    assert_eq!(t.state(&token), expected);
}

/// A venue without Soroswap's LP floor (`min_liquidity` 1): the dust bound alone catches a token amount used more than
/// 1 bp short, and quote left unused within it is booked as protocol fees.
#[test]
fn without_a_liquidity_floor_the_dust_bounds_still_hold() {
    let t = setup();
    let hold = t.add_venue(VenueKind::HoldOnly, &t.scripted, 0);
    let (short, dusty) = (t.launch_on(hold, false), t.launch_on(hold, false));
    t.complete(&short);
    t.complete(&dusty);
    t.script(Script::ShortUse);
    let before = t.state(&short);
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&short)).unwrap_err().unwrap(), err(Error::GraduationInvalid));
    assert_eq!(t.state(&short), before);
    t.script(Script::QuoteDust);
    let fees = t.curve(&dusty).protocol_fees;
    assert!(matches!(t.graduate(&dusty), GraduationOutcome::Graduated(_)));
    assert_eq!(t.curve(&dusty).protocol_fees, fees + 1);
    t.assert_solvent(&[short, dusty], 0);
}

#[test]
fn a_success_that_does_not_decode_aborts_with_graduation_invalid() {
    let t = setup();
    let garbled = t.add_venue(VenueKind::HoldOnly, &t.e.register(GarbledExecutor, ()), 0);
    let token = t.launch_on(garbled, false);
    t.complete(&token);
    let before = t.state(&token);
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&token)).unwrap_err().unwrap(), err(Error::GraduationInvalid));
    assert_eq!(t.state(&token), before);
}

// ------------------------------------------------------------------------------------------------ rescue and refunds (O2)

/// A launch on the failing venue that alice and bob bought into and alice completed, then failed to graduate:
/// stuck from now.
fn stuck_launch(t: &T) -> Address {
    let token = t.launch_on(QA_FAIL, false);
    t.after_snipe();
    t.buy(&t.bob, &token, 300 * ONE);
    t.buy(&t.alice, &token, WHALE);
    assert!(matches!(t.graduate(&token), GraduationOutcome::Failed(_)));
    token
}

#[test]
fn rescue_is_refused_early_admin_only_until_the_public_delay_then_open_to_anyone() {
    let t = setup();
    let d = PRODUCTION_LAUNCH_DURATIONS;
    let live = t.launch();
    assert_eq!(t.pad.try_rescue(&live).unwrap_err().unwrap(), err(Error::WrongPhase));
    let by_admin = stuck_launch(&t);
    let stuck_since = t.curve(&by_admin).stuck_since;
    assert_eq!(stuck_since, t.now());
    let by_anyone = stuck_launch(&t);
    let anyone_since = t.curve(&by_anyone).stuck_since;

    t.e.ledger().with_mut(|l| l.timestamp = stuck_since + d.rescue_admin - 1);
    assert_eq!(t.pad.try_rescue(&by_admin).unwrap_err().unwrap(), err(Error::NotStuck));
    t.advance(1);
    // From 7 days, the admin only.
    let args = (by_admin.clone(),).into_val(&t.e);
    assert!(!signed_by(&t, &t.alice, "rescue", args, || t.pad.try_rescue(&by_admin).is_ok()));
    t.e.set_auths(&[]);
    assert!(t.pad.try_rescue(&by_admin).is_err());
    let c = t.curve(&by_admin);
    let held = t.balance(&by_admin, &t.pad.address);
    let args = (by_admin.clone(),).into_val(&t.e);
    let rescued = signed_by(&t, &t.admin, "rescue", args, || t.pad.try_rescue(&by_admin).is_ok());
    let events = t.pad_events();
    assert!(rescued);
    let supply = t.token(&by_admin).total_supply();
    let event = Rescued {
        token: by_admin.clone(),
        stuck_since,
        by_admin: true,
        refund_quote: c.real_quote,
        refund_supply: supply,
        burned: held,
    };
    assert!(events.contains(&t.xdr_of(&event)));
    // The curve's tokens are burned, the token unlocks (L6) and the raised quote is the refund pot.
    let r = t.curve(&by_admin);
    assert_eq!(
        (r.phase, r.refund_quote, r.refund_supply, r.real_quote, r.token_reserve),
        (Phase::Rescued, c.real_quote, supply, 0, 0)
    );
    assert_eq!(supply, DEFAULT_SUPPLY - held);
    assert_eq!(t.balance(&by_admin, &t.pad.address), 0);
    assert!(t.token(&by_admin).unlocked());
    let s = t.pad.status(&by_admin);
    assert_eq!((s.phase, s.refund_quote, s.refund_supply, s.fallback_at), (Phase::Rescued, c.real_quote, supply, 0));
    // Trading, graduation and a second rescue are closed for good.
    assert_eq!(t.pad.try_buy(&t.bob, &by_admin, &ONE, &0).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert_eq!(t.pad.try_sell(&t.bob, &by_admin, &ONE, &0).unwrap_err().unwrap(), err(Error::CurveClosed));
    assert_eq!(t.unsigned(|| t.pad.try_graduate(&by_admin)).unwrap_err().unwrap(), err(Error::WrongPhase));
    assert_eq!(t.unsigned(|| t.pad.try_graduate_fallback(&by_admin)).unwrap_err().unwrap(), err(Error::WrongPhase));
    assert_eq!(t.pad.try_mark_stuck(&by_admin).unwrap_err().unwrap(), err(Error::WrongPhase));
    assert_eq!(t.pad.try_rescue(&by_admin).unwrap_err().unwrap(), err(Error::WrongPhase));

    // Between 7 and 30 days the other one still needs the admin; from 30 days anyone can rescue it, unsigned.
    t.e.ledger().with_mut(|l| l.timestamp = anyone_since + d.rescue_public - 1);
    t.e.set_auths(&[]);
    assert!(t.pad.try_rescue(&by_anyone).is_err());
    t.advance(1);
    t.pad.rescue(&by_anyone);
    let events = t.pad_events();
    t.e.mock_all_auths();
    let r = t.curve(&by_anyone);
    let event = Rescued {
        token: by_anyone.clone(),
        stuck_since: anyone_since,
        by_admin: false,
        refund_quote: r.refund_quote,
        refund_supply: r.refund_supply,
        burned: r.burned,
    };
    assert!(events.contains(&t.xdr_of(&event)));

    // Booked fees stay claimable.
    t.pad.claim_creator_fees(&by_admin);
    t.pad.claim_protocol_fees(&vec![&t.e, by_admin.clone(), by_anyone.clone()]);
    t.assert_solvent(&[live, by_admin, by_anyone], 0);
}

#[test]
fn refunds_are_pro_rata_without_fees_and_burn_the_tokens() {
    let t = setup();
    let token = stuck_launch(&t);
    t.advance(30 * DAY);
    t.pad.rescue(&token);
    let c = t.curve(&token);
    let (rq, rs) = (c.refund_quote, c.refund_supply);
    let bob_tokens = t.balance(&token, &t.bob);
    let expected = mul_div(bob_tokens / 3, rq, rs);
    assert_eq!(t.pad.quote_refund(&token, &(bob_tokens / 3)), expected);
    let before = t.balance(&t.quote, &t.bob);
    assert_eq!(t.pad.refund(&t.bob, &token, &(bob_tokens / 3)), expected);
    assert!(t.emitted(&Refunded {
        token: token.clone(),
        holder: t.bob.clone(),
        tokens_in: bob_tokens / 3,
        quote_out: expected
    }));
    assert_eq!(t.balance(&t.quote, &t.bob), before + expected);
    assert_eq!(t.balance(&token, &t.bob), bob_tokens - bob_tokens / 3);
    assert_eq!(t.token(&token).total_supply(), rs - bob_tokens / 3);
    assert_eq!(t.curve(&token).refunded, expected);
    // The holder signs, and can't refund what it doesn't hold. Alice's signature doesn't burn bob's tokens; bob's alone
    // (the refund and the burn under it) does.
    t.e.set_auths(&[]);
    assert!(t.pad.try_refund(&t.bob, &token, &ONE).is_err());
    let args = (t.bob.clone(), token.clone(), ONE).into_val(&t.e);
    assert!(!signed_by(&t, &t.alice, "refund", args, || t.pad.try_refund(&t.bob, &token, &ONE).is_ok()));
    let burn = MockAuthInvoke {
        contract: &token,
        fn_name: "burn",
        args: (t.bob.clone(), ONE).into_val(&t.e),
        sub_invokes: &[],
    };
    let refund = MockAuthInvoke {
        contract: &t.pad.address,
        fn_name: "refund",
        args: (t.bob.clone(), token.clone(), ONE).into_val(&t.e),
        sub_invokes: std::slice::from_ref(&burn),
    };
    t.e.mock_auths(&[MockAuth { address: &t.bob, invoke: &refund }]);
    assert!(t.pad.try_refund(&t.bob, &token, &ONE).is_ok());
    t.e.mock_all_auths();
    assert!(t.pad.try_refund(&t.bob, &token, &(bob_tokens * 2)).is_err());
    assert_eq!(t.pad.try_refund(&t.bob, &token, &0).unwrap_err().unwrap(), err(Error::ZeroAmount));
    // Dust worth less than one unit of the quote pays nothing and is refused.
    assert_eq!(t.pad.try_refund(&t.bob, &token, &1).unwrap_err().unwrap(), err(Error::ZeroAmount));
    // Not before a rescue.
    let live = t.launch();
    assert_eq!(t.pad.try_refund(&t.bob, &live, &ONE).unwrap_err().unwrap(), err(Error::WrongPhase));
    assert_eq!(t.pad.try_quote_refund(&live, &ONE).unwrap_err().unwrap(), err(Error::WrongPhase));
    t.assert_solvent(&[token, live], 0);
}

/// Sharing on: after a rescue, holders still claim the quote rewards the token holds for them and refund every token,
/// the launchpad keeps exactly what it owes, and the token still covers every reward it hasn't paid (I-L1, I-L8).
#[test]
fn with_sharing_on_holders_claim_their_rewards_and_refund_everything_after_a_rescue() {
    let t = setup();
    let token = t.launch_on(QA_FAIL, true);
    t.after_snipe();
    t.buy(&t.bob, &token, 300 * ONE);
    t.buy(&t.alice, &token, WHALE);
    assert!(matches!(t.graduate(&token), GraduationOutcome::Failed(_)));
    t.advance(PRODUCTION_LAUNCH_DURATIONS.rescue_public);
    t.pad.rescue(&token);
    let tok = t.token(&token);
    let (quote_rewards, _) = tok.claim(&t.bob);
    assert!(quote_rewards > 0);
    for holder in [&t.bob, &t.alice] {
        let held = t.balance(&token, holder);
        t.pad.refund(holder, &token, &held);
    }
    assert_eq!(tok.total_supply(), 0);
    t.assert_solvent(std::slice::from_ref(&token), 0);
    let s = tok.sharing().unwrap();
    assert!(t.balance(&t.quote, &token) >= s.q.funded - s.q.paid);
}

/// I-L8 as a property: whatever the holders and the order, each refund pays floor(tokens·refund_quote/refund_supply),
/// the refunds never sum past the pot, and what stays behind is rounding dust. One environment; each case is a fresh
/// launch rescued by anyone after 30 days.
#[test]
fn refunds_pay_the_same_rate_in_any_order() {
    use proptest::prelude::*;
    use proptest::test_runner::{Config, TestRunner};
    let t = setup();
    let holders: std::vec::Vec<Address> = (0..4).map(|_| Address::generate(&t.e)).collect();
    for h in &holders {
        StellarAssetClient::new(&t.e, &t.quote).mint(h, &(100_000 * ONE));
    }
    // At most 7 × 500 XLM: the holders never complete the curve themselves; alice does.
    let buys = proptest::collection::vec((0..4usize, 1..=500i128), 1..8);
    let refunds = proptest::collection::vec((0..4usize, 1..=4u8), 1..12);
    let mut runner = TestRunner::new(Config { cases: 24, failure_persistence: None, ..Config::default() });
    runner
        .run(&(buys, refunds), |(buys, refunds)| {
            let token = t.launch_on(QA_FAIL, false);
            t.after_snipe();
            for (who, xlm) in &buys {
                t.buy(&holders[*who], &token, xlm * ONE);
            }
            t.buy(&t.alice, &token, WHALE);
            t.graduate(&token);
            t.advance(30 * DAY);
            t.pad.rescue(&token);
            let c = t.curve(&token);
            let (rq, rs) = (c.refund_quote, c.refund_supply);
            prop_assert_eq!(rq, threshold());
            let mut paid = 0;
            // Random partial refunds in a random order, then everyone (alice too) refunds the rest.
            let mut order: std::vec::Vec<(Address, u8)> =
                refunds.iter().map(|(w, part)| (holders[*w].clone(), *part)).collect();
            for h in holders.iter().chain([&t.alice]) {
                order.push((h.clone(), 1));
            }
            for (holder, part) in order {
                let held = t.balance(&token, &holder);
                let amount = held / part as i128;
                let expected = mul_div(amount, rq, rs);
                if amount == 0 || expected == 0 {
                    continue;
                }
                let before = t.balance(&t.quote, &holder);
                prop_assert_eq!(t.pad.refund(&holder, &token, &amount), expected);
                prop_assert_eq!(t.balance(&t.quote, &holder), before + expected);
                paid += expected;
                prop_assert!(paid <= rq);
                prop_assert_eq!(t.curve(&token).refunded, paid);
            }
            // Every attempt leaves less than one unit of the quote behind: its floor, or its dust that was worth 0.
            let left = t.token(&token).total_supply();
            prop_assert!(left < ONE, "{} tokens never refunded", left);
            prop_assert!(rq - paid <= (refunds.len() + 5) as i128, "{} left behind", rq - paid);
            Ok(())
        })
        .unwrap();
}

// ------------------------------------------------------------------------------------------------ protocol fees

#[test]
fn claim_protocol_fees_sweeps_up_to_20_launches_in_one_transfer_per_asset() {
    let t = setup();
    let quote_b = t.new_quote();
    let tokens: std::vec::Vec<Address> = (0..20)
        .map(|i| {
            let quote = if i % 2 == 0 { &t.quote } else { &quote_b };
            t.launch_p(&t.creator, &t.params_on(quote, SOROSWAP, false))
        })
        .collect();
    t.after_snipe();
    let (mut sum_a, mut sum_b) = (0, 0);
    for (i, token) in tokens.iter().enumerate() {
        t.buy(&t.alice, token, (10 + i as i128) * ONE);
        let fees = t.curve(token).protocol_fees;
        if i % 2 == 0 {
            sum_a += fees;
        } else {
            sum_b += fees;
        }
    }
    let list = Vec::from_slice(&t.e, &tokens);
    let mut too_many = list.clone();
    too_many.push_back(tokens[0].clone());
    assert_eq!(t.pad.try_claim_protocol_fees(&too_many).unwrap_err().unwrap(), err(Error::TooManyTokens));
    assert_eq!(t.pad.try_claim_protocol_fees(&Vec::new(&t.e)).unwrap_err().unwrap(), err(Error::NothingToClaim));

    t.e.set_auths(&[]);
    let totals = t.pad.claim_protocol_fees(&list);
    // One transfer per asset, to the treasury, and one pr_claim per launch.
    let all = t.e.events().all();
    for asset in [&t.quote, &quote_b, &t.xlm] {
        assert_eq!(all.filter_by_contract(asset).events().len(), 1);
    }
    assert_eq!(all.filter_by_contract(&t.pad.address).events().len(), 20);
    t.e.mock_all_auths();
    let expected = vec![&t.e, (t.quote.clone(), sum_a), (t.xlm.clone(), 20 * LAUNCH_FEE), (quote_b.clone(), sum_b)];
    assert_eq!(totals, expected);
    assert_eq!(t.balance(&t.quote, &t.treasury), sum_a);
    assert_eq!(t.balance(&quote_b, &t.treasury), sum_b);
    assert_eq!(t.balance(&t.xlm, &t.treasury), 20 * LAUNCH_FEE);
    for token in &tokens {
        let c = t.curve(token);
        assert_eq!((c.protocol_fees, c.launch_fee_due), (0, 0));
    }
    assert_eq!(t.pad.try_claim_protocol_fees(&list).unwrap_err().unwrap(), err(Error::NothingToClaim));
    assert_eq!(
        t.pad.try_claim_protocol_fees(&vec![&t.e, Address::generate(&t.e)]).unwrap_err().unwrap(),
        err(Error::UnknownLaunch)
    );
    // One launch at a time works too, and a launch named twice is swept once.
    t.buy(&t.bob, &tokens[0], 10 * ONE);
    let fees = t.curve(&tokens[0]).protocol_fees;
    let twice = vec![&t.e, tokens[0].clone(), tokens[0].clone()];
    assert_eq!(t.pad.claim_protocol_fees(&twice), vec![&t.e, (t.quote.clone(), fees)]);
    let even: std::vec::Vec<Address> = tokens.iter().step_by(2).cloned().collect();
    t.assert_solvent(&even, 0);
}

/// An XLM-quoted launch books its quote in the same SAC balance as every launch fee, and that balance stays exactly
/// what is owed through trades and both claims (I-L1).
#[test]
fn an_xlm_quoted_launch_shares_the_launch_fee_balance_and_stays_solvent() {
    let t = setup();
    t.pad.set_quote(&t.xlm, &PHANTOM, &threshold(), &true, &vec![&t.e], &SOROSWAP);
    let mut p = t.params_on(&t.xlm, SOROSWAP, false);
    p.creator_fee_bps = 500;
    p.initial_buy = 50 * ONE;
    let launches = [t.launch_p(&t.creator, &p), t.launch()];
    let in_xlm = &launches[0];
    t.assert_solvent(&launches, 0);
    t.after_snipe();
    let got = t.buy(&t.alice, in_xlm, 300 * ONE);
    t.assert_solvent(&launches, 0);
    t.pad.sell(&t.alice, in_xlm, &(got / 3), &0);
    t.assert_solvent(&launches, 0);
    t.pad.claim_creator_fees(in_xlm);
    t.assert_solvent(&launches, 0);
    // One XLM transfer carries the XLM launch's protocol fees and both launch fees.
    let fees = t.curve(in_xlm).protocol_fees;
    let totals = t.pad.claim_protocol_fees(&Vec::from_slice(&t.e, &launches));
    assert_eq!(totals, vec![&t.e, (t.xlm.clone(), fees + 2 * LAUNCH_FEE)]);
    t.assert_solvent(&launches, 0);
}

#[test]
fn a_treasury_that_cant_receive_the_quote_fails_the_whole_claim_and_nothing_moves() {
    let t = setup();
    // The treasury becomes a classic account that trusts the XLM stand-in but not the USDC quote.
    let treasury = add_account(&t.e, 3);
    add_trustline(&t.e, 3, &t.xlm_asset);
    t.pad.propose_treasury(&treasury);
    t.advance(48 * HOUR);
    t.pad.apply_treasury();
    let usdc = classic_asset(&t.e, b"USDC", 2);
    StellarAssetClient::new(&t.e, &usdc).mint(&t.alice, &(100_000 * ONE));
    t.pad.set_quote(&usdc, &PHANTOM, &threshold(), &true, &vec![&t.e], &SOROSWAP);
    t.pad.set_quote(&t.xlm, &PHANTOM, &threshold(), &true, &vec![&t.e], &SOROSWAP);
    StellarAssetClient::new(&t.e, &t.xlm).mint(&t.alice, &(100_000 * ONE));
    // An XLM-quoted launch first, so the XLM transfer runs before the USDC one fails.
    let on_xlm = t.launch_p(&t.creator, &t.params_on(&t.xlm, SOROSWAP, false));
    let on_usdc = t.launch_p(&t.creator, &t.params_on(&usdc, SOROSWAP, false));
    t.after_snipe();
    t.buy(&t.alice, &on_xlm, 100 * ONE);
    t.buy(&t.alice, &on_usdc, 100 * ONE);
    let list = vec![&t.e, on_xlm.clone(), on_usdc.clone()];
    let before =
        (t.curve(&on_xlm), t.curve(&on_usdc), t.balance(&t.xlm, &t.pad.address), t.balance(&usdc, &t.pad.address));
    assert!(t.pad.try_claim_protocol_fees(&list).is_err());
    let after =
        (t.curve(&on_xlm), t.curve(&on_usdc), t.balance(&t.xlm, &t.pad.address), t.balance(&usdc, &t.pad.address));
    assert_eq!(after, before);
    // The XLM transfer that ran before the USDC one failed is undone too.
    assert_eq!(t.balance(&t.xlm, &treasury), 0);
    // Once it trusts USDC, the same call sweeps both, to the treasury current at the call.
    add_trustline(&t.e, 3, &credit(b"USDC", 2));
    let totals = t.pad.claim_protocol_fees(&list);
    let xlm_total = before.0.protocol_fees + 2 * LAUNCH_FEE;
    assert_eq!(totals, vec![&t.e, (t.xlm.clone(), xlm_total), (usdc.clone(), before.1.protocol_fees)]);
    assert_eq!((t.balance(&t.xlm, &treasury), t.balance(&usdc, &treasury)), (xlm_total, before.1.protocol_fees));
    assert_eq!(t.balance(&t.xlm, &t.treasury), 0);
}

// ------------------------------------------------------------------------------------------------ harvest payees (O1, L13)

fn graduated(t: &T, sharing: bool) -> (Address, Address) {
    let token = t.launch_on(SOROSWAP, sharing);
    t.complete(&token);
    match t.graduate(&token) {
        GraduationOutcome::Graduated(pair) => (token, pair),
        f => panic!("{f:?}"),
    }
}

fn side(t: &T, payees: &[(Address, u32, bool)]) -> Vec<Payee> {
    let mut v = Vec::new(&t.e);
    for (to, bps, notify) in payees {
        v.push_back(Payee { to: to.clone(), bps: *bps, notify: *notify });
    }
    v
}

#[test]
fn harvest_payees_are_the_same_50_50_list_on_both_sides() {
    let t = setup();
    let live = t.launch_on(SOROSWAP, true);
    let reference = |token: &Address| PositionRef::Launch(token.clone());
    assert_eq!(t.pad.try_harvest_payees(&reference(&live)).unwrap_err().unwrap(), err(Error::NotGraduated));
    let (shared, _) = graduated(&t, true);
    let (plain, _) = graduated(&t, false);

    // Sharing on: the treasury's half, then the token itself (notified) for its holders.
    let p = t.pad.harvest_payees(&reference(&shared));
    let list = side(&t, &[(t.treasury.clone(), 5_000, false), (shared.clone(), 5_000, true)]);
    assert_eq!(p, HarvestPayees { quote: list.clone(), base: list });
    // Sharing off: the treasury's half, then the recipient.
    let p = t.pad.harvest_payees(&reference(&plain));
    let list = side(&t, &[(t.treasury.clone(), 5_000, false), (t.creator.clone(), 5_000, false)]);
    assert_eq!(p, HarvestPayees { quote: list.clone(), base: list });
    assert!(!p.base.is_empty(), "an empty base list would make the locker burn the launch's token side");

    // Only launches: a Moment's reference, or no launch at all, is refused.
    assert_eq!(
        t.pad.try_harvest_payees(&PositionRef::Moment(shared.clone())).unwrap_err().unwrap(),
        err(Error::UnknownLaunch)
    );
    assert_eq!(
        t.pad.try_harvest_payees(&reference(&Address::generate(&t.e))).unwrap_err().unwrap(),
        err(Error::UnknownLaunch)
    );

    // A new recipient and a new treasury are named from the next harvest on.
    let (new_recipient, new_treasury) = (Address::generate(&t.e), Address::generate(&t.e));
    t.pad.transfer_creator_fee_recipient(&plain, &new_recipient);
    t.pad.propose_treasury(&new_treasury);
    t.advance(48 * HOUR);
    t.pad.apply_treasury();
    let list = side(&t, &[(new_treasury.clone(), 5_000, false), (new_recipient, 5_000, false)]);
    assert_eq!(t.pad.harvest_payees(&reference(&plain)), HarvestPayees { quote: list.clone(), base: list });
    // set_fees after graduation changes nothing here: the split is pinned in the launch (V1).
    t.pad.set_fees(&100, &2_000, &1_000, &vec![&t.e, 9_800u32], &5);
    let list = side(&t, &[(new_treasury, 5_000, false), (shared.clone(), 5_000, true)]);
    assert_eq!(t.pad.harvest_payees(&reference(&shared)), HarvestPayees { quote: list.clone(), base: list });
}

/// Round trips through the graduated pool on the Soroswap router, so the locked LP earns fees.
fn churn(t: &T, token: &Address, rounds: u32) {
    let deadline = t.now() + 600;
    let router = soroswap_router::Client::new(&t.e, &t.router);
    for _ in 0..rounds {
        let out = router.swap_exact_tokens_for_tokens(
            &(500 * ONE),
            &0,
            &vec![&t.e, t.quote.clone(), token.clone()],
            &t.bob,
            &deadline,
        );
        router.swap_exact_tokens_for_tokens(
            &out.get_unchecked(1),
            &0,
            &vec![&t.e, token.clone(), t.quote.clone()],
            &t.bob,
            &deadline,
        );
    }
}

#[test]
fn set_fees_after_graduation_leaves_the_next_harvests_split_unchanged() {
    let t = setup();
    let (token, pair) = graduated(&t, false);
    t.pad.set_fees(&100, &2_000, &1_000, &vec![&t.e, 9_800u32, 2_500, 300, 30], &5);
    churn(&t, &token, 4);
    t.advance(HOUR);
    let before = |who: &Address| (t.balance(&t.quote, who), t.balance(&token, who));
    let (treasury0, creator0) = (before(&t.treasury), before(&t.creator));
    let (base_out, quote_out) = t.locker().harvest(&pair);
    assert!(base_out > 0 && quote_out > 0);
    // 50/50 on both sides by the launch's pinned share, not the new 20/80 (V1): the treasury's half, then the
    // recipient the rest.
    assert_eq!(before(&t.treasury), (treasury0.0 + quote_out / 2, treasury0.1 + base_out / 2));
    assert_eq!(before(&t.creator), (creator0.0 + quote_out - quote_out / 2, creator0.1 + base_out - base_out / 2));
}

#[test]
fn the_treasury_never_earns_holder_rewards_also_after_a_treasury_change() {
    let t = setup();
    let (token, pair) = graduated(&t, true);
    let tok = t.token(&token);
    // Built with the treasury of the moment excluded (V2).
    assert!(tok.is_excluded(&t.treasury));
    // A new treasury, through the timelock.
    let new_treasury = Address::generate(&t.e);
    t.pad.propose_treasury(&new_treasury);
    t.advance(48 * HOUR);
    t.pad.apply_treasury();
    assert!(!tok.is_excluded(&new_treasury));
    churn(&t, &token, 4);
    t.advance(HOUR);
    let (base_out, quote_out) = t.locker().harvest(&pair);
    assert!(base_out > 0 && quote_out > 0);
    // The locker excluded the new treasury before paying it launch tokens; the old one stays excluded.
    assert!(tok.is_excluded(&new_treasury) && tok.is_excluded(&t.treasury));
    assert_eq!(t.balance(&token, &new_treasury), base_out / 2);
    assert_eq!(t.balance(&t.quote, &new_treasury), quote_out / 2);
    // The holders' half went to the token, for them; once released, the treasury earns none of it, in either asset.
    t.advance(5);
    assert_eq!(tok.pending_rewards(&new_treasury), (0, 0));
    assert_eq!(tok.pending_rewards(&t.treasury), (0, 0));
    let (q, b) = tok.pending_rewards(&t.alice);
    assert!(q > 0 && b > 0, "{q} {b}");
}

// ------------------------------------------------------------------------------------------------ admin and guardian (L8, F16)

#[test]
fn the_treasury_and_venue_timelocks() {
    let t = setup();
    let d = PRODUCTION_LAUNCH_DURATIONS;
    let new = Address::generate(&t.e);
    assert_eq!(t.pad.try_apply_treasury().unwrap_err().unwrap(), err(Error::NoProposal));
    t.pad.propose_treasury(&new);
    let (eta, expires) = (t.now() + d.timelock, t.now() + d.timelock + d.timelock_window);
    assert!(t.emitted(&TreasuryProposed { new: new.clone(), eta, expires }));
    assert_eq!(t.pad.pending_treasury(), Some(PendingTreasury { addr: new.clone(), eta, expires }));
    t.advance(d.timelock - 1);
    assert_eq!(t.pad.try_apply_treasury().unwrap_err().unwrap(), err(Error::TimelockNotElapsed));
    t.advance(1);
    t.e.set_auths(&[]);
    t.pad.apply_treasury();
    assert!(t.emitted(&TreasurySet { new: new.clone() }));
    t.e.mock_all_auths();
    assert_eq!((t.pad.treasury(), t.pad.pending_treasury()), (new.clone(), None));
    // Swept fees go to the treasury current at the call ([D], F3).
    let token = t.launch();
    t.pad.claim_protocol_fees(&vec![&t.e, token]);
    assert_eq!(t.balance(&t.xlm, &new), LAUNCH_FEE);
    // A proposal applies up to the last second of its window, and lapses after it.
    t.pad.propose_treasury(&t.treasury);
    t.advance(d.timelock + d.timelock_window);
    t.pad.apply_treasury();
    assert_eq!(t.pad.treasury(), t.treasury);
    t.pad.propose_treasury(&new);
    t.advance(d.timelock + d.timelock_window + 1);
    assert_eq!(t.pad.try_apply_treasury().unwrap_err().unwrap(), err(Error::TimelockExpired));

    // Venues: a new one waits for the timelock, joins the table disabled and is enabled for future launches.
    let id = t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 });
    let p = t.pad.pending_venue(&id).unwrap();
    assert_eq!(
        (p.id, p.kind, p.executor.clone(), p.eta),
        (4, VenueKind::Soroswap, t.exec.clone(), t.now() + d.timelock)
    );
    assert_eq!(t.pad.try_apply_venue(&id).unwrap_err().unwrap(), err(Error::TimelockNotElapsed));
    t.advance(d.timelock);
    t.pad.apply_venue(&id);
    assert!(t.emitted(&VenueAdded {
        id,
        kind: VenueKind::Soroswap,
        executor: t.exec.clone(),
        params: VenueParams { fee_fraction: 0 }
    }));
    assert_eq!(t.pad.pending_venue(&id), None);
    assert!(!t.pad.venues().get_unchecked(4).enabled);
    assert_eq!(t.pad.try_preview_launch_terms(&t.quote, &id).unwrap_err().unwrap(), err(Error::VenueNotAllowed));
    t.pad.set_venue_enabled(&id, &true);
    assert!(t.emitted(&VenueEnabled { id, enabled: true }));
    t.launch_on(id, false);
    // Proposals are refused past 8 venues; Aquarius needs one of its tiers, and every other kind none.
    assert_eq!(
        t.pad.try_propose_venue(&VenueKind::Aquarius, &t.exec, &VenueParams { fee_fraction: 25 }).unwrap_err().unwrap(),
        err(Error::InvalidConfig)
    );
    for kind in [VenueKind::Soroswap, VenueKind::HoldOnly, VenueKind::QaFail] {
        assert_eq!(
            t.pad.try_propose_venue(&kind, &t.exec, &VenueParams { fee_fraction: 30 }).unwrap_err().unwrap(),
            err(Error::InvalidConfig),
            "{kind:?}"
        );
    }
    let ids: std::vec::Vec<u32> =
        (0..3).map(|_| t.pad.propose_venue(&VenueKind::Aquarius, &t.exec, &VenueParams { fee_fraction: 30 })).collect();
    assert_eq!(ids, [5, 6, 7]);
    t.advance(d.timelock);
    for id in &ids {
        t.pad.apply_venue(id);
    }
    assert_eq!(t.pad.venues().len(), MAX_VENUES);
    assert_eq!(
        t.pad.try_propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 }).unwrap_err().unwrap(),
        err(Error::InvalidConfig)
    );
    assert_eq!(t.pad.try_apply_venue(&99).unwrap_err().unwrap(), err(Error::NoProposal));
}

#[test]
fn the_guardian_can_cancel_treasury_and_venue_proposals_and_nothing_else() {
    let t = setup();
    let e = &t.e;
    let (g, stranger, new) = (t.guardian.clone(), Address::generate(e), Address::generate(e));
    // The guardian cancels a treasury proposal and a venue proposal (L8).
    t.pad.propose_treasury(&new);
    assert!(signed_by(&t, &g, "cancel_treasury", (g.clone(),).into_val(e), || t.pad.try_cancel_treasury(&g).is_ok()));
    assert!(t.emitted(&TreasuryProposalCancelled { new: new.clone(), by: g.clone() }));
    assert_eq!(t.pad.pending_treasury(), None);
    let id = t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 });
    let args = (g.clone(), id).into_val(e);
    assert!(signed_by(&t, &g, "cancel_venue", args, || t.pad.try_cancel_venue(&g, &id).is_ok()));
    assert!(t.emitted(&VenueProposalCancelled { id, by: g.clone() }));
    assert_eq!(t.pad.pending_venue(&id), None);
    // The admin can cancel them too; a stranger can't, even signing as itself.
    t.pad.propose_treasury(&new);
    assert_eq!(t.pad.try_cancel_treasury(&stranger).unwrap_err().unwrap(), err(Error::NotAuthorized));
    let id = t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 });
    assert_eq!(t.pad.try_cancel_venue(&stranger, &id).unwrap_err().unwrap(), err(Error::NotAuthorized));
    t.pad.cancel_treasury(&t.admin);
    t.pad.cancel_venue(&t.admin, &id);
    assert_eq!(t.pad.try_cancel_treasury(&t.admin).unwrap_err().unwrap(), err(Error::NoProposal));
    assert_eq!(t.pad.try_cancel_venue(&t.admin, &id).unwrap_err().unwrap(), err(Error::NoProposal));

    // Nothing else: the guardian's signature does none of the admin's work (§16).
    let token = stuck_launch(&t);
    t.advance(7 * DAY);
    t.pad.propose_guardian(&Some(new.clone()));
    let calls: [Signed; 13] = [
        ("propose_admin", (new.clone(),).into_val(e), &|| t.pad.try_propose_admin(&new).is_ok()),
        ("propose_treasury", (new.clone(),).into_val(e), &|| t.pad.try_propose_treasury(&new).is_ok()),
        ("set_launch_fee", (0i128,).into_val(e), &|| t.pad.try_set_launch_fee(&0).is_ok()),
        ("set_launches_enabled", (false,).into_val(e), &|| t.pad.try_set_launches_enabled(&false).is_ok()),
        ("set_whitelist_enabled", (true,).into_val(e), &|| t.pad.try_set_whitelist_enabled(&true).is_ok()),
        ("set_whitelisted", (new.clone(), true).into_val(e), &|| t.pad.try_set_whitelisted(&new, &true).is_ok()),
        ("set_venue_enabled", (SCRIPTED, false).into_val(e), &|| {
            t.pad.try_set_venue_enabled(&SCRIPTED, &false).is_ok()
        }),
        ("allow_fallback", (token.clone(),).into_val(e), &|| t.pad.try_allow_fallback(&token).is_ok()),
        ("rescue", (token.clone(),).into_val(e), &|| t.pad.try_rescue(&token).is_ok()),
        ("cancel_guardian", ().into_val(e), &|| t.pad.try_cancel_guardian().is_ok()),
        ("propose_guardian", (None::<Address>,).into_val(e), &|| t.pad.try_propose_guardian(&None).is_ok()),
        ("propose_creator_fee_recipient", (token.clone(), new.clone()).into_val(e), &|| {
            t.pad.try_propose_creator_fee_recipient(&token, &new).is_ok()
        }),
        ("cancel_recipient_change", (token.clone(), g.clone()).into_val(e), &|| {
            t.pad.try_cancel_recipient_change(&token, &g).is_ok()
        }),
    ];
    for (name, args, call) in calls {
        assert!(!signed_by(&t, &g, name, args, call), "the guardian could {name}");
    }
    assert!(t.pad.pending_guardian().is_some());
}

#[test]
fn the_guardian_hands_its_role_on_in_two_steps_or_renounces_it() {
    let t = setup();
    let e = &t.e;
    let (g, g2, wrong) = (t.guardian.clone(), Address::generate(e), Address::generate(e));
    assert_eq!(t.pad.try_accept_guardian().unwrap_err().unwrap(), err(Error::NoProposal));
    // Only the guardian starts a handoff.
    assert!(!signed_by(&t, &t.admin, "transfer_guardian", (g2.clone(),).into_val(e), || t
        .pad
        .try_transfer_guardian(&g2)
        .is_ok()));
    assert!(signed_by(&t, &g, "transfer_guardian", (g2.clone(),).into_val(e), || t
        .pad
        .try_transfer_guardian(&g2)
        .is_ok()));
    assert!(t.emitted(&GuardianHandoffStarted { new: g2.clone() }));
    assert_eq!(
        (t.pad.guardian(), t.instance::<Address>(DataKey::GuardianHandoff)),
        (Some(g.clone()), Some(g2.clone()))
    );
    // A wrong address never takes the role: the new key must accept.
    assert!(!signed_by(&t, &wrong, "accept_guardian", ().into_val(e), || t.pad.try_accept_guardian().is_ok()));
    assert!(!signed_by(&t, &g, "accept_guardian", ().into_val(e), || t.pad.try_accept_guardian().is_ok()));
    assert_eq!(t.pad.guardian(), Some(g.clone()));
    assert!(signed_by(&t, &g2, "accept_guardian", ().into_val(e), || t.pad.try_accept_guardian().is_ok()));
    assert!(t.emitted(&GuardianSet { new: Some(g2.clone()) }));
    assert_eq!((t.pad.guardian(), t.instance::<Address>(DataKey::GuardianHandoff)), (Some(g2.clone()), None));
    // The old key has no power left.
    t.pad.propose_treasury(&wrong);
    assert_eq!(t.pad.try_cancel_treasury(&g).unwrap_err().unwrap(), err(Error::NotAuthorized));
    // Renouncing ends the role, and a handoff started before it.
    t.pad.transfer_guardian(&wrong);
    assert!(!signed_by(&t, &t.admin, "renounce_guardian", ().into_val(e), || t.pad.try_renounce_guardian().is_ok()));
    assert!(signed_by(&t, &g2, "renounce_guardian", ().into_val(e), || t.pad.try_renounce_guardian().is_ok()));
    assert!(t.emitted(&GuardianSet { new: None }));
    assert_eq!((t.pad.guardian(), t.instance::<Address>(DataKey::GuardianHandoff)), (None, None));
    assert_eq!(t.pad.try_accept_guardian().unwrap_err().unwrap(), err(Error::NoProposal));
    assert_eq!(t.pad.try_transfer_guardian(&wrong).unwrap_err().unwrap(), err(Error::NotAuthorized));
    assert_eq!(t.pad.try_renounce_guardian().unwrap_err().unwrap(), err(Error::NotAuthorized));
    assert_eq!(t.pad.try_cancel_treasury(&wrong).unwrap_err().unwrap(), err(Error::NotAuthorized));
}

#[test]
fn the_admin_replaces_the_guardian_through_the_timelock_which_the_guardian_cannot_stop() {
    let t = setup();
    let e = &t.e;
    let d = PRODUCTION_LAUNCH_DURATIONS;
    let (g, g2, g3) = (t.guardian.clone(), Address::generate(e), Address::generate(e));
    assert_eq!(t.pad.try_apply_guardian().unwrap_err().unwrap(), err(Error::NoProposal));
    let args = (Some(g2.clone()),).into_val(e);
    assert!(!signed_by(&t, &g, "propose_guardian", args, || t.pad.try_propose_guardian(&Some(g2.clone())).is_ok()));
    t.pad.propose_guardian(&Some(g2.clone()));
    let (eta, expires) = (t.now() + d.timelock, t.now() + d.timelock + d.timelock_window);
    assert!(t.emitted(&GuardianProposed { new: Some(g2.clone()), eta, expires }));
    assert_eq!(t.pad.pending_guardian(), Some(PendingGuardian { new: Some(g2.clone()), eta, expires }));
    // The guardian can't cancel its replacement, and a handoff, started or accepted, doesn't clear it.
    assert!(!signed_by(&t, &g, "cancel_guardian", ().into_val(e), || t.pad.try_cancel_guardian().is_ok()));
    t.pad.transfer_guardian(&g3);
    assert!(t.pad.pending_guardian().is_some());
    t.pad.accept_guardian();
    assert_eq!((t.pad.guardian(), t.pad.pending_guardian().is_some()), (Some(g3.clone()), true));
    t.pad.transfer_guardian(&g);
    t.advance(d.timelock - 1);
    assert_eq!(t.pad.try_apply_guardian().unwrap_err().unwrap(), err(Error::TimelockNotElapsed));
    t.advance(1);
    // Anyone applies it; it clears the pending handoff, so the replaced key can't pass the role on.
    t.e.set_auths(&[]);
    t.pad.apply_guardian();
    assert!(t.emitted(&GuardianSet { new: Some(g2.clone()) }));
    t.e.mock_all_auths();
    assert_eq!(
        (t.pad.guardian(), t.instance::<Address>(DataKey::GuardianHandoff), t.pad.pending_guardian()),
        (Some(g2.clone()), None, None)
    );
    assert_eq!(t.pad.try_accept_guardian().unwrap_err().unwrap(), err(Error::NoProposal));
    // Removing the guardian works the same way, and only the admin cancels.
    t.pad.propose_guardian(&None);
    assert!(!signed_by(&t, &g2, "cancel_guardian", ().into_val(e), || t.pad.try_cancel_guardian().is_ok()));
    assert!(signed_by(&t, &t.admin, "cancel_guardian", ().into_val(e), || t.pad.try_cancel_guardian().is_ok()));
    assert!(t.emitted(&GuardianProposalCancelled { new: None }));
    assert_eq!(t.pad.try_cancel_guardian().unwrap_err().unwrap(), err(Error::NoProposal));
    t.pad.propose_guardian(&None);
    t.advance(d.timelock + d.timelock_window + 1);
    assert_eq!(t.pad.try_apply_guardian().unwrap_err().unwrap(), err(Error::TimelockExpired));
    t.pad.propose_guardian(&None);
    t.advance(d.timelock);
    t.pad.apply_guardian();
    assert_eq!(t.pad.guardian(), None);
}

#[test]
fn the_admin_hands_its_role_on_in_two_steps() {
    let t = setup();
    let e = &t.e;
    let new = Address::generate(e);
    assert_eq!(t.pad.try_accept_admin().unwrap_err().unwrap(), err(Error::NoProposal));
    t.pad.propose_admin(&new);
    assert!(t.emitted(&AdminProposed { proposed: new.clone() }));
    assert_eq!(t.instance::<Address>(DataKey::PendingAdmin), Some(new.clone()));
    assert!(!signed_by(&t, &t.admin, "accept_admin", ().into_val(e), || t.pad.try_accept_admin().is_ok()));
    assert!(signed_by(&t, &new, "accept_admin", ().into_val(e), || t.pad.try_accept_admin().is_ok()));
    assert!(t.emitted(&AdminSet { new: new.clone() }));
    assert_eq!((t.pad.config().admin, t.instance::<Address>(DataKey::PendingAdmin)), (new.clone(), None));
    // The old admin has no power left.
    assert!(!signed_by(&t, &t.admin, "set_launches_enabled", (false,).into_val(e), || t
        .pad
        .try_set_launches_enabled(&false)
        .is_ok()));
    assert!(signed_by(&t, &new, "set_launches_enabled", (false,).into_val(e), || t
        .pad
        .try_set_launches_enabled(&false)
        .is_ok()));
}

#[test]
fn every_privileged_function_rejects_a_wrong_signer() {
    let t = setup();
    let e = &t.e;
    let stranger = Address::generate(e);
    let new = Address::generate(e);
    let token = stuck_launch(&t);
    let recipient_token = t.launch();
    t.advance(7 * DAY);
    let schedule = vec![e, 9_800u32];
    let none: Vec<u32> = vec![e];
    let q2 = e.register_stellar_asset_contract_v2(t.admin.clone()).address();
    let params = VenueParams { fee_fraction: 0 };
    // (function, its signer, arguments, the call). Each is refused signed by a stranger, then done by its signer.
    let cases: std::vec::Vec<SignedBy> = std::vec![
        (
            "propose_admin",
            t.admin.clone(),
            (new.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_propose_admin(&new).is_ok())
        ),
        (
            "propose_treasury",
            t.admin.clone(),
            (new.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_propose_treasury(&new).is_ok())
        ),
        (
            "cancel_treasury",
            t.guardian.clone(),
            (t.guardian.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_cancel_treasury(&t.guardian).is_ok())
        ),
        (
            "set_launch_fee",
            t.admin.clone(),
            (ONE,).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_launch_fee(&ONE).is_ok())
        ),
        (
            "set_fees",
            t.admin.clone(),
            (100u32, 5_000u32, 1_000u32, schedule.clone(), 5u32).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_fees(&100, &5_000, &1_000, &schedule, &5).is_ok()),
        ),
        (
            "set_quote",
            t.admin.clone(),
            (q2.clone(), PHANTOM, threshold(), true, none.clone(), SOROSWAP).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_quote(&q2, &PHANTOM, &threshold(), &true, &none, &SOROSWAP).is_ok()),
        ),
        (
            "set_launches_enabled",
            t.admin.clone(),
            (true,).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_launches_enabled(&true).is_ok())
        ),
        (
            "set_whitelist_enabled",
            t.admin.clone(),
            (false,).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_whitelist_enabled(&false).is_ok())
        ),
        (
            "set_whitelisted",
            t.admin.clone(),
            (new.clone(), true).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_whitelisted(&new, &true).is_ok())
        ),
        (
            "propose_venue",
            t.admin.clone(),
            (VenueKind::Soroswap, t.exec.clone(), params).into_val(e),
            std::boxed::Box::new(|| t.pad.try_propose_venue(&VenueKind::Soroswap, &t.exec, &params).is_ok()),
        ),
        (
            "cancel_venue",
            t.guardian.clone(),
            (t.guardian.clone(), 4u32).into_val(e),
            std::boxed::Box::new(|| t.pad.try_cancel_venue(&t.guardian, &4).is_ok())
        ),
        (
            "set_venue_enabled",
            t.admin.clone(),
            (SCRIPTED, true).into_val(e),
            std::boxed::Box::new(|| t.pad.try_set_venue_enabled(&SCRIPTED, &true).is_ok())
        ),
        (
            "allow_fallback",
            t.admin.clone(),
            (token.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_allow_fallback(&token).is_ok())
        ),
        (
            "propose_creator_fee_recipient",
            t.admin.clone(),
            (recipient_token.clone(), new.clone()).into_val(e),
            std::boxed::Box::new(|| t.pad.try_propose_creator_fee_recipient(&recipient_token, &new).is_ok()),
        ),
        (
            "cancel_recipient_change",
            t.creator.clone(),
            (recipient_token.clone(), t.creator.clone()).into_val(e),
            std::boxed::Box::new(|| t.pad.try_cancel_recipient_change(&recipient_token, &t.creator).is_ok()),
        ),
        (
            "transfer_creator_fee_recipient",
            t.creator.clone(),
            (recipient_token.clone(), new.clone()).into_val(e),
            std::boxed::Box::new(|| t.pad.try_transfer_creator_fee_recipient(&recipient_token, &new).is_ok()),
        ),
        (
            "propose_guardian",
            t.admin.clone(),
            (Some(new.clone()),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_propose_guardian(&Some(new.clone())).is_ok())
        ),
        (
            "cancel_guardian",
            t.admin.clone(),
            ().into_val(e),
            std::boxed::Box::new(|| t.pad.try_cancel_guardian().is_ok())
        ),
        (
            "transfer_guardian",
            t.guardian.clone(),
            (new.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_transfer_guardian(&new).is_ok())
        ),
        ("accept_guardian", new.clone(), ().into_val(e), std::boxed::Box::new(|| t.pad.try_accept_guardian().is_ok())),
        (
            "renounce_guardian",
            new.clone(),
            ().into_val(e),
            std::boxed::Box::new(|| t.pad.try_renounce_guardian().is_ok())
        ),
        (
            "rescue",
            t.admin.clone(),
            (token.clone(),).into_val(e),
            std::boxed::Box::new(|| t.pad.try_rescue(&token).is_ok())
        ),
        ("accept_admin", new.clone(), ().into_val(e), std::boxed::Box::new(|| t.pad.try_accept_admin().is_ok())),
    ];
    // Proposals the cancels and accepts below need, made by the admin with every auth mocked.
    t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &params);
    for (name, signer, args, call) in cases {
        if name == "cancel_treasury" {
            t.pad.propose_treasury(&new);
        }
        if name == "cancel_recipient_change" {
            t.pad.propose_creator_fee_recipient(&recipient_token, &new);
        }
        assert!(!signed_by(&t, &stranger, name, args.clone(), &call), "{name} accepted a stranger's signature");
        assert!(signed_by(&t, &signer, name, args, &call), "{name} refused its signer");
    }
    assert_eq!(t.pad.config().admin, new);
}

// ------------------------------------------------------------------------------------------------ live launches (I-L4)

#[test]
fn admin_changes_never_touch_a_live_launch() {
    let t = setup();
    let d = PRODUCTION_LAUNCH_DURATIONS;
    let token = t.launch();
    t.after_snipe();
    t.buy(&t.alice, &token, 100 * ONE);
    let (launch, curve) = (t.pad.get_launch(&token), t.curve(&token));
    // Everything the admin can do to future launches.
    t.pad.set_quote(&t.quote, &(PHANTOM * 2), &(threshold() * 2), &true, &vec![&t.e, SCRIPTED], &SOROSWAP);
    t.pad.set_fees(&300, &10_000, &500, &vec![&t.e], &60);
    t.pad.set_launch_fee(&MAX_LAUNCH_FEE);
    t.pad.set_venue_enabled(&SOROSWAP, &false);
    t.pad.set_whitelist_enabled(&true);
    t.pad.set_launches_enabled(&false);
    t.pad.propose_treasury(&t.bob);
    let id = t.pad.propose_venue(&VenueKind::Soroswap, &t.exec, &VenueParams { fee_fraction: 0 });
    t.advance(d.timelock);
    t.pad.apply_treasury();
    t.pad.apply_venue(&id);
    assert_eq!((t.pad.get_launch(&token), t.curve(&token)), (launch.clone(), curve));
    // Trading goes on with the pinned values: 1% fee, 50/50 split.
    t.buy(&t.bob, &token, 100 * ONE);
    let c = t.curve(&token);
    assert_eq!(c.protocol_fees, ONE);
    assert_eq!(c.creator_fees, ONE);
    // Invalid settings are refused.
    let fees = |fee: u32, share: u32, max: u32, schedule: Vec<u32>, step: u32| {
        t.pad.try_set_fees(&fee, &share, &max, &schedule, &step).unwrap_err().unwrap()
    };
    let schedule = vec![&t.e, 9_800u32];
    assert_eq!(fees(9_000, 5_000, 900, schedule.clone(), 5), err(Error::InvalidConfig));
    assert_eq!(fees(100, 10_001, 1_000, schedule.clone(), 5), err(Error::InvalidConfig));
    assert_eq!(fees(100, 5_000, 1_000, Vec::from_array(&t.e, [1u32; 11]), 5), err(Error::InvalidConfig));
    assert_eq!(fees(100, 5_000, 1_000, vec![&t.e, 10_001u32], 5), err(Error::InvalidConfig));
    assert_eq!(fees(100, 5_000, 1_000, schedule.clone(), 0), err(Error::InvalidConfig));
    assert_eq!(fees(100, 5_000, 1_000, schedule, 61), err(Error::InvalidConfig));
    assert_eq!(t.pad.try_set_launch_fee(&-1).unwrap_err().unwrap(), err(Error::InvalidConfig));
    assert_eq!(t.pad.try_set_launch_fee(&(MAX_LAUNCH_FEE + 1)).unwrap_err().unwrap(), err(Error::InvalidConfig));
    t.pad.set_fees(&100, &5_000, &9_799, &Vec::from_array(&t.e, [10_000u32; 10]), &60);
    assert_eq!(t.pad.get_launch(&token), launch);
    // Its venue, disabled for future launches, still graduates it: the launch pinned it.
    t.buy(&t.alice, &token, WHALE);
    assert!(matches!(t.graduate(&token), GraduationOutcome::Graduated(_)));
    assert_eq!(t.curve(&token).graduated_venue, Some(SOROSWAP));
}

// ------------------------------------------------------------------------------------------------ errors and size

#[test]
fn error_values_lie_in_the_launchpad_range() {
    let all = [
        Error::LaunchesDisabled,
        Error::NotWhitelisted,
        Error::QuoteNotAllowed,
        Error::InvalidName,
        Error::InvalidSymbol,
        Error::InvalidUri,
        Error::CreatorFeeTooHigh,
        Error::TermsChanged,
        Error::VenueNotAllowed,
        Error::TooManyExemptions,
        Error::UnknownLaunch,
        Error::CurveClosed,
        Error::ZeroAmount,
        Error::SlippageExceeded,
        Error::InsufficientLiquidity,
        Error::NotCompleted,
        Error::AlreadyGraduated,
        Error::WrongPhase,
        Error::NotStuck,
        Error::FallbackNotAllowed,
        Error::GraceNotElapsed,
        Error::AlreadyStuck,
        Error::NothingToClaim,
        Error::NotRecipient,
        Error::NotAuthorized,
        Error::NoProposal,
        Error::TimelockNotElapsed,
        Error::TimelockExpired,
        Error::InvalidConfig,
        Error::InvalidEconomics,
        Error::UnknownVenue,
        Error::NotGraduated,
        Error::NonceUsed,
        Error::GraduationInvalid,
        Error::TooManyTokens,
        Error::QuoteNotSac,
        Error::FallbackTooEarly,
    ];
    assert_eq!(all.len(), 37);
    for (n, e) in (1..).zip(all) {
        assert_eq!(e as u32, err_code(dyor_common::TAG_LAUNCHPAD_V2, n));
        assert_eq!(tag_of(e as u32), Some(dyor_common::TAG_LAUNCHPAD_V2));
    }
    assert_eq!((Error::GraduationInvalid as u32, Error::FallbackTooEarly as u32), (10_134, 10_137));
}

/// §18.3's budget for launchpad-v2, on the WASM build.sh writes (spec-shaken, then wasm-opt -Oz).
#[test]
fn the_release_wasm_fits_in_110_kb() {
    let wasm = include_bytes!("../../dist/dyor_launchpad_v2.wasm");
    assert!(wasm.len() <= 110 * 1024, "{} bytes", wasm.len());
}

// ------------------------------------------------------------------------------------------------ Aquarius

/// The Aquarius router's other singletons (pools plane, config storage, reward boost feed), as exec-aquarius's tests
/// stand them in: they accept what a standard pool sends them.
#[contract]
pub struct Plane;

#[contractimpl]
impl Plane {
    pub fn update(_e: Env, _pool: Address, _pool_type: Symbol, _init_args: Vec<u128>, _reserves: Vec<u128>) {}
}

#[contract]
pub struct ConfigStorage;

#[contractimpl]
impl ConfigStorage {
    pub fn get_value(_e: Env, _key: Val) -> Option<Val> {
        None
    }
}

#[contract]
pub struct BoostFeed;

#[contractimpl]
impl BoostFeed {
    pub fn total_supply(_e: Env) -> u128 {
        0
    }
}

/// CT-03's router fixture configured like the testnet router: 1 AQUA per new standard pool. Returns (router, AQUA).
fn aquarius_fixture(e: &Env) -> (Address, Address) {
    let admin = Address::generate(e);
    let aqua = e.register_stellar_asset_contract_v2(admin.clone()).address();
    let boost = e.register_stellar_asset_contract_v2(admin.clone()).address();
    let router = e.register(aquarius_router::WASM, ());
    let r = aquarius_router::Client::new(e, &router);
    r.init_admin(&admin);
    r.set_privileged_addrs(&admin, &admin, &admin, &admin, &vec![e, admin.clone()], &admin);
    r.set_pool_hash(&admin, &e.deployer().upload_contract_wasm(aquarius_pool::WASM));
    r.set_token_hash(&admin, &e.deployer().upload_contract_wasm(aquarius_share::WASM));
    r.set_reward_token(&admin, &aqua);
    r.set_pools_plane(&admin, &e.register(Plane, ()));
    r.init_config_storage(&admin, &e.register(ConfigStorage, ()));
    r.set_reward_boost_config(&admin, &boost, &e.register(BoostFeed, ()));
    r.configure_init_pool_payment(&admin, &aqua, &(ONE as u128), &(ONE as u128), &(ONE as u128), &admin);
    (router, aqua)
}

#[test]
fn a_launch_graduates_on_aquarius_and_the_locker_holds_the_share_token() {
    let t = setup();
    let e = &t.e;
    let (router, aqua) = aquarius_fixture(e);
    let exec =
        e.register(exec_aquarius::WASM, (router.clone(), aqua.clone(), 10 * ONE, vec![e, t.pad.address.clone()]));
    StellarAssetClient::new(e, &aqua).mint(&exec, &(50 * ONE));
    // The venue joins through the timelock, on the 0.3% tier (L2).
    let id = t.add_venue(VenueKind::Aquarius, &exec, 30);
    let token = t.launch_on(id, false);
    assert_eq!(t.token(&token).lock_from(), vec![e, exec.clone(), t.exec.clone()]);
    t.complete(&token);
    let (pool_tokens, pool_quote, burn) = t.pad.graduation_preview(&token);

    // The test host checks every invocation against the network's per-transaction limits, and this graduation needs
    // more memory than the 40 MiB they allow: each call into the router, the pool, the share token and the launch
    // token instantiates a VM. It is measured and printed here instead of checked; CT-10's budget suite owns the
    // ceilings.
    t.e.cost_estimate().disable_resource_limits();
    let outcome = t.graduate(&token);
    let used = t.e.cost_estimate().resources();
    std::println!("Aquarius graduation: {} instructions, {} memory bytes", used.instructions, used.mem_bytes);
    let pool = match outcome {
        GraduationOutcome::Graduated(pool) => pool,
        f => panic!("{f:?}"),
    };
    // The standard pool the router names for the pair, seeded with the curve's amounts; 1 AQUA paid from the float.
    let tokens = dyor_common::aquarius::sorted_pair(e, &token, &t.quote);
    assert!(dyor_common::aquarius::AquariusRouterClient::new(e, &router).get_pools(&tokens).values().contains(&pool));
    let p = dyor_common::aquarius::AquariusPoolClient::new(e, &pool);
    let reserves = p.get_reserves();
    let (tok_r, quote_r) = if tokens.get_unchecked(0) == token {
        (reserves.get_unchecked(0), reserves.get_unchecked(1))
    } else {
        (reserves.get_unchecked(1), reserves.get_unchecked(0))
    };
    assert_eq!((tok_r as i128, quote_r as i128), (pool_tokens, pool_quote));
    assert_eq!(t.balance(&aqua, &exec), 49 * ONE);
    // The locker holds the share token, registered as this launch's Aquarius position.
    let share = p.share_id();
    let pos = t.locker().position(&pool).unwrap();
    assert_eq!(
        (pos.kind, pos.lp_token, pos.lp),
        (lp_locker::VenueKind::Aquarius, share.clone(), t.balance(&share, &t.locker))
    );
    assert_eq!(pos.reference, lp_locker::PositionRef::Launch(token.clone()));
    assert!(pos.lp > 0);
    // Unlocked, the rest burned, graduated on the creator's venue.
    assert!(t.token(&token).unlocked());
    assert_eq!(t.balance(&token, &t.pad.address), 0);
    assert_eq!(t.token(&token).total_supply(), DEFAULT_SUPPLY - burn);
    let g = t.curve(&token);
    assert_eq!((g.phase, g.graduated_venue, g.pool, g.stuck_since), (Phase::Graduated, Some(id), Some(pool), 0));
    t.assert_solvent(&[token], 0);
}
