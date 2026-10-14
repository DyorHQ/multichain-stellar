// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MomentTypes, IMomentsFactory, IMomentCoin, IMomentVesting} from "./interfaces/IMoments.sol";

/// @notice Pull-based coin distribution. During Collecting the collect contract accrues entitlements here (no coin
///         exists yet). The graduation executor activates the schedule; from then on `claim` mints the vested,
///         unclaimed part straight to the caller. Collectors: 60% at graduation, +20% at month 1, +20% at month 2.
///         Creator: 20% at graduation, +16% of the allocation per month for 5 months. Monotonic `claimed`, CEI,
///         and a per-Moment supply check after every mint. Nobody else can mint.
contract MomentVesting is IMomentVesting, ReentrancyGuard {
    uint256 private constant BPS = MomentTypes.BPS;

    IMomentsFactory public immutable factory;

    mapping(uint256 => mapping(address => uint256)) public entitlement; // momentId => account => coins promised
    mapping(uint256 => mapping(address => uint256)) public claimed; // momentId => account => coins minted
    mapping(uint256 => uint256) public totalEntitlement; // Σ entitlements per Moment
    mapping(uint256 => uint256) public creatorClaimed; // creator allocation minted so far
    mapping(uint256 => uint256) public totalMinted; // everything this contract minted for the Moment
    mapping(uint256 => uint64) public graduatedAt; // 0 until graduation

    event Accrued(uint256 indexed momentId, address indexed account, uint256 amount, uint256 total);
    event Activated(uint256 indexed momentId, uint64 at);
    event Claimed(uint256 indexed momentId, address indexed account, uint256 collectorAmount, uint256 creatorAmount);

    error NotCollect();
    error NotGraduation();
    error AlreadyGraduated();
    error NotGraduated();
    error NothingToClaim();
    error SupplyInvariant();
    error ZeroAddress();

    constructor(IMomentsFactory _factory) {
        if (address(_factory) == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    // ------------------------------------------------------------------ writes from the modules

    /// @notice Records coins owed to `account` for a collect. Only while the Moment is still collecting.
    function accrue(uint256 momentId, address account, uint256 amount) external {
        if (msg.sender != factory.collect()) revert NotCollect();
        if (graduatedAt[momentId] != 0) revert AlreadyGraduated();
        entitlement[momentId][account] += amount;
        totalEntitlement[momentId] += amount;
        emit Accrued(momentId, account, amount, totalEntitlement[momentId]);
    }

    /// @notice Starts the vesting clock. Only the graduation executor, once.
    function activate(uint256 momentId) external {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        if (graduatedAt[momentId] != 0) revert AlreadyGraduated();
        graduatedAt[momentId] = uint64(block.timestamp);
        emit Activated(momentId, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------ claims

    function claim(uint256 momentId) external nonReentrant returns (uint256 minted) {
        minted = _claim(momentId, msg.sender);
        if (minted == 0) revert NothingToClaim();
    }

    /// @notice Sweeps every vested tranche across the given Moments in one tx (skips ones with nothing due).
    function claimAll(uint256[] calldata momentIds) external nonReentrant returns (uint256 minted) {
        for (uint256 i = 0; i < momentIds.length; i++) {
            minted += _claim(momentIds[i], msg.sender);
        }
    }

    function _claim(uint256 momentId, address account) private returns (uint256 amount) {
        if (graduatedAt[momentId] == 0) return 0;
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        (uint256 collectorDue, uint256 creatorDue) = _claimable(momentId, account, m);
        amount = collectorDue + creatorDue;
        if (amount == 0) return 0;
        // effects
        claimed[momentId][account] += collectorDue;
        if (creatorDue != 0) creatorClaimed[momentId] += creatorDue;
        totalMinted[momentId] += amount;
        // interaction (our own coin; the only other minter is the graduation executor's pool seed)
        IMomentCoin(m.coin).mint(account, amount);
        // per-Moment supply invariant, asserted after every mint
        if (
            IMomentCoin(m.coin).totalSupply() > MomentTypes.SUPPLY
                || totalMinted[momentId] > totalEntitlement[momentId] + creatorAllocation(momentId)
        ) revert SupplyInvariant();
        emit Claimed(momentId, account, collectorDue, creatorDue);
    }

    // ------------------------------------------------------------------ views

    /// @notice Coins claimable right now: the collector tranche for `account`, plus the creator tranche when
    ///         `account` is the Moment's creator.
    function claimable(uint256 momentId, address account) external view returns (uint256 collectorDue, uint256 creatorDue) {
        if (graduatedAt[momentId] == 0) return (0, 0);
        return _claimable(momentId, account, factory.getMoment(momentId));
    }

    function creatorAllocation(uint256 momentId) public view returns (uint256) {
        return MomentTypes.SUPPLY * factory.getMoment(momentId).creatorAllocBps / BPS;
    }

    /// @notice Vested share of a collector's entitlement, in bps: 6000 at graduation, 8000 after month 1, 10000 after month 2.
    function collectorVestedBps(uint256 momentId) public view returns (uint256) {
        uint64 g = graduatedAt[momentId];
        if (g == 0 || block.timestamp < g) return 0;
        uint256 months = (block.timestamp - g) / MomentTypes.MONTH;
        if (months == 0) return 6_000;
        if (months == 1) return 8_000;
        return BPS;
    }

    /// @notice Vested share of the creator allocation, in bps: 2000 at graduation, +1600 per month, 10000 at month 5.
    function creatorVestedBps(uint256 momentId) public view returns (uint256) {
        uint64 g = graduatedAt[momentId];
        if (g == 0 || block.timestamp < g) return 0;
        uint256 months = (block.timestamp - g) / MomentTypes.MONTH;
        if (months > 5) months = 5;
        return 2_000 + 1_600 * months;
    }

    function _claimable(uint256 momentId, address account, MomentTypes.Moment memory m)
        private
        view
        returns (uint256 collectorDue, uint256 creatorDue)
    {
        uint256 vested = Math.mulDiv(entitlement[momentId][account], collectorVestedBps(momentId), BPS);
        collectorDue = vested - claimed[momentId][account];
        if (account == m.creator) {
            uint256 alloc = MomentTypes.SUPPLY * m.creatorAllocBps / BPS;
            creatorDue = Math.mulDiv(alloc, creatorVestedBps(momentId), BPS) - creatorClaimed[momentId];
        }
    }
}
