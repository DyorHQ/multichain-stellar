//! DyorHQ moment-coin (DESIGN-stellar-contracts-v2 §11): a capped, burnable SEP-41 coin per graduated Moment.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-07 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct MomentCoin;

#[contractimpl]
impl MomentCoin {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_MOMENT_COIN
    }
}
