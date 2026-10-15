//! moments-graduator (§12) called the way moments-v2 calls it (§9.3): from a stand-in that pre-authorizes exactly the
//! reserve pull with `authorize_as_current_contract`, goes through `try_graduate` and records a failure as `grad_fail`
//! does; on success it repeats moments-v2's result checks and registers the LP with the locker.
//!
//! Everything else is real: the Soroswap factory, pair and router fixtures (contracts/testdata) and the shaken WASMs of
//! moment-coin, exec-soroswap, qa-exec-fail and lp-locker that build.sh writes to contracts/dist (run it first, as the
//! verify command does). `TestExecutor` is an executor that lies the ways a wrong or hostile executor could; every lie
//! must end in `GraduationInvalid` with no coin deployed and every balance unchanged (F15, V9).
//!
//! Auth is enforced in every graduation: `mock_all_auths` is on only while a test funds accounts or plays a third
//! party (`as_anyone`).
extern crate std;

use super::*;
use dyor_common::{
    err_code, grad_failure, tag_of, GradFailure, GraduateResult, GraduatorClient, LockerClient, PositionRef,
    SoroswapPairClient, VenueKind, ORIGIN_FOREIGN, ORIGIN_HOST, TAG_EXEC_SOROSWAP, TAG_QA_EXEC_FAIL,
};
use soroban_sdk::testutils::{Address as _, EnvTestConfig, Events as _};
use soroban_sdk::token::StellarAssetClient;
use soroban_sdk::xdr::{Limits, ReadXdr, ScErrorCode, ScSpecEntry, ScSpecTypeBytesN, ScSpecTypeDef};
use soroban_sdk::{panic_with_error, String};

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
/// The shaken WASMs we deploy (`./build.sh` writes dist/ before the tests run).
mod moment_coin {
    soroban_sdk::contractimport!(file = "../dist/dyor_moment_coin.wasm");
}
mod exec_soroswap {
    soroban_sdk::contractimport!(file = "../dist/dyor_exec_soroswap.wasm");
}
mod qa_exec_fail {
    soroban_sdk::contractimport!(file = "../dist/dyor_qa_exec_fail.wasm");
}
// The locker's `register` takes 9 arguments, and the generated client mirrors them.
#[allow(clippy::too_many_arguments)]
mod lp_locker {
    soroban_sdk::contractimport!(file = "../dist/dyor_lp_locker.wasm");
}

const ONE: i128 = 10_000_000; // 7 decimals
/// A Moment at the testnet threshold T = 10 USDC (§14.2): at graduation the reserve is exactly T (I-M1), and the pool
/// gets about 38.57% of S (§14.5).
const RESERVE: i128 = 10 * ONE;
const POOL_COINS: i128 = 38_571_428 * ONE;
/// moments-v2's compile-time harvest rate (§9.1).
const MOMENT_HARVEST_BPS: u32 = 6_667;
const NAME: &str = "Sunset at Labadi";
const SYMBOL: &str = "LABADI";

// ------------------------------------------------------------------------------------------------ moments-v2

#[contracttype]
#[derive(Clone)]
enum MomentsKey {
    Graduator,
    Factory,
    Locker,
    /// The failure recorded for a Moment (moments-v2's `grad_fail`).
    Failure(Address),
}

/// What one attempt came to, as moments-v2 records it. (A contract type can't box a variant's fields.)
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum Attempt {
    Graduated(MomentGradResult),
    Failed(GradFailure),
}

/// moments-v2's `GraduationInvalid` (§9.4, local code 31): its own re-check of a result failed.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum MomentsError {
    GraduationInvalid = 10_731,
}

/// Stands in for moments-v2, the graduator's only caller.
#[contract]
pub struct TestMoments;

#[contractimpl]
impl TestMoments {
    pub fn __constructor(e: Env, graduator: Address, factory: Address, locker: Address) {
        let s = e.storage().instance();
        s.set(&MomentsKey::Graduator, &graduator);
        s.set(&MomentsKey::Factory, &factory);
        s.set(&MomentsKey::Locker, &locker);
    }

    /// moments-v2's `attempt(nft)` (§9.3) with the given arguments: pre-authorizes exactly
    /// `usdc.transfer(this, graduator, reserve)` and calls the graduator through `try_`. On success it repeats the
    /// result checks (a failure there aborts, as moments-v2 panics) and registers the LP with the locker as the
    /// Moment's position; a recoverable failure is recorded instead.
    pub fn attempt(e: Env, a: MomentGradArgs) -> Attempt {
        let this = e.current_contract_address();
        let graduator: Address = e.storage().instance().get(&MomentsKey::Graduator).unwrap();
        let usdc = TokenClient::new(&e, &a.usdc);
        let u0 = usdc.balance(&this);
        e.authorize_as_current_contract(vec![&e, transfer_entry(&e, &a.usdc, &this, &graduator, a.reserve)]);
        match GraduatorClient::new(&e, &graduator).try_graduate(&a) {
            Ok(Ok(r)) => {
                recheck(&e, &a, &r, u0 - usdc.balance(&this));
                let locker: Address = e.storage().instance().get(&MomentsKey::Locker).unwrap();
                LockerClient::new(&e, &locker).register(
                    &this,
                    &r.pool,
                    &VenueKind::Soroswap,
                    &r.lp_token,
                    &r.liquidity,
                    &r.coin,
                    &a.usdc,
                    &PositionRef::Moment(a.nft.clone()),
                    &MOMENT_HARVEST_BPS,
                );
                Attempt::Graduated(r)
            }
            Ok(Err(_)) => panic!("the graduator's result doesn't decode"),
            Err(err) => {
                let f = grad_failure(err);
                e.storage().instance().set(&MomentsKey::Failure(a.nft), &f);
                Attempt::Failed(f)
            }
        }
    }

