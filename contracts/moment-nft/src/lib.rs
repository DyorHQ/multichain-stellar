//! DyorHQ moment-nft (DESIGN-stellar-contracts-v2 §10): one SEP-50 contract per Moment; the edition number is the token
//! id.
//!
//! Skeleton from CT-00, so the workspace, build.sh and the WASM list are complete; CT-06 implements it.
#![no_std]

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct MomentNft;

#[contractimpl]
impl MomentNft {
    /// This contract's error tag: its on-chain error values are `ERR_BASE + tag·100 + n` (§4, finding V10).
    pub fn error_tag() -> u32 {
        dyor_common::TAG_MOMENT_NFT
    }
}
