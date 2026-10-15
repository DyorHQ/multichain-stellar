//! DyorHQ launchpad-v2 (DESIGN-stellar-contracts-v2 §5): one contract runs every launch.
//!
//! - **launch** deploys a launch-token-v2 at an address fixed by the creator and a nonce (L15), moves the launch fee
//!   (10 XLM, O6) from the creator to the launchpad and books it on the launch, and opens a constant-product bonding
//!   curve with a phantom quote reserve ([`curve`]). The creator binds every term by value (`LaunchTerms`, P2): the
//!   fees and split, the snipe schedule, the launch fee, the quote's economics, the venue and the fallback, the
//!   locker, the token WASM and the durations. A launch writes no instance key, so concurrent launches never collide
//!   (§3.5).
//! - **Trading** reads the fees, the protocol split and the snipe values pinned in the launch's own record, never the
//!   live config (V1). Every fee is booked on the launch (protocol, creator) or sent to the token for its holders when
//!   the launch shares fees: a trade never pays a third party (P10). The snipe tax steps every `snipe_step_secs` (5 s,
//!   L11). The last buy is clamped so the curve completes at its threshold exactly (A12), and completion closes
//!   trading; graduation runs later (L3).
//! - **Graduation** ([`graduation`]): the keeper's `graduate` on the launch's venue, or `graduate_fallback` on the
//!   fallback from `stuck_since + fallback_delay` (F14), through `try_` into the venue's executor. Recoverable venue
//!   failures are recorded, bad results abort, and the LP goes to the lp-locker forever.
//! - **Rescue** ([`rescue`]) of a stuck launch by the admin after `rescue_admin` or by anyone after `rescue_public`,
//!   then pro-rata refunds without fees (O2).
//! - **The creator-fee recipient** ([`recipient`]) is transferable and can be taken over through a vetoable delay; the
//!   fees booked before a change stay with the old recipient (L14).
//! - **Admin and guardian** ([`admin`]): future launches only, plus timelocked treasury, venue and guardian changes (L8,
//!   F16). Admin can never touch a live curve, except to open refunds seven days after graduation has failed; after
//!   thirty days anyone can open them (§16).
//!
//! Quote assets are Stellar Asset Contracts only (F17). There is no upgrade function, and no call extends the
//! instance's TTL (DECISIONS #10): the keeper keeps the instance and code alive. Errors are namespaced
//! `ERR_BASE + 1·100 + n` (V10).
//!
//! The contract interface (entry points, contract types, events and errors) is documented with `//` comments, not
//! `///`: the SDK copies doc comments into the WASM's contract spec, where wasm-opt can't shrink them, and they would
//! take about 10 KB of this contract's size budget (110 KB, §18.3).
#![no_std]

mod admin;
mod curve;
mod events;
mod graduation;
mod recipient;
mod rescue;
mod storage;

pub use curve::{BuyQuote, SellQuote, MAX_TOTAL_BPS};
pub use events::*;
pub use storage::{
    Config, Curve, Launch, LaunchParams, LaunchStatus, LaunchTerms, PendingGuardian, PendingTreasury, PendingVenue,
    Phase, QuoteEconomics, Takeover, VenueInfo, VenueInit,
};

use dyor_common::{
    validate_launch_durations, validate_ttl_policy, GraduationOutcome, HarvestPayees, LaunchDurations,
    LaunchTokenV2Client, LockerClient, Payee, PositionRef, TtlPolicy, VenueKind, VenueParams, BPS, TAG_LAUNCHPAD_V2,
};
use soroban_sdk::{
    contract, contracterror, contractimpl, panic_with_error, token::TokenClient, vec, xdr::ToXdr, Address, Bytes,
    BytesN, Env, Executable, Vec,
};
use storage::{
    config, exempt, find_venue, instance_get, items, load_curve, load_launch, quote_economics, recipient, save_curve,
    set_config, set_recipient, set_temporary, set_venues, venues, whitelisted, DataKey,
};

/// One token or one XLM, in 7-decimal units.
const ONE: i128 = 10_000_000;
const DAY_SECS: u64 = 86_400;

// §14.1: what the constructor starts with; `set_fees` and `set_launch_fee` change them for future launches.
/// 1,000,000,000 tokens with 7 decimals.
pub const DEFAULT_SUPPLY: i128 = 1_000_000_000 * ONE;
pub const DEFAULT_FEE_BPS: u32 = 100;
pub const DEFAULT_PROTOCOL_SHARE_BPS: u32 = 5_000;
pub const DEFAULT_MAX_CREATOR_FEE_BPS: u32 = 1_000;
pub const DEFAULT_SNIPE_SCHEDULE: [u32; 4] = [9_800, 2_500, 300, 30];
/// One ledger (L11).
pub const DEFAULT_SNIPE_STEP_SECS: u32 = 5;

/// A sanity cap on the launch fee: 1,000 XLM. The deployed value is 10 XLM (O6).
pub const MAX_LAUNCH_FEE: i128 = 1_000 * ONE;
pub const MAX_VENUES: u32 = 8;
/// `snipe_exempt` entries a launch may name, besides the creator and the recipient.
pub const MAX_EXEMPT: u32 = 32;
/// Launches one `claim_protocol_fees` call sweeps.
pub const MAX_CLAIM_TOKENS: u32 = 20;
/// All of a launch's LP fee growth is harvested and split (O1).
pub const LAUNCH_HARVEST_BPS: u32 = BPS;
pub const MAX_NAME: u32 = 32;
pub const MAX_SYMBOL: u32 = 12;
pub const MAX_URI: u32 = 256;
pub const MAX_SCHEDULE: u32 = 10;
pub const MAX_SNIPE_STEP_SECS: u32 = 60;

