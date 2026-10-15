//! DyorHQ moments-v2 (DESIGN-stellar-contracts-v2 §9): the Moments factory and ledger. One Moment is one NFT contract
//! deployed from creator + nonce; its address is the Moment's id (L9, L15).
//!
//! - **Policy** ([`policy`]): governance and a guardian with Monad's powers, a dual pause of `publish`, and policies
//!   that apply only to Moments published after a timelock, within a window (§9.2, §16).
//! - **Publish** (here): the creator passes the terms it was shown ([`MomentsTerms`]) by value; moments-v2 refuses any
//!   difference, checks Monad's price ceiling, allocation and window rules, deploys the Moment's NFT, asks the
//!   graduator where the coin will live, computes the bundle rate and snapshots everything into an immutable
//!   [`Moment`]. USDC is the only quote (L9); there is no edition cap.
//! - **Collect** ([`collect`]): 20/5/75 into pull ledgers, the terminal clamp to exactly the threshold, coins promised
//!   at the bundle rate. Completion waits for the keeper; nothing graduates inside a collect (L3).
//! - **Graduation** ([`graduation`]): anyone, through `try_` into moments-graduator; recoverable failures are recorded
//!   and start the stuck clock, successes are checked again before the locker registers the position (§9.3).
//! - **Expiry and withdrawals** ([`collect`]): Monad's rules, tightened so only a recorded failure or the backstop lets
//!   a completed Moment expire (F15, V11); every payout goes to a snapshotted beneficiary.
//! - **Vesting** ([`vesting`]): collectors 60/80/100% over two periods, the creator 20% + 16% per period, minted by
//!   claims within the supply identity (I-M3).
//!
//! No call writes an instance key except the constructor and governance actions, so publishes and collects never
//! conflict on one (§3.5). Nothing extends the instance's or the code's TTL (DECISIONS #10). There is no upgrade path.
//! Errors are `ERR_BASE + 7·100 + n` (V10).
#![no_std]

mod collect;
mod events;
mod graduation;
mod policy;
mod storage;
mod vesting;

pub use collect::{CollectQuote, CollectResult};
pub use events::*;
pub use policy::{
    MomentsTerms, MAX_CREATOR_ALLOC_BPS, MAX_EXTERNAL_BASE, MAX_ROYALTY_BPS, MAX_THRESHOLD, MIN_MIN_PRICE,
    MIN_THRESHOLD,
};
pub use storage::{Config, Ledger, Moment, PendingPolicy, Policy, Position, State};
pub use vesting::{
    collector_vested_bps, creator_vested_bps, SupplyCheck, COLLECTOR_VESTED_BPS, CREATOR_BASE_BPS, CREATOR_PERIODS,
    CREATOR_STEP_BPS,
};

use dyor_common::{
    validate_moments_durations, validate_ttl_policy, GraduatorClient, LockerClient, MomentsDurations, TtlPolicy, BPS,
    TAG_MOMENTS_V2,
};
use policy::{base_ok, policy_ok, price_ceiling};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    contract, contractclient, contracterror, contractimpl, contracttype, panic_with_error, Address, Bytes, BytesN, Env,
    Executable, String,
};

/// S: every Moment's coin supply, 100,000,000 coins at 7 decimals (§14.2). The graduator deploys each coin with this
/// cap.
pub const SUPPLY: i128 = 100_000_000 * 10_000_000;
/// The most editions one collect mints: moment-nft's `MAX_MINT` (§14.2, ruling after CT-06).
pub const MAX_BATCH: u32 = 20;
/// The most Moments one `claim_all` covers.
pub const MAX_CLAIM_IDS: u32 = 20;
/// The share of each harvest round's fee growth the locker pays out; it compounds the rest, so compounded : harvested
/// = 3,333 : 6,667 (§9.1, V3). Compile-time: governance can't change a live Moment's post-graduation split (B13b).
pub const MOMENT_HARVEST_BPS: u32 = 6_667;
/// The creator's share of a harvest's USDC side; the platform gets the rest (Monad's 0.2 : 0.3, §9.1).
pub const MOMENT_HARVEST_CREATOR_BPS: u32 = 4_000;

