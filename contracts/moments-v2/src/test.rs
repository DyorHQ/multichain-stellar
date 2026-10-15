//! moments-v2 (§9, §18.1) against the real moment-nft, moment-coin and lp-locker WASMs in dist/ (./build.sh builds
//! them) and the Soroswap factory, pair and router fixtures in testdata/.
//!
//! The graduator is a stand-in written here: CT-08 builds the real one in parallel. By default it does what §12 says,
//! honestly: it pulls the reserve moments-v2 pre-authorized, deploys the real moment-coin at
//! `sha256("dyorhq/moment-coin/v2" ‖ nft.to_xdr())` with S as the cap and the pool's coins minted to itself, seeds a
//! fresh Soroswap pair and deposits the LP to the locker. A test can make it fail inside its own frame (its in-frame
//! `GraduationInvalid`, an executor's error, a host error) or return each of the lies §9.3's checks must catch.
//!
//! `graduate` always runs with auth enforced and nobody's signature, as the keeper (or anyone) sends it, so the
//! reserve pull works only through moments-v2's own pre-authorization. Other calls run with every auth mocked unless
//! a test checks a signature.
extern crate std;

use super::*;
use crate::collect::quote_collect;
use crate::storage::DataKey;
use dyor_common::{
    ledgers_for, mul_div, mul_div_up, GradFailure, GraduationOutcome, HarvestPayees, MomentGradArgs, MomentGradResult,
    Payee, PositionRef, SoroswapFactoryClient, SoroswapPairClient, ERR_BASE, MAX_HARVEST_ROUND_BPS, ORIGIN_HOST,
    PRODUCTION_MOMENTS_DURATIONS, TAG_EXEC_SOROSWAP, TAG_MOMENTS_GRADUATOR, TESTNET_QA_MOMENTS_DURATIONS,
    TESTNET_TTL_POLICY,
};
use proptest::prelude::*;
use proptest::test_runner::{Config as RunnerConfig, TestRunner};
use soroban_sdk::testutils::storage::Persistent as _;
use soroban_sdk::testutils::{
    Address as _, AuthorizedFunction, AuthorizedInvocation, EnvTestConfig, Events as _, Ledger as _, MockAuth,
    MockAuthInvoke,
};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::xdr::{ContractDataDurability, LedgerEntry, LedgerKey, LedgerKeyContractData, ScErrorCode, ScVal};
use soroban_sdk::{
    contract, contracterror, contractimpl, symbol_short, vec, Event as _, IntoVal, InvokeError, Symbol, TryFromVal,
    Val, Vec,
};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

// moment-nft's constructor and lp-locker's register take 10 arguments, and the generated clients mirror them.
#[allow(clippy::too_many_arguments)]
mod moment_nft {
    soroban_sdk::contractimport!(file = "../dist/dyor_moment_nft.wasm");
}
mod moment_coin {
    soroban_sdk::contractimport!(file = "../dist/dyor_moment_coin.wasm");
}
#[allow(clippy::too_many_arguments)]
mod lp_locker {
    soroban_sdk::contractimport!(file = "../dist/dyor_lp_locker.wasm");
}
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

const ONE: i128 = 10_000_000; // 7 decimals: one USDC, one coin
const MINUTE: u64 = 60;
const HOUR: u64 = 3_600;
const DAY: u64 = 86_400;
const START: u64 = 1_800_000_000;
/// What every collector is funded with.
const FUNDS: i128 = 100_000 * ONE;
/// The testnet threshold (L10, §14.2).
const T10: i128 = 10 * ONE;
/// The reserve's share of each collect on testnet: 75%.
const RESERVE_BPS: u32 = 7_500;
/// The gross that completes T10 from empty: ceil(10·10,000/7,500) USDC = 13.3333334 (the price ceiling).
const COMPLETION: i128 = 133_333_334;
const BASE: &str = "https://dyorhq.fun/moments/";
const NAME: &str = "Sunset at Labadi";
const SYMBOL: &str = "LABADI";
const URI: &str = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/moment.json";
const PLACE: &str = "Accra, Ghana";
const DATE: &str = "2026-10-14";

// ------------------------------------------------------------------------------------------------ the graduator

/// How the stand-in graduator answers its next `graduate`.
#[soroban_sdk::contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum GradMode {
    /// §12 done honestly: the coin at its predicted address, the whole reserve and `pool_coins` in a fresh pair, the
    /// LP to the locker, and the truth reported.
    Honest = 0,
    /// All of that, then its own result check rejects it: `GraduationInvalid` (11_003) from its frame.
    Rejects = 1,
    /// An executor's error passed through unchanged: exec-soroswap's `PoolNotEmpty` (10_303).
    ExecutorFails = 2,
    /// A host error inside its frame: an auth check nobody signed.
    HostFails = 3,
    // Results that slip past its own checks. moments-v2 must abort each with `GraduationInvalid`.
    /// Deploys the coin at another salt and reports that coin.
    WrongCoin = 4,
    /// Reports one more unit returned than it sent back: `usdc_used + usdc_returned ≠ reserve`.
    UsdcSumWrong = 5,
    /// Sends 10 units back but reports the whole reserve used: moments' balance fell by less than `usdc_used`.
    UsdcUnreported = 6,
    /// Seeds half the reserve and returns the rest, reported truthfully: more than 1 bp unused.
    UsdcDust = 7,
    /// Reports its own address as the pool and the LP token.
    WrongPool = 8,
    /// Seeds 10 bp fewer coins than `pool_coins`, burns the rest and reports what it used (V9).
    CoinsShort = 9,
    /// Reports one coin more used than `pool_coins`.
    CoinsOver = 10,
    /// Deposits the LP to itself instead of the locker.
    LpElsewhere = 11,
    /// Reports the coin as the LP token.
    LpTokenNotPool = 12,
    /// Leaves one coin unit unused and burns it, reported truthfully: within the 1 bp dust, so it graduates.
    CoinDust = 13,
    // Lies that break exactly one of moments-v2's checks, each trapped by that check alone (the review's mutation
    // run): everything else about the result is true and the pool is fully seeded, so the liquidity, LP and other
    // checks all pass.
    /// Seeds every pool coin but reports 10 bp fewer used: only the V9 coin floor catches it.
    CoinFloorLie = 14,
    /// Seeds the whole reserve and reports `(reserve − 10, 10)` without sending the 10 back: only the balance delta
    /// (the I-M2 guard) catches it.
    DeltaLie = 15,
    /// Seeds half of moments' reserve and half of its own USDC, returning the other half of the reserve, reported
    /// truthfully: the pool is full, but more than 1 bp of the reserve went unused. Only the USDC floor catches it.
    UsdcFloorLie = 16,
    /// Seeds the real pair honestly but reports the decoy pair (`set_decoy`), whose LP the locker holds: only the
    /// factory's `get_pair` catches it.
    DecoyPool = 17,
    /// Pulls the reserve a second time; moments-v2 authorized one pull, so the host refuses it.
    DoublePull = 18,
    /// A donation of `DONATION` USDC lands in the pair before the deposit; the graduator counts it toward the seed and
    /// returns as much of the reserve to moments-v2, reported truthfully: within the 1 bp dust, so it graduates and
    /// the treasury is owed the return.
    UsesDonation = 19,
}

#[soroban_sdk::contracttype]
#[derive(Clone)]
enum GradKey {
    Moments,
    CoinWasm,
    Executor,
    Locker,
    Factory,
    Mode,
    Decoy,
    LastArgs,
}

/// The graduator's namespace (tag 10): `GraduationInvalid` is 11_003 (§12).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum GradError {
    GraduationInvalid = 11_003,
}

/// exec-soroswap's namespace (tag 3).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum ExecError {
    PoolNotEmpty = 10_303,
}

/// The USDC donated to the pool in `UsesDonation`: 0.0005 USDC, half of 1 bp of the 10 USDC reserve.
const DONATION: i128 = 5_000;

/// The coin salt of §12: `sha256("dyorhq/moment-coin/v2" ‖ nft.to_xdr())`.
fn coin_salt(e: &Env, nft: &Address) -> BytesN<32> {
    let mut data = Bytes::from_slice(e, b"dyorhq/moment-coin/v2");
    data.append(&nft.clone().to_xdr(e));
    e.crypto().sha256(&data).into()
}

/// Stands in for moments-graduator (§12), with the interface moments-v2 calls: `graduate`, `coin_address` and the
/// configuration views (`moments`, `coin_wasm_hash`, `executor`, `locker`, `soroswap_factory`). Its constructor takes
/// CT-08's arguments in CT-08's order.
#[contract]
pub struct TestGraduator;

#[contractimpl]
impl TestGraduator {
    pub fn __constructor(
        e: Env,
        moments: Address,
        coin_wasm_hash: BytesN<32>,
        executor: Address,
        locker: Address,
        soroswap_factory: Address,
    ) {
        let s = e.storage().instance();
        s.set(&GradKey::Moments, &moments);
        s.set(&GradKey::CoinWasm, &coin_wasm_hash);
        s.set(&GradKey::Executor, &executor);
        s.set(&GradKey::Locker, &locker);
        s.set(&GradKey::Factory, &soroswap_factory);
        s.set(&GradKey::Mode, &GradMode::Honest);
    }

    pub fn set_mode(e: Env, mode: GradMode) {
        e.storage().instance().set(&GradKey::Mode, &mode);
    }

    /// The pool `DecoyPool` reports.
    pub fn set_decoy(e: Env, pool: Address) {
        e.storage().instance().set(&GradKey::Decoy, &pool);
    }

    /// The arguments of the last graduation that returned a result.
    pub fn last_args(e: Env) -> Option<MomentGradArgs> {
        e.storage().instance().get(&GradKey::LastArgs)
    }

    pub fn moments(e: Env) -> Address {
        e.storage().instance().get(&GradKey::Moments).unwrap()
    }

    pub fn coin_wasm_hash(e: Env) -> BytesN<32> {
        e.storage().instance().get(&GradKey::CoinWasm).unwrap()
    }

    pub fn executor(e: Env) -> Address {
        e.storage().instance().get(&GradKey::Executor).unwrap()
    }

    pub fn locker(e: Env) -> Address {
        e.storage().instance().get(&GradKey::Locker).unwrap()
    }

    pub fn soroswap_factory(e: Env) -> Address {
        e.storage().instance().get(&GradKey::Factory).unwrap()
    }

    pub fn coin_address(e: Env, nft: Address) -> Address {
        e.deployer().with_current_contract(coin_salt(&e, &nft)).deployed_address()
    }

    pub fn graduate(e: Env, a: MomentGradArgs) -> Result<MomentGradResult, GradError> {
        let get = |k: GradKey| -> Address { e.storage().instance().get(&k).unwrap() };
        let (moments, locker, factory) = (get(GradKey::Moments), get(GradKey::Locker), get(GradKey::Factory));
        moments.require_auth();
        let mode: GradMode = e.storage().instance().get(&GradKey::Mode).unwrap();
        match mode {
            GradMode::ExecutorFails => soroban_sdk::panic_with_error!(&e, ExecError::PoolNotEmpty),
            // The NFT never signs anything: the host refuses the auth check.
            GradMode::HostFails => a.nft.require_auth(),
            _ => {}
        }

        let this = e.current_contract_address();
        let usdc = TokenClient::new(&e, &a.usdc);
        usdc.transfer(&moments, &this, &a.reserve);
        if mode == GradMode::DoublePull {
            usdc.transfer(&moments, &this, &a.reserve);
        }
        let salt = if mode == GradMode::WrongCoin { coin_salt(&e, &this) } else { coin_salt(&e, &a.nft) };
        let coin_wasm: BytesN<32> = e.storage().instance().get(&GradKey::CoinWasm).unwrap();
        let coin = e.deployer().with_current_contract(salt).deploy_v2(
            coin_wasm,
            (moments.clone(), a.name.clone(), a.symbol.clone(), SUPPLY, this.clone(), a.pool_coins),
        );
        // As exec-soroswap does: a pair someone created earlier is used as it is.
        let factory = SoroswapFactoryClient::new(&e, &factory);
        let pair = if factory.pair_exists(&coin, &a.usdc) {
            factory.get_pair(&coin, &a.usdc)
        } else {
            factory.create_pair(&coin, &a.usdc)
        };
        if mode == GradMode::UsesDonation {
            // Nobody can create the pair before the coin exists (Soroswap's pair reads both tokens' symbols when it is
            // initialized), so the graduator's own USDC plays a donation that lands before the deposit.
            usdc.transfer(&this, &pair, &DONATION);
        }

        let coin_in = match mode {
            GradMode::CoinsShort => a.pool_coins - a.pool_coins / 1_000,
            GradMode::CoinDust => a.pool_coins - 1,
            _ => a.pool_coins,
        };
        let usdc_in = match mode {
            GradMode::UsdcDust | GradMode::UsdcFloorLie => a.reserve / 2,
            GradMode::UsdcUnreported => a.reserve - 10,
            // The donation already in the pair makes up the rest.
            GradMode::UsesDonation => a.reserve - usdc.balance(&pair),
            _ => a.reserve,
        };
        let coin_token = TokenClient::new(&e, &coin);
        coin_token.transfer(&this, &pair, &coin_in);
        usdc.transfer(&this, &pair, &usdc_in);
        if mode == GradMode::UsdcFloorLie {
            // Its own USDC fills the pool up to the whole reserve.
            usdc.transfer(&this, &pair, &(a.reserve - usdc_in));
        }
        let lp_to = if mode == GradMode::LpElsewhere { this.clone() } else { locker };
        let liquidity = SoroswapPairClient::new(&e, &pair).deposit(&lp_to);
        if coin_in < a.pool_coins {
            coin_token.burn(&this, &(a.pool_coins - coin_in));
        }
        let returned = a.reserve - usdc_in;
        if returned > 0 {
            usdc.transfer(&this, &moments, &returned);
        }
        if mode == GradMode::Rejects {
            return Err(GradError::GraduationInvalid);
        }

        let (pool, lp_token) = match mode {
            GradMode::WrongPool => (this.clone(), this.clone()),
            GradMode::LpTokenNotPool => (pair.clone(), coin.clone()),
            GradMode::DecoyPool => {
                let decoy = get(GradKey::Decoy);
                (decoy.clone(), decoy)
            }
            _ => (pair.clone(), pair),
        };
        let (usdc_used, usdc_returned) = match mode {
            GradMode::UsdcSumWrong => (usdc_in, returned + 1),
            GradMode::UsdcUnreported => (a.reserve, 0),
            GradMode::DeltaLie => (a.reserve - 10, 10),
            _ => (usdc_in, returned),
        };
        let coin_used = match mode {
            GradMode::CoinsOver => a.pool_coins + 1,
            GradMode::CoinFloorLie => a.pool_coins - a.pool_coins / 1_000,
            _ => coin_in,
        };
        e.storage().instance().set(&GradKey::LastArgs, &a);
        Ok(MomentGradResult { coin, pool, lp_token, liquidity, coin_used, usdc_used, usdc_returned })
    }
}

