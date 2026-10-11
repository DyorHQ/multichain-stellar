//! DyorHQ Moments for Stellar: collectible editions in one SEP-50 collection ("DyorHQ Moments").
//!
//! A creator publishes a Moment (metadata URI, price, quote asset, edition cap, collect window). Collectors pay
//! `price × quantity`; 95% goes straight to the creator and 5% to the treasury (policy, capped at 10%), and the
//! editions are minted sequentially to the collector. Every edition carries the creator's royalty (default 5%) for
//! any marketplace that reads it. `token_uri(id)` returns the edition's Moment metadata.
//!
//! OpenSea does not support Stellar (checked 2026-10-11), so Lite Moments are collected and shown in-app; Moments
//! with coins stay on Monad. Built on OpenZeppelin `stellar-tokens` (`NonFungibleToken` with `Base` storage and
//! the royalties storage helpers).
#![no_std]

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token::TokenClient, Address,
    Env, String,
};
use stellar_tokens::non_fungible::{Base, NonFungibleToken};

pub const BPS: u32 = 10_000;
/// Hard caps the admin can never exceed.
pub const MAX_PLATFORM_BPS: u32 = 1_000;
pub const MAX_ROYALTY_BPS: u32 = 1_000;
/// Collect windows: 1 hour to 30 days (the Monad Moments bounds).
pub const MIN_WINDOW: u64 = 3_600;
pub const MAX_WINDOW: u64 = 30 * 86_400;
pub const MAX_PER_COLLECT: u32 = 20;
const MAX_URI: u32 = 256;
const DAY_IN_LEDGERS: u32 = 17_280;
const BUMP: u32 = 90 * DAY_IN_LEDGERS;
const THRESHOLD: u32 = 30 * DAY_IN_LEDGERS;

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub admin: Address,
    pub treasury: Address,
    pub platform_bps: u32,
    pub royalty_bps: u32,
    pub publishing_enabled: bool,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuoteRule {
    pub min_price: i128,
    pub enabled: bool,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Moment {
    pub id: u32,
    pub creator: Address,
    pub uri: String,
    pub price: i128,
    pub quote: Address,
    /// 0 = open edition.
    pub max_editions: u32,
    pub minted: u32,
    pub published_at: u64,
    pub deadline: u64,
    /// Snapshotted at publish: a later policy change never applies to a live Moment.
    pub platform_bps: u32,
    pub royalty_bps: u32,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Config,
    MomentCount,
    Moment(u32),
    TokenMoment(u32),
    Quote(Address),
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    PublishingDisabled = 1,
    QuoteNotAllowed = 2,
    PriceTooLow = 3,
    InvalidWindow = 4,
    InvalidUri = 5,
    UnknownMoment = 6,
    Closed = 7,
    SoldOut = 8,
    InvalidQuantity = 9,
    MaxTotalExceeded = 10,
    InvalidConfig = 11,
}

#[contractevent(topics = ["publish"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Published {
    #[topic]
    pub moment_id: u32,
    #[topic]
    pub creator: Address,
    pub uri: String,
    pub price: i128,
    pub quote: Address,
    pub max_editions: u32,
    pub deadline: u64,
}

#[contractevent(topics = ["collect"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Collected {
    #[topic]
    pub moment_id: u32,
    #[topic]
    pub collector: Address,
    pub quantity: u32,
    pub first_token_id: u32,
    pub paid: i128,
    pub minted: u32,
}

#[contractevent(topics = ["policy"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PolicySet {
    pub config: Config,
}

#[contract]
pub struct Moments;

#[contractimpl]
impl Moments {
    pub fn __constructor(e: &Env, admin: Address, treasury: Address) {
        Base::set_metadata(e, String::from_str(e, ""), String::from_str(e, "DyorHQ Moments"), String::from_str(e, "MOMENT"));
        let cfg = Config { admin, treasury, platform_bps: 500, royalty_bps: 500, publishing_enabled: true };
        e.storage().instance().set(&DataKey::Config, &cfg);
        e.storage().instance().set(&DataKey::MomentCount, &0u32);
    }

    // -------------------------------------------------------------------------------------------- admin

    pub fn set_quote(e: &Env, quote: Address, min_price: i128, enabled: bool) {
        config(e).admin.require_auth();
        if min_price <= 0 {
            panic_with_error!(e, Error::InvalidConfig);
        }
        let key = DataKey::Quote(quote);
        e.storage().persistent().set(&key, &QuoteRule { min_price, enabled });
        e.storage().persistent().extend_ttl(&key, THRESHOLD, BUMP);
    }

    /// Platform share and royalty for Moments published from now on.
    pub fn set_policy(e: &Env, platform_bps: u32, royalty_bps: u32, publishing_enabled: bool) {
        let mut cfg = config(e);
        cfg.admin.require_auth();
        if platform_bps > MAX_PLATFORM_BPS || royalty_bps > MAX_ROYALTY_BPS {
            panic_with_error!(e, Error::InvalidConfig);
        }
        cfg.platform_bps = platform_bps;
        cfg.royalty_bps = royalty_bps;
        cfg.publishing_enabled = publishing_enabled;
        e.storage().instance().set(&DataKey::Config, &cfg);
        PolicySet { config: cfg }.publish(e);
    }

    pub fn set_admin(e: &Env, new_admin: Address) {
        let mut cfg = config(e);
        cfg.admin.require_auth();
        new_admin.require_auth();
        cfg.admin = new_admin;
        e.storage().instance().set(&DataKey::Config, &cfg);
        PolicySet { config: cfg }.publish(e);
    }

    // -------------------------------------------------------------------------------------------- publish & collect

