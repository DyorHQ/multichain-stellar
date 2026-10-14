//! The transfer lock (DESIGN-stellar-contracts-v2 §6.1, L4) and the token-account rule (F1).
//!
//! Until `unlock`, a transfer succeeds only when `from == launchpad`, `from ∈ lock_from` (this launch's venue and
//! fallback executors, fixed at construction) or `to == launchpad`; a muxed `to` is checked by its address. Burns are
//! always allowed. Together with the executors' caller allowlists this keeps every pool empty of launch tokens until
//! graduation (S:docs/DECISIONS.md #5): only launchpad-v2 and moments-graduator can make an executor act.
//!
//! The token's own address holds the launch-token rewards (§6.2). At any time, before and after unlock, nothing may
//! transfer, burn or approve from it; only `claim` and `sweep_protocol` pay out of it, through the reward hook.

use crate::{DataKey, Error};
use soroban_sdk::{panic_with_error, Address, Env, Vec};

/// Refuses a transfer of `from`'s tokens to `to` that the lock or the token-account rule forbids.
pub(crate) fn check_transfer(e: &Env, from: &Address, to: &Address) {
    check_not_token_account(e, from);
    if unlocked(e) {
        return;
    }
    let launchpad: Address = e.storage().instance().get(&DataKey::Launchpad).unwrap();
    if *from != launchpad && *to != launchpad && !lock_from(e).contains(from) {
        panic_with_error!(e, Error::TransferLocked);
    }
}

/// Refuses any spending from the token's own address.
pub(crate) fn check_not_token_account(e: &Env, from: &Address) {
    if *from == e.current_contract_address() {
        panic_with_error!(e, Error::TokenAccount);
    }
}

pub(crate) fn unlocked(e: &Env) -> bool {
    e.storage().instance().get(&DataKey::Unlocked).unwrap_or(false)
}

pub(crate) fn lock_from(e: &Env) -> Vec<Address> {
    e.storage().instance().get(&DataKey::LockFrom).unwrap()
}
