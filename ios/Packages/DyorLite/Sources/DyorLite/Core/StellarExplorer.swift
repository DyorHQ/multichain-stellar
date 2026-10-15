import Foundation
import StellarKit

/// StellarExpert's pages for the build's pinned network (docs/DESIGN-stellar-parity.md §5.6): built on the phone, so a
/// link the server sends (`explorerUrl`) is never what opens. Nil for something that isn't what it says (a hash that
/// isn't 64 hex digits, an address whose checksum fails) or a network StellarExpert doesn't show.
public enum StellarExplorer {
    /// A transaction, by its hash.
    public static func transaction(_ hash: String, network: StellarNetwork) -> URL? {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy(isHex) else { return nil }
        return page("tx/\(hash.lowercased())", network: network)
    }

    /// An account (G…).
    public static func account(_ address: String, network: StellarNetwork) -> URL? {
        guard StrKey.isValid(.accountID, address) else { return nil }
        return page("account/\(address)", network: network)
    }

    /// A contract (C…): a launch's coin, the Moments collection, a pool.
    public static func contract(_ contract: String, network: StellarNetwork) -> URL? {
        guard StrKey.isValid(.contract, contract) else { return nil }
        return page("contract/\(contract)", network: network)
    }

    /// An asset: "XLM" (or "native"), a classic asset as "CODE:ISSUER", or a token by its contract.
    public static func asset(_ asset: String, network: StellarNetwork) -> URL? {
        if asset == "XLM" || asset == "native" { return page("asset/XLM", network: network) }
        if StrKey.isValid(.contract, asset) { return contract(asset, network: network) }
        let parts = asset.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...12).contains(parts[0].utf8.count), parts[0].utf8.allSatisfy(isAlphanumeric),
              StrKey.isValid(.accountID, String(parts[1])) else { return nil }
        return page("asset/\(parts[0])-\(parts[1])", network: network)
    }

    /// StellarExpert's name for the network: "testnet", or "public" for mainnet.
    static func explorerNetwork(_ network: StellarNetwork) -> String? {
        switch network {
        case .testnet: "testnet"
        case .mainnet: "public"
        default: nil
        }
    }

    private static func page(_ path: String, network: StellarNetwork) -> URL? {
        explorerNetwork(network).flatMap { URL(string: "https://stellar.expert/explorer/\($0)/\(path)") }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}
