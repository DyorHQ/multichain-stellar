//! Graduation (§9.3) and the harvest payees (§9.2).
//!
//! **graduate** is permissionless: the keeper calls it in the ledgers after the terminal collect (L3), and the creator
//! or any collector may call it too. One attempt goes through `try_` into moments-graduator, which pulls the reserve
//! (moments pre-authorizes exactly `usdc.transfer(this, graduator, reserve)`), deploys the coin at the address
//! predicted at publish, seeds the Soroswap pool, sends the LP to the locker and checks the result inside its own
//! frame (§12, F15, V9):
//! - **A recoverable failure** (any error the graduator's frame returns, its own in-frame `GraduationInvalid` 11_003
//!   included) rolls that frame back and is recorded: `grad_failure` names its origin and code (V10), and the first
//!   one starts the stuck clock. This is the only place that writes a non-zero `stuck_since` (F15); retries keep it.
//! - **A success** is checked again here as defence in depth (B12): the coin, the USDC accounting with its balance
//!   delta, the coin side's bounds (V9), the liquidity against §12's minimum, the pool against the Soroswap factory
//!   (a pair is its own LP token, as launchpad-v2 checks too, §5.5) and the LP at the locker. A failed check panics
//!   `GraduationInvalid`, which aborts the whole transaction, since the graduator's frame has already committed; it
//!   can only happen if the graduator is wrong. Otherwise the Moment is Graduated: `stuck_since` resets (I-M6), the
//!   vesting clock starts, the NFT closes and the locker registers the position at `MOMENT_HARVEST_BPS`.
//!
//! Budget or footprint exhaustion can't be caught by `try_`: such an attempt aborts and records nothing, and only the
//! backstop of `expire` ends that Moment (V11, §25 R18).
//!
//! **harvest_payees** answers the locker on every harvest of a graduated Moment: the USDC side 40% creator / 60%
//! platform, the Moment's snapshotted beneficiaries; the coin side burned (an empty list). With the locker's
//! `MOMENT_HARVEST_BPS` that is Monad's 0.2 / 0.3 / 0.5 / 0.5 side by side (F1, V3): compounded : harvested =
//! 3,333 : 6,667, and a third of fee value deepens the pool instead of Monad's two thirds (V4).

use crate::events::{GraduationFailed, GraduationSucceeded};
use crate::storage::{self, Config, Ledger, Moment, State};
use crate::vesting::creator_allocation;
use crate::{
    Error, MomentsV2, MomentsV2Args, MomentsV2Client, NftMetadataClient, MOMENT_HARVEST_BPS,
    MOMENT_HARVEST_CREATOR_BPS, SUPPLY,
};
use dyor_common::{
    grad_failure, isqrt_u128, mul_div, GraduationOutcome, GraduatorClient, HarvestPayees, LockerClient, MomentGradArgs,
    MomentGradResult, MomentNftClient, Payee, PositionRef, SoroswapFactoryClient, VenueKind, BPS, GRAD_DUST_BPS,
    SOROSWAP_MIN_LIQ,
};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{contractimpl, panic_with_error, symbol_short, token::TokenClient, vec, Address, Env, IntoVal, Vec};

/// The coins graduation seeds the pool with: S less the creator's allocation and every collector's entitlement, so
/// `pool_coins + alloc + Σ entitlements == S` at graduation (I-M3, MomentGraduation.sol:92-99).
pub(crate) fn pool_coins(m: &Moment, l: &Ledger) -> i128 {
    SUPPLY - creator_allocation(m) - l.entitlements
}

/// The least LP a Soroswap pool seeded with `pool_coins` and `reserve` mints: `isqrt(pool_coins·reserve)` less the
/// pair's minimum-liquidity lock, less one for rounding (§12). Both amounts are far below 2^64 (S = 10^15, the
/// threshold at most 10^13), so the product fits u128.
fn min_liquidity(pool_coins: i128, reserve: i128) -> i128 {
    isqrt_u128(pool_coins as u128 * reserve as u128) as i128 - SOROSWAP_MIN_LIQ - 1
}

/// `x` less the dust an executor may leave unused (`GRAD_DUST_BPS`, 1 bp).
fn less_dust(x: i128) -> i128 {
    x - mul_div(x, GRAD_DUST_BPS as i128, BPS as i128)
}

/// §9.3's result checks, repeated after the graduator ran them in its frame. `usdc_delta` is what this contract's
/// USDC balance fell by. The two cross-contract reads run last, and a read that fails (no such pair, an LP token
/// without a balance) counts as a failed check, never as a trap.
fn result_ok(e: &Env, cfg: &Config, a: &MomentGradArgs, r: &MomentGradResult, usdc_delta: i128) -> bool {
    r.coin == a.expected_coin
        && r.usdc_returned >= 0
        && r.usdc_used.checked_add(r.usdc_returned) == Some(a.reserve)
        && r.usdc_used >= less_dust(a.reserve)
        && usdc_delta == r.usdc_used
        && r.coin_used >= less_dust(a.pool_coins)
        && r.coin_used <= a.pool_coins
        && r.liquidity > 0
        && r.liquidity >= min_liquidity(a.pool_coins, a.reserve)
        // A Soroswap pair is its own LP token.
        && r.lp_token == r.pool
        && matches!(SoroswapFactoryClient::new(e, &cfg.soroswap_factory).try_get_pair(&r.coin, &cfg.usdc),
            Ok(Ok(pair)) if pair == r.pool)
        && matches!(TokenClient::new(e, &r.lp_token).try_balance(&cfg.locker),
            Ok(Ok(held)) if held >= r.liquidity)
}

