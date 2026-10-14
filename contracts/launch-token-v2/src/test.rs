//! launch-token-v2 (§6) against a test launchpad whose treasury can change, the real Soroswap factory and pair WASMs
//! and CT-03's Aquarius router, pool and share-token fixtures (contracts/testdata). The property test at the end
//! checks the rewards against a reference model in plain Rust (§18.2).
extern crate std;

use super::*;
use dyor_common::aquarius::{sorted_pair, AquariusRouterClient};
use soroban_sdk::testutils::{Address as _, Events as _, Ledger as _, MockAuth, MockAuthInvoke, MuxedAddress as _};
use soroban_sdk::token::{StellarAssetClient, TokenClient};
use soroban_sdk::xdr;
use soroban_sdk::{contract, vec, Event as _, Executable, IntoVal, Symbol, TryIntoVal, Val};
use std::vec::Vec as StdVec;
use stellar_tokens::fungible::{FungibleTokenError, BALANCE_EXTEND_AMOUNT};

mod soroswap_factory {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_factory.wasm");
}
mod soroswap_pair {
    soroban_sdk::contractimport!(file = "../testdata/soroswap_pair.wasm");
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
const SUPPLY: i128 = 1_000_000_000 * ONE;
/// The contract address with id 0xff…ff: a token registered there sorts after every other address.
const HIGHEST_CONTRACT: &str = "CD7777777777777777777777777777777777777777777777777767GY";

// ------------------------------------------------------------------------------------------------ stand-ins

#[contracttype]
#[derive(Clone)]
enum PadKey {
    Treasury,
}

/// Stands in for launchpad-v2: it has a treasury the token reads (`TreasurySource`), which a test can change as
/// `apply_treasury` would.
#[contract]
pub struct TestLaunchpad;

#[contractimpl]
impl TestLaunchpad {
    pub fn __constructor(e: Env, treasury: Address) {
        e.storage().instance().set(&PadKey::Treasury, &treasury);
    }

    pub fn treasury(e: Env) -> Address {
        e.storage().instance().get(&PadKey::Treasury).unwrap()
    }

    pub fn set_treasury(e: Env, treasury: Address) {
        e.storage().instance().set(&PadKey::Treasury, &treasury);
    }
}

/// A contract that answers like a Soroswap pair of (`token_0`, `token_1`) without being one.
#[contract]
pub struct FakePair;

#[contracttype]
#[derive(Clone)]
enum FakeKey {
    Tokens,
    Pair,
}

#[contractimpl]
impl FakePair {
    pub fn __constructor(e: Env, token_0: Address, token_1: Address) {
        e.storage().instance().set(&FakeKey::Tokens, &(token_0, token_1));
    }

    pub fn token_0(e: Env) -> Address {
        e.storage().instance().get::<_, (Address, Address)>(&FakeKey::Tokens).unwrap().0
    }

    pub fn token_1(e: Env) -> Address {
        e.storage().instance().get::<_, (Address, Address)>(&FakeKey::Tokens).unwrap().1
    }
}

/// A factory that names `pair` for every pair of tokens.
#[contract]
pub struct LyingFactory;

#[contractimpl]
impl LyingFactory {
    pub fn __constructor(e: Env, pair: Address) {
        e.storage().instance().set(&FakeKey::Pair, &pair);
    }

    pub fn pair_exists(_e: Env, _token_a: Address, _token_b: Address) -> bool {
        true
    }

    pub fn get_pair(e: Env, _token_a: Address, _token_b: Address) -> Address {
        e.storage().instance().get(&FakeKey::Pair).unwrap()
    }
}

/// The Aquarius router's other singletons (pools plane, config storage, reward boost feed), as exec-aquarius's tests
/// stand them in: they accept what a standard pool sends them.
#[contract]
pub struct Plane;

#[contractimpl]
impl Plane {
    pub fn update(
        _e: Env,
        _pool: Address,
        _pool_type: Symbol,
        _init_args: soroban_sdk::Vec<u128>,
        _r: soroban_sdk::Vec<u128>,
    ) {
    }
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
    pad: Address,
    locker: Address,
    venue_exec: Address,
    fallback_exec: Address,
    treasury: Address,
    issuer: Address,
    quote: Address,
    factory: Address,
    router: Address,
    id: Address,
}

#[derive(Clone, Copy, PartialEq)]
enum Venues {
    /// Placeholder addresses: nothing calls them.
    None,
    /// The Soroswap factory and the Aquarius router, configured like the testnet router.
    Fixtures,
}

/// A token with `supply`, deployed by the test launchpad with sharing on or off. Every auth is mocked.
fn setup_with(sharing: bool, venues: Venues, token_last: bool) -> T {
    let e = Env::default();
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    let treasury = Address::generate(&e);
    let pad = e.register(TestLaunchpad, (treasury.clone(),));
    let issuer = Address::generate(&e);
    let quote = e.register_stellar_asset_contract_v2(issuer.clone()).address();
    let (factory, router) = match venues {
        Venues::None => (Address::generate(&e), Address::generate(&e)),
        Venues::Fixtures => (soroswap(&e), aquarius(&e)),
    };
    let mut t = T {
        locker: Address::generate(&e),
        venue_exec: Address::generate(&e),
        fallback_exec: Address::generate(&e),
        id: pad.clone(),
        e,
        pad,
        treasury,
        issuer,
        quote,
        factory,
        router,
    };
    t.id = t.deploy(sharing, &t.factory.clone(), token_last);
    t
}

fn setup(sharing: bool) -> T {
    setup_with(sharing, Venues::None, false)
}

fn soroswap(e: &Env) -> Address {
    let pair_hash = e.deployer().upload_contract_wasm(soroswap_pair::WASM);
    let factory = e.register(soroswap_factory::WASM, ());
    soroswap_factory::Client::new(e, &factory).initialize(&Address::generate(e), &pair_hash);
    factory
}

/// The Aquarius router fixture with 1 AQUA per new standard pool (exec-aquarius's test setup).
fn aquarius(e: &Env) -> Address {
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
    router
}

impl T {
    /// Deploys a token the way launchpad-v2 does (§5.5), with `factory` as its Soroswap factory.
    fn deploy(&self, sharing: bool, factory: &Address, last: bool) -> Address {
        let e = &self.e;
        let args = self.args(sharing, factory);
        if last {
            e.register_at(&Address::from_str(e, HIGHEST_CONTRACT), LaunchTokenV2, args)
        } else {
            e.register(LaunchTokenV2, args)
        }
    }

    #[allow(clippy::type_complexity)]
    fn args(
        &self,
        sharing: bool,
        factory: &Address,
    ) -> (
        Address,
        Address,
        String,
        String,
        i128,
        soroban_sdk::Vec<Address>,
        soroban_sdk::Vec<Address>,
        Option<Address>,
        Address,
        Address,
        Address,
    ) {
        let e = &self.e;
        (
            self.pad.clone(),
            self.locker.clone(),
            String::from_str(e, "Dyor Cat"),
            String::from_str(e, "DCAT"),
            SUPPLY,
            vec![e, self.venue_exec.clone(), self.fallback_exec.clone()],
            vec![e, self.pad.clone(), self.locker.clone(), self.venue_exec.clone(), self.fallback_exec.clone()],
            if sharing { Some(self.quote.clone()) } else { None },
            factory.clone(),
            self.router.clone(),
            self.treasury.clone(),
        )
    }

    fn token(&self) -> LaunchTokenV2Client<'_> {
        LaunchTokenV2Client::new(&self.e, &self.id)
    }

    fn quote(&self) -> TokenClient<'_> {
        TokenClient::new(&self.e, &self.quote)
    }

    fn launchpad(&self) -> TestLaunchpadClient<'_> {
        TestLaunchpadClient::new(&self.e, &self.pad)
    }

    fn balance(&self, a: &Address) -> i128 {
        self.token().balance(a)
    }

    /// A new holder that bought `amount` from the curve.
    fn holder(&self, amount: i128) -> Address {
        let a = Address::generate(&self.e);
        self.token().transfer(&self.pad, &a, &amount);
        a
    }

    /// The launchpad's curve-fee path (§5.5 route_fees): transfer the quote here, then notify.
    fn notify_quote(&self, amount: i128) {
        StellarAssetClient::new(&self.e, &self.quote).mint(&self.pad, &amount);
        self.quote().transfer(&self.pad, &self.id, &amount);
        self.token().notify_reward(&self.pad, &self.quote, &amount);
    }

    /// The locker's harvest path for the launch-token side (§8.2): launch tokens to the token's own address, then
    /// notify. The locker holds no tokens before unlock, so this needs the token unlocked.
    fn notify_tokens(&self, amount: i128) {
        self.token().transfer(&self.pad, &self.locker, &amount);
        self.token().transfer(&self.locker, &self.id, &amount);
        self.token().notify_reward(&self.locker, &self.id, &amount);
    }

    fn next_ledger(&self) {
        self.e.ledger().with_mut(|l| {
            l.sequence_number += 1;
            l.timestamp += 5;
        });
    }

    fn sharing(&self) -> SharingView {
        self.token().sharing().unwrap()
    }

    fn holder_entry(&self, a: &Address) -> Option<Holder> {
        self.e.as_contract(&self.id, || self.e.storage().persistent().get(&DataKey::Holder(a.clone())))
    }

    /// I-T1 and I-T2 for both pools: the funds cover everything owed, and what isn't owed is non-negative dust.
    /// `pending_rewards` already counts a releasable queue, so the stored queue is added only while it waits, or when
    /// it would go to the protocol.
    fn assert_funded(&self, holders: &[&Address]) {
        let s = self.sharing();
        let releasable = self.e.ledger().sequence() > s.queued_ledger;
        let owed = |pick: fn((i128, i128)) -> i128| -> i128 {
            holders.iter().map(|h| pick(self.token().pending_rewards(h))).sum()
        };
        for (pool, owed, balance) in
            [(&s.q, owed(|p| p.0), self.quote().balance(&self.id)), (&s.t, owed(|p| p.1), self.balance(&self.id))]
        {
            let outstanding = pool.funded - pool.paid;
            assert!(balance >= outstanding, "I-T1: balance {balance} < outstanding {outstanding}");
            let queued = if releasable && s.eligible >= MIN_ELIGIBLE { 0 } else { pool.queued };
            assert!(owed + queued + pool.protocol_owed <= outstanding, "I-T2: owed beyond the funds");
        }
    }
}

fn err(error: Error) -> soroban_sdk::Error {
    error.into()
}

fn oz(error: FungibleTokenError) -> soroban_sdk::Error {
    error.into()
}

/// The contract error a `try_` call failed with.
fn failure<R: core::fmt::Debug, C: core::fmt::Debug>(
    r: Result<R, Result<soroban_sdk::Error, C>>,
) -> soroban_sdk::Error {
    r.unwrap_err().unwrap()
}