// The local codes of §5.7 in this contract's namespace: on chain `ERR_BASE + 1·100 + n` (§4, V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    LaunchesDisabled = 10_101,
    // The whitelist is on and the creator isn't on it.
    NotWhitelisted = 10_102,
    // The quote has no economics, or they are disabled.
    QuoteNotAllowed = 10_103,
    InvalidName = 10_104,
    InvalidSymbol = 10_105,
    InvalidUri = 10_106,
    CreatorFeeTooHigh = 10_107,
    // `expected` differs from the terms in force in at least one field.
    TermsChanged = 10_108,
    // The venue is unknown, disabled or outside the quote's allowlist, or the quote's fallback is disabled.
    VenueNotAllowed = 10_109,
    TooManyExemptions = 10_110,
    UnknownLaunch = 10_111,
    // Trading on a curve that has completed, graduated or been rescued.
    CurveClosed = 10_112,
    ZeroAmount = 10_113,
    SlippageExceeded = 10_114,
    // A sell would take more than the curve's real quote.
    InsufficientLiquidity = 10_115,
    NotCompleted = 10_116,
    AlreadyGraduated = 10_117,
    WrongPhase = 10_118,
    // Not stuck, or not yet rescuable.
    NotStuck = 10_119,
    // A venue-locked launch's fallback before `locked_fallback`, without `allow_fallback`.
    FallbackNotAllowed = 10_120,
    GraceNotElapsed = 10_121,
    AlreadyStuck = 10_122,
    NothingToClaim = 10_123,
    // Numbered for §5.7. `transfer_creator_fee_recipient` checks the recipient with `require_auth`, so a call it
    // didn't sign fails in the host's auth check before this could be raised.
    NotRecipient = 10_124,
    // A guardian function with no guardian, or a cancel by someone who may not cancel.
    NotAuthorized = 10_125,
    NoProposal = 10_126,
    TimelockNotElapsed = 10_127,
    TimelockExpired = 10_128,
    InvalidConfig = 10_129,
    InvalidEconomics = 10_130,
    UnknownVenue = 10_131,
    NotGraduated = 10_132,
    // The creator already launched with this nonce.
    NonceUsed = 10_133,
    // An executor's success failed the result checks; the whole transaction aborts (§5.5).
    GraduationInvalid = 10_134,
    TooManyTokens = 10_135,
    QuoteNotSac = 10_136,
    // `graduate_fallback` before `stuck_since + fallback_delay` (F14).
    FallbackTooEarly = 10_137,
}
dyor_common::assert_err_codes!(
    TAG_LAUNCHPAD_V2;
    Error::LaunchesDisabled = 1,
    Error::NotWhitelisted = 2,
    Error::QuoteNotAllowed = 3,
    Error::InvalidName = 4,
    Error::InvalidSymbol = 5,
    Error::InvalidUri = 6,
    Error::CreatorFeeTooHigh = 7,
    Error::TermsChanged = 8,
    Error::VenueNotAllowed = 9,
    Error::TooManyExemptions = 10,
    Error::UnknownLaunch = 11,
    Error::CurveClosed = 12,
    Error::ZeroAmount = 13,
    Error::SlippageExceeded = 14,
    Error::InsufficientLiquidity = 15,
    Error::NotCompleted = 16,
    Error::AlreadyGraduated = 17,
    Error::WrongPhase = 18,
    Error::NotStuck = 19,
    Error::FallbackNotAllowed = 20,
    Error::GraceNotElapsed = 21,
    Error::AlreadyStuck = 22,
    Error::NothingToClaim = 23,
    Error::NotRecipient = 24,
    Error::NotAuthorized = 25,
    Error::NoProposal = 26,
    Error::TimelockNotElapsed = 27,
    Error::TimelockExpired = 28,
    Error::InvalidConfig = 29,
    Error::InvalidEconomics = 30,
    Error::UnknownVenue = 31,
    Error::NotGraduated = 32,
    Error::NonceUsed = 33,
    Error::GraduationInvalid = 34,
    Error::TooManyTokens = 35,
    Error::QuoteNotSac = 36,
    Error::FallbackTooEarly = 37,
);

#[contract]
pub struct LaunchpadV2;