    pub fn publish(e: &Env, creator: Address, uri: String, price: i128, quote: Address, max_editions: u32, window_secs: u64) -> u32 {
        creator.require_auth();
        let cfg = config(e);
        if !cfg.publishing_enabled {
            panic_with_error!(e, Error::PublishingDisabled);
        }
        let rule: QuoteRule = e
            .storage()
            .persistent()
            .get(&DataKey::Quote(quote.clone()))
            .unwrap_or_else(|| panic_with_error!(e, Error::QuoteNotAllowed));
        if !rule.enabled {
            panic_with_error!(e, Error::QuoteNotAllowed);
        }
        if price < rule.min_price {
            panic_with_error!(e, Error::PriceTooLow);
        }
        if !(MIN_WINDOW..=MAX_WINDOW).contains(&window_secs) {
            panic_with_error!(e, Error::InvalidWindow);
        }
        if uri.len() == 0 || uri.len() > MAX_URI {
            panic_with_error!(e, Error::InvalidUri);
        }
        let id: u32 = e.storage().instance().get::<_, u32>(&DataKey::MomentCount).unwrap_or(0) + 1;
        let now = e.ledger().timestamp();
        let m = Moment {
            id,
            creator: creator.clone(),
            uri: uri.clone(),
            price,
            quote: quote.clone(),
            max_editions,
            minted: 0,
            published_at: now,
            deadline: now + window_secs,
            platform_bps: cfg.platform_bps,
            royalty_bps: cfg.royalty_bps,
        };
        save_moment(e, &m);
        e.storage().instance().set(&DataKey::MomentCount, &id);
        e.storage().instance().extend_ttl(THRESHOLD, BUMP);
        Published { moment_id: id, creator, uri, price, quote, max_editions, deadline: m.deadline }.publish(e);
        id
    }

    /// Collects `quantity` editions for `price × quantity` (at most `max_total`). Returns the first token id; the
    /// editions are `first .. first + quantity`.
    pub fn collect(e: &Env, collector: Address, moment_id: u32, quantity: u32, max_total: i128) -> u32 {
        collector.require_auth();
        let mut m = load_moment(e, moment_id);
        if e.ledger().timestamp() >= m.deadline {
            panic_with_error!(e, Error::Closed);
        }
        if quantity == 0 || quantity > MAX_PER_COLLECT {
            panic_with_error!(e, Error::InvalidQuantity);
        }
        if m.max_editions > 0 && m.minted + quantity > m.max_editions {
            panic_with_error!(e, Error::SoldOut);
        }
        let total = m.price.checked_mul(quantity as i128).expect("overflow");
        if total > max_total {
            panic_with_error!(e, Error::MaxTotalExceeded);
        }
        let cfg = config(e);
        let platform = total * m.platform_bps as i128 / BPS as i128;
        let to_creator = total - platform;
        let quote = TokenClient::new(e, &m.quote);
        quote.transfer(&collector, &m.creator, &to_creator);
        if platform > 0 {
            quote.transfer(&collector, &cfg.treasury, &platform);
        }

        let mut first = 0u32;
        for i in 0..quantity {
            let token_id = Base::sequential_mint(e, &collector);
            if i == 0 {
                first = token_id;
            }
            let key = DataKey::TokenMoment(token_id);
            e.storage().persistent().set(&key, &moment_id);
            e.storage().persistent().extend_ttl(&key, THRESHOLD, BUMP);
            if m.royalty_bps > 0 {
                Base::set_token_royalty(e, token_id, &m.creator, m.royalty_bps);
            }
        }
        m.minted += quantity;
        save_moment(e, &m);
        e.storage().instance().extend_ttl(THRESHOLD, BUMP);
        Collected { moment_id, collector, quantity, first_token_id: first, paid: total, minted: m.minted }.publish(e);
        first
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn config(e: &Env) -> Config {
        config(e)
    }

    pub fn quote_rule(e: &Env, quote: Address) -> Option<QuoteRule> {
        e.storage().persistent().get(&DataKey::Quote(quote))
    }

    pub fn moment_count(e: &Env) -> u32 {
        e.storage().instance().get(&DataKey::MomentCount).unwrap_or(0)
    }

    pub fn get_moment(e: &Env, moment_id: u32) -> Moment {
        load_moment(e, moment_id)
    }

    /// The Moment an edition belongs to.
    pub fn moment_of(e: &Env, token_id: u32) -> u32 {
        e.storage()
            .persistent()
            .get(&DataKey::TokenMoment(token_id))
            .unwrap_or_else(|| panic_with_error!(e, Error::UnknownMoment))
    }

    /// ERC-2981-style royalty for a sale of `token_id` at `sale_price`.
    pub fn royalty_info(e: &Env, token_id: u32, sale_price: i128) -> (Address, i128) {
        Base::royalty_info(e, token_id, sale_price)
    }
}

#[contractimpl(contracttrait)]
impl NonFungibleToken for Moments {
    type ContractType = Base;

    /// The edition's Moment metadata (title, media, creator), not a per-token URI.
    fn token_uri(e: &Env, token_id: u32) -> String {
        Base::owner_of(e, token_id); // panics for a token that doesn't exist
        let moment_id = Moments::moment_of(e, token_id);
        load_moment(e, moment_id).uri
    }
}

fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

fn load_moment(e: &Env, id: u32) -> Moment {
    let key = DataKey::Moment(id);
    let m = e.storage().persistent().get(&key).unwrap_or_else(|| panic_with_error!(e, Error::UnknownMoment));
    e.storage().persistent().extend_ttl(&key, THRESHOLD, BUMP);
    m
}

fn save_moment(e: &Env, m: &Moment) {
    let key = DataKey::Moment(m.id);
    e.storage().persistent().set(&key, m);
    e.storage().persistent().extend_ttl(&key, THRESHOLD, BUMP);
}

#[cfg(test)]
mod test;