/// A classic account address (G…), which can't be a pool.
fn account(e: &Env, seed: u8) -> Address {
    let id = xdr::AccountId(xdr::PublicKey::PublicKeyTypeEd25519(xdr::Uint256([seed; 32])));
    xdr::ScAddress::Account(id).try_into_val(e).unwrap()
}

// ------------------------------------------------------------------------------------------------ v1, ported

#[test]
fn constructor_mints_supply_to_launchpad() {
    let t = setup(false);
    assert_eq!(t.balance(&t.pad), SUPPLY);
    assert_eq!(t.token().total_supply(), SUPPLY);
    assert_eq!(t.token().decimals(), 7);
    assert_eq!(t.token().symbol(), String::from_str(&t.e, "DCAT"));
    assert_eq!(t.token().name(), String::from_str(&t.e, "Dyor Cat"));
    assert_eq!(t.token().launchpad(), t.pad);
    assert!(!t.token().unlocked());
}

#[test]
fn launchpad_can_send_and_receive_before_unlock() {
    let t = setup(false);
    let alice = Address::generate(&t.e);
    t.token().transfer(&t.pad, &alice, &100);
    assert_eq!(t.balance(&alice), 100);
    t.token().transfer(&alice, &t.pad, &40);
    assert_eq!(t.balance(&alice), 60);
}

#[test]
fn holder_to_holder_is_locked_before_unlock() {
    let t = setup(false);
    let alice = t.holder(100);
    let bob = Address::generate(&t.e);
    assert_eq!(failure(t.token().try_transfer(&alice, &bob, &1)), err(Error::TransferLocked));
    // transfer_from is locked the same way, even with an allowance.
    t.token().approve(&alice, &bob, &50, &(t.e.ledger().sequence() + 100));
    assert_eq!(failure(t.token().try_transfer_from(&bob, &alice, &bob, &1)), err(Error::TransferLocked));
}

#[test]
fn unlock_opens_transfers_and_only_once() {
    let t = setup(false);
    let alice = t.holder(100);
    let bob = Address::generate(&t.e);
    t.token().unlock();
    assert!(t.token().unlocked());
    t.token().transfer(&alice, &bob, &30);
    assert_eq!(t.balance(&bob), 30);
    assert_eq!(failure(t.token().try_unlock()), err(Error::AlreadyUnlocked));
}

#[test]
fn unlock_requires_the_launchpad() {
    let t = setup(false);
    t.e.set_auths(&[]);
    // Nobody has authorized this call as the launchpad.
    assert!(t.token().try_unlock().is_err());
    // Someone else's signature doesn't do either.
    let mallory = Address::generate(&t.e);
    let as_mallory = MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke { contract: &t.id, fn_name: "unlock", args: ().into_val(&t.e), sub_invokes: &[] },
    };
    assert!(t.token().mock_auths(&[as_mallory]).try_unlock().is_err());
    assert!(!t.token().unlocked());
    let as_pad = MockAuth {
        address: &t.pad,
        invoke: &MockAuthInvoke { contract: &t.id, fn_name: "unlock", args: ().into_val(&t.e), sub_invokes: &[] },
    };
    t.token().mock_auths(&[as_pad]).unlock();
    assert!(t.token().unlocked());
}

#[test]
fn holders_can_burn() {
    let t = setup(false);
    let alice = t.holder(100);
    t.token().burn(&alice, &10);
    assert_eq!(t.balance(&alice), 90);
    assert_eq!(t.token().total_supply(), SUPPLY - 10);
}

// ------------------------------------------------------------------------------------------------ the lock (§6.1)

#[test]
fn every_path_of_the_lock_table_holds_before_unlock() {
    for sharing in [false, true] {
        let t = setup(sharing);
        let token = t.token();
        let (alice, bob) = (t.holder(1_000 * ONE), t.holder(1_000 * ONE));
        let pool = Address::generate(&t.e);
        let locked = |from: &Address, to: &Address| {
            assert_eq!(failure(token.try_transfer(from, to, &ONE)), err(Error::TransferLocked));
        };
        // holder → holder, → an executor, → a pool, → the locker: refused.
        locked(&alice, &bob);
        locked(&alice, &t.venue_exec);
        locked(&alice, &t.fallback_exec);
        locked(&alice, &pool);
        locked(&alice, &t.locker);
        // The locker is not exempt either (B1).
        token.transfer(&t.pad, &t.locker, &ONE);
        locked(&t.locker, &alice);
        // buy, sell.
        token.transfer(&t.pad, &alice, &ONE);
        token.transfer(&alice, &t.pad, &ONE);
        // graduation: launchpad → executor → pool, leftovers executor → launchpad; both executors.
        for exec in [&t.venue_exec, &t.fallback_exec] {
            token.transfer(&t.pad, exec, &(3 * ONE));
            token.transfer(exec, &pool, &(2 * ONE));
            token.transfer(exec, &t.pad, &ONE);
        }
        assert_eq!(t.balance(&pool), 4 * ONE);
        // A pool can't hand the token back to an executor (§6.1, B2).
        locked(&pool, &t.venue_exec);
        // refunds burn; burns are always allowed.
        token.burn(&alice, &ONE);
        token.approve(&alice, &bob, &ONE, &(t.e.ledger().sequence() + 10));
        token.burn_from(&bob, &alice, &ONE);
        assert_eq!(t.balance(&alice), 998 * ONE);
        assert!(!token.unlocked());
    }
}

#[test]
fn transfer_from_follows_the_same_lock() {
    let t = setup(true);
    let token = t.token();
    let (alice, spender) = (t.holder(10 * ONE), Address::generate(&t.e));
    let live = t.e.ledger().sequence() + 100;
    token.approve(&alice, &spender, &(10 * ONE), &live);
    token.approve(&t.pad, &spender, &(10 * ONE), &live);
    token.approve(&t.venue_exec, &spender, &(10 * ONE), &live);
    token.transfer(&t.pad, &t.venue_exec, &ONE);

    assert_eq!(failure(token.try_transfer_from(&spender, &alice, &spender, &1)), err(Error::TransferLocked));
    token.transfer_from(&spender, &alice, &t.pad, &1);
    token.transfer_from(&spender, &t.pad, &spender, &1);
    token.transfer_from(&spender, &t.venue_exec, &spender, &1);
    token.unlock();
    token.transfer_from(&spender, &alice, &spender, &1);
    assert_eq!(t.balance(&spender), 3);
}

#[test]
fn a_muxed_recipient_is_checked_by_its_address() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(10 * ONE);
    let muxed = MuxedAddress::generate(&t.e);
    let bob = muxed.address();
    assert_eq!(failure(token.try_transfer(&alice, &muxed, &ONE)), err(Error::TransferLocked));
    // From the launchpad the muxed recipient is credited at its address.
    token.transfer(&t.pad, &muxed, &ONE);
    assert_eq!(t.balance(&bob), ONE);
    token.unlock();
    token.transfer(&alice, &muxed, &ONE);
    assert_eq!(t.balance(&bob), 2 * ONE);
    // And it earns at its address.
    t.notify_quote(1_100);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&bob), (200, 0));
    assert_eq!(token.pending_rewards(&alice), (900, 0));
}

#[test]
fn the_token_account_never_sends_burns_or_approves() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(10 * ONE);
    // Transfers to the token's own address are allowed (the launchpad's, before unlock).
    token.transfer(&t.pad, &t.id, &(5 * ONE));
    let spender = Address::generate(&t.e);
    let live = t.e.ledger().sequence() + 100;
    for unlocked in [false, true] {
        if unlocked {
            token.unlock();
            // After unlock anyone may send to it.
            token.transfer(&alice, &t.id, &ONE);
        }
        assert_eq!(failure(token.try_transfer(&t.id, &alice, &1)), err(Error::TokenAccount));
        assert_eq!(failure(token.try_transfer(&t.id, &t.pad, &1)), err(Error::TokenAccount));
        assert_eq!(failure(token.try_transfer_from(&spender, &t.id, &alice, &1)), err(Error::TokenAccount));
        assert_eq!(failure(token.try_burn(&t.id, &1)), err(Error::TokenAccount));
        assert_eq!(failure(token.try_burn_from(&spender, &t.id, &1)), err(Error::TokenAccount));
        assert_eq!(failure(token.try_approve(&t.id, &spender, &1, &live)), err(Error::TokenAccount));
        assert_eq!(token.allowance(&t.id, &spender), 0);
    }
    assert_eq!(t.balance(&t.id), 6 * ONE);
}

#[test]
#[should_panic(expected = "Error(Contract, #10203)")]
fn the_constructor_refuses_a_zero_supply() {
    let t = setup(true);
    let mut args = t.args(true, &t.factory);
    args.4 = 0;
    t.e.register(LaunchTokenV2, args);
}

#[test]
fn fixed_exclusions_cover_the_launchpad_the_locker_the_executors_and_the_token() {
    for sharing in [false, true] {
        let t = setup(sharing);
        for a in [&t.pad, &t.locker, &t.venue_exec, &t.fallback_exec, &t.id] {
            assert!(t.token().is_excluded(a));
        }
        assert_eq!(t.token().lock_from(), vec![&t.e, t.venue_exec.clone(), t.fallback_exec.clone()]);
        assert_eq!(t.token().locker(), t.locker);
        assert!(!t.token().is_excluded(&Address::generate(&t.e)));
    }
    // A deployer that leaves them out of `fixed_excluded` doesn't make them eligible (I-T10), and duplicates are
    // dropped.
    let t = setup(true);
    let e = &t.e;
    let id = e.register(
        LaunchTokenV2,
        (
            t.pad.clone(),
            t.locker.clone(),
            String::from_str(e, "X"),
            String::from_str(e, "X"),
            SUPPLY,
            vec![e, t.venue_exec.clone(), t.venue_exec.clone()],
            soroban_sdk::Vec::<Address>::new(e),
            Some(t.quote.clone()),
            t.factory.clone(),
            t.router.clone(),
            t.treasury.clone(),
        ),
    );
    let token = LaunchTokenV2Client::new(e, &id);
    for a in [&t.pad, &t.locker, &t.venue_exec, &id] {
        assert!(token.is_excluded(a));
    }
    assert_eq!(token.lock_from(), vec![e, t.venue_exec.clone()]);
    assert_eq!(token.sharing().unwrap().eligible, 0);
}

#[test]
#[should_panic(expected = "lock_from holds at most 2 executors")]
fn the_constructor_refuses_three_executors() {
    let t = setup(true);
    let e = &t.e;
    e.register(
        LaunchTokenV2,
        (
            t.pad.clone(),
            t.locker.clone(),
            String::from_str(e, "X"),
            String::from_str(e, "X"),
            SUPPLY,
            vec![e, Address::generate(e), Address::generate(e), Address::generate(e)],
            soroban_sdk::Vec::<Address>::new(e),
            None::<Address>,
            t.factory.clone(),
            t.router.clone(),
            t.treasury.clone(),
        ),
    );
}