#[contractimpl]
impl LaunchpadV2 {
    // Every peer is fixed here (§3.4): the locker, the Soroswap factory, the Aquarius router, the token WASM and the
    // initial venue table (ids follow its order, every venue enabled). Fees, the split and the snipe schedule start at
    // the §14.1 values; launches are on and the whitelist off. Quotes are set afterwards with `set_quote`.
    //
    // Refuses (`InvalidConfig`): `xlm` that isn't a Stellar Asset Contract; invalid durations or TTL policy; a locker
    // whose `harvest_interval()` differs from `durations.harvest_interval` (F6); an empty table, more than 8 venues,
    // no Soroswap venue, an Aquarius tier outside {10, 30, 100} or a tier on another kind; a launch fee below 0 or
    // above `MAX_LAUNCH_FEE`.
    #[allow(clippy::too_many_arguments)]
    pub fn __constructor(
        e: Env,
        admin: Address,
        guardian: Option<Address>,
        treasury: Address,
        xlm: Address,
        token_wasm_hash: BytesN<32>,
        locker: Address,
        soroswap_factory: Address,
        aquarius_router: Address,
        launch_fee: i128,
        venues: Vec<VenueInit>,
        durations: LaunchDurations,
        ttl: TtlPolicy,
    ) {
        let ok = xlm.executable() == Some(Executable::StellarAsset)
            && validate_launch_durations(&durations).is_ok()
            && validate_ttl_policy(&e, &ttl)
            && admin::launch_fee_ok(launch_fee);
        if !ok {
            panic_with_error!(&e, Error::InvalidConfig);
        }
        let table = admin::initial_venues(&e, &venues);
        // The interval the phone sees in the terms is the one the locker enforces.
        let interval = LockerClient::new(&e, &locker).try_harvest_interval();
        if !matches!(interval, Ok(Ok(secs)) if secs == durations.harvest_interval) {
            panic_with_error!(&e, Error::InvalidConfig);
        }
        let cfg = Config {
            admin,
            guardian,
            treasury,
            xlm,
            token_wasm_hash,
            locker,
            soroswap_factory,
            aquarius_router,
            supply: DEFAULT_SUPPLY,
            fee_bps: DEFAULT_FEE_BPS,
            protocol_share_bps: DEFAULT_PROTOCOL_SHARE_BPS,
            max_creator_fee_bps: DEFAULT_MAX_CREATOR_FEE_BPS,
            snipe_schedule: Vec::from_array(&e, DEFAULT_SNIPE_SCHEDULE),
            snipe_step_secs: DEFAULT_SNIPE_STEP_SECS,
            launch_fee,
            launches_enabled: true,
            whitelist_enabled: false,
            durations,
            ttl,
        };
        admin::validate_fees(&e, &cfg);
        set_config(&e, &cfg);
        e.storage().instance().set(&DataKey::NextVenueId, &table.len());
        set_venues(&e, &table);
    }

    // -------------------------------------------------------------------------------------------- admin and guardian

    // Starts handing admin to `new`, who must `accept_admin`.
    pub fn propose_admin(e: Env, new: Address) {
        admin::propose_admin(&e, new);
    }

    pub fn accept_admin(e: Env) {
        admin::accept_admin(&e);
    }

    // The guardian starts handing its role to `new`, who must `accept_guardian`.
    pub fn transfer_guardian(e: Env, new: Address) {
        admin::transfer_guardian(&e, new);
    }

    pub fn accept_guardian(e: Env) {
        admin::accept_guardian(&e);
    }

    pub fn renounce_guardian(e: Env) {
        admin::renounce_guardian(&e);
    }

    // The admin's timelocked replacement of the guardian (`None` removes it): the recovery of a lost or compromised
    // guardian key, which the guardian can't cancel (F16).
    pub fn propose_guardian(e: Env, new: Option<Address>) {
        admin::propose_guardian(&e, new);
    }

    // Anyone, inside the window.
    pub fn apply_guardian(e: Env) {
        admin::apply_guardian(&e);
    }

    // The admin only.
    pub fn cancel_guardian(e: Env) {
        admin::cancel_guardian(&e);
    }

    pub fn propose_treasury(e: Env, new: Address) {
        admin::propose_treasury(&e, new);
    }

    // Anyone, inside the window.
    pub fn apply_treasury(e: Env) {
        admin::apply_treasury(&e);
    }

    // `caller` is the admin or the guardian.
    pub fn cancel_treasury(e: Env, caller: Address) {
        admin::cancel_treasury(&e, caller);
    }

    // The launch fee of future launches, in XLM stroops: 0 to `MAX_LAUNCH_FEE`.
    pub fn set_launch_fee(e: Env, amount: i128) {
        admin::set_launch_fee(&e, amount);
    }

    // Fees and the snipe schedule of future launches. Live and graduated launches keep the values pinned in their
    // `Launch` record, the harvest split included (V1).
    pub fn set_fees(
        e: Env,
        fee_bps: u32,
        protocol_share_bps: u32,
        max_creator_fee_bps: u32,
        snipe_schedule: Vec<u32>,
        snipe_step_secs: u32,
    ) {
        admin::set_fees(&e, fee_bps, protocol_share_bps, max_creator_fee_bps, snipe_schedule, snipe_step_secs);
    }

    // Economics for future launches quoted in `asset`, a Stellar Asset Contract (F17). `threshold` should be
    // phantom · (√10 − 1) for the 10× launch-to-graduation FDV. `venues_allowed` empty allows every enabled venue;
    // `fallback_venue` must be a Soroswap venue. A quote whose allowlist excludes its fallback is venue-locked.
    pub fn set_quote(
        e: Env,
        asset: Address,
        phantom: i128,
        threshold: i128,
        enabled: bool,
        venues_allowed: Vec<u32>,
        fallback_venue: u32,
    ) {
        admin::set_quote(&e, asset, phantom, threshold, enabled, venues_allowed, fallback_venue);
    }

    pub fn set_launches_enabled(e: Env, enabled: bool) {
        admin::set_launches_enabled(&e, enabled);
    }

    pub fn set_whitelist_enabled(e: Env, enabled: bool) {
        admin::set_whitelist_enabled(&e, enabled);
    }

    pub fn set_whitelisted(e: Env, account: Address, whitelisted: bool) {
        admin::set_whitelisted(&e, account, whitelisted);
    }

    // Proposes a venue; returns the id it will have once applied. Only Aquarius has a fee tier (10, 30 or 100);
    // every other kind takes 0.
    pub fn propose_venue(e: Env, kind: VenueKind, executor: Address, params: VenueParams) -> u32 {
        admin::propose_venue(&e, kind, executor, params)
    }

