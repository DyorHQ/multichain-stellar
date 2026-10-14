//! lp-locker (§8) against the real Soroswap factory, pair and router WASMs and CT-03's Aquarius router, pool and
//! share-token fixtures (contracts/testdata). Its owners are stand-ins for launchpad-v2 and moments-v2 that register
//! what they sent and answer `harvest_payees`; a sharing launch token is a stand-in that logs what the locker calls.
//!
//! Every harvest is checked against a model of §8.2 in plain Rust (`expected`), and I-K1 is checked exactly:
//! `principal ≤ √(r_b·r_q)·lp/total` as `(principal·total)² ≤ r_b·r_q·lp²` (`assert_principal_covered`). Auth is
//! enforced in every locker call: `mock_all_auths` is on only while a test funds accounts or trades (`as_anyone`).
extern crate std;

use super::*;
use crate::harvest::{harvestable_kind, pay_side, sqrt_product};
use dyor_common::aquarius::{sorted_pair, standard_pool_index, AquariusPoolClient, AquariusRouterClient};
use dyor_common::{
    isqrt_u128, mul_div_up, tag_of, HarvestPayees, LockerClient, Payee, TreasurySourceClient, MAX_HARVEST_INTERVAL,
    MAX_HARVEST_ROUND_BPS, MIN_DURATION,
};
use soroban_sdk::testutils::{Address as _, ContractEvents, EnvTestConfig, Events as _, Ledger as _};
use soroban_sdk::token::StellarAssetClient;
use soroban_sdk::xdr::{self, Limits, WriteXdr};
use soroban_sdk::{
    contract, contractimpl, contracttype, vec, Bytes, BytesN, Event as _, MuxedAddress, String, Symbol, TryIntoVal,
    Val, U256,
};
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
const HOUR: u64 = 3_600;
/// launchpad-v2's and moments-v2's compile-time harvest rates (§5.5, §9.1).
const LAUNCH_HARVEST_BPS: u32 = 10_000;
const MOMENT_HARVEST_BPS: u32 = 6_667;
/// About what a launch graduates: ~200M launch tokens against the threshold of a 2,000 XLM phantom.
const POOL_BASE: i128 = 206_913_808 * ONE;
const POOL_QUOTE: i128 = 4_324_555 * ONE / 1_000;
/// About what a Moment graduates at T = 10 USDC: 38.57M coins against 7.5 USDC.
const MOMENT_COINS: i128 = 38_571_428 * ONE;
const MOMENT_USDC: i128 = 75 * ONE / 10;
const START: u64 = 1_760_000_000;

// ------------------------------------------------------------------------------------------------ stand-ins

#[contracttype]
#[derive(Clone)]
enum OwnerKey {
    Treasury,
    Payees,
    Registered(PositionRef),
}

/// Stands in for launchpad-v2 and moments-v2: registers the positions whose LP it sent (with its own auth, as a
/// direct caller), answers `harvest_payees` with the lists a test sets, for references it registered only, and has a
/// treasury a test can change (`TreasurySource`).
#[contract]
pub struct TestOwner;

#[contractimpl]
impl TestOwner {
    pub fn __constructor(e: Env, treasury: Address) {
        e.storage().instance().set(&OwnerKey::Treasury, &treasury);
        let none = HarvestPayees { quote: Vec::new(&e), base: Vec::new(&e) };
        e.storage().instance().set(&OwnerKey::Payees, &none);
    }

    pub fn set_payees(e: Env, payees: HarvestPayees) {
        e.storage().instance().set(&OwnerKey::Payees, &payees);
    }

    pub fn set_treasury(e: Env, treasury: Address) {
        e.storage().instance().set(&OwnerKey::Treasury, &treasury);
    }

    pub fn treasury(e: Env) -> Address {
        e.storage().instance().get(&OwnerKey::Treasury).unwrap()
    }

    pub fn harvest_payees(e: Env, reference: PositionRef) -> HarvestPayees {
        assert!(e.storage().instance().has(&OwnerKey::Registered(reference)), "not my position");
        e.storage().instance().get(&OwnerKey::Payees).unwrap()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn register(
        e: Env,
        locker: Address,
        pool: Address,
        kind: VenueKind,
        lp_token: Address,
        lp: i128,
        base: Address,
        quote: Address,
        reference: PositionRef,
        harvest_bps: u32,
    ) {
        e.storage().instance().set(&OwnerKey::Registered(reference.clone()), &true);
        let this = e.current_contract_address();
        LockerClient::new(&e, &locker).register(
            &this,
            &pool,
            &kind,
            &lp_token,
            &lp,
            &base,
            &quote,
            &reference,
            &harvest_bps,
        );
    }
}

#[contracttype]
#[derive(Clone)]
enum TokenKey {
    Locker,
    Owner,
    Balance(Address),
    Notified(Address),
    Log,
}

/// Stands in for a launch token (launch-token-v2, §6): a plain SEP-41 subset with `exclude_treasury`, which reads its
/// launchpad's treasury, and `notify_reward` for the locker only, with §6.2's funding check. It logs, in order, what
/// the locker makes it do: `excl` (the treasury it excluded), `xfer` (each transfer out of the locker) and `notify`.
#[contract]
pub struct SharingToken;

#[contractimpl]
impl SharingToken {
    pub fn __constructor(e: Env, locker: Address, owner: Address) {
        e.storage().instance().set(&TokenKey::Locker, &locker);
        e.storage().instance().set(&TokenKey::Owner, &owner);
        e.storage().instance().set(&TokenKey::Log, &Vec::<(Symbol, Address, i128)>::new(&e));
    }

    pub fn decimals(_e: Env) -> u32 {
        7
    }

    pub fn name(e: Env) -> String {
        String::from_str(&e, "Launch")
    }

    pub fn symbol(e: Env) -> String {
        String::from_str(&e, "LAUNCH")
    }

    pub fn mint(e: Env, to: Address, amount: i128) {
        let b = Self::balance(e.clone(), to.clone());
        e.storage().persistent().set(&TokenKey::Balance(to), &(b + amount));
    }

    pub fn balance(e: Env, id: Address) -> i128 {
        e.storage().persistent().get(&TokenKey::Balance(id)).unwrap_or(0)
    }

    pub fn transfer(e: Env, from: Address, to: MuxedAddress, amount: i128) {
        from.require_auth();
        let to = to.address();
        let from_balance = Self::balance(e.clone(), from.clone());
        assert!(amount >= 0 && from_balance >= amount, "insufficient balance");
        e.storage().persistent().set(&TokenKey::Balance(from.clone()), &(from_balance - amount));
        Self::mint(e.clone(), to.clone(), amount);
        if from == Self::locker(&e) {
            Self::log_entry(&e, "xfer", to, amount);
        }
    }

    pub fn notify_reward(e: Env, notifier: Address, asset: Address, amount: i128) {
        assert!(notifier == Self::locker(&e), "not the locker");
        notifier.require_auth();
        assert!(amount > 0, "zero notify");
        let this = e.current_contract_address();
        let held = if asset == this {
            Self::balance(e.clone(), this)
        } else {
            soroban_sdk::token::TokenClient::new(&e, &asset).balance(&this)
        };
        let key = TokenKey::Notified(asset.clone());
        let notified = e.storage().instance().get::<_, i128>(&key).unwrap_or(0) + amount;
        assert!(held >= notified, "notified beyond the funds");
        e.storage().instance().set(&key, &notified);
        Self::log_entry(&e, "notify", asset, amount);
    }

    pub fn exclude_treasury(e: Env) -> bool {
        let owner: Address = e.storage().instance().get(&TokenKey::Owner).unwrap();
        let treasury = TreasurySourceClient::new(&e, &owner).treasury();
        Self::log_entry(&e, "excl", treasury, 0);
        true
    }

    pub fn log(e: Env) -> Vec<(Symbol, Address, i128)> {
        e.storage().instance().get(&TokenKey::Log).unwrap()
    }
}

impl SharingToken {
    fn locker(e: &Env) -> Address {
        e.storage().instance().get(&TokenKey::Locker).unwrap()
    }

