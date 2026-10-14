// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MomentTypes, IMomentsFactory} from "./interfaces/IMoments.sol";
import {MomentCoin} from "./MomentCoin.sol";
import {MomentNFT} from "./MomentNFT.sol";

/// @notice Publishes Moments and keeps the registry. Each Moment's economics (price, threshold, split, creator
///         allocation, bundle rate, collect deadline, beneficiaries) are snapshotted into an immutable record at
///         publish — there is no function that can change a live Moment. Policy edits only affect Moments published
///         after a 48h timelock. The factory never holds USDC or coins; it has no money path at all.
///
///         v2 (NOT deployed — see DyorHQ/internal: ios-app/contracts/CHANGELOG-v2.md), sec2:
///         - MO-4: `publish` takes the `termsHash()` the creator's app showed and reverts `TermsChanged` if the policy
///           (or the metadata base) changed in between, so applying a matured proposal in front of a publish can no
///           longer change a creator's terms. A proposal lapses if nobody applies it within `POLICY_APPLY_WINDOW` of
///           becoming applicable. A separate `guardian` key can cancel a proposal and pause publishing (a pause only
///           it can lift), so a stolen governance key cannot push a policy through the timelock unnoticed.
///         - MO-8: each Moment's NFT snapshots the external-link base at publish; changing it never touches existing
///           NFTs, and its length is capped.
///         - A listed price above the gross that completes the reserve is refused (it would never be charged).
contract MomentsFactory is IMomentsFactory {
    uint256 public constant POLICY_DELAY = 48 hours;
    /// @dev v2 (sec2, MO-4): a pending policy must be applied within this window after it becomes applicable.
    uint256 public constant POLICY_APPLY_WINDOW = 7 days;
    /// @dev v2 (sec2, MO-8): cap on the external-link base (a huge one would make every tokenURI unreadable).
    uint256 public constant MAX_EXTERNAL_BASE_URI_LENGTH = 256;
    /// @dev Sanity floors for policy values (USDC units): a threshold below 1 USDC or a minimum price below one cent
    ///      would make the graduation math degenerate; real policies are orders of magnitude above these.
    uint256 public constant MIN_THRESHOLD = 1_000_000;
    uint256 public constant MIN_MIN_PRICE = 10_000;

    address public governance;
    address public pendingGovernance;
    /// @notice v2 (sec2, MO-4): a second key that can only cancel a pending policy and pause publishing. Set by
    ///         governance while the modules are being wired; afterwards only the guardian itself can hand it on.
    address public guardian;
    /// @notice v2 (sec2, MO-4): the guardian's pause. Governance cannot lift it.
    bool public guardianPaused;

    // Modules, wired exactly once. Every module reads its peers from here, so nothing can be re-pointed later.
    address public collect;
    address public vesting;
    address public graduation;
    address public locker;
    address public feeHook;
    address public buyback;
    bool public modulesSet;

    MomentTypes.Policy public policy;
    MomentTypes.Policy public pendingPolicy;
    uint64 public pendingPolicyAt; // earliest time the pending policy may be applied (0 = none)

    bool public publishingPaused;
    /// @dev Metadata only: prefix for the NFTs' `external_url` / `external_link` (`<base><momentId>`). No money path.
    string public externalBaseURI;
    uint256 public momentCount; // ids are 1-based
    mapping(uint256 => MomentTypes.Moment) private _moments;
    mapping(address => uint256) public momentIdByCoin;

    struct PublishParams {
        string name;
        string symbol;
        MomentTypes.Provenance provenance;
        uint256 price; // USDC (6 dp), >= policy.minPrice
        uint16 creatorAllocBps; // <= policy.maxCreatorAllocBps
        uint32 collectWindow; // seconds the Moment can be collected for, within [MIN_COLLECT_WINDOW, MAX_COLLECT_WINDOW]
        bytes32 salt;
    }

    event GovernanceTransferStarted(address indexed from, address indexed to);
    event GovernanceTransferred(address indexed from, address indexed to);
    event ModulesSet(address collect, address vesting, address graduation, address locker, address feeHook, address buyback);
    event PolicyProposed(MomentTypes.Policy policy, uint64 applicableAt);
    event PolicyApplied(MomentTypes.Policy policy);
    event PolicyCancelled();
    event PublishingPaused(bool paused);
    event GuardianSet(address indexed guardian);
    event GuardianPaused(bool paused);
    event ExternalBaseURISet(string base);
    event Published(
        uint256 indexed momentId,
        address indexed creator,
        address coin,
        address nft,
        uint256 price,
        uint16 creatorAllocBps,
        uint256 rateNum,
        uint256 rateDen,
        uint64 deadline
    );

    error NotGovernance();
    error NotPendingGovernance();
    error ModulesAlreadySet();
    error ModulesNotSet();
    error ZeroAddress();
    error InvalidPolicy();
    error NoPendingPolicy();
    error TimelockNotElapsed();
    error Paused();
    error NotGuardian();
    error NotGovernanceOrGuardian();
    error UnpauseFirst();
    error PolicyLapsed();
    error TermsChanged();
    error BaseURITooLong();
    error PriceTooHigh();
    error PriceTooLow();
    error AllocTooHigh();
    error BadWindow();
    error UnknownMoment();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(address _governance, MomentTypes.Policy memory initial) {
        if (_governance == address(0)) revert ZeroAddress();
        _validate(initial);
        governance = _governance;
        policy = initial;
        emit GovernanceTransferred(address(0), _governance);
    }

    // ------------------------------------------------------------------ governance

    function transferGovernance(address to) external onlyGovernance {
        pendingGovernance = to;
        emit GovernanceTransferStarted(governance, to);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotPendingGovernance();
        emit GovernanceTransferred(governance, msg.sender);
        governance = msg.sender;
        pendingGovernance = address(0);
    }

    /// @notice v2 (sec2, MO-4): names the guardian. Governance can do this only while wiring (before `setModules`);
    ///         after that only the current guardian can hand the role on (or renounce it with address(0)). Renouncing
    ///         is refused while the guardian's pause is on (`UnpauseFirst`): nobody could ever lift it afterwards.
    ///         Nobody can replace a lost guardian key either; that means a new cohort.
    function setGuardian(address _guardian) external {
        bool wiring = !modulesSet && msg.sender == governance;
        bool handOn = guardian != address(0) && msg.sender == guardian;
        if (!wiring && !handOn) revert NotGuardian();
        if (_guardian == address(0) && guardianPaused) revert UnpauseFirst();
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    /// @notice Wires the modules exactly once. After this nothing about the wiring can change.
    function setModules(address _collect, address _vesting, address _graduation, address _locker, address _feeHook, address _buyback)
        external
        onlyGovernance
    {
        if (modulesSet) revert ModulesAlreadySet();
        if (
            _collect == address(0) || _vesting == address(0) || _graduation == address(0) || _locker == address(0)
                || _feeHook == address(0) || _buyback == address(0)
        ) revert ZeroAddress();
        collect = _collect;
        vesting = _vesting;
        graduation = _graduation;
        locker = _locker;
        feeHook = _feeHook;
        buyback = _buyback;
        modulesSet = true;
        emit ModulesSet(_collect, _vesting, _graduation, _locker, _feeHook, _buyback);
    }

    /// @notice Queues a policy for FUTURE Moments (threshold, split, min price, alloc cap, beneficiaries, expiry share).
    function proposePolicy(MomentTypes.Policy calldata next) external onlyGovernance {
        _validate(next);
        pendingPolicy = next;
        pendingPolicyAt = uint64(block.timestamp + POLICY_DELAY);
        emit PolicyProposed(next, pendingPolicyAt);
    }

    /// @notice Anyone may apply a matured proposal. v2 (sec2, MO-4): only within `POLICY_APPLY_WINDOW` of it becoming
    ///         applicable; a forgotten proposal lapses instead of staying applicable forever.
    function applyPolicy() external {
        if (pendingPolicyAt == 0) revert NoPendingPolicy();
        if (block.timestamp < pendingPolicyAt) revert TimelockNotElapsed();
        if (block.timestamp > uint256(pendingPolicyAt) + POLICY_APPLY_WINDOW) revert PolicyLapsed();
        policy = pendingPolicy;
        delete pendingPolicy;
        pendingPolicyAt = 0;
        emit PolicyApplied(policy);
    }

    /// @notice Governance, or (v2, sec2) the guardian, cancels a pending proposal.
    function cancelPolicy() external {
        if (msg.sender != governance && msg.sender != guardian) revert NotGovernanceOrGuardian();
        delete pendingPolicy;
        pendingPolicyAt = 0;
        emit PolicyCancelled();
    }

    function setPublishingPaused(bool paused) external onlyGovernance {
        publishingPaused = paused;
        emit PublishingPaused(paused);
    }

    /// @notice v2 (sec2, MO-4): the guardian's own pause switch; publishing stops while either pause is on.
    function setGuardianPaused(bool paused) external {
        if (msg.sender != guardian || guardian == address(0)) revert NotGuardian();
        guardianPaused = paused;
        emit GuardianPaused(paused);
    }

    /// @notice Sets the metadata-only base for the external links of Moments published from now on (e.g.
    ///         https://dyorhq.fun/moments/). v2 (sec2, MO-8): existing NFTs keep the base they were published with.
    function setExternalBaseURI(string calldata base) external onlyGovernance {
        if (bytes(base).length > MAX_EXTERNAL_BASE_URI_LENGTH) revert BaseURITooLong();
        externalBaseURI = base;
        emit ExternalBaseURISet(base);
    }

    // ------------------------------------------------------------------ publishing

    /// @notice The terms a Moment published now would snapshot: the policy and the external-link base. v2 (sec2, MO-4):
    ///         an app shows the creator `policy()` and passes this hash to `publish`.
    function termsHash() public view returns (bytes32) {
        return keccak256(abi.encode(policy, externalBaseURI));
    }

    /// @notice Publishes a Moment: deploys its coin + NFT (CREATE2) and freezes its economics and deadline.
    ///         v2 (sec2, MO-4): reverts `TermsChanged` unless `expectedTermsHash == termsHash()`, i.e. unless the terms
    ///         are the ones the creator was shown.
    function publish(PublishParams calldata p, bytes32 expectedTermsHash) external returns (uint256 momentId, address coin, address nft) {
        if (!modulesSet) revert ModulesNotSet();
        if (publishingPaused || guardianPaused) revert Paused();
        if (expectedTermsHash != termsHash()) revert TermsChanged();
        MomentTypes.Policy memory pol = policy;
        if (p.price < pol.minPrice) revert PriceTooLow();
        // v2 (sec2): at or above this gross the first collect completes the reserve and is clamped to it, so a higher
        // listed price would never be charged (a 1/1 listed at $5,000 would sell for the completion gross).
        if (p.price > Math.ceilDiv(pol.threshold * MomentTypes.BPS, pol.reserveBps)) revert PriceTooHigh();
        if (p.creatorAllocBps > pol.maxCreatorAllocBps) revert AllocTooHigh();
        if (p.collectWindow < MomentTypes.MIN_COLLECT_WINDOW || p.collectWindow > MomentTypes.MAX_COLLECT_WINDOW) revert BadWindow();

        momentId = ++momentCount;
        bytes32 salt = keccak256(abi.encode(momentId, msg.sender, p.salt));
        coin = address(new MomentCoin{salt: salt}(momentId, p.name, p.symbol, vesting, graduation));
        nft = address(new MomentNFT{salt: salt}(momentId, p.name, p.symbol, msg.sender, collect, graduation, pol.royaltyBps, p.provenance, externalBaseURI));
        (uint256 rateNum, uint256 rateDen) = bundleRate(pol.threshold, pol.reserveBps, p.creatorAllocBps);
        uint64 deadline = uint64(block.timestamp + p.collectWindow);

        _moments[momentId] = MomentTypes.Moment({
            creator: msg.sender,
            platform: pol.platform,
            treasury: pol.treasury,
            coin: coin,
            nft: nft,
            price: p.price,
            threshold: pol.threshold,
            rateNum: rateNum,
            rateDen: rateDen,
            creatorBps: pol.creatorBps,
            platformBps: pol.platformBps,
            reserveBps: pol.reserveBps,
            creatorAllocBps: p.creatorAllocBps,
            expiryCreatorBps: pol.expiryCreatorBps,
            royaltyBps: pol.royaltyBps,
            publishedAt: uint64(block.timestamp),
            deadline: deadline
        });
        momentIdByCoin[coin] = momentId;
        emit Published(momentId, msg.sender, coin, nft, p.price, p.creatorAllocBps, rateNum, rateDen, deadline);
    }

    /// @notice The price-continuous bundle rate, as an exact fraction of coin wei per USDC unit:
    ///         rate = S·(1−alloc) / (threshold/reserveFrac + threshold)
    ///              = S·(BPS−allocBps)·reserveBps / (BPS·threshold·(BPS+reserveBps)).
    ///         Deriving it from the ACTUAL creator allocation is what routes an un-taken allocation into the pool.
    function bundleRate(uint256 threshold, uint16 reserveBps, uint16 creatorAllocBps) public pure returns (uint256 num, uint256 den) {
        num = MomentTypes.SUPPLY * (MomentTypes.BPS - creatorAllocBps) * reserveBps;
        den = MomentTypes.BPS * threshold * (MomentTypes.BPS + reserveBps);
    }

    // ------------------------------------------------------------------ views

    function getMoment(uint256 momentId) external view returns (MomentTypes.Moment memory m) {
        m = _moments[momentId];
        if (m.coin == address(0)) revert UnknownMoment();
    }

    function _validate(MomentTypes.Policy memory pol) private pure {
        if (pol.platform == address(0) || pol.treasury == address(0)) revert ZeroAddress();
        if (pol.threshold < MIN_THRESHOLD || pol.minPrice < MIN_MIN_PRICE || pol.reserveBps == 0) revert InvalidPolicy();
        if (uint256(pol.creatorBps) + pol.platformBps + pol.reserveBps != MomentTypes.BPS) revert InvalidPolicy();
        // v2 (sec2): `publish` refuses prices above the completion gross, so a minimum above it would refuse them all.
        if (pol.minPrice > Math.ceilDiv(pol.threshold * MomentTypes.BPS, pol.reserveBps)) revert InvalidPolicy();
        if (pol.maxCreatorAllocBps > MomentTypes.MAX_CREATOR_ALLOC_BPS) revert InvalidPolicy();
        if (pol.expiryCreatorBps > MomentTypes.BPS) revert InvalidPolicy();
        if (pol.royaltyBps > MomentTypes.MAX_ROYALTY_BPS) revert InvalidPolicy();
    }
}
