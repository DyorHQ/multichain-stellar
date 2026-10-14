// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    MomentTypes, IMomentsFactory, IMomentNFT, IMomentVesting, IMomentCollect, IMomentGraduation, IPermit2
} from "./interfaces/IMoments.sol";

/// @notice The collect action and the USDC ledger of every Moment. A collect pays `price × quantity` USDC (via
///         `approve` or a Permit2 signature transfer), which is split creator / platform / reserve; the collector
///         receives NFT editions now and a coin entitlement (recorded in MomentVesting) for later. The collect
///         that would push the reserve past the threshold is clamped so the reserve lands EXACTLY on it: only the
///         accepted amount is pulled from the collector — nothing is ever sent back, the excess simply never leaves
///         their wallet — and graduation is attempted in an isolated subcall.
///
///         Collecting ends at graduation or at the creator-set deadline, whichever comes first. A Moment whose
///         deadline passes without graduation is wound down by `expire`: the NFT collection closes, no coin is ever
///         minted, and the reserve becomes claimable by the treasury with the policy's creator share carved out.
///
///         Every payout is pull-only by an immutable beneficiary; the reserve can only leave to the graduation
///         executor (seed) or, after expiry, to treasury/creator. There is no owner and no admin path.
contract MomentCollect is IMomentCollect, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = MomentTypes.BPS;
    /// @dev Gas reserved for the graduation subcall so a completing collect can never leave it starved.
    uint256 public constant GRADUATION_GAS = 3_000_000;

    IERC20 public immutable USDC;
    IPermit2 public immutable PERMIT2;
    IMomentsFactory public immutable factory;
    IMomentVesting public immutable vesting;

    struct Ledger {
        MomentTypes.State state;
        uint64 completedAt; // when the reserve reached the threshold
        uint64 stuckSince; // first failed graduation attempt (never reset by retries)
        uint64 endedAt; // graduation or expiry time
        uint256 reserve; // USDC held for the pool seed
        uint256 creatorClaimable; // USDC owed to the creator (pull)
        uint256 platformClaimable; // USDC owed to the platform (pull)
        uint256 treasuryClaimable; // USDC owed to the treasury after expiry (pull)
        uint256 totalGross; // USDC accepted so far
        uint256 collects; // number of collect calls
    }

    struct Quote {
        uint256 gross; // USDC accepted (after the terminal clamp)
        uint256 editions; // NFTs minted
        uint256 entitlement; // coin wei owed
        uint256 reserveIn;
        uint256 creatorIn;
        uint256 platformIn;
        uint256 excess; // USDC of the request that is NOT pulled (terminal clamp only); never a transfer
        bool terminal; // this collect completes the Moment
    }

    mapping(uint256 => Ledger) private _ledgers;

    event Collected(uint256 indexed momentId, address indexed collector, uint256 gross, uint256 editions, uint256 firstRank, uint256 entitlement, uint256 reserveIn, uint256 creatorIn, uint256 platformIn, uint256 excess);
    event Completed(uint256 indexed momentId, uint256 reserve, uint256 totalGross);
    event GraduationFailed(uint256 indexed momentId);
    event Graduated(uint256 indexed momentId);
    event Expired(uint256 indexed momentId, uint256 reserve, uint256 creatorShare, uint256 treasuryShare);
    event Withdrawn(uint256 indexed momentId, address indexed beneficiary, uint256 amount);
    event ReserveReleased(uint256 indexed momentId, address indexed to, uint256 amount);

    error NotCollecting();
    error CollectWindowClosed();
    error BadQuantity();
    error WrongToken();
    error NotGraduation();
    error WrongState();
    error NotExpirable();
    error NotBeneficiary();
    error NothingToWithdraw();
    error InsufficientGasForGraduation();
    error ZeroAddress();

    constructor(IERC20 _usdc, IPermit2 _permit2, IMomentsFactory _factory, IMomentVesting _vesting) {
        if (address(_usdc) == address(0) || address(_permit2) == address(0) || address(_factory) == address(0) || address(_vesting) == address(0)) {
            revert ZeroAddress();
        }
        USDC = _usdc;
        PERMIT2 = _permit2;
        factory = _factory;
        vesting = _vesting;
    }

    // ------------------------------------------------------------------ collect

    /// @notice Collect `quantity` editions paying with a prior `USDC.approve(this, …)`.
    function collect(uint256 momentId, uint256 quantity) external nonReentrant returns (Quote memory q) {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        q = _prepare(momentId, m, quantity);
        _book(momentId, q);
        USDC.safeTransferFrom(msg.sender, address(this), q.gross);
        _deliver(momentId, m, q);
    }

    /// @notice Collect paying with a Permit2 signature transfer (no prior approval of this contract needed).
    ///         Only the accepted amount is requested from the permit; the rest stays with the collector.
    function collectWithPermit2(uint256 momentId, uint256 quantity, IPermit2.PermitTransferFrom calldata permit, bytes calldata signature)
        external
        nonReentrant
        returns (Quote memory q)
    {
        if (permit.permitted.token != address(USDC)) revert WrongToken();
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        q = _prepare(momentId, m, quantity);
        _book(momentId, q);
        PERMIT2.permitTransferFrom(permit, IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: q.gross}), msg.sender, signature);
        _deliver(momentId, m, q);
    }

    /// @notice Previews a collect exactly as it would settle.
    function quote(uint256 momentId, uint256 quantity) external view returns (Quote memory) {
        return _prepare(momentId, factory.getMoment(momentId), quantity);
    }

    function _prepare(uint256 momentId, MomentTypes.Moment memory m, uint256 quantity) private view returns (Quote memory q) {
        Ledger storage l = _ledgers[momentId];
        if (l.state != MomentTypes.State.Collecting) revert NotCollecting();
        if (block.timestamp >= m.deadline) revert CollectWindowClosed();
        if (quantity == 0 || quantity > MomentTypes.MAX_BATCH) revert BadQuantity();

        uint256 requested = m.price * quantity;
        uint256 remaining = m.threshold - l.reserve; // > 0 while Collecting
        q.gross = requested;
        q.editions = quantity;
        q.reserveIn = requested * m.reserveBps / BPS;
        if (q.reserveIn >= remaining) {
            // Terminal collect: accept the smallest gross whose reserve share lands EXACTLY on the threshold.
            // gross = ceil(remaining·BPS/reserveBps) ⇒ floor(gross·reserveBps/BPS) == remaining.
            q.terminal = true;
            q.gross = Math.ceilDiv(remaining * BPS, m.reserveBps);
            q.reserveIn = q.gross * m.reserveBps / BPS;
            q.editions = Math.ceilDiv(q.gross, m.price); // paid editions only (≤ quantity)
            q.excess = requested - q.gross; // stays in the collector's wallet
        }
        q.platformIn = q.gross * m.platformBps / BPS;
        q.creatorIn = q.gross - q.reserveIn - q.platformIn; // creator absorbs the ≤2-unit split rounding
        q.entitlement = Math.mulDiv(q.gross, m.rateNum, m.rateDen);
    }

    /// @dev Effects before interactions: book the money first, then pull it, then hand out NFT + entitlement.
    function _book(uint256 momentId, Quote memory q) private {
        Ledger storage l = _ledgers[momentId];
        l.reserve += q.reserveIn;
        l.creatorClaimable += q.creatorIn;
        l.platformClaimable += q.platformIn;
        l.totalGross += q.gross;
        l.collects += 1;
        if (q.terminal) {
            l.state = MomentTypes.State.GraduationPending;
            l.completedAt = uint64(block.timestamp);
        }
    }

    function _deliver(uint256 momentId, MomentTypes.Moment memory m, Quote memory q) private {
        uint256 firstRank = IMomentNFT(m.nft).mint(msg.sender, q.editions);
        vesting.accrue(momentId, msg.sender, q.entitlement);
        emit Collected(momentId, msg.sender, q.gross, q.editions, firstRank, q.entitlement, q.reserveIn, q.creatorIn, q.platformIn, q.excess);
        if (q.terminal) {
            Ledger storage l = _ledgers[momentId];
            emit Completed(momentId, l.reserve, l.totalGross);
            _tryGraduate(momentId);
        }
    }

    /// @dev Graduation runs in an isolated subcall: it either completes fully or leaves the Moment
    ///      GraduationPending with the stuck clock started (retries never reset it).
    function _tryGraduate(uint256 momentId) private {
        if (gasleft() < GRADUATION_GAS + GRADUATION_GAS / 32) revert InsufficientGasForGraduation();
        try IMomentGraduation(factory.graduation()).graduate{gas: GRADUATION_GAS}(momentId) {}
        catch {
            Ledger storage l = _ledgers[momentId];
            if (l.stuckSince == 0) l.stuckSince = uint64(block.timestamp);
            emit GraduationFailed(momentId);
        }
    }

    // ------------------------------------------------------------------ expiry (wind-down)

    /// @notice Winds down a Moment that did not graduate: possible once the deadline has passed while Collecting,
    ///         or — for a completed Moment whose graduation keeps failing — once BOTH the deadline and the stuck
    ///         grace period have passed (so retries always come first). Permissionless; nothing goes to the caller.
    ///         The reserve is split creator (policy `expiryCreatorBps`) / treasury, both pull-only. The NFT closes.
    function expire(uint256 momentId) external nonReentrant {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        Ledger storage l = _ledgers[momentId];
        if (l.state == MomentTypes.State.Collecting) {
            if (block.timestamp < m.deadline) revert NotExpirable();
        } else if (l.state == MomentTypes.State.GraduationPending) {
            if (block.timestamp < m.deadline || block.timestamp < uint256(l.stuckSince) + MomentTypes.STUCK_GRACE) revert NotExpirable();
        } else {
            revert WrongState();
        }
        uint256 reserve = l.reserve;
        uint256 creatorShare = reserve * m.expiryCreatorBps / BPS;
        uint256 treasuryShare = reserve - creatorShare;
        // effects
        l.reserve = 0;
        l.creatorClaimable += creatorShare;
        l.treasuryClaimable += treasuryShare;
        l.state = MomentTypes.State.Expired;
        l.endedAt = uint64(block.timestamp);
        // interaction (our own NFT; fixes the edition size)
        IMomentNFT(m.nft).close();
        emit Expired(momentId, reserve, creatorShare, treasuryShare);
    }

    // ------------------------------------------------------------------ pull-only proceeds

    function withdrawCreator(uint256 momentId) external nonReentrant returns (uint256 amount) {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        if (msg.sender != m.creator) revert NotBeneficiary();
        Ledger storage l = _ledgers[momentId];
        amount = l.creatorClaimable;
        if (amount == 0) revert NothingToWithdraw();
        l.creatorClaimable = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(momentId, msg.sender, amount);
    }

    function withdrawPlatform(uint256 momentId) external nonReentrant returns (uint256 amount) {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        if (msg.sender != m.platform) revert NotBeneficiary();
        Ledger storage l = _ledgers[momentId];
        amount = l.platformClaimable;
        if (amount == 0) revert NothingToWithdraw();
        l.platformClaimable = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(momentId, msg.sender, amount);
    }

    function withdrawTreasury(uint256 momentId) external nonReentrant returns (uint256 amount) {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        if (msg.sender != m.treasury) revert NotBeneficiary();
        Ledger storage l = _ledgers[momentId];
        amount = l.treasuryClaimable;
        if (amount == 0) revert NothingToWithdraw();
        l.treasuryClaimable = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(momentId, msg.sender, amount);
    }

    // ------------------------------------------------------------------ graduation executor hooks

    /// @notice Hands the reserve to the graduation executor for the pool seed. Executor-only, GraduationPending only.
    function releaseReserve(uint256 momentId, address to) external returns (uint256 amount) {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        Ledger storage l = _ledgers[momentId];
        if (l.state != MomentTypes.State.GraduationPending) revert WrongState();
        amount = l.reserve;
        l.reserve = 0;
        USDC.safeTransfer(to, amount);
        emit ReserveReleased(momentId, to, amount);
    }

    function markGraduated(uint256 momentId) external {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        Ledger storage l = _ledgers[momentId];
        if (l.state != MomentTypes.State.GraduationPending) revert WrongState();
        l.state = MomentTypes.State.Graduated;
        l.stuckSince = 0;
        l.endedAt = uint64(block.timestamp);
        emit Graduated(momentId);
    }

    // ------------------------------------------------------------------ views

    function ledger(uint256 momentId) external view returns (Ledger memory) {
        return _ledgers[momentId];
    }

    function state(uint256 momentId) external view returns (MomentTypes.State) {
        return _ledgers[momentId].state;
    }

    /// @notice The supply picture of a Moment. `remainderPool` is the exact number of coins the graduation seeds
    ///         (S − creator allocation − Σ entitlements), so `remainderPool + entitlements + creatorAlloc == S` holds
    ///         by construction at every point. `impliedPool` is what the current reserve would seed at the bundle rate;
    ///         it can exceed `remainderPool` only by integer rounding: each collect can floor away < 1 USDC unit of
    ///         reserve, which the terminal clamp recovers with up to BPS/reserveBps units of extra gross, so the gap is
    ///         bounded by `collects × (ceil(rateNum·BPS / (rateDen·reserveBps)) + 1)` coin wei.
    function supplyCheck(uint256 momentId)
        external
        view
        returns (uint256 entitlements, uint256 creatorAlloc, uint256 remainderPool, uint256 impliedPool, uint256 collects)
    {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        entitlements = vesting.totalEntitlement(momentId);
        creatorAlloc = MomentTypes.SUPPLY * m.creatorAllocBps / BPS;
        remainderPool = MomentTypes.SUPPLY - creatorAlloc - entitlements; // reverts if ever over-promised
        impliedPool = Math.mulDiv(_ledgers[momentId].reserve, m.rateNum, m.rateDen);
        collects = _ledgers[momentId].collects;
    }
}
