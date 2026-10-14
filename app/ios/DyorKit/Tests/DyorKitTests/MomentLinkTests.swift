import BigInt
@testable import DyorKit
import XCTest

final class MomentLinkTests: XCTestCase {
    private func parse(_ text: String) -> MomentLink? { URL(string: text).flatMap(MomentLink.init(url:)) }
    private func key(_ cohort: MomentLink.Cohort, _ id: Int) -> MomentKey { MomentKey(factory: cohort.factory, id: BigUInt(id)) }

    /// The cohort table is the app's Moments deployments, in publish order (the order names are given out in): cohorts
    /// 1, 2 and 3 (retired), then the v2 factory (c4, the only live one; its factory is `MomentsAddresses.monadMainnet`'s).
    func testCohortTableMatchesTheDeploymentsInPublishOrder() {
        XCTAssertEqual(MomentLink.Cohort.allCases, [.c1, .c2, .c3, .c4])
        XCTAssertEqual(MomentLink.Cohort.allCases.map(\.rawValue), ["c1", "c2", "", "c4"])
        XCTAssertEqual(MomentLink.Cohort.c3.factory, MomentsAddresses.retiredMainnet[0].factory)
        XCTAssertEqual(MomentLink.Cohort.c2.factory, MomentsAddresses.retiredMainnet[1].factory)
        XCTAssertEqual(MomentLink.Cohort.c1.factory, MomentsAddresses.retiredMainnet[2].factory)
        XCTAssertEqual(MomentLink.Cohort.c4.factory, MomentsAddresses.monadMainnet.factory)
        XCTAssertEqual(MomentLink.Cohort.allCases.map(\.isRetired), [true, true, true, false])
        // Publish order is deployment order.
        XCTAssertLessThan(MomentsAddresses.retiredMainnet[2].deployBlock, MomentsAddresses.retiredMainnet[1].deployBlock)
        XCTAssertLessThan(MomentsAddresses.retiredMainnet[1].deployBlock, MomentsAddresses.retiredMainnet[0].deployBlock)
        if MomentLink.Cohort.c4.isWired {
            XCTAssertLessThan(MomentsAddresses.retiredMainnet[0].deployBlock, MomentsAddresses.monadMainnet.deployBlock)
        }
        // Every cohort's pinned count: the retired ones are final, c4 is counted live. The retired cohorts' names are
        // frozen at the Moments they had when c4 went live, and a pin never names fewer.
        XCTAssertEqual(MomentLink.Cohort.allCases.map(\.finalMomentCount), [3, 2, 1, nil])
        XCTAssertEqual(MomentLink.Cohort.allCases.map(\.namedMomentCount), [3, 2, 1, nil])
        for cohort in MomentLink.Cohort.allCases where cohort.isRetired {
            XCTAssertLessThanOrEqual(try XCTUnwrap(cohort.namedMomentCount), try XCTUnwrap(cohort.finalMomentCount), "\(cohort)")
        }
        for cohort in MomentLink.Cohort.wired { XCTAssertEqual(MomentLink.Cohort(factory: cohort.factory), cohort) }
        // The zero address is no cohort, including while c4 is pending (then c4 is simply not wired).
        XCTAssertNil(MomentLink.Cohort(factory: .zero))
        XCTAssertEqual(MomentLink.Cohort.wired, MomentLink.Cohort.c4.isWired ? MomentLink.Cohort.allCases : [.c1, .c2, .c3])
        XCTAssertEqual(MomentLink.Cohort.c4.isWired, MomentsAddresses.monadMainnet.isDeployed)
        XCTAssertNil(MomentLink(key: MomentKey(factory: .zero, id: 1)))
        XCTAssertNil(MomentLink(key: MomentKey(factory: MomentsAddresses.retiredMainnet[0].collect, id: 1)))
    }

    // MARK: Names

