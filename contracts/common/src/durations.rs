//! Duration bounds, the production and testnet-qa duration sets, and the rules both constructors check
//! (DESIGN-stellar-contracts-v2 §4, §14.3). The contracts accept any valid set; the deploy script refuses anything
//! but the production set outside testnet-qa (§17).

use crate::{LaunchDurations, MomentsDurations};

const MINUTE: u64 = 60;
const HOUR: u64 = 60 * MINUTE;
const DAY: u64 = 24 * HOUR;

/// Shortest duration any set may hold.
pub const MIN_DURATION: u64 = MINUTE;
/// Longest duration any set may hold.
pub const MAX_DURATION: u64 = 400 * DAY;
/// Longest harvest interval (the locker checks its own interval with the same bounds).
pub const MAX_HARVEST_INTERVAL: u64 = DAY;

/// The owner's testnet now, mainnet as planned (§14.3).
pub const PRODUCTION_LAUNCH_DURATIONS: LaunchDurations = LaunchDurations {
    grace: HOUR,
    fallback_delay: HOUR,
    rescue_admin: 7 * DAY,
    rescue_public: 30 * DAY,
    locked_fallback: DAY,
    takeover_delay: 3 * DAY,
    takeover_window: 3 * DAY,
    timelock: 48 * HOUR,
    timelock_window: 7 * DAY,
    harvest_interval: HOUR,
};

/// The owner's testnet now, mainnet as planned (§14.3).
pub const PRODUCTION_MOMENTS_DURATIONS: MomentsDurations = MomentsDurations {
    vest_period: 30 * DAY,
    stuck_expiry: 7 * DAY,
    pending_backstop: 30 * DAY,
    timelock: 48 * HOUR,
    timelock_window: 7 * DAY,
    min_window: HOUR,
    max_window: 30 * DAY,
    harvest_interval: HOUR,
};

/// testnet-qa only (O3): the same WASM with every path reachable within minutes (§14.3).
pub const TESTNET_QA_LAUNCH_DURATIONS: LaunchDurations = LaunchDurations {
    grace: MINUTE,
    fallback_delay: MINUTE,
    rescue_admin: 5 * MINUTE,
    rescue_public: 15 * MINUTE,
    locked_fallback: 2 * MINUTE,
    takeover_delay: 2 * MINUTE,
    takeover_window: 5 * MINUTE,
    timelock: 2 * MINUTE,
    timelock_window: 10 * MINUTE,
    harvest_interval: MINUTE,
};

/// testnet-qa only (O3, §14.3).
pub const TESTNET_QA_MOMENTS_DURATIONS: MomentsDurations = MomentsDurations {
    vest_period: 10 * MINUTE,
    stuck_expiry: 5 * MINUTE,
    pending_backstop: 30 * MINUTE,
    timelock: 2 * MINUTE,
    timelock_window: 10 * MINUTE,
    min_window: 2 * MINUTE,
    max_window: 30 * DAY,
    harvest_interval: MINUTE,
};

/// The rule a duration set breaks. Contracts report any of them as their own `InvalidConfig`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DurationError {
    /// A value outside [`MIN_DURATION`, `MAX_DURATION`].
    OutOfRange,
    /// `harvest_interval > MAX_HARVEST_INTERVAL`.
    HarvestIntervalTooLong,
    /// `rescue_public < rescue_admin`.
    PublicRescueBeforeAdmin,
    /// `grace > rescue_admin`.
    GraceAfterRescue,
    /// `fallback_delay > rescue_admin`.
    FallbackDelayAfterRescue,
    /// `locked_fallback > rescue_admin`.
    LockedFallbackAfterRescue,
    /// `min_window > max_window`.
    WindowBounds,
    /// `pending_backstop < 4 · stuck_expiry` (V11).
    BackstopTooShort,
}

/// True when `secs` is a valid harvest interval: within [`MIN_DURATION`, `MAX_HARVEST_INTERVAL`]. The locker checks
/// its constructor argument with this.
pub fn harvest_interval_ok(secs: u64) -> bool {
    (MIN_DURATION..=MAX_HARVEST_INTERVAL).contains(&secs)
}

/// The launch rules of §4: every value within the bounds, `harvest_interval ≤ MAX_HARVEST_INTERVAL`,
/// `rescue_public ≥ rescue_admin`, and `grace`, `fallback_delay` and `locked_fallback` each at most `rescue_admin`.
pub fn validate_launch_durations(d: &LaunchDurations) -> Result<(), DurationError> {
    let all = [
        d.grace,
        d.fallback_delay,
        d.rescue_admin,
        d.rescue_public,
        d.locked_fallback,
        d.takeover_delay,
        d.takeover_window,
        d.timelock,
        d.timelock_window,
        d.harvest_interval,
    ];
    check_range(&all)?;
    if !harvest_interval_ok(d.harvest_interval) {
        return Err(DurationError::HarvestIntervalTooLong);
    }
    if d.rescue_public < d.rescue_admin {
        return Err(DurationError::PublicRescueBeforeAdmin);
    }
    if d.grace > d.rescue_admin {
        return Err(DurationError::GraceAfterRescue);
    }
    if d.fallback_delay > d.rescue_admin {
        return Err(DurationError::FallbackDelayAfterRescue);
    }
    if d.locked_fallback > d.rescue_admin {
        return Err(DurationError::LockedFallbackAfterRescue);
    }
    Ok(())
}

