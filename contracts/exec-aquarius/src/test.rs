//! exec-aquarius against the Aquarius testnet fixtures (router, standard pool, share token; `testdata/fixtures.json`),
//! and CT-03's five-check gate (§7.2). Graduations go through `Source`, which stands in for launchpad-v2: it
//! pre-authorizes exactly its two transfers and calls `try_graduate`, so every auth below is real (no mocking once
//! `setup` returns).
extern crate std;

use super::*;
use dyor_common::aquarius::{AQUARIUS_POOL_LOOKUP_OK, AQUARIUS_VENUE_OK};
use dyor_common::{grad_failure, ExecutorClient, GradFailure, VenueParams, ERR_MAX, ERR_MIN, ORIGIN_HOST};
use soroban_sdk::testutils::{Address as _, AuthorizedFunction, AuthorizedInvocation, Events as _};
use soroban_sdk::token::StellarAssetClient;
use soroban_sdk::xdr::{Limited, Limits, ReadXdr, ScSpecEntry};
use soroban_sdk::{
    contract, contractimpl, contracttype, symbol_short, Bytes, Event, Executable, Map, MuxedAddress, String, Val,
};

#[allow(clippy::too_many_arguments)]
mod router {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_router.wasm");
}
#[allow(clippy::too_many_arguments)]
mod pool {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_pool.wasm");
}
mod share {
    soroban_sdk::contractimport!(file = "../testdata/aquarius_token_share.wasm");
}

const ROUTER_ID: &str = "CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD";
const POOL_ID: &str = "CCSXYUVLYALKJGIIYMGYLZI447VS6TDWFTVDL43B4IKK2WERHLWUVCRC";
const SHARE_ID: &str = "CBDBKHQ47GQYGSIO4ZGIWCQJFWZXFOFKHTF34LTBSS76MBVPHZDKWECV";

/// The contract address with id 0xff…ff.
const HIGHEST_CONTRACT: &str = "CD7777777777777777777777777777777777777777777777777767GY";

const ONE: i128 = 10_000_000; // 7 decimals
/// The testnet router's payment for a new standard pool (1 AQUA) and the testnet cap (10 AQUA, §7.2).
const POOL_PAYMENT: i128 = ONE;
const MAX_POOL_PAYMENT: i128 = 10 * ONE;
/// The float target on the owner's testnet: 50 × the pool payment (F11).
const FLOAT: i128 = 50 * ONE;
const SUPPLY: i128 = 1_000_000_000 * ONE;
const TOKEN_AMOUNT: i128 = 100_000_000 * ONE;
const QUOTE_AMOUNT: i128 = 4_324 * ONE;

// ------------------------------------------------------------------------------------------------ stand-ins

/// The router's other singletons (pools plane, config storage, reward boost feed) are not part of the gate. These
/// accept what a standard pool sends them.
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

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Outcome {
    Done(GraduateResult),
    Failed(GradFailure),
}

/// Stands in for launchpad-v2 (§5.5): pre-authorizes exactly `transfer(this, exec, amount)` on both assets, then
/// calls `try_graduate` and records a failure instead of failing itself.
#[contract]
pub struct Source;

#[contractimpl]
impl Source {
    pub fn graduate(e: Env, exec: Address, a: GraduateArgs) -> Outcome {
        let this = e.current_contract_address();
        e.authorize_as_current_contract(vec![
            &e,
            transfer_entry(&e, &a.token, &this, &exec, a.token_amount),
            transfer_entry(&e, &a.quote, &this, &exec, a.quote_amount),
        ]);
        match ExecutorClient::new(&e, &exec).try_graduate(&a) {
            Ok(Ok(r)) => Outcome::Done(r),
            Ok(Err(_)) => panic!("undecodable result"),
            Err(err) => Outcome::Failed(grad_failure(err)),
        }
    }
}

/// Stands in for lp-locker (§8.2): holds the shares and withdraws by share amount as the harvest will. Its router
/// call is its own; it pre-authorizes `pool.withdraw(this, shares, min)` → `share.burn(this, shares)` exactly.
#[contract]
pub struct Holder;

