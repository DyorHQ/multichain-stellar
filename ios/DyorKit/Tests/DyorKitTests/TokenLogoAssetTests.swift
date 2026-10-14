import CoreGraphics
import DyorKit
import Foundation
import ImageIO
import XCTest

/// The coin logos the app ships (ios/DyorHQ/Resources/TokenLogos). `TokenLogo` clips each file to a circle over the
/// card's colour, so a file must be the coin alone: square, transparent outside the disc, the disc centred and filling
/// the canvas. Seventeen of them were once drawn small in the top-left corner of an opaque white square, which showed
/// as a white crescent beside every logo on a dark card. `scripts/dev/normalize-token-logos.py` makes a file that
/// passes.
final class TokenLogoAssetTests: XCTestCase {
    /// Every symbol `TokenLogo` finds a shipped logo for: each curated token with a logo (aBIL has none on purpose), and
    /// the Perps markets that have one.
    static let expectedSymbols = Set(Token.core.filter { $0.logoURL != nil }.map(\.symbol))
        .union(["BTC", "ETH", "SOL", "ZEC", "HYPE", "MON"])

    /// The logo folder, or a skip when this checkout has only the package.
    static func logoFolder() throws -> URL {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return app.appendingPathComponent("Resources/TokenLogos")
    }

    /// The folder's file names as stored. A device looks a logo up by exact case, while this Mac's disk ignores case, so
    /// only the listing can tell `logo-USDe.png` from `logo-USDE.png`.
    static func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: logoFolder().path).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testEveryLogoTheAppLooksUpShipsInExactCase() throws {
        let names = try Self.fileNames()
        for symbol in Self.expectedSymbols.sorted() {
            XCTAssertTrue(names.contains("logo-\(symbol).png"), "logo-\(symbol).png is missing (exact case)")
        }
        // Nothing else: a logo for a symbol no curated token carries would dress any token with that symbol, and a
        // stray image would ship in the app.
        let extra = Set(names).subtracting(Self.expectedSymbols.map { "logo-\($0).png" })
        XCTAssertTrue(extra.isEmpty, "not a logo the app looks up: \(extra.sorted())")
    }

    /// Transparent outside the disc: no plate of any colour. The 2 px allowance is the disc's anti-aliased edge.
    func testNothingIsDrawnOutsideTheDisc() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            XCTAssertEqual(logo.width, logo.height, "\(name) is not square")
            XCTAssertGreaterThanOrEqual(logo.width, 128, "\(name) is smaller than 128 px")
            let radius = Double(logo.width) / 2
            var outside = 0
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) > 0 {
                    let distance = ((Double(x) + 0.5 - radius) * (Double(x) + 0.5 - radius)
                        + (Double(y) + 0.5 - radius) * (Double(y) + 0.5 - radius)).squareRoot()
                    if distance > radius + 2 { outside += 1 }
                }
            }
            XCTAssertEqual(outside, 0, "\(name) draws \(outside) pixels outside its disc")
        }
    }

    /// The coin fills the square, centred: its visible part (at least half covered) spans at least 97% of each side and
    /// sits within 1% of the middle, so it lines up with the circle `TokenLogo` clips to. On an opaque corner the coin is
    /// what differs from the corner's colour, so a coin drawn small on a plate is measured too.
    func testTheCoinIsCentredAndFillsTheSquare() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            let plate = logo.alpha(0, 0) == 255 ? logo.pixel(0, 0) : nil
            var minX = logo.width, minY = logo.height, maxX = -1, maxY = -1
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) >= 128 && plate.map({ logo.difference(x, y, $0) > 24 }) ?? true {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let side = Double(logo.width)
            XCTAssertGreaterThanOrEqual(maxX, 0, "\(name) is blank")
            guard maxX >= 0 else { continue }
            XCTAssertGreaterThanOrEqual(Double(maxX - minX + 1) / side, 0.97, "\(name) is narrower than its canvas")
            XCTAssertGreaterThanOrEqual(Double(maxY - minY + 1) / side, 0.97, "\(name) is shorter than its canvas")
            XCTAssertLessThanOrEqual(abs(Double(minX + maxX + 1) / 2 - side / 2), side * 0.01, "\(name) is off-centre across")
            XCTAssertLessThanOrEqual(abs(Double(minY + maxY + 1) / 2 - side / 2), side * 0.01, "\(name) is off-centre down")
        }
    }

    /// No coin sits on a plate. A plate already cut to a circle, with the coin drawn smaller inside it, passes both checks
    /// above, yet shows as a ring round the coin: white, cream or light grey on a dark card, black on a light one. It is a
    /// band of one colour round the rim that ends in a circle, the coin's edge, all the way round (`Bitmap.plate`). A
    /// coin's own face is a band too (MON's purple, a white coin's white), but what is drawn on it (MON's rounded square,
    /// USDC's open arcs, a letter) doesn't make a circle, so it measures nothing. A few coins do have a plain ring for a
    /// rim; each was looked at and is listed in `reviewedRims`, with the ring's colour and width, so a plate put round one
    /// of them still fails.
    func testNoCoinSitsOnAPlate() throws {
        var seen = Set<String>()
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            let plate = logo.plate()
            if let reviewed = Self.reviewedRims[name] {
                seen.insert(name)
                guard let plate else { XCTFail("\(name) no longer has its reviewed rim: drop it from reviewedRims"); continue }
                XCTAssertLessThanOrEqual(Bitmap.distance(plate.colour, reviewed.colour), Bitmap.sameColour,
                                         "\(name)'s rim is \(plate.colour), not the reviewed \(reviewed.colour): a plate?")
                XCTAssertLessThanOrEqual(plate.width, reviewed.width + 0.015, "\(name)'s rim is wider than reviewed: a plate?")
            } else {
                XCTAssertLessThan(plate?.width ?? 0, Bitmap.plateWidth,
                                  "\(name) sits on a plate of \(plate?.colour ?? []), \(Int((plate?.width ?? 0) * 100))% of its radius")
            }
        }
        XCTAssertEqual(seen, Set(Self.reviewedRims.keys), "reviewedRims lists a file that isn't shipped")
    }

    /// No coin sits on a white disc: the outer tenth of the disc is at most half near-white. A second check beside
    /// `testNoCoinSitsOnAPlate`, whose band must end in a circle, which a coin that isn't round (WETH) never makes: WETH
    /// scaled onto a white disc passes that check and fails this one. The shipped coins' edges are at most 17%
    /// near-white (WBTC); each plated build-16 file had at least 66%.
    func testNoCoinSitsOnAWhiteDisc() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            let radius = Double(logo.width) / 2
            var edge = 0, white = 0
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) >= 200 {
                    let distance = ((Double(x) + 0.5 - radius) * (Double(x) + 0.5 - radius)
                        + (Double(y) + 0.5 - radius) * (Double(y) + 0.5 - radius)).squareRoot()
                    guard distance >= radius * 0.9, distance <= radius - 2 else { continue }
                    edge += 1
                    if logo.isNearWhite(x, y) { white += 1 }
                }
            }
            XCTAssertGreaterThan(edge, 0, "\(name) has no edge")
            XCTAssertLessThanOrEqual(Double(white) / Double(max(edge, 1)), 0.5, "\(name) sits on a white disc")
        }
    }

    /// The coins whose rim is a plain ring of their own, reviewed by eye against the official art: the ring's colour
    /// (premultiplied RGBA, as `Bitmap.plate` reads it) and its width as a fraction of the radius.
    static let reviewedRims: [String: (colour: [Int], width: Double)] = [
        "logo-WBTC.png": ([40, 33, 56, 254], 0.078), // a white coin in a navy ring
        "logo-cbBTC.png": ([0, 83, 254, 254], 0.094), // a white coin in a blue ring
        "logo-gMON.png": ([237, 124, 19, 254], 0.074), // a navy coin in an orange ring
    ]

    /// The plate check catches the plates a review drew by hand, and leaves plain coins alone. The images are drawn
    /// here: a coin like USDC on a disc of white, cream, light grey or black, and a white plate with a grey border.
    func testThePlateCheckCatchesPlatesOfAnyColour() {
        let white: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
        let plates: [(String, Bitmap)] = [
            ("coin at 95% on a white disc", .drawn { $0.disc(white, 1); $0.usdcLike(0.95) }),
            ("coin at 90% on a white disc", .drawn { $0.disc(white, 1); $0.usdcLike(0.90) }),
            ("coin at 85% on a cream disc", .drawn { $0.disc((1, 245 / 255, 224 / 255), 1); $0.usdcLike(0.85) }),
            ("coin at 85% on a light-grey disc", .drawn { $0.disc((224 / 255, 224 / 255, 224 / 255), 1); $0.usdcLike(0.85) }),
            ("coin at 85% on a black disc", .drawn { $0.disc((0, 0, 0), 1); $0.usdcLike(0.85) }),
            ("coin at 75% on a white plate with a 7 px grey border",
             .drawn { $0.disc((136 / 255, 136 / 255, 136 / 255), 1); $0.disc(white, 121 / 128); $0.usdcLike(0.75) }),
        ]
        for (label, image) in plates {
            XCTAssertGreaterThanOrEqual(image.plate()?.width ?? 0, Bitmap.plateWidth, label)
        }
        let coins: [(String, Bitmap)] = [
            ("a coin like USDC", .drawn { $0.usdcLike(1) }),
            ("a coin like MON", .drawn { $0.monLike() }),
            ("a white coin", .drawn { $0.disc(white, 1); $0.bar() }),
            ("a white coin in a thin blue outline", .drawn { $0.disc((0.08, 0.31, 0.9), 1); $0.disc(white, 126 / 128); $0.bar() }),
        ]
        for (label, image) in coins {
            XCTAssertLessThan(image.plate()?.width ?? 0, Bitmap.plateWidth, label)
        }
    }
}