#[test]
fn errors_are_numbered_in_the_tokens_namespace() {
    let expected = [
        (Error::TransferLocked, 10_201),
        (Error::AlreadyUnlocked, 10_202),
        (Error::InvalidSupply, 10_203),
        (Error::NotLaunchpad, 10_204),
        (Error::NotNotifier, 10_205),
        (Error::SharingOff, 10_206),
        (Error::UnderFunded, 10_207),
        (Error::NothingToClaim, 10_208),
        (Error::NotAPool, 10_209),
        (Error::ZeroAmount, 10_210),
        (Error::UnsupportedVenue, 10_211),
        (Error::ExcludedAccount, 10_212),
        (Error::TokenAccount, 10_213),
        (Error::BelowFloor, 10_214),
        (Error::UnsupportedAsset, 10_215),
    ];
    for (error, code) in expected {
        assert_eq!(error as u32, code);
        assert_eq!(dyor_common::tag_of(code), Some(dyor_common::TAG_LAUNCH_TOKEN_V2));
    }
    assert_eq!(setup(false).token().error_tag(), dyor_common::TAG_LAUNCH_TOKEN_V2);
}

// ------------------------------------------------------------------------------------------------ rewards (§6.2)

#[test]
fn sharing_off_keeps_no_reward_state() {
    let t = setup(false);
    let token = t.token();
    let alice = t.holder(10 * ONE);
    assert_eq!(token.sharing(), None);
    assert_eq!(token.pending_rewards(&alice), (0, 0));
    assert_eq!(token.queued_rewards(), (0, 0, 0));
    StellarAssetClient::new(&t.e, &t.quote).mint(&t.id, &1_000);
    assert_eq!(failure(token.try_notify_reward(&t.pad, &t.quote, &1_000)), err(Error::SharingOff));
    assert_eq!(failure(token.try_claim(&alice)), err(Error::SharingOff));
    assert_eq!(failure(token.try_sweep_protocol()), err(Error::SharingOff));
    let pool = Address::generate(&t.e);
    assert_eq!(failure(token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &pool)), err(Error::SharingOff));
    assert!(!token.exclude(&alice));
    assert!(!token.exclude_treasury());
    assert!(!token.is_excluded(&alice));
    assert!(!token.is_excluded(&t.treasury));
    t.e.as_contract(&t.id, || {
        assert!(!t.e.storage().persistent().has(&DataKey::Sharing));
        assert!(!t.e.storage().persistent().has(&DataKey::Holder(t.treasury.clone())));
    });
}

#[test]
fn notify_reward_needs_its_funds_a_positive_amount_a_reward_asset_and_a_notifier() {
    let t = setup(true);
    let token = t.token();
    t.holder(10 * ONE);
    // Nothing funded yet, in either asset.
    assert_eq!(failure(token.try_notify_reward(&t.pad, &t.quote, &1)), err(Error::UnderFunded));
    assert_eq!(failure(token.try_notify_reward(&t.locker, &t.id, &1)), err(Error::UnderFunded));
    // The balance must cover what is already funded and unpaid plus the amount.
    StellarAssetClient::new(&t.e, &t.quote).mint(&t.id, &1_000);
    assert_eq!(failure(token.try_notify_reward(&t.pad, &t.quote, &1_001)), err(Error::UnderFunded));
    token.notify_reward(&t.pad, &t.quote, &600);
    assert_eq!(failure(token.try_notify_reward(&t.locker, &t.quote, &401)), err(Error::UnderFunded));
    token.notify_reward(&t.locker, &t.quote, &400);
    // Launch tokens at the token's own address fund the token pool.
    token.transfer(&t.pad, &t.id, &(5 * ONE));
    assert_eq!(failure(token.try_notify_reward(&t.pad, &t.id, &(5 * ONE + 1))), err(Error::UnderFunded));
    token.notify_reward(&t.pad, &t.id, &(5 * ONE));
    assert_eq!(token.queued_rewards(), (1_000, 5 * ONE, t.e.ledger().sequence() + 1));
    // Zero or less.
    for amount in [0, -1] {
        assert_eq!(failure(token.try_notify_reward(&t.pad, &t.quote, &amount)), err(Error::ZeroAmount));
    }
    // Any other asset, funded or not.
    let other = t.e.register_stellar_asset_contract_v2(t.issuer.clone()).address();
    StellarAssetClient::new(&t.e, &other).mint(&t.id, &1_000);
    assert_eq!(failure(token.try_notify_reward(&t.pad, &other, &1_000)), err(Error::UnsupportedAsset));
    // Anyone but the launchpad or the locker.
    for notifier in [Address::generate(&t.e), t.venue_exec.clone(), t.treasury.clone(), t.id.clone()] {
        assert_eq!(failure(token.try_notify_reward(&notifier, &t.quote, &1)), err(Error::NotNotifier));
    }
    let s = t.sharing();
    assert_eq!((s.q.funded, s.q.queued, s.t.funded, s.t.queued), (1_000, 1_000, 5 * ONE, 5 * ONE));
}

#[test]
fn notify_reward_needs_the_notifiers_signature() {
    let t = setup(true);
    StellarAssetClient::new(&t.e, &t.quote).mint(&t.id, &100);
    t.e.set_auths(&[]);
    assert!(t.token().try_notify_reward(&t.pad, &t.quote, &100).is_err());
    assert!(t.token().try_notify_reward(&t.locker, &t.quote, &100).is_err());
    assert_eq!(t.sharing().q.funded, 0);
}

#[test]
fn openzeppelins_balance_checks_come_first_with_sharing_on_or_off() {
    for sharing in [false, true] {
        let t = setup(sharing);
        let token = t.token();
        let (alice, bob) = (t.holder(10), Address::generate(&t.e));
        token.unlock();
        let insufficient = oz(FungibleTokenError::InsufficientBalance);
        assert_eq!(failure(token.try_transfer(&alice, &bob, &11)), insufficient);
        assert_eq!(failure(token.try_transfer(&alice, &bob, &-1)), oz(FungibleTokenError::LessThanZero));
        assert_eq!(failure(token.try_burn(&alice, &11)), insufficient);
        assert_eq!(failure(token.try_transfer(&t.pad, &bob, &SUPPLY)), insufficient);
        token.transfer(&alice, &bob, &0);
        assert_eq!(t.balance(&alice), 10);
    }
}

#[test]
fn rewards_are_released_only_in_a_later_ledger() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(100 * ONE);
    t.notify_quote(1_000);
    let ledger = t.e.ledger().sequence();
    assert_eq!(token.queued_rewards(), (1_000, 0, ledger + 1));
    assert_eq!(token.pending_rewards(&alice), (0, 0));
    assert_eq!(failure(token.try_claim(&alice)), err(Error::NothingToClaim));
    // A balance change in the same ledger releases nothing.
    token.transfer(&alice, &t.pad, &(50 * ONE));
    assert_eq!(t.sharing().q.queued, 1_000);
    t.next_ledger();
    // The view counts a releasable queue before anything has released it.
    assert_eq!(token.pending_rewards(&alice), (1_000, 0));
    assert_eq!(t.sharing().q.acc, 0);
    assert_eq!(token.claim(&alice), (1_000, 0));
    assert_eq!(t.quote().balance(&alice), 1_000);
    let s = t.sharing();
    assert_eq!((s.q.acc, s.q.queued, s.q.funded, s.q.paid), (1_000 * P / (50 * ONE), 0, 1_000, 1_000));
    assert_eq!(failure(token.try_claim(&alice)), err(Error::NothingToClaim));
}

/// I-T3: receive tokens, notify, claim and send them away within one ledger, and earn nothing in either asset.
#[test]
fn a_flash_holder_earns_nothing_in_either_asset() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(100 * ONE);
    token.unlock();
    // A queue from an earlier ledger, which the flasher's own first transfer releases.
    t.notify_quote(500);
    t.next_ledger();

    let flasher = t.holder(900 * ONE);
    t.notify_quote(1_000);
    t.notify_tokens(10 * ONE);
    assert_eq!(token.pending_rewards(&flasher), (0, 0));
    assert_eq!(failure(token.try_claim(&flasher)), err(Error::NothingToClaim));
    token.transfer(&flasher, &t.pad, &(900 * ONE));

    t.next_ledger();
    assert_eq!(token.pending_rewards(&flasher), (0, 0));
    assert_eq!(failure(token.try_claim(&flasher)), err(Error::NothingToClaim));
    // Alice held through both ledgers: all of it is hers.
    assert_eq!(token.claim(&alice), (1_500, 10 * ONE));
    t.assert_funded(&[&alice, &flasher]);
}