// ------------------------------------------------------------------------------------------------ harness

struct T {
    e: Env,
    /// moments-v2
    id: Address,
    usdc: Address,
    governance: Address,
    guardian: Address,
    platform: Address,
    treasury: Address,
    creator: Address,
    alice: Address,
    bob: Address,
    graduator: Address,
    executor: Address,
    locker: Address,
    factory: Address,
    router: Address,
    nft_wasm: BytesN<32>,
    coin_wasm: BytesN<32>,
    durations: MomentsDurations,
    nonce: Cell<u64>,
}

/// The testnet policy of §14.2: T = 10 USDC, 0.10 USDC minimum, 20/5/75, 10% maximum allocation, 70% to the creator
/// at expiry, a 5% royalty.
fn testnet_policy(platform: &Address, treasury: &Address) -> Policy {
    Policy {
        threshold: T10,
        min_price: ONE / 10,
        creator_bps: 2_000,
        platform_bps: 500,
        reserve_bps: RESERVE_BPS,
        max_creator_alloc_bps: 1_000,
        expiry_creator_bps: 7_000,
        royalty_bps: 500,
        platform: platform.clone(),
        treasury: treasury.clone(),
    }
}

/// The deployment of §3.4 in a test: the Soroswap factory and router, the locker with moments-v2 (at its precomputed
/// id) as its owner, the stand-in graduator, then moments-v2 with the testnet policy and `durations`.
fn setup_with(durations: MomentsDurations) -> T {
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    e.ledger().with_mut(|l| l.timestamp = START);
    let usdc = e.register_stellar_asset_contract_v2(Address::generate(&e)).address();
    let [governance, guardian, platform, treasury, creator, alice, bob, executor] =
        core::array::from_fn(|_| Address::generate(&e));

    let factory = e.register(soroswap_factory::WASM, ());
    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    soroswap_factory::Client::new(&e, &factory).initialize(&Address::generate(&e), &pair_hash);
    let router = e.register(soroswap_router::WASM, ());
    soroswap_router::Client::new(&e, &router).initialize(&factory);

    let id = Address::generate(&e);
    let locker = e.register(
        lp_locker::WASM,
        (vec![&e, id.clone()], factory.clone(), None::<Address>, durations.harvest_interval),
    );
    let nft_wasm = e.deployer().upload_contract_wasm(moment_nft::WASM);
    let coin_wasm = e.deployer().upload_contract_wasm(moment_coin::WASM);
    let graduator =
        e.register(TestGraduator, (id.clone(), coin_wasm.clone(), executor.clone(), locker.clone(), factory.clone()));
    e.register_at(
        &id,
        MomentsV2,
        (
            governance.clone(),
            Some(guardian.clone()),
            usdc.clone(),
            nft_wasm.clone(),
            graduator.clone(),
            locker.clone(),
            executor.clone(),
            factory.clone(),
            String::from_str(&e, BASE),
            testnet_policy(&platform, &treasury),
            durations,
            TESTNET_TTL_POLICY,
        ),
    );
    let sac = StellarAssetClient::new(&e, &usdc);
    for who in [&creator, &alice, &bob] {
        sac.mint(who, &FUNDS);
    }
    T {
        e,
        id,
        usdc,
        governance,
        guardian,
        platform,
        treasury,
        creator,
        alice,
        bob,
        graduator,
        executor,
        locker,
        factory,
        router,
        nft_wasm,
        coin_wasm,
        durations,
        nonce: Cell::new(0),
    }
}

fn setup() -> T {
    setup_with(PRODUCTION_MOMENTS_DURATIONS)
}

impl T {
    fn m(&self) -> MomentsV2Client<'_> {
        MomentsV2Client::new(&self.e, &self.id)
    }

    fn grad(&self) -> TestGraduatorClient<'_> {
        TestGraduatorClient::new(&self.e, &self.graduator)
    }

    fn locker(&self) -> lp_locker::Client<'_> {
        lp_locker::Client::new(&self.e, &self.locker)
    }

    fn nft(&self, nft: &Address) -> moment_nft::Client<'_> {
        moment_nft::Client::new(&self.e, nft)
    }

    fn coin(&self, coin: &Address) -> moment_coin::Client<'_> {
        moment_coin::Client::new(&self.e, coin)
    }

    fn usdc_of(&self, who: &Address) -> i128 {
        TokenClient::new(&self.e, &self.usdc).balance(who)
    }

    fn now(&self) -> u64 {
        self.e.ledger().timestamp()
    }

    fn set_time(&self, at: u64) {
        assert!(at >= self.now(), "time only moves forward");
        self.e.ledger().with_mut(|l| l.timestamp = at);
    }

    fn advance(&self, secs: u64) {
        self.set_time(self.now() + secs);
    }

    fn s(&self, s: &str) -> String {
        String::from_str(&self.e, s)
    }

    fn next_nonce(&self) -> u64 {
        self.nonce.set(self.nonce.get() + 1);
        self.nonce.get()
    }

    /// A Moment at 1 USDC, 10% allocation, a one-day window and the next nonce.
    fn params(&self) -> PublishParams {
        PublishParams {
            name: self.s(NAME),
            symbol: self.s(SYMBOL),
            metadata_uri: self.s(URI),
            media_hash: BytesN::from_array(&self.e, &[7; 32]),
            place: self.s(PLACE),
            date: self.s(DATE),
            price: ONE,
            creator_alloc_bps: 1_000,
            window_secs: DAY,
            nonce: self.next_nonce(),
        }
    }

    /// Publishes `p` as the creator against the live terms.
    fn publish_with(&self, p: &PublishParams) -> Address {
        self.m().publish(&self.creator, p, &self.m().terms())
    }

    fn publish(&self) -> Address {
        self.publish_with(&self.params())
    }

    fn try_publish(&self, p: &PublishParams) -> Result<Address, soroban_sdk::Error> {
        contract_result(self.m().try_publish(&self.creator, p, &self.m().terms()))
    }

    fn collect(&self, who: &Address, nft: &Address, qty: u32) -> CollectResult {
        self.m().collect(who, nft, &qty, &i128::MAX)
    }

    /// Alice collects until the Moment completes (it must be 20 editions or fewer away).
    fn complete(&self, nft: &Address) -> CollectResult {
        self.complete_by(&self.alice, nft)
    }

    /// `who` collects until the Moment completes.
    fn complete_by(&self, who: &Address, nft: &Address) -> CollectResult {
        let m = self.m().get_moment(nft);
        let l = self.m().ledger(nft);
        let gross = mul_div_up(m.threshold - l.reserve, BPS as i128, m.reserve_bps as i128);
        let r = self.collect(who, nft, mul_div_up(gross, 1, m.price) as u32);
        assert_eq!(self.m().ledger(nft).state, State::GraduationPending);
        r
    }

    /// `graduate` as the keeper sends it: auth enforced and nobody's signature.
    fn try_graduate(&self, nft: &Address) -> Result<GraduationOutcome, soroban_sdk::Error> {
        self.e.set_auths(&[]);
        let r = self.m().try_graduate(nft);
        self.e.mock_all_auths();
        contract_result(r)
    }

    fn graduate(&self, nft: &Address) -> GraduationOutcome {
        self.try_graduate(nft).unwrap()
    }

    /// A Moment published, completed by Alice and graduated.
    fn graduated(&self) -> Address {
        let nft = self.publish();
        self.complete(&nft);
        assert!(matches!(self.graduate(&nft), GraduationOutcome::Graduated(_)));
        nft
    }

    fn ledger(&self, nft: &Address) -> Ledger {
        self.m().ledger(nft)
    }

    /// Proposes `p` as governance and applies it once the timelock has passed.
    fn change_policy(&self, p: &Policy) {
        self.m().propose_policy(p);
        self.advance(self.durations.timelock);
        self.m().apply_policy();
    }

    /// Runs `f` with exactly `who`'s signature on `fn_name(args)` at moments-v2, then mocks every auth again.
    fn signed_by<R>(&self, who: &Address, fn_name: &str, args: Vec<Val>, f: impl FnOnce() -> R) -> R {
        self.e.mock_auths(&[MockAuth {
            address: who,
            invoke: &MockAuthInvoke { contract: &self.id, fn_name, args, sub_invokes: &[] },
        }]);
        let r = f();
        self.e.mock_all_auths();
        r
    }

    /// The events moments-v2 emitted in the last invocation.
    fn events(&self) -> std::vec::Vec<soroban_sdk::xdr::ContractEvent> {
        self.e.events().all().filter_by_contract(&self.id).events().to_vec()
    }

    /// Swaps `amount_in` of `token_in` for `token_out` on the router as Bob. Returns what came out.
    fn swap(&self, token_in: &Address, token_out: &Address, amount_in: i128) -> i128 {
        let path = vec![&self.e, token_in.clone(), token_out.clone()];
        let router = soroswap_router::Client::new(&self.e, &self.router);
        let out = router.swap_exact_tokens_for_tokens(&amount_in, &0, &path, &self.bob, &(self.now() + 600));
        out.get_unchecked(1)
    }
}

fn err(error: Error) -> soroban_sdk::Error {
    error.into()
}

/// A `try_` call's value, or the contract error it failed with. Anything else (a conversion failure, an abort) panics.
fn contract_result<V: core::fmt::Debug, C: core::fmt::Debug>(
    r: Result<Result<V, C>, Result<soroban_sdk::Error, InvokeError>>,
) -> Result<V, soroban_sdk::Error> {
    match r {
        Ok(Ok(v)) => Ok(v),
        Err(Ok(e)) => Err(e),
        other => panic!("not a value or a contract error: {other:?}"),
    }
}

/// The contract error a `try_` call failed with.
fn failure<V: core::fmt::Debug, C: core::fmt::Debug>(
    r: Result<Result<V, C>, Result<soroban_sdk::Error, InvokeError>>,
) -> soroban_sdk::Error {
    contract_result(r).expect_err("the call succeeded")
}

/// The host's refusal of a call whose `require_auth` no signature covers.
const AUTH_REFUSED: &str = "Error(Auth, InvalidAction)";

/// Whether `call` aborted for a missing signature. A `try_` call can't tell: the host hands every error that isn't a
/// contract error back to a top-level `try_` caller as `Error(Context, InvalidAction)`. So the call goes without
/// `try_`, and the abort's first line names the error, as in moment-nft's tests.
fn refused<R>(call: impl FnOnce() -> R) -> bool {
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(_) => false,
        Err(abort) => abort
            .downcast_ref::<std::string::String>()
            .and_then(|message| message.lines().next())
            .is_some_and(|line| line.contains(AUTH_REFUSED)),
    }
}

/// The coins a collect of `gross` promises at a Moment's bundle rate.
fn entitlement(m: &Moment, gross: i128) -> i128 {
    // Every gross in these tests keeps gross·rate_num inside i128.
    mul_div(gross, m.rate_num, m.rate_den)
}

fn alloc_of(m: &Moment) -> i128 {
    SUPPLY * m.creator_alloc_bps as i128 / BPS as i128
}

// ------------------------------------------------------------------------------------------------ storage probes

/// Every live entry the host holds, by key.
fn stored(e: &Env) -> BTreeMap<LedgerKey, (Rc<LedgerEntry>, Option<u32>)> {
    let entries = e.host().get_stored_entries().unwrap();
    entries.into_iter().filter_map(|(k, v)| v.map(|v| ((*k).clone(), v))).collect()
}

/// Runs `f` and returns the keys it wrote: new entries, replaced entries (the host stores every write as a new `Rc`)
/// and entries whose TTL changed.
fn writes<R>(e: &Env, f: impl FnOnce() -> R) -> (R, std::vec::Vec<LedgerKey>) {
    let before = stored(e);
    let r = f();
    let written = stored(e)
        .into_iter()
        .filter(|(k, (entry, ttl))| match before.get(k) {
            None => true,
            Some((old, old_ttl)) => !Rc::ptr_eq(old, entry) || old_ttl != ttl,
        })
        .map(|(k, _)| k)
        .collect();
    (r, written)
}

/// Whether `k` is an auth nonce: the entry a signer's authorization consumes.
fn is_nonce(k: &LedgerKey) -> bool {
    matches!(k, LedgerKey::ContractData(LedgerKeyContractData { key: ScVal::LedgerKeyNonce(_), .. }))
}

/// The ledger key of `contract`'s instance, which holds its instance storage.
fn instance_key(contract: &Address) -> LedgerKey {
    LedgerKey::ContractData(LedgerKeyContractData {
        contract: contract.into(),
        key: ScVal::LedgerKeyContractInstance,
        durability: ContractDataDurability::Persistent,
    })
}

/// The ledger key of one of moments-v2's persistent entries.
fn data_key(t: &T, key: &DataKey) -> LedgerKey {
    let key: Val = key.into_val(&t.e);
    LedgerKey::ContractData(LedgerKeyContractData {
        contract: (&t.id).into(),
        key: ScVal::try_from_val(&t.e, &key).unwrap(),
        durability: ContractDataDurability::Persistent,
    })
}

// ------------------------------------------------------------------------------------------------ v1's tests, ported

#[test]
fn each_moment_is_its_own_nft_with_its_name_symbol_and_provenance() {
    // v1's collection_metadata: one SEP-50 collection became one NFT contract per Moment, whose address is its id (L9).
    let t = setup();
    let p = t.params();
    let nft = t.publish_with(&p);
    assert_eq!(nft, t.m().nft_address(&t.creator, &p.nonce));
    let n = t.nft(&nft);
    assert_eq!((n.name(), n.symbol()), (t.s(NAME), t.s(SYMBOL)));
    assert_eq!((n.minter(), n.creator()), (t.id.clone(), t.creator.clone()));
    assert_eq!((n.minted(), n.edition_size()), (0, None));
    let mut url = Bytes::from_slice(&t.e, BASE.as_bytes());
    url.append(&nft.to_string().to_bytes());
    assert_eq!(
        n.provenance(),
        moment_nft::Provenance {
            media_hash: p.media_hash.clone(),
            place: t.s(PLACE),
            date: t.s(DATE),
            external_url: String::from(url),
        }
    );
    let m = t.m().get_moment(&nft);
    assert_eq!((m.nft, m.creator, m.nonce, m.price), (nft.clone(), t.creator.clone(), p.nonce, ONE));
    assert_eq!(m.coin, t.grad().coin_address(&nft));
    assert_eq!(t.m().ledger(&nft), Ledger::new());
}