    pub fn failure(e: Env, nft: Address) -> Option<GradFailure> {
        e.storage().instance().get(&MomentsKey::Failure(nft))
    }
}

/// moments-v2's own checks of a result (§9.3), defence in depth: they fail only if the graduator is wrong.
fn recheck(e: &Env, a: &MomentGradArgs, r: &MomentGradResult, usdc_spent: i128) {
    let factory: Address = e.storage().instance().get(&MomentsKey::Factory).unwrap();
    let locker: Address = e.storage().instance().get(&MomentsKey::Locker).unwrap();
    let ok = r.coin == a.expected_coin
        && r.usdc_used + r.usdc_returned == a.reserve
        && within_dust(r.usdc_used, a.reserve)
        && usdc_spent == r.usdc_used
        && within_dust(r.coin_used, a.pool_coins)
        && r.pool == SoroswapFactoryClient::new(e, &factory).get_pair(&r.coin, &a.usdc)
        && TokenClient::new(e, &r.lp_token).balance(&locker) >= r.liquidity;
    if !ok {
        panic_with_error!(e, MomentsError::GraduationInvalid);
    }
}

// ------------------------------------------------------------------------------------------------ a lying executor

#[contracttype]
#[derive(Clone)]
enum ExecKey {
    Factory,
    Lie,
}

/// How `TestExecutor` departs from what exec-soroswap does, and which check of §12 catches it.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Lie {
    /// Seeds the pair with both amounts and reports exactly that.
    Honest,
    /// Seeds all but these coins and USDC, returns them to the source and reports what it used: an honest executor
    /// leaving dust.
    LeavesDust(i128, i128),
    /// Reports one coin unit more than it was sent (the coin side's upper bound).
    CoinsOverReported,
    /// Uses one unit less than `pool_coins − 1 bp`, returns the rest and says so (the coin side's lower bound).
    CoinsBelowDust,
    /// Seeds every coin and reports one unit fewer as used (the coin balance delta).
    CoinsUnderReported,
    /// Seeds all but these coins, returns them and reports every coin as used (the coin balance delta).
    ReturnsCoins(i128),
    /// Seeds all but these coins, keeps them and reports every coin as used (the pool's coin balance, and the
    /// liquidity bound once the shortfall is large).
    KeepsCoins(i128),
    /// The USDC side's versions of the four lies above.
    UsdcOverReported,
    UsdcBelowDust,
    UsdcUnderReported,
    KeepsUsdc(i128),
    /// Reports one unit less than `min_liquidity` (the liquidity bound).
    LiquidityBelowMinimum,
    /// Reports one unit more liquidity than it minted (the locker's LP balance).
    LiquidityOverstated,
    /// Mints the LP to itself instead of the locker (the locker's LP balance).
    KeepsLp,
    /// Reports this pair as the pool and the LP token (the factory's pair).
    WrongPool(Address),
    /// Reports this token as the LP token (the pool is its own LP token).
    WrongLpToken(Address),
    /// After seeding, pays one unit of its own USDC to this address; paid to moments, its balance no longer falls by
    /// exactly what was used (moments' balance check).
    PaysTo(Address),
    /// Seeds everything, sends the LP to the locker and then fails with a foreign error.
    FailAfterSeeding,
}

/// `Lie::FailAfterSeeding`'s error: a code outside every DyorHQ namespace, so it is recorded with origin 0.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum ExecError {
    Forced = 777,
}

/// A Soroswap executor in the graduator's seat, exec-soroswap's `graduate` but for its lie.
#[contract]
pub struct TestExecutor;

#[contractimpl]
impl TestExecutor {
    pub fn __constructor(e: Env, factory: Address, lie: Lie) {
        e.storage().instance().set(&ExecKey::Factory, &factory);
        e.storage().instance().set(&ExecKey::Lie, &lie);
    }

    pub fn set_lie(e: Env, lie: Lie) {
        e.storage().instance().set(&ExecKey::Lie, &lie);
    }

