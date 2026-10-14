// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared types and interfaces for Moments. Clean-room: nothing here references the Launchpad.
library MomentTypes {
    /// @dev Basis-point denominator for every split / allocation in Moments.
    uint256 internal constant BPS = 10_000;
    /// @dev Fixed coin supply per Moment: 100,000,000 coins at 18 decimals.
    uint256 internal constant SUPPLY = 100_000_000e18;
    /// @dev A vesting "month" is a fixed 30-day cliff.
    uint256 internal constant MONTH = 30 days;
    /// @dev Upper bound on editions per collect, so one mint cannot run the block dry.
    uint256 internal constant MAX_BATCH = 20;
    /// @dev Hard cap on the creator's coin allocation (10%), regardless of policy.
    uint16 internal constant MAX_CREATOR_ALLOC_BPS = 1_000;
    /// @dev Hard cap on the ERC-2981 creator royalty a policy may set (10%).
    uint16 internal constant MAX_ROYALTY_BPS = 1_000;
    /// @dev Bounds on the creator-chosen collect window. Collecting ends at graduation or at the deadline.
    uint32 internal constant MIN_COLLECT_WINDOW = 1 hours;
    uint32 internal constant MAX_COLLECT_WINDOW = 30 days;
    /// @dev A Moment that completed but whose graduation keeps failing can only be wound down this long after the
    ///      first failure (and never before its deadline), so transient failures always get retried first.
    uint256 internal constant STUCK_GRACE = 7 days;

    enum State {
        Collecting, // NFTs mint, USDC accrues, entitlements accrue; no coin market
        GraduationPending, // reserve reached the threshold; collect path locked; graduation attempted/retriable
        Graduated, // pool live, NFT collection closed, entitlements vesting
        Expired // deadline passed without graduation: NFT closed, reserve wound down to treasury (+ creator share)
    }

    /// @dev Factory policy applied to FUTURE Moments only (snapshotted immutably into each Moment at publish).
    struct Policy {
        uint256 threshold; // USDC (6 dp) the reserve must reach to graduate
        uint256 minPrice; // minimum collect price in USDC (6 dp)
        uint16 creatorBps; // share of each collect to the creator
        uint16 platformBps; // share of each collect to the platform
        uint16 reserveBps; // share of each collect that accrues to the pool reserve
        uint16 maxCreatorAllocBps; // cap on the creator's coin allocation
        uint16 expiryCreatorBps; // share of an EXPIRED Moment's reserve the creator may claim (rest -> treasury)
        uint16 royaltyBps; // ERC-2981 creator royalty suggested to marketplaces for new Moments' NFTs
        address platform; // platform beneficiary for new Moments
        address treasury; // wind-down beneficiary for new Moments
    }

    /// @dev Everything about a Moment that is fixed at publish. Written once by the factory; there is no setter.
    struct Moment {
        address creator; // immutable beneficiary of the creator share + creator coin allocation
        address platform; // immutable beneficiary of the platform share
        address treasury; // immutable beneficiary of an expired reserve
        address coin; // per-Moment ERC-20 (CREATE2)
        address nft; // per-Moment ERC-721 (CREATE2)
        uint256 price; // collect price in USDC (6 dp)
        uint256 threshold; // graduation threshold in USDC (6 dp)
        uint256 rateNum; // entitlement = mulDiv(grossUsdc, rateNum, rateDen)  [coin wei per USDC unit]
        uint256 rateDen;
        uint16 creatorBps;
        uint16 platformBps;
        uint16 reserveBps;
        uint16 creatorAllocBps; // creator coin allocation, <= maxCreatorAllocBps
        uint16 expiryCreatorBps;
        uint16 royaltyBps;
        uint64 publishedAt;
        uint64 deadline; // collecting is possible strictly before this timestamp
    }

    struct Provenance {
        string mediaURI; // content-addressed media (e.g. ipfs://...)
        bytes32 mediaHash; // hash of the media bytes
        string place;
        uint64 date; // unix timestamp of the moment
        string animationURI; // optional content-addressed video/animation (marketplace `animation_url`)
    }
}

interface IMomentsFactory {
    function getMoment(uint256 momentId) external view returns (MomentTypes.Moment memory);
    function momentIdByCoin(address coin) external view returns (uint256);
    function externalBaseURI() external view returns (string memory);
    function momentCount() external view returns (uint256);
    function collect() external view returns (address);
    function vesting() external view returns (address);
    function graduation() external view returns (address);
    function locker() external view returns (address);
    function feeHook() external view returns (address);
    function buyback() external view returns (address);
}

interface IMomentCoin {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function SUPPLY() external view returns (uint256);
}

interface IMomentNFT {
    function mint(address to, uint256 quantity) external returns (uint256 firstRank);
    function close() external;
    function closed() external view returns (bool);
    function totalMinted() external view returns (uint256);
}

interface IMomentVesting {
    function accrue(uint256 momentId, address account, uint256 amount) external;
    function activate(uint256 momentId) external;
    function totalEntitlement(uint256 momentId) external view returns (uint256);
    function graduatedAt(uint256 momentId) external view returns (uint64);
}

interface IMomentCollect {
    function releaseReserve(uint256 momentId, address to) external returns (uint256 amount);
    function markGraduated(uint256 momentId) external;
    function state(uint256 momentId) external view returns (MomentTypes.State);
}

interface IMomentGraduation {
    function graduate(uint256 momentId) external;
}

/// @dev Minimal Permit2 SignatureTransfer surface (Uniswap Permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3).
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
