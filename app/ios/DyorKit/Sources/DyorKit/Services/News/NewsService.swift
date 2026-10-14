import Foundation

/// One headline from a crypto news feed.
public struct NewsArticle: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let link: URL
    public let source: String
    public let published: Date?
    public let summary: String
    public let imageURL: URL?

    public init(id: String, title: String, link: URL, source: String, published: Date?, summary: String, imageURL: URL?) {
        self.id = id
        self.title = title
        self.link = link
        self.source = source
        self.published = published
        self.summary = summary
        self.imageURL = imageURL
    }
}

/// A news source: its public RSS feed.
public struct NewsSource: Sendable, Hashable, Identifiable {
    public let name: String
    public let feed: URL
    public var id: String { name }
    public init(name: String, feed: URL) {
        self.name = name
        self.feed = feed
    }
}

/// Crypto news from the major outlets' public RSS feeds, merged newest first. No API keys, no tracking: the app
/// fetches the feeds directly and opens articles on the publisher's site.
public actor NewsService {
    public static let defaultSources: [NewsSource] = [
        NewsSource(name: "CoinDesk", feed: URL(string: "https://www.coindesk.com/arc/outboundfeeds/rss/")!),
        NewsSource(name: "Cointelegraph", feed: URL(string: "https://cointelegraph.com/rss")!),
        NewsSource(name: "Decrypt", feed: URL(string: "https://decrypt.co/feed")!),
        NewsSource(name: "The Defiant", feed: URL(string: "https://thedefiant.io/api/feed")!),
        NewsSource(name: "The Block", feed: URL(string: "https://www.theblock.co/rss.xml")!),
    ]

    public let sources: [NewsSource]
    private let session: URLSession
    private let now: @Sendable () -> Date
    /// Each feed's last good answer, and when it came.
    private var feeds: [NewsSource: (at: Date, articles: [NewsArticle])] = [:]
    /// How long a feed's answer is served from memory.
    public static let freshFor: TimeInterval = 120

    public init(sources: [NewsSource] = NewsService.defaultSources, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sources = sources
        self.session = session
        self.now = now
    }

    /// The latest headlines across every source, newest first. Feeds are fetched concurrently; one failing feed
    /// never hides the others. Each feed's answer is kept for two minutes and only the others are asked again: a feed
    /// that failed (or a cancellation cut short) is never kept, so it is asked on the next call instead of its gap being
    /// served as fresh (security audit 2026-09-26, RS-10), and a feed that keeps failing — one behind bot protection
    /// answering 403 — costs its own request, not a refetch of every feed.
    public func latest(limit: Int = 120, force: Bool = false) async -> [NewsArticle] {
        let asked = now()
        var answered: [NewsSource: [NewsArticle]] = [:]
        var stale: [NewsSource] = []
        for source in sources {
            if !force, let kept = feeds[source], asked.timeIntervalSince(kept.at) < Self.freshFor { answered[source] = kept.articles } else { stale.append(source) }
        }
        if !stale.isEmpty {
            let fetched = await withTaskGroup(of: (NewsSource, [NewsArticle]?).self) { group in
                for source in stale {
                    group.addTask { (source, await self.fetch(source)) }
                }
                var all: [(NewsSource, [NewsArticle]?)] = []
                for await result in group { all.append(result) }
                return all
            }
            let cutShort = Task.isCancelled
            for case let (source, articles?) in fetched {
                answered[source] = articles
                if !cutShort { feeds[source] = (asked, articles) }
            }
        }
        var seen = Set<String>()
        let merged = sources.flatMap { answered[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return Array(merged.prefix(limit))
    }

    /// One feed's articles, or nil when it couldn't be read.
    private func fetch(_ source: NewsSource) async -> [NewsArticle]? {
        var request = URLRequest(url: source.feed)
        request.timeoutInterval = 15
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return RSSParser.parse(data, source: source.name)
    }
}

/// A small RSS 2.0 / Atom reader on Foundation's `XMLParser`: title, link, date, summary and the first image.
public final class RSSParser: NSObject, XMLParserDelegate {
    public static func parse(_ data: Data, source: String, now: Date = Date()) -> [NewsArticle] {
        let parser = RSSParser(source: source)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()
        return undateIfStamped(parser.articles, now: now)
    }

    /// Some feeds stamp every item with the time the feed was generated (The Defiant does), which would float their
    /// whole list to the top as "just now". When every item carries the same timestamp within a couple of minutes of
    /// the fetch, the dates are not publication times and are dropped.
    static func undateIfStamped(_ articles: [NewsArticle], now: Date) -> [NewsArticle] {
        let dates = articles.compactMap(\.published)
        guard articles.count >= 3, dates.count == articles.count, let first = dates.first else { return articles }
        let allSame = dates.allSatisfy { abs($0.timeIntervalSince(first)) < 5 }
        guard allSame, abs(first.timeIntervalSince(now)) < 180 else { return articles }
        return articles.map { NewsArticle(id: $0.id, title: $0.title, link: $0.link, source: $0.source, published: nil, summary: $0.summary, imageURL: $0.imageURL) }
    }

    private let source: String
    private var articles: [NewsArticle] = []
    private var inItem = false
    private var current: [String: String] = [:]
    private var text = ""
    private var element = ""
    /// An explicit media tag (media:content / thumbnail / enclosure) wins over an image scraped from the summary HTML.
    private var imageCandidate: String?
    private var inlineImage: String?

    private init(source: String) { self.source = source }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        element = elementName
        if elementName == "item" || elementName == "entry" {
            inItem = true
            current = [:]
            imageCandidate = nil
            inlineImage = nil
        }
        guard inItem else { return }
        text = ""
        switch elementName {
        case "media:content", "media:thumbnail", "enclosure":
            if let url = attributes["url"], imageCandidate == nil, (attributes["type"] ?? "image").hasPrefix("image") || attributes["medium"] == "image" || elementName != "enclosure" {
                imageCandidate = url
            }
        case "link":
            // Atom: <link href="…"/>
            if let href = attributes["href"], current["link"] == nil, attributes["rel"] ?? "alternate" == "alternate" { current["link"] = href }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        text += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": current["title"] = value
        case "link": if !value.isEmpty { current["link"] = value }
        case "guid", "id": current["guid"] = value
        case "pubDate", "published", "dc:date", "updated": if current["date"] == nil || elementName == "pubDate" || elementName == "published" { current["date"] = value }
        case "description", "summary", "content:encoded":
            if current["summary"]?.isEmpty ?? true || elementName == "description" { current["summary"] = value }
            if inlineImage == nil, let src = Self.firstImage(in: value) { inlineImage = src }
        case "item", "entry":
            inItem = false
            finish()
        default: break
        }
        text = ""
    }

    private func finish() {
        // Only web links: the article opens in SFSafariViewController, which raises on any other scheme (a feed's guid
        // fallback can be a `tag:` URI or a bare number).
        guard let title = current["title"], !title.isEmpty, let linkText = current["link"] ?? current["guid"], let link = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(link.scheme?.lowercased() ?? "") else { return }
        let summary = Self.stripHTML(current["summary"] ?? "")
        let id = (current["guid"]?.isEmpty == false ? current["guid"]! : link.absoluteString)
        articles.append(NewsArticle(id: id, title: Self.decodeEntities(title), link: link, source: source, published: Self.date(current["date"]), summary: summary, imageURL: (imageCandidate ?? inlineImage).flatMap { URL(string: $0) }))
    }

    // MARK: Helpers

    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd HH:mm:ss",
    ]

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let d = formatter.date(from: text) { return d }
        }
        return nil
    }

    static func firstImage(in html: String) -> String? {
        guard let range = html.range(of: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .regularExpression) else { return nil }
        let tag = String(html[range])
        guard let srcRange = tag.range(of: "src=[\"']([^\"']+)[\"']", options: .regularExpression) else { return nil }
        let src = tag[srcRange].dropFirst(5).dropLast()
        return String(src)
    }

    static func stripHTML(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return decodeEntities(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#8217;": "’", "&#8216;": "‘", "&#8220;": "“", "&#8221;": "”", "&#8230;": "…", "&#8211;": "–", "&#8212;": "—"]
        for (entity, char) in map { out = out.replacingOccurrences(of: entity, with: char) }
        return out
    }
}