    pub fn graduate(e: Env, a: GraduateArgs) -> GraduateResult {
        a.source.require_auth();
        let lie: Lie = e.storage().instance().get(&ExecKey::Lie).unwrap();
        let this = e.current_contract_address();
        let coin = TokenClient::new(&e, &a.token);
        let usdc = TokenClient::new(&e, &a.quote);
        coin.transfer(&a.source, &this, &a.token_amount);
        usdc.transfer(&a.source, &this, &a.quote_amount);

        // What stays out of the pair, and whether it goes back to the source.
        let dust = |amount: i128| mul_div(amount, GRAD_DUST_BPS as i128, BPS as i128);
        let (coins_out, usdc_out, give_back) = match &lie {
            Lie::LeavesDust(coins, dollars) => (*coins, *dollars, true),
            Lie::CoinsBelowDust => (dust(a.token_amount) + 1, 0, true),
            Lie::UsdcBelowDust => (0, dust(a.quote_amount) + 1, true),
            Lie::ReturnsCoins(coins) => (*coins, 0, true),
            Lie::KeepsCoins(coins) => (*coins, 0, false),
            Lie::KeepsUsdc(dollars) => (0, *dollars, false),
            _ => (0, 0, false),
        };
        let factory: Address = e.storage().instance().get(&ExecKey::Factory).unwrap();
        let factory = SoroswapFactoryClient::new(&e, &factory);
        let pool = if factory.pair_exists(&a.token, &a.quote) {
            factory.get_pair(&a.token, &a.quote)
        } else {
            factory.create_pair(&a.token, &a.quote)
        };
        coin.transfer(&this, &pool, &(a.token_amount - coins_out));
        usdc.transfer(&this, &pool, &(a.quote_amount - usdc_out));
        let lp_to = if lie == Lie::KeepsLp { this.clone() } else { a.lp_to.clone() };
        let minted = SoroswapPairClient::new(&e, &pool).deposit(&lp_to);
        if give_back && coins_out > 0 {
            coin.transfer(&this, &a.source, &coins_out);
        }
        if give_back && usdc_out > 0 {
            usdc.transfer(&this, &a.source, &usdc_out);
        }

        let mut r = GraduateResult {
            pool: pool.clone(),
            lp_token: pool,
            liquidity: minted,
            token_used: a.token_amount,
            quote_used: a.quote_amount,
        };
        if give_back {
            r.token_used -= coins_out;
            r.quote_used -= usdc_out;
        }
        match lie {
            Lie::ReturnsCoins(coins) => r.token_used += coins,
            Lie::CoinsOverReported => r.token_used += 1,
            Lie::CoinsUnderReported => r.token_used -= 1,
            Lie::UsdcOverReported => r.quote_used += 1,
            Lie::UsdcUnderReported => r.quote_used -= 1,
            Lie::LiquidityBelowMinimum => r.liquidity = a.min_liquidity - 1,
            Lie::LiquidityOverstated => r.liquidity += 1,
            Lie::WrongPool(pool) => {
                r.pool = pool.clone();
                r.lp_token = pool;
            }
            Lie::WrongLpToken(token) => r.lp_token = token,
            Lie::PaysTo(to) => usdc.transfer(&this, &to, &1),
            Lie::FailAfterSeeding => panic_with_error!(&e, ExecError::Forced),
            _ => {}
        }
        r
    }
}

// ------------------------------------------------------------------------------------------------ setup

/// The executor the graduator is built with.
enum Venue {
    /// exec-soroswap, with the graduator among its callers.
    Soroswap,
    /// exec-soroswap for another caller only.
    SoroswapForOthers,
    /// qa-exec-fail with this default mode: testnet-qa's failing Moments stack (F5).
    QaFail(qa_exec_fail::Mode),
    /// `TestExecutor`, honest until a test sets its lie.
    Lying,
}

struct T {
    e: Env,
    factory: Address,
    router: Address,
    usdc: Address,
    coin_wasm_hash: BytesN<32>,
    exec: Address,
    locker: Address,
    /// The moments-v2 stand-in the graduator is built for.
    moments: Address,
    grad: Address,
}

fn setup(venue: Venue) -> T {
    setup_with(venue, None)
}

/// Registers the graduator's release WASM when one is given, else the native contract.
fn setup_with(venue: Venue, graduator_wasm: Option<&[u8]>) -> T {
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    e.cost_estimate().budget().reset_unlimited();
    e.mock_all_auths();

    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(&e, &factory).initialize(&Address::generate(&e), &pair_hash);
    let router = e.register(soroswap_router::WASM, ());
    soroswap_router::Client::new(&e, &router).initialize(&factory);
    let usdc = e.register_stellar_asset_contract_v2(Address::generate(&e)).address();
    let coin_wasm_hash = e.deployer().upload_contract_wasm(moment_coin::WASM);

    // The ids the deploy script precomputes (§3.4), so the executor, the locker and the graduator can name each other.
    let (moments, grad) = (Address::generate(&e), Address::generate(&e));
    let exec = match venue {
        Venue::Soroswap => e.register(exec_soroswap::WASM, (factory.clone(), vec![&e, grad.clone()])),
        Venue::SoroswapForOthers => e.register(exec_soroswap::WASM, (factory.clone(), vec![&e, Address::generate(&e)])),
        Venue::QaFail(mode) => e.register(qa_exec_fail::WASM, (vec![&e, grad.clone()], Address::generate(&e), mode)),
        Venue::Lying => e.register(TestExecutor, (factory.clone(), Lie::Honest)),
    };
    let locker = e.register(lp_locker::WASM, (vec![&e, moments.clone()], factory.clone(), None::<Address>, 3_600u64));
    let args = (moments.clone(), coin_wasm_hash.clone(), exec.clone(), locker.clone(), factory.clone());
    match graduator_wasm {
        Some(wasm) => e.register_at(&grad, wasm, args),
        None => e.register_at(&grad, MomentsGraduator, args),
    };
    e.register_at(&moments, TestMoments, (grad.clone(), factory.clone(), locker.clone()));
    StellarAssetClient::new(&e, &usdc).mint(&moments, &(10_000_000 * ONE));
    e.set_auths(&[]);
    T { e, factory, router, usdc, coin_wasm_hash, exec, locker, moments, grad }
}

