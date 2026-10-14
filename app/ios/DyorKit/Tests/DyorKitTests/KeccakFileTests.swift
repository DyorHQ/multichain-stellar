import Foundation
import XCTest
@testable import DyorKit

/// A picked video is hashed from its file a chunk at a time (security audit 2026-09-26, RI-5): the digest must be the
/// one `hash256(Data)` gives for the same bytes, at every block boundary.
final class KeccakFileTests: XCTestCase {
    func testFileDigestMatchesTheInMemoryDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "keccak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for length in [0, 1, 135, 136, 137, 272, 1000, 4097] {
            let bytes = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
            let file = directory.appending(path: "\(length).bin")
            try bytes.write(to: file)
            // Chunks that straddle the 136-byte blocks in every way, and the production size.
            for chunkSize in [1, 100, 136, 500, 1 << 20] {
                XCTAssertEqual(try Keccak.hash256(file: file, chunkSize: chunkSize), Keccak.hash256(bytes), "length \(length), chunk \(chunkSize)")
            }
        }
    }

    func testKnownVector() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "keccak-empty-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Keccak.hash256(file: file).hexString, "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }
}