#[test]
fn holders_share_both_assets_pro_rata() {
    let t = setup(true);
    let token = t.token();
    let (alice, bob) = (t.holder(300 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_quote(4_000);
    t.notify_tokens(40 * ONE);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (3_000, 30 * ONE));
    assert_eq!(token.pending_rewards(&bob), (1_000, 10 * ONE));

    assert_eq!(token.claim(&alice), (3_000, 30 * ONE));
    assert_eq!((t.quote().balance(&alice), t.balance(&alice)), (3_000, 330 * ONE));
    assert_eq!(token.claim(&bob), (1_000, 10 * ONE));
    assert_eq!((t.quote().balance(&t.id), t.balance(&t.id)), (0, 0));
    let s = t.sharing();
    assert_eq!((s.q.funded, s.q.paid, s.t.funded, s.t.paid), (4_000, 4_000, 40 * ONE, 40 * ONE));
    // Claimed launch tokens are eligible in the holders' hands (I-T5).
    assert_eq!(s.eligible, 440 * ONE);
    assert_eq!(s.eligible, token.total_supply() - t.balance(&t.pad) - t.balance(&t.locker));
}

#[test]
fn a_claim_of_launch_token_rewards_earns_nothing_on_itself() {
    let t = setup(true);
    let token = t.token();
    let (alice, bob) = (t.holder(100 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_tokens(200 * ONE);
    t.next_ledger();
    // The claim releases the queue, settles alice at 100 tokens, then pays her 100 more.
    assert_eq!(token.claim(&alice), (0, 100 * ONE));
    assert_eq!(t.balance(&alice), 200 * ONE);
    assert_eq!(token.pending_rewards(&alice), (0, 0));
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (0, 0));
    assert_eq!(token.claim(&bob), (0, 100 * ONE));
    assert_eq!(t.balance(&t.id), 0);
    // From then on the claimed tokens count like any others.
    t.notify_quote(4_000);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (2_000, 0));
    assert_eq!(token.pending_rewards(&bob), (2_000, 0));
}

#[test]
fn excluded_accounts_cannot_claim() {
    let t = setup(true);
    let alice = t.holder(100 * ONE);
    t.notify_quote(1_000);
    t.next_ledger();
    for a in [&t.pad, &t.locker, &t.venue_exec, &t.fallback_exec, &t.id, &t.treasury] {
        assert_eq!(failure(t.token().try_claim(a)), err(Error::ExcludedAccount));
        assert_eq!(t.token().pending_rewards(a), (0, 0));
    }
    assert!(t.token().exclude(&alice));
    assert_eq!(failure(t.token().try_claim(&alice)), err(Error::ExcludedAccount));
}

/// I-T4: Monad's drain PoC (M:contracts/test/PoC_HolderDrain.t.sol) sends tokens to itself to mint rewards.
#[test]
fn a_self_transfer_settles_and_mints_nothing() {
    let t = setup(true);
    let token = t.token();
    let (alice, bob) = (t.holder(100 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_quote(2_000);
    t.next_ledger();
    // It releases the queue but settles nobody.
    token.transfer(&alice, &alice, &(100 * ONE));
    assert_eq!(t.sharing().q.queued, 0);
    assert_eq!(t.holder_entry(&alice), None);
    assert_eq!(token.pending_rewards(&alice), (1_000, 0));
    for _ in 0..5 {
        token.transfer(&alice, &alice, &(100 * ONE));
        t.next_ledger();
    }
    t.notify_quote(2_000);
    t.next_ledger();
    token.transfer(&alice, &alice, &(50 * ONE));
    assert_eq!(t.sharing().eligible, 200 * ONE);
    assert_eq!(token.claim(&alice), (2_000, 0));
    assert_eq!(token.claim(&bob), (2_000, 0));
    t.assert_funded(&[&alice, &bob]);
}

#[test]
fn burns_settle_before_the_supply_falls() {
    let t = setup(true);
    let token = t.token();
    let (alice, bob, spender) = (t.holder(100 * ONE), t.holder(100 * ONE), Address::generate(&t.e));
    t.notify_quote(2_000);
    t.next_ledger();
    token.burn(&alice, &(50 * ONE));
    token.approve(&bob, &spender, &(100 * ONE), &(t.e.ledger().sequence() + 10));
    token.burn_from(&spender, &bob, &(100 * ONE));
    assert_eq!(token.total_supply(), SUPPLY - 150 * ONE);
    assert_eq!(t.sharing().eligible, 50 * ONE);
    assert_eq!(token.pending_rewards(&alice), (1_000, 0));
    assert_eq!(token.pending_rewards(&bob), (1_000, 0));
    // The next reward is alice's alone.
    t.notify_quote(500);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (1_500, 0));
    assert_eq!(token.pending_rewards(&bob), (1_000, 0));
    t.assert_funded(&[&alice, &bob]);
}

#[test]
fn below_min_eligible_rewards_go_to_the_protocol() {
    let t = setup(true);
    let token = t.token();
    let dust = t.holder(MIN_ELIGIBLE - 1);
    token.unlock();
    t.notify_quote(1_000);
    t.notify_tokens(5 * ONE);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&dust), (0, 0));
    // Any touch releases.
    token.transfer(&dust, &dust, &1);
    let events = t.e.events().all().filter_by_contract(&t.id);
    let eligible = MIN_ELIGIBLE - 1;
    for asset in [&t.quote, &t.id] {
        let amount = if *asset == t.quote { 1_000 } else { 5 * ONE };
        let event = RewardToProtocol { asset: asset.clone(), amount, eligible }.to_xdr(&t.e, &t.id);
        assert!(events.events().contains(&event));
    }
    let s = t.sharing();
    assert_eq!((s.q.acc, s.q.protocol_owed, s.t.acc, s.t.protocol_owed), (0, 1_000, 0, 5 * ONE));
    assert_eq!(token.sweep_protocol(), (1_000, 5 * ONE));
    assert_eq!((t.quote().balance(&t.treasury), t.balance(&t.treasury)), (1_000, 5 * ONE));
    assert_eq!(failure(token.try_sweep_protocol()), err(Error::NothingToClaim));

    // At exactly MIN_ELIGIBLE the holders share it.
    let one = t.holder(1);
    t.notify_quote(1_000);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&dust), (999, 0));
    assert_eq!(token.pending_rewards(&one), (0, 0));
    assert_eq!(t.token().queued_rewards().0, 1_000);
    token.claim(&dust);
    assert_eq!(t.sharing().q.protocol_owed, 0);
    t.assert_funded(&[&dust, &one]);
}

/// I-T2 exactly, per asset: balances that never divide the rewards, debts reset at every round, and every claim paid.
#[test]
fn debts_round_up_so_every_claim_is_funded() {
    let t = setup(true);
    let token = t.token();
    token.unlock();
    let holders: StdVec<Address> = [3_333_333, 3_333_333, 3_333_335, 7].iter().map(|b| t.holder(*b)).collect();
    let refs: StdVec<&Address> = holders.iter().collect();
    let mut rounded = 0;
    for round in 0..12usize {
        t.notify_quote(7 + round as i128);
        t.notify_tokens(11 + round as i128);
        t.next_ledger();
        let (from, to) = (&holders[round % 4], &holders[(round + 1) % 4]);
        token.transfer(from, to, &(1 + round as i128));
        // Both sides were just settled at the current acc: their debts are rounded up.
        let s = t.sharing();
        for h in [from, to] {
            let entry = t.holder_entry(h).unwrap();
            for (debt, acc) in [(entry.q_debt, s.q.acc), (entry.t_debt, s.t.acc)] {
                let exact = t.balance(h) * acc;
                assert!(debt * P >= exact && (debt - 1) * P < exact);
                rounded += i32::from(debt * P > exact);
            }
        }
        t.assert_funded(&refs);
    }
    assert!(rounded > 0);
    for h in &holders {
        if token.pending_rewards(h) != (0, 0) {
            token.claim(h);
        }
        t.assert_funded(&refs);
    }
    let s = t.sharing();
    assert_eq!(t.quote().balance(&t.id), s.q.funded - s.q.paid);
    assert_eq!(t.balance(&t.id), s.t.funded - s.t.paid);
    // What is left is rounding dust: at most a few units per holder per round.
    assert!(s.q.funded - s.q.paid <= 2 * 12 * 4 && s.t.funded - s.t.paid <= 2 * 12 * 4);
}

#[test]
fn exclude_moves_what_the_account_earned_to_the_protocol_once() {
    let t = setup(true);
    let token = t.token();
    let (pool, alice) = (t.holder(300 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_quote(4_000);
    t.notify_tokens(40 * ONE);
    t.next_ledger();
    assert!(token.exclude(&pool));
    let event = Excluded { account: pool.clone(), by_pool: false, stranded_q: 3_000, stranded_t: 30 * ONE };
    assert!(t.e.events().all().filter_by_contract(&t.id).events().contains(&event.to_xdr(&t.e, &t.id)));
    // I-T7: nothing left owed, and the protocol got what it had accrued.
    let s = t.sharing();
    assert_eq!((s.q.protocol_owed, s.t.protocol_owed, s.eligible), (3_000, 30 * ONE, 100 * ONE));
    assert_eq!(token.pending_rewards(&pool), (0, 0));
    assert_eq!(t.holder_entry(&pool), Some(Holder { excluded: true, ..Holder::default() }));
    assert!(!token.exclude(&pool));
    assert!(!token.exclude(&t.locker));
    assert_eq!(t.sharing(), s);
    // The excluded balance earns nothing; what it sends on earns in the receiver's hands.
    t.notify_quote(1_000);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (2_000, 10 * ONE));
    token.transfer(&pool, &alice, &(100 * ONE));
    assert_eq!(t.sharing().eligible, 200 * ONE);
    t.assert_funded(&[&alice]);
}

#[test]
fn exclude_requires_the_launchpad() {
    let t = setup(true);
    let alice = t.holder(ONE);
    t.e.set_auths(&[]);
    assert!(t.token().try_exclude(&alice).is_err());
    assert!(!t.token().is_excluded(&alice));
}

#[test]
fn holder_entries_are_written_from_the_first_release_on() {
    let t = setup(true);
    let token = t.token();
    let (alice, bob) = (t.holder(10 * ONE), t.holder(10 * ONE));
    token.unlock();
    token.transfer(&alice, &bob, &ONE);
    t.notify_quote(1_000);
    token.transfer(&alice, &bob, &ONE);
    assert_eq!((t.holder_entry(&alice), t.holder_entry(&bob)), (None, None));
    t.next_ledger();
    token.transfer(&alice, &bob, &ONE);
    // acc = 1,000 · P / 20 tokens = 5e12: alice earned 400 at 8 tokens, bob 600 at 12; debts round up.
    assert_eq!(t.holder_entry(&alice).unwrap(), Holder { q_debt: 350, q_owed: 400, ..Holder::default() });
    assert_eq!(t.holder_entry(&bob).unwrap(), Holder { q_debt: 650, q_owed: 600, ..Holder::default() });
    let ttl = t.e.as_contract(&t.id, || {
        use soroban_sdk::testutils::storage::Persistent as _;
        t.e.storage().persistent().get_ttl(&DataKey::Holder(alice.clone()))
    });
    assert_eq!(ttl, BALANCE_EXTEND_AMOUNT);
}

#[test]
fn reward_events_carry_their_asset() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(100 * ONE);
    token.unlock();
    let unlocked = Unlocked { launchpad: t.pad.clone() }.to_xdr(&t.e, &t.id);
    assert_eq!(t.e.events().all().filter_by_contract(&t.id).events(), [unlocked]);
    let next = t.e.ledger().sequence() + 1;
    t.notify_quote(1_000);
    let queued = RewardQueued { asset: t.quote.clone(), notifier: t.pad.clone(), amount: 1_000, releasable_from: next };
    assert!(t.e.events().all().filter_by_contract(&t.id).events().contains(&queued.to_xdr(&t.e, &t.id)));
    t.notify_tokens(10 * ONE);
    let queued =
        RewardQueued { asset: t.id.clone(), notifier: t.locker.clone(), amount: 10 * ONE, releasable_from: next };
    assert!(t.e.events().all().filter_by_contract(&t.id).events().contains(&queued.to_xdr(&t.e, &t.id)));
    t.next_ledger();
    token.claim(&alice);
    let events = t.e.events().all().filter_by_contract(&t.id);
    let (acc_q, acc_t) = (1_000 * P / (100 * ONE), 10 * ONE * P / (100 * ONE));
    for event in [
        RewardAdded { asset: t.quote.clone(), amount: 1_000, eligible: 100 * ONE, acc: acc_q }.to_xdr(&t.e, &t.id),
        RewardAdded { asset: t.id.clone(), amount: 10 * ONE, eligible: 100 * ONE, acc: acc_t }.to_xdr(&t.e, &t.id),
        RewardClaimed { asset: t.quote.clone(), holder: alice.clone(), amount: 1_000 }.to_xdr(&t.e, &t.id),
        RewardClaimed { asset: t.id.clone(), holder: alice.clone(), amount: 10 * ONE }.to_xdr(&t.e, &t.id),
        // The launch-token payout is a SEP-41 transfer from the token's own address.
        stellar_tokens::fungible::Transfer { from: t.id.clone(), to: alice.clone(), amount: 10 * ONE }
            .to_xdr(&t.e, &t.id),
    ] {
        assert!(events.events().contains(&event));
    }
}