impl T {
    fn grad(&self) -> MomentsGraduatorClient<'_> {
        MomentsGraduatorClient::new(&self.e, &self.grad)
    }

    fn moments(&self) -> TestMomentsClient<'_> {
        TestMomentsClient::new(&self.e, &self.moments)
    }

    fn usdc(&self) -> TokenClient<'_> {
        TokenClient::new(&self.e, &self.usdc)
    }

    fn coin(&self, id: &Address) -> moment_coin::Client<'_> {
        moment_coin::Client::new(&self.e, id)
    }

    fn lying_exec(&self) -> TestExecutorClient<'_> {
        TestExecutorClient::new(&self.e, &self.exec)
    }

    /// What moments-v2 passes for the Moment whose NFT is `nft`.
    fn args(&self, nft: &Address, pool_coins: i128, reserve: i128) -> MomentGradArgs {
        MomentGradArgs {
            nft: nft.clone(),
            usdc: self.usdc.clone(),
            reserve,
            pool_coins,
            name: String::from_str(&self.e, NAME),
            symbol: String::from_str(&self.e, SYMBOL),
            expected_coin: self.grad().coin_address(nft),
        }
    }

    /// A new Moment at the testnet threshold.
    fn moment(&self) -> MomentGradArgs {
        self.args(&Address::generate(&self.e), POOL_COINS, RESERVE)
    }

    fn attempt(&self, a: &MomentGradArgs) -> Attempt {
        self.moments().attempt(a)
    }

    fn graduated(&self, a: &MomentGradArgs) -> MomentGradResult {
        match self.attempt(a) {
            Attempt::Graduated(r) => r,
            Attempt::Failed(f) => panic!("graduation failed: {f:?}"),
        }
    }

    fn failure(&self, a: &MomentGradArgs) -> GradFailure {
        match self.attempt(a) {
            Attempt::Failed(f) => f,
            Attempt::Graduated(r) => panic!("graduation succeeded: {r:?}"),
        }
    }

    /// Whether a contract lives at `id`.
    fn deployed(&self, id: &Address) -> bool {
        matches!(self.coin(id).try_decimals(), Ok(Ok(_)))
    }

    /// The Soroswap pair of `coin` and USDC, if there is one.
    fn pair(&self, coin: &Address) -> Option<Address> {
        let f = soroswap_factory::Client::new(&self.e, &self.factory);
        f.pair_exists(coin, &self.usdc).then(|| f.get_pair(coin, &self.usdc))
    }

    /// The pair's reserves as (coin side, USDC side).
    fn reserves(&self, pair: &Address, coin: &Address) -> (i128, i128) {
        let p = soroswap_pair::Client::new(&self.e, pair);
        let (r0, r1) = p.get_reserves();
        if p.token_0() == *coin {
            (r0, r1)
        } else {
            (r1, r0)
        }
    }

    /// Runs `f` as a third party whose signatures are all mocked, then enforces auth again.
    fn as_anyone<R>(&self, f: impl FnOnce() -> R) -> R {
        self.e.mock_all_auths();
        let r = f();
        self.e.set_auths(&[]);
        r
    }

    fn mint_usdc(&self, to: &Address, amount: i128) {
        self.as_anyone(|| StellarAssetClient::new(&self.e, &self.usdc).mint(to, &amount));
    }

    /// Everything a graduation of `a` can change: the USDC of moments, the graduator, the executor and the locker;
    /// whether the Moment's coin exists; and once the coin's pair exists, the pair's USDC, its LP supply and the
    /// locker's LP.
    fn snapshot(&self, a: &MomentGradArgs) -> std::vec::Vec<i128> {
        let coin = self.grad().coin_address(&a.nft);
        let usdc = self.usdc();
        let mut v = [&self.moments, &self.grad, &self.exec, &self.locker].map(|who| usdc.balance(who)).to_vec();
        v.push(self.deployed(&coin) as i128);
        match self.pair(&coin) {
            Some(pair) => {
                let lp = soroswap_pair::Client::new(&self.e, &pair);
                v.extend([usdc.balance(&pair), lp.total_supply(), lp.balance(&self.locker)]);
            }
            None => v.push(-1),
        }
        v
    }

    fn recorded(&self, a: &MomentGradArgs) -> Option<GradFailure> {
        self.moments().failure(&a.nft)
    }
}

fn invalid() -> GradFailure {
    GradFailure { origin: TAG_MOMENTS_GRADUATOR, code: Error::GraduationInvalid as u32 }
}

// ------------------------------------------------------------------------------------------------ success