#[test]
fn publish_and_collect_split_20_5_75_into_pull_ledgers_and_mint_editions() {
    let t = setup();
    let nft = t.publish();
    let m = t.m().get_moment(&nft);
    let r = t.m().collect(&t.alice, &nft, &3, &(3 * ONE));
    assert_eq!(r, CollectResult { first_rank: 1, editions: 3, gross: 3 * ONE, entitlement: entitlement(&m, 3 * ONE) });
    // USDC only, and nothing is pushed: it all waits in moments-v2's ledger.
    assert_eq!(t.usdc_of(&t.alice), FUNDS - 3 * ONE);
    assert_eq!((t.usdc_of(&t.id), t.usdc_of(&t.creator), t.usdc_of(&t.platform)), (3 * ONE, FUNDS, 0));
    let l = t.ledger(&nft);
    assert_eq!((l.creator_claimable, l.platform_claimable, l.reserve), (6 * ONE / 10, 15 * ONE / 100, 225 * ONE / 100));
    assert_eq!((l.total_gross, l.collects, l.editions, l.entitlements), (3 * ONE, 1, 3, r.entitlement));
    assert_eq!(t.m().position(&nft, &t.alice), Position { entitlement: r.entitlement, claimed: 0 });
    let n = t.nft(&nft);
    for edition in 1..=3 {
        assert_eq!(n.owner_of(&edition), t.alice);
        assert_eq!(n.token_uri(&edition), t.s(URI));
    }
    // Edition numbers continue across collectors.
    assert_eq!(t.collect(&t.bob, &nft, 2).first_rank, 4);
    assert_eq!(n.balance(&t.bob), 2);

    assert_eq!(t.m().withdraw_creator(&nft), 6 * ONE / 10 + 4 * ONE / 10);
    assert_eq!(t.usdc_of(&t.creator), FUNDS + ONE);
    assert_eq!(t.m().withdraw_platform(&nft), 25 * ONE / 100);
    assert_eq!(t.usdc_of(&t.platform), 25 * ONE / 100);
}

#[test]
fn editions_are_transferable_and_carry_the_creator_royalty() {
    let t = setup();
    let nft = t.publish();
    let first = t.collect(&t.alice, &nft, 1).first_rank;
    let n = t.nft(&nft);
    n.transfer(&t.alice, &t.bob, &first);
    assert_eq!(n.owner_of(&first), t.bob);
    // The policy's 5% royalty, to the creator.
    assert_eq!(n.royalty_info(&first, &(100 * ONE)), (t.creator.clone(), 5 * ONE));
}

#[test]
fn window_quantity_and_max_total_are_enforced_and_editions_are_uncapped() {
    let t = setup();
    let nft = t.publish();
    let m = t.m();
    assert_eq!(failure(m.try_collect(&t.alice, &nft, &0, &ONE)), err(Error::BadQuantity));
    assert_eq!(failure(m.try_collect(&t.alice, &nft, &21, &(21 * ONE))), err(Error::BadQuantity));
    assert_eq!(failure(m.try_collect(&t.alice, &nft, &2, &(2 * ONE - 1))), err(Error::MaxTotalExceeded));
    m.collect(&t.alice, &nft, &2, &(2 * ONE));

    // No edition cap (L9): at the minimum price a Moment takes many full batches before it completes.
    let p = PublishParams { price: ONE / 10, ..t.params() };
    let cheap = t.publish_with(&p);
    for _ in 0..3 {
        t.collect(&t.bob, &cheap, MAX_BATCH);
    }
    assert_eq!(t.nft(&cheap).minted(), 60);

    t.set_time(m.get_moment(&nft).deadline);
    assert_eq!(failure(m.try_collect(&t.alice, &nft, &1, &ONE)), err(Error::WindowClosed));
    assert_eq!(failure(m.try_quote(&nft, &1)), err(Error::WindowClosed));
}

/// Sets one of a publish's strings.
type SetString<'a> = &'a dyn Fn(&mut PublishParams, String);

#[test]
fn publish_validates_price_allocation_window_and_strings() {
    let t = setup();
    let base = t.params();
    let with = |edit: &dyn Fn(&mut PublishParams)| {
        let mut p = PublishParams { nonce: t.next_nonce(), ..base.clone() };
        edit(&mut p);
        t.try_publish(&p).map(|_| ())
    };
    let ceiling = COMPLETION;
    assert_eq!(with(&|p| p.price = ONE / 10 - 1), Err(err(Error::PriceTooLow)));
    assert_eq!(with(&|p| p.price = ONE / 10), Ok(()));
    assert_eq!(with(&|p| p.price = ceiling), Ok(()));
    assert_eq!(with(&|p| p.price = ceiling + 1), Err(err(Error::PriceTooHigh)));
    assert_eq!(with(&|p| p.creator_alloc_bps = 1_001), Err(err(Error::AllocTooHigh)));
    assert_eq!(with(&|p| p.creator_alloc_bps = 0), Ok(()));
    assert_eq!(with(&|p| p.window_secs = HOUR - 1), Err(err(Error::InvalidWindow)));
    assert_eq!(with(&|p| p.window_secs = HOUR), Ok(()));
    assert_eq!(with(&|p| p.window_secs = 30 * DAY), Ok(()));
    assert_eq!(with(&|p| p.window_secs = 30 * DAY + 1), Err(err(Error::InvalidWindow)));

    let text = |n: usize| String::from_str(&t.e, &"x".repeat(n));
    let strings: [(SetString, usize, usize); 5] = [
        (&|p, s| p.name = s, 1, 32),
        (&|p, s| p.symbol = s, 2, 10),
        (&|p, s| p.metadata_uri = s, 1, 256),
        (&|p, s| p.place = s, 0, 64),
        (&|p, s| p.date = s, 0, 32),
    ];
    for (set, lo, hi) in strings {
        assert_eq!(with(&|p| set(p, text(lo))), Ok(()));
        assert_eq!(with(&|p| set(p, text(hi))), Ok(()));
        assert_eq!(with(&|p| set(p, text(hi + 1))), Err(err(Error::InvalidString)));
        if lo > 0 {
            assert_eq!(with(&|p| set(p, text(lo - 1))), Err(err(Error::InvalidString)));
        }
    }
}

#[test]
fn policy_changes_apply_to_moments_published_after_them_only() {
    let t = setup();
    // A window longer than the policy timelock, so the Moment is still collecting after the change.
    let live = t.publish_with(&PublishParams { window_secs: 30 * DAY, ..t.params() });
    let mut next = testnet_policy(&t.platform, &t.treasury);
    (next.creator_bps, next.platform_bps) = (1_500, 1_000);
    t.change_policy(&next);
    let later = t.publish();
    t.collect(&t.alice, &live, 10);
    t.collect(&t.alice, &later, 10);
    // 5% for the Moment published before the change, 10% after it.
    assert_eq!(t.ledger(&live).platform_claimable, ONE / 2);
    assert_eq!(t.ledger(&later).platform_claimable, ONE);
    assert_eq!((t.ledger(&live).creator_claimable, t.ledger(&later).creator_claimable), (2 * ONE, 15 * ONE / 10));
}

#[test]
fn collect_requires_the_collectors_signature() {
    let t = setup();
    let nft = t.publish();
    t.e.set_auths(&[]);
    assert!(refused(|| t.m().collect(&t.alice, &nft, &1, &ONE)));
    // Bob's signature doesn't let him spend Alice's USDC.
    let args = (t.alice.clone(), nft.clone(), 1u32, ONE).into_val(&t.e);
    assert!(t.signed_by(&t.bob, "collect", args, || refused(|| t.m().collect(&t.alice, &nft, &1, &ONE))));
    assert_eq!(t.ledger(&nft).collects, 0);
}

// ------------------------------------------------------------------------------------------------ addressing (L15)

#[test]
fn a_reused_nonce_fails_and_nonces_are_per_creator() {
    let t = setup();
    let p = t.params();
    let nft = t.publish_with(&p);
    assert_eq!(t.try_publish(&p), Err(err(Error::NonceUsed)));
    // Another creator may use the same nonce: the salt includes the creator.
    let other = t.m().publish(&t.alice, &p, &t.m().terms());
    assert_ne!(other, nft);
    assert_eq!(other, t.m().nft_address(&t.alice, &p.nonce));
    assert_eq!(t.m().get_moment(&other).creator, t.alice);
    // The salt is §9.2's.
    let mut data = Bytes::from_slice(&t.e, b"dyorhq/moment-nft/v2");
    data.append(&t.creator.clone().to_xdr(&t.e));
    data.extend_from_array(&p.nonce.to_be_bytes());
    let salt: BytesN<32> = t.e.crypto().sha256(&data).into();
    assert_eq!(nft_salt(&t.e, &t.creator, p.nonce), salt);
    assert_eq!(nft, t.e.as_contract(&t.id, || t.e.deployer().with_current_contract(salt).deployed_address()));
}

/// A value as XDR, to compare values of two environments (host objects belong to one).
fn xdr<V: IntoVal<Env, Val>>(t: &T, v: V) -> ScVal {
    ScVal::try_from_val(&t.e, &v.into_val(&t.e)).unwrap()
}

#[test]
fn the_publish_event_carries_what_the_indexer_shows_before_the_first_edition() {
    let t = setup();
    let p = t.params();
    let nft = t.publish_with(&p);
    let events = t.events();
    let m = t.m().get_moment(&nft);
    let event = Published {
        nft: nft.clone(),
        creator: t.creator.clone(),
        nonce: p.nonce,
        coin: m.coin.clone(),
        name: t.s(NAME),
        symbol: t.s(SYMBOL),
        metadata_uri: t.s(URI),
        price: ONE,
        threshold: T10,
        creator_alloc_bps: 1_000,
        rate_num: m.rate_num,
        rate_den: m.rate_den,
        deadline: START + DAY,
        durations: PRODUCTION_MOMENTS_DURATIONS,
    };
    assert_eq!(events, [event.to_xdr(&t.e, &t.id)]);
    // Views of a Moment that doesn't exist.
    let stranger = Address::generate(&t.e);
    assert_eq!(failure(t.m().try_get_moment(&stranger)), err(Error::UnknownMoment));
    assert_eq!(failure(t.m().try_ledger(&stranger)), err(Error::UnknownMoment));
    assert_eq!(failure(t.m().try_quote(&stranger, &1)), err(Error::UnknownMoment));
    assert_eq!(t.m().position(&nft, &stranger), Position::default());
}

#[test]
fn entries_live_as_long_as_section_13_says() {
    let t = setup();
    let nft = t.publish();
    let ttl = |key: DataKey| t.e.as_contract(&t.id, || t.e.storage().persistent().get_ttl(&key));
    // The Moment and its ledger: the deployment's policy, renewed whenever the ledger is written.
    assert_eq!(ttl(DataKey::Moment(nft.clone())), TESTNET_TTL_POLICY.extend_to);
    assert_eq!(ttl(DataKey::Ledger(nft.clone())), TESTNET_TTL_POLICY.extend_to);
    // A position lives through the deadline and the collectors' two vesting periods, plus a week.
    t.advance(HOUR);
    t.collect(&t.alice, &nft, 1);
    let secs = DAY - HOUR + 2 * t.durations.vest_period + 7 * DAY;
    let expected = ledgers_for(secs).min(t.e.storage().max_ttl());
    assert!(expected > TESTNET_TTL_POLICY.extend_to);
    assert_eq!(ttl(DataKey::Position(nft.clone(), t.alice.clone())), expected);
}

#[test]
fn two_creators_publishes_built_against_the_same_state_both_apply_in_either_order() {
    // Two identical deployments (the address generator is deterministic). Both publishes are built against the same
    // pre-state, with the same nonce and the same terms, and applied in opposite orders.
    let (a, b) = (setup(), setup());
    for (x, y) in [(&a.id, &b.id), (&a.creator, &b.creator), (&a.alice, &b.alice), (&a.graduator, &b.graduator)] {
        assert_eq!(xdr(&a, x), xdr(&b, y));
    }
    let nonce = 7;
    let (pa, pb) = (PublishParams { nonce, ..a.params() }, PublishParams { nonce, ..b.params() });
    let (terms_a, terms_b) = (a.m().terms(), b.m().terms());
    assert_eq!(xdr(&a, &terms_a), xdr(&b, &terms_b));
    let predicted = (a.m().nft_address(&a.creator, &nonce), a.m().nft_address(&a.alice, &nonce));

    let (first, w1) = writes(&a.e, || a.m().publish(&a.creator, &pa, &terms_a));
    let (second, w2) = writes(&a.e, || a.m().publish(&a.alice, &pa, &terms_a));
    let second_b = b.m().publish(&b.alice, &pb, &terms_b);
    let first_b = b.m().publish(&b.creator, &pb, &terms_b);
    assert_eq!((first.clone(), second.clone()), predicted);
    assert_eq!(xdr(&a, &first), xdr(&b, &first_b));
    assert_eq!(xdr(&a, &second), xdr(&b, &second_b));
    assert_eq!(xdr(&a, a.m().get_moment(&first)), xdr(&b, b.m().get_moment(&first_b)));
    assert_eq!(xdr(&a, a.m().get_moment(&second)), xdr(&b, b.m().get_moment(&second_b)));

    // Their write sets are disjoint and hold nothing of moments-v2's but the Moment's own entries.
    assert!(w1.iter().all(|k| !w2.contains(k)), "the publishes wrote a common key");
    for (nft, w) in [(&first, &w1), (&second, &w2)] {
        assert!(w.contains(&data_key(&a, &DataKey::Moment(nft.clone()))));
        assert!(w.contains(&data_key(&a, &DataKey::Ledger(nft.clone()))));
        assert!(w.contains(&instance_key(nft)), "the NFT's own instance");
        assert!(!w.contains(&instance_key(&a.id)), "moments-v2's instance");
    }
}

#[test]
fn publish_and_collect_write_no_instance_key() {
    let t = setup();
    let instance = instance_key(&t.id);
    let (nft, w) = writes(&t.e, || t.publish());
    assert!(!w.contains(&instance), "publish wrote the instance");
    let (_, w) = writes(&t.e, || t.collect(&t.alice, &nft, 2));
    assert!(!w.contains(&instance), "collect wrote the instance");
    let (_, w) = writes(&t.e, || t.complete(&nft));
    assert!(!w.contains(&instance), "the terminal collect wrote the instance");
    let (_, w) = writes(&t.e, || t.graduate(&nft));
    assert!(!w.contains(&instance), "graduate wrote the instance");
    // The probe sees instance writes: a governance call makes one.
    let (_, w) = writes(&t.e, || t.m().set_publishing_paused(&true));
    assert!(w.contains(&instance));
}

// ------------------------------------------------------------------------------------------------ terms and policy

