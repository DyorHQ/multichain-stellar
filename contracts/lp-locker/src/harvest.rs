//! The harvest of §8.2: reading a position's pool, the fee-growth maths, the withdrawal from the venue and the
//! payouts.
//!
//! A position's value is its share of the pool's √k: `isqrt(r_b·r_q)·lp/total`, in the same units as its principal.
//! Swaps never lower √k (the fee stays in the reserves) and withdrawals round in the pool's favour, so the value of
//! the locked LP only grows while nobody harvests; what lies above the principal is fee growth (or a donation). One
//! round takes `min(growth·hb/BPS, current·MAX_HARVEST_ROUND_BPS/BPS)` and burns the LP worth at most that.

use crate::{credit_owed, Position};
use dyor_common::aquarius::{sorted_pair, AquariusPoolClient, AquariusRouterClient};
use dyor_common::{
    isqrt_u128, mul_div, mul_div_u256, HarvestOwnerClient, LaunchTokenV2Client, Payee, SoroswapPairClient, VenueKind,
    BPS, MAX_HARVEST_ROUND_BPS,
};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{symbol_short, token::TokenClient, vec, Address, Env, IntoVal, Symbol, Vec, U256};

/// Kinds whose pools the locker can value: constant-product pools with readable reserves and LP supply.
pub(crate) fn valued(kind: VenueKind) -> bool {
    matches!(kind, VenueKind::Soroswap | VenueKind::Aquarius)
}

/// Kinds the locker harvests: Soroswap, and Aquarius when CT-03's gate passed (`AQUARIUS_VENUE_OK`) and the locker
/// knows the router. `HoldOnly` and `QaFail` positions are held, never harvested.
pub fn harvestable_kind(kind: VenueKind, aquarius_venue_ok: bool, has_router: bool) -> bool {
    match kind {
        VenueKind::Soroswap => true,
        VenueKind::Aquarius => aquarius_venue_ok && has_router,
        VenueKind::HoldOnly | VenueKind::QaFail => false,
    }
}

/// A pool as one call reads it.
pub(crate) struct PoolState {
    pub base_reserve: i128,
    pub quote_reserve: i128,
    /// The pool's LP supply (Soroswap's `total_supply`, Aquarius's `get_total_shares`).
    pub total: i128,
    /// floor(√(base_reserve·quote_reserve)).
    pub root: i128,
    /// Whether the venue lists `base` first (Soroswap's `token_0`; Aquarius sorts by address).
    pub base_first: bool,
}

/// One round's figures, as `harvest` would run it now.
pub(crate) struct Round {
    /// The position's value.
    pub current: i128,
    /// `current − principal`, or 0.
    pub growth: i128,
    pub take: i128,
    /// 0 when nothing can be harvested.
    pub lp_to_burn: i128,
    pub est_base: i128,
    pub est_quote: i128,
}

/// Reads the reserves (as base, quote) and the LP supply of a Soroswap or Aquarius position's pool.
pub(crate) fn read_pool(e: &Env, pos: &Position, pool: &Address) -> PoolState {
    let (first, second, total, base_first) = match pos.kind {
        VenueKind::Soroswap => {
            let pair = SoroswapPairClient::new(e, pool);
            let (r0, r1) = pair.get_reserves();
            (r0, r1, pair.total_supply(), pair.token_0() == pos.base)
        }
        _ => {
            let pool = AquariusPoolClient::new(e, pool);
            let reserves = pool.get_reserves();
            let first = to_i128(reserves.get_unchecked(0));
            (first, to_i128(reserves.get_unchecked(1)), to_i128(pool.get_total_shares()), pos.base < pos.quote)
        }
    };
    let (base_reserve, quote_reserve) = if base_first { (first, second) } else { (second, first) };
    PoolState { base_reserve, quote_reserve, total, root: sqrt_product(e, first, second), base_first }
}

impl PoolState {
    /// The √k value of `lp` units of this pool's LP.
    pub fn value(&self, e: &Env, lp: i128) -> i128 {
        if self.total == 0 {
            0
        } else {
            mul_div_u256(e, self.root, lp, self.total)
        }
    }

    pub fn round(&self, e: &Env, pos: &Position) -> Round {
        let current = self.value(e, pos.lp);
        let growth = current - pos.principal;
        let mut r = Round { current, growth: growth.max(0), take: 0, lp_to_burn: 0, est_base: 0, est_quote: 0 };
        if growth <= 0 {
            return r;
        }
        r.take = mul_div_u256(e, growth, pos.harvest_bps as i128, BPS as i128).min(mul_div_u256(
            e,
            current,
            MAX_HARVEST_ROUND_BPS as i128,
            BPS as i128,
        ));
        // The spec's `take·total/isqrt(r_b·r_q)`, divided by isqrt + 1 instead: that exceeds √k, so the value the LP
        // burned carries, lp_to_burn·√k/total, never exceeds `take` and what stays covers the new principal (I-K1).
        let lp_to_burn = mul_div_u256(e, r.take, self.total, self.root + 1);
        let est_base = mul_div_u256(e, lp_to_burn, self.base_reserve, self.total);
        let est_quote = mul_div_u256(e, lp_to_burn, self.quote_reserve, self.total);
        // Both venues refuse a withdrawal that pays nothing on one side.
        if est_base > 0 && est_quote > 0 {
            (r.lp_to_burn, r.est_base, r.est_quote) = (lp_to_burn, est_base, est_quote);
        }
        r
    }

