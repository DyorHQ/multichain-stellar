//! Events (DESIGN-stellar-contracts-v2 §5.6). Topics come first. The indexer lists launches from `launch` events
//! (there is no launch counter, L15) and names a failure's `(origin, code)` from the generated error table (V10).

use crate::storage::Config;
use dyor_common::{VenueKind, VenueParams};
use soroban_sdk::{contractevent, Address, String, Vec};

// ------------------------------------------------------------------------------------------------ launches and trades

#[contractevent(topics = ["launch"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launched {
    #[topic]
    pub token: Address,
    #[topic]
    pub creator: Address,
    pub quote: Address,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub nonce: u64,
    pub supply: i128,
    pub phantom: i128,
    pub threshold: i128,
    pub fee_bps: u32,
    pub protocol_share_bps: u32,
    pub creator_fee_bps: u32,
    // Venue ids.
    pub venue: u32,
    pub fallback_venue: u32,
    pub venue_locked: bool,
    pub holder_sharing: bool,
    pub recipient: Address,
    pub launch_fee: i128,
}

// The launch fee, moved from the creator to the launchpad and booked on the launch (O6).
#[contractevent(topics = ["fee_booked"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchFeeBooked {
    #[topic]
    pub token: Address,
    #[topic]
    pub payer: Address,
    pub asset: Address,
    pub amount: i128,
}

// A buy or a sell. The fees split into `protocol_part` (booked for the treasury), `creator_part` (booked for the
// recipient, sharing off) and `holder_part` (sent to the token for its holders, sharing on).
#[contractevent(topics = ["trade"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Trade {
    #[topic]
    pub token: Address,
    #[topic]
    pub trader: Address,
    pub is_buy: bool,
    // Buy: quote pulled from the buyer. Sell: quote paid to the seller.
    pub quote_amount: i128,
    pub token_amount: i128,
    pub base_fee: i128,
    pub snipe_fee: i128,
    pub creator_fee: i128,
    pub protocol_part: i128,
    pub creator_part: i128,
    pub holder_part: i128,
    pub quote_reserve: i128,
    pub token_reserve: i128,
    pub real_quote: i128,
}

// The curve reached its threshold: buys and sells are closed, and the keeper graduates it (L3).
#[contractevent(topics = ["complete"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Completed {
    #[topic]
    pub token: Address,
    pub real_quote: i128,
    pub completed_at: u64,
}

// ------------------------------------------------------------------------------------------------ graduation

#[contractevent(topics = ["grad_ok"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Graduated {
    #[topic]
    pub token: Address,
    pub venue: u32,
    pub pool: Address,
    pub pool_tokens: i128,
    pub pool_quote: i128,
    pub liquidity: i128,
    pub burned: i128,
    pub fallback: bool,
}

// A recoverable venue failure, decoded with `dyor_common::grad_failure` (V10).
#[contractevent(topics = ["grad_fail"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraduationFailed {
    #[topic]
    pub token: Address,
    pub venue: u32,
    pub origin: u32,
    pub code: u32,
    pub stuck_since: u64,
    pub fallback_at: u64,
}

#[contractevent(topics = ["stuck"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkedStuck {
    #[topic]
    pub token: Address,
    pub stuck_since: u64,
}

// The admin let a venue-locked launch fall back without waiting `locked_fallback`. No data.
#[contractevent(topics = ["fb_allow"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FallbackAllowed {
    #[topic]
    pub token: Address,
}

// ------------------------------------------------------------------------------------------------ rescue

#[contractevent(topics = ["rescued"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Rescued {
    #[topic]
    pub token: Address,
    pub stuck_since: u64,
    pub by_admin: bool,
    pub refund_quote: i128,
    pub refund_supply: i128,
    pub burned: i128,
}

#[contractevent(topics = ["refund"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Refunded {
    #[topic]
    pub token: Address,
    #[topic]
    pub holder: Address,
    pub tokens_in: i128,
    pub quote_out: i128,
}

// ------------------------------------------------------------------------------------------------ fees

#[contractevent(topics = ["cr_claim"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreatorFeesClaimed {
    #[topic]
    pub token: Address,
    #[topic]
    pub recipient: Address,
    pub amount: i128,
}