/// A PNG's pixels (premultiplied RGBA), decoded with ImageIO the way UIKit reads the file. An image with no alpha reads
/// as opaque.
private struct Bitmap {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init(_ url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.lastPathComponent)
        self = Bitmap.drawn(width: image.width, height: image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// An image drawn by `draw` into a `width` × `height` sRGB bitmap.
    static func drawn(width: Int = 256, height: Int = 256, _ draw: (CGContext) -> Void) -> Bitmap {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            draw(context)
            return true
        }
        XCTAssertTrue(drawn, "no bitmap context")
        return Bitmap(width: width, height: height, rgba: rgba)
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * width + x) * 4 + 3] }

    func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }

    /// Whether a pixel is white or nearly so (every channel at least 230 once its alpha is divided out): a plate's
    /// colour, never a coin's own pale tint such as ezETH's lime or mUSD's blue.
    func isNearWhite(_ x: Int, _ y: Int) -> Bool {
        let value = pixel(x, y)
        guard value[3] > 0 else { return false }
        return value[0..<3].allSatisfy { Int($0) * 255 >= 230 * Int(value[3]) }
    }

    /// How far a pixel's colour is from `other`: the sum of the channel differences.
    func difference(_ x: Int, _ y: Int, _ other: [UInt8]) -> Int {
        zip(pixel(x, y), other).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }

    static func distance(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } }

    /// Colours this close (summed premultiplied RGBA difference) are one colour: a plate's gradient or a coin's
    /// anti-aliased edge, not a coin drawn on it.
    static let sameColour = 60
    /// A band this wide, as a fraction of the radius, is a plate: 5 px of a 256 px logo, a coin at 96%. A coin's hairline
    /// outline is narrower.
    static let plateWidth = 0.04

    /// The plate the coin sits on, if it sits on one: a band of one colour round the rim (its colour taken at its outer
    /// edge, premultiplied) that ends in a circle, and its width to that circle as a fraction of the radius. A plate may
    /// be several such bands (a white plate with a grey border). Read along 720 radii, from 2.5 px inside the edge (or
    /// the first ring of one colour within the outer 4%, past a hairline outline): a ring is of one colour when 97% of
    /// it is within `sameColour` of its median, and a band ends in a circle when, on 95% of the radii, it ends within
    /// 3% of the radius of where it ends on the median one. Nil when the rim is no band, or the band doesn't end in a
    /// circle (the coin's face, with something other than a circle drawn on it).
    func plate() -> (colour: [Int], width: Double)? {
        let radius = Double(min(width, height)) / 2, count = 720
        let radii = (0..<count).map { (cos(2 * Double.pi * Double($0) / Double(count)), sin(2 * Double.pi * Double($0) / Double(count))) }
        func sample(_ direction: (Double, Double), _ r: Double) -> SIMD4<Int> {
            let x = min(width - 1, max(0, Int((radius + r * direction.0).rounded(.down))))
            let y = min(height - 1, max(0, Int((radius + r * direction.1).rounded(.down))))
            let i = (y * width + x) * 4
            return SIMD4(Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
        }
        func near(_ a: SIMD4<Int>, _ b: SIMD4<Int>) -> Bool {
            let d = a &- b
            return d.replacing(with: 0 &- d, where: d .< 0).wrappedSum() <= Self.sameColour
        }
        func colourOfRing(at r: Double) -> SIMD4<Int>? {
            let ring = radii.map { sample($0, r) }
            var median = SIMD4<Int>()
            for channel in 0..<4 { median[channel] = ring.map { $0[channel] }.sorted()[count / 2] }
            return ring.filter { near($0, median) }.count * 100 >= count * 97 ? median : nil
        }
        let innermost = radius * 0.3
        var start = radius - 2.5
        var colour = colourOfRing(at: start)
        while colour == nil, start - 0.5 >= radius - 2.5 - radius * 0.04 {
            start -= 0.5
            colour = colourOfRing(at: start)
        }
        guard let outer = colour else { return nil }
        var edge = radius
        while let band = colour, start > innermost {
            let ends = radii.map { direction -> Double in
                var r = start
                while r > innermost, near(sample(direction, r), band) { r -= 0.5 }
                return r
            }
            let median = ends.sorted()[count / 2]
            guard median > innermost, ends.filter({ abs($0 - median) <= radius * 0.03 }).count * 100 >= count * 95 else { break }
            edge = median
            start = median - 1.5
            colour = colourOfRing(at: start)
        }
        return edge < radius ? ((0..<4).map { outer[$0] }, (radius - edge) / radius) : nil
    }
}

