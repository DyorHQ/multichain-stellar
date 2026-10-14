//! DyorHQ exec-aquarius (DESIGN-stellar-contracts-v2 §7.2): the caller-restricted Aquarius graduation executor, paid
//! from its AQUA float (only if CT-03's gate says go).
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-03 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct ExecAquarius;

#[contractimpl]
impl ExecAquarius {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_EXEC_AQUARIUS
    }
}