#[contractimpl]
impl Holder {
    pub fn withdraw(e: Env, router: Address, tokens: Vec<Address>, index: BytesN<32>, shares: u128) -> Vec<u128> {
        let this = e.current_contract_address();
        let router = AquariusRouterClient::new(&e, &router);
        let pool = router.get_pools(&tokens).get(index.clone()).unwrap();
        let share = AquariusPoolClient::new(&e, &pool).share_id();
        let min_amounts = vec![&e, 0u128, 0u128];
        e.authorize_as_current_contract(vec![
            &e,
            InvokerContractAuthEntry::Contract(SubContractInvocation {
                context: ContractContext {
                    contract: pool,
                    fn_name: Symbol::new(&e, "withdraw"),
                    args: (this.clone(), shares, min_amounts.clone()).into_val(&e),
                },
                sub_invocations: vec![
                    &e,
                    InvokerContractAuthEntry::Contract(SubContractInvocation {
                        context: ContractContext {
                            contract: share,
                            fn_name: symbol_short!("burn"),
                            args: (this.clone(), shares as i128).into_val(&e),
                        },
                        sub_invocations: Vec::new(&e),
                    }),
                ],
            }),
        ]);
        router.withdraw(&this, &tokens, &index, &shares, &min_amounts)
    }
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum LockError {
    /// launch-token-v2's `TransferLocked` (§6.4: tag 2, code 1).
    TransferLocked = 10_201,
    InsufficientBalance = 10_299,
}

#[contracttype]
#[derive(Clone)]
enum TokenKey {
    Launchpad,
    LockFrom,
    Unlocked,
    Balance(Address),
    Moves,
}

/// A launch token with launch-token-v2's transfer lock (§6.1, L4): until `unlock`, a transfer needs
/// `from == launchpad`, `from ∈ lock_from` or `to == launchpad`; anything else fails `TransferLocked`. It records
/// every transfer it lets through, so a test sees each path the launch token took.
#[contract]
pub struct LockedToken;

#[contractimpl]
impl LockedToken {
    pub fn __constructor(e: Env, launchpad: Address, lock_from: Vec<Address>, supply: i128) {
        let s = e.storage().instance();
        s.set(&TokenKey::Balance(launchpad.clone()), &supply);
        s.set(&TokenKey::Launchpad, &launchpad);
        s.set(&TokenKey::LockFrom, &lock_from);
        s.set(&TokenKey::Moves, &Vec::<(Address, Address, i128)>::new(&e));
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

    pub fn balance(e: Env, id: Address) -> i128 {
        e.storage().instance().get(&TokenKey::Balance(id)).unwrap_or(0)
    }

    pub fn transfer(e: Env, from: Address, to: MuxedAddress, amount: i128) {
        from.require_auth();
        let to = to.address();
        let s = e.storage().instance();
        let launchpad: Address = s.get(&TokenKey::Launchpad).unwrap();
        let lock_from: Vec<Address> = s.get(&TokenKey::LockFrom).unwrap();
        let unlocked = s.get(&TokenKey::Unlocked).unwrap_or(false);
        if !unlocked && from != launchpad && !lock_from.contains(&from) && to != launchpad {
            panic_with_error!(&e, LockError::TransferLocked);
        }
        let from_balance = Self::balance(e.clone(), from.clone());
        if amount < 0 || from_balance < amount {
            panic_with_error!(&e, LockError::InsufficientBalance);
        }
        s.set(&TokenKey::Balance(from.clone()), &(from_balance - amount));
        let to_balance = Self::balance(e.clone(), to.clone());
        s.set(&TokenKey::Balance(to.clone()), &(to_balance + amount));
        let mut moves: Vec<(Address, Address, i128)> = s.get(&TokenKey::Moves).unwrap();
        moves.push_back((from, to, amount));
        s.set(&TokenKey::Moves, &moves);
    }

    pub fn unlock(e: Env) {
        e.storage().instance().set(&TokenKey::Unlocked, &true);
    }

    /// Every transfer so far: `(from, to, amount)`.
    pub fn moves(e: Env) -> Vec<(Address, Address, i128)> {
        e.storage().instance().get(&TokenKey::Moves).unwrap()
    }
}

// ------------------------------------------------------------------------------------------------ harness

struct T {
    e: Env,
    admin: Address,
    router: Address,
    pay_to: Address,
    aqua: Address,
    quote: Address,
    /// Stands in for launchpad-v2.
    source: Address,
    exec: Address,
    /// A lock-mimicking launch token, minted to `source`.
    token: Address,
    /// Stands in for lp-locker.
    lp_to: Address,
}

/// A local deployment of the Aquarius fixtures, configured like the testnet router (1 AQUA per new standard pool),
/// and an exec-aquarius whose callers are `source` and a graduator, with `float` AQUA. `token_first` picks whether
/// the launch token sorts before the quote. Auth is enforced from the moment this returns.
fn setup_with(float: i128, token_first: bool) -> T {
    let e = Env::default();
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    let admin = Address::generate(&e);
    let issuer = Address::generate(&e);
    let aqua = e.register_stellar_asset_contract_v2(issuer.clone()).address();
    let quote = e.register_stellar_asset_contract_v2(issuer.clone()).address();
    let boost = e.register_stellar_asset_contract_v2(issuer).address();
    let pay_to = Address::generate(&e);

    let router = e.register(router::WASM, ());
    let r = router::Client::new(&e, &router);
    r.init_admin(&admin);
    r.set_privileged_addrs(&admin, &admin, &admin, &admin, &vec![&e, admin.clone()], &admin);
    r.set_pool_hash(&admin, &e.deployer().upload_contract_wasm(pool::WASM));
    r.set_token_hash(&admin, &e.deployer().upload_contract_wasm(share::WASM));
    r.set_reward_token(&admin, &aqua);
    r.set_pools_plane(&admin, &e.register(Plane, ()));
    r.init_config_storage(&admin, &e.register(ConfigStorage, ()));
    r.set_reward_boost_config(&admin, &boost, &e.register(BoostFeed, ()));
    r.configure_init_pool_payment(
        &admin,
        &aqua,
        &(POOL_PAYMENT as u128),
        &(POOL_PAYMENT as u128),
        &(POOL_PAYMENT as u128),
        &pay_to,
    );

    let source = e.register(Source, ());
    let callers = vec![&e, source.clone(), Address::generate(&e)];
    let exec = e.register(ExecAquarius, (router.clone(), aqua.clone(), MAX_POOL_PAYMENT, callers));
    // Contracts registered here get low addresses and SACs hashed ones, so the token sorts first unless it is
    // placed at the highest contract address.
    let token_args = (source.clone(), vec![&e, exec.clone()], SUPPLY);
    let token = if token_first {
        e.register(LockedToken, token_args)
    } else {
        e.register_at(&Address::from_str(&e, HIGHEST_CONTRACT), LockedToken, token_args)
    };
    assert_eq!(token < quote, token_first);
    StellarAssetClient::new(&e, &quote).mint(&source, &(10 * QUOTE_AMOUNT));
    if float > 0 {
        StellarAssetClient::new(&e, &aqua).mint(&exec, &float);
    }
    let lp_to = e.register(Holder, ());
    e.set_auths(&[]);
    T { e, admin, router, pay_to, aqua, quote, source, exec, token, lp_to }
}

fn setup() -> T {
    setup_with(FLOAT, true)
}

impl T {
    fn router(&self) -> AquariusRouterClient<'_> {
        AquariusRouterClient::new(&self.e, &self.router)
    }

    fn admin_router(&self) -> router::Client<'_> {
        router::Client::new(&self.e, &self.router)
    }

