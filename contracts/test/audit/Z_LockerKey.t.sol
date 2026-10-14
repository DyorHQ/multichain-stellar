// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// LP-3 regression (v2 source): LaunchLocker.locked[] must be keyed by the LAUNCH token whichever way the pair
/// sorts. In v1 an ERC-20 quote that sorts below the token (AUSD, some USDC launches) was used as the key, so
/// `locked(token)` read empty and every such graduation overwrote the quote's entry.
contract Z_LockerKeyTest is LaunchpadBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockERC20 internal lowQuote; // sorts below every launch token
    MockERC20 internal highQuote; // sorts above every launch token

    function setUp() public override {
        super.setUp();
        deployCodeTo("src/mocks/MockERC20.sol:MockERC20", abi.encode("Low Dollar", "LOWD", uint8(6)), address(0x1000));
        deployCodeTo("src/mocks/MockERC20.sol:MockERC20", abi.encode("High Dollar", "HIGHD", uint8(6)), address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF));
        lowQuote = MockERC20(address(0x1000));
        highQuote = MockERC20(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF));
        factory.setPairEconomics(address(lowQuote), USD_PHANTOM, USD_THRESHOLD, 6, true);
        factory.setPairEconomics(address(highQuote), USD_PHANTOM, USD_THRESHOLD, 6, true);
        lowQuote.mint(bob, 1_000_000_000e6);
        highQuote.mint(bob, 1_000_000_000e6);
    }

    function _graduateWith(MockERC20 quote, uint256 seed) internal returns (address token, PoolKey memory key) {
        (LaunchToken t, BondingCurve curve) = _launch(alice, address(quote), 0, false, seed);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.startPrank(bob);
        while (!curve.completed()) {
            quote.approve(address(curve), 800e6);
            curve.buy(800e6, 0, bob);
        }
        vm.stopPrank();
        token = address(t);
        key = factory.poolKeyOf(token);
    }

    function _assertLockedUnderToken(address token, PoolKey memory key) internal view {
        (bytes32 poolId, int24 lower, int24 upper, uint128 liquidity) = locker.locked(token);
        assertEq(poolId, PoolId.unwrap(key.toId()), "keyed by the launch token");
        assertLt(lower, upper);
        assertGt(liquidity, 0);
        assertEq(liquidity, manager.getLiquidity(key.toId()), "the locker owns all of the pool's liquidity");
        assertEq(locker.lockedLiquidity(token), liquidity, "PoolManager confirms the locked position");
    }

    function test_quoteSortsFirst_lockedUnderLaunchToken() public {
        (address token, PoolKey memory key) = _graduateWith(lowQuote, 81);
        assertEq(Currency.unwrap(key.currency0), address(lowQuote), "quote is currency0");
        _assertLockedUnderToken(token, key);
        (bytes32 quoteEntry,,,) = locker.locked(address(lowQuote));
        assertEq(quoteEntry, bytes32(0), "nothing recorded under the quote token");
        assertEq(locker.lockedLiquidity(address(lowQuote)), 0);
    }

    function test_quoteSortsLast_lockedUnderLaunchToken() public {
        (address token, PoolKey memory key) = _graduateWith(highQuote, 82);
        assertEq(Currency.unwrap(key.currency1), address(highQuote), "quote is currency1");
        _assertLockedUnderToken(token, key);
        (bytes32 quoteEntry,,,) = locker.locked(address(highQuote));
        assertEq(quoteEntry, bytes32(0));
    }

    function test_nativeQuote_lockedUnderLaunchToken() public {
        (LaunchToken t, BondingCurve curve) = _launch(alice, address(0), 0, false, 83);
        vm.warp(vm.getBlockTimestamp() + 10);
        _completeNative(curve, bob);
        _assertLockedUnderToken(address(t), factory.poolKeyOf(address(t)));
    }

    function test_twoLaunchesSameLowQuote_doNotOverwriteEachOther() public {
        (address a, PoolKey memory ka) = _graduateWith(lowQuote, 84);
        (address b, PoolKey memory kb) = _graduateWith(lowQuote, 85);
        _assertLockedUnderToken(a, ka);
        _assertLockedUnderToken(b, kb);
    }
}