/// The Moments rules of §4: every value within the bounds, `harvest_interval ≤ MAX_HARVEST_INTERVAL`,
/// `min_window ≤ max_window`, and `pending_backstop ≥ 4 · stuck_expiry` so the backstop lies far beyond the
/// recorded-failure expiry (V11).
pub fn validate_moments_durations(d: &MomentsDurations) -> Result<(), DurationError> {
    let all = [
        d.vest_period,
        d.stuck_expiry,
        d.pending_backstop,
        d.timelock,
        d.timelock_window,
        d.min_window,
        d.max_window,
        d.harvest_interval,
    ];
    check_range(&all)?;
    if !harvest_interval_ok(d.harvest_interval) {
        return Err(DurationError::HarvestIntervalTooLong);
    }
    if d.min_window > d.max_window {
        return Err(DurationError::WindowBounds);
    }
    // Both are at most MAX_DURATION here, so 4 · stuck_expiry can't overflow.
    if d.pending_backstop < 4 * d.stuck_expiry {
        return Err(DurationError::BackstopTooShort);
    }
    Ok(())
}

fn check_range(values: &[u64]) -> Result<(), DurationError> {
    if values.iter().all(|v| (MIN_DURATION..=MAX_DURATION).contains(v)) {
        Ok(())
    } else {
        Err(DurationError::OutOfRange)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use DurationError as E;

    type Edit<T> = fn(&mut T);

    fn launch_with(edit: Edit<LaunchDurations>) -> Result<(), DurationError> {
        let mut d = PRODUCTION_LAUNCH_DURATIONS;
        edit(&mut d);
        validate_launch_durations(&d)
    }

    fn moments_with(edit: Edit<MomentsDurations>) -> Result<(), DurationError> {
        let mut d = PRODUCTION_MOMENTS_DURATIONS;
        edit(&mut d);
        validate_moments_durations(&d)
    }

    #[test]
    fn production_and_testnet_qa_sets_are_valid() {
        assert_eq!(validate_launch_durations(&PRODUCTION_LAUNCH_DURATIONS), Ok(()));
        assert_eq!(validate_launch_durations(&TESTNET_QA_LAUNCH_DURATIONS), Ok(()));
        assert_eq!(validate_moments_durations(&PRODUCTION_MOMENTS_DURATIONS), Ok(()));
        assert_eq!(validate_moments_durations(&TESTNET_QA_MOMENTS_DURATIONS), Ok(()));
    }

    #[test]
    fn sets_match_spec_14_3() {
        let p = PRODUCTION_LAUNCH_DURATIONS;
        assert_eq!(
            [p.grace, p.fallback_delay, p.rescue_admin, p.rescue_public, p.locked_fallback],
            [3_600, 3_600, 604_800, 2_592_000, 86_400]
        );
        assert_eq!(
            [p.takeover_delay, p.takeover_window, p.timelock, p.timelock_window, p.harvest_interval],
            [259_200, 259_200, 172_800, 604_800, 3_600]
        );
        let q = TESTNET_QA_LAUNCH_DURATIONS;
        assert_eq!(
            [q.grace, q.fallback_delay, q.rescue_admin, q.rescue_public, q.locked_fallback],
            [60, 60, 300, 900, 120]
        );
        assert_eq!(
            [q.takeover_delay, q.takeover_window, q.timelock, q.timelock_window, q.harvest_interval],
            [120, 300, 120, 600, 60]
        );

        let m = PRODUCTION_MOMENTS_DURATIONS;
        assert_eq!([m.vest_period, m.stuck_expiry, m.pending_backstop], [2_592_000, 604_800, 2_592_000]);
        assert_eq!(
            [m.timelock, m.timelock_window, m.min_window, m.max_window, m.harvest_interval],
            [172_800, 604_800, 3_600, 2_592_000, 3_600]
        );
        let n = TESTNET_QA_MOMENTS_DURATIONS;
        assert_eq!([n.vest_period, n.stuck_expiry, n.pending_backstop], [600, 300, 1_800]);
        assert_eq!(
            [n.timelock, n.timelock_window, n.min_window, n.max_window, n.harvest_interval],
            [120, 600, 120, 2_592_000, 60]
        );
    }

    #[test]
    fn both_sets_carry_harvest_interval_and_moments_carry_the_backstop() {
        assert_eq!(PRODUCTION_LAUNCH_DURATIONS.harvest_interval, PRODUCTION_MOMENTS_DURATIONS.harvest_interval);
        assert_eq!(TESTNET_QA_LAUNCH_DURATIONS.harvest_interval, TESTNET_QA_MOMENTS_DURATIONS.harvest_interval);
        assert_eq!(PRODUCTION_MOMENTS_DURATIONS.pending_backstop, 30 * DAY);
        assert_eq!(TESTNET_QA_MOMENTS_DURATIONS.pending_backstop, 30 * MINUTE);
    }

    #[test]
    fn every_launch_value_is_bounded() {
        let edits: [Edit<LaunchDurations>; 10] = [
            |d| d.grace = 0,
            |d| d.fallback_delay = 0,
            |d| d.rescue_admin = 0,
            |d| d.rescue_public = 0,
            |d| d.locked_fallback = 0,
            |d| d.takeover_delay = 0,
            |d| d.takeover_window = 0,
            |d| d.timelock = 0,
            |d| d.timelock_window = 0,
            |d| d.harvest_interval = 0,
        ];
        for edit in edits {
            assert_eq!(launch_with(edit), Err(E::OutOfRange));
        }
        assert_eq!(launch_with(|d| d.grace = MIN_DURATION - 1), Err(E::OutOfRange));
        assert_eq!(launch_with(|d| d.grace = MIN_DURATION), Ok(()));
        assert_eq!(launch_with(|d| d.takeover_window = MAX_DURATION + 1), Err(E::OutOfRange));
        assert_eq!(launch_with(|d| d.takeover_window = MAX_DURATION), Ok(()));
        assert_eq!(
            launch_with(|d| {
                d.rescue_admin = MAX_DURATION;
                d.rescue_public = MAX_DURATION + 1;
            }),
            Err(E::OutOfRange)
        );
    }

    #[test]
    fn every_moments_value_is_bounded() {
        let edits: [Edit<MomentsDurations>; 8] = [
            |d| d.vest_period = 59,
            |d| d.stuck_expiry = 59,
            |d| d.pending_backstop = 59,
            |d| d.timelock = 59,
            |d| d.timelock_window = 59,
            |d| d.min_window = 59,
            |d| d.max_window = 59,
            |d| d.harvest_interval = 59,
        ];
        for edit in edits {
            assert_eq!(moments_with(edit), Err(E::OutOfRange));
        }
        assert_eq!(moments_with(|d| d.vest_period = MAX_DURATION + 1), Err(E::OutOfRange));
        assert_eq!(moments_with(|d| d.max_window = MAX_DURATION), Ok(()));
    }

    #[test]
    fn harvest_interval_at_most_a_day() {
        assert_eq!(launch_with(|d| d.harvest_interval = MAX_HARVEST_INTERVAL), Ok(()));
        assert_eq!(launch_with(|d| d.harvest_interval = MAX_HARVEST_INTERVAL + 1), Err(E::HarvestIntervalTooLong));
        assert_eq!(moments_with(|d| d.harvest_interval = MAX_HARVEST_INTERVAL), Ok(()));
        assert_eq!(moments_with(|d| d.harvest_interval = MAX_HARVEST_INTERVAL + 1), Err(E::HarvestIntervalTooLong));
        assert!(harvest_interval_ok(MIN_DURATION) && harvest_interval_ok(MAX_HARVEST_INTERVAL));
        assert!(!harvest_interval_ok(MIN_DURATION - 1) && !harvest_interval_ok(MAX_HARVEST_INTERVAL + 1));
    }

    #[test]
    fn launch_ordering_rules() {
        assert_eq!(launch_with(|d| d.rescue_public = d.rescue_admin), Ok(()));
        assert_eq!(launch_with(|d| d.rescue_public = d.rescue_admin - 1), Err(E::PublicRescueBeforeAdmin));
        assert_eq!(launch_with(|d| d.grace = d.rescue_admin), Ok(()));
        assert_eq!(launch_with(|d| d.grace = d.rescue_admin + 1), Err(E::GraceAfterRescue));
        assert_eq!(launch_with(|d| d.fallback_delay = d.rescue_admin), Ok(()));
        assert_eq!(launch_with(|d| d.fallback_delay = d.rescue_admin + 1), Err(E::FallbackDelayAfterRescue));
        assert_eq!(launch_with(|d| d.locked_fallback = d.rescue_admin), Ok(()));
        assert_eq!(launch_with(|d| d.locked_fallback = d.rescue_admin + 1), Err(E::LockedFallbackAfterRescue));
    }

    #[test]
    fn moments_ordering_rules() {
        assert_eq!(moments_with(|d| d.min_window = d.max_window), Ok(()));
        assert_eq!(moments_with(|d| d.min_window = d.max_window + 1), Err(E::WindowBounds));
        assert_eq!(moments_with(|d| d.pending_backstop = 4 * d.stuck_expiry), Ok(()));
        assert_eq!(moments_with(|d| d.pending_backstop = 4 * d.stuck_expiry - 1), Err(E::BackstopTooShort));
        let mut qa = TESTNET_QA_MOMENTS_DURATIONS;
        qa.pending_backstop = 4 * qa.stuck_expiry - 1;
        assert_eq!(validate_moments_durations(&qa), Err(E::BackstopTooShort));
    }
}
