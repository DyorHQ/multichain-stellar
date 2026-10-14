import Foundation
import Observation

/// The swap picker's venue token list (`VenueTokensService`) as the app holds it: read from the store once, off the main
/// actor, and kept in memory, so a search never decodes it (9,405 tokens are 1.8 MB of JSON: 0.1–0.15 s to decode, 0.7 s
/// to encode); brought up to the chain head in the background, one run at a time, never while a wallet's history fills
/// in for the first time, nor from genesis with no wallet signed in (`follow`); and saved only once a segment is read in
/// full or a run
/// dropped addresses, off the main actor, in the format build 16 reads (a JSON array of `Token`), so a downgrade keeps
/// the list.
@Observable
@MainActor
public final class VenueTokenList {
    /// What the store holds: the list as saved, the last block it is read up to in full, and what runs dropped
    /// (`encode(dropped:)`).
    public struct Stored: Sendable {
        public var list: Data?
        public var checkpoint: UInt64
        public var dropped: Data?

        public init(list: Data?, checkpoint: UInt64, dropped: Data? = nil) {
            self.list = list
            self.checkpoint = checkpoint
            self.dropped = dropped
        }
    }

    /// Every token with a pool on a venue, as far as the list is read.
    public private(set) var tokens: [Token] = []
    /// The last block every venue is read up to in full.
    public private(set) var checkpoint: UInt64 = 0
    /// The chain head the last run read towards; nil until a run has read one.
    public private(set) var head: UInt64?
    /// Whether a run is reading.
    public private(set) var isRefreshing = false
    /// Runs in a row that ended short of the chain head: a gap, the head unread, an endpoint down or throttling.
    public private(set) var shortRuns = 0
    /// After `stop()` (Delete Account): nothing runs or is saved again until the app is launched anew.
    public private(set) var isStopped = false
    /// Whether the store has been read.
    public private(set) var isLoaded = false
    /// No wallet is signed in (`follow`): a list that holds nothing read waits for one. False until told.
    private var signedOut = false
    /// The signed-in wallet's history is filling in for the first time this session (`follow`): the run waits for it.
    /// False until told.
    private var historyFilling = false
    /// The wallets whose history has been read to the head, or stalled, once this session (`follow`): the run waits for a
    /// wallet's first fill only. In memory only, a flag per address, gone with the app.
    @ObservationIgnored private var filledOnce: Set<Address> = []

    /// Whether a search may miss a token because the list is short of the chain: the store still being read by the first
    /// run, or the list short of what the last run read towards (`VenueTokensService.target`: a fresh install, the read
    /// build 17 makes once more, a refill under way or paused while the wallet's history fills in, or a run that ended
    /// short, read on at the next return to the app). Before a run has read the head (offline, the endpoint down, or every
    /// run paused so far), short of a block the chain is known to have passed (`VenueTokensService.knownHeight`), so a
    /// list an earlier launch left half-built says so too. The swap picker says so. After `stop()`, nothing reads on, so
    /// nothing is said.
    public var isCatchingUp: Bool {
        guard !isStopped else { return false }
        guard isLoaded else { return isRefreshing }
        return checkpoint < VenueTokensService.target(head: head ?? VenueTokensService.knownHeight)
    }

    /// Whether the run waits (`follow`): while the signed-in wallet's history fills in for the first time, and, with no
    /// wallet signed in, while the list holds nothing read — no token and no checkpoint: a read from genesis. Before the
    /// store is read, the second is decided once it is (`perform`).
    public var isHeld: Bool {
        historyFilling || (signedOut && isLoaded && tokens.isEmpty && checkpoint == 0)
    }

