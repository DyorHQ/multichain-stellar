import DyorKit
import Foundation

/// Signs with a wallet the user imported into DyorHQ — their own secp256k1 key, held on this device. Transactions
/// are signed locally and broadcast by the app's own RPC client, exactly like the Privy path; the difference is
/// only where the key lives. The raw key never leaves the device.
struct LocalWallet: Wallet, DigestSigner {
    let account: Secp256k1Account

    var address: Address { account.address }

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        try account.sign(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data {
        try account.signMessage(message)
    }

    func signDigest(_ digest: Data) async throws -> String {
        try account.sign(hash32: digest).hexString
    }
}

/// A wallet that can sign a raw 32-byte digest with its secp256k1 key — what Perpl API-key enrollment needs (it
/// signs the EIP-712 digest directly). Both the Privy embedded wallet and an imported local wallet provide it, so
/// authenticated Perpl trading works with either.
protocol DigestSigner: Wallet {
    func signDigest(_ digest: Data) async throws -> String
}

extension PrivyWallet: DigestSigner {}
