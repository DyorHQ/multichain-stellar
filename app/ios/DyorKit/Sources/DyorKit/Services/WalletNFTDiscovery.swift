import BigInt
import Foundation

/// Discovers every ERC-721 a wallet holds on Monad — Moments or any other collection — from its own transfer
/// history, with no indexer: candidates come from incoming `Transfer` logs with an indexed token id, ownership is
/// confirmed on-chain, and each token's metadata (name, image, animation) is resolved from its `tokenURI`.
///
/// The transfers are the wallet's history store's (`WalletHistorySnapshot.transfersIn`, `WalletHistoryScans.transfersIn`):
/// every `Transfer` into the wallet, read newest first back to its first transaction or 30 days, whichever is earlier,
/// kept on the device and topped up — the very scan its tokens are found in (`WalletTokenDiscovery.held`). An ERC-721
/// `Transfer` matches the same filter, with four topics. In build 22 and earlier this ran a scan of its own, the same
/// filter from block 0 to the head, oldest first, on every Portfolio load: its 80 requests reached block 4.8M of 111M, the
/// chain's first two weeks, so no Moment edition (minted from block 105M) was ever found, the list read "No NFTs in this
/// wallet yet", and each load held the shared logs gate for about 20 s while the wallet's history filled in.
public struct WalletNFTDiscovery: Sendable {
    private let multicall: Multicall

    public init(multicall: Multicall) {
        self.multicall = multicall
    }

    /// Requests `held` may make, in all, past each batch's ownership read, to read again the candidates whose `ownerOf`
    /// failed in it (`ownership`). Spam editions anyone can send a wallet can burn an aggregate's gas: a few re-reads each
    /// time are enough to tell the wallet's own NFTs from them, and past the budget what is left is unread (the list says
    /// one may be missing), never thousands of requests on the endpoint Send, Swap and prices use.
    public static let ownershipRereads = 20

    /// What `held` found: the NFTs the wallet holds, and whether that is all of them.
    public struct Held: Sendable, Equatable {
        /// Newest received first.
        public let nfts: [NFTAsset]
        /// The transfers were read over their whole window, and every ownership read answered. False: an NFT the wallet
        /// holds may be missing, which a list says (with Retry, or how far the history has got) rather than "no NFTs".
        public let complete: Bool
        /// Candidates were left once `limit` NFTs were listed — unchecked, or checked and held: more may be held than
        /// `nfts` lists, so a count of them is a minimum ("N+").
        public let cut: Bool

        public init(nfts: [NFTAsset], complete: Bool, cut: Bool = false) {
            self.nfts = nfts
            self.complete = complete
            self.cut = cut
        }
    }

    /// One NFT a transfer into the wallet names: its collection and its token id.
    struct Candidate: Hashable, Sendable {
        let contract: Address
        let tokenId: BigUInt
    }

