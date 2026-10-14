import Foundation
import XCTest
@testable import DyorKit

/// NFT metadata and art are read only from content-addressed storage, within a size cap (security audit 2026-09-26,
/// IOST-12): an airdropped NFT can't make the app call a host of its choosing.
final class NFTMetadataTests: XCTestCase {
    private let cid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"

    override func setUp() { MediaStub.reset() }

    func testIPFSLinksInEveryFormGoThroughTheGateway() {
        let expected = "https://ipfs.io/ipfs/\(cid)/1.json"
        XCTAssertEqual(NFTMetadata.gatewayURL("ipfs://\(cid)/1.json")?.absoluteString, expected)
        XCTAssertEqual(NFTMetadata.gatewayURL("ipfs://ipfs/\(cid)/1.json")?.absoluteString, expected)
        XCTAssertEqual(NFTMetadata.gatewayURL("https://gateway.pinata.cloud/ipfs/\(cid)/1.json")?.absoluteString, expected)
        XCTAssertEqual(NFTMetadata.gatewayURL("https://tracker.example/ipfs/\(cid)/1.json")?.absoluteString, expected)
        XCTAssertEqual(NFTMetadata.gatewayURL("https://\(cid).ipfs.dweb.link/1.json")?.absoluteString, expected)
        XCTAssertEqual(NFTMetadata.gatewayURL("ipfs://\(cid)")?.absoluteString, "https://ipfs.io/ipfs/\(cid)")
    }

    func testArweaveGoesThroughArweave() {
        let id = "bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U"
        XCTAssertEqual(NFTMetadata.gatewayURL("ar://\(id)")?.absoluteString, "https://arweave.net/\(id)")
        XCTAssertEqual(NFTMetadata.gatewayURL("https://arweave.net/\(id)/0.png")?.absoluteString, "https://arweave.net/\(id)/0.png")
    }

    func testAnyOtherHostIsNeverFetched() {
        XCTAssertNil(NFTMetadata.gatewayURL("https://tracker.example/meta/1.json"))
        XCTAssertNil(NFTMetadata.gatewayURL("http://gateway.pinata.cloud/ipfs/\(cid)"))
        XCTAssertNil(NFTMetadata.gatewayURL("https://user:pw@ipfs.io/ipfs/\(cid)"))
        XCTAssertNil(NFTMetadata.gatewayURL("ipfs://not a cid/1.json"))
        XCTAssertNil(NFTMetadata.gatewayURL("ar://short"))
        XCTAssertNil(NFTMetadata.gatewayURL("javascript:alert(1)"))
    }

    func testOnChainDocumentIsReadWithoutAnyRequest() async throws {
        let json = #"{"name":"Edition #1","image":"https://tracker.example/1.png","animation_url":"ipfs://\#(cid)/v.mp4"}"#
        let uri = "data:application/json;base64," + Data(json.utf8).base64EncodedString()
        let resolved = await NFTMetadata.resolve(tokenURI: uri, session: MediaStub.session())
        let metadata = try XCTUnwrap(resolved)
        XCTAssertEqual(metadata.name, "Edition #1")
        XCTAssertNil(metadata.image, "an image on an arbitrary host is not loaded")
        XCTAssertEqual(metadata.animation?.absoluteString, "https://ipfs.io/ipfs/\(cid)/v.mp4")
        XCTAssertTrue(MediaStub.requests.isEmpty)
    }

    func testMetadataOnAnArbitraryHostIsNotFetched() async {
        MediaStub.reply = (200, [:], Data(#"{"name":"Claim your reward"}"#.utf8))
        let metadata = await NFTMetadata.resolve(tokenURI: "https://tracker.example/1.json", session: MediaStub.session())
        XCTAssertNil(metadata)
        XCTAssertTrue(MediaStub.requests.isEmpty)
    }

    func testIPFSDocumentIsFetchedThroughTheGatewayWithinTheCap() async throws {
        MediaStub.reply = (200, [:], Data(#"{"name":"Art","image":"ipfs://\#(cid)/a.png"}"#.utf8))
        let resolved = await NFTMetadata.resolve(tokenURI: "ipfs://\(cid)/1.json", session: MediaStub.session())
        let metadata = try XCTUnwrap(resolved)
        XCTAssertEqual(MediaStub.requests.first?.url?.absoluteString, "https://ipfs.io/ipfs/\(cid)/1.json")
        XCTAssertEqual(metadata.image?.absoluteString, "https://ipfs.io/ipfs/\(cid)/a.png")

        MediaStub.reply = (200, [:], Data(repeating: 0x20, count: NFTMetadata.maxDocumentBytes + 1))
        let oversized = await NFTMetadata.resolve(tokenURI: "ipfs://\(cid)/2.json", session: MediaStub.session())
        XCTAssertNil(oversized)
    }
}
