//! DyorHQ launch-token-v2 (DESIGN-stellar-contracts-v2 §6): one SEP-41 token per launch, with the transfer lock, opt-in
//! holder rewards in two assets and pool exclusion.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-01 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct LaunchTokenV2;

#[contractimpl]
impl LaunchTokenV2 {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_LAUNCH_TOKEN_V2
    }
}