    func testSlugBase() {
        let cases: [(String, String)] = [
            ("Bitcoin Diva", "bitcoin-diva"),
            ("Spectacular", "spectacular"),
            ("0N1 Force", "0n1-force"),
            ("0N1 Force NFT", "0n1-force-nft"),
            ("RWA", "rwa"),
            ("Logan Paul\u{2019}s Portfolio", "logan-paul-s-portfolio"),
            ("Beyoncé Live!!", "beyonce-live"),
            ("naïve café", "naive-cafe"),
            ("\u{FF26}\u{FF35}\u{FF2C}\u{FF2C} width", "full-width"), // fullwidth letters
            ("\u{FB01}re", "fire"), // the "fi" ligature
            ("  --Hello__World-- ", "hello-world"),
            ("C1", "c1"),
            ("2024", "moment-2024"),
            ("1 2 3", "moment-1-2-3"),
            ("🔥🔥", "moment"),
            ("", "moment"),
            ("Биткоин", "moment"), // no Latin letters survive
            ("Moon 🚀 Landing", "moon-landing"),
        ]
        for (name, slug) in cases {
            XCTAssertEqual(MomentSlug.base(name), slug, name)
            XCTAssertTrue(MomentSlug.isValid(slug), slug)
        }
        let long = MomentSlug.base(String(repeating: "abcdefghi ", count: 12))
        XCTAssertLessThanOrEqual(long.count, MomentSlug.maxBase)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertTrue(MomentSlug.isValid(long))
    }

    /// The first Moment with a name gets it plain, later ones the first free "-2", "-3"…, and publishing more never
    /// changes an earlier Moment's slug.
    func testSlugAssignment() {
        let ordered: [(key: MomentKey, name: String)] = [
            (key(.c1, 1), "Bitcoin Diva"),
            (key(.c1, 2), "bitcoin diva"),
            (key(.c1, 3), "Bitcoin-Diva 2"),
            (key(.c2, 1), "Bitcoin Diva"),
            (key(.c3, 1), "🔥"),
            (key(.c3, 2), "🚀"),
        ]
        let slugs = MomentSlug.assign(ordered)
        XCTAssertEqual(slugs[key(.c1, 1)], "bitcoin-diva")
        XCTAssertEqual(slugs[key(.c1, 2)], "bitcoin-diva-2")
        XCTAssertEqual(slugs[key(.c1, 3)], "bitcoin-diva-2-2")
        XCTAssertEqual(slugs[key(.c2, 1)], "bitcoin-diva-3")
        XCTAssertEqual(slugs[key(.c3, 1)], "moment")
        XCTAssertEqual(slugs[key(.c3, 2)], "moment-2")
        XCTAssertEqual(Set(slugs.values).count, ordered.count, "unique")
        for n in 1...ordered.count {
            let prefix = MomentSlug.assign(Array(ordered.prefix(n)))
            for (k, slug) in prefix { XCTAssertEqual(slugs[k], slug, "stable as more are published") }
        }
    }

    func testSlugValidity() {
        for good in ["a", "bitcoin-diva", "0n1-force", "moment-2024", "c1", "a1-b2-c3"] { XCTAssertTrue(MomentSlug.isValid(good), good) }
        for bad in ["", "2024", "-a", "a-", "a--b", "A", "bitcoin_diva", "bitcoin diva", "é", "a.b", "a/b",
                    String(repeating: "a", count: MomentSlug.maxLength + 1)] {
            XCTAssertFalse(MomentSlug.isValid(bad), bad)
        }
    }

    // MARK: Links

    func testNameLinks() throws {
        let link = try XCTUnwrap(MomentLink(name: "bitcoin-diva"))
        XCTAssertEqual(link.url.absoluteString, "https://dyorhq.fun/moments/bitcoin-diva")
        XCTAssertEqual(link.appURL.absoluteString, "dyorhq://moments/bitcoin-diva")
        XCTAssertEqual(MomentLink(url: link.url), link)
        XCTAssertEqual(MomentLink(url: link.appURL), link)
        XCTAssertNil(MomentLink(name: "Bitcoin Diva"))
        XCTAssertNil(MomentLink(name: "2024"))
    }

