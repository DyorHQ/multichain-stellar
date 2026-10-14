import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DyorKit

/// The app's one image pipeline: one download per picture for every size, sizes decoded from the bytes already fetched
/// or the thumbnail kept on the phone, what can't change kept for a week and anything else for an hour (shown at once
/// either way), a picture its sources say is gone forgotten (by what each host's answer means), every check on the bytes
/// kept, a load every view left cancelled unless a trusted download is under way (security audit 2026-09-26, RI-5) — and
/// started again for a view that came back if that download fails — and an erase that keeps nothing. A list-sized
/// thumbnail of an unchecked picture in DyorHQ's write-once bucket comes from Storage's resized copy at its size, the
/// original after it; a board warms its latest next rows from DyorHQ's hosts and the gateways only.
///
/// Where a test waits on the pipeline, it waits on gates it opens (`TestGate`) or polls (`eventually`, `settled`), so no
/// assertion rests on how fast a busy machine runs.
@MainActor
final class ImagePipelineTests: XCTestCase {
    private var folders: [URL] = []
    private var pipelines: [ImagePipeline] = []

    override func tearDown() async throws {
        // A background write still landing after the test is refused, and brings no folder back (`ImageDiskCache.store`).
        for pipe in pipelines { pipe.epoch.advance() }
        pipelines = []
        for folder in folders { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        folders = []
    }

    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-pipeline-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("remote-images-v1", isDirectory: true)
        folders.append(folder)
        return folder
    }

    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"
    private let bucketURL = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/logo.jpg")!
    private let avatarURL = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/avatars/0x6115caf237026b45b037191b20056d1e4afaffa3/avatar.jpg?v=1")!
    private let strangerURL = URL(string: "https://news.example/photo.jpg")!
    /// A CID on DyorHQ's gateway: content-addressed, so never resized — every size comes from its one download.
    private var gatewayURL: URL { URL(string: MomentsMath.ipfsGateways[0] + cid)! }

    /// Storage's resized copy of `url` at `width` (`ImageSourcePolicy.renderURL`).
    private func render(_ url: URL, _ width: Int) -> URL { ImageSourcePolicy.dyorhq.renderURL(url, width: width)! }

    /// A pipeline over `host`. The hedge is long unless a test is about it, so a source answering at once is never
    /// joined by the next on a slow machine.
    private func pipeline(_ host: FakeImageHost, folder: URL?, clock: TestClock = TestClock(), hedge: Duration = .seconds(30),
                          metered: Bool = false) -> ImagePipeline {
        let pipe = ImagePipeline(policy: .dyorhq, directory: folder, fetcher: host.fetcher, hedgeAfter: hedge, isMetered: { metered }, now: clock.read)
        pipelines.append(pipe)
        return pipe
    }

    private func image(_ outcome: ImagePipeline.Outcome, file: StaticString = #filePath, line: UInt = #line) -> CGImage? {
        if case .image(let image) = outcome { return image }
        XCTFail("no image: \(outcome)", file: file, line: line)
        return nil
    }

    /// Waits for the background disk writes to land (they run at utility priority, which a busy machine delays).
    private func settled(_ pipeline: ImagePipeline, count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if await pipeline.disk.count == count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let found = await pipeline.disk.count
        XCTAssertEqual(found, count, "files on disk", file: file, line: line)
    }

    private let large = RemoteMedia.caps(forThumbnail: ImageSizeBucket.largest)

    // MARK: One download, every size

    /// Two views of one picture that is never resized (a CID) at two sizes, at once: one download, each size decoded from
    /// it at its bucket.
    func testOneDownloadServesEverySizeAskedAtOnce() async throws {
        let host = FakeImageHost()
        host.reply(gatewayURL, .image(try Self.jpeg(width: 1000, height: 1000), respondAfter: .milliseconds(50)))
        let pipe = pipeline(host, folder: folder())
        let sources = [RemoteImageSource(url: gatewayURL)]
        async let small = pipe.fetch(sources, bucket: 96, caps: large)
        async let card = pipe.fetch(sources, bucket: 512, caps: large)
        let (a, b) = await (small, card)
        XCTAssertEqual(image(a)?.width, 96)
        XCTAssertEqual(image(b)?.width, 512)
        XCTAssertEqual(host.requests, [gatewayURL], "fetched once for both sizes")
        XCTAssertEqual(pipe.memoryImage(sources, bucket: 96)?.image.width, 96)
        XCTAssertEqual(pipe.memoryImage(sources, bucket: 192)?.image.width, 512, "a larger size answers for a smaller one")
        XCTAssertEqual(pipe.memoryImage(sources, bucket: 1200)?.exact, false, "a smaller one only stands in")
        await settled(pipe, count: 2)
    }

    /// Another size asked later comes from the bytes this session already fetched: no second download.
    func testAnotherSizeLaterComesFromTheBytesAlreadyFetched() async throws {
        let host = FakeImageHost()
        host.reply(gatewayURL, .image(try Self.jpeg(width: 1600, height: 1200)))
        let pipe = pipeline(host, folder: nil)
        let sources = [RemoteImageSource(url: gatewayURL)]
        _ = image(await pipe.fetch(sources, bucket: 192, caps: large))
        let headerFound = await pipe.stored(sources, bucket: 1200, caps: large)
        let header = try XCTUnwrap(headerFound)
        XCTAssertTrue(header.exact)
        XCTAssertTrue(header.fresh)
        XCTAssertEqual(header.image.height, 1200, "covers the bucket: the shorter side reaches it")
        XCTAssertEqual(header.image.width, 1600)
        XCTAssertEqual(host.requests.count, 1)
    }

    /// After a relaunch (a new pipeline over the same folder) a picture seen once paints from the phone with no network:
    /// its size, a smaller one decoded down from it, and a larger size shown from it while that size loads. (The card came
    /// from Storage's resized copy at its size.)
    func testAPictureSeenOnceNeedsNoNetworkAfterARelaunch() async throws {
        let folder = folder()
        let host = FakeImageHost()
        host.reply(render(bucketURL, 512), .image(try Self.jpeg(width: 512, height: 512)))
        let first = pipeline(host, folder: folder)
        let sources = [RemoteImageSource(url: bucketURL)]
        _ = image(await first.fetch(sources, bucket: 512, caps: large))
        await settled(first, count: 1)

        let relaunched = pipeline(host, folder: folder)
        XCTAssertNil(relaunched.memoryImage(sources, bucket: 512), "nothing in memory after a relaunch")
        let cardFound = await relaunched.stored(sources, bucket: 512, caps: large)
        let card = try XCTUnwrap(cardFound)
        XCTAssertTrue(card.exact && card.fresh)
        XCTAssertEqual(card.image.width, 512)
        XCTAssertEqual(relaunched.memoryImage(sources, bucket: 192)?.image.width, 512, "in memory, the larger one answers")
        let again = pipeline(host, folder: folder)
        let rowFound = await again.stored(sources, bucket: 192, caps: large)
        let row = try XCTUnwrap(rowFound)
        XCTAssertTrue(row.exact)
        XCTAssertEqual(row.image.width, 192, "decoded down from the kept 512")
        await settled(again, count: 2) // the 192 is kept too
        let headerFound = await pipeline(host, folder: folder).stored(sources, bucket: 1200, caps: large)
        let header = try XCTUnwrap(headerFound)
        XCTAssertFalse(header.exact, "a smaller one stands in while the header's size loads")
        XCTAssertEqual(host.requests, [render(bucketURL, 512)], "no network for any of it")
    }

