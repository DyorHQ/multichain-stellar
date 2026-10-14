//! Aquarius router and pool client traits (DESIGN-stellar-contracts-v2 §7.2), and CT-03's go/no-go gate.
//!
//! Every function declared here was run against the testnet WASM fixtures in `contracts/testdata` (the router
//! `CBCFTQ…6GD`, version 220, the standard pool and the share token it deploys; ids, hashes and notes in
//! `fixtures.json`) by exec-aquarius's tests. Nothing else of Aquarius's interface is relied on.
//!
//! - Amounts are `u128`. Token sets are passed sorted ascending by address; the router refuses any other order
//!   (`TokensNotSorted`, 2002).
//! - A standard (constant-product) pool is keyed by its token set and a pool index that depends only on the fee tier
//!   ([`standard_pool_index`]).
//! - The pool holds the reserves; its liquidity is a separate share token (`share_id`) whose supply is the pool's
//!   `get_total_shares` (the share token itself has no `total_supply`).
//! - Auth trees, as the fixtures record them for a `user` that calls the router:
//!   - `init_standard_pool(user, tokens, fee)` → `payment_token.transfer(user, payment_address, amount)` when the
//!     pool is new and the payment is above 0; an existing pool is returned as it is, with no payment;
//!   - `deposit(user, tokens, index, desired, min_shares)` → `pool.deposit(user, desired, min_shares)` →
//!     `tokens[i].transfer(user, pool, amount_i)`; no transfer back to `user`;
//!   - `withdraw(user, tokens, index, shares, min_amounts)` → `pool.withdraw(user, shares, min_amounts)` →
//!     `share_token.burn(user, shares)`.
//!
//!   A contract that calls the router itself is authorized for that call; it pre-authorizes the deeper nodes with
//!   `authorize_as_current_contract`, exactly as above.
//!
//! The router's pool-creation event is `["add_pool", tokens]` with data `[pool, "constant", pool_index,
//! [fee_fraction]]` for a standard pool (CT-15's pool discovery).

use soroban_sdk::{contractclient, xdr::ToXdr, Address, Bytes, BytesN, Env, Map, Symbol, Vec};

/// Gate check 4 (the router's pool lookup for a token pair, the pool's token list and `share_id`) passed.
/// launch-token-v2's `exclude_pool` handles Aquarius pools only when this is true.
pub const AQUARIUS_POOL_LOOKUP_OK: bool = true;

/// All five gate checks passed: Aquarius may be a graduation venue, and lp-locker harvests Aquarius positions.
pub const AQUARIUS_VENUE_OK: bool = true;

/// The router's standard-pool fee tiers, in basis points: 0.1%, 0.3% and 1%. Testnet uses 30 (L2).
pub const AQUARIUS_FEE_TIERS: [u32; 3] = [10, 30, 100];

/// The router's index of the standard pool with `fee_fraction`, the same for every token set:
/// `sha256(xdr(Symbol "standard") ‖ xdr(Symbol "0x00") ‖ xdr(u32 fee_fraction) ‖ xdr(Symbol "0x00"))`. Checked
/// against `init_standard_pool`'s result and against the testnet router for 10, 30 and 100.
pub fn standard_pool_index(e: &Env, fee_fraction: u32) -> BytesN<32> {
    let separator = Symbol::new(e, "0x00").to_xdr(e);
    let mut salt = Bytes::new(e);
    salt.append(&Symbol::new(e, "standard").to_xdr(e));
    salt.append(&separator);
    salt.append(&fee_fraction.to_xdr(e));
    salt.append(&separator);
    e.crypto().sha256(&salt).into()
}

/// `a` and `b` in the order the router expects.
pub fn sorted_pair(e: &Env, a: &Address, b: &Address) -> Vec<Address> {
    if a < b {
        Vec::from_array(e, [a.clone(), b.clone()])
    } else {
        Vec::from_array(e, [b.clone(), a.clone()])
    }
}

/// The Aquarius liquidity-pool router. Its functions panic with its own error codes (none in 10_100–11_099); a
/// plain call traps on them.
#[contractclient(name = "AquariusRouterClient")]
pub trait AquariusRouter {
    /// The asset a new pool's creation payment is taken in (testnet: AQUA).
    fn get_init_pool_payment_token(e: Env) -> Address;
    /// Where `init_standard_pool` sends the payment.
    fn get_init_pool_payment_address(e: Env) -> Address;
    /// The payment for a new standard pool (testnet: 10,000,000, which is 1 AQUA).
    fn get_standard_pool_payment_amount(e: Env) -> u128;
    /// Creates the standard pool of `tokens` with `fee_fraction` (10, 30 or 100, else `BadFee`, 302), paid by `user`,
    /// or returns the existing one without payment. Returns `(pool_index, pool)`.
    fn init_standard_pool(e: Env, user: Address, tokens: Vec<Address>, fee_fraction: u32) -> (BytesN<32>, Address);
    /// Deposits up to `desired_amounts` (in `tokens` order) from `user` and mints at least `min_shares` share tokens
    /// to `user`. Returns `(amounts taken, shares minted)`; an empty pool takes the desired amounts exactly.
    fn deposit(
        e: Env,
        user: Address,
        tokens: Vec<Address>,
        pool_index: BytesN<32>,
        desired_amounts: Vec<u128>,
        min_shares: u128,
    ) -> (Vec<u128>, u128);
    /// Burns `share_amount` of `user`'s share tokens and pays out the pro-rata reserves (in `tokens` order), at least
    /// `min_amounts`. Returns the amounts paid.
    fn withdraw(
        e: Env,
        user: Address,
        tokens: Vec<Address>,
        pool_index: BytesN<32>,
        share_amount: u128,
        min_amounts: Vec<u128>,
    ) -> Vec<u128>;
    /// Every pool of a token set, by pool index (standard, stable and concentrated). Empty for a token set the router
    /// has never seen.
    fn get_pools(e: Env, tokens: Vec<Address>) -> Map<BytesN<32>, Address>;
    /// The pool's total shares (the same as the pool's own `get_total_shares`).
    fn get_total_shares(e: Env, tokens: Vec<Address>, pool_index: BytesN<32>) -> u128;
}

/// An Aquarius standard pool, read directly.
#[contractclient(name = "AquariusPoolClient")]
pub trait AquariusPool {
    /// The pool's token set, sorted as the router passes it.
    fn get_tokens(e: Env) -> Vec<Address>;
    /// The pool's share token (a separate contract). Its supply is `get_total_shares`.
    fn share_id(e: Env) -> Address;
    fn get_total_shares(e: Env) -> u128;
    /// The reserves in `get_tokens` order; the pool's own balances of the tokens hold them.
    fn get_reserves(e: Env) -> Vec<u128>;
}
