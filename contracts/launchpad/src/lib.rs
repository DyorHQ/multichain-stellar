//! DyorHQ Launchpad for Stellar (Soroban).
//!
//! One contract runs every launch. `launch` deploys a `dyor-launch-token` (fixed supply minted to this contract) and
//! opens a constant-product bonding curve with a phantom quote reserve (XLM or USDC). When the curve has raised its
//! threshold it stops trading and anyone can `graduate` it: the raised quote and the price-continuous token amount
//! go straight into a Soroswap pair, the LP tokens stay in this contract forever (there is no function that moves
//! them), the rest of the curve's tokens are burned and token transfers open.
//!
//! Economics mirror the Monad launchpad: 1,000,000,000 supply, 1% curve fee split 50/50 protocol/creator, an
//! optional creator fee (≤ 10%), an anti-snipe tax by ledger offset (98%, 25%, 3%, 0.3%), threshold =
//! phantom · (√10 − 1) so graduation FDV is 10× launch FDV.
//!
//! Admin can only set the economics of *future* launches (per quote asset) and pause new launches. It cannot touch
//! a live curve, user funds, accrued creator fees or the locked LP. The treasury is fixed at deployment.
#![no_std]

mod curve;

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype, panic_with_error,
    token::TokenClient, vec, xdr::ToXdr, Address, Bytes, BytesN, Env, String, Vec,
};

pub use curve::{BuyQuote, SellQuote, BPS, MAX_TOTAL_BPS};

/// 1,000,000,000 tokens with 7 decimals.
pub const DEFAULT_SUPPLY: i128 = 1_000_000_000_0000000;
const DAY_IN_LEDGERS: u32 = 17_280;
// The contract instance and its WASM are kept alive by the operator (backend keeper: ExtendFootprintTTL), never in a
// user's call: extending the instance also extends the ~50 KB code entry, which costs ~100+ XLM of rent on testnet.
// Rent is paid by whoever extends: 30-day extensions keep a launch's fee low; an idle launch's entries archive and
// can be restored later.
const PERSISTENT_BUMP: u32 = 30 * DAY_IN_LEDGERS;
const PERSISTENT_THRESHOLD: u32 = 7 * DAY_IN_LEDGERS;
const MAX_NAME: u32 = 32;
const MAX_SYMBOL: u32 = 12;
const MAX_URI: u32 = 256;
const MAX_SCHEDULE: u32 = 10;

// ------------------------------------------------------------------------------------------------ external clients

/// Soroswap factory (UniswapV2-style). Results are unwrapped by the host: an error traps the call.
#[contractclient(name = "SoroswapFactoryClient")]
pub trait SoroswapFactory {
    fn pair_exists(e: Env, token_a: Address, token_b: Address) -> bool;
    fn get_pair(e: Env, token_a: Address, token_b: Address) -> Address;
    fn create_pair(e: Env, token_a: Address, token_b: Address) -> Address;
}

/// Soroswap pair: `deposit(to)` mints LP for whatever was transferred in (no auth), like UniswapV2 `mint`.
#[contractclient(name = "SoroswapPairClient")]
pub trait SoroswapPair {
    fn deposit(e: Env, to: Address) -> i128;
}

/// The launch token's one extra entry point.
#[contractclient(name = "LaunchTokenOpsClient")]
pub trait LaunchTokenOps {
    fn unlock(e: Env);
}

// ------------------------------------------------------------------------------------------------ types

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub admin: Address,
    /// Receives protocol fees. Fixed at deployment.
    pub treasury: Address,
    pub token_wasm_hash: BytesN<32>,
    pub soroswap_factory: Address,
    pub supply: i128,
    /// Curve fee on every buy and sell (100 = 1%).
    pub fee_bps: u32,
    /// Share of the curve fee (and snipe tax) that goes to the protocol; the rest goes to the creator.
    pub protocol_share_bps: u32,
    pub max_creator_fee_bps: u32,
    /// Snipe tax by ledger offset from the launch ledger.
    pub snipe_schedule: Vec<u32>,
    pub launches_enabled: bool,
}

/// Curve economics for one quote asset. Applies to launches created after it is set.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuoteEconomics {
    pub phantom: i128,
    pub threshold: i128,
    pub enabled: bool,
}

/// What never changes about a launch.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launch {
    pub token: Address,
    pub creator: Address,
    pub quote: Address,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub index: u32,
    pub created_ledger: u32,
    pub created_at: u64,
    pub fee_bps: u32,
    pub protocol_share_bps: u32,
    pub creator_fee_bps: u32,
    pub snipe_schedule: Vec<u32>,
}

