//! DyorHQ moments-v2 (DESIGN-stellar-contracts-v2 §9): the Moments factory: policy and timelock, publish, collect,
//! keeper graduation, vesting and expiry.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-09 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct MomentsV2;

#[contractimpl]
impl MomentsV2 {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_MOMENTS_V2
    }
}
