//! Client traits for every cross-contract call between the v2 contracts and to Soroswap (DESIGN-stellar-contracts-v2
//! §3.2, §4). SEP-41 calls (`transfer`, `balance`, `burn`) go through `soroban_sdk::token::TokenClient`; these
//! traits cover what SEP-41 doesn't. The Aquarius router and pool traits live in [`crate::aquarius`].
//!
//! A plain call unwraps the result, so an error in the callee traps the caller. `Executor` and `Graduator` declare
//! `soroban_sdk::Error` as their error type: their `try_` forms hand the callee's error over unchanged, contract
//! code and all, for [`crate::grad_failure`] to decode.

use crate::{
    GraduateArgs, GraduateResult, HarvestPayees, MomentGradArgs, MomentGradResult, PositionRef, VenueKind,
};
use soroban_sdk::{contractclient, Address, Env};

/// launch-token-v2 beyond SEP-41 (§6.4).
#[contractclient(name = "LaunchTokenV2Client")]
pub trait LaunchTokenV2 {
    /// Opens transfers, once: at graduation or at rescue. Launchpad only.
    fn unlock(e: Env);
    /// Excludes `account` (the graduation pool) from holder rewards. Launchpad only.
    fn exclude(e: Env, account: Address) -> bool;
    /// Queues `amount` of `asset` (the quote, or the token itself) for holders. `notifier` is the launchpad or the
    /// locker, which transferred the funds first.
    fn notify_reward(e: Env, notifier: Address, asset: Address, amount: i128);
    /// Excludes the launchpad's current treasury from holder rewards; false with sharing off. Never called from
    /// inside a launchpad call (it reads `launchpad.treasury()`).
    fn exclude_treasury(e: Env) -> bool;
    fn total_supply(e: Env) -> i128;
}

/// A graduation executor (§7): exec-soroswap, exec-aquarius or qa-exec-fail.
#[contractclient(name = "ExecutorClient")]
pub trait Executor {
    fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, soroban_sdk::Error>;
}

/// lp-locker (§8.2), as its owners call it.
#[contractclient(name = "LockerClient")]
pub trait Locker {
    /// Registers a position whose LP the caller has already sent. `owner` must be one of the locker's owners.
    #[allow(clippy::too_many_arguments)]
    fn register(
        e: Env,
        owner: Address,
        pool: Address,
        kind: VenueKind,
        lp_token: Address,
        lp: i128,
        base: Address,
        quote: Address,
        reference: PositionRef,
        harvest_bps: u32,
    );
    /// Seconds between harvests of one position; both owners' constructors require it to equal their durations' (F6).
    fn harvest_interval(e: Env) -> u64;
}

/// A locker owner (launchpad-v2, moments-v2): who receives each side of a position's harvest. Graduated positions
/// only; the owner refuses a reference of the other kind.
#[contractclient(name = "HarvestOwnerClient")]
pub trait HarvestOwner {
    fn harvest_payees(e: Env, reference: PositionRef) -> HarvestPayees;
}

/// moment-nft (§10), as moments-v2 calls it.
#[contractclient(name = "MomentNftClient")]
pub trait MomentNft {
    /// Mints `qty` sequential editions to `to` and returns the first edition number. Minter only.
    fn mint(e: Env, to: Address, qty: u32) -> u32;
    /// Freezes the edition size. Minter only, once.
    fn close(e: Env);
}

/// moment-coin (§11) beyond SEP-41.
#[contractclient(name = "MomentCoinClient")]
pub trait MomentCoin {
    /// Minter only, up to the cap.
    fn mint(e: Env, to: Address, amount: i128);
    fn cap(e: Env) -> i128;
    fn total_supply(e: Env) -> i128;
}

/// moments-graduator (§12).
#[contractclient(name = "GraduatorClient")]
pub trait Graduator {
    fn graduate(e: Env, a: MomentGradArgs) -> Result<MomentGradResult, soroban_sdk::Error>;
    /// The coin address a Moment's graduation deploys, predicted from its NFT address.
    fn coin_address(e: Env, nft: Address) -> Address;
}

/// launchpad-v2's treasury view, read by launch-token-v2 in `exclude_treasury` and `sweep_protocol`.
#[contractclient(name = "TreasurySourceClient")]
pub trait TreasurySource {
    fn treasury(e: Env) -> Address;
}

/// Soroswap factory (UniswapV2-style). Its functions return `Result<_, FactoryError>`; a plain call traps on an
/// error.
#[contractclient(name = "SoroswapFactoryClient")]
pub trait SoroswapFactory {
    fn pair_exists(e: Env, token_a: Address, token_b: Address) -> bool;
    fn get_pair(e: Env, token_a: Address, token_b: Address) -> Address;
    fn create_pair(e: Env, token_a: Address, token_b: Address) -> Address;
}

/// Soroswap pair. The pair is also its own LP token (SEP-41); `deposit(to)` mints LP for whatever was transferred in
/// and `withdraw(to)` burns the LP transferred in, both without auth, like UniswapV2's `mint` and `burn`.
#[contractclient(name = "SoroswapPairClient")]
pub trait SoroswapPair {
    fn token_0(e: Env) -> Address;
    fn token_1(e: Env) -> Address;
    fn get_reserves(e: Env) -> (i128, i128);
    fn total_supply(e: Env) -> i128;
    fn deposit(e: Env, to: Address) -> i128;
    fn withdraw(e: Env, to: Address) -> (i128, i128);
}
