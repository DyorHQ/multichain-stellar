import BigInt
import DyorKit
import SwiftUI

// Shared pieces of the Moments screens: artwork, state badges, the discovery card, number formatting.

/// A Moment's media: the image behind its `mediaURI`, or a monogram on the brand tint when there is none or it
/// fails to load. It loads through the app's one image pipeline (`RemoteImage`, `ImagePipeline`), like every other
/// picture: decoded at the size bucket that covers the frame it is drawn in (measured here, so a 44 pt row decodes a
/// 192 px thumbnail and only a Moment's page header 1200 px), kept on the phone between launches, and shared — the same
/// bytes and the same cache entries — by the board's card, the page's header, every row and the Moment coin's logo.
/// Loading tries every source best first — the Supabase mirror derived from on-chain provenance when the creator is
/// known, then each IPFS gateway — so a gateway that is rate-limiting (ipfs.io and dweb.link answer 429 freely) never
/// leaves a Moment blank while another source has the bytes.
struct MomentArtwork: View {
    let provenance: MomentProvenance
    let symbol: String
    /// The Moment's creator, when known: unlocks the derived Supabase mirror as the first source.
    var creator: Address? = nil

    /// Moment art keeps the full caps at every size, as it always has: a photo is the creator's original (up to 4096 px
    /// and several MB for a Moment published before build 23, `MomentsMath.photoMaxPixels` since), whose bytes must be
    /// read whole to check its hash, so a row's thumbnail is decoded from the same checked bytes as the page's header
    /// rather than refused by the logo-sized caps.
    static let caps = RemoteMedia.caps(forThumbnail: ImageSizeBucket.largest)

    /// Warms the picture `info`'s card will ask for when it is drawn `side` points across — the same sources, size bucket
    /// and caps as `body` — ahead of the board's scroll (`BoardPrefetch`, `ImagePipeline.prefetch`).
    @MainActor static func prefetch(_ info: MomentInfo, side: CGFloat) {
        RemoteImageLoader.shared.prefetch(imageSources(provenance: info.provenance, creator: info.moment.creator), bucket: ImageSizeBucket.bucket(points: side), caps: caps)
    }