/// The curve's moving state.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Curve {
    pub phantom: i128,
    pub threshold: i128,
    /// Virtual quote reserve: phantom + real quote.
    pub quote_reserve: i128,
    pub token_reserve: i128,
    /// Quote actually raised (net of fees), backing the curve.
    pub real_quote: i128,
    /// Creator fees accrued and not yet claimed, in the quote asset.
    pub creator_fees: i128,
    pub completed: bool,
    pub graduated: bool,
    pub pair: Option<Address>,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Config,
    LaunchCount,
    Quote(Address),
    Launch(Address),
    Curve(Address),
    LaunchAt(u32),
    ProtocolFees(Address),
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    LaunchesDisabled = 1,
    QuoteNotAllowed = 2,
    InvalidName = 3,
    InvalidSymbol = 4,
    InvalidUri = 5,
    CreatorFeeTooHigh = 6,
    UnknownLaunch = 7,
    CurveClosed = 8,
    ZeroAmount = 9,
    SlippageExceeded = 10,
    NotCompleted = 11,
    AlreadyGraduated = 12,
    InvalidEconomics = 13,
    InvalidConfig = 14,
    InsufficientLiquidity = 15,
    NothingToClaim = 16,
}

// ------------------------------------------------------------------------------------------------ events

#[contractevent(topics = ["launch"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launched {
    #[topic]
    pub token: Address,
    #[topic]
    pub creator: Address,
    pub quote: Address,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub index: u32,
    pub supply: i128,
    pub phantom: i128,
    pub threshold: i128,
    pub creator_fee_bps: u32,
}

#[contractevent(topics = ["trade"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Trade {
    #[topic]
    pub token: Address,
    #[topic]
    pub trader: Address,
    pub is_buy: bool,
    /// Buy: quote pulled from the buyer. Sell: quote paid to the seller.
    pub quote_amount: i128,
    pub token_amount: i128,
    /// Curve fee + snipe tax (split protocol/creator) + creator fee.
    pub fees: i128,
    pub quote_reserve: i128,
    pub token_reserve: i128,
    pub real_quote: i128,
}

#[contractevent(topics = ["complete"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Completed {
    #[topic]
    pub token: Address,
    pub real_quote: i128,
}

#[contractevent(topics = ["graduate"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Graduated {
    #[topic]
    pub token: Address,
    pub pair: Address,
    pub pool_tokens: i128,
    pub pool_quote: i128,
    pub liquidity: i128,
    pub burned: i128,
}

#[contractevent(topics = ["claim_creator"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreatorFeesClaimed {
    #[topic]
    pub token: Address,
    #[topic]
    pub creator: Address,
    pub amount: i128,
}

#[contractevent(topics = ["claim_protocol"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProtocolFeesClaimed {
    #[topic]
    pub quote: Address,
    pub treasury: Address,
    pub amount: i128,
}

#[contractevent(topics = ["quote_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuoteSet {
    #[topic]
    pub quote: Address,
    pub phantom: i128,
    pub threshold: i128,
    pub enabled: bool,
}

#[contractevent(topics = ["config_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigSet {
    pub config: Config,
}

// ------------------------------------------------------------------------------------------------ contract

#[contract]
pub struct Launchpad;

#[contractimpl]
impl Launchpad {
    pub fn __constructor(e: Env, admin: Address, treasury: Address, token_wasm_hash: BytesN<32>, soroswap_factory: Address) {
        let cfg = Config {
            admin,
            treasury,
            token_wasm_hash,
            soroswap_factory,
            supply: DEFAULT_SUPPLY,
            fee_bps: 100,
            protocol_share_bps: 5_000,
            max_creator_fee_bps: 1_000,
            snipe_schedule: vec![&e, 9_800u32, 2_500, 300, 30],
            launches_enabled: true,
        };
        validate_config(&e, &cfg);
        e.storage().instance().set(&DataKey::Config, &cfg);
        e.storage().instance().set(&DataKey::LaunchCount, &0u32);
    }

    // -------------------------------------------------------------------------------------------- admin