#[test]
fn terms_bind_every_field_including_durations_and_the_harvest_constants() {
    let t = setup();
    let terms = t.m().terms();
    assert_eq!(
        terms,
        MomentsTerms {
            policy: testnet_policy(&t.platform, &t.treasury),
            external_base: t.s(BASE),
            nft_wasm_hash: t.nft_wasm.clone(),
            coin_wasm_hash: t.coin_wasm.clone(),
            graduator: t.graduator.clone(),
            executor: t.executor.clone(),
            locker: t.locker.clone(),
            durations: PRODUCTION_MOMENTS_DURATIONS,
            harvest_bps: 6_667,
            harvest_creator_bps: 4_000,
        }
    );
    let other = Address::generate(&t.e);
    let hash = BytesN::from_array(&t.e, &[9; 32]);
    let edits: [&dyn Fn(&mut MomentsTerms); 17] = [
        &|x| x.policy.threshold += 1,
        &|x| x.policy.min_price += 1,
        &|x| (x.policy.creator_bps, x.policy.platform_bps) = (2_001, 499),
        &|x| x.policy.max_creator_alloc_bps = 900,
        &|x| x.policy.expiry_creator_bps = 6_999,
        &|x| x.policy.royalty_bps = 0,
        &|x| x.policy.treasury = other.clone(),
        &|x| x.external_base = String::from_str(&t.e, "https://example.com/"),
        &|x| x.nft_wasm_hash = hash.clone(),
        &|x| x.coin_wasm_hash = hash.clone(),
        &|x| x.graduator = other.clone(),
        &|x| x.executor = other.clone(),
        &|x| x.locker = other.clone(),
        &|x| x.durations.vest_period -= 1,
        &|x| x.durations.pending_backstop += 1,
        &|x| x.harvest_bps = 10_000,
        &|x| x.harvest_creator_bps = 5_000,
    ];
    for edit in edits {
        let mut wrong = terms.clone();
        edit(&mut wrong);
        assert_eq!(failure(t.m().try_publish(&t.creator, &t.params(), &wrong)), err(Error::TermsChanged));
    }
    // A policy applied between showing the terms and publishing changes them.
    let mut next = testnet_policy(&t.platform, &t.treasury);
    next.min_price = ONE / 5;
    t.change_policy(&next);
    assert_eq!(failure(t.m().try_publish(&t.creator, &t.params(), &terms)), err(Error::TermsChanged));
    t.publish();
}

#[test]
fn policy_validation_is_monads_at_seven_decimals() {
    let t = setup();
    let valid = testnet_policy(&t.platform, &t.treasury);
    let propose = |edit: &dyn Fn(&mut Policy)| {
        let mut p = valid.clone();
        edit(&mut p);
        contract_result(t.m().try_propose_policy(&p)).map(|_| ())
    };
    let bad = Err(err(Error::InvalidPolicy));
    assert_eq!(propose(&|_| {}), Ok(()));
    assert_eq!(propose(&|p| p.threshold = MIN_THRESHOLD - 1), bad);
    assert_eq!(propose(&|p| p.threshold = MIN_THRESHOLD), Ok(()));
    assert_eq!(propose(&|p| p.threshold = MAX_THRESHOLD), Ok(()));
    assert_eq!(propose(&|p| p.threshold = MAX_THRESHOLD + 1), bad);
    assert_eq!(propose(&|p| p.min_price = MIN_MIN_PRICE - 1), bad);
    assert_eq!(propose(&|p| p.min_price = MIN_MIN_PRICE), Ok(()));
    assert_eq!(propose(&|p| (p.creator_bps, p.reserve_bps) = (9_500, 0)), bad);
    assert_eq!(propose(&|p| p.creator_bps = 2_001), bad);
    assert_eq!(propose(&|p| (p.creator_bps, p.platform_bps) = (u32::MAX, 2_501)), bad);
    // The minimum price can't exceed the completion gross, ceil(T·BPS/reserve_bps).
    assert_eq!(propose(&|p| p.min_price = COMPLETION), Ok(()));
    assert_eq!(propose(&|p| p.min_price = COMPLETION + 1), bad);
    assert_eq!(propose(&|p| p.max_creator_alloc_bps = MAX_CREATOR_ALLOC_BPS + 1), bad);
    assert_eq!(propose(&|p| p.expiry_creator_bps = BPS), Ok(()));
    assert_eq!(propose(&|p| p.expiry_creator_bps = BPS + 1), bad);
    assert_eq!(propose(&|p| p.royalty_bps = MAX_ROYALTY_BPS), Ok(()));
    assert_eq!(propose(&|p| p.royalty_bps = MAX_ROYALTY_BPS + 1), bad);
}

#[test]
fn the_policy_timelock_window_lapse_and_cancel() {
    let t = setup();
    let d = t.durations;
    let m = t.m();
    assert_eq!(failure(m.try_apply_policy()), err(Error::NoPendingPolicy));
    let mut next = testnet_policy(&t.platform, &t.treasury);
    next.threshold = 20 * ONE;
    m.propose_policy(&next);
    let eta = t.now() + d.timelock;
    let pending = PendingPolicy { policy: next.clone(), eta, expires: eta + d.timelock_window };
    assert_eq!(
        t.events(),
        [PolicyProposed { policy: next.clone(), eta, expires: pending.expires }.to_xdr(&t.e, &t.id)]
    );
    assert_eq!(m.pending_policy(), Some(pending.clone()));

    t.set_time(eta - 1);
    assert_eq!(failure(m.try_apply_policy()), err(Error::PolicyNotReady));
    t.set_time(eta);
    m.apply_policy();
    assert_eq!(t.events(), [PolicySet { policy: next.clone() }.to_xdr(&t.e, &t.id)]);
    assert_eq!((m.policy(), m.pending_policy()), (next.clone(), None));

    // A proposal lapses one second after its window; it can't be applied, only replaced or cancelled.
    let mut later = next.clone();
    later.threshold = 30 * ONE;
    m.propose_policy(&later);
    t.advance(d.timelock + d.timelock_window);
    m.apply_policy();
    assert_eq!(m.policy(), later);
    m.propose_policy(&next);
    t.advance(d.timelock + d.timelock_window + 1);
    assert_eq!(failure(m.try_apply_policy()), err(Error::PolicyLapsed));
    assert_eq!(m.policy(), later);

    // Governance and the guardian may cancel; nobody else.
    let stranger = Address::generate(&t.e);
    assert_eq!(failure(m.try_cancel_policy(&stranger)), err(Error::NotAuthorized));
    m.cancel_policy(&t.guardian);
    assert_eq!(t.events(), [PolicyCancelled { by: t.guardian.clone() }.to_xdr(&t.e, &t.id)]);
    assert_eq!(m.pending_policy(), None);
    assert_eq!(failure(m.try_cancel_policy(&t.governance)), err(Error::NoPendingPolicy));
    m.propose_policy(&next);
    m.cancel_policy(&t.governance);
    t.advance(d.timelock);
    assert_eq!(failure(m.try_apply_policy()), err(Error::NoPendingPolicy));

    // Proposing is governance's: the guardian's or a stranger's signature isn't enough.
    for who in [&t.guardian, &stranger] {
        let args = (next.clone(),).into_val(&t.e);
        assert!(t.signed_by(who, "propose_policy", args, || refused(|| m.propose_policy(&next))));
    }
    // Cancelling needs the named caller's own signature.
    m.propose_policy(&next);
    let args = (t.guardian.clone(),).into_val(&t.e);
    assert!(t.signed_by(&stranger, "cancel_policy", args, || refused(|| m.cancel_policy(&t.guardian))));
    assert!(m.pending_policy().is_some());
}

#[test]
fn pauses_stop_publish_only() {
    // I-M5: with both pauses on, collect, graduate, claim, withdraw and expire all still work.
    let t = setup();
    let collecting = t.publish();
    let pending = t.publish();
    let expiring = t.publish();
    t.collect(&t.bob, &expiring, 1);
    t.m().set_publishing_paused(&true);
    assert_eq!(t.events(), [PublishingPaused { paused: true }.to_xdr(&t.e, &t.id)]);
    t.m().set_guardian_paused(&true);
    let cfg = t.m().config();
    assert!(cfg.publishing_paused && cfg.guardian_paused);
    assert_eq!(t.try_publish(&t.params()), Err(err(Error::PublishingPaused)));

    t.collect(&t.alice, &collecting, 1);
    t.complete(&pending);
    t.graduate(&pending);
    t.m().claim(&t.alice, &pending);
    t.m().withdraw_creator(&pending);
    t.m().withdraw_platform(&pending);
    t.set_time(t.m().get_moment(&expiring).deadline);
    t.m().expire(&expiring);
    t.m().withdraw_treasury(&expiring);

    // Each pause alone stops publishing; with both off it works again.
    t.m().set_guardian_paused(&false);
    assert_eq!(t.try_publish(&t.params()), Err(err(Error::PublishingPaused)));
    t.m().set_publishing_paused(&false);
    t.m().set_guardian_paused(&true);
    assert_eq!(t.try_publish(&t.params()), Err(err(Error::PublishingPaused)));
    t.m().set_guardian_paused(&false);
    t.publish();
}

#[test]
fn only_the_guardian_lifts_its_pause_and_hands_on_its_role() {
    let t = setup();
    let m = t.m();
    m.set_guardian_paused(&true);
    assert_eq!(t.events(), [GuardianPaused { paused: true }.to_xdr(&t.e, &t.id)]);
    // Governance can't lift the guardian's pause, and the guardian can't touch governance's.
    let args = (false,).into_val(&t.e);
    assert!(t.signed_by(&t.governance, "set_guardian_paused", args, || refused(|| m.set_guardian_paused(&false))));
    assert!(m.config().guardian_paused);
    let args = (true,).into_val(&t.e);
    assert!(t.signed_by(&t.guardian, "set_publishing_paused", args, || refused(|| m.set_publishing_paused(&true))));
    assert!(!m.config().publishing_paused);

    // The guardian can't hand on or renounce its role while its pause is on.
    let next = Address::generate(&t.e);
    assert_eq!(failure(m.try_transfer_guardian(&Some(next.clone()))), err(Error::UnpauseFirst));
    assert_eq!(failure(m.try_transfer_guardian(&None)), err(Error::UnpauseFirst));
    let args = (false,).into_val(&t.e);
    t.signed_by(&t.guardian, "set_guardian_paused", args, || m.set_guardian_paused(&false));
    let args = (Some(next.clone()),).into_val(&t.e);
    t.signed_by(&t.guardian, "transfer_guardian", args, || m.transfer_guardian(&Some(next.clone())));
    assert_eq!(t.events(), [GuardianSet { old: t.guardian.clone(), new: Some(next.clone()) }.to_xdr(&t.e, &t.id)]);
    assert_eq!(m.config().guardian, Some(next.clone()));
    // The old key has no power left.
    let args = (true,).into_val(&t.e);
    assert!(t.signed_by(&t.guardian, "set_guardian_paused", args, || refused(|| m.set_guardian_paused(&true))));
    m.propose_policy(&testnet_policy(&t.platform, &t.treasury));
    assert_eq!(failure(m.try_cancel_policy(&t.guardian)), err(Error::NotAuthorized));
    m.cancel_policy(&next);

    // Renounced: no guardian functions remain, and nobody can name a new one.
    m.transfer_guardian(&None);
    assert_eq!(m.config().guardian, None);
    assert_eq!(failure(m.try_set_guardian_paused(&true)), err(Error::NotGuardian));
    assert_eq!(failure(m.try_transfer_guardian(&Some(next))), err(Error::NotGuardian));
}

#[test]
fn governance_hands_over_in_two_steps() {
    let t = setup();
    let m = t.m();
    let next = Address::generate(&t.e);
    assert_eq!(failure(m.try_accept_governance()), err(Error::NoProposal));
    m.propose_governance(&next);
    assert_eq!(
        t.events(),
        [GovernanceProposed { governance: t.governance.clone(), new: next.clone() }.to_xdr(&t.e, &t.id)]
    );
    assert_eq!(m.pending_governance(), Some(next.clone()));
    assert_eq!(m.config().governance, t.governance);
    // Only the proposed address can accept.
    assert!(t.signed_by(&t.governance, "accept_governance", Vec::new(&t.e), || refused(|| m.accept_governance())));
    t.signed_by(&next, "accept_governance", Vec::new(&t.e), || m.accept_governance());
    assert_eq!(t.events(), [GovernanceSet { old: t.governance.clone(), new: next.clone() }.to_xdr(&t.e, &t.id)]);
    assert_eq!((m.config().governance, m.pending_governance()), (next.clone(), None));
    let args = (true,).into_val(&t.e);
    assert!(t.signed_by(&t.governance, "set_publishing_paused", args, || refused(|| m.set_publishing_paused(&true))));
}

#[test]
fn the_external_base_is_https_and_at_most_256_bytes() {
    let t = setup();
    let m = t.m();
    let base = |s: &str| String::from_str(&t.e, s);
    for wrong in ["http://dyorhq.fun/", "https:/", "", "ipfs://x", "HTTPS://dyorhq.fun/"] {
        assert_eq!(failure(m.try_set_external_base(&base(wrong))), err(Error::InvalidBase), "{wrong}");
    }
    let long = std::format!("https://{}", "a".repeat(256 - 8));
    m.set_external_base(&base(&long));
    assert_eq!(failure(m.try_set_external_base(&base(&std::format!("{long}a")))), err(Error::InvalidBase));
    m.set_external_base(&base("https://dyorhq.fun/m/"));
    assert_eq!(t.events(), [ExternalBaseSet { base: base("https://dyorhq.fun/m/") }.to_xdr(&t.e, &t.id)]);
    // It is part of the terms, and new Moments link with it.
    assert_eq!(m.terms().external_base, base("https://dyorhq.fun/m/"));
    let nft = t.publish();
    let mut url = Bytes::from_slice(&t.e, b"https://dyorhq.fun/m/");
    url.append(&nft.to_string().to_bytes());
    assert_eq!(t.nft(&nft).provenance().external_url, String::from(url));
}

// ------------------------------------------------------------------------------------------------ the constructor

/// The constructor's arguments, editable before a deployment, and what the graduator says it is wired to (`None`:
/// the deployment's own peers, as it should be).
struct Args {
    usdc: Address,
    locker_interval: u64,
    external_base: String,
    policy: Policy,
    durations: MomentsDurations,
    ttl: TtlPolicy,
    graduator_moments: Option<Address>,
    graduator_executor: Option<Address>,
    graduator_locker: Option<Address>,
    graduator_factory: Option<Address>,
}

