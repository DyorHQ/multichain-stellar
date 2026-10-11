extern crate std;

use super::*;
use soroban_sdk::{testutils::Address as _, Address, Env, String};

fn setup() -> (Env, Address, Address, LaunchTokenClient<'static>) {
    let e = Env::default();
    e.mock_all_auths();
    let launchpad = Address::generate(&e);
    let id = e.register(
        LaunchToken,
        (launchpad.clone(), String::from_str(&e, "Dyor Cat"), String::from_str(&e, "DCAT"), 1_000_000_000_0000000i128),
    );
    let client = LaunchTokenClient::new(&e, &id);
    (e, launchpad, id, client)
}

#[test]
fn constructor_mints_supply_to_launchpad() {
    let (e, launchpad, _, t) = setup();
    assert_eq!(t.balance(&launchpad), 1_000_000_000_0000000);
    assert_eq!(t.total_supply(), 1_000_000_000_0000000);
    assert_eq!(t.decimals(), 7);
    assert_eq!(t.symbol(), String::from_str(&e, "DCAT"));
    assert_eq!(t.launchpad(), launchpad);
    assert!(!t.unlocked());
}

#[test]
fn launchpad_can_send_and_receive_before_unlock() {
    let (e, launchpad, _, t) = setup();
    let alice = Address::generate(&e);
    t.transfer(&launchpad, &alice, &100);
    assert_eq!(t.balance(&alice), 100);
    t.transfer(&alice, &launchpad, &40);
    assert_eq!(t.balance(&alice), 60);
}

#[test]
fn holder_to_holder_is_locked_before_unlock() {
    let (e, launchpad, _, t) = setup();
    let alice = Address::generate(&e);
    let bob = Address::generate(&e);
    t.transfer(&launchpad, &alice, &100);
    assert_eq!(t.try_transfer(&alice, &bob, &1).unwrap_err().unwrap(), LaunchTokenError::TransferLocked.into());
    // transfer_from is locked the same way, even with an allowance.
    t.approve(&alice, &bob, &50, &(e.ledger().sequence() + 100));
    assert_eq!(
        t.try_transfer_from(&bob, &alice, &bob, &1).unwrap_err().unwrap(),
        LaunchTokenError::TransferLocked.into()
    );
}

#[test]
fn unlock_opens_transfers_and_only_once() {
    let (e, launchpad, _, t) = setup();
    let alice = Address::generate(&e);
    let bob = Address::generate(&e);
    t.transfer(&launchpad, &alice, &100);
    t.unlock();
    assert!(t.unlocked());
    t.transfer(&alice, &bob, &30);
    assert_eq!(t.balance(&bob), 30);
    assert_eq!(t.try_unlock().unwrap_err().unwrap(), LaunchTokenError::AlreadyUnlocked.into());
}

#[test]
fn unlock_requires_the_launchpad() {
    let e = Env::default();
    let launchpad = Address::generate(&e);
    let id = e.register(
        LaunchToken,
        (launchpad.clone(), String::from_str(&e, "X"), String::from_str(&e, "X"), 10i128),
    );
    let t = LaunchTokenClient::new(&e, &id);
    // No auth mocked: the launchpad has not authorized this call.
    assert!(t.try_unlock().is_err());
}

#[test]
fn holders_can_burn() {
    let (e, launchpad, _, t) = setup();
    let alice = Address::generate(&e);
    t.transfer(&launchpad, &alice, &100);
    t.burn(&alice, &10);
    assert_eq!(t.balance(&alice), 90);
    assert_eq!(t.total_supply(), 1_000_000_000_0000000 - 10);
}