    /// The NFTs' on-chain `external_url` values (read 2026-09-28) resolve to their cohort and id, and round-trip. The
    /// id forms that existed before v2 keep naming the same Moment: `/moments/<id>` is cohort 3 (0x0FD4…), whose NFTs
    /// read the bare base.
    func testOnChainExternalURLsResolve() throws {
        let onChain: [(String, MomentLink.Cohort, Int)] = [
            ("https://dyorhq.fun/moments/c1/1", .c1, 1), ("https://dyorhq.fun/moments/c1/2", .c1, 2),
            ("https://dyorhq.fun/moments/c1/3", .c1, 3), ("https://dyorhq.fun/moments/c2/1", .c2, 1),
            ("https://dyorhq.fun/moments/c2/2", .c2, 2), ("https://dyorhq.fun/moments/1", .c3, 1),
            ("https://dyorhq.fun/moments/7", .c3, 7),
        ]
        for (text, cohort, id) in onChain {
            let link = try XCTUnwrap(parse(text), text)
            XCTAssertEqual(link.target, .key(key(cohort, id)), text)
            XCTAssertEqual(link.url.absoluteString, text)
        }
        XCTAssertEqual(parse("https://dyorhq.fun/moments/7")?.target, .key(MomentKey(factory: Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26"), id: 7)))
        // Every wired cohort round-trips; a pending c4 makes no link at all.
        for cohort in MomentLink.Cohort.allCases {
            for id in [1, 9, 10, 123_456_789, 999_999_999_999_999_999] as [BigUInt] {
                guard cohort.isWired else {
                    XCTAssertNil(MomentLink(cohort: cohort, id: id), "\(cohort) is pending")
                    continue
                }
                let link = try XCTUnwrap(MomentLink(cohort: cohort, id: id))
                XCTAssertEqual(MomentLink(url: link.url), link)
                XCTAssertEqual(MomentLink(url: link.appURL), link)
            }
        }
        XCTAssertNil(MomentLink(cohort: .c3, id: 0))
        XCTAssertNil(MomentLink(cohort: .c3, id: BigUInt(10).power(18)))
    }

    /// The v2 Moments' `external_url` (`https://dyorhq.fun/moments/c4/<id>`, the base they are deployed with) resolves to
    /// the v2 factory once it is wired, and to nothing while it is pending — never to another cohort.
    func testC4LinksResolveToTheV2Factory() throws {
        for text in ["https://dyorhq.fun/moments/c4/1", "dyorhq://moments/c4/1", MomentsAddresses.expectedExternalBaseURI + "1"] {
            if MomentLink.Cohort.c4.isWired {
                XCTAssertEqual(parse(text)?.target, .key(MomentKey(factory: MomentsAddresses.monadMainnet.factory, id: 1)), text)
                XCTAssertEqual(parse(text)?.url.absoluteString, "https://dyorhq.fun/moments/c4/1")
            } else {
                XCTAssertNil(parse(text), "\(text) while v2 is pending")
            }
        }
        // The form itself is exactly the v2 base plus the id.
        XCTAssertEqual(MomentsAddresses.expectedExternalBaseURI, "https://\(MomentLink.host)/moments/\(MomentLink.Cohort.c4.rawValue)/")
    }

    /// Spellings that mean the same thing: host case, port 443, one trailing slash, any query or fragment (ignored), a
    /// name in capitals, and the app scheme.
    func testAcceptedVariants() {
        let name: [(String, String)] = [
            ("https://dyorhq.fun/moments/bitcoin-diva/", "bitcoin-diva"),
            ("https://DYORHQ.FUN/moments/bitcoin-diva", "bitcoin-diva"),
            ("https://dyorhq.fun:443/moments/Bitcoin-Diva", "bitcoin-diva"),
            ("https://dyorhq.fun/moments/bitcoin-diva-2?utm_source=x&fbclid=y#web", "bitcoin-diva-2"),
            ("https://dyorhq.fun/moments/moment-2024", "moment-2024"),
            ("https://dyorhq.fun/moments/c1", "c1"), // a Moment named "C1"; the cohort form has two segments
            ("https://dyorhq.fun/moments/c1/", "c1"),
            ("dyorhq://moments/bitcoin-diva", "bitcoin-diva"),
            ("DYORHQ://moments/Bitcoin-Diva/", "bitcoin-diva"),
        ]
        for (text, slug) in name { XCTAssertEqual(parse(text)?.target, .name(slug), text) }
        let keyed: [(String, MomentLink.Cohort, Int)] = [
            ("https://dyorhq.fun/moments/2024", .c3, 2024),
            ("https://dyorhq.fun/moments/c2/2/?ref=abc#top", .c2, 2),
            ("dyorhq://moments/3", .c3, 3),
            ("dyorhq://moments/c1/3", .c1, 3),
        ]
        for (text, cohort, id) in keyed { XCTAssertEqual(parse(text)?.target, .key(key(cohort, id)), text) }
    }

    /// Everything else is nil.
    func testRejected() {
        let rejected = [
            // origin
            "http://dyorhq.fun/moments/bitcoin-diva", "https://www.dyorhq.fun/moments/bitcoin-diva", "https://m.dyorhq.fun/moments/1",
            "https://accounts.dyorhq.fun/moments/1", "https://dyorhq.fun.evil.example/moments/1", "https://evil.example/moments/1",
            "https://u@dyorhq.fun/moments/1", "https://u:p@dyorhq.fun/moments/1", "https://dyorhq.fun:8443/moments/1",
            "ftp://dyorhq.fun/moments/1", "https://dyorhq.fun./moments/1",
            // shape
            "https://dyorhq.fun", "https://dyorhq.fun/", "https://dyorhq.fun/bitcoin-diva", "https://dyorhq.fun/moments",
            "https://dyorhq.fun/moments/", "https://dyorhq.fun/Moments/bitcoin-diva", "https://dyorhq.fun/moment/bitcoin-diva",
            "https://dyorhq.fun/x/moments/1", "https://dyorhq.fun/moments//1", "https://dyorhq.fun/moments/1//",
            "https://dyorhq.fun/moments/bitcoin-diva/buy", "https://dyorhq.fun/moments/c1/1/2", "https://dyorhq.fun/moments/c1//",
            // names
            "https://dyorhq.fun/moments/bitcoin%20diva", "https://dyorhq.fun/moments/bitcoin_diva", "https://dyorhq.fun/moments/-diva",
            "https://dyorhq.fun/moments/diva-", "https://dyorhq.fun/moments/a--b", "https://dyorhq.fun/moments/%E2%9C%93",
            "https://dyorhq.fun/moments/caf%C3%A9", "https://dyorhq.fun/moments/a.b",
            "https://dyorhq.fun/moments/" + String(repeating: "a", count: MomentSlug.maxLength + 1),
            // ids and cohorts
            "https://dyorhq.fun/moments/0", "https://dyorhq.fun/moments/01", "https://dyorhq.fun/moments/-1",
            "https://dyorhq.fun/moments/%31", "https://dyorhq.fun/moments/%D9%A1", "https://dyorhq.fun/moments/1234567890123456789",
            "https://dyorhq.fun/moments/c3/1", "https://dyorhq.fun/moments/C4/1", "https://dyorhq.fun/moments/C1/1", "https://dyorhq.fun/moments/c5/1",
            "https://dyorhq.fun/moments/live/1", "https://dyorhq.fun/moments/c1/0", "https://dyorhq.fun/moments/c1/bitcoin-diva",
            "https://dyorhq.fun/moments/c4/0", "https://dyorhq.fun/moments/c4//1", "https://dyorhq.fun/moments/c4/1/2", "https://dyorhq.fun/moments/c4/nature",
            // the scheme
            "dyorhq://oauth?code=x", "dyorhq://moments", "dyorhq://moments/", "dyorhq://moment/1", "dyorhq:moments/1",
            "dyorhq://moments:80/1",
        ]
        for text in rejected { XCTAssertNil(parse(text), text) }
        XCTAssertTrue(("١" as Character).isNumber, "why the digit check is ASCII, not isNumber")
    }

    /// Only the website's Moments paths and the scheme's `moments` host are ours: Privy's callback on the same scheme
    /// is not, so it gets no "not a Moment" notice.
    func testIsOurs() {
        XCTAssertTrue(MomentLink.isOurs(URL(string: "https://dyorhq.fun/moments/whatever_x")!))
        XCTAssertTrue(MomentLink.isOurs(URL(string: "dyorhq://moments/abc_x")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://dyorhq.fun/privacy")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "dyorhq://oauth?code=x")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://accounts.dyorhq.fun/")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://evil.example/moments/1")!))
    }

    /// Every row of the gate.
    func testGate() {
        typealias G = MomentLinkGate
        XCTAssertEqual(G.decide(phase: .loading, updateRequired: false, deletionScreen: false, busy: false), .hold)
        XCTAssertEqual(G.decide(phase: .loading, updateRequired: true, deletionScreen: false, busy: true), .hold)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: false, busy: false), .banner)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: true, busy: false), .hold)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: true, deletionScreen: true, busy: false), .hold, "the deletion screens come before the update gate")
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: true, deletionScreen: false, busy: false), .drop)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false), .deliver)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: true), .hold)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: true, deletionScreen: false, busy: false), .drop)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: true, deletionScreen: false, busy: true), .drop)
    }
}

