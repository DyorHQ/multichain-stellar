import Foundation

/// Which DyorHQ contract source a deployed stack runs. `.v1` is every launchpad and Moments cohort deployed up to the
/// 2026-09-23 relaunch (source `3fc1f47` and earlier); `.v2` is the audited release in `contracts/src` that replaces
/// them. A getter that exists only on v2 is sent only to a `.v2` stack: on a v1 contract it reverts, and in a
/// Multicall3 `readAll` one reverted sub-call fails the whole read. The Moments cohorts use it as is; the launchpad splits
/// its v1 stacks further (`LaunchpadAddresses.Generation`: legacy, pre-audit, v1, v2).
public enum ContractGeneration: Int, Sendable, Hashable, Comparable, CustomStringConvertible {
    case v1 = 1
    case v2 = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "v\(rawValue)" }
}