    // Anyone, inside the window. The venue starts disabled for future launches.
    pub fn apply_venue(e: Env, id: u32) {
        admin::apply_venue(&e, id);
    }

    // `caller` is the admin or the guardian.
    pub fn cancel_venue(e: Env, caller: Address, id: u32) {
        admin::cancel_venue(&e, caller, id);
    }

    pub fn set_venue_enabled(e: Env, id: u32, enabled: bool) {
        admin::set_venue_enabled(&e, id, enabled);
    }

    // Lets a stuck venue-locked launch use its fallback without waiting `locked_fallback`.
    pub fn allow_fallback(e: Env, token: Address) {
        graduation::allow_fallback(&e, &token);
    }

    // -------------------------------------------------------------------------------------------- the recipient

    // The current recipient hands the creator fees of `token` to `new`. The fees booked so far stay with it (L14).
    pub fn transfer_creator_fee_recipient(e: Env, token: Address, new: Address) {
        recipient::transfer(&e, &token, new);
    }

    // The admin proposes a takeover: `new` becomes the recipient if anyone executes it inside the window.
    pub fn propose_creator_fee_recipient(e: Env, token: Address, new: Address) {
        recipient::propose(&e, &token, new);
    }

    // `caller`, the admin or the current recipient (its veto), cancels a pending takeover. §5.4's
    // `cancel_creator_fee_recipient_change`: Soroban function names have at most 32 characters.
    pub fn cancel_recipient_change(e: Env, token: Address, caller: Address) {
        recipient::cancel(&e, &token, caller);
    }

    // Anyone executes a pending takeover inside its window. §5.4's `execute_creator_fee_recipient_change`.
    pub fn execute_recipient_change(e: Env, token: Address) {
        recipient::execute(&e, &token);
    }

    // -------------------------------------------------------------------------------------------- launch and trade

    // Deploys a launch token and opens its curve, if `expected` equals the terms in force. The creator pays the
    // launch fee to the launchpad, and an `initial_buy` by the creator (exempt from the snipe tax) runs in the same
    // call. Returns the token, whose address `token_address(creator, p.nonce)` predicts.
    pub fn launch(e: Env, creator: Address, p: LaunchParams, expected: LaunchTerms) -> Address {
        creator.require_auth();
        let cfg = config(&e);
        if !cfg.launches_enabled {
            panic_with_error!(&e, Error::LaunchesDisabled);
        }
        if cfg.whitelist_enabled && !whitelisted(&e, &creator) {
            panic_with_error!(&e, Error::NotWhitelisted);
        }
        let terms = launch_terms(&e, &cfg, &p.quote, p.venue);
        check_launch_params(&e, &cfg, &p);
        if terms != expected {
            panic_with_error!(&e, Error::TermsChanged);
        }
        let deployer = e.deployer().with_current_contract(launch_salt(&e, &creator, p.nonce));
        let token = deployer.deployed_address();
        if e.storage().persistent().has(&DataKey::Launch(token.clone())) {
            panic_with_error!(&e, Error::NonceUsed);
        }

        let this = e.current_contract_address();
        if terms.launch_fee > 0 {
            TokenClient::new(&e, &cfg.xlm).transfer(&creator, &this, &terms.launch_fee);
        }
        let (venue, fallback) = (terms.venue.clone(), terms.fallback.clone());
        let lock_from = dedup(&e, &[venue.executor.clone(), fallback.executor.clone()]);
        let fixed_excluded = dedup(&e, &[this.clone(), cfg.locker.clone(), venue.executor, fallback.executor]);
        let sharing_quote = if p.holder_sharing { Some(p.quote.clone()) } else { None };
        deployer.deploy_v2(
            cfg.token_wasm_hash.clone(),
            (
                this,
                cfg.locker.clone(),
                p.name.clone(),
                p.symbol.clone(),
                terms.supply,
                lock_from,
                fixed_excluded,
                sharing_quote,
                cfg.soroswap_factory.clone(),
                cfg.aquarius_router.clone(),
                cfg.treasury.clone(),
            ),
        );

        let launch = Launch {
            token: token.clone(),
            creator: creator.clone(),
            quote: p.quote.clone(),
            name: p.name.clone(),
            symbol: p.symbol.clone(),
            uri: p.uri.clone(),
            nonce: p.nonce,
            created_ledger: e.ledger().sequence(),
            created_at: e.ledger().timestamp(),
            fee_bps: terms.fee_bps,
            protocol_share_bps: terms.protocol_share_bps,
            creator_fee_bps: p.creator_fee_bps,
            snipe_schedule: terms.snipe_schedule.clone(),
            snipe_step_secs: terms.snipe_step_secs,
            venue: terms.venue.clone(),
            fallback: terms.fallback.clone(),
            venue_locked: terms.venue_locked,
            holder_sharing: p.holder_sharing,
            launch_fee_paid: terms.launch_fee,
        };
        let launch_key = DataKey::Launch(token.clone());
        e.storage().persistent().set(&launch_key, &launch);
        storage::bump(&e, &launch_key);
        let curve = Curve {
            phantom: terms.phantom,
            threshold: terms.threshold,
            quote_reserve: terms.phantom,
            token_reserve: terms.supply,
            real_quote: 0,
            creator_fees: 0,
            protocol_fees: 0,
            launch_fee_due: terms.launch_fee,
            holder_fees_total: 0,
            phase: Phase::Curve,
            completed_at: 0,
            stuck_since: 0,
            fallback_allowed: false,
            pool: None,
            graduated_venue: None,
            burned: 0,
            refund_quote: 0,
            refund_supply: 0,
            refunded: 0,
        };
        save_curve(&e, &token, &curve);
        let to = p.creator_fee_recipient.clone().unwrap_or_else(|| creator.clone());
        set_recipient(&e, &token, &to);
        let mut exempt = p.snipe_exempt.clone();
        exempt.push_back(creator.clone());
        exempt.push_back(to.clone());
        let window = launch.snipe_schedule.len() as u64 * launch.snipe_step_secs as u64;
        set_temporary(&e, &DataKey::Exempt(token.clone()), &dedup_vec(&e, &exempt), window + DAY_SECS);

        Launched {
            token: token.clone(),
            creator: creator.clone(),
            quote: p.quote,
            name: p.name,
            symbol: p.symbol,
            uri: p.uri,
            nonce: p.nonce,
            supply: terms.supply,
            phantom: terms.phantom,
            threshold: terms.threshold,
            fee_bps: terms.fee_bps,
            protocol_share_bps: terms.protocol_share_bps,
            creator_fee_bps: p.creator_fee_bps,
            venue: terms.venue.id,
            fallback_venue: terms.fallback.id,
            venue_locked: terms.venue_locked,
            holder_sharing: p.holder_sharing,
            recipient: to,
            launch_fee: terms.launch_fee,
        }
        .publish(&e);
        if terms.launch_fee > 0 {
            LaunchFeeBooked { token: token.clone(), payer: creator.clone(), asset: cfg.xlm, amount: terms.launch_fee }
                .publish(&e);
        }
        if p.initial_buy > 0 {
            do_buy(&e, &creator, &token, p.initial_buy, p.min_tokens_out);
        }
        token
    }

