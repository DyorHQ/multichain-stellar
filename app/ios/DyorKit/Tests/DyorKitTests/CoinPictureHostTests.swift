import XCTest
@testable import DyorKit

/// A coin's picture never loads from a host its creator chose (pick 6, decision 10): a Moment coin's token carries its
/// picture only as DyorHQ's bucket or IPFS through DyorHQ's gateways, a token list's logo loads only from the list hosts
/// the app really uses, a link must be short and name a real CID, and every IPFS link is read by one parser.
final class CoinPictureHostTests: XCTestCase {
    private let policy = ImageSourcePolicy.dyorhq
    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"
    private let bucket = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/moment-1.jpg"

    private func info(mediaURI: String) -> MomentInfo {
        let moment = Moment(id: 1, creator: DyorCoinChain.creator, platform: .zero, treasury: .zero, coin: Address(literal: "0x0000000000000000000000000000000000000e01"),
                            nft: Address(literal: "0x0000000000000000000000000000000000000e02"), price: 1, threshold: 1, rateNum: 1, rateDen: 1, creatorBps: 0, platformBps: 0,
                            reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0, deadline: 0, factory: MomentsAddresses.monadMainnet.factory)
        return MomentInfo(moment: moment, name: "Sea", symbol: "SEA", provenance: MomentProvenance(mediaURI: mediaURI, mediaHash: Data(count: 32), place: "", date: 0, animationURI: ""),
                          ledger: MomentLedger(state: .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: 0, platformClaimable: 0,
                                               treasuryClaimable: 0, totalGross: 0, collects: 0),
                          editions: 0, closed: false, entitlements: 0, graduated: false, progressBps: 0, pool: nil)
    }

    // MARK: A Moment coin's token (F2a)

    /// `MomentInfo.coinToken` puts the Moment's picture in `logoURL` only as the policy allows it: IPFS on DyorHQ's own
    /// gateway, DyorHQ's bucket as it is, and nothing for a creator's own host — which a stored snapshot would keep.
    func testAMomentCoinsTokenNeverCarriesTheCreatorsHost() {
        XCTAssertEqual(info(mediaURI: "ipfs://\(cid)").coinToken.logoURL, URL(string: MomentsMath.ipfsGateways[0] + cid))
        XCTAssertEqual(info(mediaURI: "https://evil.example/ipfs/\(cid)").coinToken.logoURL, URL(string: MomentsMath.ipfsGateways[0] + cid), "rewritten onto DyorHQ's gateway")
        XCTAssertEqual(info(mediaURI: bucket).coinToken.logoURL, URL(string: bucket))
        for foreign in ["https://creator-tracker.example/pixel.png", "http://example.com/a.png", "ar://abcdefghijklmnopqrstuvwxyz0123456789ABCD", "ipfs://ab", ""] {
            XCTAssertNil(info(mediaURI: foreign).coinToken.logoURL, foreign)
        }
        let fork = ImageSourcePolicy(supabaseURL: URL(string: "https://abcd.supabase.co")!, ipfsGateways: ["https://gw.example/ipfs/"])
        XCTAssertEqual(info(mediaURI: "ipfs://\(cid)").coinToken(policy: fork).logoURL, URL(string: "https://gw.example/ipfs/\(cid)"))
        let token = info(mediaURI: "https://creator-tracker.example/pixel.png").coinToken
        XCTAssertEqual(CoinIcon.resolve(token, coin: nil, policy: policy), .letters, "no source before the registry knows the coin")
    }

    // MARK: List logos (F2b)

    /// A logo a list gave a token loads only from the list hosts the app uses (Kuru's CDN and the logo bucket its rows
    /// point at, nad.fun's storage, the Monad token list's repository), or else as the creator rules allow: a stored
    /// snapshot carrying a creator's https link is refused like any other stranger's host.
    func testListLogosLoadOnlyFromTheListHosts() {
        func sources(_ logo: String) -> [URL] {
            policy.listSources(for: Token(address: Address(literal: "0x3333333333333333333333333333333333333333"), symbol: "CHOG", name: "Chog", decimals: 18, logoURL: URL(string: logo)))
        }
        for listed in ["https://dsvxs4ecepqgj.cloudfront.net/logos/chog.png", "https://crypto-token-logos-production.s3.us-west-2.amazonaws.com/0xabc.png",
                       "https://storage.nadapp.net/coin/abc.webp", "https://raw.githubusercontent.com/monad-crypto/token-list/refs/heads/main/mainnet/USDC/logo.svg"] {
            XCTAssertEqual(sources(listed), [URL(string: listed)!], listed)
        }
        XCTAssertEqual(sources(bucket), [URL(string: bucket)!], "DyorHQ's bucket")
        XCTAssertEqual(sources("https://ipfs.io/ipfs/\(cid)"), MomentsMath.ipfsGateways.map { URL(string: $0 + cid)! }, "IPFS, through the fixed gateways")
        for refused in ["https://creator-tracker.example/pixel.png", "https://raw.githubusercontent.com/attacker/repo/main/logo.png", "https://evil.cloudfront.net/x.png",
                        "https://dsvxs4ecepqgj.cloudfront.net:8443/logos/chog.png", "https://user@dsvxs4ecepqgj.cloudfront.net/logos/chog.png",
                        "http://dsvxs4ecepqgj.cloudfront.net/logos/chog.png", "https://dsvxs4ecepqgj.cloudfront.net.evil.example/x.png",
                        "https://dsvxs4ecepqgj.cloudfront.net/%2e%2e/x.png", "https://dsvxs4ecepqgj.cloudfront.net/" + String(repeating: "a", count: 2_100)] {
            XCTAssertEqual(sources(refused), [], refused)
        }
    }