/// Deploys moments-v2 in a fresh environment with `edit` applied to valid arguments, as `setup_with` does. Returns
/// the panic message of a refused deployment.
fn construct(edit: impl FnOnce(&Env, &mut Args)) -> Result<Address, std::string::String> {
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    let a = Address::generate(&e);
    let mut args = Args {
        usdc: e.register_stellar_asset_contract_v2(Address::generate(&e)).address(),
        locker_interval: PRODUCTION_MOMENTS_DURATIONS.harvest_interval,
        external_base: String::from_str(&e, BASE),
        policy: testnet_policy(&a, &a),
        durations: PRODUCTION_MOMENTS_DURATIONS,
        ttl: TESTNET_TTL_POLICY,
        graduator_moments: None,
        graduator_executor: None,
        graduator_locker: None,
        graduator_factory: None,
    };
    edit(&e, &mut args);
    let id = Address::generate(&e);
    // The executor and the Soroswap factory moments-v2 is given are `a`.
    let locker = e.register(lp_locker::WASM, (vec![&e, id.clone()], a.clone(), None::<Address>, args.locker_interval));
    let coin_wasm = e.deployer().upload_contract_wasm(moment_coin::WASM);
    let wiring = (
        args.graduator_moments.unwrap_or(id.clone()),
        coin_wasm,
        args.graduator_executor.unwrap_or(a.clone()),
        args.graduator_locker.unwrap_or(locker.clone()),
        args.graduator_factory.unwrap_or(a.clone()),
    );
    let graduator = e.register(TestGraduator, wiring);
    let nft_wasm = e.deployer().upload_contract_wasm(moment_nft::WASM);
    let deployed = catch_unwind(AssertUnwindSafe(|| {
        e.register_at(
            &id,
            MomentsV2,
            (
                a.clone(),
                None::<Address>,
                args.usdc,
                nft_wasm,
                graduator,
                locker,
                a.clone(),
                a.clone(),
                args.external_base,
                args.policy,
                args.durations,
                args.ttl,
            ),
        )
    }));
    deployed.map_err(|panic| {
        panic
            .downcast_ref::<std::string::String>()
            .cloned()
            .or_else(|| panic.downcast_ref::<&str>().map(|s| std::string::String::from(*s)))
            .unwrap_or_default()
    })
}

/// Whether a refused deployment failed with `error`.
fn refused_with(r: Result<Address, std::string::String>, error: Error) -> bool {
    match r {
        Ok(_) => false,
        Err(message) => message.contains(&std::format!("Error(Contract, #{})", error as u32)),
    }
}

#[test]
fn the_constructor_records_its_peers_and_starts_unpaused() {
    let t = setup();
    assert_eq!(
        t.m().config(),
        Config {
            governance: t.governance.clone(),
            guardian: Some(t.guardian.clone()),
            usdc: t.usdc.clone(),
            nft_wasm_hash: t.nft_wasm.clone(),
            coin_wasm_hash: t.coin_wasm.clone(),
            graduator: t.graduator.clone(),
            locker: t.locker.clone(),
            executor: t.executor.clone(),
            soroswap_factory: t.factory.clone(),
            external_base: t.s(BASE),
            publishing_paused: false,
            guardian_paused: false,
            durations: PRODUCTION_MOMENTS_DURATIONS,
            ttl: TESTNET_TTL_POLICY,
        }
    );
    assert_eq!(t.m().policy(), testnet_policy(&t.platform, &t.treasury));
    assert_eq!((t.m().pending_policy(), t.m().pending_governance()), (None, None));
    assert_eq!(t.m().error_tag(), 7);
    // testnet-qa's durations deploy with a 60 s locker.
    assert_eq!(setup_with(TESTNET_QA_MOMENTS_DURATIONS).m().config().durations, TESTNET_QA_MOMENTS_DURATIONS);
}

#[test]
fn the_constructor_refuses_a_locker_with_another_harvest_interval() {
    // F6: the interval the phone sees in the terms is the one the locker enforces.
    assert!(construct(|_, _| {}).is_ok());
    assert!(refused_with(construct(|_, a| a.locker_interval = 60), Error::InvalidConfig));
    assert!(refused_with(construct(|_, a| a.durations = TESTNET_QA_MOMENTS_DURATIONS), Error::InvalidConfig));
    assert!(construct(|_, a| {
        a.durations = TESTNET_QA_MOMENTS_DURATIONS;
        a.locker_interval = 60;
    })
    .is_ok());
}

#[test]
fn the_constructor_refuses_a_graduator_wired_to_other_peers() {
    // Lead ruling after review: the graduator must serve this moments-v2, with this constructor's locker, executor
    // and Soroswap factory, so a mis-wired stack can't be deployed.
    assert!(construct(|_, _| {}).is_ok());
    let edits: [fn(&Env, &mut Args); 4] = [
        |e, a| a.graduator_moments = Some(Address::generate(e)),
        |e, a| a.graduator_executor = Some(Address::generate(e)),
        |e, a| a.graduator_locker = Some(Address::generate(e)),
        |e, a| a.graduator_factory = Some(Address::generate(e)),
    ];
    for edit in edits {
        assert!(refused_with(construct(edit), Error::InvalidConfig));
    }
}

#[test]
fn the_constructor_refuses_invalid_arguments() {
    // USDC must be a Stellar Asset Contract: an address with nothing behind it or a Wasm token is refused.
    assert!(refused_with(construct(|e, a| a.usdc = Address::generate(e)), Error::InvalidConfig));
    assert!(refused_with(
        construct(|e, a| a.usdc = e.register(
            TestGraduator,
            (a.usdc.clone(), BytesN::from_array(e, &[0; 32]), a.usdc.clone(), a.usdc.clone(), a.usdc.clone())
        )),
        Error::InvalidConfig
    ));
    // Durations: the backstop must lie at least 4 × stuck_expiry out (V11), every value in range.
    assert!(refused_with(
        construct(|_, a| a.durations.pending_backstop = 4 * a.durations.stuck_expiry - 1),
        Error::InvalidConfig
    ));
    assert!(construct(|_, a| a.durations.pending_backstop = 4 * a.durations.stuck_expiry).is_ok());
    assert!(refused_with(construct(|_, a| a.durations.vest_period = 59), Error::InvalidConfig));
    assert!(refused_with(construct(|_, a| a.durations.min_window = a.durations.max_window + 1), Error::InvalidConfig));
    // The TTL policy.
    assert!(refused_with(construct(|_, a| a.ttl.threshold = a.ttl.extend_to), Error::InvalidConfig));
    assert!(refused_with(construct(|e, a| a.ttl.extend_to = e.storage().max_ttl() + 1), Error::InvalidConfig));
    // The external base.
    assert!(refused_with(
        construct(|e, a| a.external_base = String::from_str(e, "http://dyorhq.fun/")),
        Error::InvalidConfig
    ));
    // The policy.
    assert!(refused_with(construct(|_, a| a.policy.reserve_bps = 0), Error::InvalidPolicy));
    assert!(refused_with(construct(|_, a| a.policy.threshold = MAX_THRESHOLD + 1), Error::InvalidPolicy));
}

// ------------------------------------------------------------------------------------------------ collect

#[test]
fn the_terminal_collect_lands_the_reserve_exactly_on_the_threshold() {
    // I-M1, at a price that doesn't divide the completion gross: 3 USDC an edition, completion 13.3333334.
    let t = setup();
    let p = PublishParams { price: 3 * ONE, ..t.params() };
    let nft = t.publish_with(&p);
    let m = t.m().get_moment(&nft);
    t.collect(&t.bob, &nft, 2); // 6 USDC: 4.5 to the reserve
    let remaining = T10 - t.ledger(&nft).reserve;
    assert_eq!(remaining, 55 * ONE / 10);

    // Alice asks for 20 editions (60 USDC); only the completion is taken.
    let gross = mul_div_up(remaining, BPS as i128, RESERVE_BPS as i128);
    let q = t.m().quote(&nft, &20);
    let expected = CollectQuote {
        gross,
        editions: 3, // ceil(7.3333334 / 3)
        entitlement: entitlement(&m, gross),
        reserve_in: remaining,
        creator_in: gross - remaining - gross * 500 / 10_000,
        platform_in: gross * 500 / 10_000,
        excess: 60 * ONE - gross,
        terminal: true,
    };
    assert_eq!(q, expected);
    let r = t.m().collect(&t.alice, &nft, &20, &(60 * ONE));
    let events = t.events();
    assert_eq!(r, CollectResult { first_rank: 3, editions: 3, gross, entitlement: q.entitlement });
    // The excess never left Alice's wallet.
    assert_eq!(t.usdc_of(&t.alice), FUNDS - gross);
    let l = t.ledger(&nft);
    assert_eq!((l.reserve, l.state, l.completed_at, l.editions), (T10, State::GraduationPending, t.now(), 5));
    assert_eq!(l.total_gross, 6 * ONE + gross);
    // I-M2: moments-v2 holds exactly what its ledger owes.
    assert_eq!(t.usdc_of(&t.id), l.reserve + l.creator_claimable + l.platform_claimable + l.treasury_claimable);
    assert_eq!(
        events[1],
        Completed { nft: nft.clone(), reserve: T10, total_gross: l.total_gross, completed_at: t.now() }
            .to_xdr(&t.e, &t.id)
    );
    // Nothing graduates inside the collect (L3): the Moment waits, and collecting is over.
    assert_eq!(t.nft(&nft).edition_size(), None);
    assert_eq!(failure(t.m().try_collect(&t.bob, &nft, &1, &ONE)), err(Error::NotCollecting));
    assert_eq!(failure(t.m().try_quote(&nft, &1)), err(Error::NotCollecting));
}

#[test]
fn the_first_collect_at_the_price_ceiling_completes_with_one_edition() {
    let t = setup();
    let nft = t.publish_with(&PublishParams { price: COMPLETION, ..t.params() });
    let r = t.m().collect(&t.alice, &nft, &5, &(5 * COMPLETION));
    assert_eq!((r.editions, r.gross), (1, COMPLETION));
    assert_eq!(t.ledger(&nft).reserve, T10);
    assert_eq!(t.usdc_of(&t.alice), FUNDS - COMPLETION);
}

#[test]
fn the_collect_event_and_its_auth_tree() {
    let t = setup();
    let nft = t.publish();
    let m = t.m().get_moment(&nft);
    t.m().collect(&t.alice, &nft, &2, &(2 * ONE));
    // The collector signs exactly the collect and the USDC pull of the gross (what the phone's verifier binds).
    assert_eq!(
        t.e.auths(),
        std::vec![(
            t.alice.clone(),
            AuthorizedInvocation {
                function: AuthorizedFunction::Contract((
                    t.id.clone(),
                    Symbol::new(&t.e, "collect"),
                    (t.alice.clone(), nft.clone(), 2u32, 2 * ONE).into_val(&t.e),
                )),
                sub_invocations: std::vec![AuthorizedInvocation {
                    function: AuthorizedFunction::Contract((
                        t.usdc.clone(),
                        symbol_short!("transfer"),
                        (t.alice.clone(), t.id.clone(), 2 * ONE).into_val(&t.e),
                    )),
                    sub_invocations: std::vec![],
                }],
            }
        )]
    );
    let event = Collected {
        nft: nft.clone(),
        collector: t.alice.clone(),
        gross: 2 * ONE,
        editions: 2,
        first_rank: 1,
        entitlement: entitlement(&m, 2 * ONE),
        reserve_in: 15 * ONE / 10,
        creator_in: 4 * ONE / 10,
        platform_in: ONE / 10,
        excess: 0,
        reserve: 15 * ONE / 10,
    };
    assert_eq!(t.events(), [event.to_xdr(&t.e, &t.id)]);
}

#[test]
fn the_bundle_rate_matches_monads_vector() {
    let t = setup();
    // §14.5: at T = 771.4285714 USDC and a 10% allocation, 6.75e22 / 1.35e18 coin units per USDC unit.
    let threshold = 7_714_285_714;
    let (num, den) = t.m().bundle_rate(&threshold, &RESERVE_BPS, &1_000);
    assert_eq!(num, SUPPLY * 9_000 * 7_500);
    assert_eq!(num, 67_500_000_000_000_000_000_000);
    assert_eq!(den, 10_000 * threshold * 17_500);
    // 50,000 coins per USDC. At 7 dp the threshold is 771.428571428… rounded down, so one USDC buys 18 coin units
    // (1.8e-6 coins) more.
    assert_eq!(mul_div(ONE, num, den), 50_000 * ONE + 18);
    // Shares at every threshold (§14.5): collectors 51.43%, the pool 38.57%, the creator 10%.
    let (num, den) = t.m().bundle_rate(&T10, &RESERVE_BPS, &1_000);
    let collectors = mul_div(COMPLETION, num, den);
    let pool = SUPPLY - SUPPLY / 10 - collectors;
    assert_eq!((collectors * 10_000 / SUPPLY, pool * 10_000 / SUPPLY), (5_142, 3_857));
    // Collectors pay the price the pool opens at: reserve/pool == 1/rate, within rounding.
    assert!((T10 * num - pool * den).abs() * 1_000_000 <= pool * den);
    // Outside the policy bounds the view refuses.
    for (threshold, reserve, alloc) in [
        (MIN_THRESHOLD - 1, RESERVE_BPS, 0),
        (MAX_THRESHOLD + 1, RESERVE_BPS, 0),
        (T10, 0, 0),
        (T10, 10_001, 0),
        (T10, RESERVE_BPS, 1_001),
    ] {
        assert_eq!(failure(t.m().try_bundle_rate(&threshold, &reserve, &alloc)), err(Error::InvalidPolicy));
    }
    // Publish snapshots the rate of its allocation.
    let nft = t.publish_with(&PublishParams { creator_alloc_bps: 400, ..t.params() });
    let m = t.m().get_moment(&nft);
    assert_eq!((m.rate_num, m.rate_den), t.m().bundle_rate(&T10, &RESERVE_BPS, &400));
}

#[test]
fn collect_writes_stay_within_the_budget() {
    // §18.3's write ceilings: collect × 1 ≤ 25 entries, collect × 20 ≤ 40.
    let t = setup();
    let nft = t.publish_with(&PublishParams { price: ONE / 10, ..t.params() });
    t.collect(&t.alice, &nft, 1);
    let one = t.e.cost_estimate().resources();
    t.collect(&t.bob, &nft, MAX_BATCH);
    let twenty = t.e.cost_estimate().resources();
    assert!(one.write_entries <= 25, "{one:?}");
    assert!(twenty.write_entries <= 40, "{twenty:?}");
}