/// The name directory across the cohorts: the names read on chain (block 108,741,592) keep their slugs whatever v2
/// publishes, the retired cohorts are read only up to their frozen named counts, and a pending c4 is never asked
/// anything.
final class MomentDirectoryTests: XCTestCase {
    /// Every named retired Moment, in publish order, with the name its coin reports on chain.
    static let pinned: [(MomentLink.Cohort, Int, String, String)] = [
        (.c1, 1, "Spectacular", "spectacular"),
        (.c1, 2, "Bitcoin Diva", "bitcoin-diva"),
        (.c1, 3, "0N1 Force NFT", "0n1-force-nft"),
        (.c2, 1, "0N1 Force", "0n1-force"),
        (.c2, 2, "RWA", "rwa"),
        (.c3, 1, "Nature", "nature"),
    ]

    /// The existing name links keep naming the same Moment, and v2 Moments only get names after them: a c4 "Nature" is
    /// `nature-2`, never `nature`.
    func testExistingNamesKeepTheirSlugs() {
        let v2 = V2Fixture.moments.factory
        let ordered = Self.pinned.map { (key: MomentKey(factory: $0.0.factory, id: BigUInt($0.1)), name: $0.2) }
        let slugs = MomentSlug.assign(ordered + [(MomentKey(factory: v2, id: 1), "Nature"), (MomentKey(factory: v2, id: 2), "RWA"), (MomentKey(factory: v2, id: 3), "Spectacular 2")])
        for (cohort, id, _, slug) in Self.pinned {
            XCTAssertEqual(slugs[MomentKey(factory: cohort.factory, id: BigUInt(id))], slug, "\(cohort) #\(id)")
            XCTAssertEqual(MomentLink(name: slug)?.url.absoluteString, "https://dyorhq.fun/moments/\(slug)")
        }
        XCTAssertEqual(slugs[MomentKey(factory: v2, id: 1)], "nature-2")
        XCTAssertEqual(slugs[MomentKey(factory: v2, id: 2)], "rwa-2")
        XCTAssertEqual(slugs[MomentKey(factory: v2, id: 3)], "spectacular-2")
        XCTAssertEqual(Self.pinned.count, MomentLink.Cohort.allCases.compactMap(\.namedMomentCount).reduce(0, +))
    }

