//! moment-nft (§10, §18.1): edition numbering, close and edition size, royalty, provenance, the minter's auth, the
//! SEP-50 functions OpenZeppelin provides, and the cost of the largest collect.
extern crate std;

use super::*;
use soroban_sdk::testutils::{
    Address as _, AuthorizedFunction, AuthorizedInvocation, ContractEvents, Events as _, MockAuth, MockAuthInvoke,
};
use soroban_sdk::{vec, Event as _, IntoVal, Symbol, Val, Vec};
use std::vec::Vec as StdVec;
use stellar_tokens::non_fungible::{Mint, NonFungibleTokenError};

const ROYALTY_BPS: u32 = 500;
const URI: &str = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/moment.json";
const PLACE: &str = "Lisbon, Portugal";
const DATE: &str = "2026-10-14";
const EXTERNAL_URL: &str = "https://dyorhq.fun/moments/lisbon-sunset";

// ------------------------------------------------------------------------------------------------ stand-ins

/// Stands in for moments-v2: it mints and closes through dyor-common's `MomentNft` client, as moments-v2 does at
/// collect, graduation and expiry.
#[contract]
pub struct TestMoments;

#[contractimpl]
impl TestMoments {
    pub fn collect(e: Env, nft: Address, to: Address, qty: u32) -> u32 {
        dyor_common::MomentNftClient::new(&e, &nft).mint(&to, &qty)
    }

    pub fn end(e: Env, nft: Address) {
        dyor_common::MomentNftClient::new(&e, &nft).close();
    }
}

// ------------------------------------------------------------------------------------------------ setup

struct T {
    e: Env,
    id: Address,
    minter: Address,
    creator: Address,
}

/// A Moment NFT with `royalty_bps`, from `wasm` when given, else the native contract. Every auth is mocked.
fn setup_with(royalty_bps: u32, wasm: Option<&[u8]>) -> T {
    let e = Env::default();
    e.mock_all_auths();
    e.cost_estimate().budget().reset_unlimited();
    let minter = Address::generate(&e);
    let creator = Address::generate(&e);
    let args = args(&e, &minter, &creator, royalty_bps);
    let id = match wasm {
        Some(wasm) => e.register(wasm, args),
        None => e.register(MomentNft, args),
    };
    T { e, id, minter, creator }
}

fn setup() -> T {
    setup_with(ROYALTY_BPS, None)
}

#[allow(clippy::type_complexity)]
fn args(
    e: &Env,
    minter: &Address,
    creator: &Address,
    royalty_bps: u32,
) -> (Address, String, String, String, Address, u32, BytesN<32>, String, String, String) {
    (
        minter.clone(),
        String::from_str(e, "Lisbon Sunset"),
        String::from_str(e, "SUNSET"),
        String::from_str(e, URI),
        creator.clone(),
        royalty_bps,
        media_hash(e),
        String::from_str(e, PLACE),
        String::from_str(e, DATE),
        String::from_str(e, EXTERNAL_URL),
    )
}

fn media_hash(e: &Env) -> BytesN<32> {
    BytesN::from_array(e, &[0xab; 32])
}

impl T {
    fn nft(&self) -> MomentNftClient<'_> {
        MomentNftClient::new(&self.e, &self.id)
    }

    fn account(&self) -> Address {
        Address::generate(&self.e)
    }

    /// The editions `owner` holds, by asking `owner_of` for every edition minted.
    fn editions_of(&self, owner: &Address) -> StdVec<u32> {
        (1..=self.nft().minted()).filter(|id| self.nft().owner_of(id) == *owner).collect()
    }

    /// This NFT's events in the last invocation.
    fn events(&self) -> ContractEvents {
        self.e.events().all().filter_by_contract(&self.id)
    }

    /// The call `fn_name(args)` on this NFT, for a signer to authorize.
    fn call<'a>(&'a self, fn_name: &'a str, args: Vec<Val>) -> MockAuthInvoke<'a> {
        MockAuthInvoke { contract: &self.id, fn_name, args, sub_invokes: &[] }
    }
}

fn err(error: Error) -> soroban_sdk::Error {
    error.into()
}

fn oz(error: NonFungibleTokenError) -> soroban_sdk::Error {
    error.into()
}

/// The contract error a `try_` call failed with.
fn failure<R: core::fmt::Debug, C: core::fmt::Debug>(
    r: Result<R, Result<soroban_sdk::Error, C>>,
) -> soroban_sdk::Error {
    r.unwrap_err().unwrap()
}

// ------------------------------------------------------------------------------------------------ construction

