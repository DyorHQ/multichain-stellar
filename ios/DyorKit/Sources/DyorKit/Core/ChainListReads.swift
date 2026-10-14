import Foundation

/// Text on chain that its creator chose — a launch's name, symbol, logo, description and links, a Moment's coin name,
/// symbol and provenance — as the app reads it into a list.
public enum ChainText {
    /// What a name or symbol shows when its read failed: the same U+FFFD that stands for bytes that aren't text.
    // not localized: a symbol, the replacement character, in every language
    public static let unreadable = "\u{FFFD}"
}

/// A list read that did not answer for every item: a protocol value (a price, a supply, a ledger, a record) that must
/// be there wasn't, as when the read reached a node a block behind the one that listed the item. Shown as the error it
/// is, with Retry, never as a shorter list or a missing item.
public struct ChainListUnread: Error, LocalizedError, Equatable, Sendable {
    /// What wasn't read: each one is a whole sentence of its own, so it reads right in every language.
    public enum Item: Sendable, Equatable {
        case launch, moment, thisMoment, momentName, dyorCoin
    }

    public let what: Item

    public init(_ what: Item) { self.what = what }

    public var errorDescription: String? {
        switch what {
        case .launch: return L10n.tr("A launch couldn't be read from the chain just now. Try again.")
        case .moment: return L10n.tr("A Moment couldn't be read from the chain just now. Try again.")
        case .thisMoment: return L10n.tr("This Moment couldn't be read from the chain just now. Try again.")
        case .momentName: return L10n.tr("A Moment's name couldn't be read from the chain just now. Try again.")
        case .dyorCoin: return L10n.tr("A DyorHQ coin couldn't be read from the chain just now. Try again.")
        }
    }
}

public extension Multicall {
    /// Items per read of a list whose items carry creator text. A launch's text can be about 44 KB (all a transaction
    /// can store), a Moment's name about 20 KB and its media link 40 KB, and Monad refuses an `eth_call` answering more
    /// than about 4.1 MB (its memory then costs more gas than a call may use; 20 items of 44 KB, 0.9 MB, need about
    /// 2.5M gas). 20 such items stay well under it.
    static let textChunk = 20
    /// Items per read of a list of one creator name each (about 20 KB at most): 0.8 MB.
    static let nameChunk = 40
    /// Items per read of fixed-size records (no text): a Moment's or a launch's record is about 0.5 KB.
    static let recordChunk = 200
    /// The most reads of one list in flight at once (`readItems`): its chunks, then its per-item retries, go out this
    /// many at a time, the next as each one answers. The public RPC answers about 50 requests a second and throttles a
    /// burst of 100 (measured), and a long list sent all at once is such a burst.
    static let readsInFlight = 4

    /// The reads of a list, item by item: `items` holds each item's calls, all in the same layout, and `text` the
    /// positions in that layout that read text the item's creator chose. Every other call reads a protocol value, which
    /// the item can't be shown without: if one fails, the read didn't happen as a whole and this throws
    /// (`ChainListUnread`, `what` naming the item). A failed text call is returned as its failure, for the caller to show
    /// a stand-in (`ChainText.unreadable`): the item and its numbers, claims and routing stay. Each item's results come
    /// back in its own layout.
    ///
    /// The items are read in reads of at most `chunk` items, `readsInFlight` reads at a time, so no creator's text,
    /// however long, can make one read too large to answer (`textChunk`), and no list sends the node a burst. A read the
    /// node refuses as a whole (an `eth_call` error about the call itself: out of gas, a revert), and an item one of
    /// whose calls failed inside a read (a long answer before it can starve it of gas), are read again one item at a
    /// time, as many at a time; an item whose read still fails is read once more without its text, which then shows
    /// stand-ins. Any other error (no answer, throttling that outlasted the client's retries) throws: it would fail item
    /// by item too.
    func readItems(_ items: [[ContractCall]], text: Set<Int>, what: ChainListUnread.Item, chunk: Int = textChunk) async throws -> [[Result<[ABIValue], Error>]] {
        guard !items.isEmpty else { return [] }
        let size = max(1, chunk)
        let groups = stride(from: 0, to: items.count, by: size).map { $0 ..< min($0 + size, items.count) }
        var out = [[Result<[ABIValue], Error>]?](repeating: nil, count: items.count)
        var retry: [Int] = []
        try await withThrowingTaskGroup(of: (Range<Int>, Result<[Result<[ABIValue], Error>], Error>).self) { tasks in
            var pending = groups[...]
            func sendNext() {
                guard let group = pending.popFirst() else { return }
                tasks.addTask { (group, await ERC20.captured { try await self.read(group.flatMap { items[$0] }) }) }
            }
            for _ in 0 ..< Self.readsInFlight { sendNext() }
            while let (group, outcome) = try await tasks.next() {
                switch outcome {
                case .success(let results):
                    var start = 0
                    for index in group {
                        let slice = Array(results[start ..< start + items[index].count])
                        start += items[index].count
                        if slice.allSatisfy(Self.succeeded) { out[index] = slice } else { retry.append(index) }
                    }
                case .failure(let error):
                    guard ERC20.isCallError(error) else { throw error }
                    retry += group
                }
                sendNext()
            }
        }
        if !retry.isEmpty {
            try await withThrowingTaskGroup(of: (Int, [Result<[ABIValue], Error>]).self) { tasks in
                var pending = retry[...]
                func sendNext() {
                    guard let index = pending.popFirst() else { return }
                    tasks.addTask { (index, try await self.readAlone(items[index], text: text, what: what)) }
                }
                for _ in 0 ..< Self.readsInFlight { sendNext() }
                while let (index, slice) = try await tasks.next() {
                    out[index] = slice
                    sendNext()
                }
            }
        }
        return try out.map { slice in
            guard let slice else { throw ChainListUnread(what) }
            for (i, result) in slice.enumerated() where !text.contains(i) {
                if case .failure = result { throw ChainListUnread(what) }
            }
            return slice
        }
    }

    /// One item of `readItems`, on its own: all its calls, or, when that read is refused as a whole or a protocol call
    /// in it fails, its protocol calls alone, its text standing in as unread. Throws when its protocol values can't be read.
    private func readAlone(_ calls: [ContractCall], text: Set<Int>, what: ChainListUnread.Item) async throws -> [Result<[ABIValue], Error>] {
        do {
            let slice = try await read(calls)
            if slice.indices.allSatisfy({ text.contains($0) || Self.succeeded(slice[$0]) }) { return slice }
        } catch let error where ERC20.isCallError(error) {}
        let values = calls.indices.filter { !text.contains($0) }
        guard !values.isEmpty, !text.isEmpty else { throw ChainListUnread(what) }
        let read = try await self.read(values.map { calls[$0] })
        var slice = [Result<[ABIValue], Error>](repeating: .failure(ChainListUnread(what)), count: calls.count)
        for (i, result) in zip(values, read) {
            guard Self.succeeded(result) else { throw ChainListUnread(what) }
            slice[i] = result
        }
        return slice
    }

    private static func succeeded(_ result: Result<[ABIValue], Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