    /// Economics for launches quoted in `quote` created from now on. `threshold` should be phantom · (√10 − 1)
    /// for the 10× launch-to-graduation FDV; the contract only checks that both are positive.
    pub fn set_quote(e: Env, quote: Address, phantom: i128, threshold: i128, enabled: bool) {
        let cfg = config(&e);
        cfg.admin.require_auth();
        if enabled && (phantom <= 0 || threshold <= 0) {
            panic_with_error!(&e, Error::InvalidEconomics);
        }
        let econ = QuoteEconomics { phantom, threshold, enabled };
        e.storage().persistent().set(&DataKey::Quote(quote.clone()), &econ);
        bump_persistent(&e, &DataKey::Quote(quote.clone()));
        QuoteSet { quote, phantom, threshold, enabled }.publish(&e);
    }

    /// Fees and snipe schedule for launches created from now on; live launches keep the values they started with.
    pub fn set_fees(e: Env, fee_bps: u32, protocol_share_bps: u32, max_creator_fee_bps: u32, snipe_schedule: Vec<u32>) {
        let mut cfg = config(&e);
        cfg.admin.require_auth();
        cfg.fee_bps = fee_bps;
        cfg.protocol_share_bps = protocol_share_bps;
        cfg.max_creator_fee_bps = max_creator_fee_bps;
        cfg.snipe_schedule = snipe_schedule;
        validate_config(&e, &cfg);
        e.storage().instance().set(&DataKey::Config, &cfg);
        ConfigSet { config: cfg }.publish(&e);
    }

    pub fn set_launches_enabled(e: Env, enabled: bool) {
        let mut cfg = config(&e);
        cfg.admin.require_auth();
        cfg.launches_enabled = enabled;
        e.storage().instance().set(&DataKey::Config, &cfg);
        ConfigSet { config: cfg }.publish(&e);
    }

    /// Hands admin to `new_admin`; both must sign.
    pub fn set_admin(e: Env, new_admin: Address) {
        let mut cfg = config(&e);
        cfg.admin.require_auth();
        new_admin.require_auth();
        cfg.admin = new_admin;
        e.storage().instance().set(&DataKey::Config, &cfg);
        ConfigSet { config: cfg }.publish(&e);
    }

    // -------------------------------------------------------------------------------------------- launch & trade

    /// Deploys a launch token and opens its curve. An `initial_buy` (quote units) by the creator runs in the same
    /// call, exempt from the snipe tax. Returns the token's address.
    pub fn launch(
        e: Env,
        creator: Address,
        quote: Address,
        name: String,
        symbol: String,
        uri: String,
        creator_fee_bps: u32,
        initial_buy: i128,
        min_tokens_out: i128,
    ) -> Address {
        creator.require_auth();
        let cfg = config(&e);
        if !cfg.launches_enabled {
            panic_with_error!(&e, Error::LaunchesDisabled);
        }
        let econ: QuoteEconomics = e
            .storage()
            .persistent()
            .get(&DataKey::Quote(quote.clone()))
            .unwrap_or_else(|| panic_with_error!(&e, Error::QuoteNotAllowed));
        if !econ.enabled {
            panic_with_error!(&e, Error::QuoteNotAllowed);
        }
        if name.len() == 0 || name.len() > MAX_NAME {
            panic_with_error!(&e, Error::InvalidName);
        }
        if symbol.len() == 0 || symbol.len() > MAX_SYMBOL {
            panic_with_error!(&e, Error::InvalidSymbol);
        }
        if uri.len() > MAX_URI {
            panic_with_error!(&e, Error::InvalidUri);
        }
        if creator_fee_bps > cfg.max_creator_fee_bps {
            panic_with_error!(&e, Error::CreatorFeeTooHigh);
        }
        if initial_buy < 0 {
            panic_with_error!(&e, Error::ZeroAmount);
        }

        let index: u32 = e.storage().instance().get(&DataKey::LaunchCount).unwrap_or(0);
        let mut seed = Bytes::from_slice(&e, b"dyorhq/launch/v1");
        seed.append(&Bytes::from_array(&e, &index.to_be_bytes()));
        seed.append(&creator.clone().to_xdr(&e));
        let salt: BytesN<32> = e.crypto().sha256(&seed).into();
        let this = e.current_contract_address();
        let token = e
            .deployer()
            .with_current_contract(salt)
            .deploy_v2(cfg.token_wasm_hash.clone(), (this, name.clone(), symbol.clone(), cfg.supply));

        let launch = Launch {
            token: token.clone(),
            creator: creator.clone(),
            quote: quote.clone(),
            name: name.clone(),
            symbol: symbol.clone(),
            uri: uri.clone(),
            index,
            created_ledger: e.ledger().sequence(),
            created_at: e.ledger().timestamp(),
            fee_bps: cfg.fee_bps,
            protocol_share_bps: cfg.protocol_share_bps,
            creator_fee_bps,
            snipe_schedule: cfg.snipe_schedule.clone(),
        };
        let curve = Curve {
            phantom: econ.phantom,
            threshold: econ.threshold,
            quote_reserve: econ.phantom,
            token_reserve: cfg.supply,
            real_quote: 0,
            creator_fees: 0,
            completed: false,
            graduated: false,
            pair: None,
        };
        let launch_key = DataKey::Launch(token.clone());
        e.storage().persistent().set(&launch_key, &launch);
        bump_persistent(&e, &launch_key);
        save_curve(&e, &token, &curve);
        e.storage().persistent().set(&DataKey::LaunchAt(index), &token);
        bump_persistent(&e, &DataKey::LaunchAt(index));
        e.storage().instance().set(&DataKey::LaunchCount, &(index + 1));

        Launched {
            token: token.clone(),
            creator: creator.clone(),
            quote,
            name,
            symbol,
            uri,
            index,
            supply: cfg.supply,
            phantom: econ.phantom,
            threshold: econ.threshold,
            creator_fee_bps,
        }
        .publish(&e);

        if initial_buy > 0 {
            do_buy(&e, &creator, &token, initial_buy, min_tokens_out);
        }
        token
    }

