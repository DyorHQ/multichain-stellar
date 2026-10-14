//! DyorHQ moment-nft (DESIGN-stellar-contracts-v2 §10): one SEP-50 contract per Moment; the edition number is the token
//! id.
//!
//! - **Identity.** moments-v2 deploys one per Moment from creator + nonce (L15). This contract's address is the
//!   Moment's id; there is no numeric Moment id (L9).
//! - **Editions** (`mint`): the minter (moments-v2) mints 1 to `MAX_MINT` editions per call, numbered from 1 with no
//!   gaps, so a collector's edition number is their rank, as on Monad (M:contracts/src/moments/MomentNFT.sol:89-98).
//!   Each one goes through OpenZeppelin's `Base::mint(e, to, id)` (oz:src/non_fungible/storage.rs:717), which emits
//!   the SEP-50 `mint` event the indexer follows.
//! - **Close** (`close`): the minter fixes the edition size once, at graduation or at expiry. Nothing mints after
//!   it; editions stay transferable.
//! - **Royalties**: the default royalty is `royalty_bps` to the creator, set once at construction
//!   (oz:src/non_fungible/extensions/royalties/storage.rs:49); no edition has its own.
//! - **Metadata** is off chain [D]: `token_uri(id)` returns the Moment's metadata URI for every edition. The
//!   provenance fields (media hash, place, date, external URL) are on chain and have no setter.
//!
//! There is no burn and no admin, and no call extends the instance's TTL (DECISIONS #10): the keeper keeps the
//! instance alive.
#![no_std]

use dyor_common::TAG_MOMENT_NFT;
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, Address, BytesN, Env, String,
};
use stellar_tokens::non_fungible::{Base, NonFungibleToken};

/// The most editions one `mint` creates: a collect's quantity cap, as on Monad (MomentTypes.MAX_BATCH).
pub const MAX_MINT: u32 = 20;

/// The Moment's provenance, written once at construction (§10).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Provenance {
    /// SHA-256 of the Moment's media.
    pub media_hash: BytesN<32>,
    pub place: String,
    pub date: String,
    pub external_url: String,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    // instance, which the keeper keeps alive (§13); OpenZeppelin keeps the metadata and the default royalty there too,
    // and the owners, balances and approvals in entries of their own.
    Minter,
    Creator,
    MetadataUri,
    Provenance,
    /// Editions minted so far; the next edition number is this plus one.
    Minted,
    /// Set by `close`: the frozen edition size.
    EditionSize,
}

/// The local codes of §10 in this contract's namespace: on chain `ERR_BASE + 8·100 + n` (§4, V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// Kept so the numbering stays as §10 lists it. `mint` and `close` check the minter's own auth, which fails with
    /// the host's auth error before any contract code could raise this.
    NotMinter = 10_801,
    /// `mint` after `close`.
    Closed = 10_802,
    /// `mint` of 0 or more than `MAX_MINT` editions.
    BadQuantity = 10_803,
    /// `close` called twice.
    AlreadyClosed = 10_804,
}
dyor_common::assert_err_codes!(TAG_MOMENT_NFT;
    Error::NotMinter = 1,
    Error::Closed = 2,
    Error::BadQuantity = 3,
    Error::AlreadyClosed = 4,
);

/// The edition size is fixed: editions 1 to `edition_size` exist, and nothing mints any more.
#[contractevent(topics = ["closed"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Closed {
    pub edition_size: u32,
}

#[contract]
pub struct MomentNft;

