//! DyorHQ moment-coin (DESIGN-stellar-contracts-v2 §11): one capped, burnable SEP-41 coin per graduated Moment.
//!
//! - moments-graduator deploys it at graduation, at an address predicted from the Moment's NFT address (§12), with
//!   moments-v2 as the minter, the cap S (100M coins at 7 decimals) and the pool's coins minted to the graduator.
//! - `mint`: the minter only (moments-v2's vesting claims, §9.2), within the cap.
//! - Holders burn their own coins, or a spender burns them within its allowance (`burn_from`); the locker burns the
//!   coin side of every harvest (§8, §9.1).
//!
//! Built on OpenZeppelin `stellar-tokens` `Base` with the capped and burnable extensions. The cap bounds the supply
//! outstanding: OpenZeppelin's `check_cap` adds the amount to `total_supply`, so a burn frees room under it, and
//! moments-v2's ledger is what bounds the coins ever minted (I-M3). There is no admin, pause, tax or upgrade, and no
//! call extends the instance's TTL (DECISIONS #10): the keeper keeps the instance alive.
#![no_std]

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, panic_with_error, Address, Env, MuxedAddress, String,
};
use stellar_tokens::fungible::{burnable::FungibleBurnable, capped, Base, FungibleToken};

/// Every Moment coin has 7 decimals, like Stellar assets and Stellar USDC (§0 X1).
pub const DECIMALS: u32 = 7;

#[contracttype]
#[derive(Clone)]
enum DataKey {
    // instance
    Minter,
}

/// The local codes of §11 in this contract's namespace: on chain `ERR_BASE + 9·100 + n` (§4, V10). The cap is
/// enforced by OpenZeppelin's `ExceededCap`, which keeps OpenZeppelin's own code (origin 0 if it ever reaches a
/// `try_`).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// Kept so the numbering stays as §11 lists it. `mint` checks the minter's own auth, which fails with the host's
    /// auth error before any contract code could raise this.
    NotMinter = 10_901,
    /// A mint of 0 or less.
    ZeroAmount = 10_902,
}
dyor_common::assert_err_codes!(dyor_common::TAG_MOMENT_COIN; Error::NotMinter = 1, Error::ZeroAmount = 2);

#[contract]
pub struct MomentCoin;

#[contractimpl]
impl MomentCoin {
    /// Records `minter` and the cap, then mints `initial_amount` to `initial_to` within the cap. An initial amount of
    /// 0 mints nothing; a negative one fails `ZeroAmount`, like `mint`. moments-graduator passes
    /// `(moments, name, symbol, S, itself, pool_coins)` (§12).
    pub fn __constructor(
        e: &Env,
        minter: Address,
        name: String,
        symbol: String,
        cap: i128,
        initial_to: Address,
        initial_amount: i128,
    ) {
        Base::set_metadata(e, DECIMALS, name, symbol);
        capped::set_cap(e, cap);
        e.storage().instance().set(&DataKey::Minter, &minter);
        if initial_amount != 0 {
            mint_capped(e, &initial_to, initial_amount);
        }
    }

    /// Mints `amount` to `to`. The minter only, within the cap.
    pub fn mint(e: &Env, to: Address, amount: i128) {
        Self::minter(e).require_auth();
        mint_capped(e, &to, amount);
    }

    // -------------------------------------------------------------------------------------------- views

    /// The only address that can mint: moments-v2.
    pub fn minter(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Minter).unwrap()
    }

    /// The most coins that can be outstanding at once.
    pub fn cap(e: &Env) -> i128 {
        capped::query_cap(e)
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_MOMENT_COIN
    }
}

/// Mints within the cap: a positive amount that keeps `total_supply` at most the cap (OpenZeppelin's `check_cap`,
/// oz:src/fungible/extensions/capped/storage.rs:73-81).
fn mint_capped(e: &Env, to: &Address, amount: i128) {
    if amount <= 0 {
        panic_with_error!(e, Error::ZeroAmount);
    }
    capped::check_cap(e, amount, Base::total_supply(e));
    Base::mint(e, to, amount);
}

// SEP-41 as OpenZeppelin's `Base` implements it: it checks auth, allowance and balance, moves or burns the coins,
// bumps the balance entries and emits the SEP-41 events.
#[contractimpl(contracttrait)]
impl FungibleToken for MomentCoin {
    type ContractType = Base;
}

#[contractimpl(contracttrait)]
impl FungibleBurnable for MomentCoin {}

#[cfg(test)]
mod test;