#[test]
fn views_report_the_sharing_state() {
    let t = setup(true);
    let token = t.token();
    assert_eq!(token.exclusion_floor(), (EXCLUDE_MIN_BALANCE, EXCLUDE_MIN_OWED));
    assert_eq!((EXCLUDE_MIN_BALANCE, EXCLUDE_MIN_OWED, MIN_ELIGIBLE), (1_000 * ONE, 1_000_000, ONE));
    assert_eq!(P, 1_000_000_000_000_000_000);
    let empty = SharingView {
        quote: t.quote.clone(),
        eligible: 0,
        queued_ledger: 0,
        q: RewardPool::default(),
        t: RewardPool::default(),
    };
    assert_eq!(token.sharing(), Some(empty));
    let alice = t.holder(10 * ONE);
    t.notify_quote(100);
    let ledger = t.e.ledger().sequence();
    assert_eq!(token.queued_rewards(), (100, 0, ledger + 1));
    let s = token.sharing().unwrap();
    assert_eq!((s.eligible, s.queued_ledger, s.q.queued, s.q.funded), (10 * ONE, ledger, 100, 100));
    t.next_ledger();
    assert_eq!(token.pending_rewards(&alice), (100, 0));
    assert_eq!(token.pending_rewards(&Address::generate(&t.e)), (0, 0));
}

// ------------------------------------------------------------------------------------------------ the treasury (V2)

#[test]
fn the_treasury_is_excluded_from_birth_with_sharing_on() {
    let t = setup(true);
    assert!(t.token().is_excluded(&t.treasury));
    assert_eq!(t.holder_entry(&t.treasury), Some(Holder { excluded: true, ..Holder::default() }));
    assert!(!t.token().exclude_treasury());

    let off = setup(false);
    assert!(!off.token().is_excluded(&off.treasury));
    assert!(!off.token().exclude_treasury());
    off.launchpad().set_treasury(&Address::generate(&off.e));
    assert!(!off.token().exclude_treasury());
}

#[test]
fn exclude_treasury_follows_the_launchpads_treasury_one_way() {
    let t = setup(true);
    let token = t.token();
    // The new treasury was a holder with rewards of its own.
    let (new, alice) = (t.holder(50 * ONE), t.holder(50 * ONE));
    t.notify_quote(1_000);
    t.next_ledger();
    t.launchpad().set_treasury(&new);
    assert!(!token.is_excluded(&new));
    assert!(token.exclude_treasury());
    assert!(!token.exclude_treasury());
    // The old treasury stays excluded; the new one's rewards went to the protocol.
    assert!(token.is_excluded(&new) && token.is_excluded(&t.treasury));
    assert_eq!(token.pending_rewards(&new), (0, 0));
    let s = t.sharing();
    assert_eq!((s.q.protocol_owed, s.eligible), (500, 50 * ONE));
    // Back to the old treasury: both stay excluded.
    t.launchpad().set_treasury(&t.treasury);
    assert!(!token.exclude_treasury());
    assert!(token.is_excluded(&new));
    t.notify_quote(1_000);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&new), (0, 0));
    assert_eq!(token.pending_rewards(&alice), (1_500, 0));
}

#[test]
fn sweep_protocol_excludes_the_current_treasury_before_paying_it() {
    let t = setup(true);
    let token = t.token();
    let (new, alice) = (t.holder(100 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_quote(2_000);
    t.notify_tokens(20 * ONE);
    t.next_ledger();
    assert_eq!(failure(token.try_sweep_protocol()), err(Error::NothingToClaim));
    // The treasury changes and nobody calls exclude_treasury: the sweep excludes it, stranding its own rewards, then
    // pays it the protocol's share, which those rewards now are.
    t.launchpad().set_treasury(&new);
    assert_eq!(token.sweep_protocol(), (1_000, 10 * ONE));
    let events = t.e.events().all().filter_by_contract(&t.id);
    for event in [
        RewardSwept { asset: t.quote.clone(), treasury: new.clone(), amount: 1_000 }.to_xdr(&t.e, &t.id),
        RewardSwept { asset: t.id.clone(), treasury: new.clone(), amount: 10 * ONE }.to_xdr(&t.e, &t.id),
    ] {
        assert!(events.events().contains(&event));
    }
    assert!(token.is_excluded(&new));
    assert_eq!((t.quote().balance(&new), t.balance(&new)), (1_000, 110 * ONE));
    // Its launch tokens earn nothing (I-T10).
    assert_eq!(t.sharing().eligible, 100 * ONE);
    t.notify_quote(1_000);
    t.notify_tokens(10 * ONE);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&new), (0, 0));
    assert_eq!(token.pending_rewards(&alice), (2_000, 20 * ONE));
    t.assert_funded(&[&alice]);
}

/// The locker's harvest of a sharing launch's launch-token side (§8.2): `exclude_treasury`, then the protocol's half
/// to the treasury and the holders' half to the token's own address with a notify.
#[test]
fn a_harvest_never_pays_launch_tokens_to_an_eligible_treasury() {
    let t = setup(true);
    let token = t.token();
    let alice = t.holder(100 * ONE);
    token.unlock();
    let new = Address::generate(&t.e);
    t.launchpad().set_treasury(&new);
    for _ in 0..3 {
        token.transfer(&t.pad, &t.locker, &(20 * ONE));
        token.exclude_treasury();
        token.transfer(&t.locker, &new, &(10 * ONE));
        token.transfer(&t.locker, &t.id, &(10 * ONE));
        token.notify_reward(&t.locker, &t.id, &(10 * ONE));
        t.next_ledger();
        assert_eq!(token.pending_rewards(&new), (0, 0));
        assert_eq!(t.sharing().eligible, t.balance(&alice));
    }
    assert!(token.is_excluded(&new));
    assert_eq!(t.balance(&new), 30 * ONE);
    assert_eq!(token.claim(&alice), (0, 30 * ONE));
}

// ------------------------------------------------------------------------------------------------ exclude_pool (F2)

fn soroswap_pair(t: &T, a: &Address, b: &Address) -> Address {
    soroswap_factory::Client::new(&t.e, &t.factory).create_pair(a, b)
}

/// A standard pool opened through the router by a third party, paying the router's fee: not a DyorHQ venue.
fn aquarius_pool(t: &T, a: &Address, b: &Address) -> Address {
    let router = AquariusRouterClient::new(&t.e, &t.router);
    let user = Address::generate(&t.e);
    StellarAssetClient::new(&t.e, &router.get_init_pool_payment_token()).mint(&user, &ONE);
    router.init_standard_pool(&user, &sorted_pair(&t.e, a, b), &30).1
}

fn other_asset(t: &T) -> Address {
    t.e.register_stellar_asset_contract_v2(t.issuer.clone()).address()
}

#[test]
fn exclude_pool_accepts_this_tokens_soroswap_pair_above_the_floor() {
    for token_last in [false, true] {
        let t = setup_with(true, Venues::Fixtures, token_last);
        let token = t.token();
        let pair = soroswap_pair(&t, &t.id, &t.quote);
        let alice = t.holder(EXCLUDE_MIN_BALANCE);
        token.transfer(&t.pad, &pair, &EXCLUDE_MIN_BALANCE);
        token.unlock();
        t.notify_quote(4_000);
        t.notify_tokens(40 * ONE);
        t.next_ledger();
        assert!(token.exclude_pool(&VenueKind::Soroswap, &t.quote, &pair));
        let event = Excluded { account: pair.clone(), by_pool: true, stranded_q: 2_000, stranded_t: 20 * ONE };
        assert!(t.e.events().all().filter_by_contract(&t.id).events().contains(&event.to_xdr(&t.e, &t.id)));
        // Idempotent.
        assert!(!token.exclude_pool(&VenueKind::Soroswap, &t.quote, &pair));
        let s = t.sharing();
        assert_eq!((s.q.protocol_owed, s.t.protocol_owed, s.eligible), (2_000, 20 * ONE, EXCLUDE_MIN_BALANCE));
        // The stranded rewards of both pools go to the treasury.
        assert_eq!(token.sweep_protocol(), (2_000, 20 * ONE));
        assert_eq!((t.quote().balance(&t.treasury), t.balance(&t.treasury)), (2_000, 20 * ONE));
        assert_eq!(token.claim(&alice), (2_000, 20 * ONE));
        t.assert_funded(&[&alice]);
    }
}

#[test]
fn exclude_pool_refuses_what_is_not_this_tokens_soroswap_pair() {
    let t = setup_with(true, Venues::Fixtures, false);
    let token = t.token();
    let other = other_asset(&t);
    let real = soroswap_pair(&t, &t.id, &t.quote);
    let others_pair = soroswap_pair(&t, &t.quote, &other);
    let fake = t.e.register(FakePair, (t.id.clone(), t.quote.clone()));
    assert!(matches!(fake.executable(), Some(Executable::Wasm(_))));
    let g = account(&t.e, 7);
    let nothing = Address::generate(&t.e);
    for a in [&real, &others_pair, &fake, &g, &nothing] {
        token.transfer(&t.pad, a, &EXCLUDE_MIN_BALANCE);
    }
    let not_a_pool = |other: &Address, pool: &Address| {
        assert_eq!(failure(token.try_exclude_pool(&VenueKind::Soroswap, other, pool)), err(Error::NotAPool),);
    };
    not_a_pool(&t.quote, &g); // an account
    not_a_pool(&t.quote, &nothing); // no contract there
    not_a_pool(&t.quote, &t.quote); // the other asset itself
    not_a_pool(&t.quote, &t.id); // the token itself
    not_a_pool(&t.id, &real); // a pair of the token with itself
    not_a_pool(&t.quote, &fake); // a contract that only claims the pair's tokens
    not_a_pool(&t.quote, &others_pair); // another token's pair
    not_a_pool(&other, &real); // the real pair, named for another asset
                               // A factory that names a pair whose own tokens are another pair (a token built against it).
    let liar = t.e.register(LyingFactory, (others_pair.clone(),));
    let lied_to = LaunchTokenV2Client::new(&t.e, &t.deploy(true, &liar, false));
    assert_eq!(failure(lied_to.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &others_pair)), err(Error::NotAPool),);
    // Venue kinds without a pool registry.
    for kind in [VenueKind::HoldOnly, VenueKind::QaFail] {
        assert_eq!(failure(token.try_exclude_pool(&kind, &t.quote, &real)), err(Error::UnsupportedVenue));
    }
    for a in [&real, &others_pair, &fake, &g, &nothing] {
        assert!(!token.is_excluded(a));
    }
    assert!(token.exclude_pool(&VenueKind::Soroswap, &t.quote, &real));
}