    /// A stubbed chain where every retired cohort reports more Moments than its pin (as if one were published after the
    /// pause): the directory asks no cohort for its count, reads names only up to the named counts, sends nothing to the
    /// pending c4 (address 0), and every existing name still resolves to its Moment.
    func testTheDirectoryReadsOnlyThePinnedRetiredMomentsAndNothingPending() async throws {
        let stacks = MomentsAddresses.retiredMainnet.map { cohort -> FakeMomentsStack in
            let names = Self.pinned.filter { $0.0.factory == cohort.factory }.map(\.2) + ["Late Arrival"]
            var stack = FakeMomentsStack(addresses: cohort, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: names)
            stack.momentCount = names.count
            return stack
        }
        MomentsChainStub.install { to, data in
            for stack in stacks { if let answer = stack.answer(to, data) { return answer } }
            return nil
        }
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: MomentLink.Cohort.c4.isWired ? [.c1, .c2, .c3] : MomentLink.Cohort.allCases)
        for (cohort, id, _, slug) in Self.pinned {
            let key = try await directory.key(for: slug)
            XCTAssertEqual(key, MomentKey(factory: cohort.factory, id: BigUInt(id)), slug)
            let link = try await directory.link(for: MomentKey(factory: cohort.factory, id: BigUInt(id)))
            XCTAssertEqual(link, MomentLink(name: slug))
        }
        let late = try await directory.key(for: "late-arrival")
        XCTAssertNil(late, "a Moment past a retired cohort's pin gets no name")