    fn exec(&self) -> ExecAquariusClient<'_> {
        ExecAquariusClient::new(&self.e, &self.exec)
    }

    fn balance(&self, asset: &Address, of: &Address) -> i128 {
        TokenClient::new(&self.e, asset).balance(of)
    }

    fn tokens(&self) -> Vec<Address> {
        sorted_pair(&self.e, &self.token, &self.quote)
    }

    fn args(&self, fee_fraction: u32) -> GraduateArgs {
        GraduateArgs {
            source: self.source.clone(),
            token: self.token.clone(),
            quote: self.quote.clone(),
            token_amount: TOKEN_AMOUNT,
            quote_amount: QUOTE_AMOUNT,
            lp_to: self.lp_to.clone(),
            params: VenueParams { fee_fraction },
            min_liquidity: 1,
        }
    }

    fn graduate(&self, a: &GraduateArgs) -> Outcome {
        SourceClient::new(&self.e, &self.source).graduate(&self.exec, a)
    }

    fn graduated(&self, a: &GraduateArgs) -> GraduateResult {
        match self.graduate(a) {
            Outcome::Done(r) => r,
            Outcome::Failed(f) => panic!("graduation failed: {f:?}"),
        }
    }

    /// Runs `f` with every auth mocked (a third party's or the router admin's own actions), then enforces auth again.
    fn as_anyone<R>(&self, f: impl FnOnce() -> R) -> R {
        self.e.mock_all_auths();
        let r = f();
        self.e.set_auths(&[]);
        r
    }

    /// A fresh SAC holding `amount` at `to` (an asset without a lock, for pools seeded by third parties).
    fn asset(&self, to: &Address, amount: i128) -> Address {
        let asset = self.e.register_stellar_asset_contract_v2(self.admin.clone()).address();
        self.as_anyone(|| StellarAssetClient::new(&self.e, &asset).mint(to, &amount));
        asset
    }
}

fn failed(code: u32) -> Outcome {
    Outcome::Failed(GradFailure { origin: TAG_EXEC_AQUARIUS, code })
}

fn hex(bytes: &[u8]) -> std::string::String {
    bytes.iter().map(|b| std::format!("{b:02x}")).collect()
}

fn contract_fn(contract: &Address, name: &str, args: Vec<Val>) -> AuthorizedFunction {
    AuthorizedFunction::Contract((contract.clone(), Symbol::new(contract.env(), name), args))
}

fn node(function: AuthorizedFunction, sub_invocations: std::vec::Vec<AuthorizedInvocation>) -> AuthorizedInvocation {
    AuthorizedInvocation { function, sub_invocations }
}

// ------------------------------------------------------------------------------------------------ graduation

#[test]
fn graduation_into_a_new_pool_pays_exactly_the_routers_amount_from_the_float() {
    let t = setup();
    assert!(t.router().get_pools(&t.tokens()).is_empty());
    let source_quote = t.balance(&t.quote, &t.source);

    let r = t.graduated(&t.args(30));
    let events = t.e.events().all().filter_by_contract(&t.exec);

    let index = standard_pool_index(&t.e, 30);
    assert_eq!(t.router().get_pools(&t.tokens()), Map::from_array(&t.e, [(index, r.pool.clone())]));
    assert_eq!(t.exec().float(), FLOAT - POOL_PAYMENT);
    assert_eq!(t.balance(&t.aqua, &t.pay_to), POOL_PAYMENT);
    // An empty pool takes both amounts in full and mints √(token·quote) shares, none of them locked.
    assert_eq!((r.token_used, r.quote_used), (TOKEN_AMOUNT, QUOTE_AMOUNT));
    assert_eq!(r.liquidity as u128, (TOKEN_AMOUNT as u128 * QUOTE_AMOUNT as u128).isqrt());
    assert_eq!(t.balance(&t.token, &t.source), SUPPLY - TOKEN_AMOUNT);
    assert_eq!(t.balance(&t.quote, &t.source), source_quote - QUOTE_AMOUNT);
    assert_eq!(
        events.events(),
        [ExecGraduated {
            source: t.source.clone(),
            token: t.token.clone(),
            quote: t.quote.clone(),
            pool: r.pool.clone(),
            liquidity: r.liquidity,
        }
        .to_xdr(&t.e, &t.exec)]
    );
}

/// The router's pool-creation event, as the fixture emits it for a standard pool (CT-15's pool discovery).
#[contractevent(topics = ["add_pool"], data_format = "vec")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AddPool {
    #[topic]
    pub tokens: Vec<Address>,
    pub pool: Address,
    pub pool_type: Symbol,
    pub pool_index: BytesN<32>,
    pub init_args: Vec<u32>,
}

#[test]
fn the_router_announces_the_new_pool_with_add_pool() {
    let t = setup();
    let r = t.graduated(&t.args(30));
    let add_pool = AddPool {
        tokens: t.tokens(),
        pool: r.pool,
        pool_type: Symbol::new(&t.e, "constant"),
        pool_index: standard_pool_index(&t.e, 30),
        init_args: vec![&t.e, 30],
    };
    let events = t.e.events().all().filter_by_contract(&t.router);
    assert!(events.events().contains(&add_pool.to_xdr(&t.e, &t.router)));
}

#[test]
fn shares_arrive_at_lp_to_and_nothing_stays_with_the_executor() {
    for token_first in [true, false] {
        let t = setup_with(FLOAT, token_first);
        let r = t.graduated(&t.args(30));
        assert_eq!(r.lp_token, AquariusPoolClient::new(&t.e, &r.pool).share_id());
        assert_eq!(t.balance(&r.lp_token, &t.lp_to), r.liquidity);
        for asset in [&t.token, &t.quote, &r.lp_token] {
            assert_eq!(t.balance(asset, &t.exec), 0);
        }
        assert_eq!(t.exec().float(), FLOAT - POOL_PAYMENT);
    }
}

