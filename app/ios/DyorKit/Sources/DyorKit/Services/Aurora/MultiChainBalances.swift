import BigInt
import Foundation

/// Reads the wallet's token balances on other EVM chains, so the Bridge can show "you have X USDC on Base". The same
/// `0x…` address is used on every chain; a native asset uses `eth_getBalance`, an ERC-20 uses `balanceOf` batched
/// through that chain's multicall. Per-chain failures are swallowed (a dead public RPC returns nothing, never blocks).
///
/// A chain's two reads go out at once, and a chain is given `cap` (6 s) in all (speed work, 2026-10-10): the Bridge reads
/// every chain side by side, and one slow third-party endpoint held the picker's holdings, and a bridge's baseline, for
/// up to 30 s a read, the native balance and the tokens one after the other. What hasn't answered by then is left out,
/// as a failed read is: a token without a balance is never shown as held, and an arrival is never inferred from a balance
/// that wasn't read (`BridgeTracker`). Whether every read answered is said (`ChainBalances.complete`), so a chain read in
/// part is read again rather than taken as read (`BridgeModel.loadBalances`).
public struct MultiChainBalances: Sendable {
    /// How long one chain's balances may take, both reads together.
    public static let cap: Duration = .seconds(6)

    private let session: URLSession
    private let cap: Duration

    public init(session: URLSession = .shared, cap: Duration = MultiChainBalances.cap) {
        self.session = session
        self.cap = cap
    }

    /// One chain's balances as read: those that answered within the cap (raw, smallest units, keyed by Aurora `assetId`),
    /// and whether every read did. A read that failed or ran out of time leaves its balances out — never 0 — and the chain
    /// incomplete; a token whose own call failed inside an answered read (no such contract there) is answered, and left out.
    public struct ChainBalances: Sendable, Equatable {
        public var balances: [String: BigUInt]
        public var complete: Bool

        public init(balances: [String: BigUInt], complete: Bool) {
            self.balances = balances
            self.complete = complete
        }
    }

    /// Balances (raw, smallest units) keyed by Aurora `assetId`, for the given tokens on one chain: what answered within
    /// `cap` (`read(owner:chain:tokens:)`, which also says whether that is all of them).
    public func balances(owner: Address, chain: EVMChain, tokens: [AuroraToken]) async -> [String: BigUInt] {
        await read(owner: owner, chain: chain, tokens: tokens).balances
    }

    /// What one of a chain's reads came to.
    private enum Part: Sendable {
        case answered([String: BigUInt])
        case failed
        /// The cap passed: what hasn't answered is left out.
        case capped
    }

    /// One chain's balances for the given tokens, read within `cap`, and whether every read answered.
    public func read(owner: Address, chain: EVMChain, tokens: [AuroraToken]) async -> ChainBalances {
        let rpc = RPCClient(url: chain.rpcURL, session: session)
        let native = tokens.filter { $0.isNative }
        let pairs: [(AuroraToken, ContractCall)] = tokens.filter { !$0.isNative }.compactMap { token in
            guard let address = Address(token.contractAddress ?? ""), let call = try? ERC20.balanceOf(address, owner) else { return nil }
            return (token, call)
        }
        var reads = 0
        return await withTaskGroup(of: Part.self) { group in
            if !native.isEmpty {
                reads += 1
                group.addTask {
                    guard let balance = try? await rpc.balance(of: owner) else { return .failed }
                    return .answered(Dictionary(native.map { ($0.assetId, balance) }, uniquingKeysWith: { first, _ in first }))
                }
            }
            if !pairs.isEmpty {
                reads += 1
                group.addTask {
                    guard let results = try? await Multicall(rpc: rpc).read(pairs.map(\.1)) else { return .failed }
                    var out: [String: BigUInt] = [:]
                    for (pair, result) in zip(pairs, results) {
                        if case .success(let values) = result, let value = values.first?.uint { out[pair.0.assetId] = value }
                    }
                    return .answered(out)
                }
            }
            guard reads > 0 else { return ChainBalances(balances: [:], complete: true) }
            let cap = cap
            group.addTask {
                try? await Task.sleep(for: cap)
                return .capped
            }
            var out: [String: BigUInt] = [:]
            var complete = true
            reading: while reads > 0, let part = await group.next() {
                switch part {
                case .answered(let balances):
                    out.merge(balances) { current, _ in current }
                    reads -= 1
                case .failed:
                    complete = false
                    reads -= 1
                case .capped:
                    // The cap: what hasn't answered is left out.
                    complete = false
                    break reading
                }
            }
            group.cancelAll()
            return ChainBalances(balances: out, complete: complete)
        }
    }
}
