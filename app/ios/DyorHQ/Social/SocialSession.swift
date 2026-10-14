import DyorKit
import Foundation
import Observation
import Security

/// The DyorHQ social/backend session: signs in to Supabase by having the Privy wallet sign a nonce (login stays in
/// Privy), keeps the resulting token in the Keychain, and manages the wallet's public profile. Everything else
/// (feed, follows, watchlists, alerts) builds on this session and its `SupabaseClient`.
@Observable
@MainActor
final class SocialSession {
    enum State: Equatable { case signedOut, signingIn, signedIn }

    private(set) var state: State = .signedOut
    private(set) var profile: SocialProfile?
    private(set) var error: String?
    let client: SupabaseClient
    /// The wallet the social session is currently bound to (lowercased address), so a wallet change is detected.
    private var boundWallet: String?
    /// The open `sessions` row for this app session, persisted per wallet so a sign-out after an app relaunch can
    /// still close the same row.
    private var currentSessionRowId: String?
    /// The wallet-auth sign-in in flight and the wallet it is for. A second request for the same wallet while it runs
    /// (RootView's, while `signInWithMera`'s runs in the background) waits for it instead of signing a second nonce.
    private var pending: (wallet: String, task: Task<Void, Never>)?
    /// The stored token `bind` is restoring, and the wallet it is for. It is this launch's sign-in: a sign-in for the same
    /// wallet meanwhile waits for it, and signs a nonce only if the token didn't restore — never a second `sessions` row
    /// beside it (security audit 2026-09-26, RS-3).
    private var restoring: (wallet: String, task: Task<Void, Never>)?
    /// The access token of the session this object adopted, so a sign-out that finishes late ends that session only,
    /// never a newer one adopted meanwhile (RS-6).
    private var adoptedToken: String?
    /// Profile work still running — a restored session's (`bind`), a sign-in's follow-up (`startSignIn`, which a new
    /// passkey account doesn't await) — each of which upserts the profile row. Each removes itself when done. Account
    /// deletion waits them out first (`settle`), so a late upsert can't recreate the row it just deleted.
    private var profileWork: [UUID: Task<Void, Never>] = [:]
    /// Ends the adopted backend token's `.signedIn` a minute before it expires (12 h after wallet-auth issued it), so a
    /// dead token never reads as signed in and the next prompt-free sign-in (RootView when a passkey session opens,
    /// Bridge on open, any screen that signs in) gets a new one.
    @ObservationIgnored private var expiry: Task<Void, Never>?

    var isSignedIn: Bool { state == .signedIn }
    /// Whether this session belongs to `address` (after `bind`, or a sign-in started for it).
    func isBound(to address: Address) -> Bool { boundWallet == address.checksummed.lowercased() }

    init(config: AppConfig) {
        client = SupabaseClient(url: config.supabaseURL, anonKey: config.supabaseKey)
    }