    /// The NFTs the wallet holds among those `incoming` names (the transfers into it, `complete` when they cover their
    /// whole window), newest received first, at most `limit` resolved. An NFT whose ownership couldn't be read keeps its
    /// entry from `previous` (an earlier read's of the same wallet) and makes the read incomplete: never dropped, nor shown
    /// as held, on a read that failed. Its metadata, when its read fails, is the earlier read's, else its collection and id.
    /// At most `checkLimit` candidates are asked who owns them, newest first, `batch` a read: past it the read is
    /// incomplete, as an NFT held among the rest would be missing. Once `limit` are listed no further batch is read, and
    /// candidates left say more may be held (`Held.cut`). `rereads`: the requests past each batch's read, in all
    /// (`ownershipRereads`).
    public func held(wallet: Address, incoming: [Log], complete scanned: Bool, keeping previous: [NFTAsset] = [], limit: Int = 120,
                     checkLimit: Int = 1_200, batch: Int = 120, rereads: Int = Self.ownershipRereads) async -> Held {
        let candidates = Self.candidates(incoming)
        guard !candidates.isEmpty else { return Held(nfts: [], complete: scanned) }
        let before = Dictionary(previous.map { (Candidate(contract: $0.contract, tokenId: $0.tokenId), $0) }, uniquingKeysWith: { first, _ in first })
        var complete = scanned

        // Still owned by the wallet? A transferred-away or burned token reverts or names another owner. One whose owner
        // couldn't be read keeps the entry an earlier read showed, and says the list may be missing one.
        var owned: [Candidate] = []
        var kept: [Candidate: NFTAsset] = [:]
        var cut = false
        var budget = max(0, rereads)
        var index = 0
        while index < candidates.count, owned.count < limit {
            // A wallet an airdrop campaign spammed with editions it no longer holds would otherwise ask after them all, a
            // request per batch: past `checkLimit` the newest checked stand, and the list says one may be missing.
            guard index < checkLimit else { complete = false; break }
            let slice = Array(candidates[index ..< min(index + max(1, batch), candidates.count)])
            index += slice.count
            let read = await ownership(of: slice, wallet: wallet, rereads: budget)
            budget -= read.spent
            for candidate in slice {
                switch read.found[candidate] ?? .unread {
                case .held:
                    if owned.count < limit { owned.append(candidate) } else { cut = true }
                case .notHeld:
                    break
                case .unread:
                    complete = false
                    guard let asset = before[candidate] else { continue }
                    if owned.count < limit {
                        owned.append(candidate)
                        kept[candidate] = asset
                    } else {
                        cut = true
                    }
                }
            }
        }
        // `limit` listed with candidates never asked after: one of them may be held. No batch is read only to find out: a
        // limit reached at a batch's end sends no further read.
        if owned.count >= limit, index < candidates.count { cut = true }
        guard !owned.isEmpty else { return Held(nfts: [], complete: complete, cut: cut) }

        // Names and token URIs of those read as owned now; a failed read gives each its earlier entry, else its collection
        // and id with no art.
        let fresh = owned.filter { kept[$0] == nil }
        var results: [Result<[ABIValue], Error>]? = []
        if !fresh.isEmpty {
            if let calls = try? fresh.flatMap({ [try ERC721.name($0.contract), try ERC721.tokenURI($0.contract, $0.tokenId)] }) {
                results = try? await multicall.read(calls)
            } else {
                results = nil
            }
        }
        func text(_ i: Int) -> String {
            guard let results, results.indices.contains(i), case .success(let values) = results[i] else { return "" }
            return values.first?.stringOrNil ?? ""
        }
        let read = results != nil
        let resolved = await withTaskGroup(of: (Candidate, NFTAsset).self, returning: [Candidate: NFTAsset].self) { group in
            for (i, candidate) in fresh.enumerated() {
                if !read, let asset = before[candidate] {
                    group.addTask { (candidate, asset) }
                    continue
                }
                let collection = text(i * 2)
                let uri = text(i * 2 + 1)
                group.addTask {
                    let metadata = uri.isEmpty ? nil : await NFTMetadata.resolve(tokenURI: uri)
                    let fallback = "\(collection.isEmpty ? candidate.contract.short : collection) #\(candidate.tokenId)"
                    return (candidate, NFTAsset(contract: candidate.contract, tokenId: candidate.tokenId, collection: collection,
                                                name: metadata?.name ?? fallback, imageURL: metadata?.image, animationURL: metadata?.animation))
                }
            }
            var out: [Candidate: NFTAsset] = [:]
            for await (candidate, asset) in group { out[candidate] = asset }
            return out
        }
        return Held(nfts: owned.compactMap { kept[$0] ?? resolved[$0] }, complete: complete, cut: cut)
    }

    /// Whether the wallet holds a candidate, as its reads said: held, held by another (or burned), or unread.
    enum Ownership: Sendable { case held, notHeld, unread }

    /// What one aggregate read said of a candidate's `ownerOf`: the wallet; another owner, or an answer that isn't one (the
    /// call returned, so it wasn't starved); a call that failed — it reverted, or ran out of gas, maybe starved by a call
    /// before it, which Multicall3 reports alike; or no answer to the read at all.
    private enum OwnerRead: Sendable { case wallet, other, failed, unanswered }

