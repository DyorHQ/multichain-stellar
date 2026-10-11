import Foundation

// The subset of Stellar XDR that DyorHQ Lite signs, decoded strictly: anything outside it (an operation type, a host
// function, an auth function the app doesn't use) is a decoding error, and an error means "don't sign".

public enum Asset: Equatable, Hashable {
    case native
    case credit(code: String, issuer: String)

    /// "native" or "CODE:ISSUER", the form the API and intents use.
    public var spec: String {
        switch self {
        case .native: return "native"
        case .credit(let code, let issuer): return "\(code):\(issuer)"
        }
    }
}

public enum SCAddress: Equatable, Hashable {
    case account(String)
    case contract(String)
    case other(Int32)

    public var string: String? {
        switch self {
        case .account(let s), .contract(let s): return s
        case .other: return nil
        }
    }
}

public indirect enum SCVal: Equatable {
    case bool(Bool)
    case void
    case error
    case u32(UInt32)
    case i32(Int32)
    case u64(UInt64)
    case i64(Int64)
    case timepoint(UInt64)
    case duration(UInt64)
    case u128(hi: UInt64, lo: UInt64)
    case i128(hi: Int64, lo: UInt64)
    case u256([UInt8])
    case i256([UInt8])
    case bytes([UInt8])
    case string(String)
    case symbol(String)
    case vec([SCVal]?)
    case map([(SCVal, SCVal)]?)
    case address(SCAddress)
    case ledgerKeyContractInstance
    case ledgerKeyNonce(Int64)

    public static func == (a: SCVal, b: SCVal) -> Bool {
        switch (a, b) {
        case let (.bool(x), .bool(y)): return x == y
        case (.void, .void), (.error, .error), (.ledgerKeyContractInstance, .ledgerKeyContractInstance): return true
        case let (.u32(x), .u32(y)): return x == y
        case let (.i32(x), .i32(y)): return x == y
        case let (.u64(x), .u64(y)), let (.timepoint(x), .timepoint(y)), let (.duration(x), .duration(y)): return x == y
        case let (.i64(x), .i64(y)), let (.ledgerKeyNonce(x), .ledgerKeyNonce(y)): return x == y
        case let (.u128(h1, l1), .u128(h2, l2)): return h1 == h2 && l1 == l2
        case let (.i128(h1, l1), .i128(h2, l2)): return h1 == h2 && l1 == l2
        case let (.u256(x), .u256(y)), let (.i256(x), .i256(y)), let (.bytes(x), .bytes(y)): return x == y
        case let (.string(x), .string(y)), let (.symbol(x), .symbol(y)): return x == y
        case let (.vec(x), .vec(y)): return x == y
        case let (.map(x), .map(y)):
            guard let x, let y else { return x == nil && y == nil }
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.address(x), .address(y)): return x == y
        default: return false
        }
    }

    /// The value as a signed 64-bit amount, if it is an integer that fits (i128/u128/i64/u64/u32/i32).
    public var amount: Int64? {
        switch self {
        case let .i128(hi, lo):
            if hi == 0, lo <= UInt64(Int64.max) { return Int64(lo) }
            if hi == -1, lo > UInt64(Int64.max) { return Int64(bitPattern: lo) }
            return nil
        case let .u128(hi, lo): return hi == 0 && lo <= UInt64(Int64.max) ? Int64(lo) : nil
        case let .i64(v): return v
        case let .u64(v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case let .u32(v): return Int64(v)
        case let .i32(v): return Int64(v)
        default: return nil
        }
    }

    public var addressString: String? {
        if case let .address(a) = self { return a.string }
        return nil
    }
}

public struct InvokeContractArgs: Equatable {
    public let contract: SCAddress
    public let function: String
    public let args: [SCVal]
}

public enum AuthorizedFunction: Equatable {
    case contractFn(InvokeContractArgs)
    case createContract
}

public struct AuthorizedInvocation: Equatable {
    public let function: AuthorizedFunction
    public let subInvocations: [AuthorizedInvocation]
}

public enum SorobanCredentials: Equatable {
    case sourceAccount
    case address(SCAddress)
}

public struct AuthorizationEntry: Equatable {
    public let credentials: SorobanCredentials
    public let rootInvocation: AuthorizedInvocation
}

public enum HostFunction: Equatable {
    case invokeContract(InvokeContractArgs)
    case other(Int32)
}

public enum OperationBody: Equatable {
    case createAccount(destination: String, startingBalance: Int64)
    case payment(destination: String, asset: Asset, amount: Int64)
    case pathPaymentStrictSend(sendAsset: Asset, sendAmount: Int64, destination: String, destAsset: Asset, destMin: Int64, path: [Asset])
    case changeTrust(asset: Asset, limit: Int64)
    case manageData(name: String, value: [UInt8]?)
    case beginSponsoringFutureReserves(sponsoredID: String)
    case endSponsoringFutureReserves
    case invokeHostFunction(HostFunction, auth: [AuthorizationEntry])
    case extendFootprintTTL(extendTo: UInt32)
    case restoreFootprint