    fn log_entry(e: &Env, what: &str, who: Address, amount: i128) {
        let mut log = Self::log(e.clone());
        log.push_back((Symbol::new(e, what), who, amount));
        e.storage().instance().set(&TokenKey::Log, &log);
    }
}

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

// ------------------------------------------------------------------------------------------------ harness

struct T {
    e: Env,
    locker: Address,
    /// The two owners: stand-ins for launchpad-v2 and moments-v2.
    pad: Address,
    moments: Address,
    treasury: Address,
    factory: Address,
    router: Address,
    issuer: Address,
    /// Trades on the pools.
    trader: Address,
}

fn setup() -> T {
    setup_in(Env::default(), true)
}

/// A locker owned by two stand-ins, the Soroswap factory and pair (and the router when a test trades through it), and
/// auth enforced from the moment this returns.
fn setup_in(e: Env, with_router: bool) -> T {
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    e.ledger().with_mut(|l| l.timestamp = START);
    let treasury = Address::generate(&e);
    let pad = e.register(TestOwner, (treasury.clone(),));
    let moments = e.register(TestOwner, (treasury.clone(),));
    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(&e, &factory).initialize(&Address::generate(&e), &pair_hash);
    let router = if with_router {
        let router = e.register(soroswap_router::WASM, ());
        soroswap_router::Client::new(&e, &router).initialize(&factory);
        router
    } else {
        Address::generate(&e)
    };
    let owners = vec![&e, pad.clone(), moments.clone()];
    let locker = e.register(LpLocker, (owners, factory.clone(), None::<Address>, HOUR));
    let t = T {
        locker,
        pad,
        moments,
        treasury,
        factory,
        router,
        issuer: Address::generate(&e),
        trader: Address::generate(&e),
        e,
    };
    t.e.set_auths(&[]);
    t
}

impl T {
    fn locker(&self) -> LpLockerClient<'_> {
        LpLockerClient::new(&self.e, &self.locker)
    }

    fn owner(&self, owner: &Address) -> TestOwnerClient<'_> {
        TestOwnerClient::new(&self.e, owner)
    }

    /// Runs `f` with every auth mocked (a third party's own actions), then enforces auth again.
    fn as_anyone<R>(&self, f: impl FnOnce() -> R) -> R {
        self.e.mock_all_auths();
        let r = f();
        self.e.set_auths(&[]);
        r
    }

    fn sac(&self) -> Address {
        self.e.register_stellar_asset_contract_v2(self.issuer.clone()).address()
    }

    /// A launch token stand-in of `owner`'s.
    fn launch_token(&self, owner: &Address) -> Address {
        self.e.register(SharingToken, (self.locker.clone(), owner.clone()))
    }

    /// Mints `amount` of a SAC or a launch token stand-in to `to`.
    fn give(&self, asset: &Address, to: &Address, amount: i128) {
        self.as_anyone(|| StellarAssetClient::new(&self.e, asset).mint(to, &amount));
    }

    fn balance(&self, asset: &Address, of: &Address) -> i128 {
        soroban_sdk::token::TokenClient::new(&self.e, asset).balance(of)
    }

    fn advance(&self, secs: u64) {
        self.e.ledger().with_mut(|l| l.timestamp += secs);
    }

    fn now(&self) -> u64 {
        self.e.ledger().timestamp()
    }

    fn pos(&self, pool: &Address) -> Position {
        self.locker().position(pool).unwrap()
    }

    /// A fresh Soroswap pair of `base`/`quote` seeded with the amounts, its LP minted straight to the locker (as an
    /// executor's `deposit(lp_to)` does), and registered by `owner`. Returns the pair.
    #[allow(clippy::too_many_arguments)]
    fn soroswap_position(
        &self,
        owner: &Address,
        base: &Address,
        quote: &Address,
        base_amount: i128,
        quote_amount: i128,
        harvest_bps: u32,
        reference: &PositionRef,
    ) -> Address {
        let pair = self.as_anyone(|| soroswap_factory::Client::new(&self.e, &self.factory).create_pair(base, quote));
        self.give(base, &pair, base_amount);
        self.give(quote, &pair, quote_amount);
        let lp = soroswap_pair::Client::new(&self.e, &pair).deposit(&self.locker);
        self.owner(owner).register(
            &self.locker,
            &pair,
            &VenueKind::Soroswap,
            &pair,
            &lp,
            base,
            quote,
            reference,
            &harvest_bps,
        );
        pair
    }

    /// The pool's reserves as (base, quote) and its LP supply.
    fn pool_state(&self, pair: &Address) -> (i128, i128, i128) {
        let base = self.pos(pair).base;
        let p = soroswap_pair::Client::new(&self.e, pair);
        let (r0, r1) = p.get_reserves();
        let (rb, rq) = if p.token_0() == base { (r0, r1) } else { (r1, r0) };
        (rb, rq, p.total_supply())
    }

    /// Swaps `amount_in` of `token_in` for `token_out` on the Soroswap router as the trader. Returns what came out.
    fn swap(&self, token_in: &Address, token_out: &Address, amount_in: i128) -> i128 {
        self.give(token_in, &self.trader, amount_in);
        self.as_anyone(|| {
            let path = vec![&self.e, token_in.clone(), token_out.clone()];
            let deadline = self.now() + 600;
            let out = soroswap_router::Client::new(&self.e, &self.router).swap_exact_tokens_for_tokens(
                &amount_in,
                &0,
                &path,
                &self.trader,
                &deadline,
            );
            out.get_unchecked(1)
        })
    }

    /// `rounds` round trips of `quote_in` quote through the pool: each pays the 0.3% fee twice.
    fn churn(&self, pair: &Address, rounds: u32, quote_in: i128) {
        let p = self.pos(pair);
        for _ in 0..rounds {
            let got = self.swap(&p.quote, &p.base, quote_in);
            self.swap(&p.base, &p.quote, got);
        }
    }

    fn set_payees(&self, owner: &Address, quote: &[(Address, u32, bool)], base: &[(Address, u32, bool)]) {
        let list = |l: &[(Address, u32, bool)]| {
            let mut v = Vec::new(&self.e);
            for (to, bps, notify) in l {
                v.push_back(Payee { to: to.clone(), bps: *bps, notify: *notify });
            }
            v
        };
        self.owner(owner).set_payees(&HarvestPayees { quote: list(quote), base: list(base) });
    }
}

/// One round of §8.2 as a model in plain Rust, from the pool and the position before the harvest.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Expected {
    current: i128,
    growth: i128,
    take: i128,
    lp_burned: i128,
    compounded: i128,
    principal: i128,
    est_base: i128,
    est_quote: i128,
}

fn expected(t: &T, pair: &Address) -> Expected {
    let p = t.pos(pair);
    let (rb, rq, total) = t.pool_state(pair);
    model(rb, rq, total, &p)
}

fn model(rb: i128, rq: i128, total: i128, p: &Position) -> Expected {
    let (bps, hb) = (BPS as i128, p.harvest_bps as i128);
    let root = isqrt_u128(rb as u128 * rq as u128) as i128;
    let current = root * p.lp / total;
    let growth = (current - p.principal).max(0);
    let take = (growth * hb / bps).min(current * MAX_HARVEST_ROUND_BPS as i128 / bps);
    let mut lp_burned = take * total / (root + 1);
    let (est_base, est_quote) = (lp_burned * rb / total, lp_burned * rq / total);
    if est_base == 0 || est_quote == 0 {
        lp_burned = 0;
    }
    let compounded = mul_div_up(take, bps - hb, hb);
    let principal = (p.principal + compounded).min(current - take);
    Expected {
        current,
        growth,
        take,
        lp_burned,
        compounded: principal - p.principal,
        principal,
        est_base: if lp_burned > 0 { est_base } else { 0 },
        est_quote: if lp_burned > 0 { est_quote } else { 0 },
    }
}

/// What one checked harvest did, and every event of its invocation.
struct Done {
    x: Expected,
    base_out: i128,
    quote_out: i128,
    lp_before: i128,
    events: ContractEvents,
}

/// Harvests `pair` and checks the round against the model: the event, the position afterwards, the LP it holds, and
/// that the venue paid at least the reserves-based estimates (Soroswap pays from its balances).
fn harvest(t: &T, pair: &Address) -> Done {
    let before = t.pos(pair);
    let x = expected(t, pair);
    assert!(x.lp_burned > 0, "the model expects nothing to harvest");
    let view = t.locker().harvestable(pair);
    assert_eq!(
        view,
        (x.growth, x.lp_burned, x.est_base, x.est_quote, before.last_harvest + t.locker().harvest_interval())
    );

    let (base_out, quote_out) = t.locker().harvest(pair);
    let all = t.e.events().all();
    let event = Harvested {
        pool: pair.clone(),
        lp_burned: x.lp_burned,
        base_out,
        quote_out,
        growth: x.growth,
        take: x.take,
        compounded: x.compounded,
        principal: x.principal,
    };
    let events = all.filter_by_contract(&t.locker);
    assert!(events.events().contains(&event.to_xdr(&t.e, &t.locker)), "harvested event");

    let after = t.pos(pair);
    assert_eq!(after.lp, before.lp - x.lp_burned);
    assert_eq!(after.principal, x.principal);
    assert_eq!(after.last_harvest, t.now());
    assert_eq!(t.balance(&after.lp_token, &t.locker), t.locker().tracked(&after.lp_token));
    assert!(base_out >= x.est_base && quote_out >= x.est_quote);
    assert_principal_covered(t, pair);
    Done { x, base_out, quote_out, lp_before: before.lp, events: all }
}

