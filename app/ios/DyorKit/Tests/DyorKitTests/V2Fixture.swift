import BigInt
import Foundation
@testable import DyorKit

/// A made-up v2 deployment for tests. `MomentsAddresses.monadMainnet` and `LaunchpadAddresses.monadMainnet` stay all
/// zero until the owner deploys v2 (`V2WiringTests`), so a test that needs a live v2 stack uses these instead. No
/// address here is a real contract, a retired one, or another fixture's.
enum V2Fixture {
    static let moments = MomentsAddresses(
        factory: Address(literal: "0x00000000000000000000000000000000c4000001"),
        collect: Address(literal: "0x00000000000000000000000000000000c4000002"),
        vesting: Address(literal: "0x00000000000000000000000000000000c4000003"),
        graduation: Address(literal: "0x00000000000000000000000000000000c4000004"),
        locker: Address(literal: "0x00000000000000000000000000000000c4000005"),
        hook: Address(literal: "0x00000000000000000000000000000000c40010cc"),
        buyback: Address(literal: "0x00000000000000000000000000000000c4000007"),
        platform: Address(literal: "0x15ED3bb488231213b141A2f78b62358D52235Cd7"),
        treasury: Address(literal: "0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371"),
        deployBlock: 108_800_000,
        generation: .v2
    )

    static let launchpad = LaunchpadAddresses(
        factory: Address(literal: "0x00000000000000000000000000000000c4f00001"),
        router: Address(literal: "0x00000000000000000000000000000000c4f00002"),
        escrow: Address(literal: "0x00000000000000000000000000000000c4f00003"),
        holderFeeSharing: Address(literal: "0x00000000000000000000000000000000c4f00004"),
        hook: Address(literal: "0x00000000000000000000000000000000c4f000cc"),
        poolManager: Uniswap.poolManager,
        generation: .v2
    )

    /// The v2 policy the owner deploys with (`THRESHOLD_USDC=771428571`, the fees and treasury wallets), under the c4 link
    /// base, and its `termsHash()` (`cast abi-encode "f((uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address),string)" … | cast keccak`).
    static let termsHash = Data(hex: "0x3d9ff80b17a4f23544485081f1d595532c4f1d7932b3deea682e0b1e1fb2fa03")!

    static func policy(threshold: BigUInt = 771_428_571, minPrice: BigUInt = 100_000, royaltyBps: Int = 500, platform: Address? = nil,
                       publishingPaused: Bool = false, guardianPaused: Bool = false, base: String = MomentsAddresses.expectedExternalBaseURI,
                       termsHash: Data? = V2Fixture.termsHash) -> MomentPolicy {
        MomentPolicy(threshold: threshold, minPrice: minPrice, creatorBps: 2_000, platformBps: 500, reserveBps: 7_500, maxCreatorAllocBps: 1_000,
                     expiryCreatorBps: 7_000, royaltyBps: royaltyBps, platform: platform ?? moments.platform, treasury: moments.treasury, momentCount: 0,
                     publishingPaused: publishingPaused, externalBaseURI: base, termsHash: termsHash,
                     guardian: Address(literal: "0x00000000000000000000000000000000000900d1"), guardianPaused: guardianPaused)
    }
}
