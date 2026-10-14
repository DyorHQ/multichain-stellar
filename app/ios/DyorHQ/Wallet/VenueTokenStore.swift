import DyorKit
import Foundation

/// A global (not per-wallet) cache of tokens that trade on Monad's venues — Uniswap and Monday Trade. It feeds the swap
/// picker's search so any real Monad asset is one tap away with its accurate symbol and logo, without reading balances
/// for hundreds of tokens on every home load. The store only: `VenueTokenList` reads it once, keeps the list in memory
/// and saves it past each segment read in full.
enum VenueTokenStore {
    private static let key = "venueTokens.v1"
    private static let stampKey = "venueTokens.v1.updatedAt"
    /// The checkpoint (`VenueTokensService.refresh`). Build 16's, `venueTokens.v1.lastBlock`, moved on past ranges its
    /// scan had left unread, so this one starts at 0: every install reads the whole history once more, in the background,
    /// keeping its list and adding what the gaps hid. Build 16's is left as it was, for a reinstall of build 16, and
    /// what build 16 writes there never counts here. Not a `venueTokens.` key: a key with that prefix marks an install as
    /// earlier than App Lock's default (`AppSettings`), which no new key may do.
    private static let blockKey = "venueScan.v2.lastBlock"
    /// What runs dropped (`VenueTokenList.encode(dropped:)`), saved with the checkpoint, so a segment left short is read on
    /// at the next launch without reading it again. Not a `venueTokens.` key either.
    private static let droppedKey = "venueScan.v2.dropped"
    private static let ttl: TimeInterval = 86_400

    /// The list as saved (a JSON array of `Token`), the last block every venue has been read up to in full, so the next
    /// refresh only reads on from there (0 = never read → full history), and what runs dropped.
    static func read() -> VenueTokenList.Stored {
        VenueTokenList.Stored(list: UserDefaults.standard.data(forKey: key), checkpoint: UInt64(UserDefaults.standard.string(forKey: blockKey) ?? "") ?? 0,
                              dropped: UserDefaults.standard.data(forKey: droppedKey))
    }

    /// True when the cache is older than a day, so the caller scans the new tail.
    static func isStale() -> Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: stampKey) > ttl
    }

    /// Saves the list, and its checkpoint only once the list reads back as written: UserDefaults refuses a value past its
    /// ceiling (about 4 MB; the list is about 1.8 MB) and keeps what it had, and a checkpoint saved without its list would
    /// skip every token the list saved before it lacks. The checkpoint then stays where it was, and so do the stamp and
    /// what runs dropped. Returns whether it was saved.
    @discardableResult
    static func write(_ list: Data, lastBlock: UInt64, dropped: Data) -> Bool {
        UserDefaults.standard.set(list, forKey: key)
        guard UserDefaults.standard.data(forKey: key) == list else { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)
        UserDefaults.standard.set(String(lastBlock), forKey: blockKey)
        UserDefaults.standard.set(dropped, forKey: droppedKey)
        return true
    }
}