#[test]
fn every_fee_tier_graduates_at_the_index_the_router_returns() {
    let t = setup();
    let a = GraduateArgs { token_amount: TOKEN_AMOUNT / 4, quote_amount: QUOTE_AMOUNT / 4, ..t.args(0) };
    for (n, fee_fraction) in AQUARIUS_FEE_TIERS.into_iter().enumerate() {
        let r = t.graduated(&GraduateArgs { params: VenueParams { fee_fraction }, ..a.clone() });
        let pools = t.router().get_pools(&t.tokens());
        assert_eq!(pools.len(), n as u32 + 1);
        assert_eq!(pools.get(standard_pool_index(&t.e, fee_fraction)), Some(r.pool.clone()));
        assert_eq!(pool::Client::new(&t.e, &r.pool).get_fee_fraction(), fee_fraction);
    }
    assert_eq!(t.exec().float(), FLOAT - 3 * POOL_PAYMENT);
}

#[test]
fn an_existing_empty_pool_is_reused_without_payment() {
    let t = setup();
    let someone = Address::generate(&t.e);
    let (_, existing) = t.as_anyone(|| {
        StellarAssetClient::new(&t.e, &t.aqua).mint(&someone, &POOL_PAYMENT);
        t.router().init_standard_pool(&someone, &t.tokens(), &30)
    });

    let r = t.graduated(&t.args(30));

    assert_eq!(r.pool, existing);
    assert_eq!(t.exec().float(), FLOAT);
    assert_eq!(t.balance(&t.aqua, &t.pay_to), POOL_PAYMENT);
}

#[test]
fn a_pool_that_already_has_shares_fails_pool_not_empty() {
    let t = setup();
    // An unlocked asset in place of the launch token, so a third party can seed the pool first.
    let token = t.asset(&t.source, TOKEN_AMOUNT);
    let someone = Address::generate(&t.e);
    let tokens = sorted_pair(&t.e, &token, &t.quote);
    t.as_anyone(|| {
        StellarAssetClient::new(&t.e, &t.aqua).mint(&someone, &POOL_PAYMENT);
        StellarAssetClient::new(&t.e, &token).mint(&someone, &ONE);
        StellarAssetClient::new(&t.e, &t.quote).mint(&someone, &ONE);
        let (index, _) = t.router().init_standard_pool(&someone, &tokens, &30);
        t.router().deposit(&someone, &tokens, &index, &vec![&t.e, ONE as u128, ONE as u128], &0);
    });

    let a = GraduateArgs { token: token.clone(), ..t.args(30) };
    assert_eq!(t.graduate(&a), failed(10_406));
    assert_eq!(t.balance(&token, &t.source), TOKEN_AMOUNT);
    assert_eq!(t.exec().float(), FLOAT);
}

#[test]
fn a_payment_above_max_pool_payment_fails_payment_too_high() {
    let t = setup();
    let too_high = (MAX_POOL_PAYMENT + 1) as u128;
    t.as_anyone(|| {
        t.admin_router().configure_init_pool_payment(&t.admin, &t.aqua, &too_high, &too_high, &too_high, &t.pay_to)
    });
    assert_eq!(t.exec().pool_payment(), (t.aqua.clone(), MAX_POOL_PAYMENT + 1));

    assert_eq!(t.graduate(&t.args(30)), failed(10_405));
    assert!(t.router().get_pools(&t.tokens()).is_empty());
    assert_eq!(t.exec().float(), FLOAT);

    // At the cap it pays.
    let at_cap = MAX_POOL_PAYMENT as u128;
    t.as_anyone(|| {
        t.admin_router().configure_init_pool_payment(&t.admin, &t.aqua, &at_cap, &at_cap, &at_cap, &t.pay_to)
    });
    t.graduated(&t.args(30));
    assert_eq!(t.exec().float(), FLOAT - MAX_POOL_PAYMENT);
}

#[test]
fn a_short_float_fails_payment_unavailable_and_everything_rolls_back() {
    let t = setup_with(POOL_PAYMENT - 1, true);
    let source_quote = t.balance(&t.quote, &t.source);

    // A recoverable error through try_: the source records it and carries on.
    assert_eq!(t.graduate(&t.args(30)), failed(10_404));
    assert_eq!(t.balance(&t.token, &t.source), SUPPLY);
    assert_eq!(t.balance(&t.quote, &t.source), source_quote);
    assert_eq!(t.exec().float(), POOL_PAYMENT - 1);
    assert!(t.router().get_pools(&t.tokens()).is_empty());
    assert!(LockedTokenClient::new(&t.e, &t.token).moves().is_empty());

    // Topped up by anyone, the next attempt graduates.
    t.as_anyone(|| StellarAssetClient::new(&t.e, &t.aqua).mint(&t.exec, &1));
    t.graduated(&t.args(30));
    assert_eq!(t.exec().float(), 0);
}

#[test]
fn a_failure_after_the_pool_and_the_deposit_rolls_all_of_it_back() {
    let t = setup();
    let source_quote = t.balance(&t.quote, &t.source);
    // More shares than √(token·quote) can't be minted: LiquidityTooLow comes after the pool payment, the pool's
    // creation, both pulls and the deposit.
    let shares = (TOKEN_AMOUNT as u128 * QUOTE_AMOUNT as u128).isqrt() as i128;
    let a = GraduateArgs { min_liquidity: shares + 1, ..t.args(30) };

    assert_eq!(t.graduate(&a), failed(10_407));
    assert_eq!(t.balance(&t.token, &t.source), SUPPLY);
    assert_eq!(t.balance(&t.quote, &t.source), source_quote);
    assert_eq!(t.exec().float(), FLOAT);
    assert_eq!(t.balance(&t.aqua, &t.pay_to), 0);
    assert!(t.router().get_pools(&t.tokens()).is_empty());
    assert!(LockedTokenClient::new(&t.e, &t.token).moves().is_empty());

    let r = t.graduated(&GraduateArgs { min_liquidity: shares, ..a });
    assert_eq!(r.liquidity, shares);
}