    // Buys with up to `quote_in` of the launch's quote. Near the threshold only what completes the curve is pulled.
    // Returns the tokens received.
    pub fn buy(e: Env, buyer: Address, token: Address, quote_in: i128, min_tokens_out: i128) -> i128 {
        buyer.require_auth();
        do_buy(&e, &buyer, &token, quote_in, min_tokens_out)
    }

    // Sells `tokens_in` back to the curve. Returns the quote received.
    pub fn sell(e: Env, seller: Address, token: Address, tokens_in: i128, min_quote_out: i128) -> i128 {
        seller.require_auth();
        let launch = load_launch(&e, &token);
        let mut curve = load_curve(&e, &token);
        let q = price_sell(&e, &launch, &curve, tokens_in);
        if q.quote_out <= 0 || q.quote_out < min_quote_out {
            panic_with_error!(&e, Error::SlippageExceeded);
        }
        let split = split_fees(&launch, q.base_fee, q.creator_fee);
        curve.quote_reserve -= q.gross;
        curve.token_reserve += tokens_in;
        curve.real_quote -= q.gross;
        split.book(&mut curve);
        save_curve(&e, &token, &curve);

        let this = e.current_contract_address();
        TokenClient::new(&e, &token).transfer(&seller, &this, &tokens_in);
        split.pay_holders(&e, &launch);
        TokenClient::new(&e, &launch.quote).transfer(&this, &seller, &q.quote_out);
        Trade {
            token,
            trader: seller,
            is_buy: false,
            quote_amount: q.quote_out,
            token_amount: tokens_in,
            base_fee: q.base_fee,
            snipe_fee: 0,
            creator_fee: q.creator_fee,
            protocol_part: split.protocol,
            creator_part: split.creator,
            holder_part: split.holders,
            quote_reserve: curve.quote_reserve,
            token_reserve: curve.token_reserve,
            real_quote: curve.real_quote,
        }
        .publish(&e);
        q.quote_out
    }

    // Burns `tokens_in` of the holder's tokens of a rescued launch for its pro-rata share of the raised quote, with
    // no fees (O2). Returns the quote paid.
    pub fn refund(e: Env, holder: Address, token: Address, tokens_in: i128) -> i128 {
        rescue::refund(&e, &holder, &token, tokens_in)
    }

    // -------------------------------------------------------------------------------------------- anyone

    // One attempt to graduate a completed curve on its own venue. Never reverts on a recoverable venue failure: it
    // records it and returns `Failed`.
    pub fn graduate(e: Env, token: Address) -> GraduationOutcome {
        graduation::graduate(&e, &token, false)
    }

    // One attempt on the fallback venue only, from `stuck_since + fallback_delay` (and for a venue-locked launch from
    // `stuck_since + locked_fallback` unless the fallback was allowed).
    pub fn graduate_fallback(e: Env, token: Address) -> GraduationOutcome {
        graduation::graduate(&e, &token, true)
    }

    // Marks a completed curve stuck once its grace has passed without a graduation.
    pub fn mark_stuck(e: Env, token: Address) {
        graduation::mark_stuck(&e, &token);
    }

    // Opens refunds of a stuck launch: the admin from `stuck_since + rescue_admin`, anyone from
    // `stuck_since + rescue_public`.
    pub fn rescue(e: Env, token: Address) {
        rescue::rescue(&e, &token);
    }

    // Pays the booked creator fees of `token` to its current recipient.
    pub fn claim_creator_fees(e: Env, token: Address) -> i128 {
        recipient::claim_creator_fees(&e, &token)
    }

    // Pays `account` what recipient changes left owed to it in `asset`.
    pub fn claim_owed(e: Env, account: Address, asset: Address) -> i128 {
        recipient::claim_owed(&e, &account, &asset)
    }

