// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {HolderFeeSharing} from "../src/HolderFeeSharing.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {MemeHook} from "../src/MemeHook.sol";
import {GraduationExecutor} from "../src/GraduationExecutor.sol";
import {LaunchAndBuyRouter} from "../src/LaunchAndBuyRouter.sol";
import {LaunchDeployer} from "../src/LaunchDeployer.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Types, ILaunchpadFactory} from "../src/interfaces/ILaunchpad.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {HookAddress} from "../src/libraries/HookAddress.sol";

/// @dev Deploys a fresh Uniswap v4 PoolManager plus the whole launchpad, wired the way the deploy script wires it.
abstract contract LaunchpadBase is Test, Deployers {
    uint256 internal constant LAUNCH_FEE = 1 ether;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant PHANTOM = 4_000e18;
    uint256 internal constant THRESHOLD = 16_000e18;
    uint16 internal constant CURVE_FEE = 100;
    uint16 internal constant POOL_FEE = 100;
    uint16 internal constant PROTOCOL_SHARE = 5000;
    uint16 internal constant MAX_TAX = 1000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant USD_PHANTOM = 1_000e6;
    uint256 internal constant USD_THRESHOLD = 4_000e6;

    LaunchpadFactory internal factory;
    FeeEscrow internal escrow;
    HolderFeeSharing internal sharing;
    LaunchLocker internal locker;
    MemeHook internal hook;
    GraduationExecutor internal executor;
    LaunchAndBuyRouter internal router;
    LaunchDeployer internal launchDeployer;
    MockERC20 internal usd;

    address internal protocol = makeAddr("protocol");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal creator = makeAddr("creator");
    uint256 internal creatorStart;

    function setUp() public virtual {
        vm.warp(1_780_000_000);
        deployFreshManagerAndRouters();

        factory = new LaunchpadFactory(manager, protocol, LAUNCH_FEE, PROTOCOL_SHARE, MAX_TAX);
        escrow = new FeeEscrow();
        sharing = new HolderFeeSharing(address(factory));
        locker = new LaunchLocker(manager, address(factory));

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MemeHook).creationCode, abi.encode(manager, address(factory))));
        (address predicted, bytes32 salt) = HookAddress.mine(address(this), flags, initCodeHash, 500_000);
        hook = new MemeHook{salt: salt}(manager, address(factory));
        assertEq(address(hook), predicted, "hook landed on the mined address");

        executor = new GraduationExecutor(manager, address(factory), address(hook), address(locker));
        router = new LaunchAndBuyRouter(ILaunchpadFactory(address(factory)));
        launchDeployer = new LaunchDeployer(address(factory));
        factory.setModules(address(hook), address(executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));

        uint16[] memory schedule = new uint16[](4);
        schedule[0] = 9800;
        schedule[1] = 2500;
        schedule[2] = 300;
        schedule[3] = 30;
        factory.addLaunchConfig(
            Types.LaunchConfig({supply: SUPPLY, curveFeeBps: CURVE_FEE, poolFeeBps: POOL_FEE, tickSpacing: TICK_SPACING, snipeTaxSchedule: schedule, enabled: true})
        );
        factory.setPairEconomics(address(0), PHANTOM, THRESHOLD, 18, true);
        usd = new MockERC20("USD Coin", "USDC", 6);
        factory.setPairEconomics(address(usd), USD_PHANTOM, USD_THRESHOLD, 6, true);

        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        vm.deal(carol, 1_000_000 ether);
        vm.deal(dave, 1_000_000 ether);
        vm.deal(creator, 10 ether);
        creatorStart = creator.balance;
        usd.mint(alice, 1_000_000_000e6);
        usd.mint(bob, 1_000_000_000e6);
        usd.mint(carol, 1_000_000_000e6);
    }

    function _params(address pair, uint16 tax, bool sharingOn, uint256 saltSeed) internal view returns (Types.TokenParams memory p) {
        p.name = "Jensen's Jacket";
        p.symbol = "JENSEN";
        p.logo = "ipfs://logo";
        p.description = "Blackwell demand keeps surprising.";
        p.socials = Types.Socials("x.com/jensen", "t.me/jensen", "", "", "");
        p.creatorFeeRecipient = creator;
        p.creatorTaxBps = tax;
        p.holderFeeSharing = sharingOn;
        p.expectedEconomics = factory.previewLaunchEconomics(0, pair);
        p.salt = bytes32(saltSeed);
    }

    function _launch(address deployer, address pair, uint16 tax, bool sharingOn, uint256 saltSeed)
        internal
        returns (LaunchToken token, BondingCurve curve)
    {
        Types.TokenParams memory p = _params(pair, tax, sharingOn, saltSeed);
        vm.prank(deployer);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, pair, new address[](0));
        token = LaunchToken(t);
        curve = BondingCurve(c);
    }

    function _buy(BondingCurve curve, address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = curve.buy{value: amount}(amount, 0, who);
    }

    function _buyUsd(BondingCurve curve, address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        usd.approve(address(curve), amount);
        out = curve.buy(amount, 0, who);
        vm.stopPrank();
    }

    function _completeNative(BondingCurve curve, address who) internal {
        while (!curve.completed()) _buy(curve, who, 3_000 ether);
    }

    function _completeUsd(BondingCurve curve, address who) internal {
        while (!curve.completed()) _buyUsd(curve, who, 800e6);
    }

    // Fees now auto-push to their recipient (falling back to the escrow only if a send fails), so "earned" is the
    // sum of what landed in the wallet and any escrow fallback. protocol/creator never trade and hold no usd, so
    // their native/token balances above their starting point are exactly their fee income.
    function _protocolNative() internal view returns (uint256) {
        return protocol.balance + escrow.balanceOf(protocol);
    }

    function _creatorNative() internal view returns (uint256) {
        return (creator.balance - creatorStart) + escrow.balanceOf(creator);
    }

    function _protocolToken(address t) internal view returns (uint256) {
        return IERC20(t).balanceOf(protocol) + escrow.balanceOfToken(protocol, t);
    }

    function _creatorToken(address t) internal view returns (uint256) {
        return IERC20(t).balanceOf(creator) + escrow.balanceOfToken(creator, t);
    }
}