    /// The stellar-sdk name of the operation type, as intents list them.
    public var typeName: String {
        switch self {
        case .createAccount: return "createAccount"
        case .payment: return "payment"
        case .pathPaymentStrictSend: return "pathPaymentStrictSend"
        case .changeTrust: return "changeTrust"
        case .manageData: return "manageData"
        case .beginSponsoringFutureReserves: return "beginSponsoringFutureReserves"
        case .endSponsoringFutureReserves: return "endSponsoringFutureReserves"
        case .invokeHostFunction: return "invokeHostFunction"
        case .extendFootprintTTL: return "extendFootprintTtl"
        case .restoreFootprint: return "restoreFootprint"
        }
    }
}

public struct Operation: Equatable {
    public let source: String?
    public let body: OperationBody
}

public struct TimeBounds: Equatable {
    public let minTime: UInt64
    public let maxTime: UInt64
}

public struct Transaction: Equatable {
    public let source: String
    public let fee: UInt32
    public let sequence: Int64
    public let timeBounds: TimeBounds?
    public let operations: [Operation]
    public let resourceFee: Int64?
}

public struct DecoratedSignature: Equatable {
    public let hint: [UInt8]
    public let signature: [UInt8]
}

/// A v1 transaction envelope with the exact bytes of its transaction (what the signature base hashes).
public struct TransactionEnvelope: Equatable {
    public let transaction: Transaction
    public let transactionXDR: [UInt8]
    public var signatures: [DecoratedSignature]

    public init(base64: String) throws {
        guard let data = Data(base64Encoded: base64) else { throw XDRError.invalid("base64") }
        var r = XDRReader([UInt8](data))
        let type = try r.int32()
        guard type == 2 else { throw XDRError.unsupported(type == 5 ? "fee-bump envelope" : "envelope type \(type)") }
        let start = r.offset
        transaction = try XDRDecode.transaction(&r)
        transactionXDR = Array(r.bytes[start..<r.offset])
        signatures = try r.array(max: 20, "signatures") { r in
            DecoratedSignature(hint: try r.fixed(4), signature: try r.variable(max: 64, "signature"))
        }
        guard r.isAtEnd else { throw XDRError.invalid("trailing bytes") }
    }

    /// Re-encodes the envelope with its current signatures.
    public func base64() -> String {
        var w = XDRWriter()
        w.uint32(2)
        w.raw(transactionXDR)
        w.uint32(UInt32(signatures.count))
        for s in signatures {
            w.raw(s.hint)
            w.variable(s.signature)
        }
        return Data(w.bytes).base64EncodedString()
    }
}

enum XDRDecode {
    static func accountID(_ r: inout XDRReader) throws -> String {
        let t = try r.int32()
        guard t == 0 else { throw XDRError.unsupported("public key type \(t)") }
        return StrKey.accountID(try r.fixed(32))
    }

    /// Muxed accounts resolve to their underlying G-address (the id is dropped: Lite never uses muxed sources).
    static func muxedAccount(_ r: inout XDRReader) throws -> String {
        let t = try r.int32()
        switch t {
        case 0: return StrKey.accountID(try r.fixed(32))
        case 0x100:
            _ = try r.uint64()
            return StrKey.accountID(try r.fixed(32))
        default: throw XDRError.unsupported("muxed account type \(t)")
        }
    }

    static func assetCode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func asset(_ r: inout XDRReader) throws -> Asset {
        let t = try r.int32()
        switch t {
        case 0: return .native
        case 1:
            let code = assetCode(try r.fixed(4))
            return .credit(code: code, issuer: try accountID(&r))
        case 2:
            let code = assetCode(try r.fixed(12))
            return .credit(code: code, issuer: try accountID(&r))
        default: throw XDRError.unsupported("asset type \(t)")
        }
    }

    static func scAddress(_ r: inout XDRReader) throws -> SCAddress {
        let t = try r.int32()
        switch t {
        case 0: return .account(try accountID(&r))
        case 1: return .contract(StrKey.contractID(try r.fixed(32)))
        case 2:
            _ = try r.uint64()
            _ = try r.fixed(32)
            return .other(2)
        case 3:
            let v = try r.int32()
            guard v == 0 else { throw XDRError.unsupported("claimable balance id \(v)") }
            _ = try r.fixed(32)
            return .other(3)
        case 4:
            _ = try r.fixed(32)
            return .other(4)
        default: throw XDRError.unsupported("address type \(t)")
        }
    }