/// I-K1, exactly: the position's √k value, √(r_b·r_q)·lp/total, is at least its principal.
fn assert_principal_covered(t: &T, pair: &Address) {
    let p = t.pos(pair);
    let (rb, rq, total) = t.pool_state(pair);
    assert!(covered(&t.e, p.principal, p.lp, rb, rq, total), "I-K1: principal above the position's value");
}

fn covered(e: &Env, principal: i128, lp: i128, rb: i128, rq: i128, total: i128) -> bool {
    let u = |v: i128| U256::from_u128(e, v as u128);
    let lhs = u(principal).mul(&u(total)).pow(2);
    let rhs = u(rb).mul(&u(rq)).mul(&u(lp).pow(2));
    lhs <= rhs
}

fn locker_error(err: Error) -> soroban_sdk::Error {
    soroban_sdk::Error::from_contract_error(err as u32)
}

/// A graduated launch: its token (a stand-in) against a SAC quote, registered by the launchpad stand-in at
/// `LAUNCH_HARVEST_BPS`, paying both sides to the treasury until a test sets its own lists. Returns (pair, token,
/// quote).
fn launch(t: &T) -> (Address, Address, Address) {
    let token = t.launch_token(&t.pad);
    let quote = t.sac();
    let reference = PositionRef::Launch(token.clone());
    let pair = t.soroswap_position(&t.pad, &token, &quote, POOL_BASE, POOL_QUOTE, LAUNCH_HARVEST_BPS, &reference);
    t.set_payees(&t.pad, &[(t.treasury.clone(), BPS, false)], &[(t.treasury.clone(), BPS, false)]);
    (pair, token, quote)
}

/// Enough round trips that one harvest's growth exceeds the 0.5% round cap several times over: each round trip of a
/// whole quote reserve grows √k by about 0.15%.
fn heavy_volume(t: &T, pair: &Address) {
    t.churn(pair, 20, POOL_QUOTE);
}

// ------------------------------------------------------------------------------------------------ constructor

#[test]
fn constructor_fixes_the_owners_venues_and_interval() {
    let t = setup();
    let l = t.locker();
    assert_eq!(l.owners(), vec![&t.e, t.pad.clone(), t.moments.clone()]);
    assert_eq!(l.soroswap_factory(), t.factory);
    assert_eq!(l.aquarius_router(), None);
    assert_eq!(l.harvest_interval(), HOUR);
    assert_eq!(l.error_tag(), TAG_LP_LOCKER);

    // testnet-qa's 60 s and the 1-day bound are accepted, and the view returns the constructor's value.
    for interval in [MIN_DURATION, MAX_HARVEST_INTERVAL] {
        let e = Env::default();
        let f = Address::generate(&e);
        let r = Address::generate(&e);
        let id = e.register(LpLocker, (vec![&e, f.clone()], f, Some(r.clone()), interval));
        let l = LpLockerClient::new(&e, &id);
        assert_eq!((l.harvest_interval(), l.aquarius_router()), (interval, Some(r)));
    }
}

#[test]
#[should_panic(expected = "harvest_interval outside 60 s to 1 day")]
fn constructor_refuses_an_interval_below_60_s() {
    let e = Env::default();
    let a = Address::generate(&e);
    e.register(LpLocker, (vec![&e, a.clone()], a, None::<Address>, MIN_DURATION - 1));
}

#[test]
#[should_panic(expected = "harvest_interval outside 60 s to 1 day")]
fn constructor_refuses_an_interval_above_a_day() {
    let e = Env::default();
    let a = Address::generate(&e);
    e.register(LpLocker, (vec![&e, a.clone()], a, None::<Address>, MAX_HARVEST_INTERVAL + 1));
}

#[test]
#[should_panic(expected = "the locker needs an owner")]
fn constructor_refuses_no_owners() {
    let e = Env::default();
    let a = Address::generate(&e);
    e.register(LpLocker, (Vec::<Address>::new(&e), a, None::<Address>, HOUR));
}

// ------------------------------------------------------------------------------------------------ register

#[test]
fn register_records_the_position_with_its_principal_in_sqrt_k_units() {
    let t = setup();
    let (token, quote) = (t.launch_token(&t.pad), t.sac());
    let reference = PositionRef::Launch(token.clone());
    let pair = t.soroswap_position(&t.pad, &token, &quote, POOL_BASE, POOL_QUOTE, LAUNCH_HARVEST_BPS, &reference);
    let events = t.e.events().all().filter_by_contract(&t.locker);

    let lp = t.balance(&pair, &t.locker);
    let total = soroswap_pair::Client::new(&t.e, &pair).total_supply();
    assert_eq!(total, lp + 1_000); // Soroswap's minimum-liquidity lock
    let principal = isqrt_u128(POOL_BASE as u128 * POOL_QUOTE as u128) as i128 * lp / total;
    let p = t.pos(&pair);
    assert_eq!(
        p,
        Position {
            owner: t.pad.clone(),
            kind: VenueKind::Soroswap,
            lp_token: pair.clone(),
            base: token.clone(),
            quote: quote.clone(),
            reference: reference.clone(),
            lp,
            principal,
            harvest_bps: LAUNCH_HARVEST_BPS,
            last_harvest: START,
        }
    );
    assert_eq!(t.locker().tracked(&pair), lp);
    let event = Registered {
        pool: pair.clone(),
        owner: t.pad.clone(),
        kind: VenueKind::Soroswap,
        lp_token: pair.clone(),
        lp,
        base: token,
        quote,
        reference,
        harvest_bps: LAUNCH_HARVEST_BPS,
        principal,
    };
    assert_eq!(events, [event.to_xdr(&t.e, &t.locker)]);
    assert_principal_covered(&t, &pair);
}

/// A HoldOnly-style position: `lp` units of an LP stand-in (a SAC) sent to the locker, registered by `owner`.
fn hold(t: &T, owner: &Address, kind: VenueKind, lp_token: &Address, lp: i128) -> Result<(), soroban_sdk::Error> {
    let pool = Address::generate(&t.e);
    let reference = PositionRef::Launch(Address::generate(&t.e));
    let (base, quote) = (Address::generate(&t.e), Address::generate(&t.e));
    match t.owner(owner).try_register(&t.locker, &pool, &kind, lp_token, &lp, &base, &quote, &reference, &10_000) {
        Ok(_) => Ok(()),
        Err(Ok(err)) => Err(err),
        Err(Err(_)) => panic!("register aborted"),
    }
}

#[test]
fn register_is_for_owners_only_and_needs_their_auth() {
    let t = setup();
    let lp_token = t.sac();
    t.give(&lp_token, &t.locker, 100);

    // A contract outside the owners, signing for itself.
    let outsider = t.e.register(TestOwner, (t.treasury.clone(),));
    assert_eq!(hold(&t, &outsider, VenueKind::HoldOnly, &lp_token, 100), Err(locker_error(Error::NotOwner)));

    // An owner's address without the owner's signature: the host's auth check refuses it.
    let pool = Address::generate(&t.e);
    let r = t.locker().try_register(
        &t.pad,
        &pool,
        &VenueKind::HoldOnly,
        &lp_token,
        &100,
        &lp_token,
        &lp_token,
        &PositionRef::Launch(lp_token.clone()),
        &10_000,
    );
    assert!(r.is_err());
    assert_eq!(t.locker().position(&pool), None);

    // Both owners may register.
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 40), Ok(()));
    assert_eq!(hold(&t, &t.moments, VenueKind::HoldOnly, &lp_token, 60), Ok(()));
    assert_eq!(t.locker().tracked(&lp_token), 100);
}

#[test]
fn register_refuses_harvest_bps_of_0_or_above_bps() {
    let t = setup();
    let lp_token = t.sac();
    t.give(&lp_token, &t.locker, 100);
    let register = |hb: u32| {
        let pool = Address::generate(&t.e);
        let r = PositionRef::Moment(Address::generate(&t.e));
        t.owner(&t.moments).try_register(&t.locker, &pool, &VenueKind::HoldOnly, &lp_token, &1, &pool, &pool, &r, &hb)
    };
    for hb in [0, BPS + 1, u32::MAX] {
        assert_eq!(register(hb), Err(Ok(locker_error(Error::InvalidHarvestBps))));
    }
    for hb in [1, MOMENT_HARVEST_BPS, BPS] {
        assert!(register(hb).is_ok());
    }
}