    // MARK: Length and CID (F6)

    /// A link over 2,048 bytes gives no source, and an IPFS link must name a real CID (v0 or v1, decoded).
    func testLongLinksAndFakeCIDsGiveNoSource() {
        XCTAssertEqual(policy.creatorSources(bucket).count, 1)
        XCTAssertEqual(policy.creatorSources(bucket + "?" + String(repeating: "a", count: 10)), [], "a query on the bucket")
        let long = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/" + String(repeating: "a", count: 2_000)
        XCTAssertEqual(policy.creatorSources(long), [], "over 2,048 bytes")
        XCTAssertEqual(policy.creatorSources("ipfs://\(cid)/" + String(repeating: "a", count: 2_100)), [])
        let real = [cid, "bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe", "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG",
                    "BAFYBEID4I22Y4U6JDMDCSQFR3EL3MHSY76PCBDUFK2JNWXRDUEUSBJTP4Q", "f01701220c3c4733ec8affd06cf9e9ff50ffc6bcd2ec85a6170004bb709669c31de94391a",
                    "zdj7WWeQ43G6JJvLWQWZpyHuAMq6uYWRjkBXFad11vE2LHhQ7"]
        for text in real { XCTAssertTrue(IPFS.isCID(text), text) }
        let fake = ["ab", "bafy", "Qm" + String(repeating: "1", count: 44), cid + "a", String(cid.dropLast()), "b" + String(repeating: "a", count: 58), "notacid",
                    "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbd0", "x" + cid.dropFirst()]
        for text in fake {
            XCTAssertFalse(IPFS.isCID(text), text)
            XCTAssertEqual(policy.creatorSources("ipfs://\(text)"), [], text)
        }
    }

    // MARK: One IPFS parser (F15)

    /// Moment media, NFT metadata and coin pictures read IPFS links through `IPFS.path`, each with its own rule on top,
    /// and give what they gave before.
    func testEveryIPFSReaderGivesWhatItGaveBefore() {
        let cases: [(uri: String, path: String?, moments: [String], nft: String?, policy: [String])] = [
            ("ipfs://\(cid)", cid, MomentsMath.ipfsGateways.map { $0 + cid }, "https://ipfs.io/ipfs/\(cid)", MomentsMath.ipfsGateways.map { $0 + cid }),
            (" ipfs://ipfs/\(cid)/a.png ", "\(cid)/a.png", MomentsMath.ipfsGateways.map { $0 + cid + "/a.png" }, "https://ipfs.io/ipfs/\(cid)/a.png",
             MomentsMath.ipfsGateways.map { $0 + cid + "/a.png" }),
            ("ipfs://\(cid)/a.png?x=1#y", "\(cid)/a.png?x=1#y", MomentsMath.ipfsGateways.map { $0 + cid + "/a.png?x=1#y" }, "https://ipfs.io/ipfs/\(cid)/a.png?x=1#y",
             MomentsMath.ipfsGateways.map { $0 + cid + "/a.png" }),
            ("https://gateway.pinata.cloud/ipfs/\(cid)/1.json", "\(cid)/1.json", ["https://gateway.pinata.cloud/ipfs/\(cid)/1.json"], "https://ipfs.io/ipfs/\(cid)/1.json",
             MomentsMath.ipfsGateways.map { $0 + cid + "/1.json" }),
            ("https://\(cid).ipfs.dweb.link/1.json", "\(cid)/1.json", ["https://\(cid).ipfs.dweb.link/1.json"], "https://ipfs.io/ipfs/\(cid)/1.json",
             MomentsMath.ipfsGateways.map { $0 + cid + "/1.json" }),
            ("ipfs://x", "x", MomentsMath.ipfsGateways.map { $0 + "x" }, nil, []),
            ("ipfs://abcdef", "abcdef", MomentsMath.ipfsGateways.map { $0 + "abcdef" }, "https://ipfs.io/ipfs/abcdef", []),
            ("https://tracker.example/pixel.png", nil, ["https://tracker.example/pixel.png"], nil, []),
            ("http://gateway.pinata.cloud/ipfs/\(cid)", nil, ["http://gateway.pinata.cloud/ipfs/\(cid)"], nil, []),
            ("javascript:alert(1)", nil, [], nil, []),
        ]
        for c in cases {
            XCTAssertEqual(IPFS.path(c.uri), c.path, c.uri)
            XCTAssertEqual(MomentsMath.gatewayURLs(c.uri).map(\.absoluteString), c.moments, c.uri)
            XCTAssertEqual(NFTMetadata.gatewayURL(c.uri)?.absoluteString, c.nft, c.uri)
            XCTAssertEqual(policy.creatorSources(c.uri).map(\.absoluteString), c.policy, c.uri)
        }
    }
}