#[test]
fn a_payment_in_another_asset_fails_payment_unavailable() {
    let t = setup();
    let fee = POOL_PAYMENT as u128;
    t.as_anyone(|| t.admin_router().configure_init_pool_payment(&t.admin, &t.quote, &fee, &fee, &fee, &t.pay_to));
    assert_eq!(t.graduate(&t.args(30)), failed(10_404));
    assert_eq!(t.exec().float(), FLOAT);
}

#[test]
fn a_router_that_charges_nothing_creates_the_pool_without_a_payment() {
    let t = setup_with(0, true);
    t.as_anyone(|| t.admin_router().configure_init_pool_payment(&t.admin, &t.aqua, &0, &0, &0, &t.pay_to));
    let r = t.graduated(&t.args(30));
    assert_eq!(t.router().get_pools(&t.tokens()).get(standard_pool_index(&t.e, 30)), Some(r.pool));
    assert_eq!(t.balance(&t.aqua, &t.pay_to), 0);
}

#[test]
fn a_caller_outside_callers_fails_not_caller_and_the_float_is_unchanged() {
    // The drain probe of review B2: an attacker asks for pools of junk pairs.
    let t = setup();
    let attacker = t.e.register(Source, ());
    for _ in 0..3 {
        let junk = t.asset(&attacker, TOKEN_AMOUNT);
        let other = t.asset(&attacker, QUOTE_AMOUNT);
        let a = GraduateArgs { source: attacker.clone(), token: junk.clone(), quote: other.clone(), ..t.args(30) };
        assert_eq!(SourceClient::new(&t.e, &attacker).graduate(&t.exec, &a), failed(10_401));
        assert!(t.router().get_pools(&sorted_pair(&t.e, &junk, &other)).is_empty());
        assert_eq!(t.balance(&junk, &attacker), TOKEN_AMOUNT);
    }
    assert_eq!(t.exec().float(), FLOAT);
    assert_eq!(t.balance(&t.aqua, &t.pay_to), 0);
}

#[test]
fn naming_a_caller_as_source_without_its_auth_fails() {
    let t = setup();
    let attacker = t.e.register(Source, ());
    let source_quote = t.balance(&t.quote, &t.source);
    let outcome = SourceClient::new(&t.e, &attacker).graduate(&t.exec, &t.args(30));
    let Outcome::Failed(f) = outcome else { panic!("graduated without the source's auth") };
    assert_eq!(f.origin, ORIGIN_HOST);
    assert_eq!(t.balance(&t.token, &t.source), SUPPLY);
    assert_eq!(t.balance(&t.quote, &t.source), source_quote);
    assert_eq!(t.exec().float(), FLOAT);
}

#[test]
fn bad_arguments_fail_before_anything_moves() {
    let t = setup();
    let a = t.args(30);
    for (bad, code) in [
        (GraduateArgs { token_amount: 0, ..a.clone() }, 10_402),
        (GraduateArgs { quote_amount: -1, ..a.clone() }, 10_402),
        (GraduateArgs { min_liquidity: -1, ..a.clone() }, 10_402),
        (GraduateArgs { quote: a.token.clone(), ..a.clone() }, 10_402),
        (GraduateArgs { params: VenueParams { fee_fraction: 20 }, ..a.clone() }, 10_403),
        (GraduateArgs { params: VenueParams { fee_fraction: 0 }, ..a.clone() }, 10_403),
    ] {
        assert_eq!(t.graduate(&bad), failed(code));
    }
    assert!(LockedTokenClient::new(&t.e, &t.token).moves().is_empty());
    assert_eq!(t.exec().float(), FLOAT);
}

// ------------------------------------------------------------------------------------------------ leftovers

#[contracttype]
#[derive(Clone)]
enum FakeKey {
    Pool,
    Share,
    Tokens,
}

/// A router with one standard 0.3% pool whose deposit takes the desired amounts and then refunds part of each (a
/// real empty Aquarius pool never does): it drives the executor's leftover path with unlocked assets.
#[contract]
pub struct FakeRouter;

#[contractimpl]
impl FakeRouter {
    pub fn __constructor(e: Env, pool: Address) {
        e.storage().instance().set(&FakeKey::Pool, &pool);
    }

    pub fn get_pools(e: Env, _tokens: Vec<Address>) -> Map<BytesN<32>, Address> {
        let pool: Address = e.storage().instance().get(&FakeKey::Pool).unwrap();
        Map::from_array(&e, [(standard_pool_index(&e, 30), pool)])
    }

    pub fn deposit(
        e: Env,
        user: Address,
        tokens: Vec<Address>,
        _pool_index: BytesN<32>,
        desired_amounts: Vec<u128>,
        min_shares: u128,
    ) -> (Vec<u128>, u128) {
        let pool: Address = e.storage().instance().get(&FakeKey::Pool).unwrap();
        let pool = FakePoolClient::new(&e, &pool);
        pool.set_tokens(&tokens);
        pool.deposit(&user, &desired_amounts, &min_shares)
    }
}

#[contract]
pub struct FakePool;

#[contractimpl]
impl FakePool {
    pub fn set_share(e: Env, share: Address) {
        e.storage().instance().set(&FakeKey::Share, &share);
    }

    pub fn share_id(e: Env) -> Address {
        e.storage().instance().get(&FakeKey::Share).unwrap()
    }

    pub fn set_tokens(e: Env, tokens: Vec<Address>) {
        e.storage().instance().set(&FakeKey::Tokens, &tokens);
    }

    pub fn get_total_shares(_e: Env) -> u128 {
        0
    }