/// Publish string limits, in bytes (§9.2). A symbol's bytes must also be ASCII letters or digits ([`symbol_ok`]).
const NAME_LEN: (u32, u32) = (1, 32);
const SYMBOL_LEN: (u32, u32) = (2, 10);
const URI_LEN: (u32, u32) = (1, 256);
const MAX_PLACE_LEN: u32 = 64;
const MAX_DATE_LEN: u32 = 32;

/// The local codes of §9.4 in this contract's namespace: on chain `ERR_BASE + 7·100 + n` (§4, V10). 26 stays reserved
/// (it was GraceNotElapsed; Moments have no `mark_stuck`, F15).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `publish` while governance's or the guardian's pause is on.
    PublishingPaused = 10_701,
    /// The terms passed to `publish` differ from the live ones.
    TermsChanged = 10_702,
    PriceTooLow = 10_703,
    /// Above the gross that completes the reserve, `ceil(T·BPS/reserve_bps)`.
    PriceTooHigh = 10_704,
    /// The creator allocation is above the policy's maximum.
    AllocTooHigh = 10_705,
    /// The collect window is outside the durations' `min_window` to `max_window`.
    InvalidWindow = 10_706,
    /// A name, symbol, URI, place or date outside its length limits, or a symbol that isn't all ASCII letters or digits.
    InvalidString = 10_707,
    UnknownMoment = 10_708,
    /// `collect` on a Moment that isn't Collecting.
    NotCollecting = 10_709,
    /// `collect` at or after the deadline.
    WindowClosed = 10_710,
    /// A collect of 0 or more than 20 editions.
    BadQuantity = 10_711,
    /// The collect's gross is above `max_total`.
    MaxTotalExceeded = 10_712,
    /// `expire` before the rules allow it.
    NotExpirable = 10_713,
    /// The Moment's state doesn't allow the call.
    WrongState = 10_714,
    NothingToClaim = 10_715,
    NothingToWithdraw = 10_716,
    /// Kept so the numbering stays as §9.4 lists it. Governance functions check the governance key with
    /// `require_auth`, which fails in the host's auth check before this could be raised.
    NotGovernance = 10_717,
    /// A guardian function when there is no guardian (it renounced).
    NotGuardian = 10_718,
    NoPendingPolicy = 10_719,
    /// `apply_policy` before the proposal's `eta`.
    PolicyNotReady = 10_720,
    /// `apply_policy` after the proposal's window.
    PolicyLapsed = 10_721,
    /// A policy outside §9.2's rules.
    InvalidPolicy = 10_722,
    /// `transfer_guardian` while the guardian's pause is on.
    UnpauseFirst = 10_723,
    /// `claim_all` with more than 20 Moments.
    TooManyIds = 10_724,
    /// A claim would mint beyond `alloc + Σ entitlements`, or a Moment has no coins left for its pool (I-M3).
    SupplyInvariant = 10_725,
    /// An external base that isn't https or is longer than 256 bytes.
    InvalidBase = 10_727,
    /// `cancel_policy` by neither governance nor the guardian.
    NotAuthorized = 10_728,
    /// `accept_governance` with no handoff pending.
    NoProposal = 10_729,
    /// The creator already used this nonce: its NFT address has a Moment.
    NonceUsed = 10_730,
    /// A graduation result failed moments-v2's own checks after the graduator accepted it (an abort).
    GraduationInvalid = 10_731,
    /// A constructor argument outside the rules: USDC not a Stellar Asset Contract, invalid durations or TTL policy,
    /// a locker whose `harvest_interval` differs from the durations' (F6), an invalid external base, or a graduator
    /// wired to another moments-v2, locker, executor or Soroswap factory.
    InvalidConfig = 10_732,
    /// `harvest_payees` for a launch's position: launchpad-v2 answers those (lead ruling during CT-04).
    WrongReference = 10_733,
}
dyor_common::assert_err_codes!(TAG_MOMENTS_V2;
    Error::PublishingPaused = 1,
    Error::TermsChanged = 2,
    Error::PriceTooLow = 3,
    Error::PriceTooHigh = 4,
    Error::AllocTooHigh = 5,
    Error::InvalidWindow = 6,
    Error::InvalidString = 7,
    Error::UnknownMoment = 8,
    Error::NotCollecting = 9,
    Error::WindowClosed = 10,
    Error::BadQuantity = 11,
    Error::MaxTotalExceeded = 12,
    Error::NotExpirable = 13,
    Error::WrongState = 14,
    Error::NothingToClaim = 15,
    Error::NothingToWithdraw = 16,
    Error::NotGovernance = 17,
    Error::NotGuardian = 18,
    Error::NoPendingPolicy = 19,
    Error::PolicyNotReady = 20,
    Error::PolicyLapsed = 21,
    Error::InvalidPolicy = 22,
    Error::UnpauseFirst = 23,
    Error::TooManyIds = 24,
    Error::SupplyInvariant = 25,
    Error::InvalidBase = 27,
    Error::NotAuthorized = 28,
    Error::NoProposal = 29,
    Error::NonceUsed = 30,
    Error::GraduationInvalid = 31,
    Error::InvalidConfig = 32,
    Error::WrongReference = 33,
);

