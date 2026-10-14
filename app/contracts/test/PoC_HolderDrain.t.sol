// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderFeeSharing} from "../src/HolderFeeSharing.sol";

/// Minimal token that mirrors LaunchToken: calls beforeTransfer BEFORE moving balances, with no from==to guard.
contract MockShareToken {
    HolderFeeSharing public sharing;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(HolderFeeSharing s) { sharing = s; }

    function mint(address to, uint256 amt) external {
        sharing.beforeTransfer(address(0), to, amt);
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        sharing.beforeTransfer(msg.sender, to, amt); // before balance move — matches LaunchToken._transfer
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Attacker {
    HolderFeeSharing sharing;
    MockShareToken token;
    constructor(HolderFeeSharing s, MockShareToken t) { sharing = s; token = t; }
    function exploit() external {
        token.transfer(address(this), token.balanceOf(address(this))); // self-transfer double-settles owed
        sharing.claim(address(token));
    }
    receive() external payable {}
}

/// The test contract stands in for the factory (HolderFeeSharing(factory=this)).
contract HolderDrainPoC is Test {
    HolderFeeSharing sharing;
    MockShareToken token;
    Attacker attacker;
    address victim = address(0xBEEF);

    function escrow() external view returns (address) { return address(this); }
    function protocolFeeRecipient() external view returns (address) { return address(this); }
    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 1000 ether);
        sharing = new HolderFeeSharing(address(this));
        token = new MockShareToken(sharing);
        attacker = new Attacker(sharing, token);
        address[] memory none = new address[](0);
        sharing.register(address(token), address(0), none); // native-quote pool
        sharing.setAuthorized(address(this), true);
        token.mint(address(attacker), 100 ether); // two equal holders
        token.mint(victim, 100 ether);
        sharing.notifyReward{value: 200 ether}(address(token), 200 ether); // fair split: 100 each
    }

    /// Regression test for the self-transfer double-settle drain. The MockShareToken is adversarial: it calls
    /// beforeTransfer even for a self-transfer, so this specifically exercises the HolderFeeSharing `from==to` guard.
    /// Pre-fix the attacker drained 200 (its 100 + the victim's 100); post-fix it can claim only its fair 100 and
    /// the victim keeps theirs.
    function test_self_transfer_cannot_drain_rewards() public {
        // Rewards queue on notify and release a block later; advance so the fair split is observable/claimable.
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(sharing.pendingRewards(address(token), address(attacker)), 100 ether, "attacker fair share");
        assertEq(sharing.pendingRewards(address(token), victim), 100 ether, "victim fair share");
        assertEq(address(sharing).balance, 200 ether, "escrowed rewards");

        uint256 before = address(attacker).balance;
        attacker.exploit(); // self-transfer + claim
        uint256 received = address(attacker).balance - before;
        emit log_named_decimal_uint("attacker received (fair = 100)", received, 18);

        // FIX: the attacker gets only its own fair 100, never more.
        assertEq(received, 100 ether, "attacker must get only its fair share");

        // And the victim's 100 is still fully backed and claimable.
        uint256 vbefore = victim.balance;
        vm.prank(victim);
        sharing.claim(address(token));
        assertEq(victim.balance - vbefore, 100 ether, "victim still receives its full share");
        assertEq(address(sharing).balance, 0, "pool fully and fairly distributed");
    }
}