    /// Aquarius's `pool.deposit` signature, so the executor's pre-authorized node matches.
    pub fn deposit(e: Env, user: Address, desired: Vec<u128>, _min_shares: u128) -> (Vec<u128>, u128) {
        user.require_auth();
        let this = e.current_contract_address();
        let tokens: Vec<Address> = e.storage().instance().get(&FakeKey::Tokens).unwrap();
        let mut used = Vec::new(&e);
        for (i, refund) in [(0, 5u128), (1, 7u128)] {
            let token = TokenClient::new(&e, &tokens.get_unchecked(i));
            let amount = desired.get_unchecked(i);
            token.transfer(&user, &this, &(amount as i128));
            token.transfer(&this, &user, &(refund as i128));
            used.push_back(amount - refund);
        }
        StellarAssetClient::new(&e, &Self::share_id(e.clone())).mint(&user, &1_000);
        (used, 1_000)
    }
}

#[test]
fn leftovers_go_back_to_the_source() {
    let t = setup();
    let fake_pool = t.e.register(FakePool, ());
    let share = t.e.register_stellar_asset_contract_v2(fake_pool.clone()).address();
    let fake_router = t.e.register(FakeRouter, (fake_pool.clone(),));
    t.as_anyone(|| FakePoolClient::new(&t.e, &fake_pool).set_share(&share));
    let callers = vec![&t.e, t.source.clone()];
    let exec = t.e.register(ExecAquarius, (fake_router, t.aqua.clone(), MAX_POOL_PAYMENT, callers));
    let token = t.asset(&t.source, TOKEN_AMOUNT);
    let a = GraduateArgs { token: token.clone(), ..t.args(30) };
    let source_quote = t.balance(&t.quote, &t.source);

    let Outcome::Done(r) = SourceClient::new(&t.e, &t.source).graduate(&exec, &a) else { panic!("failed") };

    let (token_left, quote_left) = if token < t.quote { (5, 7) } else { (7, 5) };
    assert_eq!((r.token_used, r.quote_used), (TOKEN_AMOUNT - token_left, QUOTE_AMOUNT - quote_left));
    assert_eq!(t.balance(&token, &t.source), token_left);
    assert_eq!(t.balance(&t.quote, &t.source), source_quote - QUOTE_AMOUNT + quote_left);
    assert_eq!(t.balance(&share, &t.lp_to), 1_000);
    for asset in [&token, &t.quote, &share] {
        assert_eq!(t.balance(asset, &exec), 0);
    }

    // The same refund of a locked launch token is refused (pool → executor), and the graduation fails recoverably.
    let locked = t.e.register(LockedToken, (t.source.clone(), vec![&t.e, exec.clone()], SUPPLY));
    let a = GraduateArgs { token: locked.clone(), ..a };
    let outcome = SourceClient::new(&t.e, &t.source).graduate(&exec, &a);
    assert_eq!(outcome, Outcome::Failed(GradFailure { origin: dyor_common::TAG_LAUNCH_TOKEN_V2, code: 10_201 }));
    assert_eq!(t.balance(&locked, &t.source), SUPPLY);
    assert!(LockedTokenClient::new(&t.e, &locked).moves().is_empty());
}

// ------------------------------------------------------------------------------------------------ the gate (§7.2)

/// Check 1: the pool-creation payment getter, and the exact auth trees of `init_standard_pool` and `deposit` for a
/// user calling the router (the executor pre-authorizes the nodes below its own call).
#[test]
fn gate_1_payment_getter_and_the_auth_trees_of_init_standard_pool_and_deposit() {
    let t = setup();
    assert_eq!(t.router().get_init_pool_payment_token(), t.aqua);
    assert_eq!(t.router().get_init_pool_payment_address(), t.pay_to);
    assert_eq!(t.router().get_standard_pool_payment_amount(), POOL_PAYMENT as u128);
    assert_eq!(t.exec().pool_payment(), (t.aqua.clone(), POOL_PAYMENT));

    let e = &t.e;
    let user = Address::generate(e);
    let (a, b) = (t.asset(&user, 10 * ONE), t.asset(&user, 20 * ONE));
    let tokens = sorted_pair(e, &a, &b);
    e.mock_all_auths();
    StellarAssetClient::new(e, &t.aqua).mint(&user, &POOL_PAYMENT);

    let (index, pool) = t.router().init_standard_pool(&user, &tokens, &30);
    assert_eq!(index, standard_pool_index(e, 30));
    assert_eq!(
        e.auths(),
        [(
            user.clone(),
            node(
                contract_fn(&t.router, "init_standard_pool", (user.clone(), tokens.clone(), 30u32).into_val(e)),
                std::vec![node(
                    contract_fn(&t.aqua, "transfer", (user.clone(), t.pay_to.clone(), POOL_PAYMENT).into_val(e)),
                    std::vec![],
                )],
            ),
        )]
    );

    // Asked again, the router returns the same pool and takes no payment.
    assert_eq!(t.router().init_standard_pool(&user, &tokens, &30), (index.clone(), pool.clone()));
    assert_eq!(
        e.auths(),
        [(
            user.clone(),
            node(
                contract_fn(&t.router, "init_standard_pool", (user.clone(), tokens.clone(), 30u32).into_val(e)),
                std::vec![]
            ),
        )]
    );
    assert_eq!(t.balance(&t.aqua, &t.pay_to), POOL_PAYMENT);

    let desired = vec![e, 10 * ONE as u128, 20 * ONE as u128];
    let (amounts, shares) = t.router().deposit(&user, &tokens, &index, &desired, &0);
    assert_eq!(amounts, desired);
    assert_eq!(
        e.auths(),
        [(
            user.clone(),
            node(
                contract_fn(
                    &t.router,
                    "deposit",
                    (user.clone(), tokens.clone(), index, desired.clone(), 0u128).into_val(e)
                ),
                std::vec![node(
                    contract_fn(&pool, "deposit", (user.clone(), desired.clone(), 0u128).into_val(e)),
                    std::vec![
                        node(
                            contract_fn(
                                &tokens.get_unchecked(0),
                                "transfer",
                                (user.clone(), pool.clone(), 10 * ONE).into_val(e)
                            ),
                            std::vec![]
                        ),
                        node(
                            contract_fn(
                                &tokens.get_unchecked(1),
                                "transfer",
                                (user.clone(), pool.clone(), 20 * ONE).into_val(e)
                            ),
                            std::vec![]
                        ),
                    ],
                )],
            ),
        )]
    );
    assert_eq!(shares, ((10 * ONE * 20 * ONE) as u128).isqrt());
    e.set_auths(&[]);

    // The executor's own entries are exactly these nodes: graduation under enforced auth proves it.
    t.graduated(&t.args(30));
}