#[test]
fn register_checks_the_lp_received_against_tracked() {
    let t = setup();
    let lp_token = t.sac();
    t.give(&lp_token, &t.locker, 150);
    let not_received = Err(locker_error(Error::LpNotReceived));
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 151), not_received);
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 0), not_received);
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, -1), not_received);
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 100), Ok(()));
    // 100 of the 150 are tracked now: a second position may claim only the other 50.
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 51), not_received);
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 50), Ok(()));
    assert_eq!(hold(&t, &t.pad, VenueKind::HoldOnly, &lp_token, 1), not_received);
    assert_eq!(t.locker().tracked(&lp_token), 150);
}

#[test]
fn register_refuses_an_lp_token_without_a_balance_as_not_received() {
    // qa-exec-fail's mode 2 reports its own address as the LP token, and it has no `balance`: the locker refuses it
    // with its own error instead of trapping (lead ruling, 2026-10-14).
    let t = setup();
    let bogus = t.e.register(Plane, ());
    let r = hold(&t, &t.pad, VenueKind::QaFail, &bogus, 1);
    assert_eq!(r, Err(locker_error(Error::LpNotReceived)));
}

#[test]
fn register_refuses_a_pool_that_has_a_position() {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    let lp = t.pos(&pair).lp;
    // Even with more LP sent, the pool keeps its one position.
    let extra = t.as_anyone(|| {
        t.give(&token, &pair, ONE);
        t.give(&quote, &pair, ONE);
        soroswap_pair::Client::new(&t.e, &pair).deposit(&t.locker)
    });
    let r = t.owner(&t.pad).try_register(
        &t.locker,
        &pair,
        &VenueKind::Soroswap,
        &pair,
        &extra,
        &token,
        &quote,
        &PositionRef::Launch(token.clone()),
        &LAUNCH_HARVEST_BPS,
    );
    assert_eq!(r, Err(Ok(locker_error(Error::PositionExists))));
    assert_eq!(t.pos(&pair).lp, lp);
}

// ------------------------------------------------------------------------------------------------ harvest guards

#[test]
fn harvest_is_too_soon_before_the_interval() {
    let t = setup();
    let (pair, ..) = launch(&t);
    heavy_volume(&t, &pair);
    let too_soon = Err(Ok(Error::TooSoon));
    assert_eq!(t.locker().try_harvest(&pair), too_soon);
    t.advance(HOUR - 1);
    assert_eq!(t.locker().try_harvest(&pair), too_soon);
    assert_eq!(t.locker().harvestable(&pair).4, START + HOUR);
    t.advance(1);
    harvest(&t, &pair);

    // The next round is an interval after this one, whatever growth is waiting.
    t.advance(HOUR - 1);
    assert_eq!(t.locker().try_harvest(&pair), too_soon);
    t.advance(1);
    harvest(&t, &pair);
}

#[test]
fn harvest_finds_nothing_without_growth() {
    let t = setup();
    let (pair, ..) = launch(&t);
    t.advance(HOUR);
    assert_eq!(t.locker().harvestable(&pair), (0, 0, 0, 0, START + HOUR));
    assert_eq!(t.locker().try_harvest(&pair), Err(Ok(Error::NothingToHarvest)));
    // A swap too small to grow √k by a unit of the position's share leaves nothing either.
    t.swap(&t.pos(&pair).quote, &t.pos(&pair).base, 10);
    assert_eq!(t.locker().try_harvest(&pair), Err(Ok(Error::NothingToHarvest)));
}

#[test]
fn harvest_refuses_an_unknown_pool() {
    let t = setup();
    let pool = Address::generate(&t.e);
    assert_eq!(t.locker().try_harvest(&pool), Err(Ok(Error::UnknownPosition)));
    assert_eq!(t.locker().try_harvestable(&pool), Err(Ok(Error::UnknownPosition)));
    assert_eq!(t.locker().position(&pool), None);
}

#[test]
fn hold_only_and_qa_fail_positions_are_held_never_harvested() {
    let t = setup();
    for kind in [VenueKind::HoldOnly, VenueKind::QaFail] {
        let lp_token = t.sac();
        t.give(&lp_token, &t.locker, 1_000);
        let pool = Address::generate(&t.e);
        let reference = PositionRef::Launch(Address::generate(&t.e));
        t.owner(&t.pad).register(&t.locker, &pool, &kind, &lp_token, &1_000, &pool, &pool, &reference, &10_000);
        assert_eq!(t.pos(&pool).principal, 0);
        t.advance(HOUR);
        assert_eq!(t.locker().try_harvest(&pool), Err(Ok(Error::UnsupportedKind)));
        assert_eq!(t.locker().try_harvestable(&pool), Err(Ok(Error::UnsupportedKind)));
        assert_eq!(t.balance(&lp_token, &t.locker), 1_000);
    }
}

#[test]
fn the_harvested_kinds_follow_the_aquarius_gate() {
    assert!(harvestable_kind(VenueKind::Soroswap, false, false));
    assert!(harvestable_kind(VenueKind::Aquarius, true, true));
    // AQUARIUS_VENUE_OK false (CT-03's gate failed), or no router: Aquarius positions are held, not harvested.
    assert!(!harvestable_kind(VenueKind::Aquarius, false, true));
    assert!(!harvestable_kind(VenueKind::Aquarius, true, false));
    for (ok, router) in [(true, true), (false, false)] {
        assert!(!harvestable_kind(VenueKind::HoldOnly, ok, router));
        assert!(!harvestable_kind(VenueKind::QaFail, ok, router));
    }
}

// ------------------------------------------------------------------------------------------------ harvest maths

#[test]
fn the_round_cap_holds_and_capped_growth_stays_harvestable() {
    for hb in [LAUNCH_HARVEST_BPS, MOMENT_HARVEST_BPS] {
        let t = setup();
        let (token, quote) = (t.sac(), t.sac());
        let r = PositionRef::Launch(token.clone());
        let pair = t.soroswap_position(&t.pad, &token, &quote, POOL_BASE, POOL_QUOTE, hb, &r);
        t.set_payees(&t.pad, &[(t.treasury.clone(), BPS, false)], &[(t.treasury.clone(), BPS, false)]);
        heavy_volume(&t, &pair);

        // No new volume from here: every round drains the backlog by at most the cap.
        let mut capped = 0;
        loop {
            t.advance(HOUR);
            let x = expected(&t, &pair);
            if x.lp_burned == 0 {
                break;
            }
            let cap = x.current * MAX_HARVEST_ROUND_BPS as i128 / BPS as i128;
            let d = harvest(&t, &pair);
            // No round withdraws more than 0.5% of the position's LP.
            assert!(d.x.lp_burned * BPS as i128 <= d.lp_before * MAX_HARVEST_ROUND_BPS as i128);
            if d.x.take == cap && d.x.take < d.x.growth * hb as i128 / BPS as i128 {
                capped += 1;
                // What the cap left is still growth, harvested in the next rounds.
                assert!(expected(&t, &pair).growth > 0);
            }
        }
        assert!(capped >= 3, "the cap bound in {capped} rounds");
        // Drained: what is left above the principal is dust, too little to pay a unit of quote.
        assert_eq!(t.locker().try_harvest(&pair), Err(Ok(Error::NothingToHarvest)));
        let x = expected(&t, &pair);
        assert!(x.growth * 100_000 < x.current, "left {} of {}", x.growth, x.current);
    }
}

#[test]
fn harvest_bps_10000_keeps_the_principal_constant() {
    let t = setup();
    let (pair, ..) = launch(&t);
    let principal = t.pos(&pair).principal;
    for round in 0..6 {
        // Light and heavy volume, so the cap binds in some rounds and not in others.
        t.churn(&pair, 1, if round % 2 == 0 { POOL_QUOTE / 50 } else { POOL_QUOTE });
        t.advance(HOUR);
        let d = harvest(&t, &pair);
        assert_eq!(d.x.compounded, 0);
        assert_eq!(t.pos(&pair).principal, principal);
    }
}

#[test]
fn moments_compound_3333_to_6667_of_every_round_capped_or_not() {
    let t = setup();
    let (coin, usdc) = (t.sac(), t.sac());
    let nft = PositionRef::Moment(Address::generate(&t.e));
    let pair = t.soroswap_position(&t.moments, &coin, &usdc, MOMENT_COINS, MOMENT_USDC, MOMENT_HARVEST_BPS, &nft);
    let platform = Address::generate(&t.e);
    t.set_payees(&t.moments, &[(Address::generate(&t.e), 4_000, false), (platform, 6_000, false)], &[]);

    let (mut capped, mut uncapped) = (0, 0);
    for round in 0..8 {
        if round < 4 {
            t.churn(&pair, 2, MOMENT_USDC / 20);
        } else {
            t.churn(&pair, 4, 3 * MOMENT_USDC);
        }
        t.advance(HOUR);
        let d = harvest(&t, &pair);
        let (take, compounded) = (d.x.take, d.x.compounded);
        // compounded : harvested = (BPS − hb) : hb = 3,333 : 6,667, rounded up by less than one unit (F7).
        assert_eq!(compounded, mul_div_up(take, 3_333, 6_667));
        assert!(compounded * 6_667 >= take * 3_333 && compounded * 6_667 < take * 3_333 + 6_667);
        // Not 1 : 2 (V3): the compounded part is below half the harvested part.
        assert!(take > 30_000 && compounded * 2 < take);
        if take == d.x.current * MAX_HARVEST_ROUND_BPS as i128 / BPS as i128 && take < d.x.growth * 6_667 / 10_000 {
            capped += 1;
        } else {
            uncapped += 1;
        }
    }
    assert!(capped > 0 && uncapped > 0, "capped {capped}, uncapped {uncapped}");
}

