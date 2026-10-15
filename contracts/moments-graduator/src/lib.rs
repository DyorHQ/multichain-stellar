//! DyorHQ moments-graduator (DESIGN-stellar-contracts-v2 §12): the `try_` target of moments-v2's graduation. It
//! deploys a Moment's coin, seeds the coin's Soroswap pool through the executor and checks the result in its own
//! frame.
//!
//! `graduate` runs for moments-v2 only, inside moments' `try_graduate` frame (§9.3):
//! 1. moments must authorize the call. As the direct caller its auth is implicit; any other caller fails the host's
//!    auth check before anything happens;
//! 2. it reads moments' USDC balance from the SAC (never from moments, §3.3) and pulls the reserve, which moments
//!    pre-authorized as exactly `usdc.transfer(moments, this, reserve)`;
//! 3. it deploys the coin at the address `coin_address(nft)` predicts, salt `sha256("dyorhq/moment-coin/v2" ‖
//!    nft.to_xdr())`, with moment-coin's constructor `(minter = moments, name, symbol, cap = S, initial_to = this,
//!    initial_amount = pool_coins)`;
//! 4. it pre-authorizes exactly `transfer(this, executor, amount)` on the coin and on USDC and calls the executor
//!    (exec-soroswap; qa-exec-fail on testnet-qa's failing stack, F5) with the LP going to the locker and
//!    `min_liquidity = isqrt(pool_coins·reserve) − SOROSWAP_MIN_LIQ − 1`. Executors list this contract among their
//!    callers (L4);
//! 5. it checks the executor's report in this frame, before any leftover moves (F15, V9):
//!    - each side's used amount lies within `GRAD_DUST_BPS` of what was sent and never above it;
//!    - this contract's coin and USDC balances fell by exactly the amounts reported as used;
//!    - `liquidity ≥ min_liquidity`, and the coin is the one moments expects (`expected_coin`, predicted at publish);
//!    - the pool is the Soroswap factory's pair of the coin and USDC and is its own LP token (as §5.5 requires of a
//!      Soroswap venue), the locker holds at least `liquidity` of it, and the pool holds the coins and USDC
//!      reported as used. That last pair of checks catches an executor that keeps part of what it pulled while it
//!      reports everything as used: the balance deltas can't see it, and the liquidity bound sees it only once the
//!      shortfall moves √k by a unit;
//! 6. it burns the coins the pool didn't take, sends the USDC it didn't use back to moments and checks the USDC
//!    accounting against moments' own balance.
//!
//! A failed check returns `GraduationInvalid` (11_003), a recoverable error: moments' `try_graduate` rolls back the
//! whole frame (the coin's deployment, the pull, the pair's creation and the deposit) and records the failure, which
//! is what starts the Moment's stuck clock (§9.2). An executor's own error reaches moments unchanged, in the
//! executor's namespace (V10). moments registers the LP with the locker after this frame has returned (§9.3).
//!
//! The configuration, fixed at construction, is the only state; nothing here holds funds between calls, and no call
//! extends the instance's TTL (DECISIONS #10): the keeper keeps it alive.
#![no_std]

use dyor_common::{
    isqrt_u128, mul_div, ExecutorClient, GraduateArgs, MomentGradArgs, MomentGradResult, SoroswapFactoryClient,
    VenueParams, BPS, GRAD_DUST_BPS, SOROSWAP_MIN_LIQ, TAG_MOMENTS_GRADUATOR,
};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, token::TokenClient, vec, xdr::ToXdr, Address, Bytes, BytesN,
    Env, IntoVal, Symbol, Vec,
};

/// One coin: every Moment coin has 7 decimals, like USDC on Stellar (§0 X1).
const ONE_COIN: i128 = 10_000_000;
/// S, every Moment coin's cap: 100M coins (§14.2). moments-v2 derives `pool_coins` from the same S (§9.3).
pub const COIN_SUPPLY: i128 = 100_000_000 * ONE_COIN;
/// What the coin's salt hashes ahead of the NFT's XDR (§12).
const COIN_SALT_DOMAIN: &[u8] = b"dyorhq/moment-coin/v2";

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Config,
}

/// Fixed at construction; there are no setters (§3.4).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    /// moments-v2, the only caller, the coins' minter and where unused USDC goes back.
    pub moments: Address,
    /// moment-coin's WASM.
    pub coin_wasm_hash: BytesN<32>,
    pub executor: Address,
    /// lp-locker, where the LP goes.
    pub locker: Address,
    /// The Soroswap factory the pool is checked against.
    pub soroswap_factory: Address,
}

