//! DyorHQ exec-aquarius (DESIGN-stellar-contracts-v2 §7.2): the caller-restricted Aquarius graduation executor.
//!
//! `graduate` seeds an empty standard pool of the launch's pair with what its source pre-authorized and sends the
//! pool's share token to `lp_to`. A missing pool is created through the router and paid from this contract's AQUA
//! float, within `max_pool_payment`. Anyone may top up the float by transferring AQUA here; only `callers` spend it.
//!
//! The rules of every executor (§7, L4): `callers` (launchpad-v2 and moments-graduator) are fixed at construction,
//! and `graduate` requires `a.source ∈ callers` and the source's auth before it moves anything. It never calls its
//! caller and keeps no state but its configuration and the float. Its errors are namespaced (tag 4, V10) and all are
//! recoverable: a caller's `try_graduate` rolls back every transfer of a failed attempt.
//!
//! The router calls and their auth trees are the ones CT-03's gate confirmed against the testnet fixtures
//! (`dyor_common::aquarius`). This contract calls the router itself, so it pre-authorizes exactly the deeper nodes:
//! the pool payment `transfer(this, payment_address, amount)` and `pool.deposit(this, desired, 0)` with its two
//! `transfer(this, pool, amount)`. During the deposit the launch token moves only from here to the pool, so the
//! launch token's transfer lock (§6.1) allows it.
#![no_std]

use dyor_common::aquarius::{
    sorted_pair, standard_pool_index, AquariusPoolClient, AquariusRouterClient, AQUARIUS_FEE_TIERS,
};
use dyor_common::{GraduateArgs, GraduateResult, TAG_EXEC_AQUARIUS};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token::TokenClient, vec,
    Address, BytesN, Env, IntoVal, Symbol, Vec,
};

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `a.source` is not one of `callers`.
    NotCaller = 10_401,
    /// A non-positive amount, a negative `min_liquidity`, the same asset on both sides, or a negative
    /// `max_pool_payment` at construction.
    InvalidAmounts = 10_402,
    /// `params.fee_fraction` is not 10, 30 or 100.
    UnsupportedFeeTier = 10_403,
    /// The pool is missing and the float can't pay for it: the router asks for another asset, or the float is short.
    PaymentUnavailable = 10_404,
    /// The router's pool payment is above `max_pool_payment`.
    PaymentTooHigh = 10_405,
    /// The pool already has shares (the tripwire, §7).
    PoolNotEmpty = 10_406,
    /// The deposit minted fewer shares than `min_liquidity`.
    LiquidityTooLow = 10_407,
}
dyor_common::assert_err_codes!(
    TAG_EXEC_AQUARIUS;
    Error::NotCaller = 1,
    Error::InvalidAmounts = 2,
    Error::UnsupportedFeeTier = 3,
    Error::PaymentUnavailable = 4,
    Error::PaymentTooHigh = 5,
    Error::PoolNotEmpty = 6,
    Error::LiquidityTooLow = 7,
);

/// Fixed at construction; there are no setters.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub router: Address,
    /// The float's asset (testnet: the AQUA SAC).
    pub payment_asset: Address,
    pub max_pool_payment: i128,
    pub callers: Vec<Address>,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Config,
}

/// One graduation, as exec-soroswap reports it.
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
pub struct ExecAquarius;

#[contractimpl]
impl ExecAquarius {
    pub fn __constructor(
        e: Env,
        router: Address,
        payment_asset: Address,
        max_pool_payment: i128,
        callers: Vec<Address>,
    ) {
        if max_pool_payment < 0 {
            panic_with_error!(&e, Error::InvalidAmounts);
        }
        e.storage().instance().set(&DataKey::Config, &Config { router, payment_asset, max_pool_payment, callers });
    }