#[contractimpl]
impl MomentNft {
    /// moments-v2 deploys this at publish with itself as `minter`. `royalty_bps` of every sale is suggested to the
    /// creator; OpenZeppelin refuses more than 100% (moments-v2's policy caps it at 10%).
    #[allow(clippy::too_many_arguments)]
    pub fn __constructor(
        e: &Env,
        minter: Address,
        name: String,
        symbol: String,
        metadata_uri: String,
        creator: Address,
        royalty_bps: u32,
        media_hash: BytesN<32>,
        place: String,
        date: String,
        external_url: String,
    ) {
        // No base URI: `token_uri` returns the Moment's URI as it is, not `base ‖ id`.
        Base::set_metadata(e, String::from_str(e, ""), name, symbol);
        Base::set_default_royalty(e, &creator, royalty_bps);
        let s = e.storage().instance();
        s.set(&DataKey::Minter, &minter);
        s.set(&DataKey::Creator, &creator);
        s.set(&DataKey::MetadataUri, &metadata_uri);
        s.set(&DataKey::Provenance, &Provenance { media_hash, place, date, external_url });
        s.set(&DataKey::Minted, &0u32);
    }

    /// Mints `qty` editions to `to`, numbered on from the last one, and returns the first edition number. The minter
    /// only, 1 to `MAX_MINT` at a time, and never after `close`.
    pub fn mint(e: &Env, to: Address, qty: u32) -> u32 {
        Self::minter(e).require_auth();
        if Self::closed(e) {
            panic_with_error!(e, Error::Closed);
        }
        if qty == 0 || qty > MAX_MINT {
            panic_with_error!(e, Error::BadQuantity);
        }
        let minted = Self::minted(e);
        let first = minted + 1;
        for id in first..first + qty {
            Base::mint(e, &to, id);
        }
        e.storage().instance().set(&DataKey::Minted, &(minted + qty));
        first
    }

    /// Fixes the edition size at the editions minted so far. The minter only, once: at graduation or at expiry.
    pub fn close(e: &Env) {
        Self::minter(e).require_auth();
        if Self::closed(e) {
            panic_with_error!(e, Error::AlreadyClosed);
        }
        let edition_size = Self::minted(e);
        e.storage().instance().set(&DataKey::EditionSize, &edition_size);
        Closed { edition_size }.publish(e);
    }

    /// ERC-2981-style royalty for a sale of edition `token_id` at `sale_price`: `(creator, sale_price·royalty_bps /
    /// BPS)`. Panics for an edition that doesn't exist.
    pub fn royalty_info(e: &Env, token_id: u32, sale_price: i128) -> (Address, i128) {
        Base::royalty_info(e, token_id, sale_price)
    }

    // -------------------------------------------------------------------------------------------- views

    /// moments-v2, the only account that mints and closes.
    pub fn minter(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Minter).unwrap()
    }

    /// The Moment's creator, who receives the royalty.
    pub fn creator(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Creator).unwrap()
    }

    /// Whether the edition size is fixed.
    pub fn closed(e: &Env) -> bool {
        e.storage().instance().has(&DataKey::EditionSize)
    }

    /// Editions minted so far; they are numbered 1 to `minted`.
    pub fn minted(e: &Env) -> u32 {
        e.storage().instance().get(&DataKey::Minted).unwrap()
    }

    /// The fixed edition size once closed (`minted` at `close`, 0 for a Moment nobody collected), else `None`: an
    /// open edition.
    pub fn edition_size(e: &Env) -> Option<u32> {
        e.storage().instance().get(&DataKey::EditionSize)
    }

    pub fn provenance(e: &Env) -> Provenance {
        e.storage().instance().get(&DataKey::Provenance).unwrap()
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_MOMENT_NFT
    }
}

// OpenZeppelin's SEP-50 functions as they are (`balance`, `owner_of`, `transfer`, `transfer_from`, `approve`,
// `approve_for_all`, `get_approved`, `is_approved_for_all`, `name`, `symbol`), except `token_uri`.
#[contractimpl(contracttrait)]
impl NonFungibleToken for MomentNft {
    type ContractType = Base;

    /// The Moment's metadata URI, the same for every edition. Panics for an edition that doesn't exist.
    fn token_uri(e: &Env, token_id: u32) -> String {
        Base::owner_of(e, token_id);
        e.storage().instance().get(&DataKey::MetadataUri).unwrap()
    }
}

#[cfg(test)]
mod test;