    // Sweeps the booked protocol fees (each launch's quote) and launch fees (XLM) of up to `MAX_CLAIM_TOKENS`
    // launches to the treasury current at the call, one transfer per asset. All or nothing: a treasury that can't
    // receive one asset fails the whole call. Returns what went out per asset.
    pub fn claim_protocol_fees(e: Env, tokens: Vec<Address>) -> Vec<(Address, i128)> {
        if tokens.len() > MAX_CLAIM_TOKENS {
            panic_with_error!(&e, Error::TooManyTokens);
        }
        let cfg = config(&e);
        let mut totals: Vec<(Address, i128)> = Vec::new(&e);
        for token in items(&tokens) {
            let launch = load_launch(&e, &token);
            let mut curve = load_curve(&e, &token);
            let (quote_amount, launch_fee_amount) = (curve.protocol_fees, curve.launch_fee_due);
            if quote_amount == 0 && launch_fee_amount == 0 {
                continue;
            }
            curve.protocol_fees = 0;
            curve.launch_fee_due = 0;
            save_curve(&e, &token, &curve);
            add_total(&mut totals, &launch.quote, quote_amount);
            add_total(&mut totals, &cfg.xlm, launch_fee_amount);
            ProtocolFeesClaimed { token, treasury: cfg.treasury.clone(), quote_amount, launch_fee_amount }.publish(&e);
        }
        if totals.is_empty() {
            panic_with_error!(&e, Error::NothingToClaim);
        }
        let this = e.current_contract_address();
        for (asset, amount) in items(&totals) {
            TokenClient::new(&e, &asset).transfer(&this, &cfg.treasury, &amount);
        }
        totals
    }

    // Who receives each side of a graduated launch's harvest (§5.5): the same list for the quote and the launch
    // token, split by the launch's pinned `protocol_share_bps` (V1): the treasury current now, then the token itself
    // (as launch-token and quote rewards for its holders) with sharing on, or the current recipient with it off
    // (O1, L13, F1). The lp-locker reads it on every harvest. A Moment's reference is refused (`UnknownLaunch`).
    pub fn harvest_payees(e: Env, reference: PositionRef) -> HarvestPayees {
        let PositionRef::Launch(token) = reference else {
            panic_with_error!(&e, Error::UnknownLaunch);
        };
        let launch = load_launch(&e, &token);
        if load_curve(&e, &token).phase != Phase::Graduated {
            panic_with_error!(&e, Error::NotGraduated);
        }
        let ps = launch.protocol_share_bps;
        let rest = if launch.holder_sharing {
            Payee { to: token, bps: BPS - ps, notify: true }
        } else {
            Payee { to: recipient(&e, &token), bps: BPS - ps, notify: false }
        };
        let side = vec![&e, Payee { to: config(&e).treasury, bps: ps, notify: false }, rest];
        HarvestPayees { quote: side.clone(), base: side }
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn config(e: Env) -> Config {
        config(&e)
    }

    pub fn venues(e: Env) -> Vec<VenueInfo> {
        venues(&e)
    }

    // The treasury current now; launch tokens read it in `exclude_treasury` and `sweep_protocol` (V2).
    pub fn treasury(e: Env) -> Address {
        config(&e).treasury
    }

    pub fn guardian(e: Env) -> Option<Address> {
        config(&e).guardian
    }

    pub fn pending_treasury(e: Env) -> Option<PendingTreasury> {
        instance_get(&e, &DataKey::PendingTreasury)
    }

    pub fn pending_guardian(e: Env) -> Option<PendingGuardian> {
        instance_get(&e, &DataKey::PendingGuardian)
    }

    pub fn pending_venue(e: Env, id: u32) -> Option<PendingVenue> {
        instance_get(&e, &DataKey::PendingVenue(id))
    }

    pub fn quote_economics(e: Env, asset: Address) -> Option<QuoteEconomics> {
        quote_economics(&e, &asset)
    }

    // The terms a launch quoted in `quote` on venue `venue` would bind now: what `launch` expects as `expected`.
    pub fn preview_launch_terms(e: Env, quote: Address, venue: u32) -> LaunchTerms {
        launch_terms(&e, &config(&e), &quote, venue)
    }

    // The address `launch` deploys the token of `creator`'s launch with `nonce` at.
    pub fn token_address(e: Env, creator: Address, nonce: u64) -> Address {
        e.deployer().with_current_contract(launch_salt(&e, &creator, nonce)).deployed_address()
    }

    pub fn get_launch(e: Env, token: Address) -> Launch {
        load_launch(&e, &token)
    }

    pub fn get_curve(e: Env, token: Address) -> Curve {
        load_curve(&e, &token)
    }

    // The launch's phase and when each path opens.
    pub fn status(e: Env, token: Address) -> LaunchStatus {
        graduation::status(&e, &token)
    }

    pub fn creator_fee_recipient(e: Env, token: Address) -> Address {
        recipient(&e, &token)
    }

    pub fn pending_recipient_change(e: Env, token: Address) -> Option<Takeover> {
        storage::takeover(&e, &token)
    }

    pub fn creator_owed(e: Env, account: Address, asset: Address) -> i128 {
        storage::creator_owed(&e, &account, &asset)
    }

    // What `buy` would do now for `buyer`: the snipe tax depends on the buyer and the time since the launch. Refused
    // wherever `buy` is.
    pub fn quote_buy(e: Env, token: Address, buyer: Address, quote_in: i128) -> BuyQuote {
        let launch = load_launch(&e, &token);
        price_buy(&e, &launch, &load_curve(&e, &token), &buyer, quote_in)
    }

    // What `sell` would do now. Refused wherever `sell` is: a closed curve has no price.
    pub fn quote_sell(e: Env, token: Address, tokens_in: i128) -> SellQuote {
        let launch = load_launch(&e, &token);
        price_sell(&e, &launch, &load_curve(&e, &token), tokens_in)
    }

    // What `refund` pays for `tokens_in` (Rescued only).
    pub fn quote_refund(e: Env, token: Address, tokens_in: i128) -> i128 {
        rescue::refund_out(&e, &load_curve(&e, &token), tokens_in)
    }

    // What graduating now would put in the pool and burn: `(pool_tokens, pool_quote, burn)`.
    pub fn graduation_preview(e: Env, token: Address) -> (i128, i128, i128) {
        graduation::preview(&e, &token)
    }

    // This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_LAUNCHPAD_V2
    }
}

