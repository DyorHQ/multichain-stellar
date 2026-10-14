// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";

/// Re-enters `collect` from the ERC-721 receive hook fired by the NFT mint inside a collect.
contract MaliciousCollector is IERC721Receiver {
    MomentCollect public immutable collect;
    uint256 public momentId;
    bool public armed;

    constructor(MomentCollect c) {
        collect = c;
    }

    function attack(uint256 id) external {
        momentId = id;
        armed = true;
        collect.collect(id, 1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (armed) {
            armed = false;
            collect.collect(momentId, 1); // re-entrancy attempt
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
