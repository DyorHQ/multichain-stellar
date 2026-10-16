// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadProfileView.swift LaunchpadProfileView (42cd8c7 sha256:31bcde2e5646)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadProfileView.swift PositionRow (42cd8c7 sha256:d1686a2397cf)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadProfileView.swift CreatedRow (42cd8c7 sha256:ee515fed1b7f)
// My Launchpad on Stellar (docs/DESIGN-stellar-parity.md §8.10.4, §8.10.5; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// My Launchpad on Stellar, laid out as Monad's `LaunchpadProfileView`: the account's creator and trader dashboard. The
/// coins it holds (value and on-curve P&L), the coins it launched, its fees by quote asset, and its launchpad activity;
/// then every claim waiting for it, one per row: a coin's creator fees, a v2 coin's holder rewards (in its quote and in
/// the coin itself), and the creator fees owed to it from before a fee recipient change. Claim All runs one transaction
/// per claim, in sequence, in one sheet. Coins of the retired v1 launchpad are listed apart, under Retired.
///
/// My Launchpad is DyorHQ's history (decision 6): it needs a session. A passkey account without one sees "Sign in with
/// your passkey" in place of it, never an error. Holder rewards, the fee recipient and owed fees are launchpad v2's live
/// state, read for each v2 coin listed. Nothing shows as 0 before it is read: a figure still being read is a placeholder,
/// one that couldn't be read says so with Retry, and the last good one read stays.
struct StellarLaunchpadProfileView: View {
    @Environment(\.stellarSession) private var session
    /// The Monad account: the same DyorHQ account's name and picture, and what the saved figures are kept under.
    @Environment(Session.self) private var account
    @Environment(SocialSession.self) private var social
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = StellarLaunchpadProfileModel()
    @State private var tab: Tab = .positions
    @State private var claimTarget: ClaimTarget?

    private var store: LiteStore? { session?.store }
    private var canSign: Bool { session?.canSign ?? false }

    // Same identity as the user Profile screen, so the two feel like one profile.
    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    private var displayName: String {
        social.profile?.display_name ?? account.account?.label ?? stellarAddress?.short ?? tr("My Launchpad")
    }
    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? account.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
    private var subtitle: String {
        if let handle = social.profile?.handle { return "@\(handle)" }
        if let method = account.account?.method { return method == .watchOnly ? tr("Watching this address") : tr("Signed in with \(method.title)") }
        return tr("Launchpad profile")
    }
    private var stellarAddress: StellarAccountID? { store.flatMap { StellarAccountID($0.address) } }

    private enum Tab: String, CaseIterable, Identifiable { case positions, launches, activity
        var id: String { rawValue }
        var label: String {
            switch self {
            case .positions: return tr("Holdings")
            case .launches: return tr("Launches")
            case .activity: return tr("Activity")
            }
        }
    }

    /// What a claim action pays out: one claim, or every claim listed, one transaction each.
    private enum ClaimTarget: Identifiable {
        case one(StellarLaunchClaim)
        case all([StellarLaunchClaim])
        var id: String {
            switch self {
            case .one(let claim): return claim.id
            case .all: return "all"
            }
        }
    }

    /// What reads the screen again: the store, a sign-in (a passkey account's session), and the account.
    private struct Reading: Equatable {
        let store: ObjectIdentifier?
        let access: LiteSession.Access?
        let owner: Address?
    }

    private var claims: [StellarLaunchClaim] {
        guard let mine = model.mine, let store else { return [] }
        return StellarLaunchClaim.claims(mine, states: model.states, account: store.address, code: code)
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                if model.needsSignIn {
                    // DyorHQ's own history needs a session: a passkey account without one is offered its passkey, once tapped.
                    Section { StellarSignInRow() }
                } else {
                    claimSection
                    Section {
                        Picker(tr(LocalizedStringResource("myLaunchpad.view", defaultValue: "View")), selection: $tab) { ForEach(Tab.allCases) { Text(verbatim: $0.label).tag($0) } }
                            .pickerStyle(.segmented)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    switch tab {
                    case .positions: positionsSections
                    case .launches: launchesSections
                    case .activity: activitySection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("My Launchpad"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            // What was saved for the account when it was last read in full is in the sheet's first frame, never
            // placeholders under figures the phone has. Never animated.
            .onAppear { withTransaction(\.disablesAnimations, true) { model.showSaved(owner: account.address) } }
            // A sign-in reads it again: the passkey account's history comes once it has a session.
            .task(id: Reading(store: store.map(ObjectIdentifier.init), access: session?.access, owner: account.address)) { await load() }
            .refreshable { await load() }
            .sheet(item: $claimTarget) { claimSheet(for: $0) }
        }
    }

    private func load() async {
        guard let store else { return }
        await model.load(store: store, owner: account.address)
    }

    /// An asset's code, from its registry id or contract ("XLM", "USDC").
    private func code(_ asset: String) -> String { store?.asset(asset)?.code ?? asset }

    // MARK: Header + claim

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Avatar(url: avatarURL, initials: initials, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            if let stellarAddress { StellarAddressRow(title: "Address", address: stellarAddress) }
            // What was saved for the account when last read, shown while it is read again: said to be, never taken for it.
            if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
            // A read that failed over figures already on screen: they stay, and this says so, with Retry.
            if model.mine != nil, let error = model.error {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: error)
                    Spacer(minLength: 8)
                    retryButton
                }
            }
            // Each figure a placeholder while its first read runs, "—" when it couldn't be read: never 0.
            HStack {
                stat("Portfolio", model.reading ? PriceFormat.usdValue(0) : PriceFormat.usdValue(model.mine.flatMap(Self.portfolioUSD)), reading: model.reading)
                Divider().frame(height: 34)
                stat("Launched", model.mine.map { "\($0.created.count)" } ?? (model.reading ? "0" : "—"), reading: model.reading)
                Divider().frame(height: 34)
                stat("Holdings", model.mine.map { "\($0.held.count)" } ?? (model.reading ? "0" : "—"), reading: model.reading)
            }
            .padding(.vertical, 2)
        }
    }