/// Check 2: during the deposit the launch token moves only executor → pool. The lock-mimicking token refuses every
/// other path, and its log shows each transfer.
#[test]
fn gate_2_the_launch_token_moves_only_from_the_executor_to_the_pool() {
    for token_first in [true, false] {
        let t = setup_with(FLOAT, token_first);
        let r = t.graduated(&t.args(30));
        let token = LockedTokenClient::new(&t.e, &t.token);
        assert_eq!(
            token.moves(),
            vec![
                &t.e,
                (t.source.clone(), t.exec.clone(), TOKEN_AMOUNT),
                (t.exec.clone(), r.pool.clone(), TOKEN_AMOUNT),
            ]
        );
        // The path the gate excludes would have been refused: pool → executor.
        t.e.mock_all_auths();
        assert!(token.try_transfer(&r.pool, MuxedAddress::from(t.exec.clone()), &1).is_err());
        assert!(token.try_transfer(&t.lp_to, MuxedAddress::from(r.pool.clone()), &0).is_err());
        t.e.set_auths(&[]);
    }
}

/// Check 3: the address that holds the reserves is the pool the executor returns (the one launch-token-v2 excludes).
#[test]
fn gate_3_the_reserves_sit_at_the_returned_pool() {
    let t = setup();
    let r = t.graduated(&t.args(30));
    assert_eq!(t.balance(&t.token, &r.pool), TOKEN_AMOUNT);
    assert_eq!(t.balance(&t.quote, &r.pool), QUOTE_AMOUNT);
    let reserves = AquariusPoolClient::new(&t.e, &r.pool).get_reserves();
    let expected = if t.token < t.quote { [TOKEN_AMOUNT, QUOTE_AMOUNT] } else { [QUOTE_AMOUNT, TOKEN_AMOUNT] };
    assert_eq!(reserves, vec![&t.e, expected[0] as u128, expected[1] as u128]);
    assert_eq!(t.router().get_pools(&t.tokens()).get(standard_pool_index(&t.e, 30)), Some(r.pool.clone()));
    for holder in [&t.exec, &r.lp_token, &t.router] {
        assert_eq!(t.balance(&t.token, holder), 0);
        assert_eq!(t.balance(&t.quote, holder), 0);
    }
}

/// Check 4: the router's pool lookup for a token pair, the pool's token list and `share_id` (launch-token-v2's
/// `exclude_pool`, F2).
#[test]
fn gate_4_pool_lookup_token_list_and_share_id() {
    let t = setup();
    let r = t.graduated(&t.args(30));
    let tokens = t.tokens();
    let pools = t.router().get_pools(&tokens);
    assert_eq!(pools, Map::from_array(&t.e, [(standard_pool_index(&t.e, 30), r.pool.clone())]));

    let pool = AquariusPoolClient::new(&t.e, &r.pool);
    assert_eq!(pool.get_tokens(), tokens);
    let share = pool.share_id();
    assert_eq!(share, r.lp_token);
    assert!(matches!(share.executable(), Some(Executable::Wasm(_))));
    assert!(matches!(r.pool.executable(), Some(Executable::Wasm(_))));
    assert!(![&r.pool, &t.token, &t.quote].contains(&&share));
    assert_eq!(pool.get_total_shares(), r.liquidity as u128);
    assert_eq!(t.router().get_total_shares(&tokens, &standard_pool_index(&t.e, 30)), r.liquidity as u128);

    // A pair the router has never seen has no pools; an unsorted pair is refused (TokensNotSorted).
    let other = t.asset(&t.source, ONE);
    assert!(t.router().get_pools(&sorted_pair(&t.e, &t.token, &other)).is_empty());
    let reversed = vec![&t.e, tokens.get_unchecked(1), tokens.get_unchecked(0)];
    let err = t.router().try_get_pools(&reversed).unwrap_err().unwrap();
    assert_eq!(err, soroban_sdk::Error::from_contract_error(2002));
}

/// Check 5: withdraw by share amount (lp-locker's harvest), by a contract holding the shares, after the launch token
/// unlocked at graduation.
#[test]
fn gate_5_withdraw_by_share_amount() {
    let t = setup();
    let r = t.graduated(&t.args(30));
    let holder = HolderClient::new(&t.e, &t.lp_to);
    let index = standard_pool_index(&t.e, 30);
    let take = r.liquidity as u128 / 200; // 0.5%, the most one harvest round takes

    // While the launch token is locked the pool can't pay it out.
    assert!(holder.try_withdraw(&t.router, &t.tokens(), &index, &take).is_err());

    t.as_anyone(|| LockedTokenClient::new(&t.e, &t.token).unlock());
    let reserves = AquariusPoolClient::new(&t.e, &r.pool).get_reserves();
    let out = holder.withdraw(&t.router, &t.tokens(), &index, &take);
    let total = r.liquidity as u128;
    assert_eq!(out, vec![&t.e, reserves.get_unchecked(0) * take / total, reserves.get_unchecked(1) * take / total]);
    let (token_out, quote_out) = if t.token < t.quote {
        (out.get_unchecked(0), out.get_unchecked(1))
    } else {
        (out.get_unchecked(1), out.get_unchecked(0))
    };
    assert_eq!(t.balance(&t.token, &t.lp_to), token_out as i128);
    assert_eq!(t.balance(&t.quote, &t.lp_to), quote_out as i128);
    assert_eq!(t.balance(&r.lp_token, &t.lp_to), r.liquidity - take as i128);
    assert_eq!(AquariusPoolClient::new(&t.e, &r.pool).get_total_shares(), total - take);
}

