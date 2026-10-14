//! DyorHQ qa-exec-fail (DESIGN-stellar-contracts-v2 §7.3): testnet-qa's venue that never graduates, with a failure mode
//! per token. Never deployed outside testnet-qa (decision O3); the deploy script refuses it anywhere else.
//!
//! One instance is one venue for launchpad-v2 and the executor of testnet-qa's failing Moments stack, so no venue id is
//! hardcoded anywhere (findings F5, F8). Its callers are launchpad-v2 and that stack's graduator. `graduate` applies
//! the caller rule of every executor (§7) and then fails in the token's mode, `default_mode` while none is set:
//! - `Fail` (0): returns the recoverable error `ForcedFailure` without moving funds; the caller records `grad_fail`;
//! - `ExhaustBudget` (1): loops until the budget runs out, which no `try_` can catch, like a real budget failure;
//! - `BogusSuccess` (2): reports a success without moving funds, its own address as the pool and the LP token, which
//!   the caller's result checks must reject (launchpad-v2's `GraduationInvalid` abort, the graduator's in-frame
//!   `GraduationInvalid`).
//!
//! For a launch the token is the launch token; for a Moment it is the Moment's predicted coin address.
#![no_std]

use dyor_common::{bump_persistent, GraduateArgs, GraduateResult, TAG_QA_EXEC_FAIL, TESTNET_TTL_POLICY};
use soroban_sdk::{contract, contracterror, contractimpl, contracttype, Address, Bytes, Env, Vec};

/// How `graduate` fails for a token. On the wire it is the u32 of §7.3; any other value fails to decode.
#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Mode {
    Fail = 0,
    ExhaustBudget = 1,
    BogusSuccess = 2,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Callers,
    QaAdmin,
    DefaultMode,
    /// A token's mode (persistent).
    Mode(Address),
}

/// On-chain values are `ERR_BASE + 5·100 + n` (§4, finding V10).
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `source` is not one of the callers fixed at construction.
    NotCaller = 10_501,
    /// Mode `Fail`: the recoverable failure the e2e script asks for.
    ForcedFailure = 10_502,
    /// Numbered for §7.3's table. `set_mode` checks the QA admin with `require_auth`, so a call it didn't sign fails
    /// in the host's auth check before this could be raised.
    NotQaAdmin = 10_503,
}
dyor_common::assert_err_codes!(TAG_QA_EXEC_FAIL;
    Error::NotCaller = 1,
    Error::ForcedFailure = 2,
    Error::NotQaAdmin = 3,
);

#[contract]
pub struct QaExecFail;

#[contractimpl]
impl QaExecFail {
    /// `callers` are launchpad-v2 and the failing Moments stack's graduator; `qa_admin` is a throwaway testnet-qa key.
    pub fn __constructor(e: Env, callers: Vec<Address>, qa_admin: Address, default_mode: Mode) {
        e.storage().instance().set(&DataKey::Callers, &callers);
        e.storage().instance().set(&DataKey::QaAdmin, &qa_admin);
        e.storage().instance().set(&DataKey::DefaultMode, &default_mode);
    }

    /// Sets how `graduate` fails for `token`. QA admin only.
    pub fn set_mode(e: Env, token: Address, mode: Mode) {
        let qa_admin: Address = e.storage().instance().get(&DataKey::QaAdmin).unwrap();
        qa_admin.require_auth();
        let key = DataKey::Mode(token);
        e.storage().persistent().set(&key, &mode);
        bump_persistent(&e, &key, &TESTNET_TTL_POLICY);
    }

    /// Never graduates: fails in `a.token`'s mode once the caller rule passes.
    pub fn graduate(e: Env, a: GraduateArgs) -> Result<GraduateResult, Error> {
        let callers: Vec<Address> = e.storage().instance().get(&DataKey::Callers).unwrap();
        if !callers.contains(&a.source) {
            return Err(Error::NotCaller);
        }
        a.source.require_auth();
        match mode(&e, a.token) {
            Mode::Fail => Err(Error::ForcedFailure),
            Mode::ExhaustBudget => {
                // Every host call is metered, so this ends in the budget's ExceededLimit: not recoverable.
                let data = Bytes::new(&e);
                loop {
                    let _ = e.crypto().sha256(&data);
                }
            }
            Mode::BogusSuccess => {
                let this = e.current_contract_address();
                Ok(GraduateResult {
                    pool: this.clone(),
                    lp_token: this,
                    liquidity: a.min_liquidity,
                    token_used: a.token_amount,
                    quote_used: a.quote_amount,
                })
            }
        }
    }

    // -------------------------------------------------------------------------------------------- views

    /// The mode `graduate` uses for `token`: its own, or the default.
    pub fn mode(e: Env, token: Address) -> Mode {
        mode(&e, token)
    }

    pub fn callers(e: Env) -> Vec<Address> {
        e.storage().instance().get(&DataKey::Callers).unwrap()
    }

    pub fn qa_admin(e: Env) -> Address {
        e.storage().instance().get(&DataKey::QaAdmin).unwrap()
    }

    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        TAG_QA_EXEC_FAIL
    }
}

fn mode(e: &Env, token: Address) -> Mode {
    let set = e.storage().persistent().get(&DataKey::Mode(token));
    set.unwrap_or_else(|| e.storage().instance().get(&DataKey::DefaultMode).unwrap())
}

#[cfg(test)]
mod test;