/// The local codes of §12 in this contract's namespace: on chain `ERR_BASE + 10·100 + n` (§4, V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// Numbered for §12's table. `graduate` checks moments' auth with `require_auth`, so a call moments didn't make
    /// fails in the host's auth check before this could be raised.
    NotMoments = 11_001,
    /// `reserve` or `pool_coins` isn't positive, `pool_coins` exceeds S, or the two can't seed a Soroswap pool above
    /// its minimum-liquidity lock (`min_liquidity` below 1).
    InvalidAmounts = 11_002,
    /// The executor's report failed a result check. moments records it as a failed attempt (F15, V9).
    GraduationInvalid = 11_003,
}
dyor_common::assert_err_codes!(
    TAG_MOMENTS_GRADUATOR;
    Error::NotMoments = 1,
    Error::InvalidAmounts = 2,
    Error::GraduationInvalid = 3,
);

#[contract]
pub struct MomentsGraduator;

#[contractimpl]
impl MomentsGraduator {
    /// The peers are the ids the deploy script precomputes (§3.4): `moments` (moments-v2), `executor`
    /// (exec-soroswap, or qa-exec-fail for testnet-qa's failing stack) and `locker`; `coin_wasm_hash` is
    /// moment-coin's WASM.
    pub fn __constructor(
        e: Env,
        moments: Address,
        coin_wasm_hash: BytesN<32>,
        executor: Address,
        locker: Address,
        soroswap_factory: Address,
    ) {
        let cfg = Config { moments, coin_wasm_hash, executor, locker, soroswap_factory };
        e.storage().instance().set(&DataKey::Config, &cfg);
    }

    /// Graduates one Moment for moments-v2: deploys its coin, seeds the coin/USDC Soroswap pool with `pool_coins`
    /// and the `reserve` (which moments pre-authorized), sends the LP to the locker and checks the result. Unused
    /// coins are burned and unused USDC goes back to moments.
    pub fn graduate(e: Env, a: MomentGradArgs) -> Result<MomentGradResult, Error> {
        let cfg = config(&e);
        cfg.moments.require_auth();
        let min_liquidity = min_liquidity(a.pool_coins, a.reserve).ok_or(Error::InvalidAmounts)?;

        let this = e.current_contract_address();
        let usdc = TokenClient::new(&e, &a.usdc);
        let u0 = usdc.balance(&cfg.moments);
        usdc.transfer(&cfg.moments, &this, &a.reserve);

        let coin_id = e.deployer().with_current_contract(coin_salt(&e, &a.nft)).deploy_v2(
            cfg.coin_wasm_hash,
            (cfg.moments.clone(), a.name, a.symbol, COIN_SUPPLY, this.clone(), a.pool_coins),
        );
        let coin = TokenClient::new(&e, &coin_id);
        let (c0, g0) = (coin.balance(&this), usdc.balance(&this));

        // The executor pulls both assets from here: exactly these two transfers, valid for its call only.
        e.authorize_as_current_contract(vec![
            &e,
            transfer_entry(&e, &coin_id, &this, &cfg.executor, a.pool_coins),
            transfer_entry(&e, &a.usdc, &this, &cfg.executor, a.reserve),
        ]);
        let r = ExecutorClient::new(&e, &cfg.executor).graduate(&GraduateArgs {
            source: this.clone(),
            token: coin_id.clone(),
            quote: a.usdc.clone(),
            token_amount: a.pool_coins,
            quote_amount: a.reserve,
            lp_to: cfg.locker.clone(),
            params: VenueParams { fee_fraction: 0 },
            min_liquidity,
        });

        // The result checks (F15, V9), before any leftover moves. The pool's balances are read only once the pool is
        // known to be the factory's pair.
        let valid = within_dust(r.token_used, a.pool_coins)
            && within_dust(r.quote_used, a.reserve)
            && c0 - coin.balance(&this) == r.token_used
            && g0 - usdc.balance(&this) == r.quote_used
            && r.liquidity >= min_liquidity
            && coin_id == a.expected_coin
            && r.lp_token == r.pool
            && is_pair(&e, &cfg.soroswap_factory, &coin_id, &a.usdc, &r.pool)
            && holds(&e, &r.lp_token, &cfg.locker, r.liquidity)
            && coin.balance(&r.pool) >= r.token_used
            && usdc.balance(&r.pool) >= r.quote_used;
        if !valid {
            return Err(Error::GraduationInvalid);
        }

        // Leftovers: at most GRAD_DUST_BPS of each side.
        let coins_left = a.pool_coins - r.token_used;
        if coins_left > 0 {
            coin.burn(&this, &coins_left);
        }
        let usdc_returned = a.reserve - r.quote_used;
        if usdc_returned > 0 {
            usdc.transfer(&this, &cfg.moments, &usdc_returned);
        }
        // The accounting moments relies on (§9.3): what the pool used and what came back make up the reserve, and
        // moments' balance fell by exactly what the pool used.
        if r.quote_used + usdc_returned != a.reserve || u0 - usdc.balance(&cfg.moments) != r.quote_used {
            return Err(Error::GraduationInvalid);
        }

        Ok(MomentGradResult {
            coin: coin_id,
            pool: r.pool,
            lp_token: r.lp_token,
            liquidity: r.liquidity,
            coin_used: r.token_used,
            usdc_used: r.quote_used,
            usdc_returned,
        })
    }

