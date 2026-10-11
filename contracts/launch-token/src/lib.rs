//! DyorHQ launch token (SEP-41).
//!
//! One instance per launch, deployed by the launchpad. The whole fixed supply is minted to the launchpad at
//! construction. Until the launchpad graduates the launch (`unlock`), every transfer must have the launchpad on one
//! side: tokens can only be bought from and sold to the bonding curve. Nobody can seed a DEX pool at a skewed price
//! before graduation, and nothing can block graduation by pre-seeding the pair.
//!
//! Built on OpenZeppelin `stellar-tokens` (`Base` storage + burnable extension).
#![no_std]

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, Address, Env,
    MuxedAddress, String,
};
use stellar_tokens::fungible::{burnable::FungibleBurnable, Base, FungibleToken};

/// Every launch token has 7 decimals, like Stellar assets.
pub const DECIMALS: u32 = 7;

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Launchpad,
    Unlocked,
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum LaunchTokenError {
    /// A transfer between two holders before graduation.
    TransferLocked = 1,
    /// `unlock` called twice.
    AlreadyUnlocked = 2,
    /// Supply must be positive.
    InvalidSupply = 3,
}

/// Emitted once, when the launchpad graduates the launch and transfers open.
#[contractevent(topics = ["unlocked"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Unlocked {
    pub launchpad: Address,
}

#[contract]
pub struct LaunchToken;

#[contractimpl]
impl LaunchToken {
    /// Mints `supply` to `launchpad` and records it as the only party allowed to move tokens before graduation.
    pub fn __constructor(e: &Env, launchpad: Address, name: String, symbol: String, supply: i128) {
        if supply <= 0 {
            panic_with_error!(e, LaunchTokenError::InvalidSupply);
        }
        Base::set_metadata(e, DECIMALS, name, symbol);
        e.storage().instance().set(&DataKey::Launchpad, &launchpad);
        e.storage().instance().set(&DataKey::Unlocked, &false);
        Base::mint(e, &launchpad, supply);
    }

    /// The launchpad that deployed this token.
    pub fn launchpad(e: &Env) -> Address {
        e.storage().instance().get(&DataKey::Launchpad).unwrap()
    }

    /// Whether holder-to-holder transfers are open (true after graduation).
    pub fn unlocked(e: &Env) -> bool {
        e.storage().instance().get(&DataKey::Unlocked).unwrap_or(false)
    }

    /// Opens transfers for everyone. Only the launchpad, once, at graduation.
    pub fn unlock(e: &Env) {
        let launchpad = Self::launchpad(e);
        launchpad.require_auth();
        if Self::unlocked(e) {
            panic_with_error!(e, LaunchTokenError::AlreadyUnlocked);
        }
        e.storage().instance().set(&DataKey::Unlocked, &true);
        Unlocked { launchpad }.publish(e);
    }
}

fn ensure_transferable(e: &Env, from: &Address, to: &Address) {
    if LaunchToken::unlocked(e) {
        return;
    }
    let launchpad = LaunchToken::launchpad(e);
    if *from != launchpad && *to != launchpad {
        panic_with_error!(e, LaunchTokenError::TransferLocked);
    }
}

#[contractimpl(contracttrait)]
impl FungibleToken for LaunchToken {
    type ContractType = Base;

    fn transfer(e: &Env, from: Address, to: MuxedAddress, amount: i128) {
        ensure_transferable(e, &from, &to.address());
        Base::transfer(e, &from, &to, amount);
    }

    fn transfer_from(e: &Env, spender: Address, from: Address, to: Address, amount: i128) {
        ensure_transferable(e, &from, &to);
        Base::transfer_from(e, &spender, &from, &to, amount);
    }
}

#[contractimpl(contracttrait)]
impl FungibleBurnable for LaunchToken {}

#[cfg(test)]
mod test;
