//! DyorHQ exec-soroswap (DESIGN-stellar-contracts-v2 §7.1): the caller-restricted, stateless Soroswap graduation
//! executor.
//!
//! `graduate` seeds a fresh Soroswap pair for one of the callers fixed at construction, launchpad-v2 and
//! moments-graduator (decision L4):
//! 1. the source must be one of the callers (`NotCaller`) and must authorize the call;
//! 2. both assets are pulled from the source, which pre-authorized exactly `transfer(source, this, amount)` on each;
//! 3. the pair is fetched or created, and a pair that already has LP supply is refused (`PoolNotEmpty`): with the
//!    launch token's transfer lock and the caller rule nobody else can seed one, so this is a tripwire;
//! 4. both amounts go straight into the pair, then `deposit(lp_to)` mints the LP. A pre-created pair holding a quote
//!    donation (synced into its reserves or not) still graduates: the donation can't mint LP without the token side,
//!    it only raises the opening price in the LP's favour (S:contracts/launchpad/src/lib.rs:511-516);
//! 5. the minted LP must reach `min_liquidity` (`LiquidityTooLow`).
//!
//! Every error is a recoverable contract error, so the caller's `try_` frame rolls back the pulls, the pair's creation
//! and the deposit. Soroswap's `deposit` takes everything that was sent in, so nothing is left over to return: the
//! result reports both amounts as used, and the caller checks that against its own balances (§5.5).
//!
//! The factory and the callers are the only state, in the instance. The executor never calls its caller, and it never
//! moves a balance it didn't pull in the same call: anything sent to it by others stays where it is, so it can't skew
//! the caller's balance checks.
#![no_std]

use dyor_common::{GraduateArgs, GraduateResult, SoroswapFactoryClient, SoroswapPairClient, TAG_EXEC_SOROSWAP};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, token::TokenClient, Address, Env, Vec,
};

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Factory,
    Callers,
}

/// On-chain values are `ERR_BASE + 3·100 + n` (§4, finding V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `source` is not one of the callers fixed at construction.
    NotCaller = 10_301,
    /// An amount to seed is zero or negative.
    InvalidAmounts = 10_302,
    /// The pair already has LP supply; seeding it would share the liquidity with an earlier LP.
    PoolNotEmpty = 10_303,
    /// The pair minted less LP than `min_liquidity`.
    LiquidityTooLow = 10_304,
}
dyor_common::assert_err_codes!(TAG_EXEC_SOROSWAP;
    Error::NotCaller = 1,
    Error::InvalidAmounts = 2,
    Error::PoolNotEmpty = 3,
    Error::LiquidityTooLow = 4,
);

/// A pair seeded for `source`; the LP went to the `lp_to` of its call.
#[contractevent(topics = ["exec_grad"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecGraduated {
    #[topic]
    pub source: Address,
    #[topic]
    pub token: Address,
    pub quote: Address,
    pub pool: Address,
    pub liquidity: i128,
}

#[contract]
pub struct ExecSoroswap;

#[contractimpl]
impl ExecSoroswap {
    /// `callers` are launchpad-v2 and moments-graduator, by the ids the deploy script precomputes (§3.4).
    pub fn __constructor(e: Env, factory: Address, callers: Vec<Address>) {
        e.storage().instance().set(&DataKey::Factory, &factory);
        e.storage().instance().set(&DataKey::Callers, &callers);
    }

    /// Seeds the `token`/`quote` pair with exactly `token_amount` and `quote_amount` pulled from `source`, and sends
    /// the LP to `lp_to`. The pool is the pair, which is also its own LP token.
    pub fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, Error> {
        if !callers(&e).contains(&a.source) {
            return Err(Error::NotCaller);
        }
        a.source.require_auth();
        if a.token_amount <= 0 || a.quote_amount <= 0 {
            return Err(Error::InvalidAmounts);
        }

        let this = e.current_contract_address();
        let token = TokenClient::new(&e, &a.token);
        let quote = TokenClient::new(&e, &a.quote);
        token.transfer(&a.source, &this, &a.token_amount);
        quote.transfer(&a.source, &this, &a.quote_amount);

        let factory = SoroswapFactoryClient::new(&e, &factory(&e));
        let pool = if factory.pair_exists(&a.token, &a.quote) {
            factory.get_pair(&a.token, &a.quote)
        } else {
            factory.create_pair(&a.token, &a.quote)
        };
        let pair = SoroswapPairClient::new(&e, &pool);
        if pair.total_supply() != 0 {
            return Err(Error::PoolNotEmpty);
        }

        // Straight into the pair, then `deposit`: the pair mints LP for what it received above its reserves, so a dust
        // donation plus `sync` can't block the graduation the way it would block the router's `add_liquidity`.
        token.transfer(&this, &pool, &a.token_amount);
        quote.transfer(&this, &pool, &a.quote_amount);
        let liquidity = pair.deposit(&a.lp_to);
        if liquidity < a.min_liquidity {
            return Err(Error::LiquidityTooLow);
        }

        ExecGraduated { source: a.source, token: a.token, quote: a.quote, pool: pool.clone(), liquidity }.publish(&e);
        Ok(GraduateResult {
            pool: pool.clone(),
            lp_token: pool,
            liquidity,
            token_used: a.token_amount,
            quote_used: a.quote_amount,
        })
    }

    // -------------------------------------------------------------------------------------------- views

    pub fn factory(e: Env) -> Address {
        factory(&e)
    }

    pub fn callers(e: Env) -> Vec<Address> {
        callers(&e)
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_EXEC_SOROSWAP
    }
}

fn factory(e: &Env) -> Address {
    e.storage().instance().get(&DataKey::Factory).unwrap()
}

fn callers(e: &Env) -> Vec<Address> {
    e.storage().instance().get(&DataKey::Callers).unwrap()
}

#[cfg(test)]
mod test;
