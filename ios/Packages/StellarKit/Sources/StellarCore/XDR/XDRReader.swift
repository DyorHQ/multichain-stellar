import Foundation

public enum XDRError: Error, Equatable, CustomStringConvertible {
    case truncated
    case tooLong(String)
    case unsupported(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: return "XDR ended early"
        case .tooLong(let what): return "XDR \(what) is longer than allowed"
        case .unsupported(let what): return "unsupported \(what)"
        case .invalid(let what): return "invalid \(what)"
        }
    }
}

/// Big-endian XDR reader over a byte buffer.
public struct XDRReader {
    public let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var isAtEnd: Bool { offset == bytes.count }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, offset + n <= bytes.count else { throw XDRError.truncated }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    public mutating func uint32() throws -> UInt32 {
        let b = try take(4)
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    public mutating func uint64() throws -> UInt64 {
        let b = try take(8)
        return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public mutating func int64() throws -> Int64 { Int64(bitPattern: try uint64()) }

    public mutating func bool() throws -> Bool {
        switch try uint32() {
        case 0: return false
        case 1: return true
        default: throw XDRError.invalid("bool")
        }
    }

    public mutating func fixed(_ n: Int) throws -> [UInt8] {
        let v = Array(try take(n))
        let pad = (4 - n % 4) % 4
        if pad > 0 { _ = try take(pad) }
        return v
    }

    public mutating func variable(max: Int, _ what: String = "opaque") throws -> [UInt8] {
        let n = Int(try uint32())
        guard n <= max else { throw XDRError.tooLong(what) }
        return try fixed(n)
    }

    public mutating func string(max: Int, _ what: String = "string") throws -> String {
        let b = try variable(max: max, what)
        guard let s = String(bytes: b, encoding: .utf8) else { throw XDRError.invalid(what) }
        return s
    }

    public mutating func array<T>(max: Int, _ what: String, _ element: (inout XDRReader) throws -> T) throws -> [T] {
        let n = Int(try uint32())
        guard n <= max else { throw XDRError.tooLong(what) }
        var out: [T] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try element(&self)) }
        return out
    }

    public mutating func optional<T>(_ element: (inout XDRReader) throws -> T) throws -> T? {
        try bool() ? try element(&self) : nil
    }
}

/// Big-endian XDR writer: what signing needs (re-encoding an envelope's signatures and the signature base), the ledger
/// keys the app reads, and the transactions tests build.
public struct XDRWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func uint32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    public mutating func uint64(_ v: UInt64) {
        uint32(UInt32(v >> 32))
        uint32(UInt32(v & 0xffff_ffff))
    }

    public mutating func int64(_ v: Int64) { uint64(UInt64(bitPattern: v)) }

    public mutating func raw(_ b: [UInt8]) { bytes += b }

    public mutating func variable(_ b: [UInt8]) {
        uint32(UInt32(b.count))
        bytes += b
        let pad = (4 - b.count % 4) % 4
        bytes += [UInt8](repeating: 0, count: pad)
    }
}
