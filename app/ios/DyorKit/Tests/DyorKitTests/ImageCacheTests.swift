import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DyorKit

/// The pieces under the image pipeline: the size buckets a view decodes at, the disk cache it keeps them in (between
/// launches, bounded, least recently used out first, erased at once), which hosts' pictures can't change, and how a
/// picture's sources are raced.
final class ImageCacheTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        folders = []
    }

    private func folder() -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("image-cache-\(UUID().uuidString)", isDirectory: true)
        let folder = parent.appendingPathComponent("remote-images-v1", isDirectory: true)
        folders.append(folder)
        return folder
    }

    // MARK: Size buckets

    /// A view decodes the bucket that covers its frame at 3×, within a tenth: rows share the small buckets, a card the
    /// 512 px one, and only a page header the 1200 px one — never a 40 pt row.
    func testEachFrameDecodesTheBucketThatCoversIt() {
        let expected: [(CGFloat, Int)] = [(0, 96), (32, 96), (34, 96), (36, 192), (40, 192), (44, 192), (56, 192), (68, 192), (72, 256),
                                          (120, 384), (175, 512), (200, 768), (240, 768), (361, 1200), (500, 1200)]
        for (points, bucket) in expected {
            XCTAssertEqual(ImageSizeBucket.bucket(points: points), bucket, "\(points) pt")
        }
        for points in stride(from: CGFloat(1), through: 120, by: 1) {
            XCTAssertLessThan(ImageSizeBucket.bucket(points: points), 512, "\(points) pt never decodes a card's size, let alone a header's")
            XCTAssertGreaterThanOrEqual(Double(ImageSizeBucket.bucket(points: points)), Double(points * 3) * 0.9, "\(points) pt is covered")
        }
        XCTAssertEqual(ImageSizeBucket.all, ImageSizeBucket.all.sorted())
        XCTAssertEqual(ImageSizeBucket.all.last, ImageSizeBucket.largest)
        XCTAssertEqual(ImageSizeBucket.bucket(pixels: 10_000), ImageSizeBucket.largest)
    }

    /// A picture is decoded so it covers its bucket's square whatever its shape (its shorter side reaches the bucket),
    /// at most twice the bucket on its longer side, and never past its own size.
    func testAThumbnailCoversItsBucketWhateverItsShape() {
        XCTAssertEqual(ImageSizeBucket.coverPixelSize(bucket: 192, width: 2000, height: 2000), 192)
        XCTAssertEqual(ImageSizeBucket.coverPixelSize(bucket: 512, width: 4000, height: 3000), 683)
        XCTAssertEqual(ImageSizeBucket.coverPixelSize(bucket: 512, width: 3000, height: 4000), 683)
        XCTAssertEqual(ImageSizeBucket.coverPixelSize(bucket: 192, width: 8000, height: 1000), 384, "a panorama, at most twice over")
        XCTAssertEqual(ImageSizeBucket.coverPixelSize(bucket: 512, width: 100, height: 80), 100, "never scaled up")
    }

    // MARK: The disk cache

    private func cache(_ folder: URL?, capacity: Int = ImageDiskCache.defaultCapacity, epoch: ImageCacheEpoch = ImageCacheEpoch(), clock: TestClock = TestClock()) -> ImageDiskCache {
        ImageDiskCache(directory: folder, capacity: capacity, epoch: epoch, now: clock.read)
    }

    /// A miss, then the stored thumbnail — again after a relaunch (a new cache over the same folder), with when it was
    /// stored: the file's creation date, not its modification date, which every read past `touchInterval` moves (a
    /// picture viewed often must still go stale, so a takedown reaches it). Its file is named by the key's hash and the
    /// bucket, nothing of the URL.
    func testAThumbnailIsKeptBetweenLaunches() async throws {
        let folder = folder()
        let clock = TestClock()
        let first = cache(folder, clock: clock)
        let missing = await first.entry(key: "k", bucket: 192)
        XCTAssertNil(missing)
        await first.store(Data(repeating: 1, count: 100), key: "https://a.example/x.png", bucket: 192, epoch: 0)
        clock.advance(ImageDiskCache.touchInterval + 1)
        let hit = await first.entry(key: "https://a.example/x.png", bucket: 192) // read: its modification date moves on
        XCTAssertEqual(hit?.data, Data(repeating: 1, count: 100))
        let file = folder.appendingPathComponent(ImageDiskCache.fileName(key: "https://a.example/x.png", bucket: 192))
        let modified = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertEqual(modified.timeIntervalSince(clock.start), ImageDiskCache.touchInterval + 1, accuracy: 1, "the read was written back")
        clock.advance(3_600)
        let relaunched = cache(folder, clock: clock)
        let keptFound = await relaunched.entry(key: "https://a.example/x.png", bucket: 192)
        let kept = try XCTUnwrap(keptFound)
        XCTAssertEqual(kept.data.count, 100)
        XCTAssertEqual(kept.storedAt.timeIntervalSince(clock.start), 0, accuracy: 1, "stored when it was stored, not when it was last read")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names, [ImageDiskCache.fileName(key: "https://a.example/x.png", bucket: 192)])
        XCTAssertFalse(names[0].contains("example"))
        XCTAssertEqual(names[0].count, 64 + 4)
    }

    /// A larger thumbnail answers for a smaller size (it decodes down with no network); a smaller one only as the
    /// stand-in while a larger size loads.
    func testALargerThumbnailAnswersForASmallerSize() async {
        let disk = cache(folder())
        await disk.store(Data([1]), key: "k", bucket: 512, epoch: 0)
        let down = await disk.entry(key: "k", atLeast: 192)
        XCTAssertEqual(down?.bucket, 512)
        let up = await disk.entry(key: "k", atLeast: 768)
        XCTAssertNil(up)
        let below = await disk.entry(key: "k", below: 1200)
        XCTAssertEqual(below?.bucket, 512)
        let none = await disk.entry(key: "k", below: 512)
        XCTAssertNil(none)
        let other = await disk.entry(key: "other", atLeast: 96)
        XCTAssertNil(other, "another picture never answers")
    }

    /// Past its capacity the cache deletes the files used least recently, down to nine tenths; the order survives a
    /// relaunch (the last use is the file's modification date, which a read past `touchInterval` moves on).
    func testTheLeastRecentlyUsedGoFirst() async {
        let folder = folder()
        let clock = TestClock()
        let disk = cache(folder, capacity: 3_500, clock: clock)
        for key in ["a", "b", "c"] {
            await disk.store(Data(repeating: 7, count: 1_000), key: key, bucket: 192, epoch: 0)
            clock.advance(ImageDiskCache.touchInterval + 1)
        }
        _ = await disk.entry(key: "a", bucket: 192) // a is used again: b is now the oldest
        clock.advance(ImageDiskCache.touchInterval + 1)
        await disk.store(Data(repeating: 7, count: 1_000), key: "d", bucket: 192, epoch: 0)
        let total = await disk.totalBytes
        XCTAssertEqual(total, 3_000)
        for (key, kept) in [("a", true), ("b", false), ("c", true), ("d", true)] {
            let entry = await disk.entry(key: key, bucket: 192)
            XCTAssertEqual(entry != nil, kept, key)
        }

        // a and d are read again, c isn't: on disk, c was used longest ago (the check above read all three at once).
        clock.advance(ImageDiskCache.touchInterval + 1)
        _ = await disk.entry(key: "a", bucket: 192)
        _ = await disk.entry(key: "d", bucket: 192)
        // After a relaunch, with nothing read first, the order comes from the files alone: c goes.
        clock.advance(1)
        let relaunched = cache(folder, capacity: 3_500, clock: clock)
        await relaunched.store(Data(repeating: 7, count: 1_000), key: "e", bucket: 192, epoch: 0)
        for (key, kept) in [("a", true), ("c", false), ("d", true), ("e", true)] {
            let entry = await relaunched.entry(key: key, bucket: 192)
            XCTAssertEqual(entry != nil, kept, "after a relaunch: \(key)")
        }
    }

    /// An erase moves the epoch on and takes the folder away at once: the files are gone, a write captured before the
    /// erase is refused, and a cache over the same folder finds nothing. A folder left aside is deleted on next use.
    func testAnEraseTakesEveryFileAndRefusesLateWrites() async throws {
        let folder = folder()
        let epoch = ImageCacheEpoch()
        let disk = cache(folder, epoch: epoch)
        await disk.store(Data([1, 2, 3]), key: "k", bucket: 96, epoch: epoch.value)
        let before = await disk.count
        XCTAssertEqual(before, 1)
        let captured = epoch.value
        epoch.advance()
        ImageDiskCache.discardFiles(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "gone at once")
        let gone = await disk.entry(key: "k", bucket: 96)
        XCTAssertNil(gone)
        await disk.store(Data([4]), key: "late", bucket: 96, epoch: captured)
        let late = await disk.entry(key: "late", bucket: 96)
        XCTAssertNil(late, "a load from before the erase keeps nothing")
        let relaunched = cache(folder)
        let count = await relaunched.count
        XCTAssertEqual(count, 0)
        // A new picture after the erase is kept as usual.
        await disk.store(Data([5]), key: "new", bucket: 96, epoch: epoch.value)
        let fresh = await disk.entry(key: "new", bucket: 96)
        XCTAssertNotNil(fresh)

        // A folder an erase moved aside but didn't finish deleting goes on the next read.
        let aside = folder.deletingLastPathComponent().appendingPathComponent("remote-images-v1.discarded-test", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        _ = await cache(folder).count
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    /// `remove(key:)` forgets every size of a picture, and nothing else; anything in the folder the cache didn't name
    /// is deleted when it reads the folder.
    func testRemovingAPictureForgetsEverySize() async throws {
        let folder = folder()
        let disk = cache(folder)
        for bucket in [96, 512, 1200] { await disk.store(Data([1]), key: "k", bucket: bucket, epoch: 0) }
        await disk.store(Data([1]), key: "other", bucket: 96, epoch: 0)
        await disk.remove(key: "k")
        let count = await disk.count
        XCTAssertEqual(count, 1)
        try Data([9]).write(to: folder.appendingPathComponent("stray.tmp"))
        _ = await cache(folder).count
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stray.tmp").path))
    }

    /// Nothing over the entry cap, nothing empty, no bucket the pipeline doesn't use, and no folder: nothing kept.
    func testOnlyReasonableEntriesAreKept() async {
        let disk = cache(folder())
        await disk.store(Data(), key: "empty", bucket: 96, epoch: 0)
        await disk.store(Data(count: ImageDiskCache.maxEntryBytes + 1), key: "huge", bucket: 96, epoch: 0)
        await disk.store(Data([1]), key: "odd", bucket: 100, epoch: 0)
        let count = await disk.count
        XCTAssertEqual(count, 0)
        let nowhere = cache(nil)
        await nowhere.store(Data([1]), key: "k", bucket: 96, epoch: 0)
        let entry = await nowhere.entry(key: "k", bucket: 96)
        XCTAssertNil(entry)
    }

    /// An opaque thumbnail is kept as JPEG, one with transparency as PNG (JPEG would flatten it onto black).
    func testThumbnailsAreEncodedByTheirTransparency() throws {
        let opaque = try XCTUnwrap(ImageDiskCache.encode(try RemoteMedia.thumbnail(try ImagePipelineTests.jpeg(width: 40, height: 30), maxPixelSize: 40)))
        XCTAssertEqual(opaque.prefix(2), Data([0xFF, 0xD8]))
        let clear = try XCTUnwrap(ImageDiskCache.encode(try RemoteMedia.thumbnail(try RemoteMediaTests.png(width: 40, height: 30), maxPixelSize: 40)))
        XCTAssertEqual(clear.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(try RemoteMedia.inspect(clear).width, 40)
    }

    // MARK: Which pictures can't change

    private let policy = ImageSourcePolicy.dyorhq
    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"
    private let launchMedia = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/moment-1.jpg"
    private let avatar = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/avatars/0x6115caf237026b45b037191b20056d1e4afaffa3/avatar.jpg?v=1727000000"

    /// DyorHQ's write-once bucket and a CID on the app's gateways never change; an avatar (uploaded over), a list's logo,
    /// a stranger's host, a gateway link without a CID, or the bucket with a query, can.
    func testOnlyTheWriteOnceBucketAndCIDsAreImmutable() {
        XCTAssertTrue(policy.isImmutable(URL(string: launchMedia)!))
        for gateway in MomentsMath.ipfsGateways {
            XCTAssertTrue(policy.isImmutable(URL(string: gateway + cid)!), gateway)
            XCTAssertTrue(policy.isImmutable(URL(string: gateway + cid + "/photo.jpg")!), gateway)
            XCTAssertFalse(policy.isImmutable(URL(string: gateway + "not-a-cid")!), gateway)
            XCTAssertFalse(policy.isImmutable(URL(string: gateway + cid + "?filename=x")!), gateway)
        }
        for mutable in [avatar, launchMedia + "?v=2", "https://dsvxs4ecepqgj.cloudfront.net/logos/chog.png", "https://evil.example/ipfs/\(cid)",
                        "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/avatars/x/avatar.jpg"] {
            XCTAssertFalse(policy.isImmutable(URL(string: mutable)!), mutable)
        }
    }

    /// DyorHQ's host waits 8 s, a gateway 12 s, any other host 15 s; only DyorHQ's host and the gateways may finish a
    /// download nobody waits for, and only a list made of them is raced.
    func testTimeoutsTrustAndRacingFollowTheHost() {
        let bucket = URL(string: launchMedia)!, avatar = URL(string: avatar)!, gateway = URL(string: MomentsMath.ipfsGateways[0] + cid)!
        let stranger = URL(string: "https://dsvxs4ecepqgj.cloudfront.net/logos/chog.png")!
        XCTAssertEqual(policy.requestTimeout(for: bucket), 8)
        XCTAssertEqual(policy.requestTimeout(for: avatar), 8)
        XCTAssertEqual(policy.requestTimeout(for: gateway), 12)
        XCTAssertEqual(policy.requestTimeout(for: stranger), 15)
        XCTAssertTrue(policy.mayFinishUnwatched(bucket))
        XCTAssertTrue(policy.mayFinishUnwatched(avatar))
        XCTAssertTrue(policy.mayFinishUnwatched(gateway))
        XCTAssertFalse(policy.mayFinishUnwatched(stranger))
        XCTAssertFalse(policy.mayFinishUnwatched(URL(string: "https://fmnjqrguvopusfufmirs.supabase.co:8443/x")!), "another port")
        XCTAssertFalse(policy.mayFinishUnwatched(URL(string: "https://fmnjqrguvopusfufmirs.supabase.co.evil.example/x")!))

        let moment = policy.momentSources(mediaURI: "ipfs://\(cid)", mediaHash: Data(repeating: 1, count: 32), isVideo: false, creator: DyorCoinChain.creator)
        XCTAssertEqual(moment.count, 1 + MomentsMath.ipfsGateways.count)
        XCTAssertTrue(policy.mayRace(moment))
        XCTAssertFalse(policy.mayRace([RemoteImageSource(url: bucket)]), "one source")
        XCTAssertFalse(policy.mayRace([RemoteImageSource(url: stranger), RemoteImageSource(url: gateway)]))
    }

    // MARK: Storage's resized copies

    /// Storage's resized copy of an unchecked picture in DyorHQ's write-once bucket: the same object on the same host,
    /// under the render path, with a query the app writes — the width, `resize=contain` (with a width alone Storage crops
    /// a strip), quality 70.
    func testAResizedCopyIsTheSameObjectWithTheAppsQuery() throws {
        XCTAssertEqual(policy.renderURL(URL(string: launchMedia)!, width: 96)?.absoluteString,
                       "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/render/image/public/launch-media/0x6115caf237026b45b037191b20056d1e4afaffa3/moment-1.jpg?width=96&resize=contain&quality=70")
        for picture in ["launch-media/0xab/logo.JPEG", "launch-media/0xab/logo.png", "launch-media/0xab/a.webp"] {
            XCTAssertNotNil(policy.renderURL(URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/" + picture)!, width: 96), picture)
        }
        let render = try XCTUnwrap(policy.renderURL(URL(string: launchMedia)!, width: 512))
        XCTAssertTrue(policy.isFirstParty(render) && policy.mayFinishUnwatched(render), "DyorHQ's own host")
        XCTAssertEqual(policy.requestTimeout(for: render), ImageSourcePolicy.firstPartyTimeout)
        XCTAssertEqual(ImageSourcePolicy.renderQuality, 70)
    }

    /// Nothing else is resized: an avatar, with its version or without (uploaded over its own path, so a copy a CDN
    /// kept by that path could be the last one; and it is 512 px at most already), another host, port, scheme or bucket,
    /// a video, a dirty path, any query, a fragment, an IPFS gateway, a link already under the render path, or a width
    /// outside what Storage serves.
    func testOnlyAnUncheckedPictureInDyorHQsWriteOnceBucketIsResized() {
        let base = "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/"
        for refused in [avatar, base + "avatars/0xab/avatar.jpg", base + "avatars/0xab/a.webp", launchMedia + "?v=2", launchMedia + "#x",
                        base + "launch-media/0xab/moment-1.mp4", base + "launch-media/0xab/moment-1.mov", base + "launch-media/", base + "launch-media/0xab/",
                        base + "other/0xab/a.jpg", base + "launch-media/%2e%2e/a.jpg", base + "launch-media/0xab/../a.jpg",
                        "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/render/image/public/launch-media/0xab/a.jpg",
                        "https://fmnjqrguvopusfufmirs.supabase.co:8443/storage/v1/object/public/launch-media/0xab/a.jpg",
                        "http://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/launch-media/0xab/a.jpg",
                        "https://abcd.supabase.co/storage/v1/object/public/launch-media/0xab/a.jpg",
                        "https://fmnjqrguvopusfufmirs.supabase.co.evil.example/storage/v1/object/public/launch-media/0xab/a.jpg",
                        MomentsMath.ipfsGateways[0] + cid, "https://news.example/photo.jpg"] {
            XCTAssertNil(policy.renderURL(URL(string: refused)!, width: 96), refused)
        }
        XCTAssertNil(policy.renderURL(URL(string: launchMedia)!, width: 0))
        XCTAssertNil(policy.renderURL(URL(string: launchMedia)!, width: ImageSourcePolicy.maxRenderWidth + 1))
        XCTAssertNotNil(policy.renderURL(URL(string: launchMedia)!, width: ImageSourcePolicy.maxRenderWidth))
        XCTAssertNil(ImagePipeline.render([RemoteImageSource(url: URL(string: avatar)!)], bucket: 192, policy: policy), "an avatar loads its original")
    }

    /// A refusal says the picture is gone only where its host's answer means that: DyorHQ's host for Storage's 400 (its
    /// `not_found`), 404 or 410; a gateway for 404, 410 or 451 (a CID it refuses to serve); any other host for 404 or
    /// 410. A 403 is never "gone" (bot protection, a rate limit, a filtering proxy), nor a 400 off DyorHQ's host, a 429
    /// or a 5xx.
    func testGoneIsWhatEachHostsAnswerMeans() {
        let bucket = URL(string: launchMedia)!, render = policy.renderURL(URL(string: launchMedia)!, width: 96)!
        let gateway = URL(string: MomentsMath.ipfsGateways[0] + cid)!, stranger = URL(string: "https://news.example/photo.jpg")!
        for url in [bucket, render, URL(string: avatar)!] {
            XCTAssertEqual([400, 403, 404, 410, 429, 451, 500, 503].filter { policy.saysGone($0, from: url) }, [400, 404, 410], url.absoluteString)
        }
        XCTAssertEqual([400, 403, 404, 410, 429, 451, 500, 503].filter { policy.saysGone($0, from: gateway) }, [404, 410, 451])
        XCTAssertEqual([400, 403, 404, 410, 429, 451, 500, 503].filter { policy.saysGone($0, from: stranger) }, [404, 410])
    }

    /// A load asks Storage's resized copy first only at a list size (up to 768 px, never the page header's 1200) and only
    /// for an unchecked source in DyorHQ's buckets — then the original; a hash-checked mirror and the gateways are asked as
    /// they are, in their order.
    func testWhichLoadsAskAResizedCopyFirst() throws {
        let logo = RemoteImageSource(url: URL(string: launchMedia)!)
        XCTAssertEqual(ImagePipeline.maxRenderedBucket, 768)
        XCTAssertEqual(ImagePipeline.render([logo], bucket: 96, policy: policy), 96)
        XCTAssertEqual(ImagePipeline.render([logo], bucket: 768, policy: policy), 768)
        XCTAssertNil(ImagePipeline.render([logo], bucket: ImageSizeBucket.largest, policy: policy), "the page header loads the original")
        let moment = policy.momentSources(mediaURI: "ipfs://\(cid)", mediaHash: Data(repeating: 1, count: 32), isVideo: false, creator: DyorCoinChain.creator)
        XCTAssertNotNil(moment.first?.keccak)
        XCTAssertNil(ImagePipeline.render(moment, bucket: 96, policy: policy), "a hash-checked mirror and CIDs: never resized")
        XCTAssertEqual(ImagePipeline.asks(moment, render: 96, policy: policy).map(\.url), moment.map(\.url))

        XCTAssertEqual(ImagePipeline.maxRenderedBytes, RemoteMedia.smallImageBytes, "a resized copy waits in the small downloads' slots")
        let asks = ImagePipeline.asks([logo], render: 192, policy: policy)
        XCTAssertEqual(asks.map(\.url), [try XCTUnwrap(policy.renderURL(logo.url, width: 192)), logo.url])
        XCTAssertEqual(asks.map(\.render), [192, nil])
        XCTAssertTrue(policy.mayRace(asks.map { RemoteImageSource(url: $0.url) }), "the copy and its original: the same picture, DyorHQ's host")
        XCTAssertEqual(ImagePipeline.asks([logo], render: nil, policy: policy).map(\.url), [logo.url])
        let checked = RemoteImageSource(url: logo.url, keccak: Data(repeating: 2, count: 32))
        XCTAssertEqual(ImagePipeline.asks([checked], render: 192, policy: policy).map(\.url), [logo.url], "a source with a hash is asked as it is")
    }

    /// A landscape copy at the bucket's width whose height falls short (by more than a tenth) is asked again at the width
    /// whose height reaches the bucket, at most twice the bucket; a square, a portrait, a copy that nearly covers, or one
    /// narrower than asked (the original is that small) is not.
    func testALandscapeCopyIsAskedAgainOnlyWhenItFallsShort() {
        XCTAssertEqual(ImagePipeline.widerRender(width: 96, height: 72, bucket: 96), 128)
        XCTAssertEqual(ImagePipeline.widerRender(width: 512, height: 288, bucket: 512), 911, "16:9")
        XCTAssertEqual(ImagePipeline.widerRender(width: 96, height: 86, bucket: 96), 108)
        XCTAssertEqual(ImagePipeline.widerRender(width: 96, height: 10, bucket: 96), 192, "at most twice the bucket")
        XCTAssertNil(ImagePipeline.widerRender(width: 96, height: 96, bucket: 96))
        XCTAssertNil(ImagePipeline.widerRender(width: 96, height: 125, bucket: 96))
        XCTAssertNil(ImagePipeline.widerRender(width: 96, height: 87, bucket: 96), "within a tenth")
        XCTAssertNil(ImagePipeline.widerRender(width: 60, height: 40, bucket: 96), "the original is narrower than asked")
        XCTAssertNil(ImagePipeline.widerRender(width: 192, height: 0, bucket: 192))
    }

    // MARK: Racing a picture's sources
    //
    // Deterministic: each stand-in source waits on gates the test opens, and the hedge's timer is a clock the test fires
    // (`HedgeClock`), so no assertion rests on how fast a busy machine runs.

    private final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var indices: [Int] = []
        private var answeredIndices: [Int] = []
        private var cancelledIndices: [Int] = []
        func add(_ index: Int) { lock.lock(); indices.append(index); lock.unlock() }
        func answer(_ index: Int) { lock.lock(); answeredIndices.append(index); lock.unlock() }
        func cancel(_ index: Int) { lock.lock(); cancelledIndices.append(index); lock.unlock() }
        /// Every ask, in order (a source asked again appears again).
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return indices }
        var answered: [Int] { lock.lock(); defer { lock.unlock() }; return answeredIndices }
        var cancelled: [Int] { lock.lock(); defer { lock.unlock() }; return cancelledIndices }
    }

    /// What one stand-in source does when asked: waits for its download slot (`slot`, nil: it has one), says its request
    /// went out, then its server answers when `respond` opens (nil: never — silent until cancelled) and the body is in
    /// when `finish` opens (nil: at once), with `result`.
    private struct Script: Sendable {
        var slot: TestGate? = nil
        var respond: TestGate?
        var finish: TestGate? = nil
        var result: ImageAttemptResult = .accepted(Data([1]))
    }

    private func race(_ scripts: [Script], hedge: Duration?, clock: HedgeClock = HedgeClock(), maxInFlight: Int = 2,
                      control: ImageLoadControl = ImageLoadControl(), started: Started) async -> ImageSourceRace.Outcome {
        await ImageSourceRace.run(count: scripts.count, hedgeAfter: hedge, maxInFlight: maxInFlight, control: control, sleep: clock.sleep) { index, sent, responded in
            started.add(index)
            let script = scripts[index]
            do {
                try await script.slot?.wait()
                sent()
                try await (script.respond ?? TestGate()).wait()
                responded()
                started.answer(index)
                try await script.finish?.wait()
                return script.result
            } catch {
                started.cancel(index)
                return .failed(gone: false)
            }
        }
    }

    private func index(_ outcome: ImageSourceRace.Outcome) -> Int? {
        if case .accepted(let index, _) = outcome { return index }
        return nil
    }

    /// A source that hasn't answered within the hedge is joined by the next, and whichever is accepted first wins; the
    /// silent one stands down (cancelled).
    func testASilentSourceIsJoinedByTheNext() async {
        let started = Started(), clock = HedgeClock()
        let task = Task { await race([Script(respond: nil), Script(respond: .opened), Script(respond: .opened)], hedge: .seconds(2), clock: clock, started: started) }
        await eventually("the first source's hedge is armed") { clock.armed == 1 }
        clock.fire()
        let outcome = await task.value
        XCTAssertEqual(index(outcome), 1)
        XCTAssertEqual(started.all, [0, 1], "the third was never needed")
        await eventually("the silent one stopped") { started.cancelled == [0] }
    }

    /// The hedge's clock starts when a source's request goes out, not while it waits for a download slot behind other
    /// pictures: a source still queued is never joined by the next, however long it waits.
    func testTheHedgeStartsOnlyOnceTheRequestIsSent() async {
        let started = Started(), clock = HedgeClock(), slot = TestGate()
        let task = Task { await race([Script(slot: slot, respond: nil), Script(respond: .opened)], hedge: .seconds(2), clock: clock, started: started) }
        await eventually("asked") { started.all == [0] }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(clock.armed, 0, "no timer while it waits its turn")
        clock.fire()
        XCTAssertEqual(started.all, [0])
        slot.open()
        await eventually("armed once sent") { clock.armed == 1 }
        clock.fire()
        let outcome = await task.value
        XCTAssertEqual(index(outcome), 1, "silent once sent: joined")
    }

    /// A source already sending its bytes is left to finish: its hedge, firing after it answered, starts nothing.
    func testASourceSendingItsBytesIsNotHedged() async {
        let started = Started(), clock = HedgeClock(), finish = TestGate()
        let task = Task { await race([Script(respond: .opened, finish: finish), Script(respond: .opened)], hedge: .seconds(2), clock: clock, started: started) }
        await eventually("the first source answered") { started.answered == [0] }
        clock.fire()
        try? await Task.sleep(for: .milliseconds(50))
        finish.open()
        let outcome = await task.value
        XCTAssertEqual(index(outcome), 0)
        XCTAssertEqual(started.all, [0])
    }

    /// When a source answers, any other still silent stands down rather than download the same picture beside it — and
    /// is asked again in its turn if the one that answered then fails.
    func testASourceThatAnswersStandsTheOthersDownUntilItFails() async {
        let started = Started(), clock = HedgeClock()
        let answer0 = TestGate(), finish0 = TestGate(), answer1 = TestGate()
        let task = Task {
            await race([Script(respond: answer0, finish: finish0, result: .failed(gone: false)), Script(respond: answer1)], hedge: .seconds(2), clock: clock, started: started)
        }
        await eventually("the first source's hedge is armed") { clock.armed == 1 }
        clock.fire()
        await eventually("the second joined") { started.all == [0, 1] }
        answer0.open()
        await eventually("the second stood down") { started.cancelled == [1] }
        finish0.open()
        await eventually("asked again once the first failed") { started.all == [0, 1, 1] }
        answer1.open()
        let outcome = await task.value
        XCTAssertEqual(index(outcome), 1)
    }

    /// A source that fails lets the next start at once, hedge or not; at most `maxInFlight` run together.
    func testAFailureStartsTheNextAndAtMostTwoRun() async {
        let started = Started()
        let outcome = await race([Script(respond: .opened, result: .failed(gone: true)), Script(respond: .opened)], hedge: nil, started: started)
        XCTAssertEqual(index(outcome), 1)

        let crowd = Started(), clock = HedgeClock()
        let task = Task { await race(Array(repeating: Script(respond: nil), count: 4), hedge: .seconds(2), clock: clock, started: crowd) }
        await eventually("the first source's hedge is armed") { clock.armed == 1 }
        clock.fire()
        await eventually("the second joined, its hedge armed") { crowd.all == [0, 1] && clock.armed == 1 }
        clock.fire()
        await eventually("every hedge fired") { clock.armed == 0 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(crowd.all, [0, 1], "two at once, however long they stay silent")
        task.cancel()
        _ = await task.value
    }

    /// Without a hedge (a list the policy doesn't allow racing), strictly one after another.
    func testWithoutAHedgeOneAfterAnother() async {
        let started = Started()
        let task = Task { await race([Script(respond: nil), Script(respond: .opened)], hedge: nil, started: started) }
        await eventually("asked") { started.all == [0] }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(started.all, [0])
        task.cancel()
        _ = await task.value
    }

    /// "Gone" only when every source was asked and each said the picture isn't there; a timeout or a 429 among them
    /// says nothing.
    func testGoneOnlyWhenEverySourceSaysSo() async {
        let gone = await race([Script(respond: .opened, result: .failed(gone: true)), Script(respond: .opened, result: .failed(gone: true))], hedge: nil, started: Started())
        guard case .failed(gone: true, abandoned: false) = gone else { return XCTFail("\(gone)") }
        let mixed = await race([Script(respond: .opened, result: .failed(gone: true)), Script(respond: .opened, result: .failed(gone: false))], hedge: nil, started: Started())
        guard case .failed(gone: false, abandoned: false) = mixed else { return XCTFail("\(mixed)") }
    }

    /// Abandoned (every view left while a trusted download was sending its bytes): that download finishes, and nothing
    /// new starts — the source it stood down stays down.
    func testAnAbandonedRaceFinishesOnlyWhatIsSending() async {
        let started = Started(), clock = HedgeClock(), control = ImageLoadControl()
        let answer = TestGate(), finish = TestGate()
        let task = Task {
            await race([Script(respond: nil), Script(respond: answer, finish: finish), Script(respond: .opened)], hedge: .seconds(2), clock: clock,
                       control: control, started: started)
        }
        await eventually("the first source's hedge is armed") { clock.armed == 1 }
        clock.fire()
        await eventually("0 is silent, 1 asked") { started.all == [0, 1] }
        XCTAssertFalse(control.abandonIfTrusted(), "not trusted yet: the caller cancels")
        XCTAssertFalse(control.isAbandoned)
        answer.open()
        await eventually("1 is sending, 0 stood down") { started.answered == [1] && started.cancelled == [0] }
        control.markTrusted()
        XCTAssertTrue(control.abandonIfTrusted())
        finish.open()
        let outcome = await task.value
        XCTAssertEqual(index(outcome), 1, "the download under way finished")
        XCTAssertEqual(started.all, [0, 1], "nothing new started")
        XCTAssertTrue(control.isAbandoned)
    }

    /// An abandoned race whose download then fails starts nothing: it ends abandoned (the pipeline starts the load again
    /// if a view came back to it, `ImagePipelineTests`).
    func testAnAbandonedRaceStartsNothingWhenItsDownloadFails() async {
        let started = Started(), control = ImageLoadControl(), finish = TestGate()
        let task = Task {
            await race([Script(respond: .opened, finish: finish, result: .failed(gone: false)), Script(respond: .opened)], hedge: .seconds(2),
                       control: control, started: started)
        }
        await eventually("sending") { started.answered == [0] }
        control.markTrusted()
        XCTAssertTrue(control.abandonIfTrusted())
        finish.open()
        let outcome = await task.value
        guard case .failed(gone: false, abandoned: true) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(started.all, [0])
    }
}

// MARK: Test helpers

/// A door a test opens: what waits on it goes on once it is open, and a wait that is cancelled throws (one that is never
/// opened gives up after a minute, so a broken test fails rather than hangs).
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    /// A gate already open: at once.
    static var opened: TestGate {
        let gate = TestGate()
        gate.open()
        return gate
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }

    func open() { lock.lock(); opened = true; lock.unlock() }

    func wait() async throws {
        let deadline = Date().addingTimeInterval(60)
        while !isOpen {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// The race's hedge timers (`ImageSourceRace.run`'s `sleep`), fired by hand: a timer ends when `fire()` is called after it
/// began, or throws when cancelled; `armed` counts those waiting.
final class HedgeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = 0
    private var waiting = 0

    var armed: Int { lock.lock(); defer { lock.unlock() }; return waiting }

    func fire() { lock.lock(); fired += 1; lock.unlock() }

    var sleep: @Sendable (Duration) async throws -> Void { { [self] _ in try await wait() } }

    private func wait() async throws {
        lock.lock()
        let begun = fired
        waiting += 1
        lock.unlock()
        defer { lock.lock(); waiting -= 1; lock.unlock() }
        while true {
            lock.lock()
            let now = fired
            lock.unlock()
            if now > begun { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Waits until `condition` holds, polling on the caller's actor — a busy machine only makes it slower — and fails after
/// `seconds`.
func eventually(_ what: String, seconds: Double = 30, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("never: \(what)", file: file, line: line)
}