    static func scVal(_ r: inout XDRReader, depth: Int = 0) throws -> SCVal {
        guard depth < 32 else { throw XDRError.tooLong("value nesting") }
        let t = try r.int32()
        switch t {
        case 0: return .bool(try r.bool())
        case 1: return .void
        case 2:
            let et = try r.int32()
            if et == 0 { _ = try r.uint32() } else { _ = try r.int32() }
            return .error
        case 3: return .u32(try r.uint32())
        case 4: return .i32(try r.int32())
        case 5: return .u64(try r.uint64())
        case 6: return .i64(try r.int64())
        case 7: return .timepoint(try r.uint64())
        case 8: return .duration(try r.uint64())
        case 9: return .u128(hi: try r.uint64(), lo: try r.uint64())
        case 10: return .i128(hi: try r.int64(), lo: try r.uint64())
        case 11: return .u256(try r.fixed(32))
        case 12: return .i256(try r.fixed(32))
        case 13: return .bytes(try r.variable(max: 256 * 1024, "bytes"))
        case 14: return .string(try r.string(max: 256 * 1024))
        case 15: return .symbol(try r.string(max: 32, "symbol"))
        case 16: return .vec(try r.optional { r in try r.array(max: 1_000, "vec") { r in try scVal(&r, depth: depth + 1) } })
        case 17:
            return .map(try r.optional { r in
                try r.array(max: 1_000, "map") { r in (try scVal(&r, depth: depth + 1), try scVal(&r, depth: depth + 1)) }
            })
        case 18: return .address(try scAddress(&r))
        case 20: return .ledgerKeyContractInstance
        case 21: return .ledgerKeyNonce(try r.int64())
        default: throw XDRError.unsupported("value type \(t)")
        }
    }

    static func invokeContractArgs(_ r: inout XDRReader) throws -> InvokeContractArgs {
        let contract = try scAddress(&r)
        let fn = try r.string(max: 32, "function name")
        let args = try r.array(max: 100, "args") { r in try scVal(&r) }
        return InvokeContractArgs(contract: contract, function: fn, args: args)
    }

    static func authorizedInvocation(_ r: inout XDRReader, depth: Int = 0) throws -> AuthorizedInvocation {
        guard depth < 16 else { throw XDRError.tooLong("auth nesting") }
        let t = try r.int32()
        let function: AuthorizedFunction
        switch t {
        case 0: function = .contractFn(try invokeContractArgs(&r))
        default: throw XDRError.unsupported("authorization of contract creation")
        }
        let subs = try r.array(max: 100, "sub-invocations") { r in try authorizedInvocation(&r, depth: depth + 1) }
        return AuthorizedInvocation(function: function, subInvocations: subs)
    }

    static func authEntry(_ r: inout XDRReader) throws -> AuthorizationEntry {
        let ct = try r.int32()
        let credentials: SorobanCredentials
        switch ct {
        case 0: credentials = .sourceAccount
        case 1:
            let address = try scAddress(&r)
            _ = try r.int64() // nonce
            _ = try r.uint32() // signature expiration ledger
            _ = try scVal(&r) // signature
            credentials = .address(address)
        default: throw XDRError.unsupported("credentials type \(ct)")
        }
        return AuthorizationEntry(credentials: credentials, rootInvocation: try authorizedInvocation(&r))
    }

    static func operation(_ r: inout XDRReader) throws -> Operation {
        let source = try r.optional { r in try muxedAccount(&r) }
        let type = try r.int32()
        let body: OperationBody
        switch type {
        case 0: body = .createAccount(destination: try accountID(&r), startingBalance: try r.int64())
        case 1: body = .payment(destination: try muxedAccount(&r), asset: try asset(&r), amount: try r.int64())
        case 6:
            let line = try asset(&r) // ChangeTrustAsset: pool shares (type 3) are rejected by `asset`
            body = .changeTrust(asset: line, limit: try r.int64())
        case 10:
            let name = try r.string(max: 64, "data name")
            body = .manageData(name: name, value: try r.optional { r in try r.variable(max: 64, "data value") })
        case 13:
            let sendAsset = try asset(&r)
            let sendAmount = try r.int64()
            let destination = try muxedAccount(&r)
            let destAsset = try asset(&r)
            let destMin = try r.int64()
            let path = try r.array(max: 5, "path") { r in try asset(&r) }
            body = .pathPaymentStrictSend(sendAsset: sendAsset, sendAmount: sendAmount, destination: destination, destAsset: destAsset, destMin: destMin, path: path)
        case 16: body = .beginSponsoringFutureReserves(sponsoredID: try accountID(&r))
        case 17: body = .endSponsoringFutureReserves
        case 24:
            let ht = try r.int32()
            let fn: HostFunction
            switch ht {
            case 0: fn = .invokeContract(try invokeContractArgs(&r))
            default: throw XDRError.unsupported("host function \(ht)")
            }
            let auth = try r.array(max: 50, "auth") { r in try authEntry(&r) }
            body = .invokeHostFunction(fn, auth: auth)
        case 25:
            _ = try r.int32() // ExtensionPoint v0
            body = .extendFootprintTTL(extendTo: try r.uint32())
        case 26:
            _ = try r.int32()
            body = .restoreFootprint
        default: throw XDRError.unsupported("operation type \(type)")
        }
        return Operation(source: source, body: body)
    }