#[test]
fn random_collects_land_on_the_threshold_and_conserve_every_unit() {
    // I-M1 and I-M3's identity over random policies, prices and collect sequences, through the same quote collect
    // uses. pool_coins (what graduation seeds) stays positive and within Monad's rounding bound of the pool the
    // reserve implies at the bundle rate (MomentCollect.sol:284-289).
    let strategy = (
        prop_oneof![MIN_THRESHOLD..=1_000 * ONE, MIN_THRESHOLD..=MAX_THRESHOLD],
        prop_oneof![1u32..=100, 1u32..=BPS],
        0u32..=MAX_CREATOR_ALLOC_BPS,
        any::<u64>(),
        proptest::collection::vec(1u32..=MAX_BATCH, 1..120),
    );
    TestRunner::new(RunnerConfig { cases: 1_000, failure_persistence: None, ..RunnerConfig::default() })
        .run(&strategy, |(threshold, reserve_bps, alloc_bps, seed, qtys)| {
            // A fresh host per case: the U256 intermediates of every quote stay allocated until it is dropped.
            let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
            e.cost_estimate().budget().reset_unlimited();
            let a = Address::generate(&e);
            let platform_bps = (seed % (BPS - reserve_bps + 1) as u64) as u32;
            let ceiling = price_ceiling(threshold, reserve_bps);
            let price = MIN_MIN_PRICE + (seed >> 20) as i128 % (ceiling - MIN_MIN_PRICE + 1);
            let (rate_num, rate_den) = bundle_rate(threshold, reserve_bps, alloc_bps);
            let m = Moment {
                nft: a.clone(),
                creator: a.clone(),
                platform: a.clone(),
                treasury: a.clone(),
                coin: a.clone(),
                price,
                threshold,
                rate_num,
                rate_den,
                creator_bps: BPS - reserve_bps - platform_bps,
                platform_bps,
                reserve_bps,
                creator_alloc_bps: alloc_bps,
                expiry_creator_bps: 7_000,
                royalty_bps: 0,
                nonce: 0,
                published_at: 0,
                deadline: u64::MAX,
            };
            let mut l = Ledger::new();
            for qty in qtys {
                if l.state != State::Collecting {
                    break;
                }
                let q = quote_collect(&e, &m, &l, qty, 1);
                prop_assert!(q.gross > 0 && q.reserve_in >= 0 && q.platform_in >= 0 && q.creator_in >= 0);
                prop_assert_eq!(q.reserve_in + q.platform_in + q.creator_in, q.gross);
                prop_assert_eq!(q.gross + q.excess, price * qty as i128);
                prop_assert!(q.editions >= 1 && q.editions <= qty);
                if q.terminal {
                    prop_assert!(price * (q.editions as i128 - 1) < q.gross && q.gross <= price * q.editions as i128);
                } else {
                    prop_assert_eq!((q.excess, q.editions), (0, qty));
                }
                l.reserve += q.reserve_in;
                l.total_gross += q.gross;
                l.entitlements += q.entitlement;
                l.collects += 1;
                if q.terminal {
                    l.state = State::GraduationPending;
                    // I-M1: exactly the threshold.
                    prop_assert_eq!(l.reserve, threshold);
                } else {
                    prop_assert!(l.reserve < threshold);
                }
            }
            let alloc = mul_div(SUPPLY, alloc_bps as i128, BPS as i128);
            let pool_coins = SUPPLY - alloc - l.entitlements;
            prop_assert!(pool_coins > 0, "nothing left for the pool");
            if l.state == State::GraduationPending {
                let implied = mul_div(threshold, rate_num, rate_den);
                let per_collect = mul_div_up(rate_num, BPS as i128, rate_den * reserve_bps as i128) + 1;
                let collects = l.collects as i128;
                prop_assert!(implied - pool_coins <= collects * per_collect, "{} {} {}", implied, pool_coins, collects);
                prop_assert!(pool_coins - implied <= collects + 2, "{} {} {}", implied, pool_coins, collects);
            }
            Ok(())
        })
        .unwrap();
}

// ------------------------------------------------------------------------------------------------ graduation

#[test]
fn graduation_deploys_the_predicted_coin_seeds_the_pool_and_locks_the_lp() {
    let t = setup();
    let nft = t.publish();
    let m = t.m().get_moment(&nft);
    t.collect(&t.creator, &nft, 2);
    t.complete(&nft);
    let pending = t.ledger(&nft);
    let alloc = alloc_of(&m);
    let pool_coins = SUPPLY - alloc - pending.entitlements;
    t.advance(10);
    let outcome = t.graduate(&nft);
    let events = t.events();

    let pair = soroswap_factory::Client::new(&t.e, &t.factory).get_pair(&m.coin, &t.usdc);
    assert_eq!(outcome, GraduationOutcome::Graduated(pair.clone()));
    // The graduator was asked for exactly this Moment's reserve, pool coins, names and predicted coin.
    let asked = MomentGradArgs {
        nft: nft.clone(),
        usdc: t.usdc.clone(),
        reserve: T10,
        pool_coins,
        name: t.s(NAME),
        symbol: t.s(SYMBOL),
        expected_coin: m.coin.clone(),
    };
    assert_eq!(t.grad().last_args(), Some(asked));

    // The coin lives at the address predicted at publish, capped at S, minted by moments-v2 only (I-M3).
    let coin = t.coin(&m.coin);
    assert_eq!(coin.total_supply(), pool_coins);
    assert_eq!(pool_coins + alloc + pending.entitlements, SUPPLY);
    assert_eq!((coin.cap(), coin.minter(), coin.name(), coin.symbol()), (SUPPLY, t.id.clone(), t.s(NAME), t.s(SYMBOL)));
    // The pool opens at the price collectors paid: reserve/pool_coins == 1/rate, within 1e-6.
    let pair_client = soroswap_pair::Client::new(&t.e, &pair);
    let (r0, r1) = pair_client.get_reserves();
    let (coins, usdc) = if pair_client.token_0() == m.coin { (r0, r1) } else { (r1, r0) };
    assert_eq!((coins, usdc), (pool_coins, T10));
    assert!((T10 * m.rate_num - pool_coins * m.rate_den).abs() * 1_000_000 <= pool_coins * m.rate_den);

    // The locker holds the LP, registered by moments-v2 at 6,667 bps for this Moment.
    let pos = t.locker().position(&pair).unwrap();
    let liquidity = TokenClient::new(&t.e, &pair).balance(&t.locker);
    assert_eq!(pos.owner, t.id);
    assert_eq!(pos.kind, lp_locker::VenueKind::Soroswap);
    assert_eq!((pos.lp_token, pos.base, pos.quote), (pair.clone(), m.coin.clone(), t.usdc.clone()));
    assert_eq!(pos.reference, lp_locker::PositionRef::Moment(nft.clone()));
    assert_eq!((pos.harvest_bps, pos.lp, pos.last_harvest), (MOMENT_HARVEST_BPS, liquidity, t.now()));
    assert_eq!(liquidity, pair_client.total_supply() - 1_000);

    let l = t.ledger(&nft);
    assert_eq!((l.state, l.stuck_since, l.graduated_at, l.ended_at), (State::Graduated, 0, t.now(), t.now()));
    assert_eq!((l.reserve, l.pool.clone(), l.liquidity, l.treasury_claimable), (0, Some(pair.clone()), liquidity, 0));
    // I-M2: the reserve left; the collect shares stay claimable.
    assert_eq!(t.usdc_of(&t.id), l.creator_claimable + l.platform_claimable);
    // The edition size is fixed at what was collected.
    assert_eq!(t.nft(&nft).edition_size(), Some(l.editions));
    let event = GraduationSucceeded {
        nft: nft.clone(),
        coin: m.coin.clone(),
        pool: pair.clone(),
        lp_token: pair,
        liquidity,
        pool_coins,
        coin_used: pool_coins,
        usdc_used: T10,
        usdc_returned: 0,
    };
    assert_eq!(events, [event.to_xdr(&t.e, &t.id)]);
    let supply = t.m().supply_check(&nft);
    assert_eq!(
        (supply.entitlements, supply.creator_alloc, supply.pool_coins, supply.minted_by_vesting),
        (pending.entitlements, alloc, pool_coins, 0)
    );
}

#[test]
fn graduate_needs_a_pending_moment() {
    let t = setup();
    let nft = t.publish();
    assert_eq!(t.try_graduate(&nft), Err(err(Error::WrongState)));
    assert_eq!(t.try_graduate(&Address::generate(&t.e)), Err(err(Error::UnknownMoment)));
    t.complete(&nft);
    t.graduate(&nft);
    assert_eq!(t.try_graduate(&nft), Err(err(Error::WrongState)));
    let expired = t.publish();
    t.set_time(t.m().get_moment(&expired).deadline);
    t.m().expire(&expired);
    assert_eq!(t.try_graduate(&expired), Err(err(Error::WrongState)));
}

#[test]
fn a_graduator_graduation_invalid_is_recorded_as_origin_10_code_11003_and_nothing_else_changes() {
    // V10: the graduator's in-frame rejection reaches moments-v2 with its namespace, and its frame (the reserve pull,
    // the coin deployment, the pair, the deposit) rolls back.
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    let before = t.ledger(&nft);
    let held = t.usdc_of(&t.id);
    let coin = t.m().get_moment(&nft).coin;
    t.grad().set_mode(&GradMode::Rejects);
    t.advance(30);

    let recorded = GradFailure { origin: TAG_MOMENTS_GRADUATOR, code: 11_003 };
    assert_eq!(t.graduate(&nft), GraduationOutcome::Failed(recorded));
    assert_eq!(
        t.events(),
        [GraduationFailed { nft: nft.clone(), origin: 10, code: 11_003, stuck_since: t.now() }.to_xdr(&t.e, &t.id)]
    );
    assert_eq!(t.ledger(&nft), Ledger { stuck_since: t.now(), ..before });
    assert_eq!(t.usdc_of(&t.id), held);
    assert_eq!(t.usdc_of(&t.graduator), 0);
    assert!(!coin.exists(), "the coin deployment rolled back");
    assert!(!SoroswapFactoryClient::new(&t.e, &t.factory).pair_exists(&coin, &t.usdc));
    assert_eq!(t.nft(&nft).edition_size(), None);
    assert_eq!(t.grad().last_args(), None);
}

#[test]
fn executor_and_host_errors_are_recorded_with_their_origins() {
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    t.grad().set_mode(&GradMode::ExecutorFails);
    let first = t.now();
    assert_eq!(
        t.graduate(&nft),
        GraduationOutcome::Failed(GradFailure { origin: TAG_EXEC_SOROSWAP, code: ERR_BASE + 303 })
    );
    t.grad().set_mode(&GradMode::HostFails);
    t.advance(HOUR);
    assert_eq!(
        t.graduate(&nft),
        GraduationOutcome::Failed(GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 })
    );
    // Retries keep the first failure's clock.
    assert_eq!(
        t.events(),
        [GraduationFailed {
            nft: nft.clone(),
            origin: ORIGIN_HOST,
            code: ScErrorCode::InvalidAction as u32,
            stuck_since: first,
        }
        .to_xdr(&t.e, &t.id)]
    );
    assert_eq!(t.ledger(&nft).stuck_since, first);
}

#[test]
fn any_failed_attempt_starts_the_clock_once_and_a_success_resets_it() {
    // graduate needs nobody's signature, so the creator, a collector or a stranger records a failure the same way.
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    t.grad().set_mode(&GradMode::Rejects);
    t.advance(MINUTE);
    let first = t.now();
    t.graduate(&nft);
    for _ in 0..3 {
        t.advance(HOUR);
        assert!(matches!(t.graduate(&nft), GraduationOutcome::Failed(_)));
        assert_eq!(t.ledger(&nft).stuck_since, first);
    }
    // I-M6: a graduation clears it.
    t.grad().set_mode(&GradMode::Honest);
    t.advance(HOUR);
    assert!(matches!(t.graduate(&nft), GraduationOutcome::Graduated(_)));
    let l = t.ledger(&nft);
    assert_eq!((l.state, l.stuck_since, l.graduated_at), (State::Graduated, 0, t.now()));
}

#[test]
fn results_that_slip_past_the_graduator_abort_with_graduation_invalid() {
    // B12, V9: moments-v2 repeats the checks. Each lie aborts the whole transaction: nothing of the attempt is kept,
    // not even a recorded failure, and the Moment stays GraduationPending.
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    let before = t.ledger(&nft);
    let held = t.usdc_of(&t.id);
    let coin = t.m().get_moment(&nft).coin;
    for mode in [
        GradMode::WrongCoin,
        GradMode::UsdcSumWrong,
        GradMode::UsdcUnreported,
        GradMode::UsdcDust,
        GradMode::WrongPool,
        GradMode::CoinsShort,
        GradMode::CoinsOver,
        GradMode::LpElsewhere,
        GradMode::LpTokenNotPool,
    ] {
        t.grad().set_mode(&mode);
        assert_eq!(t.try_graduate(&nft), Err(err(Error::GraduationInvalid)), "{mode:?}");
        assert_eq!(t.ledger(&nft), before, "{mode:?}");
        assert_eq!(t.usdc_of(&t.id), held, "{mode:?}");
        assert!(!coin.exists(), "{mode:?}");
        assert_eq!(t.grad().last_args(), None, "{mode:?}");
    }
    // With the graduator fixed it graduates.
    t.grad().set_mode(&GradMode::Honest);
    assert!(matches!(t.graduate(&nft), GraduationOutcome::Graduated(_)));
}

#[test]
fn coins_left_within_one_bp_are_accepted() {
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    let pool_coins = SUPPLY - SUPPLY / 10 - t.ledger(&nft).entitlements;
    t.grad().set_mode(&GradMode::CoinDust);
    assert!(matches!(t.graduate(&nft), GraduationOutcome::Graduated(_)));
    let coin = t.m().get_moment(&nft).coin;
    // The unused coin was burned, so the supply is one unit under the identity's pool coins.
    assert_eq!(t.coin(&coin).total_supply(), pool_coins - 1);
}

/// A Soroswap pair of two other assets whose LP outweighs any Moment's, all of it held by the locker: what
/// `DecoyPool` reports.
fn decoy_pair(t: &T) -> Address {
    let (x, y) = (
        t.e.register_stellar_asset_contract_v2(Address::generate(&t.e)).address(),
        t.e.register_stellar_asset_contract_v2(Address::generate(&t.e)).address(),
    );
    let pair = soroswap_factory::Client::new(&t.e, &t.factory).create_pair(&x, &y);
    for asset in [&x, &y] {
        StellarAssetClient::new(&t.e, asset).mint(&pair, &(1_000_000 * ONE));
    }
    soroswap_pair::Client::new(&t.e, &pair).deposit(&t.locker);
    pair
}

