//! DyorHQ qa-exec-fail (DESIGN-stellar-contracts-v2 §7.3): testnet-qa's venue that never graduates, with a failure mode
//! per token. Never deployed outside testnet-qa.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-02 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct QaExecFail;

#[contractimpl]
impl QaExecFail {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_QA_EXEC_FAIL
    }
}
