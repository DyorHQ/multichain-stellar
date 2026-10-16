// Stellar copy of ios/DyorHQ/Home/HomeView.swift HomeAction (42cd8c7 sha256:3e32e86f1b75)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift TokenListRow (42cd8c7 sha256:3288ec203a87)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift HoldingRow (42cd8c7 sha256:82ba4f912a22)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift LaunchHoldingRow (42cd8c7 sha256:ec989ee1a371)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift PositionSummaryRow (42cd8c7 sha256:5aedeb469e1d)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift MomentHoldingRow (42cd8c7 sha256:e69fe20eac3c)
// Stellar Home's building blocks: its tiles, Top Tokens' rows and My Holdings' four tabs (docs/DESIGN-stellar-parity.md
// §8.2.2, §8.2.5, §8.2.6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// My Holdings' four tabs on Stellar, which the balance card's split names too: Monad's Spot, Launch and Moments, with
/// Earn in Perps' place, as the Earn tab sits in Trade's.
enum StellarHoldingCategory: String, CaseIterable, Identifiable {
    case spot, earn, launch, moments
    var id: String { rawValue }

    /// The category's name where four share Home's card, as Monad's `HoldingCategory` names its own: Earn's is a key of
    /// its own, short like the others.
    var label: String {
        switch self {
        case .spot: return HoldingCategory.spot.label
        case .earn: return liteTr(LocalizedStringResource("homeCategory.earn", defaultValue: "Earn", table: "StellarHome", comment: "[tight] Stellar Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. Lending XLM or USDC to earn interest, in the place Perps has on Monad"))
        case .launch: return HoldingCategory.launchpad.label
        case .moments: return HoldingCategory.moments.label
        }
    }

    /// The part of the account it shows, as Home reads it (`HomeReadState`): Earn is read in Perps' place.
    var part: HomeReadState.Part {
        switch self {
        case .spot: return .spot
        case .earn: return .perps
        case .launch: return .launch
        case .moments: return .moments
        }
    }
}

/// A Stellar asset's logo (`StellarTokenLogo`): chosen by its issuer (`classic`) or its uploaded art, its code giving only
/// the letters drawn when there is neither. Written through `init` because DyorKit's DyorCoinWiringTests refuses the text
/// of a symbol-keyed Monad logo call, which a direct call of this one's initializer reads as.
private func stellarLogo(code: String, classic: String?, image: String?, size: CGFloat) -> StellarTokenLogo {
    StellarTokenLogo.init(symbol: code, classic: classic, image: image, size: size)
}

/// One of the four Home actions: an SF Symbol over a label, filling its share of the row. Faded while it can't be used
/// (Home not ready yet, or an account that can't sign on this iPhone), so the card above says why.
struct StellarHomeAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    /// One height for every symbol, so the four tiles and their labels line up: Transfer's arrows stand taller.
    @ScaledMetric(relativeTo: .body) private var symbolHeight: CGFloat = 24
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold)).frame(height: symbolHeight)
                Text(title).font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}

/// A ranked market row for Top Tokens: rank, logo, code with its badge, name, the price and its 24h change ("New" for a
/// coin under a day old, which has none yet).
struct StellarTokenListRow: View {
    let rank: Int
    let row: StellarMarketRow
    /// The rank column's width (`StellarHomeView.rankWidth`).
    let rankWidth: CGFloat

    private static let spacing: CGFloat = 12
    private static let logoSize: CGFloat = 34