#[test]
fn construction_sets_the_moment_up_open_and_empty() {
    let t = setup();
    let nft = t.nft();
    assert_eq!(nft.name(), String::from_str(&t.e, "Lisbon Sunset"));
    assert_eq!(nft.symbol(), String::from_str(&t.e, "SUNSET"));
    assert_eq!(nft.minter(), t.minter);
    assert_eq!(nft.creator(), t.creator);
    assert!(!nft.closed());
    assert_eq!(nft.minted(), 0);
    assert_eq!(nft.edition_size(), None);
    assert_eq!(
        nft.provenance(),
        Provenance {
            media_hash: media_hash(&t.e),
            place: String::from_str(&t.e, PLACE),
            date: String::from_str(&t.e, DATE),
            external_url: String::from_str(&t.e, EXTERNAL_URL),
        }
    );
    // No edition exists yet.
    assert_eq!(failure(nft.try_owner_of(&1)), oz(NonFungibleTokenError::NonExistentToken));
    assert_eq!(failure(nft.try_token_uri(&1)), oz(NonFungibleTokenError::NonExistentToken));
}

#[test]
#[should_panic(expected = "Error(Contract, #212)")]
fn a_royalty_above_100_percent_is_refused() {
    setup_with(10_001, None);
}

#[test]
fn errors_are_numbered_in_the_nfts_namespace() {
    let expected = [
        (Error::NotMinter, 10_801),
        (Error::Closed, 10_802),
        (Error::BadQuantity, 10_803),
        (Error::AlreadyClosed, 10_804),
    ];
    for (error, code) in expected {
        assert_eq!(error as u32, code);
        assert_eq!(dyor_common::tag_of(code), Some(TAG_MOMENT_NFT));
    }
    assert_eq!(setup().nft().error_tag(), TAG_MOMENT_NFT);
}

// ------------------------------------------------------------------------------------------------ mint

#[test]
fn edition_numbers_start_at_one_and_run_on_across_mints() {
    let t = setup();
    let nft = t.nft();
    let (alice, bob) = (t.account(), t.account());

    assert_eq!(nft.mint(&alice, &3), 1);
    assert_eq!(nft.mint(&bob, &2), 4);
    assert_eq!(nft.mint(&alice, &MAX_MINT), 6);
    assert_eq!(nft.mint(&bob, &1), 26);

    assert_eq!(nft.minted(), 26);
    let alice_editions: StdVec<u32> = (1..=3).chain(6..=25).collect();
    assert_eq!(t.editions_of(&alice), alice_editions);
    assert_eq!(t.editions_of(&bob), [4, 5, 26]);
    assert_eq!((nft.balance(&alice), nft.balance(&bob)), (23, 3));
    // Nothing exists outside 1..=minted.
    assert_eq!(failure(nft.try_owner_of(&0)), oz(NonFungibleTokenError::NonExistentToken));
    assert_eq!(failure(nft.try_owner_of(&27)), oz(NonFungibleTokenError::NonExistentToken));
}

#[test]
fn a_mint_emits_one_sep50_mint_event_per_edition() {
    let t = setup();
    let alice = t.account();
    t.nft().mint(&alice, &1);
    t.nft().mint(&alice, &3);
    let mints: StdVec<_> = (2..=4).map(|token_id| Mint { to: alice.clone(), token_id }.to_xdr(&t.e, &t.id)).collect();
    assert_eq!(t.events(), mints);
}

#[test]
fn a_quantity_outside_one_to_twenty_is_refused() {
    let t = setup();
    let nft = t.nft();
    let alice = t.account();
    assert_eq!(failure(nft.try_mint(&alice, &0)), err(Error::BadQuantity));
    assert_eq!(failure(nft.try_mint(&alice, &(MAX_MINT + 1))), err(Error::BadQuantity));
    assert_eq!(failure(nft.try_mint(&alice, &u32::MAX)), err(Error::BadQuantity));
    // A refused mint leaves nothing behind.
    assert_eq!((nft.minted(), nft.balance(&alice)), (0, 0));
    assert_eq!(nft.mint(&alice, &1), 1);
    assert_eq!(nft.mint(&alice, &MAX_MINT), 2);
    assert_eq!(nft.minted(), 21);
}

// ------------------------------------------------------------------------------------------------ close

