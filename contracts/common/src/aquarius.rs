//! Aquarius router and pool client traits (DESIGN-stellar-contracts-v2 §7.2).
//!
//! A stub from CT-00. CT-03 owns this file: it adds `#[contractclient]` traits for exactly the router and pool
//! functions it confirms against the WASM fixtures, and sets each flag below from the go/no-go gate.

/// Gate check 4 (the router's pool lookup for a token pair, the pool's token list and `share_id`) passed.
/// launch-token-v2's `exclude_pool` handles Aquarius pools only when this is true.
pub const AQUARIUS_POOL_LOOKUP_OK: bool = false;

/// All five gate checks passed: Aquarius may be a graduation venue, and lp-locker harvests Aquarius positions.
pub const AQUARIUS_VENUE_OK: bool = false;