    /// A picture that can't change (the write-once bucket, a CID) stays fresh for a week from when it was stored — not
    /// from when it was last read, so a picture viewed often still goes stale and a takedown reaches it; any other (an
    /// avatar) for an hour. Past that it still shows at once (`fresh` false), and the network is asked behind it.
    func testImmutableForAWeekMutableForAnHour() async throws {
        let folder = folder()
        let clock = TestClock()
        let host = FakeImageHost()
        let jpeg = try Self.jpeg(width: 300, height: 300)
        host.reply(render(bucketURL, 192), .image(jpeg))
        host.reply(avatarURL, .image(jpeg))
        let first = pipeline(host, folder: folder, clock: clock)
        let logo = [RemoteImageSource(url: bucketURL)], avatar = [RemoteImageSource(url: avatarURL)]
        _ = image(await first.fetch(logo, bucket: 192, caps: large))
        _ = image(await first.fetch(avatar, bucket: 192, caps: large))
        await settled(first, count: 2)
        XCTAssertEqual(host.requests, [render(bucketURL, 192), avatarURL], "an avatar is read from its original")
        XCTAssertEqual(first.lifetime(logo), ImagePipeline.immutableLifetime)
        XCTAssertEqual(first.lifetime(avatar), ImagePipeline.mutableLifetime)
        XCTAssertEqual(ImagePipeline.immutableLifetime, 7 * 86_400)
        XCTAssertEqual(ImagePipeline.mutableLifetime, 3_600)

        clock.advance(2 * 3_600)
        XCTAssertEqual(first.memoryImage(logo, bucket: 192)?.fresh, true)
        XCTAssertEqual(first.memoryImage(avatar, bucket: 192)?.fresh, false)
        let relaunched = pipeline(host, folder: folder, clock: clock)
        let keptLogoFound = await relaunched.stored(logo, bucket: 192, caps: large) // a read: the file's last use moves on
        let keptLogo = try XCTUnwrap(keptLogoFound)
        let keptAvatarFound = await relaunched.stored(avatar, bucket: 192, caps: large)
        let keptAvatar = try XCTUnwrap(keptAvatarFound)
        XCTAssertTrue(keptLogo.fresh, "immutable: no network")
        XCTAssertFalse(keptAvatar.fresh, "mutable, an hour on: shown, and asked again")

        // A week and an hour after it was stored, 6 days 23 hours after it was last read.
        clock.advance(7 * 86_400 - 3_600)
        let weekOnFound = await pipeline(host, folder: folder, clock: clock).stored(logo, bucket: 192, caps: large)
        let weekOn = try XCTUnwrap(weekOnFound)
        XCTAssertFalse(weekOn.fresh, "a week on, even an immutable picture is asked about again (a takedown)")
        XCTAssertEqual(host.requests.count, 2)
    }

    /// A stale picture is replaced (and kept fresh again) when its source answers, and stays when the source can't be
    /// reached; a picture every source says is gone is taken out of memory and off the disk.
    func testAStalePictureIsRefreshedKeptOrForgotten() async throws {
        let folder = folder()
        let clock = TestClock()
        let host = FakeImageHost()
        host.reply(avatarURL, .image(try Self.jpeg(width: 300, height: 300)))
        let pipe = pipeline(host, folder: folder, clock: clock)
        let avatar = [RemoteImageSource(url: avatarURL)]
        _ = image(await pipe.fetch(avatar, bucket: 192, caps: large))
        await settled(pipe, count: 1)
        XCTAssertEqual(host.requests, [avatarURL])

        clock.advance(2 * 3_600)
        host.reply(avatarURL, .status(503))
        guard case .failed = await pipe.fetch(avatar, bucket: 192, caps: large) else { return XCTFail("unreachable is a failure") }
        XCTAssertEqual(host.requests.count, 2)
        XCTAssertNotNil(pipe.memoryImage(avatar, bucket: 192), "the copy stays")
        let count = await pipe.disk.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(pipe.failedLately(avatar, caps: large), "not asked again for a minute")
        XCTAssertEqual(pipe.retryAfter(avatar, caps: large) ?? 0, 60, accuracy: 0.001)
        guard case .failed = await pipe.fetch(avatar, bucket: 192, caps: large) else { return XCTFail() }
        XCTAssertEqual(host.requests.count, 2, "the miss wasn't asked again")

        clock.advance(61)
        XCTAssertNil(pipe.retryAfter(avatar, caps: large))
        host.reply(avatarURL, .image(try Self.jpeg(width: 200, height: 200)))
        let refreshed = image(await pipe.fetch(avatar, bucket: 192, caps: large))
        XCTAssertEqual(refreshed?.width, 192)
        XCTAssertEqual(pipe.memoryImage(avatar, bucket: 192)?.fresh, true)

        clock.advance(2 * 3_600)
        host.reply(avatarURL, .status(404))
        guard case .gone = await pipe.fetch(avatar, bucket: 192, caps: large) else { return XCTFail("every source said it's gone") }
        XCTAssertNil(pipe.memoryImage(avatar, bucket: 192))
        await settled(pipe, count: 0)
        // A write of the earlier copy that lands only now is refused: it was fetched before the picture was gone.
        let earlier = try XCTUnwrap(ImageDiskCache.encode(try XCTUnwrap(refreshed)))
        let pictureKey = ImagePipeline.key(avatar)
        await pipe.disk.store(earlier, key: pictureKey, bucket: 192, storedAt: clock.now - 60, epoch: pipe.epoch.value)
        let late = await pipe.disk.count
        XCTAssertEqual(late, 0)
        await pipe.disk.store(earlier, key: pictureKey, bucket: 192, storedAt: clock.now, epoch: pipe.epoch.value)
        let after = await pipe.disk.count
        XCTAssertEqual(after, 1, "one fetched since is kept")
    }

