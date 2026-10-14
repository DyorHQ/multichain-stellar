// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MondayGraduationExecutor} from "../src/MondayGraduationExecutor.sol";
import {MondayFeeVault} from "../src/MondayFeeVault.sol";
import {IMondayV3Factory, IMondayV3Pool, IMondayV3SwapCallback} from "../src/interfaces/IMondayV3.sol";
import {TransferHelper} from "../src/libraries/TransferHelper.sol";

/// @notice Fork test against Monday Trade's LIVE spot factory on Monad mainnet. Proves the fee-collection fix:
///         graduation liquidity is minted to a `MondayFeeVault`, a real swap accrues the 1% pool fee, and the vault
///         harvests ONLY the fees to the fees address while the LP principal stays locked. Run with:
///           forge test --match-path test/MondayFeeVault.t.sol --fork-url monad -vvv
contract MondayFeeVaultTest is Test, IMondayV3SwapCallback {
    IMondayV3Factory constant FACTORY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    uint24 constant FEE = 10_000;

    MondayGraduationExecutor executor;
    MondayFeeVault vault;
    address governance = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");
    MockERC20 token;

    function setUp() public {
        vm.createSelectFork("monad");
        vault = new MondayFeeVault(governance, feeRecipient);
        // A fresh executor that mints graduated liquidity to the COLLECTABLE vault instead of the dead locker.
        // This test contract stands in for the launchpad factory (the only allowed caller of graduate).
        executor = new MondayGraduationExecutor(FACTORY, address(this), address(vault), WMON);
        token = new MockERC20("Vault Launch", "VLT", 18);
    }

    function test_graduate_thenCollectFees_principalStaysLocked() public {
        uint256 tokenAmount = 200_000_000e18; // reserved supply swept from the curve
        uint256 quoteAmount = 10e18; // WMON raised
        uint256 phantomQuote = 4_000e18;
        token.mint(address(executor), tokenAmount);
        deal(WMON, address(executor), quoteAmount);

        (bytes32 poolId, uint128 liquidity) =
            executor.graduate(address(token), WMON, quoteAmount, tokenAmount, phantomQuote, int24(60));
        address pool = address(uint160(uint256(poolId)));
        assertGt(liquidity, 0, "no liquidity minted");

        // The vault owns the full-range position.
        int24 spacing = FACTORY.feeAmountTickSpacing(FEE);
        int24 lower = TickMath.minUsableTick(spacing);
        int24 upper = TickMath.maxUsableTick(spacing);
        bytes32 key = keccak256(abi.encodePacked(address(vault), lower, upper));
        (uint128 posLiq,,,,) = IMondayV3Pool(pool).positions(key);
        assertGt(posLiq, 0, "vault holds no position");

        uint128 principalBefore = IMondayV3Pool(pool).liquidity();

        // The vault holds the swept remainder (reserved supply + a sliver of quote), locked — same as the old
        // locker. Fees must bypass the vault entirely, so record this and assert `collect` never adds to it.
        uint256 vaultWmonRemainder = _bal(WMON, address(vault));

        // A trader swaps WMON -> token, paying the 1% fee, which accrues to the vault's full-range position.
        _swapExactWmonIn(pool, 1e18);
        assertEq(_bal(WMON, feeRecipient), 0, "fee recipient prefunded");

        (uint128 amt0, uint128 amt1) = vault.collectFees(pool);
        assertTrue(amt0 > 0 || amt1 > 0, "no fees collected");

        // The fees address received the WMON fee; the collect paid it directly, never through the vault's balance.
        assertGt(_bal(WMON, feeRecipient), 0, "fee recipient got no fees");
        assertEq(_bal(WMON, address(vault)), vaultWmonRemainder, "collect routed fees through the vault");

        // Principal is untouched: pool + position liquidity unchanged after the harvest.
        assertEq(IMondayV3Pool(pool).liquidity(), principalBefore, "pool principal changed");
        (uint128 posLiqAfter,,,,) = IMondayV3Pool(pool).positions(key);
        assertEq(posLiqAfter, posLiq, "position principal changed");

        // A second harvest with no new trades yields nothing and still leaves principal intact.
        (uint128 a0, uint128 a1) = vault.collectFees(pool);
        assertEq(uint256(a0) + uint256(a1), 0, "double-harvest paid twice");
        assertEq(IMondayV3Pool(pool).liquidity(), principalBefore, "principal changed on empty harvest");
    }

    function test_roles_ownerOnly_and_twoStepOwnership() public {
        vm.expectRevert(MondayFeeVault.NotOwner.selector);
        vault.setLpFeeRecipient(address(0xBEEF));

        address newRecipient = makeAddr("newRecipient");
        vm.prank(governance);
        vault.setLpFeeRecipient(newRecipient);
        assertEq(vault.lpFeeRecipient(), newRecipient, "recipient not set");

        address newOwner = makeAddr("newOwner");
        vm.prank(governance);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), governance, "owner changed before accept");
        vm.expectRevert(MondayFeeVault.NotPendingOwner.selector);
        vault.acceptOwnership();
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner, "ownership not accepted");
    }

    // --- swap helper + v3 callback ---

    function _swapExactWmonIn(address pool, uint256 amountIn) internal {
        deal(WMON, address(this), amountIn * 2);
        bool zeroForOne = WMON < address(token); // selling WMON for the launch token
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IMondayV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address pool = msg.sender;
        if (amount0Delta > 0) TransferHelper.safeTransfer(IMondayV3Pool(pool).token0(), pool, uint256(amount0Delta));
        if (amount1Delta > 0) TransferHelper.safeTransfer(IMondayV3Pool(pool).token1(), pool, uint256(amount1Delta));
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(data, (uint256)) : 0;
    }
}
