// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

/// Phase 4 (v1.1): the on-chain metadata is valid JSON whatever the creator typed, and round-trips exactly.
contract NFTMetadataTest is MomentsBase {
    function _publishNamed(string memory name_, string memory place) internal returns (uint256 id, MomentNFT nft) {
        MomentsFactory.PublishParams memory p = _params(PRICE, 0, 77);
        p.name = name_;
        p.symbol = "WEIRD";
        p.provenance = MomentTypes.Provenance({mediaURI: 'ipfs://bafy"quoted', mediaHash: keccak256("x"), place: place, date: 1_779_900_000, animationURI: ""});
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        (uint256 i,, address n) = factory.publish(p, terms);
        return (i, MomentNFT(n));
    }

    function test_tokenURI_is_valid_json_with_quotes_backslashes_and_control_chars() public {
        string memory name_ = 'Sun"rise \\ over Labadi';
        string memory place = "Accra \"old town\"\n(beach)";
        (uint256 id, MomentNFT nft) = _publishNamed(name_, place);
        _collect(id, alice, 1);
        string memory uri = nft.tokenURI(1);
        bytes memory raw = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertEq(string(_slice(raw, 0, prefix.length)), string(prefix));
        string memory json = string(_b64decode(_slice(raw, prefix.length, raw.length - prefix.length)));
        // forge's JSON parser rejects malformed documents; the fields must round-trip exactly
        assertEq(vm.parseJsonString(json, ".name"), string.concat(name_, " #1"));
        assertEq(vm.parseJsonString(json, ".image"), 'ipfs://bafy"quoted');
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), place);
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 1);
    }

    function test_tokenURI_plain_strings_unchanged_and_edition_size_after_close() public {
        (uint256 id, MomentNFT nft) = _publishNamed("Plain name", "Accra");
        _collect(id, alice, 2);
        string memory json = string(_b64decode(_slice(bytes(nft.tokenURI(2)), 29, bytes(nft.tokenURI(2)).length - 29)));
        assertEq(vm.parseJsonString(json, ".name"), "Plain name #2");
        assertTrue(_contains(json, "(open edition)"));
        _completeWithSingles(id, bob);
        json = string(_b64decode(_slice(bytes(nft.tokenURI(2)), 29, bytes(nft.tokenURI(2)).length - 29)));
        assertTrue(_contains(json, string.concat("Edition #2 of ", vm.toString(nft.totalMinted()))));
        vm.expectRevert(); // ERC721NonexistentToken
        nft.tokenURI(999);
    }

    /// OpenSea / marketplace standards: ERC-165 ids, ERC-2981, ERC-4906 refresh on close, ERC-7572 contractURI,
    /// owner() convention, animation_url + external_url, numeric rank with max_value once the edition is fixed.
    function test_marketplace_standards() public {
        MomentsFactory.PublishParams memory p = _params(PRICE, 0, 78);
        p.provenance.animationURI = "ipfs://bafy-video.mp4";
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        (uint256 id,, address n) = factory.publish(p, terms);
        MomentNFT nft = MomentNFT(n);
        assertTrue(nft.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(nft.supportsInterface(0x5b5e139f), "ERC-721 metadata");
        assertTrue(nft.supportsInterface(0x780e9d63), "ERC-721 enumerable");
        assertTrue(nft.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(nft.supportsInterface(0x49064906), "ERC-4906");
        assertFalse(nft.supportsInterface(0xffffffff));
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1_000_000);
        assertEq(receiver, creator, "royalties to the immutable creator");
        assertEq(amount, 50_000, "5% policy royalty");
        assertEq(nft.owner(), creator, "collection-admin convention");
        assertEq(nft.royaltyBps(), ROYALTY_BPS);

        _collect(id, alice, 2);
        string memory json = _decode(nft.tokenURI(2));
        assertEq(vm.parseJsonString(json, ".animation_url"), "ipfs://bafy-video.mp4");
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://bafy-labadi");
        assertEq(vm.parseJsonString(json, ".attributes[0].display_type"), "number");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 2);
        assertEq(vm.parseJsonString(json, ".attributes[2].display_type"), "date");
        assertFalse(vm.keyExistsJson(json, ".external_url"), "no external_url before a base is set");
        // contract-level metadata
        string memory cjson = _decode(nft.contractURI());
        assertEq(vm.parseJsonString(cjson, ".name"), "Sunrise over Labadi");
        assertEq(vm.parseJsonString(cjson, ".image"), "ipfs://bafy-labadi");

        // external links appear on Moments published once governance has set the base (metadata only). v2 (sec2,
        // MO-8): each collection keeps the base it was published with, so this one stays without a link.
        vm.prank(gov);
        factory.setExternalBaseURI("https://dyorhq.fun/moments/");
        assertFalse(vm.keyExistsJson(_decode(nft.tokenURI(1)), ".external_url"), "an existing NFT is never rewritten");
        (uint256 linkedId, MomentNFT linked) = _publishNamed("Linked", "Accra");
        _collect(linkedId, alice, 1);
        json = _decode(linked.tokenURI(1));
        assertEq(vm.parseJsonString(json, ".external_url"), string.concat("https://dyorhq.fun/moments/", vm.toString(linkedId)));
        cjson = _decode(linked.contractURI());
        assertEq(vm.parseJsonString(cjson, ".external_link"), string.concat("https://dyorhq.fun/moments/", vm.toString(linkedId)));

        // closing fixes the edition: ERC-4906 batch refresh + ERC-7572 signal, rank gets max_value, edition size trait
        for (uint256 i = 0; i < 11; i++) _collect(id, bob, 1); // reserve 9.75
        vm.expectEmit(true, true, true, true, address(nft));
        emit MomentNFT.BatchMetadataUpdate(1, 14);
        vm.expectEmit(true, true, true, true, address(nft));
        emit MomentNFT.ContractURIUpdated();
        _collect(id, carol, 1); // terminal: graduates and closes at 14 editions
        assertTrue(nft.closed());
        json = _decode(nft.tokenURI(2));
        assertEq(vm.parseJsonUint(json, ".attributes[0].max_value"), 14);
        assertEq(vm.parseJsonString(json, ".attributes[5].trait_type"), "Edition size");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 14);
        assertTrue(_contains(json, "Edition #2 of 14."));
        // freely transferable, and marketplaces operate through standard approvals
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.safeTransferFrom(alice, carol, 1);
        assertEq(nft.ownerOf(1), carol);
    }

    function _decode(string memory uri) internal pure returns (string memory) {
        bytes memory raw = bytes(uri);
        return string(_b64decode(_slice(raw, 29, raw.length - 29)));
    }

    // ---- helpers ----
    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) out[i] = b[start + i];
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length && ok; j++) ok = h[i + j] == n[j];
            if (ok) return true;
        }
        return false;
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        uint256 len = data.length;
        uint256 pad;
        if (len > 0 && data[len - 1] == "=") pad++;
        if (len > 1 && data[len - 2] == "=") pad++;
        out = new bytes(len / 4 * 3 - pad);
        uint256 o;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (_v(data[i]) << 18) | (_v(data[i + 1]) << 12) | (_v(data[i + 2]) << 6) | _v(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(n >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(n >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(n));
        }
    }

    function _v(bytes1 c) internal pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - 65;
        if (c >= "a" && c <= "z") return uint8(c) - 97 + 26;
        if (c >= "0" && c <= "9") return uint8(c) - 48 + 52;
        if (c == "+") return 62;
        if (c == "/") return 63;
        return 0; // '='
    }
}