/// Shapes for the drawn plate fixtures, in fractions of the canvas's radius about its centre.
private extension CGContext {
    private var radius: CGFloat { CGFloat(min(width, height)) / 2 }

    private func paint(_ rgb: (CGFloat, CGFloat, CGFloat)) { setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)) }

    /// A disc of `rgb`, `scale` of the canvas across.
    func disc(_ rgb: (CGFloat, CGFloat, CGFloat), _ scale: CGFloat) {
        paint(rgb)
        let r = radius * scale
        fillEllipse(in: CGRect(x: radius - r, y: radius - r, width: 2 * r, height: 2 * r))
    }

    /// A coin like USDC, `scale` of the canvas across: blue, with two white arcs open at the top and bottom, and a bar.
    func usdcLike(_ scale: CGFloat) {
        disc((0.04, 0.33, 0.76), scale)
        setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        setLineWidth(radius * scale * 0.1)
        for (from, to) in [(CGFloat.pi * 0.62, CGFloat.pi * 1.38), (CGFloat.pi * 1.62, CGFloat.pi * 2.38)] {
            addArc(center: CGPoint(x: radius, y: radius), radius: radius * scale * 0.72, startAngle: from, endAngle: to, clockwise: false)
            strokePath()
        }
        paint((1, 1, 1))
        fill(CGRect(x: radius - radius * scale * 0.08, y: radius - radius * scale * 0.4, width: radius * scale * 0.16, height: radius * scale * 0.8))
    }

    /// A coin like MON: purple, with a white rounded square.
    func monLike() {
        disc((0.43, 0.33, 1), 1)
        paint((1, 1, 1))
        let side = radius * 0.9
        addPath(CGPath(roundedRect: CGRect(x: radius - side / 2, y: radius - side / 2, width: side, height: side),
                       cornerWidth: side * 0.3, cornerHeight: side * 0.3, transform: nil))
        fillPath()
    }

    /// A blue bar across the middle, a letter's stand-in.
    func bar() {
        paint((0.1, 0.35, 0.9))
        fill(CGRect(x: radius * 0.6, y: radius * 0.5, width: radius * 0.7, height: radius))
    }
}
