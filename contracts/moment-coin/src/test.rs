//! moment-coin (§11): the constructor's initial mint, the minter-only capped `mint`, burns by holders and by
//! spenders within an allowance, SEP-41 transfers, the error namespace, and a moments-v2 stand-in that mints through
//! dyor-common's `MomentCoinClient` with its own auth.
extern crate std;

use super::*;
use dyor_common::{grad_failure, GradFailure, ORIGIN_FOREIGN, TAG_MOMENT_COIN};
use soroban_sdk::testutils::storage::Instance as _;
use soroban_sdk::testutils::{
    Address as _, AuthorizedFunction, AuthorizedInvocation, Events as _, Ledger as _, MockAuth, MockAuthInvoke,
    MuxedAddress as _,
};
use soroban_sdk::{Event as _, IntoVal, MuxedAddress, Symbol, Val, Vec};
use stellar_tokens::fungible::burnable::Burn;
use stellar_tokens::fungible::{FungibleTokenError, Mint, Transfer};

const ONE: i128 = 10_000_000; // 7 decimals
/// S, the cap every Moment coin is deployed with: 100M coins (§14.2).
const S: i128 = 100_000_000 * ONE;
/// What the graduator mints to itself for the pool: S less the allocation and the entitlements (§9.3).
const POOL_COINS: i128 = 25_000_000 * ONE;

// ------------------------------------------------------------------------------------------------ stand-ins

/// Stands in for moments-v2, the minter: it mints through dyor-common's client, so its direct call carries its auth.
#[contract]
pub struct TestMoments;

#[contractimpl]
impl TestMoments {
    pub fn mint(e: Env, coin: Address, to: Address, amount: i128) {
        dyor_common::MomentCoinClient::new(&e, &coin).mint(&to, &amount);
    }
}

// ------------------------------------------------------------------------------------------------ harness

struct T {
    e: Env,
    /// moments-v2
    minter: Address,
    /// moments-graduator, which receives the pool's coins at construction
    graduator: Address,
    id: Address,
}

/// A coin as the graduator deploys it, with `cap` and `initial_amount`. Every auth is mocked.
fn setup_with(cap: i128, initial_amount: i128) -> T {
    let e = Env::default();
    e.mock_all_auths();
    let minter = Address::generate(&e);
    let graduator = Address::generate(&e);
    let id = e.register(MomentCoin, args(&e, &minter, cap, &graduator, initial_amount));
    T { e, minter, graduator, id }
}

fn setup() -> T {
    setup_with(S, POOL_COINS)
}

fn args(
    e: &Env,
    minter: &Address,
    cap: i128,
    initial_to: &Address,
    initial_amount: i128,
) -> (Address, String, String, i128, Address, i128) {
    (
        minter.clone(),
        String::from_str(e, "Sunset at Labadi"),
        String::from_str(e, "LABADI"),
        cap,
        initial_to.clone(),
        initial_amount,
    )
}