#[contractimpl]
impl MomentsV2 {
    /// One graduation attempt for a GraduationPending Moment. Anyone may call it. Returns the pool, or the recoverable
    /// failure it recorded; it never reverts on one. `WrongState` unless GraduationPending; `GraduationInvalid` (an
    /// abort) when a result the graduator accepted fails the checks here.
    pub fn graduate(e: Env, nft: Address) -> GraduationOutcome {
        let cfg = storage::config(&e);
        let m = storage::moment(&e, &nft);
        let mut l = storage::ledger(&e, &nft);
        if l.state != State::GraduationPending {
            panic_with_error!(&e, Error::WrongState);
        }
        let pool_coins = pool_coins(&m, &l);
        if pool_coins <= 0 {
            panic_with_error!(&e, Error::SupplyInvariant);
        }
        let meta = NftMetadataClient::new(&e, &nft);
        let a = MomentGradArgs {
            nft: nft.clone(),
            usdc: cfg.usdc.clone(),
            reserve: l.reserve,
            pool_coins,
            name: meta.name(),
            symbol: meta.symbol(),
            expected_coin: m.coin.clone(),
        };

        let this = e.current_contract_address();
        let usdc = TokenClient::new(&e, &cfg.usdc);
        let u0 = usdc.balance(&this);
        // The graduator pulls the reserve inside its frame; this authorizes exactly that transfer and nothing else.
        e.authorize_as_current_contract(vec![
            &e,
            InvokerContractAuthEntry::Contract(SubContractInvocation {
                context: ContractContext {
                    contract: cfg.usdc.clone(),
                    fn_name: symbol_short!("transfer"),
                    args: (this.clone(), cfg.graduator.clone(), l.reserve).into_val(&e),
                },
                sub_invocations: Vec::new(&e),
            }),
        ]);
        let now = e.ledger().timestamp();
        let r = match GraduatorClient::new(&e, &cfg.graduator).try_graduate(&a) {
            Ok(Ok(r)) => r,
            // The frame committed but its result doesn't decode: nothing of it can be trusted.
            Ok(Err(_)) => panic_with_error!(&e, Error::GraduationInvalid),
            Err(err) => {
                // Recoverable: the graduator's frame (pull, coin deployment, pool) was rolled back.
                let f = grad_failure(err);
                if l.stuck_since == 0 {
                    l.stuck_since = now;
                }
                storage::save_ledger(&e, &nft, &l, &cfg.ttl);
                GraduationFailed { nft, origin: f.origin, code: f.code, stuck_since: l.stuck_since }.publish(&e);
                return GraduationOutcome::Failed(f);
            }
        };
        if !result_ok(&e, &cfg, &a, &r, u0 - usdc.balance(&this)) {
            panic_with_error!(&e, Error::GraduationInvalid);
        }

        l.state = State::Graduated;
        l.stuck_since = 0;
        l.graduated_at = now;
        l.ended_at = now;
        l.reserve = 0;
        // At most 1 bp of the reserve that the pool didn't take.
        l.treasury_claimable += r.usdc_returned;
        l.pool = Some(r.pool.clone());
        l.liquidity = r.liquidity;
        storage::save_ledger(&e, &nft, &l, &cfg.ttl);
        MomentNftClient::new(&e, &nft).close();
        LockerClient::new(&e, &cfg.locker).register(
            &this,
            &r.pool,
            &VenueKind::Soroswap,
            &r.lp_token,
            &r.liquidity,
            &r.coin,
            &cfg.usdc,
            &PositionRef::Moment(nft.clone()),
            &MOMENT_HARVEST_BPS,
        );
        GraduationSucceeded {
            nft,
            coin: r.coin,
            pool: r.pool.clone(),
            lp_token: r.lp_token,
            liquidity: r.liquidity,
            pool_coins,
            coin_used: r.coin_used,
            usdc_used: r.usdc_used,
            usdc_returned: r.usdc_returned,
        }
        .publish(&e);
        GraduationOutcome::Graduated(r.pool)
    }

    /// The payees of a graduated Moment's harvests, for the locker: `{quote: [creator 4000, platform 6000], base: []}`.
    /// `WrongReference` for a launch's reference (launchpad-v2 answers those), `WrongState` before graduation.
    pub fn harvest_payees(e: Env, reference: PositionRef) -> HarvestPayees {
        let nft = match reference {
            PositionRef::Moment(nft) => nft,
            PositionRef::Launch(_) => panic_with_error!(&e, Error::WrongReference),
        };
        let m = storage::moment(&e, &nft);
        if storage::ledger(&e, &nft).state != State::Graduated {
            panic_with_error!(&e, Error::WrongState);
        }
        HarvestPayees {
            quote: vec![
                &e,
                Payee { to: m.creator, bps: MOMENT_HARVEST_CREATOR_BPS, notify: false },
                Payee { to: m.platform, bps: BPS - MOMENT_HARVEST_CREATOR_BPS, notify: false },
            ],
            // Empty: the locker burns the coin side.
            base: Vec::new(&e),
        }
    }
}