/// What a creator publishes (§9.1). The NFT address is derived from the creator and `nonce`, which the backend picks
/// at random; the address is the Moment's id.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PublishParams {
    /// The Moment's name and symbol, which its NFT and later its coin carry. The name is free-form; the symbol is 2 to
    /// 10 ASCII letters or digits.
    pub name: String,
    pub symbol: String,
    /// Every edition's `token_uri`: the Moment's metadata JSON (off chain, §10).
    pub metadata_uri: String,
    pub media_hash: BytesN<32>,
    pub place: String,
    pub date: String,
    /// USDC per edition.
    pub price: i128,
    pub creator_alloc_bps: u32,
    /// Seconds from now until the collect deadline.
    pub window_secs: u64,
    pub nonce: u64,
}

// ------------------------------------------------------------------------------------------------ client traits
// What moments-v2 calls that dyor-common's traits don't declare.

/// moments-graduator's configuration views (its constructor arguments, §12). The constructor checks the wiring
/// against its own arguments and reads the coin code the terms carry (§9.1).
#[contractclient(name = "GraduatorConfigClient")]
pub trait GraduatorConfig {
    fn moments(e: Env) -> Address;
    fn coin_wasm_hash(e: Env) -> BytesN<32>;
    fn executor(e: Env) -> Address;
    fn locker(e: Env) -> Address;
    fn soroswap_factory(e: Env) -> Address;
}

/// A Moment NFT's SEP-50 metadata, read at graduation: the coin takes the Moment's name and symbol.
#[contractclient(name = "NftMetadataClient")]
pub trait NftMetadata {
    fn name(e: Env) -> String;
    fn symbol(e: Env) -> String;
}

/// The NFT salt of §9.2 (L15): `sha256("dyorhq/moment-nft/v2" ‖ creator.to_xdr() ‖ nonce as 8 big-endian bytes)`.
/// Salts never come from a counter, so two creators' publishes touch disjoint keys.
pub fn nft_salt(e: &Env, creator: &Address, nonce: u64) -> BytesN<32> {
    let mut data = Bytes::from_slice(e, b"dyorhq/moment-nft/v2");
    data.append(&creator.clone().to_xdr(e));
    data.extend_from_array(&nonce.to_be_bytes());
    e.crypto().sha256(&data).into()
}

/// The bundle rate as an exact fraction of coin units per USDC unit
/// (M:contracts/src/moments/MomentsFactory.sol:276-283): `S·(BPS − alloc)·reserve_bps / (BPS·T·(BPS + reserve_bps))`.
/// Collectors buy coins at the price the pool opens at, and an untaken allocation goes to the pool. At
/// T = 771.4285714 USDC and 10% it is 50,000 coins per USDC (§14.5).
pub(crate) fn bundle_rate(threshold: i128, reserve_bps: u32, alloc_bps: u32) -> (i128, i128) {
    let bps = BPS as i128;
    let r = reserve_bps as i128;
    (SUPPLY * (bps - alloc_bps as i128) * r, bps * threshold * (bps + r))
}

fn strings_ok(p: &PublishParams) -> bool {
    let within = |s: &String, (lo, hi): (u32, u32)| (lo..=hi).contains(&s.len());
    within(&p.name, NAME_LEN)
        && symbol_ok(&p.symbol)
        && within(&p.metadata_uri, URI_LEN)
        && p.place.len() <= MAX_PLACE_LEN
        && p.date.len() <= MAX_DATE_LEN
}

