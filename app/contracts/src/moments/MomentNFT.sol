// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MomentTypes} from "./interfaces/IMoments.sol";

/// @notice The per-Moment collectible: a freely transferable ERC-721 whose token id IS the collector's edition rank
///         (#1, #2, ...). Minted only by the collect contract while the Moment is Collecting; the collection is
///         closed at graduation (by the executor) or at expiry (by the collect contract) and can never mint again.
///         Provenance is written once at construction and has no setter. Metadata is fully on-chain.
///
///         Marketplace standards (OpenSea et al.): ERC-721 + ERC-165 + ERC-721Enumerable; ERC-2981 royalties paid
///         to the immutable creator; ERC-4906 metadata-refresh events (emitted when the edition size is fixed);
///         ERC-7572 `contractURI()` collection metadata; `owner()` returns the creator purely as the collection-admin
///         convention marketplaces read — it confers no on-chain power; `animation_url` for video Moments and
///         `external_url` back to the Moment page (metadata only). v2 (sec2, MO-8): the link base is the factory's
///         at publish, stored here once; a later change of the factory's base never rewrites this collection.
contract MomentNFT is ERC721Enumerable, IERC2981 {
    using Strings for uint256;

    uint256 public constant MAX_BATCH = MomentTypes.MAX_BATCH;
    uint16 public constant MAX_ROYALTY_BPS = MomentTypes.MAX_ROYALTY_BPS;
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    uint256 public immutable momentId;
    address public immutable factory; // the deployer
    address public immutable creator;
    address public immutable collect; // the only minter; also closes on expiry
    address public immutable graduation; // closes at graduation
    uint16 public immutable royaltyBps; // ERC-2981 creator royalty suggested to marketplaces

    MomentTypes.Provenance private _provenance;
    /// @notice v2 (sec2, MO-8): prefix of this collection's external links (`<base><momentId>`), fixed at publish.
    string public externalBaseURI;
    uint256 public totalMinted;
    bool public closed;

    event Closed(uint256 totalMinted);
    /// @dev ERC-4906
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @dev ERC-7572
    event ContractURIUpdated();

    error NotCollect();
    error NotCloser();
    error CollectionClosed();
    error BadQuantity();
    error ZeroAddress();
    error BadRoyalty();

    constructor(
        uint256 _momentId,
        string memory name_,
        string memory symbol_,
        address _creator,
        address _collect,
        address _graduation,
        uint16 _royaltyBps,
        MomentTypes.Provenance memory prov,
        string memory externalBase
    ) ERC721(name_, symbol_) {
        if (_creator == address(0) || _collect == address(0) || _graduation == address(0)) revert ZeroAddress();
        if (_royaltyBps > MAX_ROYALTY_BPS) revert BadRoyalty();
        momentId = _momentId;
        factory = msg.sender;
        creator = _creator;
        collect = _collect;
        graduation = _graduation;
        royaltyBps = _royaltyBps;
        _provenance = prov;
        externalBaseURI = externalBase;
        emit ContractURIUpdated();
    }

    // ------------------------------------------------------------------ minting / closing

    /// @notice Mints `quantity` sequential editions to `to`; returns the first rank minted.
    function mint(address to, uint256 quantity) external returns (uint256 firstRank) {
        if (msg.sender != collect) revert NotCollect();
        if (closed) revert CollectionClosed();
        if (quantity == 0 || quantity > MAX_BATCH) revert BadQuantity();
        firstRank = totalMinted + 1;
        totalMinted += quantity;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(to, firstRank + i);
        }
    }

    /// @notice Fixes the edition size forever: at graduation (executor) or at expiry (collect contract).
    ///         Emits the ERC-4906 refresh so marketplaces re-read "Edition #n of N" and the ERC-7572 signal.
    function close() external {
        if (msg.sender != graduation && msg.sender != collect) revert NotCloser();
        if (closed) return;
        closed = true;
        emit Closed(totalMinted);
        if (totalMinted != 0) emit BatchMetadataUpdate(1, totalMinted);
        emit ContractURIUpdated();
    }

    // ------------------------------------------------------------------ marketplace standards

    /// @notice ERC-2981: `royaltyBps` of every sale to the immutable creator.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (creator, salePrice * royaltyBps / MomentTypes.BPS);
    }

    /// @notice Collection-admin convention read by marketplaces (OpenSea uses `owner()` to let the creator manage
    ///         the collection page). It is a view of the immutable creator and grants no permission in this contract.
    function owner() external view returns (address) {
        return creator;
    }

    /// @notice ERC-7572 contract-level metadata (collection name, description, image, external link).
    function contractURI() external view returns (string memory) {
        MomentTypes.Provenance memory p = _provenance;
        string memory external_ = _externalURL();
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _json(name()),
            '","description":"A DyorHQ Moment captured at ',
            _json(p.place),
            ". ",
            closed ? string.concat("Fixed edition of ", totalMinted.toString(), ".") : "Open edition while collecting.",
            '","image":"',
            _json(p.mediaURI),
            bytes(external_).length != 0 ? string.concat('","external_link":"', _json(external_)) : "",
            '"}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    function provenance() external view returns (MomentTypes.Provenance memory) {
        return _provenance;
    }

    /// @notice A page of `owner`'s token ids (ranks), for wallets without an indexer.
    function tokensOfOwner(address holder, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(holder);
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = tokenOfOwnerByIndex(holder, i);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        MomentTypes.Provenance memory p = _provenance;
        string memory external_ = _externalURL();
        bytes memory head = abi.encodePacked(
            '{"name":"',
            _json(name()),
            " #",
            tokenId.toString(),
            '","description":"A collected DyorHQ Moment. Edition #',
            tokenId.toString(),
            closed ? string.concat(" of ", totalMinted.toString(), ".") : " (open edition).",
            '","image":"',
            _json(p.mediaURI),
            bytes(p.animationURI).length != 0 ? string.concat('","animation_url":"', _json(p.animationURI)) : "",
            bytes(external_).length != 0 ? string.concat('","external_url":"', _json(external_)) : "",
            '",'
        );
        bytes memory attrs = abi.encodePacked(
            '"attributes":[{"display_type":"number","trait_type":"Rank","value":',
            tokenId.toString(),
            closed ? string.concat(',"max_value":', totalMinted.toString()) : "",
            '},{"trait_type":"Place","value":"',
            _json(p.place),
            '"},{"display_type":"date","trait_type":"Date","value":',
            uint256(p.date).toString(),
            '},{"trait_type":"Creator","value":"',
            Strings.toHexString(creator),
            '"},{"trait_type":"Media hash","value":"',
            Strings.toHexString(uint256(p.mediaHash), 32),
            closed ? string.concat('"},{"display_type":"number","trait_type":"Edition size","value":', totalMinted.toString(), "}]}") : '"}]}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(abi.encodePacked(head, attrs))));
    }

    // ------------------------------------------------------------------ internals

    /// @dev `<externalBaseURI><momentId>` when a base was set at publish; empty otherwise.
    function _externalURL() private view returns (string memory) {
        if (bytes(externalBaseURI).length == 0) return "";
        return string.concat(externalBaseURI, momentId.toString());
    }

    /// @dev Escapes a creator-supplied string for embedding in the metadata JSON: `"` and `\` are backslash-escaped
    ///      and control characters become `\u00XX`, so a quote in a name or place can never break the document.
    function _json(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") extra += 1;
            else if (c < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (c < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    // ---- OZ multiple-inheritance plumbing ----
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }
}
