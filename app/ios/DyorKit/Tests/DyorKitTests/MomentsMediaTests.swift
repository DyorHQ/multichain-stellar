import XCTest
@testable import DyorKit

/// Moment media links: the gateway order the app tries for `ipfs://`, and the Supabase mirror derived from on-chain
/// provenance (creator + media hash), which must match the object name the uploader files media under.
final class MomentsMediaTests: XCTestCase {
    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"
    private let dedicated = "https://scarlet-secure-kangaroo-820.mypinata.cloud/ipfs/"

    func testIPFSGoesThroughTheDedicatedGatewayFirst() {
        let urls = MomentsMath.gatewayURLs("ipfs://\(cid)").map(\.absoluteString)
        XCTAssertEqual(urls, [
            dedicated + cid,
            "https://gateway.pinata.cloud/ipfs/\(cid)",
            "https://ipfs.io/ipfs/\(cid)",
            "https://dweb.link/ipfs/\(cid)",
        ])
        XCTAssertEqual(MomentsMath.url("ipfs://\(cid)")?.absoluteString, urls.first)
    }

    func testIPFSPathsAndLegacyPrefixAreKept() {
        XCTAssertEqual(MomentsMath.url(" ipfs://\(cid)/photo.jpg ")?.absoluteString, dedicated + cid + "/photo.jpg")
        XCTAssertEqual(MomentsMath.url("IPFS://ipfs/\(cid)")?.absoluteString, dedicated + cid)
    }

    func testHTTPSPassesThroughAndJunkIsRejected() {
        let https = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xab/moment-1.jpg"
        XCTAssertEqual(MomentsMath.gatewayURLs(https).map(\.absoluteString), [https])
        XCTAssertEqual(MomentsMath.url(https)?.absoluteString, https)
        XCTAssertNil(MomentsMath.url(""))
        XCTAssertNil(MomentsMath.url("javascript:alert(1)"))
        XCTAssertTrue(MomentsMath.gatewayURLs("ftp://x").isEmpty)
    }

    func testMirrorIsDerivedFromOnChainProvenance() {
        let creator = Address(literal: "0x2AF85656F1B17Ce935DE335A4Ce95A4eFa807af5")
        let hash = Data(hex: "0xdb08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900")!
        XCTAssertEqual(MomentsMath.mediaName(hash: hash), "moment-db08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900")
        XCTAssertEqual(
            MomentsMath.mirrorURL(creator: creator, mediaHash: hash, supabaseURL: URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!)?.absoluteString,
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x2af85656f1b17ce935de335a4ce95a4efa807af5/moment-db08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900.jpg"
        )
        // Only a keccak-256 digest names an object; the create-screen preview passes an empty hash.
        XCTAssertNil(MomentsMath.mirrorURL(creator: creator, mediaHash: Data(), supabaseURL: URL(string: "https://x.test")!))
    }
}