/// A symbol is 2 to 10 ASCII letters or digits ([A-Za-z0-9]). The coin takes the Moment's symbol at graduation, and
/// Soroswap's pair names its LP token from the first 6 bytes of each token's symbol, decoded as UTF-8 with an
/// unwrap: a symbol cut inside a multi-byte character there would make every graduation fail, a recorded failure
/// each time, until the creator could expire the Moment and take 70% of its reserve while collectors get no coins.
/// The name is free-form: the pair doesn't read it.
fn symbol_ok(symbol: &String) -> bool {
    let len = symbol.len();
    if !(SYMBOL_LEN.0..=SYMBOL_LEN.1).contains(&len) {
        return false;
    }
    let mut buf = [0u8; SYMBOL_LEN.1 as usize];
    let bytes = &mut buf[..len as usize];
    symbol.copy_into_slice(bytes);
    bytes.iter().all(u8::is_ascii_alphanumeric)
}

#[contract]
pub struct MomentsV2;

#[contractimpl]
impl MomentsV2 {
    /// Every peer is a constructor argument (§3.4): the deploy script precomputes the ids, deploying the locker and
    /// the graduator first. Both pauses start off. Refuses with `InvalidPolicy` a policy outside §9.2's rules, and
    /// with `InvalidConfig` a USDC that isn't a Stellar Asset Contract, invalid durations or TTL policy, a locker whose
    /// `harvest_interval()` differs from `durations.harvest_interval` (F6), an external base that isn't https or is
    /// longer than 256 bytes, or a graduator wired to anything but this contract and this constructor's locker,
    /// executor and Soroswap factory (lead ruling after review), so a mis-wired stack can't be deployed. The coin's
    /// WASM hash, part of the terms, is read from the graduator.
    #[allow(clippy::too_many_arguments)]
    pub fn __constructor(
        e: Env,
        governance: Address,
        guardian: Option<Address>,
        usdc: Address,
        nft_wasm_hash: BytesN<32>,
        graduator: Address,
        locker: Address,
        executor: Address,
        soroswap_factory: Address,
        external_base: String,
        policy: Policy,
        durations: MomentsDurations,
        ttl: TtlPolicy,
    ) {
        if !policy_ok(&policy) {
            panic_with_error!(&e, Error::InvalidPolicy);
        }
        let valid = usdc.executable() == Some(Executable::StellarAsset)
            && validate_moments_durations(&durations).is_ok()
            && validate_ttl_policy(&e, &ttl)
            && base_ok(&e, &external_base)
            && LockerClient::new(&e, &locker).harvest_interval() == durations.harvest_interval;
        let g = GraduatorConfigClient::new(&e, &graduator);
        let wired = g.moments() == e.current_contract_address()
            && g.locker() == locker
            && g.executor() == executor
            && g.soroswap_factory() == soroswap_factory;
        if !valid || !wired {
            panic_with_error!(&e, Error::InvalidConfig);
        }
        let coin_wasm_hash = g.coin_wasm_hash();
        storage::set_config(
            &e,
            &Config {
                governance,
                guardian,
                usdc,
                nft_wasm_hash,
                coin_wasm_hash,
                graduator,
                locker,
                executor,
                soroswap_factory,
                external_base,
                publishing_paused: false,
                guardian_paused: false,
                durations,
                ttl,
            },
        );
        storage::set_policy(&e, &policy);
    }