    /// The coins held, in dollars at today's prices: nil when none of them could be priced.
    static func portfolioUSD(_ mine: StellarMyLaunchpad) -> Double? {
        let values = mine.held.compactMap(\.valueUsd)
        if mine.held.isEmpty { return 0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Fees: the creator fees the account earned (Total), claimed (Received) and waiting in the launchpad (Claimable), each
    /// per quote asset with its dollar value at today's prices; then a row for each claim waiting, and Claim All.
    @ViewBuilder private var claimSection: some View {
        let fees = model.mine.map { mine in StellarLaunchFeeLines(fees: mine.fees, code: code) }
        let claims = self.claims
        Section {
            VStack(spacing: 10) {
                feeTile(Text("Total fees"), fees?.total, loading: model.reading)
                HStack(alignment: .top, spacing: 10) {
                    feeTile(Text("Received"), fees?.received, loading: model.reading)
                    feeTile(Text("Claimable"), fees?.claimable, loading: model.reading, tint: claims.isEmpty ? .primary : .brand)
                }
                // Side by side, the two tiles share the taller one's height.
                .fixedSize(horizontal: false, vertical: true)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            if model.mine == nil, model.error != nil {
                retryRow("Creator fees couldn't be read just now.")
            }
            if model.statesUnread {
                retryRow("Holder rewards couldn't be read just now.")
            }
            ForEach(claims) { claim in
                claimRow(claim) { claimTarget = .one(claim) }
            }
            if canSign, claims.count > 1 {
                Button { Haptics.tap(); claimTarget = .all(claims) } label: {
                    Text("Claim All").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        } header: {
            Text("Fees")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Paragraph(LocalizedStringResource("Received: creator fees you claimed. Claimable: creator fees waiting in the launchpad. Holder rewards and fees owed to you from before a fee recipient change are claims of their own. Claim All sends one transaction per claim, one after another, each with its own network fee.", table: "StellarLaunchBoard", comment: "Under the fee tiles and claims of My Launchpad on Stellar: what Received and Claimable count, which other claims show, and how Claim All runs"))
                if AppNetwork.stellar.isTestnet {
                    Paragraph(LocalizedStringResource("Dollar values use mainnet market prices. Testnet assets have no value.", table: "StellarLaunchBoard", comment: "Under My Launchpad's dollar figures on Stellar testnet: they come from real mainnet prices, while testnet assets themselves are worth nothing"))
                }
            }
        }
    }

    private func retryRow(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: message)
            Spacer(minLength: 8)
            retryButton
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await load() } }
            .font(.footnote.weight(.semibold))
    }

    /// A section's first read, under way.
    private func loadingRow(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// One fee tile: its title, the amount in each quote asset (XLM first), and their dollar value. `lines` nil: a spinner
    /// while the first read runs (`loading`), "—" when it couldn't be read; empty: none ("0 XLM").
    private func feeTile(_ title: Text, _ lines: [StellarLaunchFeeLines.Line]?, loading: Bool, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            if loading {
                ProgressView().controlSize(.small).padding(.vertical, 2)
            } else if let lines {
                if lines.isEmpty {
                    Text(verbatim: "0 XLM").font(.headline).monospacedDigit()
                } else {
                    ForEach(lines) { line in
                        Text(verbatim: line.amount).font(.headline).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                if let usd = StellarLaunchFeeLines.usd(lines), !lines.isEmpty {
                    Text(verbatim: PriceFormat.usdValue(usd)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else {
                Text(verbatim: "—").font(.headline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func claimRow(_ claim: StellarLaunchClaim, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: claim.icon).font(.subheadline.weight(.semibold)).frame(width: 30, height: 30)
                .background(Color.brand.opacity(0.14), in: Circle()).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                claim.title.font(.subheadline.weight(.medium))
                Text(verbatim: claim.amount + (claim.usd.map { " · \(PriceFormat.usdValue($0))" } ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if claim.retired { Text("Retired launchpad").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button("Claim", action: action).buttonStyle(.bordered).controlSize(.small).tint(.brand).disabled(!canSign)
        }
    }

    /// `reading`: its first read is under way, so `value` is only the shape of one (a placeholder, which VoiceOver reads as
    /// loading: `unreadFigure`).
    private func stat(_ label: LocalizedStringKey, _ value: String, reading: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .unreadFigure(reading)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Holdings

    /// The coins held, with their value and P&L; launchpad v2's first, the retired launchpad's apart. "No launch coins held"
    /// only once read; while the first read runs, a loading row; when it couldn't be read, an error with Retry.
    @ViewBuilder private var positionsSections: some View {
        let held = model.mine.map { StellarLaunchpadProfileModel.split($0.held, by: \.launch) }
        Section {
            if let held {
                if held.live.isEmpty {
                    emptyRow("No launch coins held", "Buy a coin on the curve and it appears here with its PnL.")
                } else {
                    ForEach(held.live) { position in
                        Button { open(position.token) } label: { positionRow(position) }.buttonStyle(.plain)
                    }
                }
            } else if model.error != nil {
                retryRow("Your balances couldn't be read. Check your connection and try again.")
            } else {
                loadingRow("Reading your balances…")
            }
        } header: { Text("Holdings") }
        if let held, !held.retired.isEmpty {
            retiredSection {
                ForEach(held.retired) { position in
                    Button { open(position.token) } label: { positionRow(position) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func positionRow(_ position: StellarMyLaunchpad.Held) -> some View {
        StellarPositionRow(position: position, rewards: model.states[position.token].map { StellarLaunchClaim.rewards($0, symbol: position.launch.symbol) } ?? [])
    }

    // MARK: Launches

    @ViewBuilder private var launchesSections: some View {
        let created = model.mine.map { StellarLaunchpadProfileModel.split($0.created, by: \.launch) }
        Section {
            if let created {
                if created.live.isEmpty {
                    emptyRow("No coins launched", "Launch a coin and it shows here with its market cap and performance.")
                } else {
                    ForEach(created.live) { item in
                        Button { open(item.launch.token) } label: { StellarCreatedRow(item: item, sharing: model.states[item.launch.token]?.rewards.sharing) }
                            .buttonStyle(.plain)
                    }
                }
            } else if model.error != nil {
                retryRow("The coins you launched couldn't be read just now.")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        } header: { Text("Coins You Launched") }
        if let created, !created.retired.isEmpty {
            retiredSection {
                ForEach(created.retired) { item in
                    Button { open(item.launch.token) } label: { StellarCreatedRow(item: item, sharing: false) }.buttonStyle(.plain)
                }
            }
        }
    }

    /// The retired v1 launchpad's coins: sold and claimed from their pages, never bought on the curve.
    private func retiredSection<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        Section {
            rows()
        } header: {
            Text(StellarLaunchBoardWords.retired)
        } footer: {
            Paragraph(LocalizedStringResource("On DyorHQ's retired launchpad: a coin still on its curve can be sold, not bought, and its creator fees can still be claimed.", table: "StellarLaunchBoard", comment: "Under My Launchpad's Retired section on Stellar: coins from DyorHQ's previous launchpad take sales and creator fee claims only. DyorHQ is never translated"))
        }
    }

    // MARK: Activity

    /// The account's launchpad trades, launches and claims, newest first.
    @ViewBuilder private var activitySection: some View {
        Section {
            if let mine = model.mine {
                if mine.activity.isEmpty {
                    emptyRow("No launchpad activity", "Your buys, sells and launches show here.")
                } else {
                    ForEach(mine.activity) { item in StellarActivityRow(item: item) }
                }
            } else if let error = model.error {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: error)
                    Spacer(minLength: 8)
                    retryButton
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        } header: { Text("Your Launchpad Activity") }
    }

    private func emptyRow(_ title: LocalizedStringKey, _ detail: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Paragraph(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// A coin's page, over the Launch board: My Launchpad closes first.
    private func open(_ token: String) {
        dismiss()
        router.openStellar(.launch(token: token))
    }

    // MARK: Reviews (§8.10.5)

    @ViewBuilder private func claimSheet(for target: ClaimTarget) -> some View {
        if let store, let launches = model.launches {
            switch target {
            case .one(let claim):
                StellarConfirmationSheet(title: claim.reviewTitle, confirmTitle: claim.confirmTitle,
                                         build: { try await claim.plan(store: store, launches: launches) },
                                         onDone: { Task { await load() } }) {
                    DetailRow(claim.reviewLabel, Text(verbatim: claim.amount))
                    DetailRow("To", verbatim: StellarAccountID(claim.to)?.short ?? "—")
                }
            case .all(let claims):
                StellarClaimAllSheet(claims: claims, build: { try await $0.plan(store: store, launches: launches) },
                                     onDone: { Task { await load() } })
            }
        }
    }
}

// MARK: - Claims

/// One claim My Launchpad offers (§8.10.4, DESIGN-stellar-contracts-v2 §21): a coin's creator fees (either generation),
/// a v2 coin's holder rewards, or the creator fees owed to the account in one asset from before a fee recipient change.
/// Each is one transaction.
struct StellarLaunchClaim: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A coin's creator fees; `retired`: on the v1 launchpad (claimed through `LiteStore`).
        case creator(token: String, symbol: String, retired: Bool)
        /// A v2 coin's holder rewards, in its quote and in the coin.
        case rewards(token: String, symbol: String)
        /// Owed fees are per asset, not per coin (L14).
        case owed(asset: StellarLaunchStateV2.Quote, units: Int64)
    }

    let kind: Kind
    /// What it pays, as one piece of text with nothing to translate: "12.5 XLM", "0.3 XLM + 1,200 ECAT".
    let amount: String
    /// Its dollar value at today's prices, where the server gave one.
    let usd: Double?
    /// Who it pays: a coin's creator fees go to its fee recipient, the rest to the account.
    let to: String

    var id: String {
        switch kind {
        case .creator(let token, _, _): "creator-\(token)"
        case .rewards(let token, _): "rewards-\(token)"
        case .owed(let asset, _): "owed-\(asset.contract)"
        }
    }

    var retired: Bool {
        if case .creator(_, _, true) = kind { return true }
        return false
    }

    var icon: String {
        if case .rewards = kind { return "gift" }
        return "banknote"
    }

    /// Its row's title in My Launchpad.
    var title: Text {
        switch kind {
        case .creator(_, let symbol, _): Text("Creator fees · \(symbol)")
        case .rewards(_, let symbol): Text("\(symbol) rewards")
        case .owed(let asset, _): Text(Self.owed(asset.code))
        }
    }

    /// Its row in Claim All's review.
    var allLabel: Text {
        switch kind {
        case .creator(_, let symbol, false): Text("Creator · \(symbol)")
        case .creator(_, let symbol, true): Text("Creator · \(symbol) (retired launchpad)")
        case .rewards(_, let symbol): Text("\(symbol) rewards")
        case .owed(let asset, _): Text(Self.owed(asset.code))
        }
    }

    var reviewTitle: LocalizedStringResource {
        switch kind {
        case .creator: "Claim Creator Fees"
        case .rewards: "Claim Rewards"
        case .owed: StellarLaunchWords.claimOwed
        }
    }

    var confirmTitle: LocalizedStringResource {
        if case .rewards = kind { return "Claim" }
        return "Claim Fees"
    }

    /// The review's row naming what the claim pays.
    var reviewLabel: Text {
        if case .rewards = kind { return Text("Holder rewards") }
        return Text("Claimable")
    }

    static func owed(_ code: String) -> LocalizedStringResource {
        LocalizedStringResource("Owed fees · \(code)", table: "StellarLaunchBoard", comment: "A claim on My Launchpad on Stellar: creator fees owed to the account from before a coin's fee recipient changed. The value is the asset's code (XLM)")
    }

    /// Its plan: v2's from `launches`, a retired coin's creator fees from `store` (v1).
    func plan(store: LiteStore, launches: LaunchV2Store) async throws -> PreparedAction {
        switch kind {
        case .creator(let token, _, true):
            guard let action = try await store.claimPlan(tokens: [token]).first else { throw LiteAPIError.decoding("the claim") }
            return action
        case .creator(let token, let symbol, false):
            return try await launches.claimPlan(token: token, symbol: symbol)
        case .rewards(let token, let symbol):
            return try await launches.claimRewardsPlan(token: token, symbol: symbol)
        case .owed(let asset, let units):
            return try await launches.claimOwedPlan(asset: asset, amount: units)
        }
    }

    /// Every claim waiting for `account`, in order: creator fees (launchpad v2's coins, then the retired launchpad's), holder
    /// rewards, then owed fees. A v2 coin's creator fees are claimed by its fee recipient: they are the account's only while
    /// launchpad v2's state says it is the recipient (the server's figure stands in while the state is unread). `code`
    /// names a quote asset from its id.
    static func claims(_ mine: StellarMyLaunchpad, states: [String: StellarLaunchStateV2], account: String,
                       code: (String) -> String) -> [StellarLaunchClaim] {
        var live: [StellarLaunchClaim] = []
        var retired: [StellarLaunchClaim] = []
        for item in mine.created {
            let coin = item.launch
            let fees = item.creatorFees
            let serverUnits = Int64(fees.unclaimed) ?? 0
            if StellarLaunchBoardModel.isRetired(coin) {
                guard serverUnits > 0 else { continue }
                retired.append(StellarLaunchClaim(kind: .creator(token: coin.token, symbol: coin.symbol, retired: true),
                                                  amount: StellarFormat.amount(serverUnits, code: code(fees.quote)), usd: fees.unclaimedUsd, to: account))
                continue
            }
            let state = states[coin.token]
            if let state, state.you?.isRecipient != true { continue }
            let units = state.flatMap { Int64($0.creatorFees) } ?? serverUnits
            guard units > 0 else { continue }
            live.append(StellarLaunchClaim(kind: .creator(token: coin.token, symbol: coin.symbol, retired: false),
                                           amount: StellarFormat.amount(units, code: state?.quote.code ?? code(fees.quote)),
                                           usd: units == serverUnits ? fees.unclaimedUsd : nil, to: state?.recipient ?? account))
        }
        var claims = live + retired
        let coins = mine.held.map(\.launch) + mine.created.map(\.launch)
        var seen = Set<String>()
        for coin in coins where !StellarLaunchBoardModel.isRetired(coin) && seen.insert(coin.token).inserted {
            guard let state = states[coin.token] else { continue }
            let lines = rewards(state, symbol: coin.symbol)
            guard !lines.isEmpty else { continue }
            claims.append(StellarLaunchClaim(kind: .rewards(token: coin.token, symbol: coin.symbol),
                                             amount: lines.map { "\($0.amount) \($0.code)" }.joined(separator: " + "), usd: nil, to: account))
        }
        var owedAssets = Set<String>()
        for coin in coins where !StellarLaunchBoardModel.isRetired(coin) {
            guard let state = states[coin.token], let owed = state.you.flatMap({ Int64($0.creatorOwed) }), owed > 0,
                  owedAssets.insert(state.quote.contract).inserted else { continue }
            claims.append(StellarLaunchClaim(kind: .owed(asset: state.quote, units: owed), amount: StellarFormat.amount(owed, code: state.quote.code),
                                             usd: nil, to: account))
        }
        return claims
    }

    /// A v2 coin's holder rewards waiting for the account, claimable now: in its quote, then in the coin itself after
    /// graduation; none without fee sharing.
    static func rewards(_ state: StellarLaunchStateV2, symbol: String) -> [StellarRewardLine] {
        guard state.rewards.sharing else { return [] }
        var lines: [StellarRewardLine] = []
        if let quote = state.rewards.pendingQuote.flatMap({ Int64($0) }), quote > 0 {
            lines.append(StellarRewardLine(amount: StellarFormat.units(quote, compact: true), code: state.quote.code))
        }
        if let coins = state.rewards.pendingToken.flatMap({ Int64($0) }), coins > 0 {
            lines.append(StellarRewardLine(amount: StellarFormat.units(coins, compact: true), code: symbol))
        }
        return lines
    }
}

/// An amount of holder rewards and its asset's code ("0.3", "XLM"), for "Rewards: %@ %@".
struct StellarRewardLine: Equatable {
    let amount: String
    let code: String
}

/// My Launchpad's fee tiles: the creator fees of the coins the account launched, per quote asset as the server totals
/// them (XLM first).
struct StellarLaunchFeeLines: Equatable {
    struct Line: Identifiable, Equatable {
        /// The quote asset's id.
        let id: String
        /// "12.5 XLM".
        let amount: String
        let usd: Double?
    }

    let total: [Line]
    let received: [Line]
    let claimable: [Line]

    init(fees: StellarMyLaunchpad.Fees, code: (String) -> String) {
        func line(_ id: String, _ units: Int64, _ usd: Double?) -> Line { Line(id: id, amount: StellarFormat.amount(units, code: code(id)), usd: usd) }
        var total: [Line] = []
        var received: [Line] = []
        var claimable: [Line] = []
        for quote in fees.byQuote {
            let got = Int64(quote.received) ?? 0
            let waiting = Int64(quote.claimable) ?? 0
            let (sum, overflow) = got.addingReportingOverflow(waiting)
            total.append(line(quote.quote, overflow ? .max : sum, quote.receivedUsd.flatMap { r in quote.claimableUsd.map { r + $0 } }))
            received.append(line(quote.quote, got, quote.receivedUsd))
            claimable.append(line(quote.quote, waiting, quote.claimableUsd))
        }
        self.total = total
        self.received = received
        self.claimable = claimable
    }

    /// The tile's dollar value: the sum of the lines that have one; nil when none has.
    static func usd(_ lines: [Line]) -> Double? {
        let priced = lines.compactMap(\.usd)
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }
}

// MARK: - Model

/// What My Launchpad reads and keeps: the account's launchpad history (`/v1/launchpad/me`, a session read), launchpad
/// v2's live state of each v2 coin it lists (viewer reads: holder rewards, the fee recipient, owed fees), and what was
/// saved for the account when last read in full.
@Observable
@MainActor
final class StellarLaunchpadProfileModel {
    private(set) var mine: StellarMyLaunchpad?
    /// Launchpad v2's state of each v2 coin held or launched, by token.
    private(set) var states: [String: StellarLaunchStateV2] = [:]
    /// Some coin's state couldn't be read at the last read: its rewards and owed fees may be missing (those read before
    /// stay).
    private(set) var statesUnread = false
    /// The claim plans of launchpad v2.
    private(set) var launches: LaunchV2Store?
    private(set) var loading = false
    /// The last read's failure, in the current language; nil once one goes through.
    private(set) var error: String?
    /// A passkey account with no session: the screen offers its passkey.
    private(set) var needsSignIn = false
    /// When the figures on screen were saved, while they are what was saved when last read in full; nil once read.
    private(set) var savedAt: Date?
    private var restoredFor: Address?

    /// What My Launchpad saves for an account once read in full (`SavedScreens.Screen.myLaunchpad`).
    struct Saved: Codable, Sendable {
        let mine: StellarMyLaunchpad
        let states: [String: StellarLaunchStateV2]
    }

    /// The first read is under way, with nothing to show yet.
    var reading: Bool { mine == nil && error == nil && !needsSignIn }

    /// Before the sheet's first frame: what was saved for `owner` when last read in full, said to be.
    func showSaved(owner: Address?) {
        guard let owner, restoredFor != owner else { return }
        restoredFor = owner
        guard mine == nil, let saved = StellarSaved.shared.load(Saved.self, .myLaunchpad, owner: owner) else { return }
        mine = saved.value.mine
        states = saved.value.states
        savedAt = saved.savedAt
    }

    /// Reads the account's launchpad history, then the state of each v2 coin in it. A read that fails keeps what was read
    /// before and says so; a passkey account with no session gets `needsSignIn`, and nothing asks.
    func load(store: LiteStore, owner: Address?) async {
        loading = true
        defer { loading = false }
        showSaved(owner: owner)
        let launches = self.launches.flatMap { $0.store === store ? $0 : nil } ?? LaunchV2Store(store: store)
        self.launches = launches
        let epoch = owner.map { StellarSaved.shared.epoch(for: $0) }
        let read: StellarMyLaunchpad
        do {
            read = try await store.myLaunchpad()
        } catch {
            guard !Task.isCancelled else { return }
            if store.status(.myLaunchpad) == .needsSignIn {
                needsSignIn = true
                self.error = nil
            } else {
                needsSignIn = false
                self.error = LiteErrorText.describe(error)
            }
            return
        }
        guard !Task.isCancelled else { return }
        needsSignIn = false
        let tokens = Self.v2Tokens(read)
        var fresh: [String: StellarLaunchStateV2] = [:]
        var unread = false
        await withTaskGroup(of: (String, StellarLaunchStateV2?, Bool).self) { group in
            for token in tokens {
                group.addTask { @MainActor in
                    do { return (token, try await launches.state(token), true) } catch { return (token, nil, false) }
                }
            }
            for await (token, state, ok) in group {
                if let state { fresh[token] = state }
                if !ok { unread = true }
            }
        }
        guard !Task.isCancelled else { return }
        let readAt = Date()
        mine = read
        // A coin whose state couldn't be read keeps the one read before.
        states = fresh.merging(states.filter { token, _ in tokens.contains(token) && fresh[token] == nil }) { new, _ in new }
        statesUnread = unread
        error = nil
        savedAt = nil
        if !unread, let owner, let epoch {
            StellarSaved.shared.save(Saved(mine: read, states: states), .myLaunchpad, owner: owner, savedAt: readAt, epoch: epoch)
        }
    }

    /// Launchpad v2's coins among those held and launched, once each.
    nonisolated static func v2Tokens(_ mine: StellarMyLaunchpad) -> [String] {
        var seen = Set<String>()
        return (mine.held.map(\.launch) + mine.created.map(\.launch)).filter { !StellarLaunchBoardModel.isRetired($0) && seen.insert($0.token).inserted }.map(\.token)
    }

    /// `items` split into launchpad v2's and the retired launchpad's, each in the server's order.
    nonisolated static func split<Item>(_ items: [Item], by coin: KeyPath<Item, StellarLaunch>) -> (live: [Item], retired: [Item]) {
        (items.filter { !StellarLaunchBoardModel.isRetired($0[keyPath: coin]) }, items.filter { StellarLaunchBoardModel.isRetired($0[keyPath: coin]) })
    }
}

// MARK: - Rows

private struct StellarPositionRow: View {
    let position: StellarMyLaunchpad.Held
    /// Its holder rewards waiting, in the quote and in the coin.
    let rewards: [StellarRewardLine]

    private var mcapText: String {
        position.launch.marketCapUsd.map { PriceFormat.usdValue($0, compact: true) } ?? StellarLaunchCard.marketCap(position.launch)
    }

    /// The profit or loss on the curve as a share of what was paid; nil without a cost basis (coins received by transfer).
    private var pnlPercent: Double? {
        guard let cost = position.costBasisQuote.flatMap(Double.init), cost > 0, let pnl = position.pnlQuote.flatMap(Double.init) else { return nil }
        return pnl / cost * 100
    }

    var body: some View {
        HStack(spacing: 12) {
            StellarArtwork(symbol: position.launch.symbol, image: position.launch.image, pointSize: 36)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: position.launch.symbol).font(.subheadline.weight(.semibold))
                Text("\(StellarFormat.units(position.balance, compact: true)) · MC \(mcapText)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                ForEach(rewards, id: \.code) { reward in
                    Text("Rewards: \(reward.amount) \(reward.code)")
                        .font(.caption2).foregroundStyle(Color.brand)
                }
                if StellarLaunchBoardModel.isRetired(position.launch), !position.launch.graduated {
                    Text("Retired launchpad").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: PriceFormat.usdValue(position.valueUsd)).font(.subheadline.weight(.medium)).monospacedDigit()
                // No P&L for coins received by transfer: nothing was paid on the curve for them.
                if let pnl = position.pnlUsd {
                    Text(verbatim: "\(PriceFormat.usdValue(pnl, signed: true))\(pnlPercent.map { " (\($0 >= 0 ? "+" : "")\(NumberStyle.number($0, maximumFractionDigits: 1))%)" } ?? "")")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(pnl >= 0 ? Color.positive : Color.negative)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct StellarCreatedRow: View {
    let item: StellarMyLaunchpad.Created
    /// Whether it shares fees with its holders (launchpad v2's state); nil while unread.
    let sharing: Bool?

    var body: some View {
        HStack(spacing: 12) {
            StellarArtwork(symbol: item.launch.symbol, image: item.launch.image, pointSize: 36)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.launch.symbol).font(.subheadline.weight(.semibold))
                    if let sharing {
                        Text(sharing ? "Shares fees" : "Creator fees").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                status
                    .font(.caption2).foregroundStyle(item.launch.graduated ? Color.positive : .secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: item.launch.marketCapUsd.map { PriceFormat.usdValue($0) } ?? StellarLaunchCard.marketCap(item.launch))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("Market cap").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Where the coin stands: its progress on the curve, waiting to graduate, in refunds, or graduated.
    private var status: Text {
        if item.launch.graduated { return Text(verbatim: LaunchPhase.graduated.title) }
        if item.launch.phase == "rescued" { return Text(verbatim: LaunchPhase.refund.title) }
        if item.launch.completed { return Text("Graduation pending") }
        return Text("\(StellarLaunchMath.progressPercent(item.launch))% to graduation")
    }
}

// MARK: - Claim All

/// Claim All (§8.10.5, CA): every claim My Launchpad lists, each its own transaction, built and reviewed together in one
/// sheet with a network fee row each, then signed and sent one after another, as Monad's review runs one plan. A claim
/// that fails stops the run: those before it are settled, and Claim All carries on from it, unless it already reached
/// the network (then the sheet only closes, as the review does).
private struct StellarClaimAllSheet: View {
    let claims: [StellarLaunchClaim]
    let build: (StellarLaunchClaim) async throws -> PreparedAction
    /// The caller's reload once a claim settled: on Done, or when the sheet goes.
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(\.stellarSession) private var stellar
    @Environment(\.stellarActions) private var stellarActions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var prepared: [String: PreparedAction] = [:]
    @State private var buildErrors: [String: String] = [:]
    @State private var preparing = true
    /// Each claim's run, once Claim All started it.
    @State private var runs: [String: StellarReviewRun] = [:]
    @State private var running = false
    @State private var accountCheck = AccountCheck.reading
    @State private var accountReads = 0
    @State private var cleanedUp = false

    /// The sheet's read of the account's XLM: on appear, and again on return to the app.
    private enum AccountCheck { case reading, read, failed }

    private var store: LiteStore? { stellar?.store }
    private var isPasskey: Bool { session.isPasskeyAccount }
    private var allPrepared: Bool { !preparing && claims.allSatisfy { prepared[$0.id] != nil } }
    private var isDone: Bool { !claims.isEmpty && claims.allSatisfy { runs[$0.id]?.isDone == true } }
    private var anySettled: Bool { runs.values.contains { $0.isDone } }

    /// The claim whose run failed, and why.
    private var failed: (claim: StellarLaunchClaim, run: StellarReviewRun, message: String)? {
        for claim in claims {
            if let run = runs[claim.id], case .failed(let message) = run.phase { return (claim, run, message) }
        }
        return nil
    }

    /// The claims still to send.
    private var pending: [PreparedAction] {
        claims.filter { runs[$0.id]?.isDone != true }.compactMap { prepared[$0.id] }
    }

    private var steps: Int { pending.reduce(0) { $0 + $1.plan.steps.count } }

    /// What the account's XLM can't cover of the claims still to send, once the sheet's own read of the account went through.
    private var shortage: StellarXLMShortage? {
        guard accountCheck == .read, allPrepared, let store, let position = store.account?.xlm.flatMap({ XLMReserve($0) }) else { return nil }
        let pending = self.pending
        let limits = pending.reduce(into: [String: Int64]()) { all, action in all.merge(action.limits, uniquingKeysWith: +) }
        return StellarXLMShortage.of(fees: PlanFees(steps: pending.flatMap(\.fees.steps)), limits: limits, position: position, estimates: store.fees,
                                     isXLM: { $0 == "XLM" || $0 == "native" || store.asset("XLM")?.contract == $0 })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(claims) { claim in DetailRow(claim.allLabel, Text(verbatim: claim.amount)) }
                } header: {
                    if AppNetwork.stellar.isTestnet { StellarNetworkLine() }
                } footer: {
                    if allPrepared, !isDone {
                        Paragraph(LocalizedStringResource("Each claim is its own transaction, sent one after another. Your phone checks each one against this review before it signs, and refuses anything else.", table: "StellarLaunchBoard", comment: "The Claim All review on My Launchpad on Stellar: every claim is a separate transaction, and the phone signs only what the review shows"))
                    }
                }
                if !isDone, !prepared.isEmpty {
                    Section {
                        ForEach(claims) { claim in
                            if let action = prepared[claim.id] {
                                DetailRow(claim.allLabel, Text(verbatim: StellarFormat.feeSummary(StellarFeeSummary(action.fees))))
                            }
                        }
                    } header: {
                        Text("Max network fee")
                    } footer: {
                        Paragraph("The most the network can charge. Each transaction's fee is checked again before it's signed, and refused if it's unusually high.")
                    }
                }
                if let shortage, !running, !isDone {
                    shortageSection(shortage)
                }
                if allPrepared, !running, !isDone {
                    accountCheckSection
                }
                if preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                ForEach(claims) { claim in
                    if let error = buildErrors[claim.id] {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                claim.allLabel.font(.subheadline.weight(.medium))
                                InlineError(message: error)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                ForEach(claims) { claim in
                    if let run = runs[claim.id], !run.progress.isEmpty {
                        Section { StellarTransactionProgress(steps: run.progress.steps) } header: { claim.allLabel }
                    }
                }
                if let failed {
                    Section { InlineError(message: failed.message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Claim All Fees"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Done" : "Cancel") { finish() }
                        .disabled(running)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if let failed, failed.run.progress.reachedNetwork {
                        // The failed claim already reached the network: Claim All never sends it again from here.
                        Text(TransactionRun.alreadySent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if stellar?.canSign == false {
                        Paragraph(SessionError.readOnly.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        if isPasskey, steps > 1, !running {
                            Text("\(steps) steps · each asks for your passkey", tableName: "StellarLaunchBoard", comment: "The Claim All review on Stellar, above its button, on a passkey account: how many transactions the claims sign, each with its own passkey prompt")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        PrimaryButton(title: Text("Claim All"), isBusy: running,
                                      isDisabled: !allPrepared || accountCheck != .read || shortage != nil) {
                            Task { await confirm() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .interactiveDismissDisabled(running)
        }
        .onDisappear { cleanUp() }
        .holdsMomentLinks()
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: isDone) { _, done in done }
        .task { await prepare() }
        .task { await readAccount() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !running, !isDone else { return }
            Task { await readAccount() }
        }
    }

    /// The account's XLM can't cover the claims: what it needs and can spend, with the way to add some. Claim All stays off.
    private func shortageSection(_ shortage: StellarXLMShortage) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                InlineError(message: LocalizedStringResource("Not enough XLM for these claims' network fees.", table: "StellarLaunchBoard", comment: "The Claim All review on Stellar: the account's XLM can't pay the network fees of all the claims. XLM is never translated"))
                Paragraph(LocalizedStringResource("You need about \(StellarFormat.units(shortage.need)) XLM and can spend \(StellarFormat.units(shortage.spendable)) XLM. Your account keeps \(StellarFormat.units(shortage.minBalance)) XLM to stay open.", table: "StellarLaunchBoard", comment: "The Claim All review on Stellar, when the account's XLM is short. The values are amounts of XLM: what the claims need, what the account can spend, and the minimum balance Stellar keeps in it"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Haptics.tap()
                    stellarActions.addFunds()
                } label: {
                    Text("Add XLM", tableName: "StellarLaunchBoard", comment: "Button in the Claim All review on Stellar when the account's XLM is short: opens Deposit to add XLM. XLM is never translated")
                }
                .buttonStyle(.bordered)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// The sheet's read of the account, while it is under way or when it failed: Claim All waits for it either way.
    @ViewBuilder private var accountCheckSection: some View {
        switch accountCheck {
        case .reading:
            Section {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your balances…").foregroundStyle(.secondary) }
            }
        case .failed:
            Section {
                InlineError(message: "Couldn’t check your wallet’s balance. Check your connection and try again.")
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await readAccount() } }
            }
        case .read:
            EmptyView()
        }
    }

    /// Builds each claim's plan, one after another: each is verified and priced on the phone, as the review's is.
    private func prepare() async {
        for claim in claims {
            do {
                prepared[claim.id] = try await build(claim)
            } catch {
                buildErrors[claim.id] = LiteErrorText.describe(error)
            }
        }
        preparing = false
    }

    /// Reads the account again for the preflight (`StellarConfirmationSheet`'s rule): Claim All waits for a read that went
    /// through.
    private func readAccount() async {
        accountReads += 1
        let read = accountReads
        accountCheck = .reading
        guard let store else {
            accountCheck = .failed
            return
        }
        let started = Date()
        await store.refreshAccount()
        guard read == accountReads else { return }
        accountCheck = store.updatedAt.map { $0 >= started } == true ? .read : .failed
    }

    /// Sends the claims in order, each through the store's own task with its own prompt (App Lock when it applies, or the
    /// passkey per step): a claim already settled is skipped, and a failure stops the run there.
    private func confirm() async {
        guard let store, !running, allPrepared else { return }
        running = true
        defer { running = false }
        let reason = tr("Confirm \(tr("Claim All"))")
        for claim in claims {
            guard let action = prepared[claim.id] else { return }
            let run = runs[claim.id] ?? StellarReviewRun()
            runs[claim.id] = run
            if run.isDone { continue }
            guard await run.start(action, store: store, reason: reason, passkey: isPasskey) != nil else { return }
        }
    }

    private func finish() {
        dismiss()
        cleanUp()
    }

    /// The caller's reload, once, when any claim settled.
    private func cleanUp() {
        guard anySettled, !cleanedUp else { return }
        cleanedUp = true
        onDone()
    }
}
#endif