impl T {
    fn coin(&self) -> MomentCoinClient<'_> {
        MomentCoinClient::new(&self.e, &self.id)
    }

    fn balance(&self, a: &Address) -> i128 {
        self.coin().balance(a)
    }

    /// A new account holding `amount`, minted to it by the minter.
    fn holder(&self, amount: i128) -> Address {
        let a = Address::generate(&self.e);
        self.coin().mint(&a, &amount);
        a
    }

    fn live_until(&self) -> u32 {
        self.e.ledger().sequence() + 100
    }

    fn events(&self) -> std::vec::Vec<soroban_sdk::xdr::ContractEvent> {
        self.e.events().all().filter_by_contract(&self.id).events().to_vec()
    }

    fn instance_ttl(&self) -> u32 {
        self.e.as_contract(&self.id, || self.e.storage().instance().get_ttl())
    }

    /// Exactly `coin.fn_name(args)`, for a `MockAuth`.
    fn invoke<'a>(&'a self, fn_name: &'a str, args: Vec<Val>) -> MockAuthInvoke<'a> {
        MockAuthInvoke { contract: &self.id, fn_name, args, sub_invokes: &[] }
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

/// The one authorization a call needed: `address` signing `coin.fn_name(args)` with nothing below it.
fn signed_by(t: &T, address: &Address, fn_name: &str, args: Vec<Val>) -> (Address, AuthorizedInvocation) {
    let function = AuthorizedFunction::Contract((t.id.clone(), Symbol::new(&t.e, fn_name), args));
    (address.clone(), AuthorizedInvocation { function, sub_invocations: std::vec![] })
}

// ------------------------------------------------------------------------------------------------ construction

#[test]
fn the_initial_mint_lands_at_initial_to() {
    let t = setup();
    assert_eq!(t.events(), [Mint { to: t.graduator.clone(), amount: POOL_COINS }.to_xdr(&t.e, &t.id)]);
    assert_eq!(t.balance(&t.graduator), POOL_COINS);
    assert_eq!(t.balance(&t.minter), 0);
    assert_eq!(t.coin().total_supply(), POOL_COINS);
    assert_eq!(t.coin().cap(), S);
    assert_eq!(t.coin().minter(), t.minter);
    assert_eq!(t.coin().decimals(), DECIMALS);
    assert_eq!(DECIMALS, 7);
    assert_eq!(t.coin().name(), String::from_str(&t.e, "Sunset at Labadi"));
    assert_eq!(t.coin().symbol(), String::from_str(&t.e, "LABADI"));
}

#[test]
fn an_initial_amount_of_zero_mints_nothing() {
    let t = setup_with(S, 0);
    assert_eq!(t.events(), []);
    assert_eq!(t.balance(&t.graduator), 0);
    assert_eq!(t.coin().total_supply(), 0);
    // The whole cap is left for the minter.
    t.coin().mint(&t.graduator, &S);
    assert_eq!(t.coin().total_supply(), S);
}

#[test]
fn an_initial_amount_of_exactly_the_cap_fills_it() {
    let t = setup_with(S, S);
    assert_eq!(t.balance(&t.graduator), S);
    assert_eq!(failure(t.coin().try_mint(&t.graduator, &1)), oz(FungibleTokenError::ExceededCap));
}

#[test]
#[should_panic(expected = "Error(Contract, #106)")]
fn the_constructor_refuses_an_initial_amount_above_the_cap() {
    setup_with(S, S + 1);
}

#[test]
#[should_panic(expected = "Error(Contract, #10902)")]
fn the_constructor_refuses_a_negative_initial_amount() {
    setup_with(S, -1);
}

#[test]
#[should_panic(expected = "Error(Contract, #107)")]
fn the_constructor_refuses_a_negative_cap() {
    setup_with(-1, 0);
}

// ------------------------------------------------------------------------------------------------ mint

#[test]
fn the_minter_mints_up_to_the_cap_and_never_beyond() {
    let t = setup();
    let alice = Address::generate(&t.e);
    let room = S - POOL_COINS;
    t.coin().mint(&alice, &(room - 1));
    assert_eq!(t.events(), [Mint { to: alice.clone(), amount: room - 1 }.to_xdr(&t.e, &t.id)]);
    assert_eq!(failure(t.coin().try_mint(&alice, &2)), oz(FungibleTokenError::ExceededCap));
    t.coin().mint(&alice, &1);
    assert_eq!((t.balance(&alice), t.coin().total_supply()), (room, S));
    for amount in [1, ONE, S, i128::MAX - S] {
        assert_eq!(failure(t.coin().try_mint(&alice, &amount)), oz(FungibleTokenError::ExceededCap));
    }
    // An amount whose sum with the supply doesn't fit in an i128 is refused before the cap is compared.
    assert_eq!(failure(t.coin().try_mint(&alice, &i128::MAX)), oz(FungibleTokenError::MathOverflow));
    assert_eq!((t.balance(&alice), t.coin().total_supply()), (room, S));
}

#[test]
fn a_mint_of_zero_or_less_fails_zero_amount() {
    let t = setup();
    let alice = Address::generate(&t.e);
    for amount in [0, -1, -S, i128::MIN] {
        assert_eq!(failure(t.coin().try_mint(&alice, &amount)), err(Error::ZeroAmount));
    }
    assert_eq!(t.coin().total_supply(), POOL_COINS);
}

#[test]
fn a_mint_past_i128_fails_without_wrapping() {
    let t = setup_with(i128::MAX, i128::MAX);
    assert_eq!(failure(t.coin().try_mint(&t.graduator, &1)), oz(FungibleTokenError::MathOverflow));
    assert_eq!(t.coin().total_supply(), i128::MAX);
}

#[test]
fn only_the_minter_can_mint() {
    let t = setup();
    let alice = Address::generate(&t.e);
    let mallory = Address::generate(&t.e);
    let mint_args: Vec<Val> = (alice.clone(), ONE).into_val(&t.e);

    // Nobody has signed.
    t.e.set_auths(&[]);
    assert!(t.coin().try_mint(&alice, &ONE).is_err());
    // A holder's or a stranger's signature doesn't do either.
    let invoke = t.invoke("mint", mint_args.clone());
    for address in [&mallory, &t.graduator] {
        assert!(t.coin().mock_auths(&[MockAuth { address, invoke: &invoke }]).try_mint(&alice, &ONE).is_err());
    }
    assert_eq!(t.coin().total_supply(), POOL_COINS);

    // The minter's signature for exactly this mint does.
    t.coin().mock_auths(&[MockAuth { address: &t.minter, invoke: &invoke }]).mint(&alice, &ONE);
    assert_eq!(t.balance(&alice), ONE);
    // And it is the one authorization a mint needs.
    t.e.mock_all_auths();
    t.coin().mint(&alice, &ONE);
    assert_eq!(t.e.auths(), [signed_by(&t, &t.minter, "mint", mint_args)]);
}

#[test]
fn moments_v2_mints_through_the_common_client_with_its_own_auth() {
    // No mocked auth: the minter contract's direct call carries its auth.
    let e = Env::default();
    let moments = e.register(TestMoments, ());
    let graduator = Address::generate(&e);
    let id = e.register(MomentCoin, args(&e, &moments, S, &graduator, POOL_COINS));
    let coin = dyor_common::MomentCoinClient::new(&e, &id);
    assert_eq!((coin.cap(), coin.total_supply()), (S, POOL_COINS));

    let collector = Address::generate(&e);
    TestMomentsClient::new(&e, &moments).mint(&id, &collector, &(10 * ONE));
    assert_eq!(MomentCoinClient::new(&e, &id).balance(&collector), 10 * ONE);
    assert_eq!(coin.total_supply(), POOL_COINS + 10 * ONE);

    // Another contract running the same code is not the minter.
    let impostor = e.register(TestMoments, ());
    assert!(TestMomentsClient::new(&e, &impostor).try_mint(&id, &collector, &ONE).is_err());
    assert_eq!(coin.total_supply(), POOL_COINS + 10 * ONE);
}

// ------------------------------------------------------------------------------------------------ burn

#[test]
fn holders_burn_their_own_coins() {
    let t = setup();
    let alice = t.holder(100 * ONE);
    t.coin().burn(&alice, &(40 * ONE));
    assert_eq!(t.events(), [Burn { from: alice.clone(), amount: 40 * ONE }.to_xdr(&t.e, &t.id)]);
    assert_eq!(t.e.auths(), [signed_by(&t, &alice, "burn", (alice.clone(), 40 * ONE).into_val(&t.e))]);
    assert_eq!(t.balance(&alice), 60 * ONE);
    assert_eq!(t.coin().total_supply(), POOL_COINS + 60 * ONE);

    // The graduator burns what the pool left unused the same way (§12 step 6).
    t.coin().burn(&t.graduator, &POOL_COINS);
    assert_eq!(t.coin().total_supply(), 60 * ONE);

    assert_eq!(failure(t.coin().try_burn(&alice, &(60 * ONE + 1))), oz(FungibleTokenError::InsufficientBalance));
    assert_eq!(failure(t.coin().try_burn(&alice, &-1)), oz(FungibleTokenError::LessThanZero));
}

#[test]
fn nobody_else_burns_a_holders_coins() {
    let t = setup();
    let alice = t.holder(100 * ONE);
    let mallory = Address::generate(&t.e);
    let burn_args: Vec<Val> = (alice.clone(), ONE).into_val(&t.e);
    let invoke = t.invoke("burn", burn_args);
    for address in [&mallory, &t.minter] {
        assert!(t.coin().mock_auths(&[MockAuth { address, invoke: &invoke }]).try_burn(&alice, &ONE).is_err());
    }
    t.coin().mock_auths(&[MockAuth { address: &alice, invoke: &invoke }]).burn(&alice, &ONE);
    assert_eq!(t.balance(&alice), 99 * ONE);
}

#[test]
fn burn_from_spends_an_allowance() {
    let t = setup();
    let alice = t.holder(100 * ONE);
    let locker = Address::generate(&t.e);
    let coin = t.coin();

    // Without an allowance, a spender burns nothing.
    assert_eq!(failure(coin.try_burn_from(&locker, &alice, &1)), oz(FungibleTokenError::InsufficientAllowance));

    coin.approve(&alice, &locker, &(30 * ONE), &t.live_until());
    coin.burn_from(&locker, &alice, &(20 * ONE));
    assert_eq!(t.events(), [Burn { from: alice.clone(), amount: 20 * ONE }.to_xdr(&t.e, &t.id)]);
    // The spender's signature is the one the burn needs.
    let args = (locker.clone(), alice.clone(), 20 * ONE).into_val(&t.e);
    assert_eq!(t.e.auths(), [signed_by(&t, &locker, "burn_from", args)]);
    assert_eq!((t.balance(&alice), coin.allowance(&alice, &locker)), (80 * ONE, 10 * ONE));
    assert_eq!(coin.total_supply(), POOL_COINS + 80 * ONE);

    // Beyond the allowance, and for another spender, it fails.
    assert_eq!(
        failure(coin.try_burn_from(&locker, &alice, &(10 * ONE + 1))),
        oz(FungibleTokenError::InsufficientAllowance)
    );
    let mallory = Address::generate(&t.e);
    assert_eq!(failure(coin.try_burn_from(&mallory, &alice, &1)), oz(FungibleTokenError::InsufficientAllowance));

    // The rest of the allowance burns exactly, and nothing more.
    coin.burn_from(&locker, &alice, &(10 * ONE));
    assert_eq!((t.balance(&alice), coin.allowance(&alice, &locker)), (70 * ONE, 0));
    assert_eq!(failure(coin.try_burn_from(&locker, &alice, &1)), oz(FungibleTokenError::InsufficientAllowance));
}

#[test]
fn burn_from_needs_the_spenders_signature_and_a_live_allowance() {
    let t = setup();
    let alice = t.holder(100 * ONE);
    let locker = Address::generate(&t.e);
    let coin = t.coin();
    let live_until = t.live_until();
    coin.approve(&alice, &locker, &(30 * ONE), &live_until);

    // The holder's signature doesn't let a spender burn: the spender signs.
    let burn_args: Vec<Val> = (locker.clone(), alice.clone(), ONE).into_val(&t.e);
    let invoke = t.invoke("burn_from", burn_args);
    assert!(coin
        .mock_auths(&[MockAuth { address: &alice, invoke: &invoke }])
        .try_burn_from(&locker, &alice, &ONE)
        .is_err());
    coin.mock_auths(&[MockAuth { address: &locker, invoke: &invoke }]).burn_from(&locker, &alice, &ONE);
    assert_eq!(t.balance(&alice), 99 * ONE);

    // Once the allowance has lapsed, nothing burns.
    t.e.mock_all_auths();
    t.e.ledger().with_mut(|l| l.sequence_number = live_until + 1);
    assert_eq!(coin.allowance(&alice, &locker), 0);
    assert_eq!(failure(coin.try_burn_from(&locker, &alice, &1)), oz(FungibleTokenError::InsufficientAllowance));
    assert_eq!(t.balance(&alice), 99 * ONE);
}

#[test]
fn a_burn_frees_room_under_the_cap() {
    // The cap bounds the coins outstanding. moments-v2 bounds the coins ever minted with its own ledger (I-M3).
    let t = setup_with(S, S);
    t.coin().burn(&t.graduator, &(5 * ONE));
    assert_eq!(t.coin().total_supply(), S - 5 * ONE);
    let alice = Address::generate(&t.e);
    assert_eq!(failure(t.coin().try_mint(&alice, &(5 * ONE + 1))), oz(FungibleTokenError::ExceededCap));
    t.coin().mint(&alice, &(5 * ONE));
    assert_eq!(t.coin().total_supply(), S);
}

// ------------------------------------------------------------------------------------------------ SEP-41

#[test]
fn coins_move_like_any_sep41_token() {
    let t = setup();
    let coin = t.coin();
    let alice = t.holder(100 * ONE);
    let bob = Address::generate(&t.e);

    coin.transfer(&alice, &bob, &(30 * ONE));
    let transfer = Transfer { from: alice.clone(), to: bob.clone(), amount: 30 * ONE };
    assert_eq!(t.events(), [transfer.to_xdr(&t.e, &t.id)]);
    assert_eq!((t.balance(&alice), t.balance(&bob)), (70 * ONE, 30 * ONE));

    let spender = Address::generate(&t.e);
    coin.approve(&bob, &spender, &(10 * ONE), &t.live_until());
    coin.transfer_from(&spender, &bob, &alice, &(10 * ONE));
    assert_eq!((t.balance(&alice), t.balance(&bob)), (80 * ONE, 20 * ONE));
    assert_eq!(coin.allowance(&bob, &spender), 0);

    // A muxed recipient is credited at its address.
    let muxed = MuxedAddress::generate(&t.e);
    coin.transfer(&alice, &muxed, &ONE);
    assert_eq!(t.balance(&muxed.address()), ONE);

    assert_eq!(failure(coin.try_transfer(&bob, &alice, &(20 * ONE + 1))), oz(FungibleTokenError::InsufficientBalance));
    assert_eq!(coin.total_supply(), POOL_COINS + 100 * ONE);
}

#[test]
fn no_call_extends_the_instance() {
    // DECISIONS #10: the keeper keeps the instance alive, never a user's call.
    let t = setup();
    let ttl = t.instance_ttl();
    let coin = t.coin();
    let alice = t.holder(100 * ONE);
    let bob = Address::generate(&t.e);
    coin.transfer(&alice, &bob, &ONE);
    coin.approve(&alice, &bob, &ONE, &t.live_until());
    coin.transfer_from(&bob, &alice, &bob, &ONE);
    coin.burn(&bob, &ONE);
    coin.approve(&alice, &bob, &ONE, &t.live_until());
    coin.burn_from(&bob, &alice, &ONE);
    assert_eq!(t.instance_ttl(), ttl);
}

// ------------------------------------------------------------------------------------------------ errors (§4, V10)

#[test]
fn errors_are_numbered_in_the_coins_namespace() {
    for (error, n, code) in [(Error::NotMinter, 1, 10_901), (Error::ZeroAmount, 2, 10_902)] {
        assert_eq!(error as u32, code);
        assert_eq!(dyor_common::err_code(TAG_MOMENT_COIN, n), code);
        assert_eq!(dyor_common::tag_of(code), Some(TAG_MOMENT_COIN));
    }
    assert_eq!(setup().coin().error_tag(), TAG_MOMENT_COIN);
    // OpenZeppelin's cap error keeps its own code, outside every DyorHQ namespace.
    assert_eq!(FungibleTokenError::ExceededCap as u32, 106);
    assert_eq!(dyor_common::tag_of(FungibleTokenError::ExceededCap as u32), None);
}

#[test]
fn a_try_caller_reads_the_cap_error_as_openzeppelins_and_zero_amount_as_the_coins() {
    let t = setup_with(S, S);
    let alice = Address::generate(&t.e);
    let exceeded = grad_failure(t.coin().try_mint(&alice, &1).unwrap_err());
    assert_eq!(exceeded, GradFailure { origin: ORIGIN_FOREIGN, code: FungibleTokenError::ExceededCap as u32 });
    let zero = grad_failure(t.coin().try_mint(&alice, &0).unwrap_err());
    assert_eq!(zero, GradFailure { origin: TAG_MOMENT_COIN, code: 10_902 });
}
