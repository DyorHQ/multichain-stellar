import BigInt
import DyorKit
import Foundation
import PrivySDK

/// Signs with Privy's embedded wallet. Transactions are signed locally and broadcast by the app's own RPC
/// client, so Monad never has to be on Privy's list of hosted networks.
struct PrivyWallet: Wallet {
    let address: Address
    let provider: any EmbeddedEthereumWalletProvider

    func sign(_ tx: PreparedTransaction) async throws -> Data {
        let unsigned = EthereumRpcRequest.UnsignedEthTransaction(
            from: tx.from.checksummed,
            to: tx.to.checksummed,
            nonce: .hexadecimalNumber(BigUInt(tx.nonce).hexQuantity),
            gasLimit: .hexadecimalNumber(tx.gasLimit.hexQuantity),
            data: tx.data.hexString,
            value: .hexadecimalNumber(tx.value.hexQuantity),
            chainId: .hexadecimalNumber(BigUInt(tx.chainId).hexQuantity),
            type: 2,
            maxFeePerGas: .hexadecimalNumber(tx.maxFeePerGas.hexQuantity),
            maxPriorityFeePerGas: .hexadecimalNumber(tx.maxPriorityFeePerGas.hexQuantity)
        )
        let signed = try await provider.request(.ethSignTransaction(transaction: unsigned))
        guard let bytes = Data(hex: signed) else { throw TransactionError.rejected(tr("The wallet returned an unreadable signature.")) }
        // Privy returns the RLP-encoded signed transaction. A bare 65-byte signature is assembled here just in case.
        if bytes.count == 65 {
            let r = BigUInt(bytes.prefix(32))
            let s = BigUInt(bytes.subdata(in: 32..<64))
            var v = bytes[64]
            if v >= 27 { v -= 27 }
            return RLP.signedTransaction(tx, v: v, r: r, s: s)
        }
        return bytes
    }

    func signMessage(_ message: Data) async throws -> Data {
        let signature = try await provider.request(.personalSign(message: message.hexString, address: address.checksummed))
        guard let bytes = Data(hex: signature) else { throw TransactionError.rejected(tr("The wallet returned an unreadable signature.")) }
        return bytes
    }

    /// Signs a raw 32-byte hash with the wallet's secp256k1 key and returns a `0x`-hex 65-byte EIP-712 signature
    /// (v normalised to 27/28). Used to authorize Perpl API-key enrollment over the same EIP-712 digest the
    /// Ed25519 proof-of-possession covers.
    func signDigest(_ digest: Data) async throws -> String {
        let signature = try await provider.request(.secp256k1Sign(hash: digest.hexString))
        guard var bytes = Data(hex: signature) else { throw TransactionError.rejected(tr("The wallet returned an unreadable signature.")) }
        if bytes.count == 65, bytes[64] < 27 { bytes[64] += 27 }
        return bytes.hexString
    }
}