#[test]
fn exclude_pool_needs_the_floor_in_tokens() {
    let t = setup_with(true, Venues::Fixtures, false);
    let token = t.token();
    let pair = soroswap_pair(&t, &t.id, &t.quote);
    t.holder(100 * ONE);
    token.transfer(&t.pad, &pair, &(EXCLUDE_MIN_BALANCE - 1));
    assert_eq!(failure(token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &pair)), err(Error::BelowFloor));
    assert!(!token.is_excluded(&pair));
    token.transfer(&t.pad, &pair, &1);
    assert!(token.exclude_pool(&VenueKind::Soroswap, &t.quote, &pair));
}

/// A pool under the token floor that has collected at least EXCLUDE_MIN_OWED of the quote is worth excluding.
#[test]
fn exclude_pool_takes_a_pool_whose_unclaimed_quote_reaches_the_floor() {
    let t = setup_with(true, Venues::Fixtures, false);
    let token = t.token();
    let pair = soroswap_pair(&t, &t.id, &t.quote);
    // Eligible: 1e11 units, the pair a hair under a tenth.
    t.holder(9 * EXCLUDE_MIN_BALANCE + 1);
    token.transfer(&t.pad, &pair, &(EXCLUDE_MIN_BALANCE - 1));
    t.notify_quote(10_000_000);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&pair), (EXCLUDE_MIN_OWED - 1, 0));
    assert_eq!(failure(token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &pair)), err(Error::BelowFloor));
    t.notify_quote(10);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&pair), (EXCLUDE_MIN_OWED, 0));
    assert!(token.exclude_pool(&VenueKind::Soroswap, &t.quote, &pair));
    assert_eq!(t.sharing().q.protocol_owed, EXCLUDE_MIN_OWED);
}

#[test]
fn exclude_pool_takes_a_pool_whose_unclaimed_tokens_reach_the_floor() {
    let t = setup_with(true, Venues::Fixtures, false);
    let token = t.token();
    let pair = soroswap_pair(&t, &t.id, &t.quote);
    t.holder(9 * EXCLUDE_MIN_BALANCE + 1);
    token.transfer(&t.pad, &pair, &(EXCLUDE_MIN_BALANCE - 1));
    token.unlock();
    t.notify_tokens(10 * EXCLUDE_MIN_BALANCE);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&pair), (0, EXCLUDE_MIN_BALANCE - 1));
    assert_eq!(failure(token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &pair)), err(Error::BelowFloor));
    t.notify_tokens(20);
    t.next_ledger();
    assert_eq!(token.pending_rewards(&pair), (0, EXCLUDE_MIN_BALANCE));
    assert!(token.exclude_pool(&VenueKind::Soroswap, &t.quote, &pair));
    assert_eq!(t.sharing().t.protocol_owed, EXCLUDE_MIN_BALANCE);
}

#[test]
fn exclude_pool_accepts_an_aquarius_pool_the_router_names() {
    for token_last in [false, true] {
        let t = setup_with(true, Venues::Fixtures, token_last);
        assert_eq!(t.id > t.quote, token_last);
        let token = t.token();
        let pool = aquarius_pool(&t, &t.id, &t.quote);
        let alice = t.holder(EXCLUDE_MIN_BALANCE);
        token.transfer(&t.pad, &pool, &EXCLUDE_MIN_BALANCE);
        t.notify_quote(2_000);
        t.next_ledger();
        assert!(token.exclude_pool(&VenueKind::Aquarius, &t.quote, &pool));
        assert!(!token.exclude_pool(&VenueKind::Aquarius, &t.quote, &pool));
        assert_eq!(t.sharing().q.protocol_owed, 1_000);
        assert_eq!(token.pending_rewards(&alice), (1_000, 0));
    }
}

#[test]
fn exclude_pool_refuses_what_is_not_this_tokens_aquarius_pool() {
    let t = setup_with(true, Venues::Fixtures, false);
    let token = t.token();
    let other = other_asset(&t);
    let pool = aquarius_pool(&t, &t.id, &t.quote);
    let others_pool = aquarius_pool(&t, &t.quote, &other);
    let share = dyor_common::aquarius::AquariusPoolClient::new(&t.e, &pool).share_id();
    let fake = t.e.register(FakePair, (t.id.clone(), t.quote.clone()));
    let low = aquarius_pool(&t, &t.id, &other);
    for a in [&pool, &others_pool, &share, &fake] {
        token.transfer(&t.pad, a, &EXCLUDE_MIN_BALANCE);
    }
    token.transfer(&t.pad, &low, &(EXCLUDE_MIN_BALANCE - 1));
    let refused = |kind: VenueKind, other: &Address, pool: &Address, error: Error| {
        assert_eq!(failure(token.try_exclude_pool(&kind, other, pool)), err(error));
    };
    refused(VenueKind::Aquarius, &t.quote, &others_pool, Error::NotAPool); // another pair's pool
    refused(VenueKind::Aquarius, &t.quote, &share, Error::NotAPool); // the pool's share token
    refused(VenueKind::Aquarius, &t.quote, &fake, Error::NotAPool);
    refused(VenueKind::Aquarius, &other, &pool, Error::NotAPool); // named for (token, quote), not (token, other)
    refused(VenueKind::Aquarius, &t.quote, &account(&t.e, 9), Error::NotAPool);
    refused(VenueKind::Soroswap, &t.quote, &pool, Error::NotAPool); // no such Soroswap pair
    refused(VenueKind::Aquarius, &other, &low, Error::BelowFloor);
    assert!(token.exclude_pool(&VenueKind::Aquarius, &t.quote, &pool));
}

/// The Aquarius branch is gated by CT-03's check 4 alone (`AQUARIUS_POOL_LOOKUP_OK`), never by the venue decision
/// (`AQUARIUS_VENUE_OK`): anyone can open an Aquarius pool for an unlocked token (F2).
#[test]
fn aquarius_exclusion_depends_only_on_the_pool_lookup_check() {
    let t = setup_with(true, Venues::Fixtures, false);
    let pool = aquarius_pool(&t, &t.id, &t.quote);
    // CT-03's gate passed check 4, so exclude_pool passes `true` here.
    const { assert!(dyor_common::aquarius::AQUARIUS_POOL_LOOKUP_OK) };
    t.e.as_contract(&t.id, || rewards::check_pool(&t.e, VenueKind::Aquarius, &t.quote, &pool, true));
    // The contract's sources never read the venue gate, so its value can't change exclude_pool.
    for source in [include_str!("lib.rs"), include_str!("lock.rs"), include_str!("rewards.rs")] {
        assert!(!source.contains("AQUARIUS_VENUE_OK"));
    }
}

#[test]
#[should_panic(expected = "Error(Contract, #10211)")]
fn without_the_pool_lookup_check_aquarius_is_an_unsupported_venue() {
    let t = setup_with(true, Venues::Fixtures, false);
    let pool = aquarius_pool(&t, &t.id, &t.quote);
    t.e.as_contract(&t.id, || rewards::check_pool(&t.e, VenueKind::Aquarius, &t.quote, &pool, false));
}

// ------------------------------------------------------------------------------------------------ resources

/// Runs `f` while a release of both pools is due, so it pays for the release, both settles and both entries, and
/// returns what `f`'s invocation cost.
fn measure(t: &T, what: &str, f: impl FnOnce()) -> (i64, u32) {
    t.notify_quote(1_000);
    t.notify_tokens(10 * ONE);
    t.next_ledger();
    f();
    let r = t.e.cost_estimate().resources();
    std::println!("{what}: {} instructions, {} write entries", r.instructions, r.write_entries);
    assert!(r.instructions <= 30_000_000, "{what}: {} instructions", r.instructions);
    (r.instructions, r.write_entries)
}

/// §6 acceptance: a sharing transfer stays within 30M instructions and 6 write entries. Measured on the release WASM
/// when build.sh has written it to contracts/dist (VM costs included), else on the native contract, which leaves the
/// VM's instructions out but writes exactly the same entries. The write count includes the signer's auth nonce, as
/// the network charges it: a plain SEP-41 transfer writes 3 (two balances and the nonce).
#[test]
fn sharing_transfers_stay_within_their_resource_budget() {
    let wasm = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../dist/dyor_launch_token_v2.wasm")).ok();
    let mut t = setup(true);
    if let Some(wasm) = &wasm {
        t.id = t.e.register(wasm.as_slice(), t.args(true, &t.factory));
    }
    std::println!("measuring the {}", if wasm.is_some() { "release WASM" } else { "native contract" });
    let token = t.token();
    let (alice, bob) = (t.holder(100 * ONE), t.holder(100 * ONE));
    token.unlock();
    t.notify_quote(1_000);
    t.next_ledger();
    token.transfer(&alice, &bob, &ONE);

    // Two balances, two holder entries, the released Sharing entry and the nonce.
    assert_eq!(measure(&t, "holder → holder", || token.transfer(&alice, &bob, &ONE)).1, 6);
    // The launchpad is excluded: one holder entry fewer.
    assert_eq!(measure(&t, "buy", || token.transfer(&t.pad, Address::generate(&t.e), &ONE)).1, 5);
    assert_eq!(measure(&t, "sell", || token.transfer(&bob, &t.pad, &ONE)).1, 5);
    // A burn also writes the total supply, which OpenZeppelin keeps in the instance.
    assert_eq!(measure(&t, "burn", || token.burn(&alice, &ONE)).1, 5);
    // transfer_from adds the allowance it spends, as every SEP-41 transfer_from does.
    token.approve(&alice, &bob, &(10 * ONE), &(t.e.ledger().sequence() + 100));
    assert_eq!(measure(&t, "transfer_from", || token.transfer_from(&bob, &alice, &bob, &ONE)).1, 7);
    measure(&t, "claim of both assets", || {
        token.claim(&alice);
    });
}

// ------------------------------------------------------------------------------------------------ property (§18.2)

/// Random sequences of buys, sells, transfers and self-transfers, burns and burn_from, exclusions (by the launchpad,
/// of a verified pool, of the treasury), treasury changes, notifies of both assets, ledger advances, claims, sweeps
/// and spending attempts from the token's own address, checked after every step against a reference model in plain
/// Rust. The model holds every balance, exclusion and pool total, and each account's exact pro-rata share of every
/// release (u128, in units of 1/S). It checks I-T1 to I-T10 in both pools and each account's rewards against its
/// exact share: never above it, and below it by less than 2 units per release it took part in, one for the floored
/// accrual and one for the debt rounded up at the settle before it (§6.2: "at most 1 stroop per settle").
/// 1,000 cases in all; PROPTEST_CASES=100000 for the nightly run.
mod property {
    use super::*;
    use proptest::prelude::*;
    use proptest::test_runner::{Config, TestCaseError, TestRunner};
    use soroban_sdk::testutils::EnvTestConfig;
    // prop_oneof! expands to an unqualified `vec!`: std's, not the soroban one the parent module imports.
    use std::vec;