#[test]
fn graduates_a_moment_into_a_soroswap_pool_whose_lp_the_locker_holds() {
    let t = setup(Venue::Soroswap);
    // The testnet Moment; the smallest pool that mints anything above Soroswap's lock; all of S; a 1M USDC reserve.
    for (pool_coins, reserve) in
        [(POOL_COINS, RESERVE), (1_002, 1_002), (COIN_SUPPLY, RESERVE), (POOL_COINS, 1_000_000 * ONE)]
    {
        let a = t.args(&Address::generate(&t.e), pool_coins, reserve);
        assert!(!t.deployed(&a.expected_coin));
        let u0 = t.usdc().balance(&t.moments);

        let r = t.graduated(&a);

        // The coin lives where coin_address said, built by moment-coin's constructor for moments.
        assert_eq!(r.coin, a.expected_coin);
        let coin = t.coin(&r.coin);
        assert_eq!((coin.minter(), coin.cap(), coin.decimals()), (t.moments.clone(), COIN_SUPPLY, 7));
        assert_eq!((coin.name(), coin.symbol()), (a.name.clone(), a.symbol.clone()));
        // The pool opens at reserve / pool_coins, with all of both.
        let pair = t.pair(&r.coin).unwrap();
        assert_eq!((r.pool.clone(), r.lp_token.clone()), (pair.clone(), pair.clone()));
        assert_eq!(t.reserves(&pair, &r.coin), (pool_coins, reserve));
        assert_eq!((r.coin_used, r.usdc_used, r.usdc_returned), (pool_coins, reserve, 0));
        assert_eq!(coin.total_supply(), pool_coins);
        // The locker holds every LP unit but Soroswap's lock, registered by moments as the Moment's position.
        let liquidity = isqrt_u128((pool_coins * reserve) as u128) as i128 - SOROSWAP_MIN_LIQ;
        let lp = soroswap_pair::Client::new(&t.e, &pair);
        assert_eq!(r.liquidity, liquidity);
        assert_eq!((lp.balance(&t.locker), lp.total_supply()), (liquidity, liquidity + SOROSWAP_MIN_LIQ));
        let pos = lp_locker::Client::new(&t.e, &t.locker).position(&pair).unwrap();
        assert_eq!((pos.owner, pos.kind, pos.lp_token), (t.moments.clone(), lp_locker::VenueKind::Soroswap, pair));
        let expected = (liquidity, r.coin.clone(), t.usdc.clone(), MOMENT_HARVEST_BPS);
        assert_eq!((pos.lp, pos.base, pos.quote, pos.harvest_bps), expected);
        assert_eq!(pos.reference, lp_locker::PositionRef::Moment(a.nft.clone()));
        // moments paid exactly the reserve; the graduator and the executor keep nothing.
        assert_eq!(t.usdc().balance(&t.moments), u0 - reserve);
        for who in [&t.grad, &t.exec] {
            assert_eq!((coin.balance(who), t.usdc().balance(who)), (0, 0));
        }
        assert_eq!(t.recorded(&a), None);
    }
}

#[test]
fn coin_address_is_the_graduators_deployment_address_for_the_nft_salt() {
    let t = setup(Venue::Soroswap);
    let nft = Address::generate(&t.e);
    let mut seed = Bytes::from_slice(&t.e, b"dyorhq/moment-coin/v2");
    seed.append(&nft.clone().to_xdr(&t.e));
    let salt: BytesN<32> = t.e.crypto().sha256(&seed).into();
    let predicted = t.e.deployer().with_address(t.grad.clone(), salt).deployed_address();

    assert_eq!(t.grad().coin_address(&nft), predicted);
    assert_ne!(t.grad().coin_address(&Address::generate(&t.e)), predicted);
    assert!(!t.deployed(&predicted));
    assert_eq!(t.graduated(&t.args(&nft, POOL_COINS, RESERVE)).coin, predicted);
    assert!(t.deployed(&predicted));
    assert_eq!(t.grad().coin_address(&nft), predicted);
}

#[test]
fn a_moment_graduates_once() {
    // moments-v2 never graduates a Moment twice. If it did, the coin's address is taken, so the deployment fails (a
    // host error, origin 99 once try_ narrows it) and the reserve pulled before it goes back.
    let t = setup(Venue::Soroswap);
    let a = t.moment();
    t.graduated(&a);
    let before = t.snapshot(&a);
    assert_eq!(t.failure(&a), GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 });
    assert_eq!(t.snapshot(&a), before);
}