// Fees booked before a recipient change, kept for the old recipient (L14).
#[contractevent(topics = ["cr_owed"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreatorFeesOwed {
    #[topic]
    pub token: Address,
    #[topic]
    pub old_recipient: Address,
    pub amount: i128,
}

#[contractevent(topics = ["owed_claim"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwedClaimed {
    #[topic]
    pub account: Address,
    #[topic]
    pub asset: Address,
    pub amount: i128,
}

// One launch's booked protocol fees (quote) and launch fee (XLM), swept to `treasury`.
#[contractevent(topics = ["pr_claim"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProtocolFeesClaimed {
    #[topic]
    pub token: Address,
    pub treasury: Address,
    pub quote_amount: i128,
    pub launch_fee_amount: i128,
}

// ------------------------------------------------------------------------------------------------ creator fee recipient

#[contractevent(topics = ["recip_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecipientSet {
    #[topic]
    pub token: Address,
    pub old: Address,
    pub new: Address,
    pub by_takeover: bool,
}

#[contractevent(topics = ["recip_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecipientProposed {
    #[topic]
    pub token: Address,
    pub new: Address,
    pub effective_at: u64,
    pub expires_at: u64,
}

#[contractevent(topics = ["recip_cncl"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecipientChangeCancelled {
    #[topic]
    pub token: Address,
    pub by: Address,
}

// ------------------------------------------------------------------------------------------------ admin and guardian

// The role changes below carry only the new value: the old one is in the previous event or `config`.
#[contractevent(topics = ["admin_prop"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminProposed {
    pub proposed: Address,
}

#[contractevent(topics = ["admin_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminSet {
    pub new: Address,
}

// The guardian started handing its role to `new`, who must accept it.
#[contractevent(topics = ["guard_hand"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianHandoffStarted {
    pub new: Address,
}

#[contractevent(topics = ["guard_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianProposed {
    pub new: Option<Address>,
    pub eta: u64,
    pub expires: u64,
}

// The guardian changed: accepted handoff, renounce (`None`) or the admin's applied replacement.
#[contractevent(topics = ["guard_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianSet {
    pub new: Option<Address>,
}

#[contractevent(topics = ["guard_cncl"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuardianProposalCancelled {
    pub new: Option<Address>,
}

#[contractevent(topics = ["treas_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TreasuryProposed {
    pub new: Address,
    pub eta: u64,
    pub expires: u64,
}

#[contractevent(topics = ["treas_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TreasurySet {
    pub new: Address,
}

#[contractevent(topics = ["treas_cncl"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TreasuryProposalCancelled {
    pub new: Address,
    pub by: Address,
}

#[contractevent(topics = ["fee_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchFeeSet {
    pub launch_fee: i128,
}

#[contractevent(topics = ["config_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigSet {
    pub config: Config,
}

#[contractevent(topics = ["quote_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuoteSet {
    #[topic]
    pub quote: Address,
    pub phantom: i128,
    pub threshold: i128,
    pub enabled: bool,
    pub venues_allowed: Vec<u32>,
    pub fallback_venue: u32,
}

#[contractevent(topics = ["venue_prop"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueProposed {
    #[topic]
    pub id: u32,
    pub kind: VenueKind,
    pub executor: Address,
    pub params: VenueParams,
    pub eta: u64,
    pub expires: u64,
}

// A proposed venue joined the table, disabled for future launches until `set_venue_enabled`.
#[contractevent(topics = ["venue_set"])]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueAdded {
    #[topic]
    pub id: u32,
    pub kind: VenueKind,
    pub executor: Address,
    pub params: VenueParams,
}

#[contractevent(topics = ["venue_cncl"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueProposalCancelled {
    #[topic]
    pub id: u32,
    pub by: Address,
}

#[contractevent(topics = ["venue_on"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VenueEnabled {
    #[topic]
    pub id: u32,
    pub enabled: bool,
}

#[contractevent(topics = ["wl_set"], data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WhitelistSet {
    #[topic]
    pub account: Address,
    pub whitelisted: bool,
}