        let calls = MomentsChainStub.calls()
        XCTAssertFalse(calls.isEmpty)
        XCTAssertFalse(calls.contains { $0.to == .zero }, "a call went to address 0")
        XCTAssertFalse(calls.contains { $0.selector == ABI.selector(MomentsABI.Factory.momentCount).hexString }, "a retired cohort's count was read")
        let getMoment = ABI.selector(MomentsABI.Factory.getMoment).hexString
        XCTAssertEqual(calls.filter { $0.selector == getMoment }.count, Self.pinned.count, "each named Moment read once, none past it")
    }

    /// A Debug fork rehearsal (AppConfig's MOMENTS_* override) moves c4, and only c4, to the rehearsal's factory: its
    /// Moments' `…/moments/c4/<id>` links parse, Share has a link, and the directory names them after every retired
    /// Moment (a c4 "Nature" is `nature-2`). Cleared, c4 is `MomentsAddresses.monadMainnet`'s again.
    func testAForkRehearsalMovesOnlyC4() async throws {
        let rehearsal = V2Fixture.moments.factory
        MomentLink.Cohort.rehearse(liveFactory: rehearsal)
        defer { MomentLink.Cohort.rehearse(liveFactory: nil) }
        XCTAssertEqual(MomentLink.Cohort.c4.factory, rehearsal)
        XCTAssertEqual(MomentLink.Cohort.wired, MomentLink.Cohort.allCases)
        XCTAssertEqual(MomentLink.Cohort(factory: rehearsal), .c4)
        XCTAssertEqual(URL(string: "https://dyorhq.fun/moments/c4/2").flatMap(MomentLink.init(url:))?.target, .key(MomentKey(factory: rehearsal, id: 2)))
        XCTAssertEqual(MomentLink(key: MomentKey(factory: rehearsal, id: 2))?.url.absoluteString, "https://dyorhq.fun/moments/c4/2")
        XCTAssertEqual([MomentLink.Cohort.c1, .c2, .c3].map(\.factory), MomentsAddresses.retiredMainnet.reversed().map(\.factory), "c1–c3 never move")
        XCTAssertEqual(URL(string: "https://dyorhq.fun/moments/1").flatMap(MomentLink.init(url:))?.target, .key(MomentKey(factory: MomentLink.Cohort.c3.factory, id: 1)))

        let stacks = MomentsAddresses.retiredMainnet.map { cohort -> FakeMomentsStack in
            FakeMomentsStack(addresses: cohort, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: Self.pinned.filter { $0.0.factory == cohort.factory }.map(\.2))
        } + [FakeMomentsStack(addresses: V2Fixture.moments, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                              nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Nature", "Fork sunrise"])]
        MomentsChainStub.install { to, data in
            for stack in stacks { if let answer = stack.answer(to, data) { return answer } }
            return nil
        }
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc())
        let nature = try await directory.key(for: "nature")
        XCTAssertEqual(nature, MomentKey(factory: MomentLink.Cohort.c3.factory, id: 1))
        let second = try await directory.key(for: "nature-2")
        XCTAssertEqual(second, MomentKey(factory: rehearsal, id: 1))
        let sunrise = try await directory.link(for: MomentKey(factory: rehearsal, id: 2))
        XCTAssertEqual(sunrise?.url.absoluteString, "https://dyorhq.fun/moments/fork-sunrise")

        MomentLink.Cohort.rehearse(liveFactory: nil)
        XCTAssertEqual(MomentLink.Cohort.c4.factory, MomentsAddresses.monadMainnet.factory)
        XCTAssertEqual(MomentLink.Cohort.c4.isWired, MomentsAddresses.monadMainnet.isDeployed)
    }

    /// Build 16's c4 is the v2 factory deployed on 2026-09-28 (0x95eb…): `…/moments/c4/<id>` opens its Moments, every
    /// existing name keeps its Moment, and a c4 Moment named like an older one gets the next free name.
    func testTheShippedC4IsTheV2FactoryAndExistingNamesKeepTheirLinks() async throws {
        let v2 = Address(literal: "0x95eb7F5A88B10D9dF32aC54F48C767927fa80840")
        XCTAssertEqual(MomentsAddresses.monadMainnet.factory, v2)
        XCTAssertEqual(MomentLink.Cohort.c4.factory, v2)
        XCTAssertEqual(MomentLink.Cohort(factory: v2), .c4)
        XCTAssertEqual(MomentLink.Cohort.wired, MomentLink.Cohort.allCases)
        XCTAssertEqual(URL(string: "https://dyorhq.fun/moments/c4/1").flatMap(MomentLink.init(url:))?.target, .key(MomentKey(factory: v2, id: 1)))
        XCTAssertEqual(MomentLink(key: MomentKey(factory: v2, id: 1))?.url.absoluteString, "https://dyorhq.fun/moments/c4/1")

        let stacks = MomentsAddresses.retiredMainnet.map { cohort -> FakeMomentsStack in
            FakeMomentsStack(addresses: cohort, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: Self.pinned.filter { $0.0.factory == cohort.factory }.map(\.2))
        } + [FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                              nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Nature", "Bitcoin Diva"])]
        MomentsChainStub.install { to, data in
            for stack in stacks { if let answer = stack.answer(to, data) { return answer } }
            return nil
        }
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc())
        for (cohort, id, _, slug) in Self.pinned {
            let key = try await directory.key(for: slug)
            XCTAssertEqual(key, MomentKey(factory: cohort.factory, id: BigUInt(id)), slug)
        }
        let nature = try await directory.key(for: "nature-2")
        XCTAssertEqual(nature, MomentKey(factory: v2, id: 1))
        let diva = try await directory.link(for: MomentKey(factory: v2, id: 2))
        XCTAssertEqual(diva?.url.absoluteString, "https://dyorhq.fun/moments/bitcoin-diva-2")
    }

    /// Cohort 3 stays open on chain, so a build before 16 (or anyone calling its factory) can publish there after c4 went
    /// live. Such a Moment never takes a name: a c4 "Sunset" is `sunset` whatever cohort 3 holds, the late cohort 3
    /// "Sunset" shares its id link only, and raising cohort 3's pin to take in its coin (`finalMomentCount`) moves no
    /// name, since names stop at the frozen `namedMomentCount`.
    func testAMomentPublishedLateOnCohortThreeNeverTakesAName() async throws {
        let v2 = MomentsAddresses.monadMainnet.factory
        let stacks = MomentsAddresses.retiredMainnet.map { cohort -> FakeMomentsStack in
            var names = Self.pinned.filter { $0.0.factory == cohort.factory }.map(\.2)
            if cohort.factory == MomentLink.Cohort.c3.factory { names.append("Sunset") }
            var stack = FakeMomentsStack(addresses: cohort, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: names)
            stack.momentCount = names.count
            return stack
        } + [FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                              nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Sunset"])]
        MomentsChainStub.install { to, data in
            for stack in stacks { if let answer = stack.answer(to, data) { return answer } }
            return nil
        }
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc())
        let sunset = try await directory.key(for: "sunset")
        XCTAssertEqual(sunset, MomentKey(factory: v2, id: 1), "c4's Sunset keeps the plain name")
        let c4Link = try await directory.link(for: MomentKey(factory: v2, id: 1))
        XCTAssertEqual(c4Link?.url.absoluteString, "https://dyorhq.fun/moments/sunset")
        let late = MomentKey(factory: MomentLink.Cohort.c3.factory, id: 2)
        let lateLink = try await directory.link(for: late)
        XCTAssertNil(lateLink, "a Moment past cohort 3's named count gets no name")
        XCTAssertEqual(MomentLink(key: late)?.url.absoluteString, "https://dyorhq.fun/moments/2", "it shares its id link")
        let second = try await directory.key(for: "sunset-2")
        XCTAssertNil(second)
        let nature = try await directory.key(for: "nature")
        XCTAssertEqual(nature, MomentKey(factory: MomentLink.Cohort.c3.factory, id: 1))
    }
}