    /// Who owns each of `group` (`Ownership`), read in one aggregate, and the requests spent past it (at most `budget`).
    /// A call that fails in an aggregate may have been starved of gas by an earlier one (a spam edition can burn it all), so
    /// it is never taken for "not held" there: as `ERC20.metadataReport` reads a failed symbol again, the first that failed
    /// is read on its own (one that starves the rest fails first), the others again together, and what fails again one by
    /// one, five at a time. A call that fails read on its own wasn't starved: not the wallet's. Past `budget` what is left
    /// is unread, as is a read that got no answer. In build 22 and earlier a failed call was "not held": a wallet's NFT
    /// after a gas-burning spam edition in the same read dropped silently from the list.
    func ownership(of group: [Candidate], wallet: Address, rereads budget: Int) async -> (found: [Candidate: Ownership], spent: Int) {
        var found: [Candidate: Ownership] = [:]
        var spent = 0
        // What the reads said; the calls that failed in a read of several, to read again.
        func take(_ reads: [(Candidate, OwnerRead)], alone: Bool) -> [Candidate] {
            var failed: [Candidate] = []
            for (candidate, read) in reads {
                switch read {
                case .wallet: found[candidate] = .held
                case .other: found[candidate] = .notHeld
                case .failed: if alone { found[candidate] = .notHeld } else { failed.append(candidate) }
                case .unanswered: found[candidate] = .unread
                }
            }
            return failed
        }
        let failed = take(await ownerReads(group, wallet: wallet), alone: group.count == 1)
        guard let first = failed.first else { return (found, spent) }
        guard spent < budget else {
            for candidate in failed { found[candidate] = .unread }
            return (found, spent)
        }
        spent += 1
        _ = take(await ownerReads([first], wallet: wallet), alone: true)
        let rest = Array(failed.dropFirst())
        guard !rest.isEmpty else { return (found, spent) }
        guard spent < budget else {
            for candidate in rest { found[candidate] = .unread }
            return (found, spent)
        }
        spent += 1
        let again = take(await ownerReads(rest, wallet: wallet), alone: rest.count == 1)
        let affordable = min(again.count, budget - spent)
        for candidate in again.dropFirst(affordable) { found[candidate] = .unread }
        spent += affordable
        for start in stride(from: 0, to: affordable, by: 5) {
            let reads = await withTaskGroup(of: [(Candidate, OwnerRead)].self, returning: [(Candidate, OwnerRead)].self) { tasks in
                for candidate in again[start ..< min(start + 5, affordable)] {
                    tasks.addTask { await self.ownerReads([candidate], wallet: wallet) }
                }
                var out: [(Candidate, OwnerRead)] = []
                for await read in tasks { out += read }
                return out
            }
            _ = take(reads, alone: true)
        }
        return (found, spent)
    }

    /// `ownerOf` of each of `group` in one aggregate read, and what it said of each (`OwnerRead`).
    private func ownerReads(_ group: [Candidate], wallet: Address) async -> [(Candidate, OwnerRead)] {
        guard let calls = try? group.map({ try ERC721.ownerOf($0.contract, $0.tokenId) }) else { return group.map { ($0, .unanswered) } }
        guard let results = try? await multicall.read(calls), results.count == group.count else { return group.map { ($0, .unanswered) } }
        return zip(group, results).map { candidate, result in
            switch result {
            case .success(let values): return (candidate, values.first?.address == wallet ? .wallet : .other)
            // `Multicall.read` reports a call that failed as an `RPCError`, and one that returned what isn't an address as
            // the decoding's error.
            case .failure(let error): return (candidate, error is RPCError ? .failed : .other)
            }
        }
    }

    /// The NFTs `incoming` names, newest first, each once. ERC-721 indexes the token id: four topics and no data. ERC-20
    /// transfers share the signature but not the shape (an ERC-20 that indexes its amount is weeded out by `ownerOf`).
    static func candidates(_ incoming: [Log]) -> [Candidate] {
        var seen = Set<Candidate>()
        var out: [Candidate] = []
        for log in incoming.sorted(by: { $0.blockNumber == $1.blockNumber ? $0.logIndex > $1.logIndex : $0.blockNumber > $1.blockNumber }) where log.topics.count == 4 {
            let candidate = Candidate(contract: log.address, tokenId: BigUInt(log.topics[3]))
            if seen.insert(candidate).inserted { out.append(candidate) }
        }
        return out
    }
}
