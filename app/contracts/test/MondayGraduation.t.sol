// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MondayGraduationExecutor} from "../src/MondayGraduationExecutor.sol";
import {IMondayV3Factory, IMondayV3Pool} from "../src/interfaces/IMondayV3.sol";

/// @notice Fork test against Monday Trade's LIVE spot factory on Monad mainnet. It proves that our graduation
///         executor speaks Monday's real interface — createPool, initialize, mint, and the mint callback — before a
///         single transaction is broadcast. Run with:
///           forge test --match-path test/MondayGraduation.t.sol --fork-url monad -vvv
contract MondayGraduationTest is Test {
    // Monday Trade spot (Uniswap-v3-style) factory and the canonical WMON, both on Monad mainnet.
    IMondayV3Factory constant FACTORY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    uint24 constant FEE = 10_000;

    MondayGraduationExecutor executor;
    address locker = makeAddr("locker");
    MockERC20 token;

    function setUp() public {
        vm.createSelectFork("monad");
        // The launchpad factory is simulated by this test contract (it is the only allowed caller).
        executor = new MondayGraduationExecutor(FACTORY, address(this), locker, WMON);
        token = new MockERC20("Test Launch", "TKN", 18);
    }

    function test_factoryIsV3() public view {
        // Sanity: the fee tier resolves to a tick spacing (confirms a v3-style factory at this address).
        assertGt(FACTORY.feeAmountTickSpacing(FEE), int24(0), "fee tier not supported");
    }

    function test_graduateIntoMondayPool() public {
        uint256 tokenAmount = 200_000_000e18; // reserved supply swept from the curve
        uint256 quoteAmount = 10e18;           // WMON raised (~$10-ish at test scale)
        uint256 phantomQuote = 4_000e18;

        // The launchpad sweeps the reserves to the executor before calling graduate; simulate that.
        token.mint(address(executor), tokenAmount);
        deal(WMON, address(executor), quoteAmount);

        vm.prank(address(this)); // the "launchpad factory"
        (bytes32 poolId, uint128 liquidity) = executor.graduate(address(token), WMON, quoteAmount, tokenAmount, phantomQuote, int24(60));

        address pool = address(uint160(uint256(poolId)));
        assertEq(pool, FACTORY.getPool(address(token), WMON, FEE), "poolId should be the pool address");
        assertTrue(pool != address(0), "pool not created");
        assertGt(liquidity, 0, "no liquidity minted");

        // The pool now holds our concentrated liquidity, and the locked position belongs to the locker.
        assertGt(IMondayV3Pool(pool).liquidity(), 0, "pool liquidity is zero");
        int24 spacing = FACTORY.feeAmountTickSpacing(FEE);
        int24 lower = (int24(-887272) / spacing) * spacing;
        int24 upper = (int24(887272) / spacing) * spacing;
        bytes32 key = keccak256(abi.encodePacked(locker, lower, upper));
        (uint128 posLiquidity,,,,) = IMondayV3Pool(pool).positions(key);
        assertGt(posLiquidity, 0, "locker holds no position");

        // The executor keeps nothing — leftovers were swept to the locker.
        assertEq(_erc20Balance(WMON, address(executor)), 0, "executor kept quote");
        assertEq(token.balanceOf(address(executor)), 0, "executor kept tokens");
    }

    function test_graduateNativePair() public {
        // The launchpad's default pair is native MON (address(0)); the executor must wrap it into a TOKEN/WMON pool.
        uint256 tokenAmount = 200_000_000e18;
        uint256 quoteAmount = 10e18;
        uint256 phantomQuote = 4_000e18;

        MockERC20 tkn = new MockERC20("Native Launch", "NAT", 18);
        tkn.mint(address(executor), tokenAmount);
        vm.deal(address(executor), quoteAmount); // native MON swept in

        vm.prank(address(this));
        (bytes32 poolId, uint128 liquidity) = executor.graduate(address(tkn), address(0), quoteAmount, tokenAmount, phantomQuote, int24(60));

        address pool = address(uint160(uint256(poolId)));
        assertEq(pool, FACTORY.getPool(address(tkn), WMON, FEE), "native pair should graduate into a TOKEN/WMON pool");
        assertGt(liquidity, 0, "no liquidity minted");
        assertGt(IMondayV3Pool(pool).liquidity(), 0, "pool liquidity is zero");
        assertEq(address(executor).balance, 0, "executor kept native");
        assertEq(_erc20Balance(WMON, address(executor)), 0, "executor kept wrapped quote");
    }

    function _erc20Balance(address asset, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(data, (uint256)) : 0;
    }
}