    @ObservationIgnored private let service: VenueTokensService
    @ObservationIgnored private let logos: @Sendable () async -> [Address: URL]
    @ObservationIgnored private let read: @Sendable () -> Stored
    @ObservationIgnored private let write: @MainActor (Data, UInt64, Data) -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    /// When `resume` may run again after a run that ended short.
    @ObservationIgnored private var retryAfter = Date.distantPast
    /// The checkpoint the store holds: moved only by a save the store took.
    @ObservationIgnored private var saved: UInt64 = 0
    /// Addresses a run read with no readable symbol (`VenueTokensService.Progress.dropped`), kept for the runs after it: a
    /// segment a run left short is read again, and what it dropped isn't read again with it. Saved with the checkpoint, so
    /// a segment that needs more reads again than one run allows (`VenueTokensService.metadataRereads`) is read in full
    /// over a few launches, not read from nothing again at each.
    @ObservationIgnored private var dropped: Set<Address> = []
    /// What the store holds of `dropped`, the newest first (`storedDropped(_:after:)`), and what `dropped` held then.
    @ObservationIgnored private var droppedStored: [Address] = []
    @ObservationIgnored private var droppedSaved: Set<Address> = []
    @ObservationIgnored private var run: Task<Void, Never>?
    /// The store's read, under way or done (`loadStore`): one read, however many wait for it — `load` at launch and a
    /// run starting meanwhile each decoded the 1.8 MB list.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Which run may change the list and the store: `stop` moves it on, so a run it cancelled, and a save of that run
    /// already on its way, change nothing. A pause (`follow`) doesn't: what the run it cancels read in full is the list's.
    @ObservationIgnored private var generation = 0

    /// `read` and `write` are the store: `read` runs off the main actor, once; `write` on it, with the list, the checkpoint
    /// and what runs dropped encoded, and says whether the store took them (UserDefaults refuses a value past its ceiling,
    /// and the checkpoint isn't saved then).
    public init(service: VenueTokensService, logos: @escaping @Sendable () async -> [Address: URL], read: @escaping @Sendable () -> Stored,
                write: @escaping @MainActor (Data, UInt64, Data) -> Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.logos = logos
        self.read = read
        self.write = write
        self.now = now
    }

    /// Brings the list up to the chain head in the background (`VenueTokensService.refresh`), unless a run already is, or
    /// the run waits (`isHeld`). The first run reads the store first. Call it once App Lock's default is decided
    /// (`AppSettings`): a save writes keys an earlier install is told apart by.
    public func refresh() {
        guard !isStopped, run == nil, !isHeld else { return }
        isRefreshing = true
        let generation = generation
        run = Task { await perform(generation) }
    }

    /// The signed-in wallet (nil: none) and whether its history is filling in (true too while the app's history isn't on
    /// that wallet yet), as the app has them on every change of either (RootView, once App Lock's default is decided, as
    /// `refresh`), and with them whether the list reads on now (`isHeld`). The run's requests wait behind every screen's
    /// scan and the history's at the app's one gate (`LogsGate.Lane.background`), and besides:
    /// - while a wallet's history fills in for the first time this session (`historyFilling`), the run waits: one under
    ///   way is cancelled at once, and the next reads on from the checkpoint — the end of the last segment it read in full,
    ///   saved as it was read — so a pause costs the segment it was reading at most, read again. In build 22 and earlier a
    ///   run started during onboarding read on, to the head, through a fresh install's first history fill. A run a pause
    ///   cancelled isn't one that ended short (`shortRuns`): the next starts as soon as the history is read, or stalled,
    ///   and at once when that came while the cancelled one was still ending (`perform`).
    /// - once that wallet's history has been read to the head, or stalled, the run no longer waits for it: a round left
    ///   with a gap, or the transfer scans reading further back once the wallet's first transaction is found, fills it in
    ///   again, and pausing on each would cancel the run each time, a segment of up to three venues' requests read again;
    ///   the gate already puts the run behind every history round.
    /// - with no wallet signed in (`wallet` nil), a list that holds nothing read waits for a sign-in: a fresh install reads
    ///   from genesis (about 5,600 requests) only once a wallet is signed in, and search has the curated and Kuru lists
    ///   meanwhile, as it has while the list is empty. A list read before (in part, or build 16's) reads on. There is no
    ///   wallet's history to wait for then: `historyFilling` counts only with a wallet signed in (the app's history with
    ///   no wallet is an empty stand-in, which reads as filling in).
    /// Otherwise the list reads on (`refresh`) — unless the last run ended short and its pause isn't over: a return to the
    /// app after it runs it again (`resume`), as when nothing held it.
    public func follow(wallet: Address?, historyFilling: Bool) {
        signedOut = wallet == nil
        if let wallet, !historyFilling { filledOnce.insert(wallet) }
        self.historyFilling = wallet.map { historyFilling && !filledOnce.contains($0) } ?? false
        if isHeld {
            run?.cancel()
        } else if shortRuns == 0 || now() >= retryAfter {
            refresh()
        }
    }

