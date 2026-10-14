// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IFeeEscrow, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Routes a launch's creator fees to its holders pro-rata. Accounting is the classic
///         reward-per-share scheme: the token reports every balance change before it happens, so each
///         holder's share is settled at their old balance and re-based at the new one. Protocol-owned
///         balances (curve, locker, pool manager, hook, factory, executors, Monday vault/pool, burn) are
///         excluded from the split.
///
///         Rewards are NOT distributed the moment they arrive. They are queued and released at the first touch of
///         a LATER block — before that touch changes any balance — so a reward is always split by the balances
///         that stood at the end of the block it arrived in. Without this, anyone could flash-borrow the launch
///         token out of its Uniswap v4 pool (take/settle inside one `unlock`), trigger the permissionless fee
///         sweep and be paid a "holder's" share for a balance held for zero blocks. A flash position cannot
///         survive a block boundary, so a queued reward only ever reaches real holders.
contract HolderFeeSharing {
    uint256 private constant PRECISION = 1e36;

    address public immutable factory;

    struct Pool {
        address quoteToken; // address(0) = native
        bool registered;
        uint256 accPerShare; // rewards per eligible token, scaled by PRECISION
        uint256 eligibleSupply;
        uint256 queued; // rewards received in `queuedBlock`, distributed at the first touch of a later block
        uint256 queuedBlock;
    }

    mapping(address => Pool) public pools; // token => pool
    mapping(address => mapping(address => bool)) public excluded; // token => account => excluded
    mapping(address => mapping(address => uint256)) private _debt; // token => account => settled baseline
    mapping(address => mapping(address => uint256)) public owed; // token => account => claimable
    mapping(address => bool) public authorized; // reward notifiers (curves, hook, factory)

    event Registered(address indexed token, address indexed quoteToken);
    event Excluded(address indexed token, address indexed account);
    event RewardQueued(address indexed token, uint256 amount, uint256 blockNumber);
    /// Emitted when a queued reward is released into the per-share accumulator.
    event RewardAdded(address indexed token, uint256 amount, uint256 eligibleSupply);
    event Claimed(address indexed token, address indexed account, uint256 amount);

    error NotFactory();
    error NotAuthorized();
    error NotRegistered();
    error AlreadyRegistered();
    error NativeValueMismatch();
    error UnexpectedNativeValue();
    error NothingToClaim();

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address _factory) {
        factory = _factory;
    }

    /// @notice Registers a launch token before it is deployed (its address is precomputed with CREATE2).
    function register(address token, address quoteToken, address[] calldata excludedAccounts) external onlyFactory {
        Pool storage p = pools[token];
        if (p.registered) revert AlreadyRegistered();
        p.registered = true;
        p.quoteToken = quoteToken;
        for (uint256 i = 0; i < excludedAccounts.length; i++) {
            excluded[token][excludedAccounts[i]] = true;
            emit Excluded(token, excludedAccounts[i]);
        }
        emit Registered(token, quoteToken);
    }

    /// @notice Excludes an account created after registration (the curve at launch, a Monday pool at graduation).
    function exclude(address token, address account) external onlyFactory {
        Pool storage p = pools[token];
        if (!p.registered) revert NotRegistered();
        if (excluded[token][account]) return;
        _release(token, p);
        _settle(token, account, p);
        uint256 bal = IERC20(token).balanceOf(account);
        excluded[token][account] = true;
        p.eligibleSupply -= bal;
        _debt[token][account] = 0;
        emit Excluded(token, account);
    }

    function setAuthorized(address account, bool allowed) external onlyFactory {
        authorized[account] = allowed;
    }

    /// @notice Called by a registered token before a transfer/mint moves balances.
    function beforeTransfer(address from, address to, uint256 amount) external {
        Pool storage p = pools[msg.sender];
        if (!p.registered) revert NotRegistered();
        address token = msg.sender;
        // Any touch in a later block first releases what the previous block queued, split by the balances as
        // they stand right now — i.e. BEFORE this transfer moves anything.
        _release(token, p);
        // A self-transfer is net-zero, but settling both the `from` and `to` sides for the SAME account would
        // double-credit its rewards (accrued once, debt re-based twice), letting a holder mint unfunded rewards
        // and drain the pool. Self-transfers change no balance, so there is nothing to settle — return early.
        if (from == to) return;
        bool fromEligible = from != address(0) && !excluded[token][from];
        bool toEligible = to != address(0) && !excluded[token][to];
        if (fromEligible) {
            _settle(token, from, p);
            _debt[token][from] = FullMath.mulDiv(IERC20(token).balanceOf(from) - amount, p.accPerShare, PRECISION);
        }
        if (toEligible) {
            _settle(token, to, p);
            _debt[token][to] = FullMath.mulDiv(IERC20(token).balanceOf(to) + amount, p.accPerShare, PRECISION);
        }
        if (fromEligible && !toEligible) p.eligibleSupply -= amount;
        else if (!fromEligible && toEligible) p.eligibleSupply += amount;
    }

    /// @notice Adds `amount` of the launch's quote asset to the holders' pool. Native rewards ride on
    ///         msg.value; ERC-20 rewards are pulled from the caller. The reward is queued and distributed at the
    ///         first touch of a later block (see the contract notice).
    function notifyReward(address token, uint256 amount) external payable {
        if (!authorized[msg.sender]) revert NotAuthorized();
        Pool storage p = pools[token];
        if (!p.registered) revert NotRegistered();
        if (p.quoteToken == address(0)) {
            if (msg.value != amount) revert NativeValueMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            TransferHelper.safeTransferFrom(p.quoteToken, msg.sender, address(this), amount);
        }
        _release(token, p);
        if (amount == 0) return;
        p.queued += amount;
        p.queuedBlock = block.number;
        emit RewardQueued(token, amount, block.number);
    }

    function claim(address token) external returns (uint256 amount) {
        Pool storage p = pools[token];
        if (!p.registered) revert NotRegistered();
        _release(token, p);
        if (!excluded[token][msg.sender]) {
            _settle(token, msg.sender, p);
            _debt[token][msg.sender] = FullMath.mulDiv(IERC20(token).balanceOf(msg.sender), p.accPerShare, PRECISION);
        }
        amount = owed[token][msg.sender];
        if (amount == 0) revert NothingToClaim();
        owed[token][msg.sender] = 0;
        TransferHelper.pay(p.quoteToken, msg.sender, amount);
        emit Claimed(token, msg.sender, amount);
    }

    /// @notice Claimable rewards for `account`, including its share of a queued reward that is already releasable.
    function pendingRewards(address token, address account) external view returns (uint256) {
        Pool storage p = pools[token];
        uint256 pending = owed[token][account];
        if (!excluded[token][account]) {
            uint256 acc = p.accPerShare;
            if (p.queued != 0 && p.queuedBlock < block.number && p.eligibleSupply != 0) {
                acc += FullMath.mulDiv(p.queued, PRECISION, p.eligibleSupply);
            }
            uint256 accrued = FullMath.mulDiv(IERC20(token).balanceOf(account), acc, PRECISION);
            pending += accrued - _debt[token][account];
        }
        return pending;
    }

    /// @notice The reward waiting in the queue and the block from which any touch will distribute it.
    function queuedRewards(address token) external view returns (uint256 amount, uint256 releasableFromBlock) {
        Pool storage p = pools[token];
        return (p.queued, p.queued == 0 ? 0 : p.queuedBlock + 1);
    }

    /// @dev Distributes the queued reward once a later block has begun. Pro-rata over the eligible supply as it
    ///      stands at this moment; with nobody eligible the protocol keeps it rather than stranding it here.
    function _release(address token, Pool storage p) internal {
        uint256 amount = p.queued;
        if (amount == 0 || p.queuedBlock >= block.number) return;
        p.queued = 0;
        if (p.eligibleSupply == 0) {
            _forwardToProtocol(p.quoteToken, amount);
            return;
        }
        p.accPerShare += FullMath.mulDiv(amount, PRECISION, p.eligibleSupply);
        emit RewardAdded(token, amount, p.eligibleSupply);
    }

    function _forwardToProtocol(address quoteToken, uint256 amount) internal {
        address escrow = ILaunchpadFactory(factory).escrow();
        address protocol = ILaunchpadFactory(factory).protocolFeeRecipient();
        if (quoteToken == address(0)) {
            IFeeEscrow(escrow).credit{value: amount}(protocol);
        } else {
            TransferHelper.safeApprove(quoteToken, escrow, amount);
            IFeeEscrow(escrow).creditToken(protocol, quoteToken, amount);
        }
    }

    function _settle(address token, address account, Pool storage p) internal {
        uint256 accrued = FullMath.mulDiv(IERC20(token).balanceOf(account), p.accPerShare, PRECISION);
        uint256 debt = _debt[token][account];
        if (accrued > debt) owed[token][account] += accrued - debt;
    }
}