#[test]
fn close_freezes_the_edition_size_at_the_editions_minted() {
    let t = setup();
    let nft = t.nft();
    let (alice, bob) = (t.account(), t.account());
    nft.mint(&alice, &7);
    nft.mint(&bob, &5);

    nft.close();
    assert_eq!(t.events(), [Closed { edition_size: 12 }.to_xdr(&t.e, &t.id)]);
    assert!(nft.closed());
    assert_eq!(nft.edition_size(), Some(nft.minted()));
    assert_eq!(nft.edition_size(), Some(12));

    // Minting after close and closing twice both fail, and change nothing.
    assert_eq!(failure(nft.try_mint(&alice, &1)), err(Error::Closed));
    assert_eq!(failure(nft.try_close()), err(Error::AlreadyClosed));
    assert_eq!((nft.minted(), nft.edition_size()), (12, Some(12)));
    assert_eq!(failure(nft.try_owner_of(&13)), oz(NonFungibleTokenError::NonExistentToken));
}

#[test]
fn a_moment_nobody_collected_closes_at_zero() {
    let t = setup();
    t.nft().close();
    assert_eq!(t.nft().edition_size(), Some(0));
    assert_eq!(failure(t.nft().try_mint(&t.account(), &1)), err(Error::Closed));
}

// ------------------------------------------------------------------------------------------------ royalty, metadata

#[test]
fn royalty_info_pays_royalty_bps_to_the_creator() {
    let t = setup();
    let nft = t.nft();
    let alice = t.account();
    nft.mint(&alice, &2);
    // 5% of 100 USDC (7 decimals), for every edition, also after close and after a transfer.
    assert_eq!(nft.royalty_info(&1, &1_000_000_000), (t.creator.clone(), 50_000_000));
    nft.close();
    nft.transfer(&alice, &t.account(), &2);
    assert_eq!(nft.royalty_info(&2, &1_000_000_000), (t.creator.clone(), 50_000_000));
    assert_eq!(nft.royalty_info(&2, &19), (t.creator.clone(), 0));
    assert_eq!(failure(nft.try_royalty_info(&3, &1_000)), oz(NonFungibleTokenError::NonExistentToken));
}

#[test]
fn a_zero_royalty_still_names_the_creator() {
    let t = setup_with(0, None);
    t.nft().mint(&t.account(), &1);
    assert_eq!(t.nft().royalty_info(&1, &1_000_000_000), (t.creator.clone(), 0));
}

#[test]
fn token_uri_is_the_moments_metadata_uri_for_every_edition() {
    let t = setup();
    let nft = t.nft();
    nft.mint(&t.account(), &3);
    for id in 1..=3 {
        assert_eq!(nft.token_uri(&id), String::from_str(&t.e, URI));
    }
    assert_eq!(failure(nft.try_token_uri(&4)), oz(NonFungibleTokenError::NonExistentToken));
}

// ------------------------------------------------------------------------------------------------ auth

#[test]
fn mint_and_close_carry_the_minters_auth() {
    let t = setup();
    let alice = t.account();
    t.nft().mint(&alice, &3);
    let invocation = |name: &str, args: Vec<Val>| AuthorizedInvocation {
        function: AuthorizedFunction::Contract((t.id.clone(), Symbol::new(&t.e, name), args)),
        sub_invocations: std::vec![],
    };
    assert_eq!(t.e.auths(), [(t.minter.clone(), invocation("mint", (alice.clone(), 3u32).into_val(&t.e)))]);
    t.nft().close();
    assert_eq!(t.e.auths(), [(t.minter.clone(), invocation("close", vec![&t.e]))]);
}

#[test]
fn only_the_minter_can_mint_or_close() {
    let t = setup();
    let nft = t.nft();
    let (alice, mallory) = (t.account(), t.account());
    let mint = t.call("mint", (alice.clone(), 2u32).into_val(&t.e));
    let close = t.call("close", ().into_val(&t.e));
    t.e.set_auths(&[]);

    // Nobody has authorized these calls as the minter.
    assert!(nft.try_mint(&alice, &2).is_err());
    assert!(nft.try_close().is_err());
    // Someone else's signature doesn't do either: not a stranger's, the creator's or the collector's.
    for signer in [&mallory, &t.creator, &alice] {
        assert!(nft.mock_auths(&[MockAuth { address: signer, invoke: &mint }]).try_mint(&alice, &2).is_err());
        assert!(nft.mock_auths(&[MockAuth { address: signer, invoke: &close }]).try_close().is_err());
    }
    assert_eq!((nft.minted(), nft.closed()), (0, false));

    assert_eq!(nft.mock_auths(&[MockAuth { address: &t.minter, invoke: &mint }]).mint(&alice, &2), 1);
    nft.mock_auths(&[MockAuth { address: &t.minter, invoke: &close }]).close();
    assert_eq!(nft.edition_size(), Some(2));
}