#[test]
fn growth_is_measured_in_sqrt_k_so_a_donation_is_growth_and_swaps_never_lower_it() {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    let mut last = expected(&t, &pair).current;
    for i in 0..10 {
        let (a, b) = if i % 2 == 0 { (&quote, &token) } else { (&token, &quote) };
        let size = if i % 2 == 0 { POOL_QUOTE / 3 } else { POOL_BASE / 3 };
        t.swap(a, b, size);
        let now = expected(&t, &pair).current;
        assert!(now >= last);
        last = now;
    }
    // A synced quote donation raises √k at the donor's cost.
    t.give(&quote, &pair, POOL_QUOTE / 100);
    t.as_anyone(|| soroswap_pair::Client::new(&t.e, &pair).sync());
    assert!(expected(&t, &pair).current > last);
}

#[test]
fn sqrt_product_is_exact_beyond_u128() {
    let e = Env::default();
    e.cost_estimate().budget().reset_unlimited();
    let check = |x: i128, y: i128| {
        let r = sqrt_product(&e, x, y);
        let u = |v: i128| U256::from_u128(&e, v as u128);
        let n = u(x).mul(&u(y));
        let next = u(r).add(&U256::from_u32(&e, 1));
        assert!(u(r).pow(2) <= n && next.pow(2) > n, "√({x}·{y}) = {r}");
    };
    for (x, y) in [
        (0, 0),
        (0, i128::MAX),
        (1, 1),
        (POOL_BASE, POOL_QUOTE),
        (i128::MAX, i128::MAX),
        (i128::MAX, 2),
        (2, i128::MAX),
        (1 << 100, 1 << 100),
        ((1 << 100) - 1, (1 << 100) + 1),
        (u64::MAX as i128 + 1, u64::MAX as i128 + 1),
        (3, (1 << 126) + 12_345),
    ] {
        check(x, y);
    }
    let mut seed = 0x9e37_79b9_7f4a_7c15u128;
    for _ in 0..500 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let x = (seed >> 1) as i128 >> (seed % 64);
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let y = (seed >> 1) as i128 >> (seed % 64);
        check(x, y);
    }
}

// ------------------------------------------------------------------------------------------------ payouts

#[test]
fn a_launch_without_sharing_pays_treasury_and_recipient_50_50_on_both_sides() {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    let recipient = Address::generate(&t.e);
    let side = [(t.treasury.clone(), 5_000, false), (recipient.clone(), 5_000, false)];
    t.set_payees(&t.pad, &side, &side);
    heavy_volume(&t, &pair);
    t.advance(HOUR);

    let d = harvest(&t, &pair);
    let half = |x: i128| x * 5_000 / 10_000;
    assert_eq!(t.balance(&quote, &t.treasury), half(d.quote_out));
    assert_eq!(t.balance(&quote, &recipient), d.quote_out - half(d.quote_out));
    assert_eq!(t.balance(&token, &t.treasury), half(d.base_out));
    assert_eq!(t.balance(&token, &recipient), d.base_out - half(d.base_out));
    assert_eq!((t.balance(&quote, &t.locker), t.balance(&token, &t.locker)), (0, 0));
    // No notify payee: the token is never asked to exclude the treasury, and never notified.
    let log = SharingTokenClient::new(&t.e, &token).log();
    assert_eq!(log.iter().filter(|(what, ..)| what != &Symbol::new(&t.e, "xfer")).count(), 0);
}

#[test]
fn a_sharing_launch_excludes_the_treasury_then_notifies_its_token_in_both_assets() {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    let side = [(t.treasury.clone(), 5_000, false), (token.clone(), 5_000, true)];
    t.set_payees(&t.pad, &side, &side);
    heavy_volume(&t, &pair);
    t.advance(HOUR);

    let d = harvest(&t, &pair);
    let (q_treasury, b_treasury) = (d.quote_out / 2, d.base_out / 2);
    let (q_holders, b_holders) = (d.quote_out - q_treasury, d.base_out - b_treasury);
    assert_eq!(t.balance(&quote, &t.treasury), q_treasury);
    assert_eq!(t.balance(&token, &t.treasury), b_treasury);
    // The holders' halves sit at the token's own address, queued with notify_reward for the right asset.
    assert_eq!(t.balance(&quote, &token), q_holders);
    assert_eq!(t.balance(&token, &token), b_holders);
    let s = |v: &str| Symbol::new(&t.e, v);
    let log = SharingTokenClient::new(&t.e, &token).log();
    assert_eq!(
        log,
        vec![
            &t.e,
            // V2: the current treasury is excluded before any base-side payout, the treasury's included.
            (s("excl"), t.treasury.clone(), 0),
            (s("notify"), quote.clone(), q_holders),
            (s("xfer"), t.treasury.clone(), b_treasury),
            (s("xfer"), token.clone(), b_holders),
            (s("notify"), token.clone(), b_holders),
        ]
    );

    // After a treasury change the next harvest excludes and pays the new treasury (§5.5, F3).
    let new_treasury = Address::generate(&t.e);
    t.owner(&t.pad).set_treasury(&new_treasury);
    let side = [(new_treasury.clone(), 5_000, false), (token.clone(), 5_000, true)];
    t.set_payees(&t.pad, &side, &side);
    t.advance(HOUR);
    let d = harvest(&t, &pair);
    let log = SharingTokenClient::new(&t.e, &token).log();
    let round: std::vec::Vec<_> = log.iter().skip(5).collect();
    assert_eq!(round[0], (s("excl"), new_treasury.clone(), 0));
    assert_eq!(round[2], (s("xfer"), new_treasury.clone(), d.base_out / 2));
    assert_eq!(t.balance(&quote, &new_treasury), d.quote_out / 2);
}

#[test]
fn moments_pay_the_quote_side_40_60_and_burn_the_coin_side() {
    let t = setup();
    let (coin, usdc) = (t.sac(), t.sac());
    let nft = Address::generate(&t.e);
    let reference = PositionRef::Moment(nft.clone());
    let pair = t.soroswap_position(&t.moments, &coin, &usdc, MOMENT_COINS, MOMENT_USDC, MOMENT_HARVEST_BPS, &reference);
    let (creator, platform) = (Address::generate(&t.e), Address::generate(&t.e));
    t.set_payees(&t.moments, &[(creator.clone(), 4_000, false), (platform.clone(), 6_000, false)], &[]);
    t.churn(&pair, 4, MOMENT_USDC);
    t.advance(HOUR);

    let d = harvest(&t, &pair);
    let to_creator = d.quote_out * 4_000 / 10_000;
    assert_eq!(t.balance(&usdc, &creator), to_creator);
    assert_eq!(t.balance(&usdc, &platform), d.quote_out - to_creator);
    assert!(to_creator > 0 && d.base_out > 0);
    // The coin side was burned: the locker holds none of it and the coin's only event in the round past the pair's
    // payout is the burn of exactly base_out.
    assert_eq!((t.balance(&coin, &t.locker), t.balance(&coin, &creator), t.balance(&coin, &platform)), (0, 0, 0));
    assert_eq!(burned(&d.events, &coin), d.base_out);
}

/// The total the SAC `asset` burned in `events` (SEP-41 `burn` events: topics `["burn", from, …]`, data the amount).
fn burned(events: &ContractEvents, asset: &Address) -> i128 {
    let burn = xdr::ScVal::Symbol(xdr::ScSymbol("burn".try_into().unwrap()));
    let mut sum = 0;
    for ev in events.filter_by_contract(asset).events() {
        let xdr::ContractEventBody::V0(body) = &ev.body;
        if body.topics.first() == Some(&burn) {
            let xdr::ScVal::I128(parts) = &body.data else { panic!("burn data") };
            sum += ((parts.hi as i128) << 64) | parts.lo as i128;
        }
    }
    sum
}

