extern crate std;

use super::*;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    token::{StellarAssetClient, TokenClient},
    Address, Env, String,
};

const ONE: i128 = 10_000_000;

struct T {
    e: Env,
    treasury: Address,
    creator: Address,
    alice: Address,
    bob: Address,
    quote: Address,
    m: MomentsClient<'static>,
}

fn setup() -> T {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().with_mut(|l| l.timestamp = 1_800_000_000);
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);
    let creator = Address::generate(&e);
    let alice = Address::generate(&e);
    let bob = Address::generate(&e);
    let quote = e.register_stellar_asset_contract_v2(Address::generate(&e)).address();
    let sac = StellarAssetClient::new(&e, &quote);
    sac.mint(&alice, &(1_000 * ONE));
    sac.mint(&bob, &(1_000 * ONE));
    let id = e.register(Moments, (admin, treasury.clone()));
    let m = MomentsClient::new(&e, &id);
    m.set_quote(&quote, &(ONE / 10), &true);
    T { e, treasury, creator, alice, bob, quote, m }
}

fn publish(t: &T, price: i128, max: u32, window: u64) -> u32 {
    t.m.publish(&t.creator, &String::from_str(&t.e, "ipfs://bafy-moment-1"), &price, &t.quote, &max, &window)
}

fn bal(t: &T, who: &Address) -> i128 {
    TokenClient::new(&t.e, &t.quote).balance(who)
}

#[test]
fn collection_metadata() {
    let t = setup();
    assert_eq!(t.m.name(), String::from_str(&t.e, "DyorHQ Moments"));
    assert_eq!(t.m.symbol(), String::from_str(&t.e, "MOMENT"));
}

#[test]
fn publish_and_collect_split_95_5_and_mint_editions() {
    let t = setup();
    let id = publish(&t, 2 * ONE, 10, 86_400);
    assert_eq!(id, 1);
    let first = t.m.collect(&t.alice, &id, &3, &(6 * ONE));
    assert_eq!(bal(&t, &t.alice), 1_000 * ONE - 6 * ONE);
    assert_eq!(bal(&t, &t.creator), 6 * ONE * 95 / 100);
    assert_eq!(bal(&t, &t.treasury), 6 * ONE * 5 / 100);
    assert_eq!(t.m.balance(&t.alice), 3);
    for tok in first..first + 3 {
        assert_eq!(t.m.owner_of(&tok), t.alice);
        assert_eq!(t.m.moment_of(&tok), id);
        assert_eq!(t.m.token_uri(&tok), String::from_str(&t.e, "ipfs://bafy-moment-1"));
    }
    assert_eq!(t.m.get_moment(&id).minted, 3);
}

#[test]
fn editions_are_transferable_and_carry_the_creator_royalty() {
    let t = setup();
    let id = publish(&t, ONE, 0, 3_600);
    let tok = t.m.collect(&t.alice, &id, &1, &ONE);
    t.m.transfer(&t.alice, &t.bob, &tok);
    assert_eq!(t.m.owner_of(&tok), t.bob);
    let (receiver, amount) = t.m.royalty_info(&tok, &(100 * ONE));
    assert_eq!(receiver, t.creator);
    assert_eq!(amount, 5 * ONE);
}

#[test]
fn sold_out_window_quantity_and_max_total_are_enforced() {
    let t = setup();
    let id = publish(&t, ONE, 2, 3_600);
    assert_eq!(t.m.try_collect(&t.alice, &id, &3, &(3 * ONE)).unwrap_err().unwrap(), Error::SoldOut.into());
    assert_eq!(t.m.try_collect(&t.alice, &id, &2, &(2 * ONE - 1)).unwrap_err().unwrap(), Error::MaxTotalExceeded.into());
    assert_eq!(t.m.try_collect(&t.alice, &id, &0, &ONE).unwrap_err().unwrap(), Error::InvalidQuantity.into());
    t.m.collect(&t.alice, &id, &2, &(2 * ONE));
    assert_eq!(t.m.try_collect(&t.bob, &id, &1, &ONE).unwrap_err().unwrap(), Error::SoldOut.into());

    let open = publish(&t, ONE, 0, 3_600);
    assert_eq!(t.m.try_collect(&t.alice, &open, &21, &(21 * ONE)).unwrap_err().unwrap(), Error::InvalidQuantity.into());
    t.e.ledger().with_mut(|l| l.timestamp += 3_600);
    assert_eq!(t.m.try_collect(&t.alice, &open, &1, &ONE).unwrap_err().unwrap(), Error::Closed.into());
}

#[test]
fn publish_validates_price_window_uri_and_quote() {
    let t = setup();
    let uri = String::from_str(&t.e, "ipfs://x");
    assert_eq!(
        t.m.try_publish(&t.creator, &uri, &(ONE / 10 - 1), &t.quote, &0, &3_600).unwrap_err().unwrap(),
        Error::PriceTooLow.into()
    );
    assert_eq!(t.m.try_publish(&t.creator, &uri, &ONE, &t.quote, &0, &3_599).unwrap_err().unwrap(), Error::InvalidWindow.into());
    assert_eq!(
        t.m.try_publish(&t.creator, &uri, &ONE, &t.quote, &0, &(30 * 86_400 + 1)).unwrap_err().unwrap(),
        Error::InvalidWindow.into()
    );
    assert_eq!(
        t.m.try_publish(&t.creator, &String::from_str(&t.e, ""), &ONE, &t.quote, &0, &3_600).unwrap_err().unwrap(),
        Error::InvalidUri.into()
    );
    let other = t.e.register_stellar_asset_contract_v2(Address::generate(&t.e)).address();
    assert_eq!(t.m.try_publish(&t.creator, &uri, &ONE, &other, &0, &3_600).unwrap_err().unwrap(), Error::QuoteNotAllowed.into());
}

#[test]
fn policy_changes_apply_to_new_moments_only_and_are_capped() {
    let t = setup();
    let live = publish(&t, 10 * ONE, 0, 3_600);
    t.m.set_policy(&1_000, &0, &true);
    let later = publish(&t, 10 * ONE, 0, 3_600);
    t.m.collect(&t.alice, &live, &1, &(10 * ONE));
    assert_eq!(bal(&t, &t.treasury), ONE / 2); // 5% snapshot
    t.m.collect(&t.alice, &later, &1, &(10 * ONE));
    assert_eq!(bal(&t, &t.treasury), ONE / 2 + ONE); // 10% for the new one
    assert_eq!(t.m.try_set_policy(&1_001, &0, &true).unwrap_err().unwrap(), Error::InvalidConfig.into());
    t.m.set_policy(&500, &500, &false);
    assert_eq!(
        t.m.try_publish(&t.creator, &String::from_str(&t.e, "ipfs://y"), &ONE, &t.quote, &0, &3_600).unwrap_err().unwrap(),
        Error::PublishingDisabled.into()
    );
}

#[test]
fn collect_requires_the_collectors_signature() {
    let t = setup();
    let id = publish(&t, ONE, 0, 3_600);
    t.e.set_auths(&[]);
    assert!(t.m.try_collect(&t.alice, &id, &1, &ONE).is_err());
}