    /// Seeds the empty standard pool of `(a.token, a.quote)` with fee `a.params.fee_fraction`, creating it if it is
    /// missing, and sends the share token to `a.lp_to`. The source pre-authorized `transfer(source, this, amount)`
    /// on both assets. Leftovers go back to the source.
    pub fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, Error> {
        let cfg = config(&e);
        if !cfg.callers.contains(&a.source) {
            return Err(Error::NotCaller);
        }
        a.source.require_auth();
        if a.token_amount <= 0 || a.quote_amount <= 0 || a.min_liquidity < 0 || a.token == a.quote {
            return Err(Error::InvalidAmounts);
        }
        let fee_fraction = a.params.fee_fraction;
        if !AQUARIUS_FEE_TIERS.contains(&fee_fraction) {
            return Err(Error::UnsupportedFeeTier);
        }

        let this = e.current_contract_address();
        let router = AquariusRouterClient::new(&e, &cfg.router);
        let tokens = sorted_pair(&e, &a.token, &a.quote);
        let index = standard_pool_index(&e, fee_fraction);
        let (index, pool) = match router.get_pools(&tokens).get(index.clone()) {
            Some(pool) => (index, pool),
            None => create_pool(&e, &cfg, &router, &tokens, fee_fraction)?,
        };
        let pool_client = AquariusPoolClient::new(&e, &pool);
        if pool_client.get_total_shares() != 0 {
            return Err(Error::PoolNotEmpty);
        }

        TokenClient::new(&e, &a.token).transfer(&a.source, &this, &a.token_amount);
        TokenClient::new(&e, &a.quote).transfer(&a.source, &this, &a.quote_amount);

        // `tokens` order. Both amounts are positive i128s, so the casts are exact.
        let token_first = tokens.get_unchecked(0) == a.token;
        let (first, second) =
            if token_first { (a.token_amount, a.quote_amount) } else { (a.quote_amount, a.token_amount) };
        let desired = vec![&e, first as u128, second as u128];
        // min_shares 0: the shares are checked below, so a shortfall fails with this contract's own error.
        e.authorize_as_current_contract(vec![
            &e,
            InvokerContractAuthEntry::Contract(SubContractInvocation {
                context: ContractContext {
                    contract: pool.clone(),
                    fn_name: Symbol::new(&e, "deposit"),
                    args: (this.clone(), desired.clone(), 0u128).into_val(&e),
                },
                sub_invocations: vec![
                    &e,
                    transfer_entry(&e, &tokens.get_unchecked(0), &this, &pool, first),
                    transfer_entry(&e, &tokens.get_unchecked(1), &this, &pool, second),
                ],
            }),
        ]);
        let (amounts, shares) = router.deposit(&this, &tokens, &index, &desired, &0);

        let used = |i: u32| amounts.get(i).and_then(|x| i128::try_from(x).ok());
        let (Some(used_first), Some(used_second)) = (used(0), used(1)) else {
            return Err(Error::InvalidAmounts);
        };
        let (token_used, quote_used) = if token_first { (used_first, used_second) } else { (used_second, used_first) };
        if token_used > a.token_amount || quote_used > a.quote_amount {
            return Err(Error::InvalidAmounts);
        }
        let liquidity = i128::try_from(shares).unwrap_or(i128::MAX);
        if liquidity <= 0 || liquidity < a.min_liquidity {
            return Err(Error::LiquidityTooLow);
        }

        let lp_token = pool_client.share_id();
        TokenClient::new(&e, &lp_token).transfer(&this, &a.lp_to, &liquidity);
        if token_used < a.token_amount {
            TokenClient::new(&e, &a.token).transfer(&this, &a.source, &(a.token_amount - token_used));
        }
        if quote_used < a.quote_amount {
            TokenClient::new(&e, &a.quote).transfer(&this, &a.source, &(a.quote_amount - quote_used));
        }

        ExecGraduated { source: a.source, token: a.token, quote: a.quote, pool: pool.clone(), liquidity }.publish(&e);
        Ok(GraduateResult { pool, lp_token, liquidity, token_used, quote_used })
    }

    /// The AQUA this executor holds for pool payments.
    pub fn float(e: Env) -> i128 {
        let cfg = config(&e);
        TokenClient::new(&e, &cfg.payment_asset).balance(&e.current_contract_address())
    }

    /// The router's current payment for a new standard pool: `(asset, amount)`. The deploy script and the keeper
    /// compare the float with it (target 50×, alert below 5×, F11).
    pub fn pool_payment(e: Env) -> (Address, i128) {
        let router = AquariusRouterClient::new(&e, &config(&e).router);
        let amount = i128::try_from(router.get_standard_pool_payment_amount()).unwrap_or(i128::MAX);
        (router.get_init_pool_payment_token(), amount)
    }

    pub fn max_pool_payment(e: Env) -> i128 {
        config(&e).max_pool_payment
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_EXEC_AQUARIUS
    }
}

fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

/// Creates the missing standard pool, paying the router's fee from the float. Returns `(pool_index, pool)`.
fn create_pool(
    e: &Env,
    cfg: &Config,
    router: &AquariusRouterClient,
    tokens: &Vec<Address>,
    fee_fraction: u32,
) -> Result<(BytesN<32>, Address), Error> {
    let this = e.current_contract_address();
    let amount = router.get_standard_pool_payment_amount();
    if amount > 0 {
        if router.get_init_pool_payment_token() != cfg.payment_asset {
            return Err(Error::PaymentUnavailable);
        }
        let amount = match i128::try_from(amount) {
            Ok(amount) if amount <= cfg.max_pool_payment => amount,
            _ => return Err(Error::PaymentTooHigh),
        };
        if TokenClient::new(e, &cfg.payment_asset).balance(&this) < amount {
            return Err(Error::PaymentUnavailable);
        }
        let to = router.get_init_pool_payment_address();
        e.authorize_as_current_contract(vec![e, transfer_entry(e, &cfg.payment_asset, &this, &to, amount)]);
    }
    Ok(router.init_standard_pool(&this, tokens, &fee_fraction))
}

/// The auth node of `asset.transfer(from, to, amount)`.
fn transfer_entry(e: &Env, asset: &Address, from: &Address, to: &Address, amount: i128) -> InvokerContractAuthEntry {
    InvokerContractAuthEntry::Contract(SubContractInvocation {
        context: ContractContext {
            contract: asset.clone(),
            fn_name: Symbol::new(e, "transfer"),
            args: (from.clone(), to.clone(), amount).into_val(e),
        },
        sub_invocations: Vec::new(e),
    })
}

#[cfg(test)]
mod test;
