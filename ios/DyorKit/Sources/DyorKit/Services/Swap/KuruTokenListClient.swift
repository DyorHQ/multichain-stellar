import Foundation

/// Kuru's public, unauthenticated token directory — searchable across (almost) every token tradeable on Monad,
/// hundreds of them, most with real logos. This is the broad token list behind the swap picker's search box, so a
/// person can find any Monad asset by symbol, name, or pasted address without it being curated in the app.
///
/// Uses the data host `api.kuru.io` (GET, no auth), distinct from the Flow quote host `ws.kuru.io` the swap engine
/// already uses. Search results are cached per query for the session; the logo directory (`logos`) is kept on the phone
/// for a day.
public actor KuruTokenListClient {
    private let session: URLSession
    private var cache: [String: [Token]] = [:]
    /// The logo directory and when it was read from Kuru: from the file at first use, then from each read.
    private var logoCache: (logos: [Address: URL], readAt: Date)?
    private var loadedSavedLogos = false
    /// The read of the directory under way: a caller that asks meanwhile waits for it rather than download it again.
    private var logosRead: Task<[Address: URL], Never>?
    /// When the last read failed: Kuru isn't asked again for `logosRetryAfter`.
    private var logosFailedAt: Date?
    private let logosFile: URL?
    private let now: @Sendable () -> Date

    /// How long the directory is used before Kuru is asked again: its logos change rarely, and the markets list it comes
    /// from is about 800 KB, which took about 6 s to arrive (measured 2026-10-08).
    public static let logosLifetime: TimeInterval = 86_400
    /// How long after a failed read Kuru isn't asked again; the last directory read, if any, is used meanwhile.
    public static let logosRetryAfter: TimeInterval = 300

    /// The directory's file, in the app's Caches folder: Kuru's public list, the same on every phone, holding nothing of
    /// who uses this one.
    public static var defaultLogosFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("kuru-logos-v1.json")
    }

    /// `logosFile`: where the logo directory is kept between launches; nil keeps it in memory only.
    public init(session: URLSession = .shared, logosFile: URL? = KuruTokenListClient.defaultLogosFile, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.logosFile = logosFile
        self.now = now
    }

    /// A bulk address → logo map from Kuru's markets (hundreds of Monad tokens with real CDN icons), for enriching
    /// tokens discovered on-chain or from venue pools — the practical renderable logo source (the canonical Monad
    /// token-list ships SVGs, which the app can't draw, and so are left out here too). Read from Kuru at most once a day
    /// (`logosLifetime`): the directory kept on the phone answers in between, with no network, from the first call after a
    /// launch. One older than that still answers at once while Kuru is read again behind it; with none, the call waits for
    /// that read. A read that fails, or brings no logo at all, keeps the last directory read (empty when there is none)
    /// and isn't tried again for `logosRetryAfter`, never for the rest of the session. One read at a time.
    public func logos() async -> [Address: URL] {
        if !loadedSavedLogos {
            loadedSavedLogos = true
            if logoCache == nil, let saved = Self.readSaved(logosFile) { logoCache = saved }
        }
        let time = now()
        if let logoCache, logoCache.readAt <= time, time.timeIntervalSince(logoCache.readAt) < Self.logosLifetime { return logoCache.logos }
        if let failed = logosFailedAt, time.timeIntervalSince(failed) < Self.logosRetryAfter { return logoCache?.logos ?? [:] }
        let read = logosRead ?? startLogosRead()
        if let logoCache { return logoCache.logos }
        return await read.value
    }

    /// Whether a read of the directory is under way.
    var readingLogos: Bool { logosRead != nil }

    private func startLogosRead() -> Task<[Address: URL], Never> {
        let read = Task {
            let logos = await self.readLogos()
            self.logosRead = nil
            return logos
        }
        logosRead = read
        return read
    }

    /// One read of the directory from Kuru: kept in memory and on the phone when it brings logos; otherwise the last one.
    private func readLogos() async -> [Address: URL] {
        guard let fetched = await Self.fetchLogos(session: session), !fetched.isEmpty else {
            logosFailedAt = now()
            return logoCache?.logos ?? [:]
        }
        let readAt = now()
        logoCache = (fetched, readAt)
        logosFailedAt = nil
        Self.save(fetched, readAt: readAt, to: logosFile)
        return fetched
    }

    /// Kuru's markets, read into an address → logo map (an SVG logo left out: ImageIO can't draw one, so it would only
    /// hold a download slot and then show letters). Nil when they couldn't be read.
    private static func fetchLogos(session: URLSession) async -> [Address: URL]? {
        guard var components = URLComponents(url: Kuru.dataApi.appending(path: "api/v1/markets"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "limit", value: "500")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
        return parseLogos(data)
    }

    /// The address → logo map in a markets answer: each market's base and quote token with an address and an image URL
    /// that isn't an SVG. Nil when the answer isn't the markets JSON.
    static func parseLogos(_ data: Data) -> [Address: URL]? {
        guard let json = try? JSONDecoder().decode(JSON.self, from: data), let markets = json["data"]["data"].array else { return nil }
        var map: [Address: URL] = [:]
        for market in markets {
            for side in ["basetoken", "quotetoken"] {
                let token = market[side]
                if let addressString = token["address"].string, let address = Address(addressString),
                   let logoString = token["imageurl"].string, let logo = URL(string: logoString), logo.pathExtension.lowercased() != "svg" {
                    map[address] = logo
                }
            }
        }
        return map
    }

    // MARK: The directory on the phone

    /// The directory as it is saved: when it was read from Kuru, and each token's logo by its address.
    struct SavedLogos: Codable {
        let readAt: Date
        let logos: [String: String]
    }

    private static func readSaved(_ file: URL?) -> (logos: [Address: URL], readAt: Date)? {
        guard let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(SavedLogos.self, from: data) else { return nil }
        var logos: [Address: URL] = [:]
        for (address, logo) in saved.logos {
            guard let address = Address(address), let url = URL(string: logo), url.pathExtension.lowercased() != "svg" else { continue }
            logos[address] = url
        }
        return logos.isEmpty ? nil : (logos, saved.readAt)
    }

    private static func save(_ logos: [Address: URL], readAt: Date, to file: URL?) {
        guard let file else { return }
        let saved = SavedLogos(readAt: readAt, logos: Dictionary(uniqueKeysWithValues: logos.map { ($0.key.hex, $0.value.absoluteString) }))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Deletes the saved directory (Forget This Device, Delete Account): the phone as a new install finds it. A read under
    /// way may save it again — Kuru's public list, nothing of the account.
    public static func removeSavedLogos(at file: URL? = defaultLogosFile) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Tokens matching `query` — a symbol, a name, or a pasted 0x address. An empty query returns Kuru's default
    /// top list. Returns an empty array on any network/parse failure (the picker falls back to its local universe).
    public func search(_ query: String) async -> [Token] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cache[key] { return cached }
        guard var components = URLComponents(url: Kuru.dataApi.appending(path: "api/v1/tokens/search"), resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: key)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let json = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }

        // Rank the noisy long tail: an exact ticker/address match first, then verified tokens, keeping Kuru's order
        // within each group — so the real asset surfaces above look-alike scams that merely contain the query.
        let rows = (json["data"]["data"].array ?? []).enumerated().sorted { a, b in
            let (ra, rb) = (Self.rank(a.element, query: key), Self.rank(b.element, query: key))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var out: [Token] = []
        var seen = Set<Address>()
        for row in rows {
            guard let token = Self.token(from: row), seen.insert(token.address).inserted else { continue }
            out.append(token)
        }
        cache[key] = out
        return out
    }

    /// Lower rank = shown first: 0 exact ticker/address match, 1 verified/strict, 2 everything else.
    private static func rank(_ row: JSON, query: String) -> Int {
        let ticker = (row["ticker"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = (row["address"].string ?? "").lowercased()
        if ticker == query || address == query { return 0 }
        if row["is_verified"].bool == true || row["is_strict"].bool == true { return 1 }
        return 2
    }

    /// Maps a Kuru token row onto the app's `Token`. Sanitizes the noisy long tail (names carry leading tabs/emoji)
    /// and accepts `decimal` as either a number (search endpoint) or a string (markets endpoint).
    private static func token(from row: JSON) -> Token? {
        guard let addressString = row["address"].string, let address = Address(addressString) else { return nil }
        let symbol = (row["ticker"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { return nil }
        var name = (row["name"].string ?? symbol).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = symbol }
        let decimals = row["decimal"].number.flatMap { Int(exactly: $0) } ?? Int(row["decimal"].string ?? "") ?? 18
        // The API's word, not the chain's: never trap on it, and drop rows no ERC-20 could have (0…36, as ERC20.metadata).
        guard (0...36).contains(decimals) else { return nil }
        let logo = row["imageurl"].string.flatMap { URL(string: $0) }
        return Token(address: address, symbol: symbol, name: name, decimals: decimals, logoURL: logo)
    }
}