    /// Binds the social session to the active wallet. Called whenever the signed-in wallet changes (sign in, sign
    /// out, or switch accounts), so the social identity always matches the current wallet — there is no separate
    /// social sign-out. A different wallet (or none) immediately drops the previous wallet's in-memory session so a
    /// stale profile can never show; a genuine wallet sign-out (wallet → none) also clears the stored token, fully
    /// signing out of social. A stored session is only ever reused when it belongs to exactly this wallet.
    func bind(address: Address?) {
        let target = address?.checksummed.lowercased()
        guard target != boundWallet else { return }
        let previous = boundWallet
        boundWallet = target

        // Full wallet sign-out: the stored token goes now, the sign-out time is recorded on the still-authed session,
        // then that session (only that one) ends.
        if target == nil {
            let token = adoptedToken, rowId = currentSessionRowId
            state = .signedOut; profile = nil; error = nil
            cancelExpiry()
            adoptedToken = nil; currentSessionRowId = nil
            if previous != nil { SupabaseSessionStore.clear() }
            Task {
                if let previous { await closeSession(wallet: previous, id: rowId) }
                if let token { await client.signOut(ifAccessToken: token) }
            }
            return
        }

        reset() // switching to a different wallet: drop the previous wallet's in-memory session
        guard let target, let stored = SupabaseSessionStore.load(), stored.wallet == target, stored.isValid else { return }
        // The stored token is this launch's sign-in (RS-3): registered before anyone can ask for a sign-in, so RootView's
        // joins it (`signIn(address:wallet:)`) instead of signing a second nonce alongside it.
        let task = Task { @MainActor in
            defer { if self.restoring?.wallet == target { self.restoring = nil } }
            await self.client.restore(stored)
            guard await self.client.currentSession?.accessToken == stored.accessToken else { return }
            // Signed out or switched while it restored: drop exactly what this restored (RS-6). No later sign-out would,
            // since this object never adopted it.
            guard self.boundWallet == target else { await self.client.signOut(ifAccessToken: stored.accessToken); return }
            self.adopted(stored)
            self.trackProfileWork {
                try? await self.ensureProfile(wallet: target) // safety net: a returning wallet always has a profile
                await self.openSession(wallet: target)        // a restored session on launch is this app-session's sign-in
                await self.loadProfile()
            }
        }
        restoring = (target, task)
    }

    /// Waits for the sign-in in flight, a stored token's restore, and all profile work (`profileWork`). Account
    /// deletion calls it before deleting the profile row, which any of them could otherwise recreate afterwards.
    func settle() async {
        if let restoring { await restoring.task.value }
        if let pending { await pending.task.value }
        while let running = profileWork.values.first { await running.value }
    }