    var body: some View {
        GeometryReader { frame in
            let side = max(frame.size.width, frame.size.height)
            Group {
                if side > 0 {
                    RemoteImage(sources: Self.imageSources(provenance: provenance, creator: creator), pointSize: side, caps: Self.caps) { loading in
                        if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                    }
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
        }
        .accessibilityIgnoresInvertColors()
    }

    /// Where to look for a Moment's image, best first, through `ImageSourcePolicy` (`momentSources`), as a Moment coin's
    /// icon loads it: only DyorHQ's `launch-media` bucket and the fixed IPFS gateways, never a host the creator chose
    /// (another https link shows the placeholder). The Supabase mirror derived from the creator + media hash is a
    /// DyorHQ-hosted object, so it is never shown on trust (security audit 2026-09-26, PR-2):
    /// - a photo Moment's provenance hash is the keccak-256 of the very JPEG in the mirror, so the mirror goes first (it
    ///   is fast and DyorHQ-run) but its bytes count only while they still match that hash — and the cache keys the
    ///   picture by its sources with that hash, so what a hash-checked list kept never answers for one without it;
    /// - a video Moment's hash is the video's, while the mirror holds its poster frame, which nothing on-chain can check
    ///   — so the mirror is not a source at all, and the image comes from the content-addressed IPFS pointer only.
    ///   That includes a video Moment whose on-chain image IS that mirror (earlier builds wrote it when pinning failed):
    ///   it shows the placeholder, since until the bucket is write-once (supabase migration 26) the creator can swap
    ///   those bytes.
    /// Without a creator there is no mirror to derive: the pointer alone, held to the same hosts.
    static func imageSources(provenance: MomentProvenance, creator: Address?) -> [RemoteImageSource] {
        let policy = ImageSourcePolicy.app
        guard let creator else { return policy.creatorSources(provenance.mediaURI).map { RemoteImageSource(url: $0) } }
        return policy.momentSources(mediaURI: provenance.mediaURI, mediaHash: provenance.mediaHash, isVideo: !provenance.animationURI.isEmpty, creator: creator)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.allocationMoments.opacity(0.35), Color.brand.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 36 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 36. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(ChainText.leading(symbol, 2).uppercased())
                    .font(.system(size: min(36, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Where a Moment is in its life: collecting (with the time left), window closed, graduation pending, graduated,
/// expired. Colour never stands alone — the word is always there. A collecting Moment's badge keeps its own time: it is
/// drawn again, alone, at each instant its countdown reads differently (`MomentCountdown`, about once a minute) and at
/// the deadline, so the card or page around it isn't.
struct MomentStateBadge: View {
    let info: MomentInfo
    /// On top of a photo the badge sits on a material so it stays legible whatever the image.
    var onMedia = false

    var body: some View {
        if info.state == .collecting {
            TimelineView(CountdownSchedule(deadline: info.moment.deadline)) { context in
                MomentStateLabel(info: info, now: Int(context.date.timeIntervalSince1970), onMedia: onMedia)
            }
        } else {
            MomentStateLabel(info: info, now: Int(Date().timeIntervalSince1970), onMedia: onMedia)
        }
    }
}

/// The instants a collecting Moment's badge reads differently, from when it is drawn to its deadline
/// (`MomentCountdown.nextChange`); none after it.
struct CountdownSchedule: TimelineSchedule {
    let deadline: Int

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = MomentCountdown.nextChange(after: Int(current.timeIntervalSince1970), deadline: deadline).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return current
        }
    }
}

/// `MomentStateBadge` at one time.
private struct MomentStateLabel: View {
    let info: MomentInfo
    let now: Int
    var onMedia: Bool

    /// The badge's words, in the app's language.
    private var text: String {
        switch info.state {
        case .collecting:
            if now >= info.moment.deadline { return tr(LocalizedStringResource("Window closed", comment: "[tight] Moment badge: its collect window has closed")) }
            let left = MomentsFormat.countdown(info.secondsLeft(at: now), short: onMedia)
            return onMedia ? left : tr(LocalizedStringResource("Collecting · \(left)", comment: "[tight] Moment badge: still collecting, then the time left (\"2d 3h left\")"))
        case .graduationPending: return tr(LocalizedStringResource("Graduation pending", comment: "[tight] Moment badge: its graduation has not completed yet"))
        case .graduated: return tr(LocalizedStringResource("Graduated", comment: "[tight] A status: the coin graduated into its pool. A badge on Moments, a section of the Launch board and a date row: use a form that fits each"))
        case .expired: return tr(LocalizedStringResource("Expired", comment: "[tight] The Moment expired before graduating: a badge, a status and a section header"))
        }
    }

    private var tint: Color {
        switch info.state {
        case .collecting: return now >= info.moment.deadline ? .secondary : .brand
        case .graduationPending: return .attention
        case .graduated: return .positive
        case .expired: return .secondary
        }
    }

    private var symbol: String {
        switch info.state {
        case .collecting: return now >= info.moment.deadline ? "clock.badge.xmark" : "clock"
        case .graduationPending: return "hourglass"
        case .graduated: return "checkmark.seal.fill"
        case .expired: return "xmark.circle"
        }
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if onMedia { Capsule().fill(.regularMaterial) } else { Capsule().fill(tint.opacity(0.14)) }
            }
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A discovery-grid card: square media with the state badge, then name, ticker, the collect price and progress. Only its
/// badge moves with the time (`MomentStateBadge`): the card itself is drawn again only when its Moment changes.
struct MomentCard: View {
    let info: MomentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator) }
                    .clipped()
                MomentStateBadge(info: info, onMedia: true).padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(info.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        // A graduated coin's per-unit price is a tiny fraction of a cent; the fully diluted value reads better in a card.
                        (info.graduated ? Text("FDV", comment: "[tight] Fully diluted valuation: a stat on a Moment's page and on its card") : Text("Per edition", comment: "[tight] The price of one edition: a stat on a Moment's page and on its card"))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(info.graduated ? MomentsFormat.usd(info.pool?.fdvUSD ?? 0) : MomentsFormat.usdc(info.moment.price))
                            .font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Editions", comment: "[tight] How many editions of a Moment were collected: a stat on the Moment's page and on its card").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: "\(info.editions)").font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                }
                if !info.graduated, info.state != .expired {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                                Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, Double(info.progressBps) / 10_000), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text("\(String(info.progressBps / 100))% to graduation", comment: "[tight] Moment card: how far the reserve is toward graduation")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Number formatting shared by the Moments screens, in the app's one dollar style (`PriceFormat`).
enum MomentsFormat {
    /// USDC units as dollars with every decimal kept (up to 6), e.g. "$1.00", "$0.123456": for amounts that must be
    /// exact, like what a collect pays and approves.
    static func usdc(_ units: BigUInt) -> String {
        PriceFormat.usdValue(MomentsMath.usdc(units), fractionDigits: 2...6)
    }

    /// USDC units rounded to the cent, e.g. "$771.43": for the reserve, the graduation threshold and what is still needed,
    /// which a policy can set to a sixth decimal (771.428571 USDC for cohort 4). Under half a cent but not zero reads
    /// "<$0.01".
    static func usdcCents(_ units: BigUInt) -> String {
        PriceFormat.usdValue(MomentsMath.usdc(units))
    }

    /// Whole coins, compact, e.g. "3.86M".
    static func coins(_ wei: BigUInt) -> String { NumberStyle.number(MomentsMath.coins(wei), compact: true) }

    /// A coin's dollar price (`PriceFormat.usdPrice`: "$0.0₆1234" for a tiny one), "—" when there is none. VoiceOver
    /// reads `coinPriceSpoken`.
    static func coinPrice(_ usd: Double) -> String {
        guard usd > 0 else { return "—" }
        return PriceFormat.usdPrice(usd)
    }

    /// `coinPrice` with every zero written out, for VoiceOver.
    static func coinPriceSpoken(_ usd: Double) -> String {
        guard usd > 0 else { return "—" }
        return PriceFormat.spoken(usd)
    }

    /// A dollar amount, compact ("$25.90", "$1.2K").
    static func usd(_ value: Double) -> String {
        PriceFormat.usdValue(value, compact: true)
    }

    /// A valuation stated in full ("$2,000", never "$2K"): the graduation FDV is a number people quote exactly.
    static func fdv(_ value: Double) -> String {
        PriceFormat.usdValue(value, fractionDigits: value < 100 ? 2...2 : 0...0)
    }

    /// "2d 3h left", "45m left", "closed"; `short` drops the word for tight spaces ("2d 3h"). The units are the system's
    /// narrow ones in the app's language ("2j 3h" in French), whole units only: minutes under an hour (at least one),
    /// hours and minutes under a day, then days and hours.
    static func countdown(_ seconds: Int, short: Bool = false) -> String {
        guard seconds > 0 else { return tr(LocalizedStringResource("closed", comment: "[tight] A Moment's collect window: it has closed")) }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 3_600 ? [.minutes] : seconds < 86_400 ? [.hours, .minutes] : [.days, .hours]
        let time = Duration.seconds(max(60, seconds)).formatted(remaining(units))
        return short ? time : tr(LocalizedStringResource("\(time) left", comment: "[tight] The time left to collect a Moment (\"2d 3h left\")"))
    }

    /// The countdown's style: narrow units in the app's language, a zero unit still shown ("1h 0m"), never rounded up.
    static func remaining(_ units: Set<Duration.UnitsFormatStyle.Unit>) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(allowedUnits: units, width: .narrow, zeroValueUnits: .show(length: 1), fractionalPart: .hide(rounded: .down)).locale(L10n.locale)
    }

    /// A day and time ("Oct 1, 2026 at 9:41 AM"), in the app's language.
    static func date(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return date(Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }

    /// A day ("October 1, 2026"), in the app's language.
    static func day(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
    }
}

/// The unix time a Moments screen is drawn at, for what it shows that changes with the time alone: whether a Moment is
/// collecting, can be expired, how much has vested (`MomentBoardTimes`, `MomentPageTimes`). It is checked every second
/// but moves on only when what the screen shows would change (`run(showing:)`): until build 23 it moved every second,
/// drawing the whole board or page again each time. Countdowns keep their own time (`MomentStateBadge`).
@Observable
@MainActor
final class Clock {
    private(set) var now = Int(Date().timeIntervalSince1970)

    /// Every second, moves `now` to the time if `face` — everything the screen shows that depends on the time alone, at a
    /// given time — differs there from at `now`; `face` reads the screen's current values each time, so a Moment read
    /// again is checked as it is now. Until cancelled (the screen closed).
    func run<Face: Equatable>(showing face: @escaping @MainActor (Int) -> Face) async {
        while !Task.isCancelled {
            let time = Int(Date().timeIntervalSince1970)
            if time != now, face(time) != face(now) { now = time }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// Both wallets the app can sign with provide the raw-digest signature a Permit2 collect needs.
extension LocalWallet: MomentsPermitSigner {}
extension PrivyWallet: MomentsPermitSigner {}