#[test]
fn the_payee_lists_are_read_at_every_harvest() {
    // A recipient change between harvests: the growth harvested afterwards goes to the new recipient (F3).
    let t = setup();
    let (pair, _, quote) = launch(&t);
    let (old, new) = (Address::generate(&t.e), Address::generate(&t.e));
    t.set_payees(&t.pad, &[(old.clone(), BPS, false)], &[(old.clone(), BPS, false)]);
    heavy_volume(&t, &pair);
    t.advance(HOUR);
    let first = harvest(&t, &pair);
    t.set_payees(&t.pad, &[(new.clone(), BPS, false)], &[(new.clone(), BPS, false)]);
    t.advance(HOUR);
    let second = harvest(&t, &pair);
    assert_eq!(t.balance(&quote, &old), first.quote_out);
    assert_eq!(t.balance(&quote, &new), second.quote_out);
}

// ---------------------------------------------------------------------------- classic accounts and trustlines

fn account_id(seed: u8) -> xdr::AccountId {
    xdr::AccountId(xdr::PublicKey::PublicKeyTypeEd25519(xdr::Uint256([seed; 32])))
}

fn account(e: &Env, seed: u8) -> Address {
    xdr::ScAddress::Account(account_id(seed)).try_into_val(e).unwrap()
}

