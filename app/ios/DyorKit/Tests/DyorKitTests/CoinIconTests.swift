import XCTest
@testable import DyorKit

/// Which picture a token shows, by address: a curated token's bundled logo, a DyorHQ coin's own art loaded only from
/// DyorHQ's bucket or through DyorHQ's IPFS gateways, a list logo for anything else — and letters for a look-alike or a
/// picture from a host nobody vouches for (RI-5 area: no creator-chosen host ever learns who looked).
final class CoinIconTests: XCTestCase {
    private let supabase = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!
    private var policy: ImageSourcePolicy { ImageSourcePolicy(supabaseURL: supabase) }
    private let creator = Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")
    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"

    private func gateways(_ path: String) -> [URL] { MomentsMath.ipfsGateways.map { URL(string: $0 + path)! } }

    private func launch(_ logo: String, symbol: String = "QT", address: Address = DyorCoinChain.qt) -> (Token, DyorCoin) {
        (Token(address: address, symbol: symbol, name: "Coin", decimals: 18),
         DyorCoin(address: address, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: symbol, name: "Coin", creator: creator, logo: logo, pair: .zero))
    }

    private func sources(_ icon: CoinIcon) -> [URL]? {
        if case .remote(let list, _) = icon { return list.map(\.url) }
        return nil
    }

    // MARK: The resolver

    func testCuratedTokensShowTheirBundledLogoByAddress() {
        XCTAssertEqual(CoinIcon.resolve(.usdc, coin: nil, policy: policy), .bundled(symbol: "USDC"))
        XCTAssertEqual(CoinIcon.resolve(.mon, coin: nil, policy: policy), .bundled(symbol: "MON"))
        let renamed = Token(address: Monad.usdc, symbol: "USD Coin", name: "Anything", decimals: 6)
        XCTAssertEqual(CoinIcon.resolve(renamed, coin: nil, policy: policy), .bundled(symbol: "USDC"), "the curated entry's symbol, whatever the snapshot says")
        XCTAssertEqual(CoinIcon.resolve(.abil, coin: nil, policy: policy), .letters, "aBIL ships no logo, on purpose")
        for curated in Token.core where curated.logoURL != nil {
            XCTAssertEqual(CoinIcon.resolve(curated, coin: nil, policy: policy), .bundled(symbol: curated.symbol))
        }
    }

