// The Pro wallet signs the Monad side of the bridge (testnet CCTP: chain 10143), through DyorKit's own sender.
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation
import StellarKit

struct MonadBridgeAdapter: LiteMonadBridge {
    let session: Session
    static let testnetChainId = 10143
    static let testnetRPC = URL(string: "https://testnet-rpc.monad.xyz")!

    var monadAddress: String { MainActor.assumeIsolated { session.address?.description ?? "" } }

    func send(_ steps: [EvmStep]) async throws -> String {
        guard steps.allSatisfy({ $0.chainId == Self.testnetChainId }) else { throw LiteAPIError.decoding("a Monad step for another chain") }
        guard let wallet = await MainActor.run(body: { session.wallet(for: nil) }) else { throw LiteAPIError.notSignedIn }
        let sender = TransactionSender(rpc: RPCClient(url: Self.testnetRPC), chainId: Self.testnetChainId)
        let plan: [TransactionStep] = try steps.map { s in
            guard let to = Address(s.to), let data = Data(hexString: s.data) else { throw LiteAPIError.decoding("a Monad step") }
            return TransactionStep.call(TransactionRequest(to: to, data: data, value: BigUInt(s.value) ?? 0), label: s.label)
        }
        let hash = try await sender.run(plan, from: wallet) { _ in }
        return "0x" + hash.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
#endif