    // -------------------------------------------------------------------------------------------- views

    /// The address `graduate` deploys the coin of the Moment whose NFT is `nft` at. moments-v2 records it at
    /// publish and passes it back as `expected_coin`.
    pub fn coin_address(e: Env, nft: Address) -> Address {
        e.deployer().with_current_contract(coin_salt(&e, &nft)).deployed_address()
    }

    pub fn moments(e: Env) -> Address {
        config(&e).moments
    }

    pub fn coin_wasm_hash(e: Env) -> BytesN<32> {
        config(&e).coin_wasm_hash
    }

    pub fn executor(e: Env) -> Address {
        config(&e).executor
    }

    pub fn locker(e: Env) -> Address {
        config(&e).locker
    }

    pub fn soroswap_factory(e: Env) -> Address {
        config(&e).soroswap_factory
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_MOMENTS_GRADUATOR
    }
}

fn config(e: &Env) -> Config {
    e.storage().instance().get(&DataKey::Config).unwrap()
}

/// `sha256("dyorhq/moment-coin/v2" ‖ nft.to_xdr())` (§12): one coin address per Moment, known from its publish on.
fn coin_salt(e: &Env, nft: &Address) -> BytesN<32> {
    let mut seed = Bytes::from_slice(e, COIN_SALT_DOMAIN);
    seed.append(&nft.clone().to_xdr(e));
    e.crypto().sha256(&seed).into()
}

/// `isqrt(pool_coins·reserve) − SOROSWAP_MIN_LIQ − 1` (§12): what a first deposit of both amounts mints, less one
/// unit for rounding. `None` when an amount isn't positive, `pool_coins` exceeds S or the product overflows, or when
/// the pool would mint less than 1.
fn min_liquidity(pool_coins: i128, reserve: i128) -> Option<i128> {
    if pool_coins <= 0 || pool_coins > COIN_SUPPLY || reserve <= 0 {
        return None;
    }
    let product = (pool_coins as u128).checked_mul(reserve as u128)?;
    let min = isqrt_u128(product) as i128 - SOROSWAP_MIN_LIQ - 1;
    (min > 0).then_some(min)
}

/// `amount − amount·GRAD_DUST_BPS/BPS ≤ used ≤ amount`.
fn within_dust(used: i128, amount: i128) -> bool {
    amount - mul_div(amount, GRAD_DUST_BPS as i128, BPS as i128) <= used && used <= amount
}

/// Whether `pool` is the Soroswap factory's pair of `coin` and `usdc`. A lookup that fails (no such pair) is a no.
fn is_pair(e: &Env, factory: &Address, coin: &Address, usdc: &Address, pool: &Address) -> bool {
    matches!(SoroswapFactoryClient::new(e, factory).try_get_pair(coin, usdc), Ok(Ok(pair)) if pair == *pool)
}

/// Whether `holder` holds at least `amount` of `token`. A balance call that fails is a no, never a trap: the lead's
/// ruling after CT-01..03, for LP tokens without a balance function such as the one qa-exec-fail's mode 2 reports.
fn holds(e: &Env, token: &Address, holder: &Address, amount: i128) -> bool {
    matches!(TokenClient::new(e, token).try_balance(holder), Ok(Ok(held)) if held >= amount)
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
