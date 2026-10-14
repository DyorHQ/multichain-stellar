//! DyorHQ moments-graduator (DESIGN-stellar-contracts-v2 §12): moments-v2's try_ target: deploys the coin, seeds the
//! Soroswap pool and checks the result in its own frame.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-08 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct MomentsGraduator;

#[contractimpl]
impl MomentsGraduator {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_MOMENTS_GRADUATOR
    }
}