#[test]
fn leftovers_within_the_dust_bound_are_burned_and_returned() {
    let t = setup(Venue::Lying);
    let cases = [
        // The testnet Moment, 1,000 coin units left over: a quarter of a √k unit, within min_liquidity's rounding.
        (POOL_COINS, RESERVE, 1_000, 0),
        // A reserve far above the coins, with 30 USDC units left over.
        (1_000 * ONE, 1_000_000 * ONE, 0, 30),
        // Equal sides with one unit of each left over: exactly the unit of rounding min_liquidity allows.
        (100_000 * ONE, 100_000 * ONE, 1, 1),
    ];
    for (pool_coins, reserve, coins_left, usdc_left) in cases {
        t.lying_exec().set_lie(&Lie::LeavesDust(coins_left, usdc_left));
        let a = t.args(&Address::generate(&t.e), pool_coins, reserve);
        let u0 = t.usdc().balance(&t.moments);

        let r = t.graduated(&a);

        assert_eq!((r.coin_used, r.usdc_used), (pool_coins - coins_left, reserve - usdc_left));
        assert_eq!(r.usdc_returned, usdc_left);
        assert_eq!(t.reserves(&r.pool, &r.coin), (pool_coins - coins_left, reserve - usdc_left));
        // The coins the pool didn't take are burned; the USDC it didn't use is back at moments.
        let coin = t.coin(&r.coin);
        assert_eq!(coin.total_supply(), pool_coins - coins_left);
        assert_eq!((coin.balance(&t.grad), t.usdc().balance(&t.grad)), (0, 0));
        assert_eq!(t.usdc().balance(&t.moments), u0 - reserve + usdc_left);
    }
}

#[test]
fn the_graduated_coin_trades_on_the_router() {
    let t = setup(Venue::Soroswap);
    let r = t.graduated(&t.moment());
    let bob = Address::generate(&t.e);
    t.mint_usdc(&bob, ONE);
    let got = t.as_anyone(|| {
        let path = vec![&t.e, t.usdc.clone(), r.coin.clone()];
        let deadline = t.e.ledger().timestamp() + 600;
        soroswap_router::Client::new(&t.e, &t.router).swap_exact_tokens_for_tokens(&ONE, &0, &path, &bob, &deadline);
        t.coin(&r.coin).balance(&bob)
    });
    assert!(got > 0);
    assert_eq!(t.reserves(&r.pool, &r.coin), (POOL_COINS - got, RESERVE + ONE));
}

#[test]
fn nobody_can_create_the_coins_pair_before_the_graduation() {
    // The coin's address is public from publish on, but a Soroswap pair reads its tokens' symbols when it is created,
    // and the coin exists only from inside the graduation's frame. So nobody can create the pair early, let alone seed
    // it or donate to it: the graduation always creates it and opens it at exactly reserve / pool_coins.
    let t = setup(Venue::Soroswap);
    let a = t.moment();
    let early =
        t.as_anyone(|| soroswap_factory::Client::new(&t.e, &t.factory).try_create_pair(&a.expected_coin, &t.usdc));
    assert!(early.is_err());
    assert_eq!(t.pair(&a.expected_coin), None);

    let r = t.graduated(&a);
    assert_eq!(Some(r.pool.clone()), t.pair(&a.expected_coin));
    assert_eq!(t.reserves(&r.pool, &r.coin), (POOL_COINS, RESERVE));
}

#[test]
fn stray_usdc_at_the_graduator_stays_put() {
    // Anyone can send USDC to the graduator. It compares its balance before and after the executor, so a stray
    // balance moves no check, and it only ever moves the reserve it pulled.
    let t = setup(Venue::Soroswap);
    t.mint_usdc(&t.grad, 3 * ONE);
    let a = t.moment();
    let u0 = t.usdc().balance(&t.moments);
    let r = t.graduated(&a);
    assert_eq!(t.usdc().balance(&t.grad), 3 * ONE);
    assert_eq!(t.usdc().balance(&t.moments), u0 - RESERVE);
    assert_eq!(t.reserves(&r.pool, &r.coin), (POOL_COINS, RESERVE));
}

// ------------------------------------------------------------------------------------------------ refusals

#[test]
fn only_the_configured_moments_can_graduate() {
    let t = setup(Venue::Soroswap);
    let a = t.moment();
    // Another moments instance holding USDC and pre-authorizing the pull exactly as moments does.
    let intruder = t.e.register(TestMoments, (t.grad.clone(), t.factory.clone(), t.locker.clone()));
    t.mint_usdc(&intruder, 1_000 * ONE);
    let before = t.snapshot(&a);

    // moments' auth is missing, which the host reports as an auth failure (narrowed by try_, origin 99).
    let auth_failure = GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 };
    assert_eq!(TestMomentsClient::new(&t.e, &intruder).attempt(&a), Attempt::Failed(auth_failure));
    // Called directly, with nobody's authorization.
    assert!(t.grad().try_graduate(&a).is_err());

    assert_eq!(t.snapshot(&a), before);
    assert_eq!(t.usdc().balance(&intruder), 1_000 * ONE);
    // The configured moments graduates the same Moment.
    assert_eq!(t.graduated(&a).coin, a.expected_coin);
}

#[test]
fn exec_soroswap_refuses_a_graduator_outside_its_callers() {
    let t = setup(Venue::SoroswapForOthers);
    let a = t.moment();
    let before = t.snapshot(&a);
    let not_caller = GradFailure { origin: TAG_EXEC_SOROSWAP, code: err_code(TAG_EXEC_SOROSWAP, 1) };
    assert_eq!(t.failure(&a), not_caller);
    assert_eq!(not_caller.code, 10_301);
    assert_eq!(t.snapshot(&a), before);
    assert_eq!(t.recorded(&a), Some(not_caller));
}