    /// Publishes a Moment and returns its NFT address, the Moment's id. The creator's auth; `expected` must equal
    /// [`terms`](MomentsV2::terms) field by field. Neither pause may be on.
    pub fn publish(e: Env, creator: Address, p: PublishParams, expected: MomentsTerms) -> Address {
        creator.require_auth();
        let cfg = storage::config(&e);
        if cfg.publishing_paused || cfg.guardian_paused {
            panic_with_error!(&e, Error::PublishingPaused);
        }
        let terms = policy::terms(&e, &cfg);
        if expected != terms {
            panic_with_error!(&e, Error::TermsChanged);
        }
        let pol = terms.policy;
        if p.price < pol.min_price {
            panic_with_error!(&e, Error::PriceTooLow);
        }
        if p.price > price_ceiling(pol.threshold, pol.reserve_bps) {
            panic_with_error!(&e, Error::PriceTooHigh);
        }
        if p.creator_alloc_bps > pol.max_creator_alloc_bps {
            panic_with_error!(&e, Error::AllocTooHigh);
        }
        if !(cfg.durations.min_window..=cfg.durations.max_window).contains(&p.window_secs) {
            panic_with_error!(&e, Error::InvalidWindow);
        }
        if !strings_ok(&p) {
            panic_with_error!(&e, Error::InvalidString);
        }
        let deployer = e.deployer().with_current_contract(nft_salt(&e, &creator, p.nonce));
        let nft = deployer.deployed_address();
        if storage::has_moment(&e, &nft) {
            panic_with_error!(&e, Error::NonceUsed);
        }

        // The NFT's external link is `<base><nft address>`, Monad's `<base><momentId>` with the address as the id.
        let mut external_url = cfg.external_base.to_bytes();
        external_url.append(&nft.to_string().to_bytes());
        deployer.deploy_v2(
            cfg.nft_wasm_hash.clone(),
            (
                e.current_contract_address(),
                p.name.clone(),
                p.symbol.clone(),
                p.metadata_uri.clone(),
                creator.clone(),
                pol.royalty_bps,
                p.media_hash,
                p.place,
                p.date,
                String::from(external_url),
            ),
        );
        let coin = GraduatorClient::new(&e, &cfg.graduator).coin_address(&nft);
        let (rate_num, rate_den) = bundle_rate(pol.threshold, pol.reserve_bps, p.creator_alloc_bps);
        let now = e.ledger().timestamp();
        let m = Moment {
            nft: nft.clone(),
            creator: creator.clone(),
            platform: pol.platform,
            treasury: pol.treasury,
            coin: coin.clone(),
            price: p.price,
            threshold: pol.threshold,
            rate_num,
            rate_den,
            creator_bps: pol.creator_bps,
            platform_bps: pol.platform_bps,
            reserve_bps: pol.reserve_bps,
            creator_alloc_bps: p.creator_alloc_bps,
            expiry_creator_bps: pol.expiry_creator_bps,
            royalty_bps: pol.royalty_bps,
            nonce: p.nonce,
            published_at: now,
            deadline: now + p.window_secs,
        };
        storage::create_moment(&e, &m, &cfg.ttl);
        Published {
            nft: nft.clone(),
            creator,
            nonce: p.nonce,
            coin,
            name: p.name,
            symbol: p.symbol,
            metadata_uri: p.metadata_uri,
            price: p.price,
            threshold: pol.threshold,
            creator_alloc_bps: p.creator_alloc_bps,
            rate_num,
            rate_den,
            deadline: m.deadline,
            durations: cfg.durations,
        }
        .publish(&e);
        nft
    }

    // -------------------------------------------------------------------------------------------- views

    /// The NFT address, and so the Moment id, that `creator` publishing with `nonce` gets.
    pub fn nft_address(e: Env, creator: Address, nonce: u64) -> Address {
        e.deployer().with_current_contract(nft_salt(&e, &creator, nonce)).deployed_address()
    }

    pub fn get_moment(e: Env, nft: Address) -> Moment {
        storage::moment(&e, &nft)
    }

    pub fn ledger(e: Env, nft: Address) -> Ledger {
        storage::ledger(&e, &nft)
    }

    /// `account`'s entitlement and claimed coins in `nft`; zero when it never collected.
    pub fn position(e: Env, nft: Address, account: Address) -> Position {
        storage::position(&e, &nft, &account)
    }

    /// The bundle rate a Moment published with this threshold, reserve share and allocation gets, as
    /// `(rate_num, rate_den)` coin units per USDC unit. `InvalidPolicy` for values no policy allows.
    pub fn bundle_rate(e: Env, threshold: i128, reserve_bps: u32, alloc_bps: u32) -> (i128, i128) {
        let valid = (MIN_THRESHOLD..=MAX_THRESHOLD).contains(&threshold)
            && reserve_bps > 0
            && reserve_bps <= BPS
            && alloc_bps <= MAX_CREATOR_ALLOC_BPS;
        if !valid {
            panic_with_error!(&e, Error::InvalidPolicy);
        }
        bundle_rate(threshold, reserve_bps, alloc_bps)
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_MOMENTS_V2
    }
}

#[cfg(test)]
mod test;
