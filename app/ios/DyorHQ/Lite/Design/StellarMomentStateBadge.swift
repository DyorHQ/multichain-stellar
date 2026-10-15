// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentStateBadge (42cd8c7 sha256:e656eda0dbb7)
// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentStateLabel (42cd8c7 sha256:a4ec2c6cd7d5)
// Where a Stellar Moment is (docs/DESIGN-stellar-parity.md §8.11). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// Where a Stellar Moment is: collecting (with the time left), window closed, or sold out. Stellar Moments are editions
/// with no coin, so there is no graduation (`StellarMomentState`). Colour never stands alone — the word is always there.
/// A collecting Moment's badge keeps its own time: it is drawn again, alone, at each instant its countdown reads
/// differently (about once a minute) and at the deadline, so the card or page around it isn't.
struct StellarMomentStateBadge: View {
    let moment: StellarMoment
    /// On top of a photo the badge sits on a material so it stays legible whatever the image.
    var onMedia = false

    var body: some View {
        if let deadline = StellarFormat.date(moment.deadline), StellarMomentState(moment, now: Date()).isCollecting {
            TimelineView(CountdownSchedule(deadline: Int(deadline.timeIntervalSince1970))) { context in
                StellarMomentStateLabel(moment: moment, now: context.date, onMedia: onMedia)
            }
        } else {
            StellarMomentStateLabel(moment: moment, now: Date(), onMedia: onMedia)
        }
    }
}

/// `StellarMomentStateBadge` at one time.
private struct StellarMomentStateLabel: View {
    let moment: StellarMoment
    let now: Date
    var onMedia: Bool

    private var state: StellarMomentState { StellarMomentState(moment, now: now) }

    /// The badge's words, in the app's language.
    private var words: String {
        switch state {
        case .collecting:
            let seconds = StellarFormat.date(moment.deadline).map { Int($0.timeIntervalSince(now)) } ?? 0
            let left = MomentsFormat.countdown(seconds, short: onMedia)
            return onMedia ? left : tr("Collecting · \(left)")
        case .windowClosed:
            return tr("Window closed")
        case .soldOut:
            return liteTr(LocalizedStringResource("Sold out", table: "StellarCommon", comment: "[tight] A Stellar Moment's badge: every edition of it was collected"))
        }
    }

    private var tint: Color {
        switch state {
        case .collecting: return .brand
        case .windowClosed: return .secondary
        case .soldOut: return .positive
        }
    }

    private var symbol: String {
        switch state {
        case .collecting: return "clock"
        case .windowClosed: return "clock.badge.xmark"
        case .soldOut: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        Label(words, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if onMedia { Capsule().fill(.regularMaterial) } else { Capsule().fill(tint.opacity(0.14)) }
            }
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
#endif