/// The flags in dyor_common::aquarius record the gate: check 4 alone sets the first, all five the second.
#[test]
fn the_flags_record_that_every_check_passed() {
    assert_eq!([AQUARIUS_POOL_LOOKUP_OK, AQUARIUS_VENUE_OK], [true, true]);
}

// ------------------------------------------------------------------------------------------------ views and fixtures

#[test]
fn views_report_the_float_the_payment_and_the_cap() {
    let t = setup();
    assert_eq!(t.exec().float(), FLOAT);
    assert_eq!(t.exec().pool_payment(), (t.aqua.clone(), POOL_PAYMENT));
    assert_eq!(t.exec().max_pool_payment(), MAX_POOL_PAYMENT);
    assert_eq!(t.exec().error_tag(), TAG_EXEC_AQUARIUS);
    // F11: the testnet target is 50 × the payment, and the keeper alerts below 5 ×.
    assert_eq!(t.exec().float(), 50 * t.exec().pool_payment().1);
}

#[test]
#[should_panic(expected = "Error(Contract, #10402)")]
fn the_constructor_refuses_a_negative_cap() {
    let e = Env::default();
    let r = Address::generate(&e);
    e.register(ExecAquarius, (r.clone(), r, -1i128, Vec::<Address>::new(&e)));
}

#[test]
fn standard_pool_index_matches_the_testnet_router() {
    // get_pools(XLM, AQUA) on the testnet router, 2026-10-14 (fixtures.json).
    let e = Env::default();
    for (fee, index) in [
        (10, "b2e02fcfca6c96f8ad5cbd84e7784a777b36d9c96a2459402c4f458462aab7f0"),
        (30, "9ac7a9cde23ac2ada11105eeaa42e43c2ea8332ca0aa8f41f58d7160274d718e"),
        (100, "37b955f3708dae748cad465441fcad70b26ffe272385227a4a737234ae429bdf"),
    ] {
        assert_eq!(hex(&standard_pool_index(&e, fee).to_array()), index);
    }
}

#[test]
fn error_codes_are_10_401_to_10_407() {
    let codes = [
        Error::NotCaller,
        Error::InvalidAmounts,
        Error::UnsupportedFeeTier,
        Error::PaymentUnavailable,
        Error::PaymentTooHigh,
        Error::PoolNotEmpty,
        Error::LiquidityTooLow,
    ]
    .map(|c| c as u32);
    assert_eq!(codes, [10_401, 10_402, 10_403, 10_404, 10_405, 10_406, 10_407]);
}

/// The `contractspecv0` entries of a WASM module.
fn contract_spec(wasm: &[u8]) -> std::vec::Vec<ScSpecEntry> {
    fn leb128(b: &[u8], i: &mut usize) -> usize {
        let (mut value, mut shift) = (0, 0);
        loop {
            let byte = b[*i];
            *i += 1;
            value |= ((byte & 0x7f) as usize) << shift;
            if byte & 0x80 == 0 {
                return value;
            }
            shift += 7;
        }
    }
    let mut i = 8; // magic and version
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let size = leb128(wasm, &mut i);
        let end = i + size;
        if id == 0 {
            let mut j = i;
            let name_len = leb128(wasm, &mut j);
            if &wasm[j..j + name_len] == b"contractspecv0" {
                let mut data = Limited::new(&wasm[j + name_len..end], Limits::none());
                return ScSpecEntry::read_xdr_iter(&mut data).collect::<Result<_, _>>().unwrap();
            }
        }
        i = end;
    }
    panic!("no contract spec");
}

#[test]
fn no_aquarius_fixture_error_code_falls_in_the_dyorhq_namespace() {
    for (name, wasm) in [("router", router::WASM), ("pool", pool::WASM), ("token_share", share::WASM)] {
        let codes: std::vec::Vec<u32> = contract_spec(wasm)
            .into_iter()
            .flat_map(|entry| match entry {
                ScSpecEntry::UdtErrorEnumV0(en) => en.cases.iter().map(|c| c.value).collect(),
                _ => std::vec![],
            })
            .collect();
        assert!(!codes.is_empty(), "{name} declares error codes");
        for code in codes {
            assert!(!(ERR_MIN..=ERR_MAX).contains(&code), "{name} error {code} inside 10_100–11_099");
        }
    }
}

#[test]
fn fixtures_json_records_each_fixture_by_id_and_sha256() {
    let e = Env::default();
    let manifest = include_str!("../../testdata/fixtures.json");
    for (file, id, wasm) in [
        ("aquarius_router.wasm", ROUTER_ID, router::WASM),
        ("aquarius_pool.wasm", POOL_ID, pool::WASM),
        ("aquarius_token_share.wasm", SHARE_ID, share::WASM),
    ] {
        let start = manifest.find(&std::format!("\"file\": \"{file}\"")).expect(file);
        let entry = &manifest[start..start + manifest[start..].find('}').unwrap()];
        let sha256 = hex(&e.crypto().sha256(&Bytes::from_slice(&e, wasm)).to_array());
        assert!(entry.contains(&std::format!("\"contract_id\": \"{id}\"")), "{file}: contract id");
        assert!(entry.contains(&std::format!("\"sha256\": \"{sha256}\"")), "{file}: sha256");
        assert!(entry.contains("\"network\": \"testnet\""), "{file}: network");
    }
}
