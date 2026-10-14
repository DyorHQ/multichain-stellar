//! TTL helpers (DESIGN-stellar-contracts-v2 §13). Instances and code are kept alive by the keeper, never in a
//! user's call (DECISIONS #10); persistent entries are bumped when a call touches them, by the deployment's policy.

use crate::TtlPolicy;
use soroban_sdk::{Env, IntoVal, Val};

/// Ledgers close about every 5 seconds.
pub const LEDGER_SECS: u64 = 5;
pub const DAY_IN_LEDGERS: u32 = 17_280;

/// Testnet and testnet-qa: bump below 7 days, to 30 days (as v1, S:contracts/launchpad/src/lib.rs:33-34).
pub const TESTNET_TTL_POLICY: TtlPolicy = TtlPolicy { threshold: 7 * DAY_IN_LEDGERS, extend_to: 30 * DAY_IN_LEDGERS };

/// A policy is valid when `0 < threshold < extend_to ≤ e.storage().max_ttl()`.
pub fn validate_ttl_policy(e: &Env, p: &TtlPolicy) -> bool {
    p.threshold > 0 && p.threshold < p.extend_to && p.extend_to <= e.storage().max_ttl()
}

/// Extends a persistent entry to `p.extend_to` ledgers when its TTL has fallen below `p.threshold`.
pub fn bump_persistent<K: IntoVal<Env, Val>>(e: &Env, key: &K, p: &TtlPolicy) {
    e.storage().persistent().extend_ttl(key, p.threshold, p.extend_to);
}

/// The number of ledgers that covers `secs` seconds (rounded up), saturating at `u32::MAX`.
pub fn ledgers_for(secs: u64) -> u32 {
    u32::try_from(secs.div_ceil(LEDGER_SECS)).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod test {
    use super::*;
    use soroban_sdk::testutils::storage::Persistent as _;
    use soroban_sdk::testutils::Ledger as _;
    use soroban_sdk::{contract, symbol_short};

    #[contract]
    pub struct Holder;

    #[test]
    fn testnet_policy_is_valid_and_matches_v1() {
        let e = Env::default();
        assert_eq!(TESTNET_TTL_POLICY, TtlPolicy { threshold: 120_960, extend_to: 518_400 });
        assert!(validate_ttl_policy(&e, &TESTNET_TTL_POLICY));
    }

    #[test]
    fn invalid_policies_are_refused() {
        let e = Env::default();
        let max = e.storage().max_ttl();
        assert!(!validate_ttl_policy(&e, &TtlPolicy { threshold: 0, extend_to: 100 }));
        assert!(!validate_ttl_policy(&e, &TtlPolicy { threshold: 100, extend_to: 100 }));
        assert!(!validate_ttl_policy(&e, &TtlPolicy { threshold: 200, extend_to: 100 }));
        assert!(!validate_ttl_policy(&e, &TtlPolicy { threshold: 100, extend_to: max + 1 }));
        assert!(validate_ttl_policy(&e, &TtlPolicy { threshold: 100, extend_to: max }));
    }

    #[test]
    fn bump_persistent_extends_below_the_threshold_only() {
        let e = Env::default();
        let id = e.register(Holder, ());
        let key = symbol_short!("k");
        let initial = e.as_contract(&id, || {
            e.storage().persistent().set(&key, &1u32);
            e.storage().persistent().get_ttl(&key)
        });
        // A fresh entry starts below the threshold.
        let p = TtlPolicy { threshold: initial + 1_000, extend_to: initial + 5_000 };
        e.as_contract(&id, || {
            bump_persistent(&e, &key, &p);
            assert_eq!(e.storage().persistent().get_ttl(&key), p.extend_to);
        });
        e.ledger().with_mut(|l| l.sequence_number += 2_000);
        e.as_contract(&id, || {
            // initial + 3,000 left: above the threshold, so nothing changes.
            bump_persistent(&e, &key, &p);
            assert_eq!(e.storage().persistent().get_ttl(&key), initial + 3_000);
        });
    }

    #[test]
    fn ledgers_for_rounds_up_and_saturates() {
        assert_eq!(ledgers_for(0), 0);
        assert_eq!(ledgers_for(1), 1);
        assert_eq!(ledgers_for(5), 1);
        assert_eq!(ledgers_for(6), 2);
        assert_eq!(ledgers_for(86_400), DAY_IN_LEDGERS);
        assert_eq!(ledgers_for(u64::MAX), u32::MAX);
    }
}