    /// Buys with up to `quote_in` of the launch's quote asset. Near the threshold only the amount that completes
    /// the curve is pulled. Returns the tokens received.
    pub fn buy(e: Env, buyer: Address, token: Address, quote_in: i128, min_tokens_out: i128) -> i128 {
        buyer.require_auth();
        do_buy(&e, &buyer, &token, quote_in, min_tokens_out)
    }

    /// Sells `tokens_in` back to the curve. Returns the quote received.
    pub fn sell(e: Env, seller: Address, token: Address, tokens_in: i128, min_quote_out: i128) -> i128 {
        seller.require_auth();
        let launch = load_launch(&e, &token);
        let mut curve = load_curve(&e, &token);
        if curve.completed || curve.graduated {
            panic_with_error!(&e, Error::CurveClosed);
        }
        if tokens_in <= 0 {
            panic_with_error!(&e, Error::ZeroAmount);
        }
        let q = curve::quote_sell(tokens_in, curve.quote_reserve, curve.token_reserve, launch.fee_bps, launch.creator_fee_bps);
        if q.gross > curve.real_quote {
            panic_with_error!(&e, Error::InsufficientLiquidity);
        }
        if q.quote_out <= 0 || q.quote_out < min_quote_out {
            panic_with_error!(&e, Error::SlippageExceeded);
        }
        let this = e.current_contract_address();
        TokenClient::new(&e, &token).transfer(&seller, &this, &tokens_in);

        curve.quote_reserve -= q.gross;
        curve.token_reserve += tokens_in;
        curve.real_quote -= q.gross;
        accrue_fees(&e, &launch, &mut curve, q.base_fee, q.creator_fee);
        save_curve(&e, &token, &curve);

        TokenClient::new(&e, &launch.quote).transfer(&this, &seller, &q.quote_out);
        Trade {
            token,
            trader: seller,
            is_buy: false,
            quote_amount: q.quote_out,
            token_amount: tokens_in,
            fees: q.base_fee + q.creator_fee,
            quote_reserve: curve.quote_reserve,
            token_reserve: curve.token_reserve,
            real_quote: curve.real_quote,
        }
        .publish(&e);
        q.quote_out
    }