    /// A refusal that says nothing of whether the picture exists — a 403 (bot protection, a rate limit, a filtering
    /// proxy), a 400 from a host that isn't DyorHQ's, a 429, a 5xx — keeps the copy shown; only a 404 or 410 from a
    /// stranger's host forgets it (`ImageSourcePolicy.saysGone`).
    func testARefusalThatSaysNothingKeepsThePicture() async throws {
        let folder = folder()
        let clock = TestClock()
        let host = FakeImageHost()
        host.reply(strangerURL, .image(try Self.jpeg(width: 300, height: 300)))
        let pipe = pipeline(host, folder: folder, clock: clock)
        let news = [RemoteImageSource(url: strangerURL)]
        let small = RemoteMedia.caps(forThumbnail: 192)
        _ = image(await pipe.fetch(news, bucket: 192, caps: small))
        await settled(pipe, count: 1)
        for status in [403, 400, 429, 503] {
            clock.advance(2 * 3_600)
            host.reply(strangerURL, .status(status))
            guard case .failed = await pipe.fetch(news, bucket: 192, caps: small) else { return XCTFail("\(status) says nothing") }
            XCTAssertNotNil(pipe.memoryImage(news, bucket: 192), "\(status): the copy stays")
            let kept = await pipe.disk.count
            XCTAssertEqual(kept, 1, "\(status)")
        }
        clock.advance(2 * 3_600)
        host.reply(strangerURL, .status(404))
        guard case .gone = await pipe.fetch(news, bucket: 192, caps: small) else { return XCTFail("a 404 says it's gone") }
        XCTAssertNil(pipe.memoryImage(news, bucket: 192))
        await settled(pipe, count: 0)
    }

    // MARK: Every check kept

    /// A source whose bytes don't hash to its keccak (a swapped mirror) falls through to the next — and a picture loaded
    /// under a hash check is kept apart from the same link without one.
    func testAHashMismatchFallsThroughToTheNextSource() async throws {
        let host = FakeImageHost()
        let jpeg = try Self.jpeg(width: 200, height: 200)
        let gateway = URL(string: MomentsMath.ipfsGateways[0] + cid)!
        host.reply(bucketURL, .image(jpeg))
        host.reply(gateway, .image(try Self.jpeg(width: 120, height: 120)))
        let pipe = pipeline(host, folder: nil)
        let checked = [RemoteImageSource(url: bucketURL, keccak: Data(repeating: 0xAB, count: 32)), RemoteImageSource(url: gateway)]
        let fellThrough = await pipe.fetch(checked, bucket: 96, caps: large)
        XCTAssertEqual(image(fellThrough)?.width, 96)
        XCTAssertEqual(host.requests, [bucketURL, gateway])
        XCTAssertNil(pipe.memoryImage([RemoteImageSource(url: bucketURL)], bucket: 96), "the unchecked link has its own entry")
        XCTAssertNotEqual(ImagePipeline.key(checked), ImagePipeline.key([RemoteImageSource(url: bucketURL), RemoteImageSource(url: gateway)]))

        // The right hash: the mirror counts.
        let good = [RemoteImageSource(url: bucketURL, keccak: Keccak.hash256(jpeg)), RemoteImageSource(url: gateway)]
        let mirrored = await pipe.fetch(good, bucket: 96, caps: large)
        XCTAssertEqual(image(mirrored)?.width, 96)
        XCTAssertEqual(host.requests.count, 3)
    }

    /// Bytes that are no image (an SVG, an HTML page), or over the caps, are refused like a failed source; nothing is
    /// kept, and the picture isn't asked for again for a minute.
    func testBytesThatAreNoImageOrTooLargeAreRefused() async throws {
        let host = FakeImageHost()
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64"/></svg>"#.utf8)
        host.reply(strangerURL, .image(svg))
        let folder = folder()
        let pipe = pipeline(host, folder: folder)
        let sources = [RemoteImageSource(url: strangerURL)]
        let small = RemoteMedia.caps(forThumbnail: 96)
        guard case .failed = await pipe.fetch(sources, bucket: 96, caps: small) else { return XCTFail("an SVG is no image") }
        XCTAssertTrue(pipe.failedLately(sources, caps: small))
        XCTAssertFalse(pipe.failedLately(sources, caps: large), "a miss under one caps says nothing of the other")

        host.reply(bucketURL, .image(try Self.jpeg(width: 2000, height: 2000)))
        let pixels = RemoteMedia.Caps(maxBytes: 10 * 1024 * 1024, maxSourcePixels: 1_000_000)
        guard case .failed = await pipe.fetch([RemoteImageSource(url: bucketURL)], bucket: 96, caps: pixels) else { return XCTFail("too many pixels") }
        try? await Task.sleep(for: .milliseconds(100))
        let count = await pipe.disk.count
        XCTAssertEqual(count, 0)
    }

    // MARK: Views that leave

    /// Every view leaves before the bytes are in: a download from a stranger's host is cancelled (RI-5), and so is one
    /// from DyorHQ's host still silent; one from DyorHQ's host already sending its bytes finishes into the cache. (At this
    /// list size, DyorHQ's host is asked for Storage's resized copy.)
    func testALoadEveryViewLeftIsCancelledUnlessATrustedDownloadIsUnderWay() async throws {
        let jpeg = try Self.jpeg(width: 400, height: 400)
        for (url, answers, kept) in [(strangerURL, true, false), (bucketURL, false, false), (bucketURL, true, true)] {
            let host = FakeImageHost(), finish = TestGate()
            let target = ImageSourcePolicy.dyorhq.renderURL(url, width: 192) ?? url
            host.reply(target, .image(jpeg, answer: answers ? .opened : TestGate(), finish: finish))
            let pipe = pipeline(host, folder: folder())
            let sources = [RemoteImageSource(url: url)]
            let view = Task { await pipe.fetch(sources, bucket: 192, caps: large) }
            await eventually("asked\(answers ? " and answered" : "")") { host.requests.count == 1 && host.answered.count == (answers ? 1 : 0) }
            view.cancel()
            guard case .failed = await view.value else { return XCTFail("a view that left gets nothing") }
            if kept {
                finish.open()
                await eventually("finished into the cache") { pipe.memoryImage(sources, bucket: 192) != nil }
                await settled(pipe, count: 1)
                XCTAssertEqual(host.cancelled, [], "\(url)")
            } else {
                await eventually("\(url) answers \(answers): cancelled") { host.cancelled == [target] }
                finish.open()
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertNil(pipe.memoryImage(sources, bucket: 192), "\(url) answers \(answers)")
            }
            XCTAssertFalse(pipe.failedLately(sources, caps: large), "leaving is no miss")
        }
    }