    func testALookAlikeShowsLettersWhateverMadeIt() {
        let fake = Token(address: Address(literal: "0x2222222222222222222222222222222222222222"), symbol: "USDC", name: "USD Coin", decimals: 6,
                         logoURL: URL(string: "https://raw.githubusercontent.com/monad-crypto/token-list/refs/heads/main/mainnet/USDC/logo.svg"))
        XCTAssertEqual(CoinIcon.resolve(fake, coin: nil, policy: policy), .letters, "never the real USDC's picture")
        let monad = Token(address: Address(literal: "0x2222222222222222222222222222222222222223"), symbol: "MND", name: "Monad", decimals: 18)
        XCTAssertEqual(CoinIcon.resolve(monad, coin: nil, policy: policy), .letters)
        let (token, coin) = launch(DyorCoinChain.media(creator, "usdc.jpg"), symbol: "USDC", address: Address(literal: "0x0000000000000000000000000000000000000c01"))
        XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: policy), .letters, "a DyorHQ launch called USDC too")
        let cyrillic = Token(address: Address(literal: "0x2222222222222222222222222222222222222224"), symbol: "USD\u{0421}", name: "Dollar", decimals: 6)
        XCTAssertEqual(CoinIcon.resolve(cyrillic, coin: nil, policy: policy), .letters)
    }

    func testADyorHQLaunchShowsItsOwnArtFilled() {
        let logo = DyorCoinChain.media(DyorCoinChain.owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg")
        let (token, coin) = launch(logo)
        XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: policy), .remote([RemoteImageSource(url: URL(string: logo)!)], fill: true))
        let (_, onIPFS) = launch("ipfs://\(cid)/x.png")
        XCTAssertEqual(sources(CoinIcon.resolve(token, coin: onIPFS, policy: policy)), gateways("\(cid)/x.png"), "DyorHQ's dedicated gateway first")
        XCTAssertEqual(MomentsMath.ipfsGateways.first, "https://scarlet-secure-kangaroo-820.mypinata.cloud/ipfs/")
        let (_, elsewhere) = launch("https://evil.example/ipfs/\(cid)")
        XCTAssertEqual(sources(CoinIcon.resolve(token, coin: elsewhere, policy: policy)), gateways(cid), "rewritten onto DyorHQ's gateways")
        for hostile in ["https://evil.example/qt.png", "http://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/a.jpg", "data:image/png;base64,iVBORw0KGgo=",
                        "javascript:alert(1)", "ar://abcdefghijklmnopqrstuvwxyz0123456789ABCD", "", "   "] {
            let (_, coin) = launch(hostile)
            XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: policy), .letters, hostile)
        }
        let (_, other) = launch(DyorCoinChain.media(creator, "x.jpg"))
        XCTAssertEqual(CoinIcon.resolve(Token(address: Address(literal: "0x0000000000000000000000000000000000000c09"), symbol: "QT", name: "Coin", decimals: 18), coin: other, policy: policy), .letters,
                       "another coin's entry lends it nothing")
    }

    /// A Moment coin shows its art as the Moments screens load it: a photo on IPFS from DyorHQ's mirror first (checked
    /// against its hash), then the gateways; a video from its poster pointer alone; c1's https photos as they are.
    func testADyorHQMomentShowsItsArtAsTheMomentsScreensDo() throws {
        let hash = try XCTUnwrap(Data(hex: "0xdb08e94e078678ab7488b080ab5051615e70d5dd84e3331c6d7c5bb4aa0f5900"))
        let mirror = try XCTUnwrap(MomentsMath.mirrorURL(creator: creator, mediaHash: hash, supabaseURL: supabase))
        func moment(_ uri: String, video: Bool) -> (Token, DyorCoin) {
            let address = Address(literal: "0xC18941ca9fBaa613841c3d31a7Dd1D262a47a2E5")
            return (Token(address: address, symbol: "0N1", name: "0N1 Force", decimals: 18),
                    DyorCoin(address: address, origin: .moment(factory: DyorCoinChain.c2, id: 1, retired: true), symbol: "0N1", name: "0N1 Force", creator: creator,
                             logo: uri, mediaHash: hash, mediaIsVideo: video, pair: Monad.usdc))
        }
        let (token, photo) = moment("ipfs://\(cid)", video: false)
        guard case .remote(let list, let fill) = CoinIcon.resolve(token, coin: photo, policy: policy) else { return XCTFail("a picture") }
        XCTAssertTrue(fill)
        XCTAssertEqual(list.first, RemoteImageSource(url: mirror, keccak: hash), "the mirror first, kept only while its bytes match")
        XCTAssertEqual(list.dropFirst().map(\.url), gateways(cid))
        XCTAssertTrue(list.dropFirst().allSatisfy { $0.keccak == nil })

        let (_, video) = moment("ipfs://\(cid)", video: true)
        XCTAssertEqual(sources(CoinIcon.resolve(token, coin: video, policy: policy)), gateways(cid), "a video's poster from its pointer: nothing on chain checks the mirror's")
        let (_, mirrored) = moment(mirror.absoluteString, video: false)
        XCTAssertEqual(CoinIcon.resolve(token, coin: mirrored, policy: policy), .remote([RemoteImageSource(url: mirror, keccak: hash)], fill: true))
        let (_, mirroredVideo) = moment(mirror.absoluteString, video: true)
        XCTAssertEqual(CoinIcon.resolve(token, coin: mirroredVideo, policy: policy), .letters)
        let spt = DyorCoinChain.media(creator, "moment-1bba9cd9-1a1e-4bba-a364-df5466842c37.jpg")
        let (_, bucket) = moment(spt, video: false)
        XCTAssertEqual(sources(CoinIcon.resolve(token, coin: bucket, policy: policy)), [URL(string: spt)!], "cohort 1's photos, in DyorHQ's bucket")
        let (_, foreign) = moment("https://evil.example/photo.jpg", video: false)
        XCTAssertEqual(CoinIcon.resolve(token, coin: foreign, policy: policy), .letters)
    }

    /// A token that isn't DyorHQ's shows the logo a list gave it (Kuru's hosts included, any https), fitted; one with none,
    /// or an unusable one, its letters. A launchpad coin's stored logo is its creator's, so it keeps the creator rules.
    func testOtherTokensShowTheirListLogo() {
        let kuru = URL(string: "https://dsvxs4ecepqgj.cloudfront.net/logos/chog.png")!
        let chog = Token(address: Address(literal: "0x3333333333333333333333333333333333333333"), symbol: "CHOG", name: "Chog", decimals: 18, logoURL: kuru)
        XCTAssertEqual(CoinIcon.resolve(chog, coin: nil, policy: policy), .remote([RemoteImageSource(url: kuru)], fill: false))
        let james = Token(address: DyorCoinChain.james, symbol: "JAMES", name: "The Busy Bull of Monad", decimals: 18)
        XCTAssertEqual(CoinIcon.resolve(james, coin: nil, policy: policy), .letters, "no third-party picture for a token sent to you")
        let insecure = Token(address: chog.address, symbol: "CHOG", name: "Chog", decimals: 18, logoURL: URL(string: "http://example.com/chog.png"))
        XCTAssertEqual(CoinIcon.resolve(insecure, coin: nil, policy: policy), .letters)
        let credentials = Token(address: chog.address, symbol: "CHOG", name: "Chog", decimals: 18, logoURL: URL(string: "https://user:pw@example.com/chog.png"))
        XCTAssertEqual(CoinIcon.resolve(credentials, coin: nil, policy: policy), .letters)
        let bought = Token(address: Address(literal: "0x4444444444444444444444444444444444444444"), symbol: "PEPE", name: "Pepe", decimals: 18,
                           logoURL: URL(string: "https://tracker.example/pepe.png"), isLaunchpad: true)
        XCTAssertEqual(CoinIcon.resolve(bought, coin: nil, policy: policy), .letters, "a launch logo from a stranger's host, not yet in the registry")
    }

    // MARK: The policy

    func testCreatorPicturesLoadOnlyFromDyorHQsBucketOrItsGateways() {
        let bucket = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xabc/1.jpg"
        XCTAssertEqual(policy.creatorSources(bucket), [URL(string: bucket)!])
        XCTAssertEqual(policy.creatorSources("  \(bucket)\n"), [URL(string: bucket)!])
        XCTAssertEqual(policy.creatorSources("IPFS://ipfs/\(cid)"), gateways(cid))
        XCTAssertEqual(policy.creatorSources("ipfs://\(cid)/a/b.png?x=1#y"), gateways("\(cid)/a/b.png"), "query and fragment dropped")
        XCTAssertEqual(policy.creatorSources("https://\(cid).ipfs.dweb.link/logo.png"), gateways("\(cid)/logo.png"), "subdomain form")
        XCTAssertEqual(policy.creatorSources("https://gateway.pinata.cloud/ipfs/\(cid)"), gateways(cid), "even a gateway DyorHQ uses: the list decides the order")
        let refused = [
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/avatars/0xabc/1.jpg", // another bucket
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/", // the bucket itself
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/../avatars/1.jpg",
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/%2e%2e/avatars/1.jpg",
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xabc%2F..%2Fx.jpg",
            "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xabc/1.jpg?download=1",
            "https://fmnjqrguvopusfufmirs.supabase.co:8443/storage/v1/object/public/launch-media/0xabc/1.jpg",
            "https://user@fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xabc/1.jpg",
            "https://fmnjqrguvopusfufmirs.supabase.co.evil.example/storage/v1/object/public/launch-media/0xabc/1.jpg",
            "https://evil.supabase.co/storage/v1/object/public/launch-media/0xabc/1.jpg",
            "https://evil.example/logo.png",
            "http://evil.example/ipfs/\(cid)",
            "ipfs://\(cid)/../../etc",
            "ipfs://not a cid",
            "ipfs://",
            "ipfs://\(String(repeating: "a", count: 129))",
            "https://evil.example/ipfs/",
            "ar://abcdefghijklmnopqrstuvwxyz0123456789ABCD",
            "https://arweave.net/abcdefghijklmnopqrstuvwxyz0123456789ABCD",
            "data:image/png;base64,iVBORw0KGgo=",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://evil.example/\u{202E}gnp.png",
            "",
        ]
        for uri in refused { XCTAssertEqual(policy.creatorSources(uri), [], uri) }
    }

    func testTheBucketIsThisBuildsSupabaseProject() {
        let fork = ImageSourcePolicy(supabaseURL: URL(string: "https://abcd.supabase.co")!, ipfsGateways: ["https://gw.example/ipfs/"])
        XCTAssertEqual(fork.creatorSources("https://abcd.supabase.co/storage/v1/object/public/launch-media/a.jpg"), [URL(string: "https://abcd.supabase.co/storage/v1/object/public/launch-media/a.jpg")!])
        XCTAssertEqual(fork.creatorSources("https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/a.jpg"), [])
        XCTAssertEqual(fork.creatorSources("ipfs://\(cid)"), [URL(string: "https://gw.example/ipfs/\(cid)")!])
    }
}
