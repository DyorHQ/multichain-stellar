//! moments-v2's events (DESIGN-stellar-contracts-v2 §9.2, §20.5). Topics come first; the Moment's NFT address is the
//! first topic of every per-Moment event, so the indexer keys Moments by it (L15).

use crate::storage::Policy;
use dyor_common::MomentsDurations;
use soroban_sdk::{contractevent, Address, String, Symbol};

// ------------------------------------------------------------------------------------------------ governance

/// Governance proposed `new` as its successor; `new` must accept.
#[contractevent(topics = ["gov_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GovernanceProposed {
    #[topic]
    pub governance: Address,
    pub new: Address,
}

#[contractevent(topics = ["gov_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GovernanceSet {
    pub old: Address,
    pub new: Address,
}

/// The guardian handed its role on, or renounced it (`new` is `None`).
#[contractevent(topics = ["guard_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianSet {
    pub old: Address,
    pub new: Option<Address>,
}

#[contractevent(topics = ["pol_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PolicyProposed {
    pub policy: Policy,
    pub eta: u64,
    pub expires: u64,
}

/// The policy that Moments published from now on snapshot.
#[contractevent(topics = ["pol_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PolicySet {
    pub policy: Policy,
}

/// `by` (governance or the guardian) cancelled the pending policy.
#[contractevent(topics = ["pol_cncl"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PolicyCancelled {
    pub by: Address,
}

#[contractevent(topics = ["pub_pause"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PublishingPaused {
    pub paused: bool,
}

#[contractevent(topics = ["guard_pause"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianPaused {
    pub paused: bool,
}

/// The external-link base of Moments published from now on.
#[contractevent(topics = ["base_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternalBaseSet {
    pub base: String,
}

// ------------------------------------------------------------------------------------------------ Moments

/// A Moment was published. It carries what the indexer and the app show before the first edition exists
/// (`token_uri` needs one, ruling after CT-06), and the durations its vesting and expiry follow.
#[contractevent(topics = ["publish"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Published {
    #[topic]
    pub nft: Address,
    #[topic]
    pub creator: Address,
    pub nonce: u64,
    pub coin: Address,
    pub name: String,
    pub symbol: String,
    pub metadata_uri: String,
    pub price: i128,
    pub threshold: i128,
    pub creator_alloc_bps: u32,
    pub rate_num: i128,
    pub rate_den: i128,
    pub deadline: u64,
    pub durations: MomentsDurations,
}

/// One collect: `gross` was pulled and split, `editions` minted from `first_rank`, `entitlement` coins promised.
/// `excess` is the part of `price·qty` a terminal collect didn't take (it never left the collector).
#[contractevent(topics = ["collect"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Collected {
    #[topic]
    pub nft: Address,
    #[topic]
    pub collector: Address,
    pub gross: i128,
    pub editions: u32,
    pub first_rank: u32,
    pub entitlement: i128,
    pub reserve_in: i128,
    pub creator_in: i128,
    pub platform_in: i128,
    pub excess: i128,
    /// The reserve after this collect.
    pub reserve: i128,
}

/// The reserve reached the threshold: the Moment waits for graduation (L3).
#[contractevent(topics = ["complete"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Completed {
    #[topic]
    pub nft: Address,
    pub reserve: i128,
    pub total_gross: i128,
    pub completed_at: u64,
}

/// The Moment graduated: the coin, its pool and the LP the locker now holds, with the graduator's accounting.
#[contractevent(topics = ["grad_ok"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraduationSucceeded {
    #[topic]
    pub nft: Address,
    pub coin: Address,
    pub pool: Address,
    pub lp_token: Address,
    pub liquidity: i128,
    pub pool_coins: i128,
    pub coin_used: i128,
    pub usdc_used: i128,
    pub usdc_returned: i128,
}

/// A recoverable graduation failure, recorded: `origin` and `code` as `grad_failure` decodes them (V10), and the
/// stuck clock it started or left running (F15).
#[contractevent(topics = ["grad_fail"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraduationFailed {
    #[topic]
    pub nft: Address,
    pub origin: u32,
    pub code: u32,
    pub stuck_since: u64,
}

/// The Moment was wound down: its reserve split `creator_share` / `treasury_share`. `backstop` is true when it expired
/// through `pending_backstop`, without a recorded failure (V11).
#[contractevent(topics = ["expired"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Expired {
    #[topic]
    pub nft: Address,
    pub reserve: i128,
    pub creator_share: i128,
    pub treasury_share: i128,
    pub backstop: bool,
}

#[contractevent(topics = ["vest_claim"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VestingClaimed {
    #[topic]
    pub nft: Address,
    #[topic]
    pub account: Address,
    pub collector_amount: i128,
    pub creator_amount: i128,
}

/// `amount` USDC paid to `to`, the Moment's snapshotted beneficiary in `role` (`creator`, `platform` or `treasury`).
#[contractevent(topics = ["withdrawn"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Withdrawn {
    #[topic]
    pub nft: Address,
    #[topic]
    pub role: Symbol,
    pub to: Address,
    pub amount: i128,
}