    static func preconditions(_ r: inout XDRReader) throws -> TimeBounds? {
        let t = try r.int32()
        switch t {
        case 0: return nil
        case 1: return TimeBounds(minTime: try r.uint64(), maxTime: try r.uint64())
        case 2:
            let tb = try r.optional { r in TimeBounds(minTime: try r.uint64(), maxTime: try r.uint64()) }
            _ = try r.optional { r in (try r.uint32(), try r.uint32()) } // ledger bounds
            _ = try r.optional { r in try r.int64() } // min seq num
            _ = try r.uint64() // min seq age
            _ = try r.uint32() // min seq ledger gap
            let extra = try r.array(max: 2, "extra signers") { r -> Int32 in
                let st = try r.int32()
                switch st {
                case 0, 1, 2: _ = try r.fixed(32)
                case 3:
                    _ = try r.fixed(32)
                    _ = try r.variable(max: 64, "signed payload")
                default: throw XDRError.unsupported("signer key \(st)")
                }
                return st
            }
            guard extra.isEmpty else { throw XDRError.unsupported("extra signers") }
            return tb
        default: throw XDRError.unsupported("preconditions \(t)")
        }
    }

    static func memo(_ r: inout XDRReader) throws {
        let t = try r.int32()
        switch t {
        case 0: return
        case 1: _ = try r.variable(max: 28, "memo")
        case 2: _ = try r.uint64()
        case 3, 4: _ = try r.fixed(32)
        default: throw XDRError.unsupported("memo type \(t)")
        }
    }

    static func ledgerKey(_ r: inout XDRReader) throws {
        let t = try r.int32()
        switch t {
        case 0: _ = try accountID(&r)
        case 1:
            _ = try accountID(&r)
            let at = try r.int32()
            switch at {
            case 0: break
            case 1:
                _ = try r.fixed(4)
                _ = try accountID(&r)
            case 2:
                _ = try r.fixed(12)
                _ = try accountID(&r)
            case 3: _ = try r.fixed(32)
            default: throw XDRError.unsupported("trustline asset \(at)")
            }
        case 2:
            _ = try accountID(&r)
            _ = try r.int64()
        case 3:
            _ = try accountID(&r)
            _ = try r.string(max: 64)
        case 4:
            _ = try r.int32()
            _ = try r.fixed(32)
        case 5: _ = try r.fixed(32)
        case 6:
            _ = try scAddress(&r)
            _ = try scVal(&r)
            _ = try r.int32()
        case 7: _ = try r.fixed(32)
        case 8: _ = try r.int32()
        case 9: _ = try r.fixed(32)
        default: throw XDRError.unsupported("ledger key \(t)")
        }
    }

    /// SorobanTransactionData; returns the resource fee.
    static func sorobanData(_ r: inout XDRReader) throws -> Int64 {
        let ext = try r.int32()
        switch ext {
        case 0: break
        case 1: _ = try r.array(max: 1_000, "archived entries") { r in try r.uint32() }
        default: throw XDRError.unsupported("soroban data ext \(ext)")
        }
        _ = try r.array(max: 1_000, "read-only footprint") { r in try ledgerKey(&r) }
        _ = try r.array(max: 1_000, "read-write footprint") { r in try ledgerKey(&r) }
        _ = try r.uint32() // instructions
        _ = try r.uint32() // disk read bytes
        _ = try r.uint32() // write bytes
        return try r.int64()
    }

    static func transaction(_ r: inout XDRReader) throws -> Transaction {
        let source = try muxedAccount(&r)
        let fee = try r.uint32()
        let seq = try r.int64()
        let tb = try preconditions(&r)
        try memo(&r)
        let ops = try r.array(max: 100, "operations") { r in try operation(&r) }
        let ext = try r.int32()
        var resourceFee: Int64?
        switch ext {
        case 0: break
        case 1: resourceFee = try sorobanData(&r)
        default: throw XDRError.unsupported("transaction ext \(ext)")
        }
        return Transaction(source: source, fee: fee, sequence: seq, timeBounds: tb, operations: ops, resourceFee: resourceFee)
    }
}