/// A classic account with some XLM.
fn add_account(e: &Env, seed: u8) -> Address {
    let id = account_id(seed);
    let key = Rc::new(xdr::LedgerKey::Account(xdr::LedgerKeyAccount { account_id: id.clone() }));
    let entry = Rc::new(xdr::LedgerEntry {
        data: xdr::LedgerEntryData::Account(xdr::AccountEntry {
            account_id: id,
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
    account(e, seed)
}

fn credit_asset(code: &[u8; 4], issuer: u8) -> xdr::AlphaNum4 {
    xdr::AlphaNum4 { asset_code: xdr::AssetCode4(*code), issuer: account_id(issuer) }
}

/// The SAC of the classic asset `code` issued by account `issuer`, which is created too.
fn classic_asset(e: &Env, code: &[u8; 4], issuer: u8) -> Address {
    add_account(e, issuer);
    let asset = xdr::Asset::CreditAlphanum4(credit_asset(code, issuer)).to_xdr(Limits::none()).unwrap();
    e.deployer().with_stellar_asset(Bytes::from_slice(e, &asset)).deploy()
}

/// An authorized trustline from account `holder` to `code` of `issuer`.
fn add_trustline(e: &Env, holder: u8, code: &[u8; 4], issuer: u8) {
    let asset = xdr::TrustLineAsset::CreditAlphanum4(credit_asset(code, issuer));
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

#[test]
fn a_payee_without_a_trustline_is_owed_on_either_side_and_withdraw_owed_pays_later() {
    let t = setup();
    let (base, quote) = (classic_asset(&t.e, b"BASE", 1), classic_asset(&t.e, b"USDC", 2));
    let r = PositionRef::Launch(base.clone());
    let pair = t.soroswap_position(&t.pad, &base, &quote, POOL_BASE, POOL_QUOTE, LAUNCH_HARVEST_BPS, &r);
    // A classic account that trusts neither asset.
    let recipient = add_account(&t.e, 3);
    let side = [(t.treasury.clone(), 5_000, false), (recipient.clone(), 5_000, false)];
    t.set_payees(&t.pad, &side, &side);
    heavy_volume(&t, &pair);
    t.advance(HOUR);

    let d = harvest(&t, &pair);
    let events = d.events.filter_by_contract(&t.locker);
    let (q_owed, b_owed) = (d.quote_out - d.quote_out / 2, d.base_out - d.base_out / 2);
    assert_eq!(t.balance(&quote, &t.treasury), d.quote_out / 2);
    assert_eq!(t.balance(&base, &t.treasury), d.base_out / 2);
    assert_eq!(t.locker().owed(&recipient, &quote), q_owed);
    assert_eq!(t.locker().owed(&recipient, &base), b_owed);
    assert_eq!((t.balance(&quote, &t.locker), t.balance(&base, &t.locker)), (q_owed, b_owed));
    for (asset, amount) in [(&quote, q_owed), (&base, b_owed)] {
        let credit = OwedCredited { to: recipient.clone(), asset: asset.clone(), amount, owed: amount };
        assert!(events.events().contains(&credit.to_xdr(&t.e, &t.locker)));
    }

    // Still no trustline: the payout fails as a whole and stays owed.
    assert!(t.locker().try_withdraw_owed(&recipient, &quote).is_err());
    assert_eq!(t.locker().owed(&recipient, &quote), q_owed);

    // A second harvest adds to what is owed.
    heavy_volume(&t, &pair);
    t.advance(HOUR);
    let d2 = harvest(&t, &pair);
    let q_owed = q_owed + d2.quote_out - d2.quote_out / 2;
    let b_owed = b_owed + d2.base_out - d2.base_out / 2;
    assert_eq!(t.locker().owed(&recipient, &quote), q_owed);

    // Once the recipient trusts both assets, anyone pays it out, with no signature.
    add_trustline(&t.e, 3, b"USDC", 2);
    add_trustline(&t.e, 3, b"BASE", 1);
    assert_eq!(t.locker().withdraw_owed(&recipient, &quote), q_owed);
    let paid = OwedPaid { to: recipient.clone(), asset: quote.clone(), amount: q_owed };
    assert_eq!(t.e.events().all().filter_by_contract(&t.locker), [paid.to_xdr(&t.e, &t.locker)]);
    assert_eq!(t.locker().withdraw_owed(&recipient, &base), b_owed);
    assert_eq!((t.balance(&quote, &recipient), t.balance(&base, &recipient)), (q_owed, b_owed));
    assert_eq!((t.locker().owed(&recipient, &quote), t.locker().owed(&recipient, &base)), (0, 0));
    assert_eq!((t.balance(&quote, &t.locker), t.balance(&base, &t.locker)), (0, 0));
    assert_eq!(t.locker().try_withdraw_owed(&recipient, &quote), Err(Ok(Error::NothingOwed)));
}

#[test]
fn zero_payouts_are_skipped() {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    // Accounts without trustlines: a zero transfer tried on them would leave an owed entry or an event.
    let (a, b) = (add_account(&t.e, 7), add_account(&t.e, 8));
    t.set_payees(
        &t.pad,
        &[(a.clone(), 0, false), (t.treasury.clone(), BPS, false)],
        &[(t.treasury.clone(), BPS, false), (token.clone(), 0, true), (b.clone(), 0, false)],
    );
    heavy_volume(&t, &pair);
    t.advance(HOUR);
    let d = harvest(&t, &pair);
    assert_eq!(t.balance(&quote, &t.treasury), d.quote_out);
    assert_eq!(t.balance(&token, &t.treasury), d.base_out);
    assert_eq!((t.locker().owed(&a, &quote), t.locker().owed(&b, &token)), (0, 0));
    // The token is a notify payee, so it excludes the treasury, but a zero share is never sent or notified.
    let log = SharingTokenClient::new(&t.e, &token).log();
    let s = |v: &str| Symbol::new(&t.e, v);
    assert_eq!(log, vec![&t.e, (s("excl"), t.treasury.clone(), 0), (s("xfer"), t.treasury.clone(), d.base_out)]);

    // Splitting 1 unit 50/50: the first share rounds to 0 and is skipped, the last takes the remainder; 0 of a side
    // that would be burned burns nothing.
    let usdc = t.sac();
    t.give(&usdc, &t.locker, 1);
    let (c, d) = (add_account(&t.e, 9), Address::generate(&t.e));
    let payees = vec![
        &t.e,
        Payee { to: c.clone(), bps: 5_000, notify: false },
        Payee { to: d.clone(), bps: 5_000, notify: false },
    ];
    t.e.as_contract(&t.locker, || {
        pay_side(&t.e, &usdc, 1, &payees);
        pay_side(&t.e, &usdc, 0, &Vec::new(&t.e));
    });
    assert_eq!((t.balance(&usdc, &d), t.locker().owed(&c, &usdc)), (1, 0));
}

// ------------------------------------------------------------------------------------------------ §8.3

/// The same graduated launch with the same volume behind it, built identically in a fresh Env.
fn sandwich_world() -> (T, Address, Address, Address) {
    let t = setup();
    let (pair, token, quote) = launch(&t);
    heavy_volume(&t, &pair);
    t.advance(HOUR);
    (t, pair, token, quote)
}

#[test]
fn moving_the_price_4x_before_a_harvest_takes_no_value_and_shifts_at_most_one_rounds_quote_side() {
    // World A harvests at the true price. In world B a mover first pushes the price 4x up or 4x down with one swap.
    let (a, pair_a, ..) = sandwich_world();
    let (rb, rq, _) = a.pool_state(&pair_a);
    let honest = harvest(&a, &pair_a);
    assert!(honest.x.take > 0);

    for up in [true, false] {
        let (b, pair, token, quote) = sandwich_world();
        assert_eq!(b.pool_state(&pair), (rb, rq, a.pool_state(&pair_a).2 + honest.x.lp_burned));
        // One swap of a whole reserve moves the price by just under 4x (the fee keeps part of the input).
        if up {
            b.swap(&quote, &token, rq);
        } else {
            b.swap(&token, &quote, rb);
        }
        let (mb, mq, _) = b.pool_state(&pair);
        // p' / p = (mq/mb) / (rq/rb): between 3.9 and 4 (or the inverse).
        let (num, den) = if up { (mq * rb, rq * mb) } else { (rq * mb, mq * rb) };
        assert!(num * 10 >= den * 39 && num <= den * 4, "moved {num}/{den}");

        let moved = harvest(&b, &pair);
        // The withdrawn value at the true price p = rq/rb never falls: base·rq/rb + quote, multiplied by rb.
        let value = |d: &Done| d.base_out * rq + d.quote_out * rb;
        assert!(value(&moved) >= value(&honest), "up {up}: {} < {}", value(&moved), value(&honest));
        // Only the mix moves, by at most one round's quote side, compared at the same take: the mover's own fees
        // grew √k, so its round takes a little more.
        let shift = (moved.quote_out * honest.x.take - honest.quote_out * moved.x.take).abs();
        assert!(shift <= honest.quote_out * moved.x.take, "up {up}: shift {shift}");
        assert!(moved.x.take >= honest.x.take);
    }
}

// ------------------------------------------------------------------------------------------------ custody

#[test]
fn harvests_need_no_signature_and_never_move_principal_lp() {
    let t = setup();
    let (pair, ..) = launch(&t);
    let lp0 = t.pos(&pair).lp;
    let supply0 = soroswap_pair::Client::new(&t.e, &pair).total_supply();
    let mut burned = 0;
    for _ in 0..5 {
        heavy_volume(&t, &pair);
        t.advance(HOUR);
        // Auth is enforced (no mocks): the keeper's call needs no signature, and the locker signs only for itself.
        burned += harvest(&t, &pair).x.lp_burned;
    }
    // Every LP unit that left the locker was burned by the pair for its reserves: the supply fell by exactly that,
    // the pair holds only its own minimum-liquidity lock, and the locker holds all the rest.
    let pair_client = soroswap_pair::Client::new(&t.e, &pair);
    assert_eq!(pair_client.total_supply(), supply0 - burned);
    assert_eq!(pair_client.balance(&pair), 1_000);
    assert_eq!(t.balance(&pair, &t.locker), lp0 - burned);
    assert_eq!(t.pos(&pair).lp, lp0 - burned);
    assert!(burned * 100 < lp0 * 3, "five rounds burned {burned} of {lp0}");
}

// ------------------------------------------------------------------------------------------------ Aquarius

struct Aq {
    t: T,
    /// A second locker without the Aquarius router.
    blind: Address,
    pool: Address,
    share: Address,
    tokens: Vec<Address>,
    index: BytesN<32>,
    base: Address,
    quote: Address,
}

/// The Aquarius fixtures configured like the testnet router (exec-aquarius's setup, with a free pool), a standard
/// 0.3% pool of two SACs seeded by a provider, and its shares split between a locker that knows the router and one
/// that doesn't, each registered by the launchpad stand-in.
fn aquarius_setup() -> Aq {
    let base_t = setup();
    let e = base_t.e.clone();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let aqua = e.register_stellar_asset_contract_v2(admin.clone()).address();
    let boost = e.register_stellar_asset_contract_v2(admin.clone()).address();
    let router = e.register(aquarius_router::WASM, ());
    let r = aquarius_router::Client::new(&e, &router);
    r.init_admin(&admin);
    r.set_privileged_addrs(&admin, &admin, &admin, &admin, &vec![&e, admin.clone()], &admin);
    r.set_pool_hash(&admin, &e.deployer().upload_contract_wasm(aquarius_pool::WASM));
    r.set_token_hash(&admin, &e.deployer().upload_contract_wasm(aquarius_share::WASM));
    r.set_reward_token(&admin, &aqua);
    r.set_pools_plane(&admin, &e.register(Plane, ()));
    r.init_config_storage(&admin, &e.register(ConfigStorage, ()));
    r.set_reward_boost_config(&admin, &boost, &e.register(BoostFeed, ()));
    r.configure_init_pool_payment(&admin, &aqua, &0, &0, &0, &admin);

    let owners = vec![&e, base_t.pad.clone(), base_t.moments.clone()];
    let locker = e.register(LpLocker, (owners.clone(), base_t.factory.clone(), Some(router.clone()), HOUR));
    let blind = e.register(LpLocker, (owners, base_t.factory.clone(), None::<Address>, HOUR));
    let t = T { locker, ..base_t };

    let (base, quote) = (t.sac(), t.sac());
    let tokens = sorted_pair(&e, &base, &quote);
    let provider = Address::generate(&e);
    let (index, pool) = AquariusRouterClient::new(&e, &router).init_standard_pool(&provider, &tokens, &30);
    assert_eq!(index, standard_pool_index(&e, 30));
    let (b_amt, q_amt) = (POOL_BASE as u128, POOL_QUOTE as u128);
    let desired = if tokens.get_unchecked(0) == base { vec![&e, b_amt, q_amt] } else { vec![&e, q_amt, b_amt] };
    StellarAssetClient::new(&e, &base).mint(&provider, &POOL_BASE);
    StellarAssetClient::new(&e, &quote).mint(&provider, &POOL_QUOTE);
    let (_, shares) = AquariusRouterClient::new(&e, &router).deposit(&provider, &tokens, &index, &desired, &0);
    let share = AquariusPoolClient::new(&e, &pool).share_id();
    let half = shares as i128 / 2;
    let st = soroban_sdk::token::TokenClient::new(&e, &share);
    st.transfer(&provider, &t.locker, &half);
    st.transfer(&provider, &blind, &half);
    let reference = PositionRef::Launch(base.clone());
    for l in [&t.locker, &blind] {
        t.owner(&t.pad).register(l, &pool, &VenueKind::Aquarius, &share, &half, &base, &quote, &reference, &10_000);
    }
    t.set_payees(&t.pad, &[(t.treasury.clone(), BPS, false)], &[(t.treasury.clone(), BPS, false)]);
    e.set_auths(&[]);
    Aq { t, blind, pool, share, tokens, index, base, quote }
}

impl Aq {
    fn swap(&self, token_in: &Address, token_out: &Address, amount: i128) -> u128 {
        let t = &self.t;
        t.give(token_in, &t.trader, amount);
        t.as_anyone(|| {
            aquarius_router::Client::new(&t.e, &t.locker().aquarius_router().unwrap()).swap(
                &t.trader,
                &self.tokens,
                token_in,
                token_out,
                &self.index,
                &(amount as u128),
                &0,
            )
        })
    }

    fn reserves(&self) -> (i128, i128, i128) {
        let p = AquariusPoolClient::new(&self.t.e, &self.pool);
        let r = p.get_reserves();
        let (r0, r1) = (r.get_unchecked(0) as i128, r.get_unchecked(1) as i128);
        let (rb, rq) = if self.tokens.get_unchecked(0) == self.base { (r0, r1) } else { (r1, r0) };
        (rb, rq, p.get_total_shares() as i128)
    }
}

#[test]
fn aquarius_positions_are_valued_by_shares_and_harvested_by_withdrawing_shares() {
    let aq = aquarius_setup();
    let t = &aq.t;
    let (rb, rq, total) = aq.reserves();
    let p = t.pos(&aq.pool);
    assert_eq!(p.principal, isqrt_u128(rb as u128 * rq as u128) as i128 * p.lp / total);
    assert_eq!(p.lp_token, aq.share);

    for _ in 0..6 {
        let got = aq.swap(&aq.quote, &aq.base, POOL_QUOTE);
        aq.swap(&aq.base, &aq.quote, got as i128);
    }
    t.advance(HOUR);
    let (rb, rq, total) = aq.reserves();
    let x = model(rb, rq, total, &t.pos(&aq.pool));
    assert!(x.lp_burned > 0);

    // Auth enforced: the locker calls the router itself and pre-authorizes pool.withdraw and the share burn.
    let (base_out, quote_out) = t.locker().harvest(&aq.pool);
    // The pool pays the reserves pro rata to the shares burned (CT-03's check 5).
    assert_eq!((base_out, quote_out), (rb * x.lp_burned / total, rq * x.lp_burned / total));
    assert_eq!(aq.reserves().2, total - x.lp_burned);
    let after = t.pos(&aq.pool);
    assert_eq!((after.lp, after.principal), (p.lp - x.lp_burned, x.principal));
    assert_eq!(t.balance(&aq.share, &t.locker), after.lp);
    assert_eq!((t.balance(&aq.base, &t.treasury), t.balance(&aq.quote, &t.treasury)), (base_out, quote_out));
    let (rb, rq, total) = aq.reserves();
    assert!(covered(&t.e, after.principal, after.lp, rb, rq, total));

    // The locker without a router holds the same kind of position and never harvests it.
    let blind = LpLockerClient::new(&t.e, &aq.blind);
    assert_eq!(blind.try_harvest(&aq.pool), Err(Ok(Error::UnsupportedKind)));
    assert_eq!(t.balance(&aq.share, &aq.blind), p.lp);
}

// ------------------------------------------------------------------------------------------------ errors

#[test]
fn error_codes_are_10_601_to_10_609() {
    let errors = [
        Error::NotOwner,
        Error::PositionExists,
        Error::LpNotReceived,
        Error::UnknownPosition,
        Error::UnsupportedKind,
        Error::TooSoon,
        Error::NothingToHarvest,
        Error::NothingOwed,
        Error::InvalidHarvestBps,
    ];
    for (n, err) in (1..).zip(errors) {
        assert_eq!(err as u32, dyor_common::err_code(TAG_LP_LOCKER, n));
        assert_eq!(tag_of(err as u32), Some(TAG_LP_LOCKER));
    }
    assert_eq!(errors.map(|e| e as u32), [10_601, 10_602, 10_603, 10_604, 10_605, 10_606, 10_607, 10_608, 10_609]);
}

// ------------------------------------------------------------------------------------------------ property

/// Random swaps in both directions and random harvests on the Soroswap fixture, at a random harvest rate (10,000,
/// 6,667 or any other valid bps): after every step the position's √k value covers its principal exactly (I-K1);
/// every harvest matches the model, takes at most the growth and the round cap, burns at most 0.5% of the LP, and
/// compounds exactly ⌈take·(BPS − hb)/hb⌉ (F7). Trades go straight to the pair (UniswapV2's `swap`), which keeps a
/// case to a few VM calls per step. 1,000 cases in all; PROPTEST_CASES=100000 for the nightly run.
mod property {
    use super::*;
    use proptest::prelude::*;
    use proptest::test_runner::{Config, TestCaseError, TestRunner};

    #[derive(Clone, Debug)]
    enum Op {
        /// Quote in, as a share of the quote reserve in ‱ (up to 50%).
        Buy(u32),
        /// Base in, as a share of the base reserve.
        Sell(u32),
        /// Advance by the interval (or by half of it) and harvest.
        Harvest(bool),
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            4 => (1u32..5_000).prop_map(Op::Buy),
            4 => (1u32..5_000).prop_map(Op::Sell),
            2 => any::<bool>().prop_map(Op::Harvest),
        ]
    }

    fn rate() -> impl Strategy<Value = u32> {
        prop_oneof![Just(LAUNCH_HARVEST_BPS), Just(MOMENT_HARVEST_BPS), 1u32..=BPS]
    }

    /// One position on a fresh pair, with the pair's state cached between steps: reserves as (base, quote) and the
    /// LP supply, which only a harvest changes.
    struct World {
        t: T,
        pair: Address,
        hb: u32,
        base_first: bool,
        reserves: (i128, i128),
        total: i128,
    }

    impl World {
        fn new(hb: u32, base_amount: i128, quote_amount: i128) -> World {
            let t = setup_in(Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false }), false);
            let (base, quote) = (t.sac(), t.sac());
            let r = PositionRef::Moment(Address::generate(&t.e));
            let pair = t.soroswap_position(&t.moments, &base, &quote, base_amount, quote_amount, hb, &r);
            t.set_payees(&t.moments, &[(t.treasury.clone(), BPS, false)], &[]);
            let p = soroswap_pair::Client::new(&t.e, &pair);
            let (base_first, total) = (p.token_0() == base, p.total_supply());
            World { t, pair, hb, base_first, reserves: (base_amount, quote_amount), total }
        }

        fn pair(&self) -> soroswap_pair::Client<'_> {
            soroswap_pair::Client::new(&self.t.e, &self.pair)
        }

        fn read_reserves(&mut self) {
            let (r0, r1) = self.pair().get_reserves();
            self.reserves = if self.base_first { (r0, r1) } else { (r1, r0) };
        }

        /// Sends `amount_in` to the pair and takes UniswapV2's `get_amount_out` for it (0.3% fee). A swap the pair
        /// refuses leaves the input in the pair as an unsynced donation, which only raises what the LP is worth.
        fn swap(&mut self, base_in: bool, amount_in: i128) {
            let (rb, rq) = self.reserves;
            let (r_in, r_out) = if base_in { (rb, rq) } else { (rq, rb) };
            let out = amount_in * 997 * r_out / (r_in * 1_000 + amount_in * 997);
            if out == 0 {
                return;
            }
            let p = self.t.pos(&self.pair);
            self.t.give(if base_in { &p.base } else { &p.quote }, &self.pair, amount_in);
            let (out_base, out_quote) = if base_in { (0, out) } else { (out, 0) };
            let (out_0, out_1) = if self.base_first { (out_base, out_quote) } else { (out_quote, out_base) };
            let _ = self.pair().try_swap(&out_0, &out_1, &self.t.trader);
            self.read_reserves();
        }

        fn harvest(&mut self, full: bool) -> Result<(), TestCaseError> {
            let t = &self.t;
            t.advance(if full { HOUR } else { HOUR / 2 });
            let before = t.pos(&self.pair);
            let x = model(self.reserves.0, self.reserves.1, self.total, &before);
            let r = t.locker().try_harvest(&self.pair);
            if t.now() < before.last_harvest + HOUR {
                prop_assert_eq!(r, Err(Ok(Error::TooSoon)));
                return Ok(());
            }
            if x.lp_burned == 0 {
                prop_assert_eq!(r, Err(Ok(Error::NothingToHarvest)));
                return Ok(());
            }
            let (base_out, quote_out) = r.unwrap().unwrap();
            let after = t.pos(&self.pair);
            let (bps, h) = (BPS as i128, self.hb as i128);
            prop_assert!(x.take <= x.growth && x.take * bps <= x.growth * h);
            prop_assert!(x.take * bps <= x.current * MAX_HARVEST_ROUND_BPS as i128);
            prop_assert!(x.lp_burned * bps <= before.lp * MAX_HARVEST_ROUND_BPS as i128);
            prop_assert!(base_out >= x.est_base && quote_out >= x.est_quote);
            prop_assert_eq!(after.principal - before.principal, mul_div_up(x.take, bps - h, h));
            prop_assert_eq!((after.lp, after.principal), (before.lp - x.lp_burned, x.principal));
            prop_assert_eq!(t.balance(&self.pair, &t.locker), after.lp);
            self.total -= x.lp_burned;
            prop_assert_eq!(self.pair().total_supply(), self.total);
            self.read_reserves();
            Ok(())
        }

        fn step(&mut self, op: &Op) -> Result<(), TestCaseError> {
            match *op {
                Op::Buy(share) => self.swap(false, self.reserves.1 * share as i128 / BPS as i128),
                Op::Sell(share) => self.swap(true, self.reserves.0 * share as i128 / BPS as i128),
                Op::Harvest(full) => self.harvest(full)?,
            }
            let p = self.t.pos(&self.pair);
            let (rb, rq) = self.reserves;
            prop_assert!(covered(&self.t.e, p.principal, p.lp, rb, rq, self.total), "I-K1 after {:?}", op);
            Ok(())
        }
    }

    /// The cases are split over four tests, which the test harness runs in parallel.
    const SHARDS: u32 = 4;

    fn run_shard() {
        let cases = std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or(1_000);
        let config = Config { cases: cases.div_ceil(SHARDS), failure_persistence: None, ..Config::default() };
        // Pools from dust-scale to a large launch: 10^4 to 10^17 units a side.
        let amount = || (4u32..=16).prop_flat_map(|exp| 10i128.pow(exp)..10i128.pow(exp + 1));
        TestRunner::new(config)
            .run(&(rate(), amount(), amount(), prop::collection::vec(op(), 1..20)), |(hb, b, q, ops)| {
                let mut w = World::new(hb, b, q);
                for op in &ops {
                    w.step(op)?;
                }
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn principal_stays_covered_and_rounds_compound_in_proportion_1() {
        run_shard();
    }

    #[test]
    fn principal_stays_covered_and_rounds_compound_in_proportion_2() {
        run_shard();
    }

    #[test]
    fn principal_stays_covered_and_rounds_compound_in_proportion_3() {
        run_shard();
    }

    #[test]
    fn principal_stays_covered_and_rounds_compound_in_proportion_4() {
        run_shard();
    }
}