// ------------------------------------------------------------------------------------------------ launch internals

/// The terms in force for a launch quoted in `quote` on venue `venue_id` (§5.3). The quote must be enabled; the venue
/// must exist, be enabled and be on the quote's allowlist (empty: every venue); the quote's fallback must be enabled.
fn launch_terms(e: &Env, cfg: &Config, quote: &Address, venue_id: u32) -> LaunchTerms {
    let econ = match quote_economics(e, quote) {
        Some(econ) if econ.enabled => econ,
        _ => panic_with_error!(e, Error::QuoteNotAllowed),
    };
    storage::bump(e, &DataKey::Quote(quote.clone()));
    let table = venues(e);
    let venue = match find_venue(&table, venue_id) {
        Some(v) if v.enabled && (econ.venues_allowed.is_empty() || econ.venues_allowed.contains(venue_id)) => v,
        _ => panic_with_error!(e, Error::VenueNotAllowed),
    };
    let fallback = match find_venue(&table, econ.fallback_venue) {
        Some(v) if v.enabled => v,
        _ => panic_with_error!(e, Error::VenueNotAllowed),
    };
    LaunchTerms {
        supply: cfg.supply,
        fee_bps: cfg.fee_bps,
        protocol_share_bps: cfg.protocol_share_bps,
        max_creator_fee_bps: cfg.max_creator_fee_bps,
        snipe_schedule: cfg.snipe_schedule.clone(),
        snipe_step_secs: cfg.snipe_step_secs,
        launch_fee: cfg.launch_fee,
        fee_asset: cfg.xlm.clone(),
        quote: quote.clone(),
        phantom: econ.phantom,
        threshold: econ.threshold,
        venue,
        fallback,
        venue_locked: !econ.venues_allowed.is_empty() && !econ.venues_allowed.contains(econ.fallback_venue),
        locker: cfg.locker.clone(),
        token_wasm_hash: cfg.token_wasm_hash.clone(),
        durations: cfg.durations,
    }
}

/// The creator's own inputs: name 1–32 bytes, symbol 1–12, URI at most 256 (the backend enforces a 2–10 character
/// ticker), the creator fee within the cap, at most 32 exemptions, and no negative initial buy.
fn check_launch_params(e: &Env, cfg: &Config, p: &LaunchParams) {
    if p.name.is_empty() || p.name.len() > MAX_NAME {
        panic_with_error!(e, Error::InvalidName);
    }
    if p.symbol.is_empty() || p.symbol.len() > MAX_SYMBOL {
        panic_with_error!(e, Error::InvalidSymbol);
    }
    if p.uri.len() > MAX_URI {
        panic_with_error!(e, Error::InvalidUri);
    }
    // fee_bps + max_creator_fee_bps < MAX_TOTAL_BPS (set_fees), so fee + creator fee stay below it too.
    if p.creator_fee_bps > cfg.max_creator_fee_bps {
        panic_with_error!(e, Error::CreatorFeeTooHigh);
    }
    if p.snipe_exempt.len() > MAX_EXEMPT {
        panic_with_error!(e, Error::TooManyExemptions);
    }
    if p.initial_buy < 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
}

/// sha256("dyorhq/launch/v2" ‖ creator.to_xdr() ‖ nonce big-endian) (L15): no global counter.
fn launch_salt(e: &Env, creator: &Address, nonce: u64) -> BytesN<32> {
    let mut seed = Bytes::from_slice(e, b"dyorhq/launch/v2");
    seed.append(&creator.clone().to_xdr(e));
    seed.append(&Bytes::from_array(e, &nonce.to_be_bytes()));
    e.crypto().sha256(&seed).into()
}

// ------------------------------------------------------------------------------------------------ trade internals

fn do_buy(e: &Env, buyer: &Address, token: &Address, quote_in: i128, min_tokens_out: i128) -> i128 {
    let launch = load_launch(e, token);
    let mut curve = load_curve(e, token);
    let q = price_buy(e, &launch, &curve, buyer, quote_in);
    if q.tokens_out <= 0 || q.tokens_out < min_tokens_out {
        panic_with_error!(e, Error::SlippageExceeded);
    }
    let split = split_fees(&launch, q.base_fee + q.snipe_fee, q.creator_fee);
    curve.quote_reserve += q.net;
    curve.token_reserve -= q.tokens_out;
    curve.real_quote += q.net;
    split.book(&mut curve);
    // Monad's clamp lands the last buy on the threshold exactly (I-L7); graduation is a later call (L3).
    let completed = curve.real_quote == curve.threshold;
    if completed {
        curve.phase = Phase::Completed;
        curve.completed_at = e.ledger().timestamp();
    }
    save_curve(e, token, &curve);

    let this = e.current_contract_address();
    TokenClient::new(e, &launch.quote).transfer(buyer, &this, &q.used);
    split.pay_holders(e, &launch);
    TokenClient::new(e, token).transfer(&this, buyer, &q.tokens_out);
    Trade {
        token: token.clone(),
        trader: buyer.clone(),
        is_buy: true,
        quote_amount: q.used,
        token_amount: q.tokens_out,
        base_fee: q.base_fee,
        snipe_fee: q.snipe_fee,
        creator_fee: q.creator_fee,
        protocol_part: split.protocol,
        creator_part: split.creator,
        holder_part: split.holders,
        quote_reserve: curve.quote_reserve,
        token_reserve: curve.token_reserve,
        real_quote: curve.real_quote,
    }
    .publish(e);
    if completed {
        Completed { token: token.clone(), real_quote: curve.real_quote, completed_at: curve.completed_at }.publish(e);
    }
    q.tokens_out
}