    /// Before this device's data is erased (Delete Account, Forget This Device): the run under way is cancelled, and
    /// nothing is read or saved again until the app is launched anew. A save after the erase would put the list's
    /// `venueTokens.` keys back in an emptied store, and App Lock's default would then take the next launch for an
    /// install from before it (`AppSettings`, R4) and start OFF. The list in memory stays for search: it is public data.
    public func stop() {
        isStopped = true
        generation += 1
        run?.cancel()
        run = nil
        isRefreshing = false
    }

    /// On a return to the app: runs again when the last run ended short of the chain head, which a cold launch alone
    /// used to retry, after a pause that doubles with each such run in a row (`retryPause`), so an endpoint that is down
    /// or throttling isn't asked again at every return. Nothing when the last run read to the head, one is running, or
    /// the run waits (`isHeld`).
    public func resume() {
        guard shortRuns > 0, now() >= retryAfter else { return }
        refresh()
    }

    /// The pause before the run after `shortRuns` runs in a row ended short: 30 s, doubling, at most 30 min.
    nonisolated static func retryPause(afterShortRuns shortRuns: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, shortRuns - 1))), 1_800)
    }

    /// Waits for the run under way, if any.
    public func finished() async {
        await run?.value
    }

    /// Reads the stored list, so search has it at once; the run that brings it up to the chain head is `refresh`,
    /// which may come later (`follow`: once the wallet's history has been read). Nothing after `stop()`, or once read.
    public func load() async {
        guard !isStopped, !isLoaded else { return }
        await loadStore(generation)
    }

    /// The store into memory, read once: a load or a run that comes while it is read waits for that read.
    private func loadStore(_ generation: Int) async {
        if loading == nil {
            let read = self.read
            loading = Task { [weak self] in
                let stored = await Task.detached(priority: .utility) { Self.decode(read()) }.value
                self?.take(stored, generation)
            }
        }
        await loading?.value
    }

    /// What the store held, into memory, unless `stop()` was called while it was read.
    private func take(_ stored: (tokens: [Token], checkpoint: UInt64, dropped: [Address]), _ generation: Int) {
        guard generation == self.generation, !isLoaded else { return }
        tokens = stored.tokens
        checkpoint = stored.checkpoint
        saved = stored.checkpoint
        dropped.formUnion(stored.dropped)
        droppedStored = stored.dropped
        droppedSaved = dropped
        isLoaded = true
    }

    private func perform(_ generation: Int) async {
        if !isLoaded { await loadStore(generation) }
        // Stopped meanwhile: `stop()` ended the run, and nothing after it reads, saves or starts another (R4).
        guard generation == self.generation else { return }
        // Held while the store was read (`follow`) — paused, or no wallet signed in and the store held nothing read — or
        // cancelled by a pause: nothing is read, and this is no run that ended short.
        if isLoaded, !isHeld, !Task.isCancelled {
            let result = await service.refresh(tokens: tokens, checkpoint: checkpoint, dropped: dropped, logos: logos) { [weak self] progress in
                guard let self, await self.show(progress, generation) else { return }
                let data = await Task.detached(priority: .utility) { Self.encode(progress.tokens) }.value
                if let data { await self.store(data, checkpoint: progress.checkpoint, dropped: progress.dropped, generation) }
            }
            guard generation == self.generation else { return } // stopped meanwhile (R4), as above
            // Nothing read (the head couldn't be read): the list is as it was, and so is what the picker says.
            if let result { head = result.head; dropped = result.dropped }
            if result?.complete == true {
                shortRuns = 0
            } else if !Task.isCancelled {
                // Short on its own account (a gap, the head unread, an endpoint down or throttling). One a pause cancelled
                // (`follow`) isn't: it reads on as soon as nothing holds it, with no pause before.
                shortRuns += 1
                retryAfter = now().addingTimeInterval(Self.retryPause(afterShortRuns: shortRuns))
            }
        }
        run = nil
        isRefreshing = false
        // Cancelled by a pause that lifted while this run was ending (`follow` found it still running): the next run
        // starts now, from the checkpoint. Nothing while the run still waits (`refresh`). A task started here doesn't
        // inherit this one's cancellation.
        if Task.isCancelled { refresh() }
    }

    /// A run's progress, in memory at once; whether the store should follow: only once the checkpoint moved or the run
    /// dropped more, so a segment read in part, or one to be read again for more tokens than a read keeps, costs no save
    /// unless it dropped addresses.
    private func show(_ progress: VenueTokensService.Progress, _ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        tokens = progress.tokens
        checkpoint = progress.checkpoint
        head = progress.head
        dropped = progress.dropped
        return progress.checkpoint != saved || progress.dropped.count != droppedSaved.count
    }

    /// Checked here, on the main actor with the write: an erase runs there too, so it comes before this save (which then
    /// writes nothing) or after it (and erases it). A save the store declined is tried again with the next progress.
    private func store(_ list: Data, checkpoint: UInt64, dropped: Set<Address>, _ generation: Int) {
        guard generation == self.generation else { return }
        let kept = Self.storedDropped(dropped.subtracting(droppedSaved), after: droppedStored)
        guard write(list, checkpoint, Self.encode(dropped: kept)) else { return }
        saved = checkpoint
        droppedStored = kept
        droppedSaved = dropped
    }

    /// The most addresses of what runs dropped the store keeps: 100 KB. A list read from genesis drops a handful (3 on
    /// 2026-09-30); past this, only addresses put in pools in bulk.
    nonisolated static let maxStoredDropped = 5_000

    /// What the store keeps, the newest first: what was `dropped` since it last saved that `stored` (the store's, newest
    /// first) lacks, then `stored`, at most `maxStoredDropped`, so a segment read again keeps what its own runs dropped.
    nonisolated static func storedDropped(_ dropped: Set<Address>, after stored: [Address]) -> [Address] {
        let known = Set(stored)
        return Array((dropped.filter { !known.contains($0) } + stored).prefix(maxStoredDropped))
    }

    /// Addresses as the store keeps them: 20 bytes each, one after the other.
    nonisolated static func encode(dropped: [Address]) -> Data {
        dropped.reduce(into: Data()) { $0.append($1.data) }
    }

    /// The addresses `encode(dropped:)` stored, at most `maxStoredDropped`; none from what isn't such a list.
    nonisolated static func decode(dropped data: Data?) -> [Address] {
        guard let data, !data.isEmpty, data.count % 20 == 0 else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 20).prefix(maxStoredDropped).compactMap { Address(data: Data(bytes[$0 ..< $0 + 20])) }
    }

    /// The stored list, its symbols and names capped (`VenueTokensService.capped`), its checkpoint, and what runs dropped.
    /// A list that can't be read back is read again from genesis: its checkpoint would skip every token it held.
    nonisolated static func decode(_ stored: Stored) -> (tokens: [Token], checkpoint: UInt64, dropped: [Address]) {
        let dropped = decode(dropped: stored.dropped)
        guard let data = stored.list, let list = try? JSONDecoder().decode([Token].self, from: data) else { return ([], 0, dropped) }
        return (list.map(VenueTokensService.capped), stored.checkpoint, dropped)
    }

    /// The list as build 16 stores it.
    nonisolated static func encode(_ tokens: [Token]) -> Data? {
        try? JSONEncoder().encode(tokens)
    }
}