#[test]
fn a_failure_after_seeding_rolls_back_the_coin_and_every_transfer() {
    let t = setup(Venue::Lying);
    t.lying_exec().set_lie(&Lie::FailAfterSeeding);
    let a = t.moment();
    let before = t.snapshot(&a);

    // The executor had pulled both assets, created and seeded the pair and sent the LP to the locker when it failed.
    let attempt = t.attempt(&a);
    // Events are the last call's. moments emits none, so every one there was the failed frame's, and none survives:
    // not the coin's mint, the transfers, the pair's creation or the deposit.
    assert!(t.e.events().all().events().is_empty());
    let forced = GradFailure { origin: ORIGIN_FOREIGN, code: ExecError::Forced as u32 };
    assert_eq!(attempt, Attempt::Failed(forced));
    assert!(!t.deployed(&a.expected_coin));
    assert_eq!(t.pair(&a.expected_coin), None);
    assert_eq!(t.snapshot(&a), before);
    assert_eq!(t.recorded(&a), Some(forced));

    // The rollback freed the coin's address: the next attempt deploys the coin there.
    t.lying_exec().set_lie(&Lie::Honest);
    assert_eq!(t.graduated(&a).coin, a.expected_coin);
}

#[test]
fn qa_exec_fail_fails_recoverably_and_its_bogus_success_is_graduation_invalid() {
    // testnet-qa's failing Moments stack (F5): the same code with qa-exec-fail as the executor. Mode 0 fails with the
    // executor's own error; mode 2 reports a success without moving anything (its own address as the pool and the LP
    // token), which the result checks reject. The two failures record different (origin, code) pairs (V10).
    let t = setup(Venue::QaFail(qa_exec_fail::Mode::Fail));
    let (forced, bogus) = (t.moment(), t.moment());
    // A Moment's mode is keyed by its predicted coin address (§7.3).
    t.as_anyone(|| {
        qa_exec_fail::Client::new(&t.e, &t.exec).set_mode(&bogus.expected_coin, &qa_exec_fail::Mode::BogusSuccess)
    });
    let forced_failure = GradFailure { origin: TAG_QA_EXEC_FAIL, code: 10_502 };
    for (a, expected) in [(&forced, forced_failure), (&bogus, invalid())] {
        let before = t.snapshot(a);
        assert_eq!(t.failure(a), expected);
        assert_eq!(t.snapshot(a), before);
        assert_eq!(t.recorded(a), Some(expected));
    }
    assert_eq!(invalid(), GradFailure { origin: 10, code: 11_003 });
}

#[test]
fn every_lie_of_an_executor_is_graduation_invalid_with_nothing_changed() {
    let t = setup(Venue::Lying);
    // Another real pair for the wrong-pool lie; USDC at the locker, so that only the LP-token check can catch the
    // wrong-LP-token lie; and USDC at the executor, so that it can pay moments behind the graduator's back.
    let other_asset = t.e.register_stellar_asset_contract_v2(Address::generate(&t.e)).address();
    let other_pair = t.as_anyone(|| soroswap_factory::Client::new(&t.e, &t.factory).create_pair(&t.usdc, &other_asset));
    t.mint_usdc(&t.locker, 1_000_000 * ONE);
    t.mint_usdc(&t.exec, ONE);
    let lies = [
        (Lie::CoinsOverReported, "coins used above pool_coins"),
        (Lie::CoinsBelowDust, "coins used below pool_coins − 1 bp"),
        (Lie::CoinsUnderReported, "a coin balance delta that differs from coin_used"),
        (Lie::ReturnsCoins(1), "a coin short in the pool, returned, every coin reported as used"),
        (Lie::KeepsCoins(1), "a coin short in the pool, kept, every coin reported as used"),
        (Lie::KeepsCoins(POOL_COINS / 2), "half the coins kept, every coin reported as used"),
        (Lie::UsdcOverReported, "USDC used above the reserve"),
        (Lie::UsdcBelowDust, "USDC used below the reserve − 1 bp"),
        (Lie::UsdcUnderReported, "a USDC balance delta that differs from usdc_used"),
        (Lie::KeepsUsdc(1), "a USDC unit short in the pool, kept, the whole reserve reported as used"),
        (Lie::LiquidityBelowMinimum, "liquidity below the minimum"),
        (Lie::LiquidityOverstated, "more liquidity reported than the locker received"),
        (Lie::KeepsLp, "the LP sent elsewhere"),
        (Lie::WrongPool(other_pair), "another pair reported as the pool"),
        (Lie::WrongLpToken(t.usdc.clone()), "another token reported as the LP token"),
        (Lie::PaysTo(t.moments.clone()), "moments paid behind the graduator's back"),
    ];
    let mut rolled_back = std::vec::Vec::new();
    for (lie, what) in lies {
        t.lying_exec().set_lie(&lie);
        let a = t.moment();
        let before = t.snapshot(&a);
        assert_eq!(t.attempt(&a), Attempt::Failed(invalid()), "{what}");
        assert_eq!(t.snapshot(&a), before, "{what}");
        assert_eq!(t.recorded(&a), Some(invalid()), "{what}");
        rolled_back.push(a);
    }

    // A wrong expected coin fails the same way with an honest executor.
    t.lying_exec().set_lie(&Lie::Honest);
    let mut a = t.moment();
    a.expected_coin = t.grad().coin_address(&Address::generate(&t.e));
    let before = t.snapshot(&a);
    assert_eq!(t.failure(&a), invalid());
    assert_eq!(t.snapshot(&a), before);

    // Each rolled-back Moment still graduates at its predicted address once the executor is honest.
    for a in rolled_back {
        assert_eq!(t.graduated(&a).coin, a.expected_coin);
    }
}