    /// Four holders and a DEX pool of the token, which earns like any holder until it is excluded.
    const ACCOUNTS: usize = 5;
    const POOL: usize = 4;
    const S: u128 = 1_000_000_000_000_000_000;
    /// Steps between full checks. Every step compares the stored state and every result with the model; the full
    /// check reads every account's pending rewards, which costs a contract call each.
    const CHECK_EVERY: usize = 4;

    #[derive(Clone, Debug)]
    enum Op {
        Buy(usize, i128),
        Sell(usize, u8),
        /// From == to is a self-transfer.
        Transfer(usize, usize, u8),
        Burn(usize, u8),
        BurnFrom(usize, u8),
        Exclude(usize),
        ExcludePool,
        ExcludeNotAPool(usize),
        NotifyQuote(i128, bool),
        NotifyTokens(i128),
        Advance(u32),
        Claim(usize),
        Sweep,
        Unlock,
        /// The launchpad's treasury becomes a holder or a fresh address.
        NewTreasury(Option<usize>),
        ExcludeTreasury,
        SpendTokenAccount(u8),
    }

    fn op() -> impl Strategy<Value = Op> {
        let who = 0..ACCOUNTS;
        let amount = prop_oneof![1..=MIN_ELIGIBLE, 1..=1_000 * ONE, 1..=20_000 * ONE];
        prop_oneof![
            5 => (who.clone(), amount).prop_map(|(w, a)| Op::Buy(w, a)),
            2 => (who.clone(), any::<u8>()).prop_map(|(w, p)| Op::Sell(w, p)),
            5 => (who.clone(), who.clone(), any::<u8>()).prop_map(|(f, t, p)| Op::Transfer(f, t, p)),
            1 => (who.clone(), any::<u8>()).prop_map(|(w, p)| Op::Burn(w, p)),
            1 => (who.clone(), any::<u8>()).prop_map(|(w, p)| Op::BurnFrom(w, p)),
            1 => (0..POOL).prop_map(Op::Exclude),
            2 => Just(Op::ExcludePool),
            1 => (0..POOL).prop_map(Op::ExcludeNotAPool),
            4 => (prop_oneof![1..=1_000i128, 1..=1_000_000_000i128], any::<bool>())
                .prop_map(|(a, by_locker)| Op::NotifyQuote(a, by_locker)),
            3 => prop_oneof![1..=1_000i128, 1..=1_000 * ONE].prop_map(Op::NotifyTokens),
            4 => (1..=3u32).prop_map(Op::Advance),
            4 => who.prop_map(Op::Claim),
            1 => Just(Op::Sweep),
            1 => Just(Op::Unlock),
            1 => prop::option::of(0..POOL).prop_map(Op::NewTreasury),
            1 => Just(Op::ExcludeTreasury),
            1 => (0..5u8).prop_map(Op::SpendTokenAccount),
        ]
    }

    #[derive(Clone, Copy, Debug, Default)]
    struct Pool {
        queued: i128,
        funded: i128,
        paid: i128,
        protocol: i128,
    }

    /// The launchpad's current treasury: one of the accounts, or an address outside them.
    #[derive(Clone, Copy, Debug, PartialEq)]
    enum Treasury {
        Holder(usize),
        /// An index into `outside`.
        Outside(usize),
    }

    #[derive(Clone, Debug)]
    struct Model {
        ledger: u32,
        queued_ledger: u32,
        unlocked: bool,
        bal: [i128; ACCOUNTS],
        excluded: [bool; ACCOUNTS],
        /// Quote, then launch token.
        pools: [Pool; 2],
        /// Σ over releases of amount · balance / eligible, in units of 1/S: the exact pro-rata share.
        share: [[u128; 2]; ACCOUNTS],
        /// The releases each account took part in.
        releases: [[u32; 2]; ACCOUNTS],
        /// Claimed, or stranded at the account's exclusion.
        received: [[i128; 2]; ACCOUNTS],
        treasury: Treasury,
        /// Treasuries that aren't holders: whether each is excluded. The first is the one the token was built with.
        outside: StdVec<bool>,
    }

    impl Model {
        fn eligible(&self) -> i128 {
            (0..ACCOUNTS).filter(|&i| !self.excluded[i]).map(|i| self.bal[i]).sum()
        }

        /// What any touching call does first (§6.2 release): the queue goes to the holders of this moment, or to the
        /// protocol below MIN_ELIGIBLE.
        fn release(&mut self) {
            if self.ledger <= self.queued_ledger {
                return;
            }
            let eligible = self.eligible();
            for k in 0..2 {
                let amount = core::mem::take(&mut self.pools[k].queued);
                if amount == 0 {
                    continue;
                }
                if eligible < MIN_ELIGIBLE {
                    self.pools[k].protocol += amount;
                    continue;
                }
                for i in 0..ACCOUNTS {
                    if !self.excluded[i] && self.bal[i] > 0 {
                        let (n, e) = (amount as u128 * self.bal[i] as u128, eligible as u128);
                        self.share[i][k] += n / e * S + n % e * S / e;
                        self.releases[i][k] += 1;
                    }
                }
            }
        }

        fn strand(&mut self, i: usize, pending: (i128, i128)) {
            self.received[i][0] += pending.0;
            self.received[i][1] += pending.1;
            self.pools[0].protocol += pending.0;
            self.pools[1].protocol += pending.1;
            self.excluded[i] = true;
        }

        fn part(&self, i: usize, p: u8) -> i128 {
            self.bal[i] * (p as i128 + 1) / 256
        }
    }

    struct World {
        t: T,
        accounts: [Address; ACCOUNTS],
        outside: StdVec<Address>,
        spender: Address,
        model: Model,
        /// Accounts whose last claim found nothing; check() confirms nothing was owed.
        nothing_claimed: StdVec<usize>,
    }

    /// A sharing token whose Soroswap factory names `accounts[POOL]` as the pair of (token, quote), and whose pair
    /// answers with those tokens, so `exclude_pool` verifies it without the fixtures' cost.
    fn world() -> World {
        let e = Env::new_with_config(EnvTestConfig { capture_snapshot_at_drop: false });
        e.mock_all_auths();
        e.cost_estimate().budget().reset_unlimited();
        let treasury = Address::generate(&e);
        let pad = e.register(TestLaunchpad, (treasury.clone(),));
        let issuer = Address::generate(&e);
        let quote = e.register_stellar_asset_contract_v2(issuer.clone()).address();
        let id = Address::generate(&e);
        let pool = e.register(FakePair, (id.clone(), quote.clone()));
        let factory = e.register(LyingFactory, (pool.clone(),));
        let t = T {
            locker: Address::generate(&e),
            venue_exec: Address::generate(&e),
            fallback_exec: Address::generate(&e),
            router: Address::generate(&e),
            id: id.clone(),
            e,
            pad,
            treasury: treasury.clone(),
            issuer,
            quote,
            factory,
        };
        t.e.register_at(&id, LaunchTokenV2, t.args(true, &t.factory));
        let holder = || Address::generate(&t.e);
        let accounts = [holder(), holder(), holder(), holder(), pool];
        let model = Model {
            ledger: t.e.ledger().sequence(),
            queued_ledger: 0,
            unlocked: false,
            bal: [0; ACCOUNTS],
            excluded: [false; ACCOUNTS],
            pools: [Pool::default(); 2],
            share: [[0; 2]; ACCOUNTS],
            releases: [[0; 2]; ACCOUNTS],
            received: [[0; 2]; ACCOUNTS],
            treasury: Treasury::Outside(0),
            outside: vec![true],
        };
        let spender = Address::generate(&t.e);
        World { accounts, outside: vec![treasury], spender, model, t, nothing_claimed: StdVec::new() }
    }

    impl World {
        fn treasury_of(&self, m: &Model) -> Address {
            match m.treasury {
                Treasury::Holder(i) => self.accounts[i].clone(),
                Treasury::Outside(k) => self.outside[k].clone(),
            }
        }

        fn treasury_excluded(m: &Model) -> bool {
            match m.treasury {
                Treasury::Holder(i) => m.excluded[i],
                Treasury::Outside(k) => m.outside[k],
            }
        }

        /// Excludes the model's current treasury (exclude_treasury, sweep_protocol) with what it had pending.
        fn exclude_treasury_in(&self, m: &mut Model) {
            match m.treasury {
                Treasury::Holder(i) if !m.excluded[i] => {
                    let pending = self.t.token().pending_rewards(&self.accounts[i]);
                    m.strand(i, pending);
                }
                Treasury::Outside(k) => m.outside[k] = true,
                Treasury::Holder(_) => {}
            }
        }