    /// Moves a completed curve into a Soroswap pair at the curve's final price. Anyone can call it.
    /// Returns the pair.
    pub fn graduate(e: Env, token: Address) -> Address {
        let launch = load_launch(&e, &token);
        let mut curve = load_curve(&e, &token);
        if curve.graduated {
            panic_with_error!(&e, Error::AlreadyGraduated);
        }
        if !curve.completed {
            panic_with_error!(&e, Error::NotCompleted);
        }
        let cfg = config(&e);
        let this = e.current_contract_address();
        let pool_quote = curve.real_quote;
        let pool_tokens = curve::pool_tokens(curve.real_quote, curve.token_reserve, curve.quote_reserve);
        let burned = curve.token_reserve - pool_tokens;

        let factory = SoroswapFactoryClient::new(&e, &cfg.soroswap_factory);
        let pair = if factory.pair_exists(&token, &launch.quote) {
            factory.get_pair(&token, &launch.quote)
        } else {
            factory.create_pair(&token, &launch.quote)
        };
        // Straight into the pair, then `deposit`: the pair mints LP for what it received. Using the router instead
        // would let a dust donation + `sync` on the empty pair block graduation.
        let token_client = TokenClient::new(&e, &token);
        token_client.transfer(&this, &pair, &pool_tokens);
        TokenClient::new(&e, &launch.quote).transfer(&this, &pair, &pool_quote);
        let liquidity = SoroswapPairClient::new(&e, &pair).deposit(&this);
        LaunchTokenOpsClient::new(&e, &token).unlock();
        if burned > 0 {
            token_client.burn(&this, &burned);
        }

        curve.graduated = true;
        curve.real_quote = 0;
        curve.token_reserve = 0;
        curve.pair = Some(pair.clone());
        save_curve(&e, &token, &curve);
        Graduated { token, pair: pair.clone(), pool_tokens, pool_quote, liquidity, burned }.publish(&e);
        pair
    }

    /// Pays the creator's accrued fees for `token` to the creator.
    pub fn claim_creator_fees(e: Env, token: Address) -> i128 {
        let launch = load_launch(&e, &token);
        launch.creator.require_auth();
        let mut curve = load_curve(&e, &token);
        let amount = curve.creator_fees;
        if amount <= 0 {
            panic_with_error!(&e, Error::NothingToClaim);
        }
        curve.creator_fees = 0;
        save_curve(&e, &token, &curve);
        TokenClient::new(&e, &launch.quote).transfer(&e.current_contract_address(), &launch.creator, &amount);
        CreatorFeesClaimed { token, creator: launch.creator, amount }.publish(&e);
        amount
    }

