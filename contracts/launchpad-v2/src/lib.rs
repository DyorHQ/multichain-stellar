//! DyorHQ launchpad-v2 (DESIGN-stellar-contracts-v2 §5): the launch factory: bonding curves, the launch fee, terms, fee
//! booking, guarded graduation with a fallback, stuck, rescue and pro-rata refunds, and the creator fee recipient.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-05 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct LaunchpadV2;

#[contractimpl]
impl LaunchpadV2 {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_LAUNCHPAD_V2
    }
}