#[test]
fn amounts_that_cant_seed_a_pool_fail_invalid_amounts() {
    let t = setup(Venue::Soroswap);
    let cases = [
        (POOL_COINS, 0),
        (POOL_COINS, -1),
        (0, RESERVE),
        (-1, RESERVE),
        (COIN_SUPPLY + 1, RESERVE),
        // isqrt(1,002,001) = 1,001 and isqrt(1,000,000) = 1,000: min_liquidity 0 and −1.
        (1_001, 1_001),
        (1_000, 1_000),
        // pool_coins · reserve overflows.
        (COIN_SUPPLY, i128::MAX),
    ];
    let invalid_amounts = GradFailure { origin: TAG_MOMENTS_GRADUATOR, code: Error::InvalidAmounts as u32 };
    for (pool_coins, reserve) in cases {
        let a = t.args(&Address::generate(&t.e), pool_coins, reserve);
        let before = t.snapshot(&a);
        assert_eq!(t.failure(&a), invalid_amounts, "{pool_coins} · {reserve}");
        assert_eq!(t.snapshot(&a), before);
    }
}

// ------------------------------------------------------------------------------------------------ interface

#[test]
fn the_constructor_is_the_pinned_one() {
    // CT-11a's deploy kit builds these arguments and refuses a WASM whose constructor spec differs (its rule L-d).
    let ScSpecEntry::FunctionV0(f) =
        ScSpecEntry::from_xdr(MomentsGraduator::spec_xdr___constructor(), Limits::none()).unwrap()
    else {
        panic!("not a function");
    };
    let inputs: std::vec::Vec<_> = f.inputs.iter().map(|i| (i.name.to_utf8_string_lossy(), i.type_.clone())).collect();
    let expected = [
        ("moments", ScSpecTypeDef::Address),
        ("coin_wasm_hash", ScSpecTypeDef::BytesN(ScSpecTypeBytesN { n: 32 })),
        ("executor", ScSpecTypeDef::Address),
        ("locker", ScSpecTypeDef::Address),
        ("soroswap_factory", ScSpecTypeDef::Address),
    ]
    .map(|(name, ty)| (std::string::String::from(name), ty));
    assert_eq!(inputs, expected);
    assert!(f.outputs.is_empty());
}

#[test]
fn views_return_the_constructor_arguments() {
    let t = setup(Venue::Soroswap);
    let g = t.grad();
    assert_eq!((g.moments(), g.executor(), g.locker()), (t.moments.clone(), t.exec.clone(), t.locker.clone()));
    assert_eq!((g.soroswap_factory(), g.coin_wasm_hash()), (t.factory.clone(), t.coin_wasm_hash.clone()));
    assert_eq!(g.error_tag(), TAG_MOMENTS_GRADUATOR);
}

#[test]
fn error_values_lie_in_the_graduator_range() {
    let errors = [Error::NotMoments, Error::InvalidAmounts, Error::GraduationInvalid];
    for (n, err) in (1..).zip(errors) {
        assert_eq!(err as u32, err_code(TAG_MOMENTS_GRADUATOR, n));
        assert!((11_001..=11_003).contains(&(err as u32)));
        assert_eq!(tag_of(err as u32), Some(TAG_MOMENTS_GRADUATOR));
    }
    assert_eq!(Error::GraduationInvalid as u32, 11_003);
}

// ------------------------------------------------------------------------------------------------ resources

/// §18.3: a Moments graduation stays within 250M instructions and 80 write entries. Measured on the graduator's
/// release WASM when build.sh has written it to contracts/dist (VM costs included), else on the native contract. The
/// moments-v2 stand-in is native, so its own few instructions aren't metered; the locker registration it makes is.
#[test]
fn a_graduation_stays_within_the_moments_budget() {
    let wasm = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../dist/dyor_moments_graduator.wasm")).ok();
    let t = setup_with(Venue::Soroswap, wasm.as_deref());
    std::println!("measuring the {}", if wasm.is_some() { "release WASM" } else { "native contract" });
    let r = t.graduated(&t.moment());
    let res = t.e.cost_estimate().resources();
    std::println!(
        "Moments graduation: {} instructions, {} write entries, {} read entries, {} bytes written",
        res.instructions,
        res.write_entries,
        res.disk_read_entries + res.memory_read_entries,
        res.write_bytes
    );
    assert!(res.instructions <= 250_000_000, "{} instructions", res.instructions);
    assert!(res.write_entries <= 80, "{} write entries", res.write_entries);
    assert_eq!(t.reserves(&r.pool, &r.coin), (POOL_COINS, RESERVE));
}