/// Prices a buy with the launch's pinned fees and snipe schedule (V1). The snipe step is the time since the launch
/// in `snipe_step_secs` steps (L11); exempt buyers, the creator and the initial recipient pay none.
fn price_buy(e: &Env, launch: &Launch, curve: &Curve, buyer: &Address, quote_in: i128) -> BuyQuote {
    require_open(e, curve, quote_in);
    let step = e.ledger().timestamp().saturating_sub(launch.created_at) / launch.snipe_step_secs as u64;
    let snipe_bps = if step >= launch.snipe_schedule.len() as u64 || exempt(e, &launch.token).contains(buyer) {
        0
    } else {
        launch.snipe_schedule.get_unchecked(step as u32)
    };
    curve::quote_buy(
        quote_in,
        curve.quote_reserve,
        curve.token_reserve,
        curve.threshold - curve.real_quote,
        launch.fee_bps,
        launch.creator_fee_bps,
        snipe_bps,
    )
}

/// Prices a sell with the launch's pinned fees. A sell can't take more than the curve's real quote: tokens that
/// never came from the curve don't count.
fn price_sell(e: &Env, launch: &Launch, curve: &Curve, tokens_in: i128) -> SellQuote {
    require_open(e, curve, tokens_in);
    let q =
        curve::quote_sell(tokens_in, curve.quote_reserve, curve.token_reserve, launch.fee_bps, launch.creator_fee_bps);
    if q.gross > curve.real_quote {
        panic_with_error!(e, Error::InsufficientLiquidity);
    }
    q
}

/// Trades and their quotes need a curve still trading (once it completes, graduates or is rescued its reserves price
/// nothing) and a positive amount.
fn require_open(e: &Env, curve: &Curve, amount: i128) {
    if curve.phase != Phase::Curve {
        panic_with_error!(e, Error::CurveClosed);
    }
    if amount <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
}

/// One trade's fees, split by the launch's pinned `protocol_share_bps` (V1), as Monad's curve splits them
/// (M:contracts/src/BondingCurve.sol:292-319): the protocol takes its share of `shared` (the curve fee and the snipe
/// tax); the rest and the creator fee are the creator part, booked for the recipient, or with sharing on sent to the
/// token for its holders.
struct FeeSplit {
    protocol: i128,
    creator: i128,
    holders: i128,
}

fn split_fees(launch: &Launch, shared: i128, creator_only: i128) -> FeeSplit {
    let protocol = curve::fee_of(shared, launch.protocol_share_bps);
    let creator_part = shared - protocol + creator_only;
    if launch.holder_sharing {
        FeeSplit { protocol, creator: 0, holders: creator_part }
    } else {
        FeeSplit { protocol, creator: creator_part, holders: 0 }
    }
}

impl FeeSplit {
    /// Books the protocol and creator parts on the launch: no key shared with another launch (§3.5).
    fn book(&self, curve: &mut Curve) {
        curve.protocol_fees += self.protocol;
        curve.creator_fees += self.creator;
        curve.holder_fees_total += self.holders;
    }

    /// Sends the holders' part to the token, then queues it for them (two direct calls, funds first, §6.2).
    fn pay_holders(&self, e: &Env, launch: &Launch) {
        if self.holders > 0 {
            let this = e.current_contract_address();
            TokenClient::new(e, &launch.quote).transfer(&this, &launch.token, &self.holders);
            LaunchTokenV2Client::new(e, &launch.token).notify_reward(&this, &launch.quote, &self.holders);
        }
    }
}

// ------------------------------------------------------------------------------------------------ helpers

/// Adds `amount` of `asset` to the per-asset totals of `claim_protocol_fees`.
fn add_total(totals: &mut Vec<(Address, i128)>, asset: &Address, amount: i128) {
    if amount == 0 {
        return;
    }
    let found = items(totals).position(|(a, _)| a == *asset);
    match found {
        Some(i) => {
            let (a, sum) = totals.get_unchecked(i as u32);
            totals.set(i as u32, (a, sum + amount));
        }
        None => totals.push_back((asset.clone(), amount)),
    }
}

/// `items` without repeats, in their order.
fn dedup(e: &Env, items: &[Address]) -> Vec<Address> {
    let mut out = Vec::new(e);
    for a in items {
        if !out.contains(a) {
            out.push_back(a.clone());
        }
    }
    out
}

fn dedup_vec(e: &Env, list: &Vec<Address>) -> Vec<Address> {
    let mut out = Vec::new(e);
    for a in items(list) {
        if !out.contains(&a) {
            out.push_back(a);
        }
    }
    out
}

#[cfg(test)]
mod test;