/// A completed Moment whose graduator answers with `mode`, a lie only one of moments-v2's checks catches: the attempt
/// aborts with `GraduationInvalid` and nothing of it is kept, and the same Moment graduates once the graduator tells
/// the truth. Each of the tests below fails if its check is removed (the review's mutation run).
fn assert_only_one_check_catches(mode: GradMode) {
    let t = setup();
    // UsdcFloorLie fills half the pool from the graduator's own USDC; DecoyPool reports a pair whose LP the locker
    // holds, so the LP check passes.
    StellarAssetClient::new(&t.e, &t.usdc).mint(&t.graduator, &T10);
    t.grad().set_decoy(&decoy_pair(&t));
    let nft = t.publish();
    t.complete(&nft);
    let before = t.ledger(&nft);
    let held = t.usdc_of(&t.id);
    let coin = t.m().get_moment(&nft).coin;
    t.grad().set_mode(&mode);
    assert_eq!(t.try_graduate(&nft), Err(err(Error::GraduationInvalid)));
    assert_eq!((t.ledger(&nft), t.usdc_of(&t.id), coin.exists()), (before, held, false));
    t.grad().set_mode(&GradMode::Honest);
    assert!(matches!(t.graduate(&nft), GraduationOutcome::Graduated(_)));
}

#[test]
fn only_the_coin_floor_catches_coins_reported_unused_that_the_pool_took() {
    // V9: every pool coin seeded, 10 bp fewer reported used.
    assert_only_one_check_catches(GradMode::CoinFloorLie);
}

#[test]
fn only_the_balance_delta_catches_usdc_reported_returned_but_kept() {
    // I-M2: the reserve seeded, (reserve − 10, 10) reported, the 10 never sent back.
    assert_only_one_check_catches(GradMode::DeltaLie);
}

#[test]
fn only_the_usdc_floor_catches_a_reserve_mostly_returned() {
    // Half the reserve returned and reported truthfully, the pool topped up from the graduator's own USDC.
    assert_only_one_check_catches(GradMode::UsdcFloorLie);
}

#[test]
fn only_the_factory_check_catches_a_decoy_pool() {
    // The real pair seeded, a decoy pair (its LP at the locker) reported as the pool.
    assert_only_one_check_catches(GradMode::DecoyPool);
}

#[test]
fn the_pre_authorization_covers_exactly_one_pull_of_the_reserve() {
    // moments-v2 holds more than two reserves, so only the authorization's scope stops a second pull: the host refuses
    // it, which is a recoverable failure the Moment records (origin 99), with nothing moved.
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    let other = t.publish();
    t.collect(&t.bob, &other, 10);
    assert!(t.usdc_of(&t.id) >= 2 * T10);
    let before = t.ledger(&nft);
    let held = t.usdc_of(&t.id);
    t.grad().set_mode(&GradMode::DoublePull);
    let refused = GradFailure { origin: ORIGIN_HOST, code: ScErrorCode::InvalidAction as u32 };
    assert_eq!(t.graduate(&nft), GraduationOutcome::Failed(refused));
    assert_eq!(t.ledger(&nft), Ledger { stuck_since: t.now(), ..before });
    assert_eq!(t.usdc_of(&t.id), held);
}

#[test]
fn usdc_a_graduation_returns_is_owed_to_the_treasury() {
    // A USDC donation lands in the pair before the deposit; the graduator counts it toward the seed and returns as
    // much of the reserve, within the 1 bp dust. moments-v2 books the return for the treasury.
    let t = setup();
    let nft = t.publish();
    t.complete(&nft);
    let coin = t.m().get_moment(&nft).coin;
    StellarAssetClient::new(&t.e, &t.usdc).mint(&t.graduator, &DONATION);
    let held = t.usdc_of(&t.id);
    t.grad().set_mode(&GradMode::UsesDonation);
    let outcome = t.graduate(&nft);
    let pair = soroswap_factory::Client::new(&t.e, &t.factory).get_pair(&coin, &t.usdc);
    assert_eq!(outcome, GraduationOutcome::Graduated(pair.clone()));
    let l = t.ledger(&nft);
    assert_eq!((l.reserve, l.treasury_claimable), (0, DONATION));
    // The pool still holds the whole reserve's worth.
    assert_eq!(t.usdc_of(&pair), T10);
    // I-M2: the pool took the reserve less the donation; the rest stays here, owed to the treasury.
    assert_eq!(t.usdc_of(&t.id), held - (T10 - DONATION));
    assert_eq!(t.usdc_of(&t.id), l.creator_claimable + l.platform_claimable + l.treasury_claimable);
    assert_eq!(t.m().withdraw_treasury(&nft), DONATION);
    assert_eq!(t.usdc_of(&t.treasury), DONATION);
}

// ------------------------------------------------------------------------------------------------ harvests

#[test]
fn harvest_payees_pay_the_usdc_side_40_60_and_burn_the_coin_side() {
    let t = setup();
    let nft = t.publish();
    let reference = PositionRef::Moment(nft.clone());
    assert_eq!(failure(t.m().try_harvest_payees(&reference)), err(Error::WrongState));
    assert_eq!(failure(t.m().try_harvest_payees(&PositionRef::Launch(nft.clone()))), err(Error::WrongReference));
    assert_eq!(
        failure(t.m().try_harvest_payees(&PositionRef::Moment(Address::generate(&t.e)))),
        err(Error::UnknownMoment)
    );
    t.complete(&nft);
    t.graduate(&nft);
    let payees = t.m().harvest_payees(&reference);
    assert_eq!(
        payees,
        HarvestPayees {
            quote: vec![
                &t.e,
                Payee { to: t.creator.clone(), bps: 4_000, notify: false },
                Payee { to: t.platform.clone(), bps: 6_000, notify: false },
            ],
            base: Vec::new(&t.e),
        }
    );
    // A policy change never redirects a live Moment's harvests.
    let other = Address::generate(&t.e);
    t.change_policy(&testnet_policy(&other, &other));
    assert_eq!(t.m().harvest_payees(&reference), payees);
}

#[test]
fn a_harvest_through_the_locker_pays_the_creator_and_the_platform_and_burns_coins() {
    // The real locker against this contract's harvest_payees, after real swaps on the graduation pool.
    let t = setup();
    let nft = t.graduated();
    let m = t.m().get_moment(&nft);
    let pool = t.ledger(&nft).pool.unwrap();
    for _ in 0..4 {
        let coins = t.swap(&t.usdc, &m.coin, 3 * ONE);
        t.swap(&m.coin, &t.usdc, coins);
    }
    t.advance(t.durations.harvest_interval);
    let supply = t.coin(&m.coin).total_supply();
    let principal = t.locker().position(&pool).unwrap().principal;
    let (growth, ..) = t.locker().harvestable(&pool);
    let (creator0, platform0) = (t.usdc_of(&t.creator), t.usdc_of(&t.platform));
    let (coin_out, usdc_out) = t.locker().harvest(&pool);
    assert!(coin_out > 0 && usdc_out > 0);
    let to_creator = usdc_out * 4_000 / 10_000;
    assert_eq!(t.usdc_of(&t.creator) - creator0, to_creator);
    assert_eq!(t.usdc_of(&t.platform) - platform0, usdc_out - to_creator);
    // The coin side was burned: the supply fell by it and nobody holds it.
    assert_eq!(t.coin(&m.coin).total_supply(), supply - coin_out);
    assert_eq!(t.coin(&m.coin).balance(&t.locker), 0);
    // With MOMENT_HARVEST_BPS the principal grew by take·3,333/6,667, rounded up: compounded : harvested =
    // 3,333 : 6,667 (§8.2, V3).
    let current = principal + growth;
    let take = mul_div(growth, MOMENT_HARVEST_BPS as i128, BPS as i128).min(mul_div(
        current,
        MAX_HARVEST_ROUND_BPS as i128,
        BPS as i128,
    ));
    let ratchet = mul_div_up(take, (BPS - MOMENT_HARVEST_BPS) as i128, MOMENT_HARVEST_BPS as i128);
    let compounded = t.locker().position(&pool).unwrap().principal - principal;
    assert!(take > 0);
    assert_eq!(compounded, ratchet.min(current - take - principal));
}

// ------------------------------------------------------------------------------------------------ expiry

#[test]
fn a_collecting_moment_expires_at_its_deadline_70_30() {
    let t = setup();
    let nft = t.publish();
    let m = t.m().get_moment(&nft);
    t.collect(&t.alice, &nft, 4);
    t.set_time(m.deadline - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(m.deadline);
    let reserve = t.ledger(&nft).reserve;
    t.m().expire(&nft);
    let creator_share = reserve * 7_000 / 10_000;
    assert_eq!(
        t.events(),
        [Expired {
            nft: nft.clone(),
            reserve,
            creator_share,
            treasury_share: reserve - creator_share,
            backstop: false
        }
        .to_xdr(&t.e, &t.id)]
    );
    let l = t.ledger(&nft);
    assert_eq!((l.state, l.reserve, l.ended_at), (State::Expired, 0, t.now()));
    // The creator gets its collect shares plus 70% of the reserve; the treasury the rest. Collectors keep their
    // editions and get nothing back (Monad's rule).
    assert_eq!(l.creator_claimable, 4 * ONE * 2_000 / 10_000 + creator_share);
    assert_eq!(l.treasury_claimable, reserve - creator_share);
    assert_eq!(t.nft(&nft).edition_size(), Some(4));
    assert_eq!(t.nft(&nft).balance(&t.alice), 4);
    assert_eq!(t.m().withdraw_treasury(&nft), reserve - creator_share);
    assert_eq!(t.usdc_of(&t.treasury), reserve - creator_share);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::WrongState));
    assert_eq!(failure(t.m().try_collect(&t.alice, &nft, &1, &ONE)), err(Error::NotCollecting));
    // A Moment nobody collected closes at 0 editions.
    let empty = t.publish();
    t.set_time(t.m().get_moment(&empty).deadline);
    t.m().expire(&empty);
    assert_eq!(t.nft(&empty).edition_size(), Some(0));
}

/// A Moment published with a `window`-second collect window and completed `after` seconds later.
fn completed(t: &T, window: u64, after: u64) -> Address {
    let nft = t.publish_with(&PublishParams { window_secs: window, ..t.params() });
    t.advance(after);
    t.complete(&nft);
    nft
}

#[test]
fn without_a_recorded_failure_a_pending_moment_waits_for_the_backstop() {
    // V11, I-M7, I-M8 with the production durations: no attempt ever recorded (the keeper's simulations only ever
    // aborted). The backstop is 30 d after completion, never before the deadline.
    let t = setup();
    let d = t.durations;
    let nft = completed(&t, 2 * DAY, HOUR);
    let completed_at = t.ledger(&nft).completed_at;
    let deadline = t.m().get_moment(&nft).deadline;
    t.set_time(deadline);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.stuck_expiry);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.pending_backstop - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.pending_backstop);
    t.m().expire(&nft);
    let creator_share = T10 * 7_000 / 10_000;
    assert_eq!(
        t.events(),
        [Expired {
            nft: nft.clone(),
            reserve: T10,
            creator_share,
            treasury_share: T10 - creator_share,
            backstop: true
        }
        .to_xdr(&t.e, &t.id)]
    );
    assert_eq!(t.ledger(&nft).state, State::Expired);
}

