//! DyorHQ lp-locker (DESIGN-stellar-contracts-v2 §8): holds every graduated LP position forever and harvests only its
//! fee growth.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-04 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct LpLocker;

#[contractimpl]
impl LpLocker {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_LP_LOCKER
    }
}