    /// Withdraws `lp` LP of `pool` back to the locker. Returns `(base_out, quote_out)`.
    pub fn withdraw(&self, e: &Env, pos: &Position, pool: &Address, router: Option<Address>, lp: i128) -> (i128, i128) {
        let this = e.current_contract_address();
        let (first, second) = match pos.kind {
            // UniswapV2's burn: the LP goes into the pair, `withdraw` pays out what it is worth (no auth).
            VenueKind::Soroswap => {
                TokenClient::new(e, &pos.lp_token).transfer(&this, pool, &lp);
                SoroswapPairClient::new(e, pool).withdraw(&this)
            }
            // CT-03's check 5: the router's withdraw by share amount, which calls `pool.withdraw(this, shares, min)`
            // and that burns the shares. The locker calls the router itself and pre-authorizes exactly those two.
            _ => {
                let router = AquariusRouterClient::new(e, &router.unwrap());
                let tokens = sorted_pair(e, &pos.base, &pos.quote);
                let (index, _) = router.get_pools(&tokens).iter().find(|(_, p)| p == pool).expect("pool unknown");
                let shares = lp as u128;
                let min_amounts = vec![e, 0u128, 0u128];
                e.authorize_as_current_contract(vec![
                    e,
                    InvokerContractAuthEntry::Contract(SubContractInvocation {
                        context: ContractContext {
                            contract: pool.clone(),
                            fn_name: Symbol::new(e, "withdraw"),
                            args: (this.clone(), shares, min_amounts.clone()).into_val(e),
                        },
                        sub_invocations: vec![
                            e,
                            InvokerContractAuthEntry::Contract(SubContractInvocation {
                                context: ContractContext {
                                    contract: pos.lp_token.clone(),
                                    fn_name: symbol_short!("burn"),
                                    args: (this.clone(), lp).into_val(e),
                                },
                                sub_invocations: Vec::new(e),
                            }),
                        ],
                    }),
                ]);
                let out = router.withdraw(&this, &tokens, &index, &shares, &min_amounts);
                (to_i128(out.get_unchecked(0)), to_i128(out.get_unchecked(1)))
            }
        };
        if self.base_first {
            (first, second)
        } else {
            (second, first)
        }
    }
}

/// Pays a round out by the owner's payee lists, read now, so a treasury or recipient change applies from the next
/// harvest. A launch token on the base side first excludes the current treasury from its holder rewards, before the
/// treasury receives launch tokens (V2); the owner's `harvest_payees` has returned by then, so nothing re-enters it.
pub(crate) fn pay(e: &Env, pos: &Position, base_out: i128, quote_out: i128) {
    let payees = HarvestOwnerClient::new(e, &pos.owner).harvest_payees(&pos.reference);
    for p in payees.base.iter() {
        if p.notify {
            LaunchTokenV2Client::new(e, &p.to).exclude_treasury();
        }
    }
    pay_side(e, &pos.quote, quote_out, &payees.quote);
    pay_side(e, &pos.base, base_out, &payees.base);
}

/// Splits `amount` of `asset` by bps, the last payee taking the remainder, and skips zero shares (B13c). A notify
/// payee (a launch token) receives its share and queues it for its holders; another payee that can't receive (no
/// trustline) is owed it. An empty list burns the side.
pub(crate) fn pay_side(e: &Env, asset: &Address, amount: i128, payees: &Vec<Payee>) {
    if amount == 0 {
        return;
    }
    let this = e.current_contract_address();
    let token = TokenClient::new(e, asset);
    if payees.is_empty() {
        token.burn(&this, &amount);
        return;
    }
    let last = payees.len() - 1;
    let mut left = amount;
    for (i, p) in payees.iter().enumerate() {
        let x = if i as u32 == last { left } else { mul_div(amount, p.bps as i128, BPS as i128).min(left) };
        left -= x;
        if x == 0 {
            continue;
        }
        if p.notify {
            token.transfer(&this, &p.to, &x);
            LaunchTokenV2Client::new(e, &p.to).notify_reward(&this, asset, &x);
        } else if token.try_transfer(&this, &p.to, &x).is_err() {
            credit_owed(e, &p.to, asset, x);
        }
    }
}

/// floor(√(x·y)) for reserves `x, y ≥ 0`, exact: when the product exceeds u128 it is formed in U256 and Newton's
/// method runs there, from (isqrt(x) + 1)·(isqrt(y) + 1), which lies above the root.
pub(crate) fn sqrt_product(e: &Env, x: i128, y: i128) -> i128 {
    let (x, y) = (u128::try_from(x).expect("negative reserve"), u128::try_from(y).expect("negative reserve"));
    if let Some(n) = x.checked_mul(y) {
        return isqrt_u128(n) as i128;
    }
    // x, y < 2^127, so each root plus one is at most 2^63.5 + 1 and their product fits u128.
    let n = U256::from_u128(e, x).mul(&U256::from_u128(e, y));
    let mut r = U256::from_u128(e, (isqrt_u128(x) + 1) * (isqrt_u128(y) + 1));
    loop {
        let next = r.add(&n.div(&r)).shr(1);
        if next >= r {
            // floor(√n) < 2^127.
            return r.to_u128().unwrap() as i128;
        }
        r = next;
    }
}

fn to_i128(v: u128) -> i128 {
    i128::try_from(v).expect("amount exceeds i128")
}