#[test]
fn moments_v2_mints_and_closes_through_the_shared_client() {
    let e = Env::default();
    let moments = e.register(TestMoments, ());
    let other = e.register(TestMoments, ());
    let creator = Address::generate(&e);
    let id = e.register(MomentNft, args(&e, &moments, &creator, ROYALTY_BPS));
    let (alice, bob) = (Address::generate(&e), Address::generate(&e));
    // No mocked auth: the minter contract's direct call authorizes itself, and nothing else does.
    let (minter, stranger) = (TestMomentsClient::new(&e, &moments), TestMomentsClient::new(&e, &other));

    assert_eq!(minter.collect(&id, &alice, &4), 1);
    assert_eq!(minter.collect(&id, &bob, &MAX_MINT), 5);
    assert!(stranger.try_collect(&id, &alice, &1).is_err());
    assert!(stranger.try_end(&id).is_err());

    minter.end(&id);
    let nft = MomentNftClient::new(&e, &id);
    assert_eq!((nft.minted(), nft.edition_size()), (24, Some(24)));
    assert!(minter.try_collect(&id, &alice, &1).is_err());
    assert!(minter.try_end(&id).is_err());
}

// ------------------------------------------------------------------------------------------------ SEP-50

#[test]
fn editions_move_by_transfer_approval_and_operator_also_after_close() {
    let t = setup();
    let nft = t.nft();
    let (alice, bob, carol, market) = (t.account(), t.account(), t.account(), t.account());
    nft.mint(&alice, &3);
    nft.close();
    let live_until = t.e.ledger().sequence() + 1_000;

    nft.transfer(&alice, &bob, &1);
    nft.approve(&alice, &market, &2, &live_until);
    assert_eq!(nft.get_approved(&2), Some(market.clone()));
    nft.transfer_from(&market, &alice, &carol, &2);
    assert_eq!(nft.get_approved(&2), None);
    nft.approve_for_all(&alice, &market, &live_until);
    assert!(nft.is_approved_for_all(&alice, &market));
    nft.transfer_from(&market, &alice, &carol, &3);

    // Editions keep their numbers when they move.
    assert_eq!((t.editions_of(&bob), t.editions_of(&carol)), (std::vec![1], std::vec![2, 3]));
    assert_eq!((nft.balance(&alice), nft.balance(&bob), nft.balance(&carol)), (0, 1, 2));
    // Only the owner, an approved account or an operator moves an edition.
    assert_eq!(failure(nft.try_transfer(&alice, &bob, &2)), oz(NonFungibleTokenError::IncorrectOwner));
    assert_eq!(failure(nft.try_transfer_from(&bob, &carol, &bob, &2)), oz(NonFungibleTokenError::InsufficientApproval));
}

#[test]
fn there_is_no_burn_and_no_admin() {
    let t = setup();
    t.nft().mint(&t.account(), &1);
    let missing = [
        "burn",
        "burn_from",
        "set_default_royalty",
        "set_token_royalty",
        "remove_token_royalty",
        "set_metadata",
        "set_minter",
        "set_admin",
        "upgrade",
    ];
    for name in missing {
        let r = t.e.try_invoke_contract::<Val, soroban_sdk::Error>(&t.id, &Symbol::new(&t.e, name), vec![&t.e]);
        assert!(r.is_err(), "{name} must not exist");
    }
    assert_eq!(t.nft().minted(), 1);
}

// ------------------------------------------------------------------------------------------------ resources

/// §10 acceptance: the largest collect, `mint(…, 20)`, writes at most 25 entries. Measured on the release WASM when
/// build.sh has written it to contracts/dist (VM costs included), else on the native contract, which leaves the VM's
/// instructions out but writes exactly the same entries. The minter here signs as an account, so the count includes
/// its auth nonce; moments-v2 calls as a contract and writes one entry fewer.
#[test]
fn minting_twenty_editions_writes_at_most_25_entries() {
    let wasm = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../dist/dyor_moment_nft.wasm")).ok();
    let t = setup_with(ROYALTY_BPS, wasm.as_deref());
    std::println!("measuring the {}", if wasm.is_some() { "release WASM" } else { "native contract" });
    let (alice, bob) = (t.account(), t.account());

    let measure = |what: &str, to: &Address| {
        t.nft().mint(to, &MAX_MINT);
        let r = t.e.cost_estimate().resources();
        std::println!("{what}: {} instructions, {} write entries", r.instructions, r.write_entries);
        assert!(r.write_entries <= 25, "{what}: {} write entries", r.write_entries);
        r.write_entries
    };
    // 20 owner entries, the collector's balance, the instance (the edition counter) and the nonce.
    assert_eq!(measure("first collect of 20", &alice), 23);
    assert_eq!(measure("second collect of 20", &alice), 23);
    assert_eq!(measure("collect of 20 by another collector", &bob), 23);
    assert_eq!(t.nft().minted(), 60);
}