    /// Pays the protocol fees accrued in `quote` to the treasury. Anyone can call it.
    pub fn claim_protocol_fees(e: Env, quote: Address) -> i128 {
        let cfg = config(&e);
        let key = DataKey::ProtocolFees(quote.clone());
        let amount: i128 = e.storage().persistent().get(&key).unwrap_or(0);
        if amount <= 0 {
            panic_with_error!(&e, Error::NothingToClaim);
        }
        e.storage().persistent().set(&key, &0i128);
        TokenClient::new(&e, &quote).transfer(&e.current_contract_address(), &cfg.treasury, &amount);
        ProtocolFeesClaimed { quote, treasury: cfg.treasury, amount }.publish(&e);
        amount
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn config(e: Env) -> Config {
        config(&e)
    }

    pub fn quote_economics(e: Env, quote: Address) -> Option<QuoteEconomics> {
        e.storage().persistent().get(&DataKey::Quote(quote))
    }

    pub fn launch_count(e: Env) -> u32 {
        e.storage().instance().get(&DataKey::LaunchCount).unwrap_or(0)
    }

    pub fn launch_at(e: Env, index: u32) -> Address {
        e.storage()
            .persistent()
            .get(&DataKey::LaunchAt(index))
            .unwrap_or_else(|| panic_with_error!(&e, Error::UnknownLaunch))
    }

    pub fn get_launch(e: Env, token: Address) -> Launch {
        load_launch(&e, &token)
    }

    pub fn get_curve(e: Env, token: Address) -> Curve {
        load_curve(&e, &token)
    }

    pub fn protocol_fees(e: Env, quote: Address) -> i128 {
        e.storage().persistent().get(&DataKey::ProtocolFees(quote)).unwrap_or(0)
    }

    /// What `buy` would do now for `buyer` (snipe tax depends on the buyer and the ledger).
    pub fn quote_buy(e: Env, token: Address, buyer: Address, quote_in: i128) -> BuyQuote {
        let launch = load_launch(&e, &token);
        let curve = load_curve(&e, &token);
        if curve.completed || curve.graduated {
            panic_with_error!(&e, Error::CurveClosed);
        }
        price_buy(&e, &launch, &curve, &buyer, quote_in)
    }

    pub fn quote_sell(e: Env, token: Address, tokens_in: i128) -> SellQuote {
        let launch = load_launch(&e, &token);
        let curve = load_curve(&e, &token);
        curve::quote_sell(tokens_in, curve.quote_reserve, curve.token_reserve, launch.fee_bps, launch.creator_fee_bps)
    }
}

// ------------------------------------------------------------------------------------------------ internals

fn do_buy(e: &Env, buyer: &Address, token: &Address, quote_in: i128, min_tokens_out: i128) -> i128 {
    let launch = load_launch(e, token);
    let mut curve = load_curve(e, token);
    if curve.completed || curve.graduated {
        panic_with_error!(e, Error::CurveClosed);
    }
    if quote_in <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
    let q = price_buy(e, &launch, &curve, buyer, quote_in);
    if q.tokens_out <= 0 || q.tokens_out < min_tokens_out {
        panic_with_error!(e, Error::SlippageExceeded);
    }
    let this = e.current_contract_address();
    TokenClient::new(e, &launch.quote).transfer(buyer, &this, &q.used);

    curve.quote_reserve += q.net;
    curve.token_reserve -= q.tokens_out;
    curve.real_quote += q.net;
    accrue_fees(e, &launch, &mut curve, q.base_fee + q.snipe_fee, q.creator_fee);
    let completed_now = curve.real_quote >= curve.threshold;
    if completed_now {
        curve.completed = true;
    }
    save_curve(e, token, &curve);

    TokenClient::new(e, token).transfer(&this, buyer, &q.tokens_out);
    Trade {
        token: token.clone(),
        trader: buyer.clone(),
        is_buy: true,
        quote_amount: q.used,
        token_amount: q.tokens_out,
        fees: q.base_fee + q.snipe_fee + q.creator_fee,
        quote_reserve: curve.quote_reserve,
        token_reserve: curve.token_reserve,
        real_quote: curve.real_quote,
    }
    .publish(e);
    if completed_now {
        Completed { token: token.clone(), real_quote: curve.real_quote }.publish(e);
    }
    q.tokens_out
}

fn price_buy(e: &Env, launch: &Launch, curve: &Curve, buyer: &Address, quote_in: i128) -> BuyQuote {
    let snipe = if *buyer == launch.creator {
        0
    } else {
        let offset = e.ledger().sequence().saturating_sub(launch.created_ledger);
        if offset < launch.snipe_schedule.len() { launch.snipe_schedule.get_unchecked(offset) } else { 0 }
    };
    curve::quote_buy(
        quote_in,
        curve.quote_reserve,
        curve.token_reserve,
        curve.threshold - curve.real_quote,
        launch.fee_bps,
        launch.creator_fee_bps,
        snipe,
    )
}

/// `shared` (curve fee + snipe tax) is split protocol/creator; `creator_only` goes to the creator.
fn accrue_fees(e: &Env, launch: &Launch, curve: &mut Curve, shared: i128, creator_only: i128) {
    let protocol = curve::fee_of(shared, launch.protocol_share_bps);
    curve.creator_fees += shared - protocol + creator_only;
    if protocol > 0 {
        let key = DataKey::ProtocolFees(launch.quote.clone());
        let current: i128 = e.storage().persistent().get(&key).unwrap_or(0);
        e.storage().persistent().set(&key, &(current + protocol));
        bump_persistent(e, &key);
    }
}

fn validate_config(e: &Env, cfg: &Config) {
    let ok = cfg.fee_bps + cfg.max_creator_fee_bps < MAX_TOTAL_BPS
        && cfg.protocol_share_bps <= BPS as u32
        && cfg.supply > 0
        && cfg.snipe_schedule.len() <= MAX_SCHEDULE
        && cfg.snipe_schedule.iter().all(|b| b <= BPS as u32);
    if !ok {
        panic_with_error!(e, Error::InvalidConfig);
    }
}

fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

fn load_launch(e: &Env, token: &Address) -> Launch {
    let key = DataKey::Launch(token.clone());
    let launch = e
        .storage()
        .persistent()
        .get(&key)
        .unwrap_or_else(|| panic_with_error!(e, Error::UnknownLaunch));
    bump_persistent(e, &key);
    launch
}

fn load_curve(e: &Env, token: &Address) -> Curve {
    e.storage()
        .persistent()
        .get(&DataKey::Curve(token.clone()))
        .unwrap_or_else(|| panic_with_error!(e, Error::UnknownLaunch))
}

fn save_curve(e: &Env, token: &Address, curve: &Curve) {
    let key = DataKey::Curve(token.clone());
    e.storage().persistent().set(&key, curve);
    bump_persistent(e, &key);
}

fn bump_persistent(e: &Env, key: &DataKey) {
    e.storage().persistent().extend_ttl(key, PERSISTENT_THRESHOLD, PERSISTENT_BUMP);
}


#[cfg(test)]
mod test;