    /// Runs `work` as profile work (`profileWork`), which removes itself when done. The task can't start before it is
    /// recorded: both run on the main actor, and this holds it until then.
    @discardableResult
    private func trackProfileWork(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await work()
            self.profileWork[id] = nil
        }
        profileWork[id] = task
        return task
    }

    /// Clears the in-memory session (keeps any stored token). Used when rebinding to a different wallet: the session
    /// this object adopted ends, never one adopted after it (RS-6).
    private func reset() {
        if let token = adoptedToken { Task { await client.signOut(ifAccessToken: token) } }
        adoptedToken = nil
        cancelExpiry()
        state = .signedOut
        profile = nil
        error = nil
    }

    /// `session` is the client's now: signed in until a minute before it expires, for as long as this wallet stays bound.
    private func adopted(_ session: SupabaseSession) {
        adoptedToken = session.accessToken
        state = .signedIn
        expiry?.cancel()
        let wallet = boundWallet
        let ends = session.expiresAt.addingTimeInterval(-60)
        expiry = Task { @MainActor [weak self] in
            let delay = ends.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.boundWallet == wallet, self.state == .signedIn else { return }
            // The wallet stays bound and the stored token is left to expire; the client already treats it as gone
            // (`SupabaseSession.isValid`), so only the state needs to follow.
            self.expiry = nil
            self.state = .signedOut
        }
    }

    private func cancelExpiry() {
        expiry?.cancel()
        expiry = nil
    }

    func signIn(session: Session) async {
        guard let wallet = session.wallet, let address = session.address else { error = SessionError.readOnly.localizedDescription; return }
        await signIn(address: address, wallet: wallet)
    }

    /// Signs in as `address` with `wallet`, or waits for the sign-in already in flight for it. A stored token being
    /// restored for it is waited for first, and a nonce is signed only if it didn't restore (RS-3).
    func signIn(address: Address, wallet: any Wallet) async {
        let target = address.checksummed.lowercased()
        if let restoring, restoring.wallet == target {
            await restoring.task.value
            guard !isSignedIn, boundWallet == target else { return }
        }
        await startSignIn(address: address, wallet: wallet).value
    }

    /// Starts the wallet-auth sign-in for `address` (or returns the one in flight for it) without waiting. Synchronous
    /// up to the network: the session is bound to this wallet before the call returns, so an account published in the
    /// same main-actor turn (`Session.signInWithMera`) finds it bound when RootView rebinds, and the rebind leaves the
    /// sign-in alone instead of resetting it. With `profileInBackground` (a new passkey account), the task ends once
    /// wallet-auth has answered — whoever joins it (RootView's restore) goes on — and the profile row, this
    /// app-session's `sessions` row and the profile load follow on their own. A passkey account's background signer
    /// that finds its session ended (`MeraSession.Failure.promptNeeded`) skips the sign-in quietly: no error, and
    /// RootView retries once the account can sign without a prompt.
    @discardableResult
    func startSignIn(address: Address, wallet: any Wallet, profileInBackground: Bool = false) -> Task<Void, Never> {
        #if DEBUG && targetEnvironment(simulator)
        // Simulator test mode: a passkey account the stub derived never signs in to the (production) backend — its key
        // sits in plain UserDefaults (`MeraSession.isStub`). Every wallet-auth sign-in comes through here, so each one
        // is skipped quietly, before any request: no error, the state as it was.
        if Self.isStubSigner(wallet) { return Task {} }
        #endif
        let target = address.checksummed.lowercased()
        if let pending, pending.wallet == target { return pending.task }
        if boundWallet != target { profile = nil; boundWallet = target }
        state = .signingIn
        error = nil
        let task = Task {
            defer { if pending?.wallet == target { pending = nil } }
            do {
                // Not adopted by the client yet: another wallet may be bound by the time wallet-auth answers.
                let created = try await client.signIn(address: address.checksummed, adopt: false) { message in try await wallet.signMessage(message) }
                // The app moved on (signed out, or another wallet) while wallet-auth answered: don't adopt it.
                guard boundWallet == target else { return }
                await client.restore(created)
                // It moved on during that hop: drop exactly what was just restored (RS-6), which no later sign-out would.
                guard boundWallet == target else { await client.signOut(ifAccessToken: created.accessToken); return }
                SupabaseSessionStore.save(created)
                boundWallet = created.wallet
                adopted(created)
                let followUp = trackProfileWork {
                    try? await self.ensureProfile(wallet: created.wallet)
                    await self.openSession(wallet: created.wallet)
                    await self.loadProfile()
                }
                if !profileInBackground { await followUp.value }
            } catch {
                // Superseded (signed out, or another wallet signed in meanwhile): leave that wallet's state alone.
                guard boundWallet == target else { return }
                state = .signedOut
                // A background signer that needed a prompt, or a passkey prompt the person dismissed, is no error.
                if case MeraSession.Failure.promptNeeded = error { return }
                if isUserCancellation(error) { return }
                self.error = describe(error)
            }
        }
        pending = (target, task)
        return task
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Whether `wallet` is a passkey account's signer whose session runs on the Simulator stub.
    private static func isStubSigner(_ wallet: any Wallet) -> Bool {
        if let signer = wallet as? MeraWallet { return signer.session.isStub }
        if let signer = wallet as? MeraBackgroundSigner { return signer.session.isStub }
        return false
    }
    #endif

    /// Full sign-out: the stored token is cleared at once, the sign-out time is recorded on the still-authed session,
    /// then that session ends — only that one, so a sign-in that finishes meanwhile keeps its session (RS-6).
    func signOut() {
        let wallet = boundWallet, token = adoptedToken, rowId = currentSessionRowId
        state = .signedOut; profile = nil; error = nil
        cancelExpiry()
        boundWallet = nil; adoptedToken = nil; currentSessionRowId = nil
        SupabaseSessionStore.clear()
        Task {
            if let wallet { await closeSession(wallet: wallet, id: rowId) } // on the still-authed session
            if let token { await client.signOut(ifAccessToken: token) }
        }
    }

    /// Make sure a profile row exists so foreign keys (activity, sessions, posts, follows, watchlists) resolve and the
    /// user has a profile to edit. Called on every sign-in and session restore, so creating an account, importing a
    /// private key, or using a passkey all auto-create the profile.
    private func ensureProfile(wallet: String) async throws {
        struct Row: Encodable { let wallet: String }
        let _: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet), onConflict: "wallet")
    }

    // MARK: Sessions (sign-in / sign-out analytics)

    private struct SessionRow: Decodable { let id: String }
    private static func sessionKey(_ wallet: String) -> String { "session.rowid.\(wallet)" }

    /// Opens a `sessions` row (client-generated id) marking this app-session's sign-in. Best-effort; a failure never
    /// blocks sign-in. The id is persisted per wallet so a later sign-out can close exactly this row.
    private func openSession(wallet: String) async {
        let id = UUID().uuidString.lowercased()
        struct Row: Encodable { let id: String; let wallet: String }
        let opened: SessionRow? = try? await client.upsert("sessions", Row(id: id, wallet: wallet), onConflict: "id")
        guard opened != nil else { return }
        currentSessionRowId = id
        UserDefaults.standard.set(id, forKey: Self.sessionKey(wallet))
    }

    /// Stamps `signed_out_at` on the wallet's open session row (`id`, this app-session's, else the one persisted for the
    /// wallet). Must run while the client is still authed.
    private func closeSession(wallet: String, id: String?) async {
        guard let id = id ?? UserDefaults.standard.string(forKey: Self.sessionKey(wallet)) else { return }
        struct Row: Encodable { let id: String; let wallet: String; let signed_out_at: String }
        let _: SessionRow? = try? await client.upsert("sessions", Row(id: id, wallet: wallet, signed_out_at: Self.iso(Date())), onConflict: "id")
        // Only this row's record: a sign-in since may have opened (and persisted) a newer one.
        if UserDefaults.standard.string(forKey: Self.sessionKey(wallet)) == id { UserDefaults.standard.removeObject(forKey: Self.sessionKey(wallet)) }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    func loadProfile() async {
        guard let wallet = await client.signedInWallet else { return }
        let rows: [SocialProfile] = (try? await client.read("profiles", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "wallet", value: "eq.\(wallet)"),
        ], authed: true)) ?? []
        profile = rows.first
    }

    func save(handle: String?, displayName: String?, bio: String?) async throws {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        struct Row: Encodable {
            let wallet: String
            let handle: String?
            let display_name: String?
            let bio: String?
        }
        let clean: (String?) -> String? = { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        let updated: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet, handle: clean(handle)?.lowercased(), display_name: clean(displayName), bio: clean(bio)), onConflict: "wallet")
        profile = updated
    }

    /// Uploads a launchpad coin image to the wallet's folder in the public `launch-media` bucket and returns its
    /// public URL — which the caller writes on-chain as the token's logo. Requires a DyorHQ Social session. The bucket
    /// is write-once (its URLs go on-chain) and every logo gets a fresh name.
    func uploadLaunchImage(jpeg: Data) async throws -> URL {
        guard await client.signedInWallet != nil else { throw SupabaseError.notSignedIn }
        let wallet = await client.signedInWallet!
        let name = UUID().uuidString.lowercased()
        return try await client.uploadPublic(bucket: "launch-media", path: "\(wallet)/\(name).jpg", data: jpeg, contentType: "image/jpeg", upsert: false)
    }

    /// Moment media in the wallet's folder of the public `launch-media` bucket: its object path (what `pinMomentMedia`
    /// pins) and its public URL, the fast in-app mirror.
    struct MomentUpload: Sendable {
        let path: String
        let mirror: URL
    }

    /// Uploads Moment media (a photo, or a video's cover frame) to the public bucket. The object is named after the
    /// keccak-256 of `data` (`moment-<hash>`), so the mirror can be derived later from the on-chain provenance alone
    /// (`MomentsMath.mirrorURL`); pass `name` to file it under another hash — a video's poster frame is stored under
    /// the video's hash, which is the hash the NFT records — or under its own when it is already known (a photo, hashed
    /// off the main thread with its encoding, so it isn't hashed again here). The bucket is write-once: an object already
    /// there under that name was uploaded from the same bytes (or, for a poster, the same video), so it is used as is.
    func uploadMomentMedia(_ data: Data, contentType: String, fileExtension: String, name: String? = nil) async throws -> MomentUpload {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        let path = "\(wallet)/\(name ?? MomentsMath.mediaName(hash: Keccak.hash256(data))).\(fileExtension)"
        do {
            return MomentUpload(path: path, mirror: try await client.uploadPublic(bucket: "launch-media", path: path, data: data, contentType: contentType, upsert: false))
        } catch where SupabaseClient.isDuplicateUpload(error) {
            return MomentUpload(path: path, mirror: client.publicURL(bucket: "launch-media", path: path))
        }
    }

    /// `uploadMomentMedia` for a file on disk (a picked video), streamed from the file so it is never read into memory
    /// whole. `hash` is the keccak-256 of its bytes (`Keccak.hash256(file:)`), which names the object.
    func uploadMomentMedia(file: URL, hash: Data, contentType: String, fileExtension: String) async throws -> MomentUpload {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        let path = "\(wallet)/\(MomentsMath.mediaName(hash: hash)).\(fileExtension)"
        do {
            return MomentUpload(path: path, mirror: try await client.uploadPublic(bucket: "launch-media", path: path, file: file, contentType: contentType, upsert: false))
        } catch where SupabaseClient.isDuplicateUpload(error) {
            return MomentUpload(path: path, mirror: client.publicURL(bucket: "launch-media", path: path))
        }
    }

    /// Pins uploaded Moment media to IPFS and returns its `ipfs://` URI, the NFT's permanent on-chain pointer that
    /// outlives DyorHQ's servers. Throws when pinning fails or times out: the caller shows that before anything is
    /// published, and the https mirror is never written on-chain in its place without the user choosing it (security
    /// audit 2026-09-26, RI-9).
    func pinMomentMedia(_ upload: MomentUpload) async throws -> String {
        try await client.pinToIPFS(bucket: "launch-media", path: upload.path)
    }

    /// Uploads a new profile picture (JPEG bytes) to the wallet's own folder in the public `avatars` bucket, then
    /// records its URL on the profile. A cache-busting query is appended so the new image shows immediately — on this
    /// phone from the bytes just uploaded (`ImagePipeline.seed`), with no read back.
    func uploadAvatar(jpeg: Data) async throws {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = try await client.uploadPublic(bucket: "avatars", path: "\(wallet)/avatar.jpg", data: jpeg, contentType: "image/jpeg")
        let cacheBusted = "\(url.absoluteString)?v=\(stamp)"
        struct Row: Encodable { let wallet: String; let avatar_url: String }
        let updated: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet, avatar_url: cacheBusted), onConflict: "wallet")
        if let shown = URL(string: updated.avatar_url ?? cacheBusted) {
            RemoteImageLoader.shared.seed(jpeg, for: [RemoteImageSource(url: shown)])
        }
        profile = updated
    }
}

/// A public DyorHQ profile row.
struct SocialProfile: Codable, Identifiable, Equatable {
    let wallet: String
    var handle: String?
    var display_name: String?
    var bio: String?
    var avatar_url: String?
    var id: String { wallet }
}

/// Keychain storage for the short-lived Supabase session token (a bearer token, never a key).
enum SupabaseSessionStore {
    private static let service = "fun.dyorhq.supabase"
    private static let account = "session"

    static func save(_ session: SupabaseSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: session token stays on this device only
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> SupabaseSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