#[test]
fn the_backstop_never_comes_before_the_deadline() {
    // testnet-qa's backstop is 30 min, far inside a one-day window.
    let t = setup_with(TESTNET_QA_MOMENTS_DURATIONS);
    let d = t.durations;
    let nft = completed(&t, DAY, MINUTE);
    let completed_at = t.ledger(&nft).completed_at;
    let deadline = t.m().get_moment(&nft).deadline;
    t.set_time(completed_at + d.pending_backstop - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.pending_backstop);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(deadline - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(deadline);
    t.m().expire(&nft);
    assert_eq!(t.ledger(&nft).state, State::Expired);
}

#[test]
fn a_recorded_failure_makes_a_pending_moment_expirable_after_stuck_expiry() {
    // The graduator's own GraduationInvalid starts the clock (F15); expiry follows stuck_expiry later, once the
    // deadline has passed, with the 70/30 split.
    let t = setup();
    let d = t.durations;
    let nft = completed(&t, 2 * DAY, HOUR);
    t.grad().set_mode(&GradMode::Rejects);
    t.advance(HOUR);
    t.graduate(&nft);
    let stuck = t.ledger(&nft).stuck_since;
    assert_eq!(stuck, t.now());
    let deadline = t.m().get_moment(&nft).deadline;
    t.set_time(deadline);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(stuck + d.stuck_expiry - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(stuck + d.stuck_expiry);
    t.m().expire(&nft);
    let events = t.events();
    let l = t.ledger(&nft);
    let creator_share = T10 * 7_000 / 10_000;
    assert_eq!((l.state, l.treasury_claimable), (State::Expired, T10 - creator_share));
    assert_eq!(
        events,
        [Expired {
            nft: nft.clone(),
            reserve: T10,
            creator_share,
            treasury_share: T10 - creator_share,
            backstop: false
        }
        .to_xdr(&t.e, &t.id)]
    );
    assert_eq!(t.nft(&nft).edition_size(), Some(l.editions));
    assert_eq!(t.try_graduate(&nft), Err(err(Error::WrongState)));
}

#[test]
fn a_recorded_failure_never_lets_a_moment_expire_before_its_deadline() {
    let t = setup_with(TESTNET_QA_MOMENTS_DURATIONS);
    let d = t.durations;
    let nft = completed(&t, DAY, MINUTE);
    t.grad().set_mode(&GradMode::ExecutorFails);
    t.graduate(&nft);
    let stuck = t.ledger(&nft).stuck_since;
    t.set_time(stuck + d.stuck_expiry);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(t.m().get_moment(&nft).deadline);
    t.m().expire(&nft);
}

#[test]
fn an_aborted_attempt_records_nothing_so_only_the_backstop_expires_it() {
    // A result moments-v2 rejects aborts the transaction: no failure is recorded and stuck_since stays 0 (I-M7).
    let t = setup_with(TESTNET_QA_MOMENTS_DURATIONS);
    let d = t.durations;
    let nft = completed(&t, 2 * MINUTE, MINUTE);
    t.grad().set_mode(&GradMode::WrongPool);
    assert_eq!(t.try_graduate(&nft), Err(err(Error::GraduationInvalid)));
    assert_eq!(t.ledger(&nft).stuck_since, 0);
    let completed_at = t.ledger(&nft).completed_at;
    t.set_time(completed_at + d.stuck_expiry);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.pending_backstop - 1);
    assert_eq!(failure(t.m().try_expire(&nft)), err(Error::NotExpirable));
    t.set_time(completed_at + d.pending_backstop);
    t.m().expire(&nft);
}

// ------------------------------------------------------------------------------------------------ vesting

/// §18.1: the boundaries at one period minus one second against one period, and at 2 and 5 periods. Alice and the
/// creator both collect; the creator also holds the 10% allocation. Claims mint exactly what has vested (I-M4), and
/// with everything claimed the supply identity is exact (I-M3).
fn vesting_boundaries(durations: MomentsDurations) {
    let t = setup_with(durations);
    let p = durations.vest_period;
    let nft = t.publish();
    let m = t.m().get_moment(&nft);
    t.collect(&t.creator, &nft, 3);
    t.complete(&nft);
    t.graduate(&nft);
    let g = t.ledger(&nft).graduated_at;
    let alice = t.m().position(&nft, &t.alice).entitlement;
    let own = t.m().position(&nft, &t.creator).entitlement;
    let alloc = alloc_of(&m);
    let coin = t.coin(&m.coin);
    let vested = |amount: i128, bps: u32| amount * bps as i128 / 10_000;

    // (time, collectors' bps, the creator's bps)
    let schedule = [
        (g, 6_000, 2_000),
        (g + p - 1, 6_000, 2_000),
        (g + p, 8_000, 3_600),
        (g + 2 * p - 1, 8_000, 3_600),
        (g + 2 * p, 10_000, 5_200),
        (g + 5 * p - 1, 10_000, 8_400),
        (g + 5 * p, 10_000, 10_000),
        (g + 9 * p, 10_000, 10_000),
    ];
    for (at, collector_bps, creator_bps) in schedule {
        t.set_time(at);
        let periods = (at - g) / p;
        assert_eq!((collector_vested_bps(periods), creator_vested_bps(periods)), (collector_bps, creator_bps));
        let alice_due = vested(alice, collector_bps) - coin.balance(&t.alice);
        let creator_held = coin.balance(&t.creator);
        let creator_due = vested(own, collector_bps) + vested(alloc, creator_bps) - creator_held;
        let (c, k) = t.m().claimable(&nft, &t.creator);
        assert_eq!(c + k, creator_due, "at {}", at - g);
        assert_eq!(t.m().claimable(&nft, &t.alice), (alice_due, 0), "at {}", at - g);
        if alice_due > 0 {
            assert_eq!(t.m().claim(&t.alice, &nft), (alice_due, 0));
        } else {
            assert_eq!(failure(t.m().try_claim(&t.alice, &nft)), err(Error::NothingToClaim));
        }
        if creator_due > 0 {
            let (c, k) = t.m().claim(&t.creator, &nft);
            assert_eq!(c + k, creator_due);
        } else {
            assert_eq!(failure(t.m().try_claim(&t.creator, &nft)), err(Error::NothingToClaim));
        }
        // I-M4: what has been minted is exactly what has vested, never more.
        assert_eq!(coin.balance(&t.alice), vested(alice, collector_bps));
        assert_eq!(coin.balance(&t.creator), vested(own, collector_bps) + vested(alloc, creator_bps));
        assert_eq!(t.m().position(&nft, &t.alice).claimed, coin.balance(&t.alice));
        assert_eq!(t.m().claimable(&nft, &t.alice), (0, 0));
    }
    // Everything vested: the coins ever minted are exactly S.
    let l = t.ledger(&nft);
    assert_eq!((l.creator_claimed, l.minted_by_vesting), (alloc, alloc + l.entitlements));
    assert_eq!(coin.total_supply(), SUPPLY);
}

#[test]
fn vesting_boundaries_with_the_production_durations() {
    vesting_boundaries(PRODUCTION_MOMENTS_DURATIONS);
}

#[test]
fn vesting_boundaries_with_the_testnet_qa_durations() {
    vesting_boundaries(TESTNET_QA_MOMENTS_DURATIONS);
}

#[test]
fn collecting_twice_adds_both_entitlements_and_both_vest() {
    let t = setup();
    let nft = t.publish();
    let first = t.collect(&t.alice, &nft, 3);
    let second = t.collect(&t.alice, &nft, 2);
    let alice = first.entitlement + second.entitlement;
    assert!(first.entitlement > 0 && second.entitlement > 0);
    assert_eq!(t.m().position(&nft, &t.alice), Position { entitlement: alice, claimed: 0 });
    let last = t.complete_by(&t.bob, &nft);
    let entitlements = t.ledger(&nft).entitlements;
    assert_eq!(entitlements, alice + last.entitlement);
    t.graduate(&nft);
    let m = t.m().get_moment(&nft);
    // Everything vested: both collects' coins reach Alice, and the coins ever minted are exactly S.
    t.advance(CREATOR_PERIODS * t.durations.vest_period);
    assert_eq!(t.m().claim(&t.alice, &nft), (alice, 0));
    assert_eq!(t.m().claim(&t.bob, &nft), (last.entitlement, 0));
    assert_eq!(t.m().claim(&t.creator, &nft), (0, alloc_of(&m)));
    let coin = t.coin(&m.coin);
    assert_eq!(coin.balance(&t.alice), alice);
    assert_eq!(t.m().position(&nft, &t.alice), Position { entitlement: alice, claimed: alice });
    assert_eq!(t.ledger(&nft).minted_by_vesting, alloc_of(&m) + entitlements);
    assert_eq!(coin.total_supply(), SUPPLY);
}

#[test]
fn claims_need_a_graduated_moment_and_the_accounts_signature() {
    let t = setup();
    let nft = t.publish();
    t.collect(&t.alice, &nft, 2);
    assert_eq!(failure(t.m().try_claim(&t.alice, &nft)), err(Error::WrongState));
    assert_eq!(t.m().claimable(&nft, &t.alice), (0, 0));
    assert_eq!(failure(t.m().try_claim(&t.alice, &Address::generate(&t.e))), err(Error::UnknownMoment));
    t.complete(&nft);
    assert_eq!(failure(t.m().try_claim(&t.alice, &nft)), err(Error::WrongState));
    t.graduate(&nft);
    // A stranger has nothing; Bob can't claim for Alice.
    assert_eq!(failure(t.m().try_claim(&t.bob, &nft)), err(Error::NothingToClaim));
    let args = (t.alice.clone(), nft.clone()).into_val(&t.e);
    assert!(t.signed_by(&t.bob, "claim", args, || refused(|| t.m().claim(&t.alice, &nft))));
    let (c, _) = t.m().claim(&t.alice, &nft);
    assert_eq!(
        t.events(),
        [VestingClaimed { nft: nft.clone(), account: t.alice.clone(), collector_amount: c, creator_amount: 0 }
            .to_xdr(&t.e, &t.id)]
    );
    // An allocation of 0 leaves the creator nothing of its own.
    let none = t.publish_with(&PublishParams { creator_alloc_bps: 0, ..t.params() });
    t.complete(&none);
    t.graduate(&none);
    assert_eq!(t.m().claimable(&none, &t.creator), (0, 0));
}

#[test]
fn claim_all_covers_twenty_moments_and_refuses_more() {
    let t = setup();
    // The SDK enforces older, lower limits than the live network's (§2: 200 write entries); §18.3's ceiling is checked
    // below instead.
    t.e.cost_estimate().disable_resource_limits();
    let mut nfts = Vec::new(&t.e);
    let mut expected = 0;
    for _ in 0..20 {
        // One edition at the price ceiling completes a Moment.
        let nft = t.publish_with(&PublishParams { price: COMPLETION, ..t.params() });
        t.collect(&t.alice, &nft, 1);
        t.graduate(&nft);
        expected += t.m().position(&nft, &t.alice).entitlement * 6_000 / 10_000;
        nfts.push_back(nft);
    }
    let mut too_many = nfts.clone();
    too_many.push_back(Address::generate(&t.e));
    assert_eq!(failure(t.m().try_claim_all(&t.alice, &too_many)), err(Error::TooManyIds));
    let (claimed, written) = writes(&t.e, || t.m().claim_all(&t.alice, &nfts));
    assert_eq!(claimed, expected);
    assert_eq!(t.events().len(), 20);
    // Four writes per Moment (its ledger, Alice's position, the coin's balance and supply entries) and Alice's auth
    // nonce: §18.3 puts claim_all × 20 at 80 entries, before the signer's nonce. The network allows 200.
    let nonces = written.iter().filter(|k| is_nonce(k)).count();
    assert_eq!((written.len(), nonces), (20 * 4 + 1, 1), "{written:?}");
    assert_eq!(t.e.cost_estimate().resources().write_entries as usize, written.len());
    // Nothing is left due: the call refuses, and so does a list of unknown or ungraduated Moments.
    assert_eq!(failure(t.m().try_claim_all(&t.alice, &nfts)), err(Error::NothingToClaim));
    let open = t.publish();
    t.collect(&t.alice, &open, 1);
    let skipped = vec![&t.e, open, Address::generate(&t.e)];
    assert_eq!(failure(t.m().try_claim_all(&t.alice, &skipped)), err(Error::NothingToClaim));
    // A duplicate is claimed once.
    t.advance(t.durations.vest_period);
    let first = nfts.get_unchecked(0);
    let due = t.m().claimable(&first, &t.alice).0;
    assert_eq!(t.m().claim_all(&t.alice, &vec![&t.e, first.clone(), first]), due);
}

#[test]
fn random_claim_times_never_mint_beyond_what_has_vested() {
    // I-M4 over random entitlements, allocations and increasing claim times: claimed amounts only grow, never pass
    // the vested amount, and reach the whole entitlement and allocation.
    let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
    let creator = Address::generate(&e);
    let strategy = (
        1i128..=SUPPLY / 2,
        0u32..=MAX_CREATOR_ALLOC_BPS,
        60u64..=40 * DAY,
        proptest::collection::vec(0u64..=3 * 40 * DAY, 1..12),
    );
    TestRunner::new(RunnerConfig { cases: 2_000, failure_persistence: None, ..RunnerConfig::default() })
        .run(&strategy, |(ent, alloc_bps, period, mut times)| {
            // Time only moves forward, and the last claim comes after every tranche has vested.
            times.sort_unstable();
            times.push(times[times.len() - 1].max(CREATOR_PERIODS * period));
            let m = Moment {
                nft: creator.clone(),
                creator: creator.clone(),
                platform: creator.clone(),
                treasury: creator.clone(),
                coin: creator.clone(),
                price: ONE,
                threshold: T10,
                rate_num: 1,
                rate_den: 1,
                creator_bps: 2_000,
                platform_bps: 500,
                reserve_bps: RESERVE_BPS,
                creator_alloc_bps: alloc_bps,
                expiry_creator_bps: 7_000,
                royalty_bps: 0,
                nonce: 0,
                published_at: 0,
                deadline: 0,
            };
            let mut l = Ledger { state: State::Graduated, graduated_at: 0, entitlements: ent, ..Ledger::new() };
            let mut p = Position { entitlement: ent, claimed: 0 };
            let alloc = alloc_of(&m);
            for now in times {
                let periods = now / period;
                let (c, k) = crate::vesting::due(&m, &l, &p, &creator, now, period);
                prop_assert!(c >= 0 && k >= 0);
                p.claimed += c;
                l.creator_claimed += k;
                prop_assert_eq!(p.claimed, ent * collector_vested_bps(periods) as i128 / 10_000);
                prop_assert_eq!(l.creator_claimed, alloc * creator_vested_bps(periods) as i128 / 10_000);
                prop_assert!(p.claimed + l.creator_claimed <= ent + alloc);
            }
            prop_assert_eq!((p.claimed, l.creator_claimed), (ent, alloc));
            Ok(())
        })
        .unwrap();
}

// ------------------------------------------------------------------------------------------------ withdrawals

#[test]
fn withdrawals_pay_only_the_snapshotted_beneficiaries_even_after_a_policy_change() {
    let t = setup();
    let early = t.publish_with(&PublishParams { window_secs: 30 * DAY, ..t.params() });
    let (platform2, treasury2) = (Address::generate(&t.e), Address::generate(&t.e));
    t.change_policy(&testnet_policy(&platform2, &treasury2));
    let late = t.publish();
    for nft in [&early, &late] {
        t.collect(&t.alice, nft, 4);
    }
    // Anyone may call; the money goes to the Moment's own beneficiary.
    t.e.set_auths(&[]);
    assert_eq!(t.m().withdraw_platform(&early), 4 * ONE * 500 / 10_000);
    assert_eq!(t.m().withdraw_platform(&late), 4 * ONE * 500 / 10_000);
    assert_eq!(
        t.events(),
        [Withdrawn { nft: late.clone(), role: symbol_short!("platform"), to: platform2.clone(), amount: ONE / 5 }
            .to_xdr(&t.e, &t.id)]
    );
    assert_eq!((t.usdc_of(&t.platform), t.usdc_of(&platform2)), (ONE / 5, ONE / 5));
    t.e.mock_all_auths();
    for nft in [&early, &late] {
        t.set_time(t.now().max(t.m().get_moment(nft).deadline));
        t.m().expire(nft);
    }
    let treasury_share = 3 * ONE - 3 * ONE * 7_000 / 10_000;
    assert_eq!(t.m().withdraw_treasury(&early), treasury_share);
    assert_eq!(t.m().withdraw_treasury(&late), treasury_share);
    assert_eq!((t.usdc_of(&t.treasury), t.usdc_of(&treasury2)), (treasury_share, treasury_share));
    let creator_due = 4 * ONE * 2_000 / 10_000 + 3 * ONE * 7_000 / 10_000;
    assert_eq!(t.m().withdraw_creator(&early), creator_due);
    assert_eq!(t.usdc_of(&t.creator), FUNDS + creator_due);
    // Paid out once: the next call has nothing to pay.
    for r in
        [t.m().try_withdraw_creator(&early), t.m().try_withdraw_platform(&early), t.m().try_withdraw_treasury(&early)]
    {
        assert_eq!(failure(r), err(Error::NothingToWithdraw));
    }
    assert_eq!(failure(t.m().try_withdraw_creator(&Address::generate(&t.e))), err(Error::UnknownMoment));
    // I-M2 holds with everything paid out.
    let l = t.ledger(&late);
    assert_eq!(t.usdc_of(&t.id), l.creator_claimable + l.platform_claimable + l.treasury_claimable);
}

// ------------------------------------------------------------------------------------------------ errors

#[test]
fn errors_live_in_the_moments_namespace() {
    // V10: tag 7, so every on-chain value is 10_700 + the local code of §9.4; 26 stays unused.
    let codes = [
        (Error::PublishingPaused, 1),
        (Error::TermsChanged, 2),
        (Error::NonceUsed, 30),
        (Error::GraduationInvalid, 31),
        (Error::InvalidConfig, 32),
        (Error::WrongReference, 33),
    ];
    for (error, n) in codes {
        assert_eq!(error as u32, ERR_BASE + 7 * 100 + n);
        assert_eq!(dyor_common::tag_of(error as u32), Some(dyor_common::TAG_MOMENTS_V2));
    }
}
