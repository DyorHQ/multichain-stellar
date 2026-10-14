//! DyorHQ exec-soroswap (DESIGN-stellar-contracts-v2 §7.1): the caller-restricted, stateless Soroswap graduation
//! executor.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-02 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct ExecSoroswap;

#[contractimpl]
impl ExecSoroswap {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_EXEC_SOROSWAP
    }
}