    /// Where the row's text starts, for the divider under it: rank, gap, logo, gap (74 pt at the default text size).
    static func textInset(rankWidth: CGFloat) -> CGFloat { rankWidth + spacing + logoSize + spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(verbatim: "\(rank)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary).frame(width: rankWidth, alignment: .center)
            stellarLogo(code: row.code, classic: row.classic, image: row.image, size: Self.logoSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: row.code).font(.subheadline.weight(.semibold))
                    if let badge = StellarTokenBadge.kind(badges: row.badges, verified: row.verified, code: row.code) { StellarTokenBadge(badge) }
                }
                Text(verbatim: row.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            USDText(price: row.priceUsd, font: .subheadline.weight(.medium))
                .layoutPriority(1) // the price keeps its width; the name truncates first
            if row.isNew {
                StellarTokenBadge(.new)
            } else {
                ChangeBadge(value: row.change24hPercent)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A Spot holding: logo, code with its badge (Blend's test USDC, an Unverified classic asset) and the amount; its value,
/// price and 24h change.
struct StellarHoldingRow: View {
    let row: StellarHoldings.SpotHolding

    var body: some View {
        HStack(spacing: 12) {
            stellarLogo(code: row.code, classic: row.classic, image: nil, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: row.code).font(.subheadline.weight(.semibold))
                    if let badge = StellarTokenBadge.kind(badges: row.badges, verified: row.verified, code: row.code) { StellarTokenBadge(badge) }
                }
                // An amount with its code, nothing to translate: shown as it is, never the key "%@ %@".
                Text(verbatim: "\(StellarFormat.units(row.balance, decimals: row.decimals, compact: true)) \(row.code)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: row.valueUsd, font: .subheadline.weight(.medium))
                // Always the per-unit price next to the 24h change, even for a small balance.
                HStack(spacing: 5) {
                    USDText(price: row.priceUsd, font: .caption2).foregroundStyle(.secondary)
                    ChangeText(value: row.change24hPercent, style: .caption2)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A launch coin the account holds: its artwork, the amount, and its value at the coin's price, then how far its curve
/// is toward graduation, or where it is past it.
struct StellarLaunchHoldingRow: View {
    let coin: StellarHoldings.LaunchHolding

    var body: some View {
        HStack(spacing: 12) {
            StellarArtwork(symbol: coin.symbol, image: coin.image, pointSize: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: coin.symbol).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(StellarFormat.units(coin.balance, compact: true)) \(coin.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: coin.valueUsd, font: .subheadline.weight(.medium))
                phase.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// On its curve: how far toward graduation; past it, the phase as Monad's launch rows name it.
    private var phase: Text {
        switch coin.phase {
        case "graduated": return Text(verbatim: LaunchPhase.graduated.title)
        case "completed": return Text(verbatim: LaunchPhase.migrating.title)
        default: return Text("\(Self.percent(coin))% to graduation")
        }
    }

    /// The whole percent toward graduation, floored, so that 99.6% doesn't read 100% before the curve is full.
    static func percent(_ coin: StellarHoldings.LaunchHolding) -> Int {
        guard coin.phase == "curve" else { return 100 }
        guard coin.progress.isFinite else { return 0 }
        return min(99, max(0, Int((coin.progress * 100).rounded(.down))))
    }
}

/// An Earn position: no logo (as Monad's perps rows have none), the asset with its supply rate, the amount supplied, and
/// what it has earned in dollars, unknown ("—") in the public view, which has none of DyorHQ's records.
struct StellarEarnPositionRow: View {
    let position: EarnPosition

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: position.code).font(.subheadline.weight(.semibold))
                    if let apy = position.supplyApyPercent {
                        Text("\(NumberStyle.percent(apy, signed: false)) APY", tableName: "StellarHome", comment: "[tight] Stellar Home, My Holdings' Earn tab: a chip with the yearly rate a position earns. %@ is a percentage (3.10%). APY: annual percentage yield")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.brand.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.brand)
                    }
                }
                Text("\(StellarFormat.units(position.supplied, compact: true)) \(position.code) supplied", tableName: "StellarHome", comment: "Stellar Home, My Holdings' Earn tab, under a position: how much is lent. The values are an amount (1,250.5), then the asset's code (XLM), never translated")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let earned = Self.earnedUsd(position) {
                    Text(PriceFormat.usdValue(earned, signed: true))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                        .foregroundStyle(earned < 0 ? Color.negative : earned > 0 ? Color.positive : Color.primary)
                } else {
                    Text(verbatim: "—").font(.subheadline.weight(.medium)).foregroundStyle(.tertiary)
                }
                Text("Earned", tableName: "StellarHome", comment: "[tight] Stellar Home, My Holdings' Earn tab: under the interest a position has earned so far, in dollars").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// What the position has earned, in dollars at the price its value is counted at (its value over the amount
    /// supplied, both in the asset's base units); nil when DyorHQ has no record of it (the public view) or nothing
    /// prices it.
    static func earnedUsd(_ position: EarnPosition) -> Double? {
        guard let earned = position.earned.flatMap(Double.init), let value = position.valueUsd,
              let supplied = Double(position.supplied), supplied > 0 else { return nil }
        return earned / supplied * value
    }
}

/// A Moment the account holds editions of: its picture, its title, how many editions, and what they trade at, which is
/// nothing: Stellar Moments are editions with no coin and no market. Under it, whether its window is still open, once
/// the Moment's board row says.
struct StellarMomentHoldingRow: View {
    let row: StellarHomeModel.MomentHolding

    var body: some View {
        HStack(spacing: 12) {
            StellarMomentArtwork(image: row.image, name: row.title ?? "#\(row.momentId)")
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                title.font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(row.editions) editions").font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("No market", tableName: "StellarHome", comment: "[tight] Stellar Home, My Holdings' Moments tab, where a value would be: a Stellar Moment's editions have no market, so no price")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                if let state = row.state {
                    (state.isCollecting
                        ? Text("Open", tableName: "StellarHome", comment: "[tight] Stellar Home, My Holdings' Moments tab: the Moment's collecting window is open, so editions can still be collected (an adjective)")
                        : Text("Closed", tableName: "StellarHome", comment: "[tight] Stellar Home, My Holdings' Moments tab: the Moment's collecting window has closed or it sold out, so no more editions can be collected (an adjective)"))
                        .font(.caption2).foregroundStyle(state.isCollecting ? Color.positive : .secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var title: Text {
        if let name = row.title { return Text(verbatim: name) }
        return Text("Moment #\(row.momentId)", tableName: "StellarHome", comment: "Stellar Home, My Holdings' Moments tab: a Moment with no title, named by its number. %lld is the number")
    }
}
#endif