    /// Two views wait on one download from a stranger's host: one leaving cancels nothing — the other still gets the
    /// picture — and the last one out cancels it (RI-5).
    func testALoadGoesOnForTheViewsStillWaiting() async throws {
        let host = FakeImageHost(), finish = TestGate()
        let jpeg = try Self.jpeg(width: 400, height: 400)
        host.reply(strangerURL, .image(jpeg, finish: finish))
        let pipe = pipeline(host, folder: nil)
        let sources = [RemoteImageSource(url: strangerURL)]
        let small = RemoteMedia.caps(forThumbnail: 192)
        let a = Task { await pipe.fetch(sources, bucket: 192, caps: small) }
        let b = Task { await pipe.fetch(sources, bucket: 192, caps: small) }
        await eventually("answered") { host.answered.count == 1 }
        a.cancel()
        guard case .failed = await a.value else { return XCTFail("the view that left gets nothing") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.cancelled, [], "another view still waits")
        finish.open()
        let stayed = await b.value
        XCTAssertEqual(image(stayed)?.width, 192)
        XCTAssertEqual(host.requests.count, 1, "one download for both")

        let other = URL(string: "https://news.example/other.jpg")!
        host.reply(other, .image(jpeg, finish: TestGate()))
        let c = Task { await pipe.fetch([RemoteImageSource(url: other)], bucket: 192, caps: small) }
        let d = Task { await pipe.fetch([RemoteImageSource(url: other)], bucket: 192, caps: small) }
        await eventually("answered") { host.answered.count == 2 }
        c.cancel()
        _ = await c.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.cancelled, [])
        d.cancel()
        _ = await d.value
        await eventually("the last view out cancels it") { host.cancelled == [other] }
    }

    /// A view that left while a trusted download was sending its bytes, and comes back (scrolled away and back), joins
    /// that download instead of starting another.
    func testAViewThatComesBackJoinsTheDownloadUnderWay() async throws {
        let host = FakeImageHost(), finish = TestGate()
        host.reply(render(bucketURL, 192), .image(try Self.jpeg(width: 400, height: 400), finish: finish))
        let pipe = pipeline(host, folder: nil)
        let sources = [RemoteImageSource(url: bucketURL)]
        let first = Task { await pipe.fetch(sources, bucket: 192, caps: large) }
        await eventually("sending") { host.answered.count == 1 }
        first.cancel()
        _ = await first.value
        let back = Task { await pipe.fetch(sources, bucket: 192, caps: large) }
        try await Task.sleep(for: .milliseconds(20)) // the view comes back (it runs before this test does again)
        finish.open()
        let cameBack = await back.value
        XCTAssertEqual(image(cameBack)?.width, 192)
        XCTAssertEqual(host.requests.count, 1, "one download")
    }

    /// A view that came back to a load left to a trusted download is answered with the picture when that download fails
    /// (a mirror whose bytes don't hash): the load starts again for it and reaches the gateway — never `.failed` with a
    /// source not asked.
    func testAViewThatCameBackIsAnsweredWhenTheDownloadItWasLeftToFails() async throws {
        let host = FakeImageHost(), finish = TestGate()
        let photo = try Self.jpeg(width: 200, height: 200)
        host.reply(bucketURL, .image(try Self.jpeg(width: 120, height: 120), finish: finish))
        host.reply(gatewayURL, .image(photo))
        let pipe = pipeline(host, folder: nil, hedge: .seconds(30))
        let sources = [RemoteImageSource(url: bucketURL, keccak: Keccak.hash256(photo)), RemoteImageSource(url: gatewayURL)]
        let first = Task { await pipe.fetch(sources, bucket: 192, caps: large) }
        await eventually("the mirror is sending") { host.answered == [bucketURL] }
        first.cancel()
        _ = await first.value
        let back = Task { await pipe.fetch(sources, bucket: 192, caps: large) }
        try await Task.sleep(for: .milliseconds(20)) // the view comes back
        finish.open()
        let cameBack = await back.value
        XCTAssertEqual(image(cameBack)?.width, 192, "the gateway was asked for the view that came back")
        XCTAssertEqual(host.requests, [bucketURL, bucketURL, gatewayURL])
        XCTAssertFalse(pipe.failedLately(sources, caps: large))
    }

    // MARK: Racing

    /// A picture's sources are raced where the policy allows: a silent mirror (hash-checked, so never resized) is joined by
    /// the gateway after the hedge. A stranger's list is not raced: each source in turn.
    func testSilentSourcesAreJoinedOnlyWhereThePolicyAllows() async throws {
        let host = FakeImageHost()
        let gateway = URL(string: MomentsMath.ipfsGateways[0] + cid)!
        let photo = try Self.jpeg(width: 200, height: 200)
        host.reply(bucketURL, .image(photo, answer: TestGate()))
        host.reply(gateway, .image(photo))
        let pipe = pipeline(host, folder: nil, hedge: .milliseconds(50))
        _ = image(await pipe.fetch([RemoteImageSource(url: bucketURL, keccak: Keccak.hash256(photo)), RemoteImageSource(url: gateway)], bucket: 96, caps: large))
        XCTAssertEqual(host.requests, [bucketURL, gateway], "the gateway answered while the mirror was silent")

        let other = URL(string: "https://cdn.example/b.png")!
        host.reply(strangerURL, .image(try Self.jpeg(width: 200, height: 200), respondAfter: .milliseconds(400)))
        host.reply(other, .image(try Self.jpeg(width: 200, height: 200)))
        _ = image(await pipe.fetch([RemoteImageSource(url: strangerURL), RemoteImageSource(url: other)], bucket: 96, caps: large))
        XCTAssertEqual(host.requests.suffix(1), [strangerURL], "the first answered, so the second was never asked")
    }

    /// The hedge counts from when a request goes out, not while it waits for a download slot behind other pictures: a
    /// Moment's mirror queued longer than the hedge isn't joined by its gateway, which would download the same picture
    /// beside it once both got slots.
    func testAQueuedRequestIsNotHedged() async throws {
        let host = FakeImageHost()
        let slots = AsyncLimiter(1)
        host.slots = slots
        let photo = try Self.jpeg(width: 200, height: 200)
        host.reply(bucketURL, .image(photo))
        host.reply(gatewayURL, .image(photo))
        let pipe = pipeline(host, folder: nil, hedge: .milliseconds(200))
        // Another picture holds the only slot.
        let holding = TestGate(), held = TestGate()
        let holder = Task { try await slots.run { holding.open(); try await held.wait() } }
        await eventually("the slot is taken") { holding.isOpen }
        let sources = [RemoteImageSource(url: bucketURL, keccak: Keccak.hash256(photo)), RemoteImageSource(url: gatewayURL)]
        let view = Task { await pipe.fetch(sources, bucket: 96, caps: large) }
        await eventually("the mirror waits its turn") { await slots.queued == 1 }
        try await Task.sleep(for: .milliseconds(600)) // three hedges' time in the queue
        let queued = await slots.queued
        XCTAssertEqual(queued, 1, "no hedge while it waits: the gateway isn't queued beside it")
        held.open()
        _ = try await holder.value
        let queuedView = await view.value
        XCTAssertEqual(image(queuedView)?.width, 96)
        XCTAssertEqual(host.requests, [bucketURL], "the mirror answered once sent: the gateway was never asked")
    }

    /// Each source is asked with its host's timeout: Storage's resized copy, on DyorHQ's host, as the original.
    func testEachSourceIsAskedWithItsHostsTimeout() async throws {
        let host = FakeImageHost()
        let gateway = URL(string: MomentsMath.ipfsGateways[0] + cid)!
        for url in [render(bucketURL, 96), bucketURL, gateway, strangerURL] { host.reply(url, .status(404)) }
        let pipe = pipeline(host, folder: nil)
        for url in [bucketURL, gateway, strangerURL] { _ = await pipe.fetch([RemoteImageSource(url: url)], bucket: 96, caps: large) }
        XCTAssertEqual(host.requests, [render(bucketURL, 96), bucketURL, gateway, strangerURL])
        XCTAssertEqual(host.timeouts, [8, 8, 12, 15])
        XCTAssertEqual(host.maxBytes, [RemoteMedia.smallImageBytes, large.maxBytes, large.maxBytes, large.maxBytes],
                       "a resized copy under the small byte cap, so it waits in the small downloads' slots")
    }

    // MARK: Erasing

    /// An erase empties memory, misses and the disk at once; a load under way still answers its view, but nothing it
    /// finishes afterwards is kept.
    func testAnEraseKeepsNothingALoadFinishesAfterIt() async throws {
        let folder = folder()
        let host = FakeImageHost()
        let jpeg = try Self.jpeg(width: 300, height: 300)
        host.reply(bucketURL, .image(jpeg))
        host.reply(strangerURL, .status(500))
        let pipe = pipeline(host, folder: folder)
        let kept = [RemoteImageSource(url: bucketURL)], missed = [RemoteImageSource(url: strangerURL)]
        _ = image(await pipe.fetch(kept, bucket: 1200, caps: large))
        _ = await pipe.fetch(missed, bucket: 192, caps: large)
        await settled(pipe, count: 1)
        XCTAssertTrue(pipe.failedLately(missed, caps: large))

        let late = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/late.jpg")!
        let finish = TestGate()
        host.reply(late, .image(jpeg, finish: finish))
        let view = Task { await pipe.fetch([RemoteImageSource(url: late)], bucket: 1200, caps: large) }
        await eventually("sending") { host.answered.contains(late) }
        pipe.removeAll()
        XCTAssertNil(pipe.memoryImage(kept, bucket: 1200))
        XCTAssertFalse(pipe.failedLately(missed, caps: large))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the folder is gone at once")
        finish.open()
        let answered = await view.value
        XCTAssertNotNil(image(answered), "the view still waiting gets its picture")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(pipe.memoryImage([RemoteImageSource(url: late)], bucket: 1200), "but nothing is kept")
        let stored = await pipe.stored([RemoteImageSource(url: late)], bucket: 1200, caps: large)
        XCTAssertNil(stored)
        let count = await pipe.disk.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no folder brought back")
    }

    /// A warm-up still waiting for its turn when the caches are erased is cancelled: it asks nothing and keeps nothing
    /// once its turn would have come. One asked for after the erase works as before.
    func testAWarmUpQueuedWhenTheCachesAreErasedKeepsNothing() async throws {
        let folder = folder()
        let host = FakeImageHost()
        host.reply(render(bucketURL, 192), .image(try Self.jpeg(width: 192, height: 192)))
        let pipe = pipeline(host, folder: folder)
        let logo = [RemoteImageSource(url: bucketURL)]
        let small = RemoteMedia.caps(forThumbnail: 192)
        // The app-wide warm-up slots are taken (another board's pictures still loading).
        let taken = Tally(), held = TestGate()
        let holders = (0..<2).map { _ in Task { try await ImagePipeline.prefetches.run { taken.add(); try await held.wait() } } }
        await eventually("both warm-up slots taken") { taken.value == 2 }
        pipe.prefetch(logo, bucket: 192, caps: small)
        await eventually("queued behind them") { await ImagePipeline.prefetches.queued == 1 }
        pipe.removeAll()
        XCTAssertEqual(pipe.warming, 0, "cancelled")
        held.open()
        for holder in holders { _ = try await holder.value }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.requests, [], "nothing asked after the erase")
        XCTAssertNil(pipe.memoryImage(logo, bucket: 192))
        let count = await pipe.disk.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        pipe.prefetch(logo, bucket: 192, caps: small)
        await settled(pipe, count: 1)
        XCTAssertEqual(host.requests, [render(bucketURL, 192)])
    }

    // MARK: Storage's resized copies

    /// A list-sized thumbnail of an unchecked picture in DyorHQ's write-once bucket — a launch logo — comes from Storage's
    /// resized copy at its size bucket alone; a larger size asks its own; the page header's size, an avatar (uploaded
    /// over its own path) and a hash-checked mirror at any size load the original.
    func testListSizesOfAnUncheckedBucketPictureComeResized() async throws {
        let host = FakeImageHost()
        host.reply(render(bucketURL, 96), .image(try Self.jpeg(width: 96, height: 96)))
        host.reply(render(bucketURL, 512), .image(try Self.jpeg(width: 512, height: 512)))
        host.reply(bucketURL, .image(try Self.jpeg(width: 1500, height: 1500)))
        host.reply(avatarURL, .image(try Self.jpeg(width: 400, height: 400)))
        let pipe = pipeline(host, folder: nil)
        let logo = [RemoteImageSource(url: bucketURL)]
        let row = await pipe.fetch(logo, bucket: 96, caps: RemoteMedia.caps(forThumbnail: 96))
        XCTAssertEqual(image(row)?.width, 96)
        XCTAssertEqual(host.requests, [render(bucketURL, 96)], "a few KB, not the whole file")
        let card = await pipe.fetch(logo, bucket: 512, caps: large)
        XCTAssertEqual(image(card)?.width, 512)
        XCTAssertEqual(host.requests.last, render(bucketURL, 512), "a larger size isn't decoded from the 96 px copy")
        let header = await pipe.fetch(logo, bucket: 1200, caps: large)
        XCTAssertEqual(image(header)?.width, 1200)
        XCTAssertEqual(host.requests.last, bucketURL, "the page header's size: the original")
        let avatar = await pipe.fetch([RemoteImageSource(url: avatarURL)], bucket: 192, caps: large)
        XCTAssertEqual(image(avatar)?.width, 192)
        XCTAssertEqual(host.requests.last, avatarURL, "an avatar: its original")

        let photo = try Self.jpeg(width: 800, height: 800)
        host.reply(bucketURL, .image(photo))
        let mirror = [RemoteImageSource(url: bucketURL, keccak: Keccak.hash256(photo))]
        let checked = await pipe.fetch(mirror, bucket: 96, caps: large)
        XCTAssertEqual(image(checked)?.width, 96)
        XCTAssertEqual(host.requests.last, bucketURL, "hash-checked: the original, whatever the size")
        XCTAssertEqual(host.requests.count, 5)
    }

    /// Storage's resized copy answers for its size and smaller ones — from memory, and decoded down from the phone after a
    /// relaunch — never for a larger size, which it only stands in for while that size loads (the bytes fetched for it are
    /// not decoded up into one).
    func testAResizedCopyAnswersOnlyForItsSizeAndSmaller() async throws {
        let folder = folder()
        let host = FakeImageHost()
        host.reply(render(bucketURL, 384), .image(try Self.jpeg(width: 384, height: 384)))
        let pipe = pipeline(host, folder: folder)
        let logo = [RemoteImageSource(url: bucketURL)]
        _ = image(await pipe.fetch(logo, bucket: 384, caps: large))
        XCTAssertEqual(pipe.memoryImage(logo, bucket: 192)?.exact, true)
        let largerFound = await pipe.stored(logo, bucket: 768, caps: large)
        let larger = try XCTUnwrap(largerFound)
        XCTAssertFalse(larger.exact, "the 384 px copy only stands in for 768")
        XCTAssertEqual(larger.image.width, 384)
        await settled(pipe, count: 1)

        let relaunched = pipeline(host, folder: folder)
        let smallerFound = await relaunched.stored(logo, bucket: 192, caps: large)
        let smaller = try XCTUnwrap(smallerFound)
        XCTAssertTrue(smaller.exact)
        XCTAssertEqual(smaller.image.width, 192, "decoded down from the kept copy")
        let headerFound = await relaunched.stored(logo, bucket: 1200, caps: large)
        let header = try XCTUnwrap(headerFound)
        XCTAssertFalse(header.exact)
        XCTAssertEqual(host.requests.count, 1)
        await settled(relaunched, count: 2) // the 192 is kept too
    }

    /// When the resized copy fails, the original answers (right away, not after the hedge) and nothing is remembered as a
    /// miss; the picture is gone only when the original says so too, and a miss when both fail.
    func testWhenTheResizedCopyFailsTheOriginalAnswers() async throws {
        let host = FakeImageHost()
        host.reply(render(bucketURL, 192), .status(503))
        host.reply(bucketURL, .image(try Self.jpeg(width: 500, height: 500)))
        let pipe = pipeline(host, folder: nil, hedge: .seconds(30))
        let logo = [RemoteImageSource(url: bucketURL)]
        let answered = await pipe.fetch(logo, bucket: 192, caps: large)
        XCTAssertEqual(image(answered)?.width, 192, "the failure started the original at once, long before the hedge")
        XCTAssertEqual(host.requests, [render(bucketURL, 192), bucketURL])
        XCTAssertFalse(pipe.failedLately(logo, caps: large))

        let other = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/other.jpg")!
        host.reply(render(other, 192), .status(404))
        host.reply(other, .status(503))
        guard case .failed = await pipe.fetch([RemoteImageSource(url: other)], bucket: 192, caps: large) else { return XCTFail("the original may still be there") }
        XCTAssertTrue(pipe.failedLately([RemoteImageSource(url: other)], caps: large), "both failed: a miss")
        let gone = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/gone.jpg")!
        host.reply(render(gone, 192), .status(400))
        host.reply(gone, .status(404))
        guard case .gone = await pipe.fetch([RemoteImageSource(url: gone)], bucket: 192, caps: large) else { return XCTFail("both said it isn't there") }
    }

    /// A landscape picture's resized copy at a bucket's width falls short of the bucket in height: it is asked again at
    /// the width that covers it, and the first copy kept when that fails. A square or a portrait one is asked once.
    func testALandscapeCopyIsAskedAgainWideEnoughToCoverItsSize() async throws {
        let host = FakeImageHost()
        host.reply(render(bucketURL, 96), .image(try Self.jpeg(width: 96, height: 72)))
        host.reply(render(bucketURL, 128), .image(try Self.jpeg(width: 128, height: 96)))
        let pipe = pipeline(host, folder: nil)
        let wide = image(await pipe.fetch([RemoteImageSource(url: bucketURL)], bucket: 96, caps: large))
        XCTAssertEqual(wide?.height, 96, "covers a 96 px square")
        XCTAssertEqual(wide?.width, 128)
        XCTAssertEqual(host.requests, [render(bucketURL, 96), render(bucketURL, 128)])

        let other = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/wide.jpg")!
        host.reply(render(other, 96), .image(try Self.jpeg(width: 96, height: 72)))
        host.reply(render(other, 128), .status(503))
        let first = await pipe.fetch([RemoteImageSource(url: other)], bucket: 96, caps: large)
        XCTAssertEqual(image(first)?.height, 72, "the first copy, when the wider one fails")

        let tall = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/tall.jpg")!
        host.reply(render(tall, 96), .image(try Self.jpeg(width: 96, height: 125)))
        _ = image(await pipe.fetch([RemoteImageSource(url: tall)], bucket: 96, caps: large))
        XCTAssertEqual(host.requests.filter { $0.path.hasSuffix("tall.jpg") }.count, 1, "a portrait copy covers at the bucket's width")
    }

    /// A smaller size joins a resized copy under way at a larger one (or the original's load); a larger size never joins
    /// a smaller copy.
    func testASmallerSizeJoinsALargerCopyUnderWay() async throws {
        let host = FakeImageHost(), answer = TestGate()
        host.reply(render(bucketURL, 512), .image(try Self.jpeg(width: 512, height: 512), answer: answer))
        host.reply(render(bucketURL, 96), .image(try Self.jpeg(width: 96, height: 96)))
        let pipe = pipeline(host, folder: nil, hedge: .seconds(30))
        let logo = [RemoteImageSource(url: bucketURL)]
        let card = Task { await pipe.fetch(logo, bucket: 512, caps: large) }
        await eventually("the card's copy is asked") { host.requests.count == 1 }
        let row = Task { await pipe.fetch(logo, bucket: 96, caps: large) }
        try await Task.sleep(for: .milliseconds(20)) // the row joins (it runs before this test does again)
        answer.open()
        let rowAnswer = await row.value
        XCTAssertEqual(image(rowAnswer)?.width, 96)
        let cardAnswer = await card.value
        XCTAssertEqual(image(cardAnswer)?.width, 512)
        XCTAssertEqual(host.requests, [render(bucketURL, 512)], "one download for both")

        let other = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/other.jpg")!
        let smallAnswer = TestGate()
        host.reply(render(other, 96), .image(try Self.jpeg(width: 96, height: 96), answer: smallAnswer))
        host.reply(render(other, 512), .image(try Self.jpeg(width: 512, height: 512)))
        let smaller = Task { await pipe.fetch([RemoteImageSource(url: other)], bucket: 96, caps: large) }
        await eventually("the row's copy is asked") { host.requests.count == 2 }
        let larger = await pipe.fetch([RemoteImageSource(url: other)], bucket: 512, caps: large)
        XCTAssertEqual(image(larger)?.width, 512)
        smallAnswer.open()
        _ = await smaller.value
        XCTAssertEqual(host.requests.suffix(2), [render(other, 96), render(other, 512)], "the 96 px copy can't answer for 512")
    }

    // MARK: Pictures the app uploaded

    /// A picture the app just uploaded (a new avatar) is drawn from the bytes it sent, at every size, with no request;
    /// only for an unchecked source on DyorHQ's host, and only bytes that are an image.
    func testAPictureTheAppUploadedIsDrawnFromItsOwnBytes() async throws {
        let host = FakeImageHost() // no replies: any request would fail
        let pipe = pipeline(host, folder: nil)
        let jpeg = try Self.jpeg(width: 400, height: 400)
        let avatar = [RemoteImageSource(url: avatarURL)]
        pipe.seed(jpeg, for: avatar)
        let rowFound = await pipe.stored(avatar, bucket: 192, caps: RemoteMedia.caps(forThumbnail: 192))
        let row = try XCTUnwrap(rowFound)
        XCTAssertTrue(row.exact && row.fresh)
        XCTAssertEqual(row.image.width, 192)
        let headerAnswer = await pipe.fetch(avatar, bucket: 1200, caps: large)
        XCTAssertEqual(image(headerAnswer)?.width, 400, "every size, never scaled up")
        XCTAssertEqual(host.requests, [])

        let refused = [[RemoteImageSource(url: strangerURL)], [RemoteImageSource(url: bucketURL, keccak: Data(repeating: 1, count: 32))]]
        for sources in refused {
            pipe.seed(jpeg, for: sources)
            let found = await pipe.stored(sources, bucket: 192, caps: large)
            XCTAssertNil(found, "\(sources)")
        }
        let other = [RemoteImageSource(url: URL(string: avatarURL.absoluteString + "2")!)]
        pipe.seed(Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8), for: other)
        let svg = await pipe.stored(other, bucket: 192, caps: large)
        XCTAssertNil(svg, "no image")
    }

    // MARK: Warming a board's next rows

    /// A prefetch loads the picture into memory and onto the phone at the size its view will ask for, once however often
    /// it is asked; the view then needs no network. A picture already in memory is left alone.
    func testAPrefetchWarmsThePictureAheadOfItsView() async throws {
        let host = FakeImageHost()
        host.reply(render(bucketURL, 192), .image(try Self.jpeg(width: 192, height: 192), respondAfter: .milliseconds(50)))
        let pipe = pipeline(host, folder: folder(), hedge: .seconds(5))
        let logo = [RemoteImageSource(url: bucketURL)]
        let small = RemoteMedia.caps(forThumbnail: 192)
        pipe.prefetch(logo, bucket: 192, caps: small)
        pipe.prefetch(logo, bucket: 192, caps: small)
        await settled(pipe, count: 1)
        XCTAssertEqual(pipe.memoryImage(logo, bucket: 192)?.exact, true)
        XCTAssertEqual(host.requests, [render(bucketURL, 192)], "once")
        pipe.prefetch(logo, bucket: 192, caps: small)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.requests.count, 1, "in memory already: nothing to do")

        // After a relaunch, a prefetch decodes the kept copy into memory: no network.
        let relaunched = pipeline(host, folder: pipe.disk.directory)
        relaunched.prefetch(logo, bucket: 192, caps: small)
        await eventually("decoded from the phone") { relaunched.memoryImage(logo, bucket: 192) != nil }
        XCTAssertEqual(relaunched.memoryImage(logo, bucket: 192)?.exact, true)
        XCTAssertEqual(host.requests.count, 1)
    }

    /// No host but DyorHQ's and the app's gateways is asked for a picture nobody is looking at (RI-5): a prefetch of a
    /// stranger's picture, or of a list with one in it, does nothing.
    func testAPrefetchNeverAsksAStrangersHost() async throws {
        let host = FakeImageHost()
        host.reply(strangerURL, .image(try Self.jpeg(width: 200, height: 200)))
        host.reply(gatewayURL, .image(try Self.jpeg(width: 200, height: 200)))
        let pipe = pipeline(host, folder: nil)
        pipe.prefetch([RemoteImageSource(url: strangerURL)], bucket: 192, caps: large)
        pipe.prefetch([RemoteImageSource(url: gatewayURL), RemoteImageSource(url: strangerURL)], bucket: 192, caps: large)
        XCTAssertEqual(pipe.warming, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.requests, [])
        pipe.prefetch([RemoteImageSource(url: gatewayURL)], bucket: 192, caps: large)
        await eventually("warmed") { pipe.memoryImage([RemoteImageSource(url: gatewayURL)], bucket: 192) != nil }
        XCTAssertEqual(host.requests, [gatewayURL], "a gateway's CID may be warmed")
    }

    /// Only the latest `BoardPrefetch.ahead` warm-ups are kept: after a fling, one asked for earlier — a row the scroll
    /// passed — is dropped before it takes a slot, and one asked for again counts as asked for now.
    func testOnlyTheLatestWarmUpsAreKept() async throws {
        let host = FakeImageHost(), answer = TestGate()
        let jpeg = try Self.jpeg(width: 200, height: 200)
        let pictures = (0..<8).map { URL(string: MomentsMath.ipfsGateways[0] + cid + "/\($0).jpg")! }
        for url in pictures { host.reply(url, .image(jpeg, answer: answer)) }
        let pipe = pipeline(host, folder: nil)
        let taken = Tally(), held = TestGate()
        let holders = (0..<2).map { _ in Task { try await ImagePipeline.prefetches.run { taken.add(); try await held.wait() } } }
        await eventually("both warm-up slots taken") { taken.value == 2 }
        func warm(_ index: Int) { pipe.prefetch([RemoteImageSource(url: pictures[index])], bucket: 192, caps: large) }
        for index in 0..<7 { warm(index) }
        XCTAssertEqual(pipe.warming, BoardPrefetch.ahead, "the first dropped")
        warm(1) // asked again: now the latest
        warm(7) // 2 is the oldest left: dropped
        XCTAssertEqual(pipe.warming, BoardPrefetch.ahead)
        await eventually("the dropped ones left the queue") { await ImagePipeline.prefetches.queued == BoardPrefetch.ahead }
        held.open()
        for holder in holders { _ = try await holder.value }
        answer.open()
        await eventually("every warm-up ended") { pipe.warming == 0 }
        XCTAssertEqual(Set(host.requests), Set([1, 3, 4, 5, 6, 7].map { pictures[$0] }))
        XCTAssertEqual(host.requests.count, 6)
    }

    /// A warm-up that fails is no miss for the views — a card that scrolls in asks for itself — but isn't warmed again
    /// for a minute.
    func testAWarmUpThatFailsIsNoMissForTheViews() async throws {
        let host = FakeImageHost()
        host.reply(gatewayURL, .status(503))
        let pipe = pipeline(host, folder: nil)
        let moment = [RemoteImageSource(url: gatewayURL)]
        pipe.prefetch(moment, bucket: 192, caps: large)
        await eventually("the warm-up ended") { host.requests.count == 1 && pipe.warming == 0 }
        XCTAssertFalse(pipe.failedLately(moment, caps: large), "the card asks for itself")
        pipe.prefetch(moment, bucket: 192, caps: large)
        XCTAssertEqual(pipe.warming, 0, "not warmed again for a minute")
        host.reply(gatewayURL, .image(try Self.jpeg(width: 200, height: 200)))
        let viewAnswer = await pipe.fetch(moment, bucket: 192, caps: large)
        XCTAssertEqual(image(viewAnswer)?.width, 192)
        XCTAssertEqual(host.requests.count, 2)
    }

    /// On a network that costs by the byte (Low Data Mode, cellular), no whole original is warmed — its card loads it as
    /// it scrolls in — while a launch logo's resized copy still is.
    func testNoWholeOriginalIsWarmedOnAMeteredNetwork() async throws {
        let host = FakeImageHost()
        host.reply(gatewayURL, .image(try Self.jpeg(width: 200, height: 200)))
        host.reply(render(bucketURL, 192), .image(try Self.jpeg(width: 192, height: 192)))
        let pipe = pipeline(host, folder: nil, metered: true)
        pipe.prefetch([RemoteImageSource(url: gatewayURL)], bucket: 192, caps: large)
        XCTAssertEqual(pipe.warming, 0)
        pipe.prefetch([RemoteImageSource(url: bucketURL)], bucket: 192, caps: large)
        await eventually("the resized copy warmed") { pipe.memoryImage([RemoteImageSource(url: bucketURL)], bucket: 192) != nil }
        XCTAssertEqual(host.requests, [render(bucketURL, 192)])
        let viewAnswer = await pipe.fetch([RemoteImageSource(url: gatewayURL)], bucket: 192, caps: large)
        XCTAssertEqual(image(viewAnswer)?.width, 192, "its view asks")
    }

    /// A board warms the items after the one that came on screen: the next `ahead`, none past the end.
    func testABoardWarmsTheItemsAfterTheOneOnScreen() {
        struct Item: Identifiable { let id: Int }
        let items = (0..<10).map(Item.init)
        XCTAssertEqual(BoardPrefetch.ahead, 6)
        XCTAssertEqual(BoardPrefetch.following(0, in: items).map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(BoardPrefetch.following(6, in: items).map(\.id), [7, 8, 9])
        XCTAssertEqual(BoardPrefetch.following(9, in: items).map(\.id), [])
        XCTAssertEqual(BoardPrefetch.following(42, in: items).map(\.id), [], "not on the board")
    }

    // MARK: Fixtures

    /// An opaque JPEG of `width` × `height`.
    nonisolated static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// A count several tasks add to.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A stand-in network for the pipeline: a scripted answer per URL; the requests sent (with their timeouts and byte caps),
/// the ones whose server answered, and the downloads cancelled. With `slots`, a request waits for one before it is sent,
/// as the app's do (`RemoteMedia.fetchSlots`).
final class FakeImageHost: @unchecked Sendable {
    enum Reply: Sendable {
        /// The bytes: the server answers after `respondAfter` and once `answer` opens, and the body arrives `finishAfter`
        /// later and once `finish` opens (a nil gate: at once).
        case image(Data, respondAfter: Duration = .zero, finishAfter: Duration = .zero, answer: TestGate? = nil, finish: TestGate? = nil)
        case status(Int)
    }

    private let lock = NSLock()
    private var replies: [URL: Reply] = [:]
    private var made: [(url: URL, timeout: TimeInterval, maxBytes: Int)] = []
    private var responses: [URL] = []
    private var cancellations: [URL] = []
    var slots: AsyncLimiter?

    func reply(_ url: URL, _ reply: Reply) {
        lock.lock()
        replies[url] = reply
        lock.unlock()
    }

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return made.map(\.url) }
    var timeouts: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return made.map(\.timeout) }
    var maxBytes: [Int] { lock.lock(); defer { lock.unlock() }; return made.map(\.maxBytes) }
    var answered: [URL] { lock.lock(); defer { lock.unlock() }; return responses }
    var cancelled: [URL] { lock.lock(); defer { lock.unlock() }; return cancellations }

    var fetcher: ImageFetcher {
        ImageFetcher { [self] url, maxBytes, timeout, sent, responded in
            guard let slots else { return try await serve(url, maxBytes, timeout, sent, responded) }
            return try await slots.run { try await self.serve(url, maxBytes, timeout, sent, responded) }
        }
    }

    private func serve(_ url: URL, _ maxBytes: Int, _ timeout: TimeInterval, _ sent: @Sendable () -> Void, _ responded: @Sendable () -> Void) async throws -> Data {
        lock.lock()
        made.append((url, timeout, maxBytes))
        let reply = replies[url]
        lock.unlock()
        sent()
        switch reply {
        case .image(let data, let respondAfter, let finishAfter, let answer, let finish):
            do {
                if respondAfter > .zero { try await Task.sleep(for: respondAfter) }
                try await answer?.wait()
                guard data.count <= maxBytes else { throw RemoteMedia.Failure.tooLarge }
                responded()
                lock.lock()
                responses.append(url)
                lock.unlock()
                if finishAfter > .zero { try await Task.sleep(for: finishAfter) }
                try await finish?.wait()
            } catch is CancellationError {
                lock.lock()
                cancellations.append(url)
                lock.unlock()
                throw CancellationError()
            }
            return data
        case .status(let status):
            throw RemoteMedia.Failure.status(status)
        case nil:
            throw URLError(.cannotFindHost)
        }
    }
}