        /// Runs `op` on the contract and on a copy of the model, compares the outcomes and keeps the copy.
        fn step(&mut self, op: &Op) -> Result<(), TestCaseError> {
            let t = &self.t;
            let token = t.token();
            let a = &self.accounts;
            let mut m = self.model.clone();
            let live = t.e.ledger().sequence() + 100;
            match *op {
                Op::Buy(i, amount) => {
                    token.transfer(&t.pad, &a[i], &amount);
                    m.release();
                    m.bal[i] += amount;
                }
                Op::Sell(i, p) => {
                    let amount = m.part(i, p);
                    token.transfer(&a[i], &t.pad, &amount);
                    m.release();
                    m.bal[i] -= amount;
                }
                Op::Transfer(i, j, p) => {
                    let amount = m.part(i, p);
                    let r = token.try_transfer(&a[i], &a[j], &amount);
                    // I-T6: before unlock no holder sends to anyone but the launchpad.
                    if m.unlocked {
                        prop_assert!(r.is_ok());
                        m.release();
                        m.bal[i] -= amount;
                        m.bal[j] += amount;
                    } else {
                        prop_assert_eq!(failure(r), err(Error::TransferLocked));
                    }
                }
                Op::Burn(i, p) => {
                    let amount = m.part(i, p);
                    token.burn(&a[i], &amount);
                    m.release();
                    m.bal[i] -= amount;
                }
                Op::BurnFrom(i, p) => {
                    let amount = m.part(i, p);
                    token.approve(&a[i], &self.spender, &amount, &live);
                    token.burn_from(&self.spender, &a[i], &amount);
                    m.release();
                    m.bal[i] -= amount;
                }
                Op::Exclude(i) => {
                    let pending = token.pending_rewards(&a[i]);
                    prop_assert_eq!(token.exclude(&a[i]), !m.excluded[i]);
                    m.release();
                    if !m.excluded[i] {
                        m.strand(i, pending);
                    }
                }
                Op::ExcludePool => {
                    let pending = token.pending_rewards(&a[POOL]);
                    let r = token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &a[POOL]);
                    let above = m.bal[POOL] >= EXCLUDE_MIN_BALANCE
                        || pending.0 >= EXCLUDE_MIN_OWED
                        || pending.1 >= EXCLUDE_MIN_BALANCE;
                    // I-T9: only above the floor, once.
                    if m.excluded[POOL] {
                        prop_assert_eq!(r, Ok(Ok(false)));
                        m.release();
                    } else if above {
                        prop_assert_eq!(r, Ok(Ok(true)));
                        m.release();
                        m.strand(POOL, pending);
                    } else {
                        prop_assert_eq!(failure(r), err(Error::BelowFloor));
                    }
                }
                Op::ExcludeNotAPool(i) => {
                    let r = token.try_exclude_pool(&VenueKind::Soroswap, &t.quote, &a[i]);
                    prop_assert_eq!(failure(r), err(Error::NotAPool));
                }
                Op::NotifyQuote(amount, by_locker) => {
                    let notifier = if by_locker { &t.locker } else { &t.pad };
                    StellarAssetClient::new(&t.e, &t.quote).mint(&t.id, &amount);
                    token.notify_reward(notifier, &t.quote, &amount);
                    m.release();
                    m.pools[0].funded += amount;
                    m.pools[0].queued += amount;
                    m.queued_ledger = m.ledger;
                }
                Op::NotifyTokens(amount) => {
                    // After unlock the locker funds it (§8.2); before, only the launchpad can send to the token.
                    let notifier = if m.unlocked {
                        token.transfer(&t.pad, &t.locker, &amount);
                        token.transfer(&t.locker, &t.id, &amount);
                        &t.locker
                    } else {
                        token.transfer(&t.pad, &t.id, &amount);
                        &t.pad
                    };
                    token.notify_reward(notifier, &t.id, &amount);
                    m.release();
                    m.pools[1].funded += amount;
                    m.pools[1].queued += amount;
                    m.queued_ledger = m.ledger;
                }
                Op::Advance(n) => {
                    t.e.ledger().with_mut(|l| l.sequence_number += n);
                    m.ledger += n;
                }
                Op::Claim(i) => {
                    let r = token.try_claim(&a[i]);
                    if m.excluded[i] {
                        prop_assert_eq!(failure(r), err(Error::ExcludedAccount));
                    } else if let Ok(Ok((q, tk))) = r {
                        // Every claim is funded (I-T2); check() holds the amounts to the account's exact share.
                        prop_assert!(q > 0 || tk > 0);
                        m.release();
                        m.received[i][0] += q;
                        m.received[i][1] += tk;
                        m.pools[0].paid += q;
                        m.pools[1].paid += tk;
                        m.bal[i] += tk;
                    } else {
                        prop_assert_eq!(failure(r), err(Error::NothingToClaim));
                        self.nothing_claimed.push(i);
                    }
                }
                Op::Sweep => {
                    m.release();
                    self.exclude_treasury_in(&mut m);
                    let owed = (m.pools[0].protocol, m.pools[1].protocol);
                    let r = token.try_sweep_protocol();
                    if owed == (0, 0) {
                        prop_assert_eq!(failure(r), err(Error::NothingToClaim));
                        return Ok(());
                    }
                    prop_assert_eq!(r, Ok(Ok(owed)));
                    for k in 0..2 {
                        m.pools[k].paid += m.pools[k].protocol;
                        m.pools[k].protocol = 0;
                    }
                    if let Treasury::Holder(i) = m.treasury {
                        m.bal[i] += owed.1;
                    }
                    // I-T10: the treasury it paid launch tokens to was excluded first.
                    prop_assert!(token.is_excluded(&self.treasury_of(&m)));
                }
                Op::Unlock => {
                    let r = token.try_unlock();
                    if m.unlocked {
                        prop_assert_eq!(failure(r), err(Error::AlreadyUnlocked));
                    } else {
                        prop_assert!(r.is_ok());
                        m.unlocked = true;
                    }
                }
                Op::NewTreasury(holder) => {
                    m.treasury = match holder {
                        Some(i) => Treasury::Holder(i),
                        None => {
                            self.outside.push(Address::generate(&t.e));
                            m.outside.push(false);
                            Treasury::Outside(m.outside.len() - 1)
                        }
                    };
                    t.launchpad().set_treasury(&self.treasury_of(&m));
                }
                Op::ExcludeTreasury => {
                    let expected = !Self::treasury_excluded(&m);
                    m.release();
                    self.exclude_treasury_in(&mut m);
                    prop_assert_eq!(token.exclude_treasury(), expected);
                    prop_assert!(token.is_excluded(&self.treasury_of(&m)));
                }
                Op::SpendTokenAccount(kind) => {
                    // I-T8: nothing spends from the token's own address.
                    let (this, to) = (&t.id, &a[0]);
                    let e = match kind {
                        0 => failure(token.try_transfer(this, to, &1)),
                        1 => failure(token.try_burn(this, &1)),
                        2 => failure(token.try_approve(this, &self.spender, &1, &live)),
                        3 => failure(token.try_transfer_from(&self.spender, this, to, &1)),
                        _ => failure(token.try_burn_from(&self.spender, this, &1)),
                    };
                    prop_assert_eq!(e, err(Error::TokenAccount));
                }
            }
            self.model = m;
            self.compare_state()
        }

        /// The stored `Sharing` against the model: one view call, after every step.
        fn compare_state(&self) -> Result<(), TestCaseError> {
            let s = self.t.token().sharing().unwrap();
            let m = &self.model;
            // I-T5: eligible is what the holders that aren't excluded hold.
            prop_assert_eq!(s.eligible, m.eligible());
            prop_assert_eq!(s.queued_ledger, m.queued_ledger);
            for (k, pool) in [&s.q, &s.t].into_iter().enumerate() {
                let p = &m.pools[k];
                prop_assert_eq!(
                    (pool.queued, pool.funded, pool.paid, pool.protocol_owed),
                    (p.queued, p.funded, p.paid, p.protocol)
                );
            }
            Ok(())
        }

        /// Every account's rewards against its exact share, and the funds against what is owed (I-T1, I-T2).
        fn check(&mut self) -> Result<(), TestCaseError> {
            let token = self.t.token();
            let m = &self.model;
            // I-T1, and I-T8: the token's balances are exactly what was funded and not paid.
            prop_assert_eq!(self.t.quote().balance(&self.t.id), m.pools[0].funded - m.pools[0].paid);
            prop_assert_eq!(token.balance(&self.t.id), m.pools[1].funded - m.pools[1].paid);
            // What a release in this ledger would do, as the pending view counts it.
            let mut v = m.clone();
            v.release();
            let pending: StdVec<(i128, i128)> = self.accounts.iter().map(|a| token.pending_rewards(a)).collect();
            for k in 0..2 {
                let mut owed = v.pools[k].queued + v.pools[k].protocol;
                for (i, p) in pending.iter().enumerate() {
                    let now = if k == 0 { p.0 } else { p.1 };
                    if v.excluded[i] {
                        prop_assert_eq!(now, 0);
                    }
                    owed += now;
                    let total = (v.received[i][k] + now) as u128;
                    let (share, releases) = (v.share[i][k], v.releases[i][k] as u128);
                    // Never more than the exact share (I-T4: nothing minted), and less by under 2 per release.
                    prop_assert!(total * S <= share + releases, "account {} pool {}: {} over {}", i, k, total, share);
                    prop_assert!(
                        share < (total + 2 * releases + 1) * S,
                        "account {} pool {}: {} under {} by more than 2 per release ({})",
                        i,
                        k,
                        total,
                        share,
                        releases
                    );
                }
                // I-T2: owed never exceeds the funds; the rest is rounding dust.
                let outstanding = v.pools[k].funded - v.pools[k].paid;
                let dust_bound: i128 = (0..ACCOUNTS).map(|i| 2 * v.releases[i][k] as i128 + 1).sum();
                prop_assert!(owed <= outstanding && outstanding - owed <= dust_bound);
            }
            Ok(())
        }

        /// A claim that found nothing had nothing owed: its exact share is within rounding of what it received.
        fn check_nothing_claimed(&mut self) -> Result<(), TestCaseError> {
            for i in core::mem::take(&mut self.nothing_claimed) {
                let m = &self.model;
                for k in 0..2 {
                    let (share, releases) = (m.share[i][k], m.releases[i][k] as u128);
                    prop_assert!(share < (m.received[i][k] as u128 + 2 * releases + 1) * S);
                }
            }
            Ok(())
        }

        /// Everyone claims and the protocol is swept: nothing fails for lack of funds. Then the balances, the
        /// exclusions and I-T5 are checked from the contract's own state.
        fn finish(&mut self) -> Result<(), TestCaseError> {
            for i in 0..ACCOUNTS {
                if !self.model.excluded[i] && self.t.token().pending_rewards(&self.accounts[i]) != (0, 0) {
                    self.step(&Op::Claim(i))?;
                }
            }
            self.step(&Op::Sweep)?;
            self.check()?;
            let t = &self.t;
            let token = t.token();
            let m = &self.model;
            for i in 0..ACCOUNTS {
                prop_assert_eq!(token.balance(&self.accounts[i]), m.bal[i]);
                prop_assert_eq!(token.is_excluded(&self.accounts[i]), m.excluded[i]);
                prop_assert_eq!(token.pending_rewards(&self.accounts[i]), (0, 0));
            }
            for (k, excluded) in m.outside.iter().enumerate() {
                prop_assert_eq!(token.is_excluded(&self.outside[k]), *excluded);
            }
            // I-T10: the fixed set is never eligible.
            let fixed = [&t.pad, &t.locker, &t.venue_exec, &t.fallback_exec, &t.id];
            for a in fixed {
                prop_assert!(token.is_excluded(a));
            }
            // I-T5 from the balances: the total supply less everything excluded.
            let excluded: i128 = fixed.iter().map(|a| token.balance(a)).sum::<i128>()
                + self.outside.iter().map(|a| token.balance(a)).sum::<i128>()
                + (0..ACCOUNTS).filter(|&i| m.excluded[i]).map(|i| m.bal[i]).sum::<i128>();
            prop_assert_eq!(token.sharing().unwrap().eligible, token.total_supply() - excluded);
            Ok(())
        }
    }

    /// The cases are split over four tests, which the test harness runs in parallel: every contract call meters its
    /// budget, which a debug build makes slow.
    const SHARDS: u32 = 4;

    fn run_shard() {
        let cases = std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or(1_000);
        let config = Config { cases: cases.div_ceil(SHARDS), failure_persistence: None, ..Config::default() };
        TestRunner::new(config)
            .run(&prop::collection::vec(op(), 1..28), |ops| {
                let mut w = world();
                for (n, op) in ops.iter().enumerate() {
                    w.step(op)?;
                    w.check_nothing_claimed()?;
                    if n % CHECK_EVERY == CHECK_EVERY - 1 {
                        w.check()?;
                    }
                }
                w.finish()
            })
            .unwrap();
    }

    #[test]
    fn rewards_match_the_reference_model_1() {
        run_shard();
    }

    #[test]
    fn rewards_match_the_reference_model_2() {
        run_shard();
    }

    #[test]
    fn rewards_match_the_reference_model_3() {
        run_shard();
    }

    #[test]
    fn rewards_match_the_reference_model_4() {
        run_shard();
    }
}
