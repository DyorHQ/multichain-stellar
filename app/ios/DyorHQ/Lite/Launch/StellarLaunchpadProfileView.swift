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
/// the coin itself), and the creator fees owed to it from before a fee recipient change. A claim whose figures come from
/// an earlier read says "As last read"; Claim All runs the claims of the latest read, one transaction per claim, in
/// sequence, in one sheet. Every review shows what the claim's own plan pays, and to whom. Coins of the retired v1
/// launchpad are listed apart, under Retired.
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
        guard let mine = model.mine else { return [] }
        return StellarLaunchClaim.claims(mine, states: model.states, fresh: model.fresh, mineCurrent: model.mineCurrent, code: code)
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

    /// Fees: the creator fees the account earned (Total), claimed (Received) and can claim now (Claimable: what its claim
    /// rows pay, owed fees included), each per quote asset with its dollar value at today's prices; then a row for each
    /// claim waiting, and Claim All.
    @ViewBuilder private var claimSection: some View {
        let claims = self.claims
        let fees = model.mine.map { mine in StellarLaunchFeeLines(fees: mine.fees, claims: claims, code: code) }
        // Claim All sends only what the latest read found: a claim as last read is claimed on its own row.
        let current = StellarLaunchClaim.claimAll(claims)
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
            if canSign, current.count > 1 {
                Button { Haptics.tap(); claimTarget = .all(current) } label: {
                    Text("Claim All").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        } header: {
            Text("Fees")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Paragraph(LocalizedStringResource("Received: creator fees you claimed. Claimable: creator fees you can claim now, those owed to you from before a fee recipient change included. Holder rewards are claims of their own. Claim All sends one transaction per claim, one after another, each with its own network fee.", table: "StellarLaunchBoard", comment: "Under the fee tiles and claims of My Launchpad on Stellar: what Received and Claimable count (Claimable includes the fees owed from before a fee recipient change), that holder rewards are claimed apart, and how Claim All runs"))
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
                // Monad's caption: the retired launchpad's, and a figure kept from an earlier read.
                let caption = [claim.retired ? tr("Retired launchpad") : nil, claim.current ? nil : tr("As last read")].compactMap { $0 }
                if !caption.isEmpty { Text(verbatim: caption.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
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
                StellarClaimReview(claim: claim, account: store.address, build: { try await claim.plan(store: store, launches: launches) },
                                   onDone: { Task { await load() } })
            case .all(let claims):
                StellarClaimAllSheet(claims: claims, account: store.address, build: { try await $0.plan(store: store, launches: launches) },
                                     estimate: { kind in store.fees?.estimate(kind) ?? StellarFeeDefaults.estimate(kind) },
                                     onDone: { Task { await load() } })
            }
        }
    }
}

/// My Launchpad's words (table StellarLaunchBoard).
enum StellarLaunchBoardWords {
    static let retired = LocalizedStringResource("Retired", table: "StellarLaunchBoard", comment: "[tight] A section of My Launchpad on Stellar: the coins held or launched on DyorHQ's previous, retired launchpad")
}

// MARK: - Claims

/// One claim My Launchpad offers (§8.10.4, DESIGN-stellar-contracts-v2 §21): a coin's creator fees (either generation),
/// a v2 coin's holder rewards, or the creator fees owed to the account in one asset from before a fee recipient change.
/// Each is one transaction. Its row's figures are the screen's reads; its review's are its plan's (`amount(in:)`,
/// `payee(in:account:)`), which the server reads from the contracts as it builds it.
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
    /// Every figure it shows was read in the latest load; false for one kept from an earlier read (or from what was
    /// saved), which says "As last read" and stays out of Claim All.
    let current: Bool
    /// The creator fees it pays, in their quote asset: a coin's, or those owed to the account; nil for holder rewards. My
    /// Launchpad's Claimable tile adds these up.
    var fee: Fee? = nil

    struct Fee: Equatable {
        /// The quote asset's id, as the API names it ("XLM", "USDC", or a contract it doesn't list).
        let quote: String
        /// In the quote asset's base units.
        let units: Int64
    }

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

    /// What it claims, in a few words with nothing to translate: the coin's ticker, or the owed asset's code.
    var subject: String {
        switch kind {
        case .creator(_, let symbol, _), .rewards(_, let symbol): symbol
        case .owed(let asset, _): asset.code
        }
    }

    /// What its plan pays, from the claim step's intent (`display`), written as its row writes it: a coin's creator fees and
    /// owed fees in their asset, holder rewards in both. Nil when the plan doesn't say (an older server).
    func amount(in display: [String: StellarJSON]?) -> String? {
        guard let display else { return nil }
        func text(_ key: String) -> String? {
            if case .string(let value)? = display[key], !value.isEmpty { return value }
            return nil
        }
        func units(_ key: String) -> Int64? { text(key).flatMap { Int64($0) } }
        switch kind {
        case .creator:
            guard let units = units("amount"), let code = text("quote") else { return nil }
            return StellarFormat.amount(units, code: code)
        case .owed:
            guard let units = units("amount"), let code = text("asset") else { return nil }
            return StellarFormat.amount(units, code: code)
        case .rewards(_, let symbol):
            var parts: [String] = []
            if let quote = units("pendingQuote"), quote > 0, let code = text("quote") { parts.append("\(StellarFormat.units(quote, compact: true)) \(code)") }
            if let coins = units("pendingToken"), coins > 0 { parts.append("\(StellarFormat.units(coins, compact: true)) \(text("symbol") ?? symbol)") }
            return parts.isEmpty ? nil : parts.joined(separator: " + ")
        }
    }

    /// Who its plan pays: a coin's creator fees go to the fee recipient the plan names, owed fees to the account it names;
    /// holder rewards go to the account that claims them (`claim(user)` pays the caller). Nil when the plan doesn't say.
    func payee(in display: [String: StellarJSON]?, account: String) -> String? {
        if case .rewards = kind { return account }
        if case .string(let to)? = display?["to"], !to.isEmpty { return to }
        return nil
    }

    /// Why the plan can't be My Launchpad's claim: a coin's creator fees that now go to another fee recipient (the
    /// account would pay the network fee for someone else's payout). Nil when it may go.
    func refusal(in display: [String: StellarJSON]?, account: String) -> LocalizedStringResource? {
        guard case .creator = kind, let payee = payee(in: display, account: account), payee != account else { return nil }
        return LocalizedStringResource("These creator fees now go to the coin's fee recipient, not to you.", table: "StellarLaunchBoard", comment: "The creator fee claim review on Stellar, when the coin's fee recipient is no longer this account: the claim would pay someone else, so it is refused")
    }

    /// The claims Claim All sends: those whose figures were all read in the latest load.
    static func claimAll(_ claims: [StellarLaunchClaim]) -> [StellarLaunchClaim] { claims.filter(\.current) }

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

    /// Every claim waiting for the account, in order: creator fees (launchpad v2's coins, then the retired launchpad's),
    /// holder rewards, then owed fees. A v2 coin's creator fees are claimed by its fee recipient: they are the account's
    /// only while launchpad v2's state says it is the recipient (the server's figure stands in while the state is unread,
    /// and the review refuses a plan that pays someone else). `fresh`: the coins whose state the latest load read;
    /// `mineCurrent`: `mine` is that load's. A claim made from anything older isn't `current`. `code` names a quote asset
    /// from its id.
    static func claims(_ mine: StellarMyLaunchpad, states: [String: StellarLaunchStateV2], fresh: Set<String>, mineCurrent: Bool,
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
                                                  amount: StellarFormat.amount(serverUnits, code: code(fees.quote)), usd: fees.unclaimedUsd, current: mineCurrent,
                                                  fee: Fee(quote: fees.quote, units: serverUnits)))
                continue
            }
            let state = states[coin.token]
            if let state, state.you?.isRecipient != true { continue }
            let units = state.flatMap { Int64($0.creatorFees) } ?? serverUnits
            guard units > 0 else { continue }
            live.append(StellarLaunchClaim(kind: .creator(token: coin.token, symbol: coin.symbol, retired: false),
                                           amount: StellarFormat.amount(units, code: state?.quote.code ?? code(fees.quote)),
                                           usd: units == serverUnits ? fees.unclaimedUsd : nil,
                                           current: state == nil ? mineCurrent : fresh.contains(coin.token),
                                           fee: Fee(quote: state?.quote.id ?? fees.quote, units: units)))
        }
        var claims = live + retired
        let coins = mine.held.map(\.launch) + mine.created.map(\.launch)
        var seen = Set<String>()
        for coin in coins where !StellarLaunchBoardModel.isRetired(coin) && seen.insert(coin.token).inserted {
            guard let state = states[coin.token] else { continue }
            let lines = rewards(state, symbol: coin.symbol)
            guard !lines.isEmpty else { continue }
            claims.append(StellarLaunchClaim(kind: .rewards(token: coin.token, symbol: coin.symbol),
                                             amount: lines.map { "\($0.amount) \($0.code)" }.joined(separator: " + "), usd: nil,
                                             current: fresh.contains(coin.token)))
        }
        // Owed fees are the account's in an asset, whichever coin's state tells them: the latest load's state, where one
        // read them, says what they are now, zero included.
        var owed: [String: (asset: StellarLaunchStateV2.Quote, units: Int64, current: Bool)] = [:]
        var assets: [String] = []
        for coin in coins where !StellarLaunchBoardModel.isRetired(coin) {
            guard let state = states[coin.token], let you = state.you else { continue }
            let units = Int64(you.creatorOwed) ?? 0
            let current = fresh.contains(coin.token)
            if let found = owed[state.quote.contract] {
                if current, !found.current { owed[state.quote.contract] = (state.quote, units, true) }
            } else {
                owed[state.quote.contract] = (state.quote, units, current)
                assets.append(state.quote.contract)
            }
        }
        for contract in assets {
            guard let found = owed[contract], found.units > 0 else { continue }
            claims.append(StellarLaunchClaim(kind: .owed(asset: found.asset, units: found.units), amount: StellarFormat.amount(found.units, code: found.asset.code),
                                             usd: nil, current: found.current, fee: Fee(quote: found.asset.id, units: found.units)))
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

/// My Launchpad's fee tiles, per quote asset (XLM first, in the server's order): the creator fees the account claimed
/// (Received, as the server totals them), those it can claim now (Claimable, what its claim rows pay), and the two
/// together (Total).
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

    /// Received is the server's figure for each quote asset. Claimable is what `claims`, My Launchpad's claim rows, pay in
    /// it (`StellarLaunchClaim.fee`): a coin's creator fees only while the account is its fee recipient, whatever the
    /// server books for a coin whose fees now go to someone else, and the fees owed to the account from before a recipient
    /// change. A quote asset only owed fees are in comes after the server's. Dollar values: the server's for its own
    /// amount, otherwise its price for the quote asset applied to the amount.
    init(fees: StellarMyLaunchpad.Fees, claims: [StellarLaunchClaim], code: (String) -> String) {
        func line(_ id: String, _ units: Int64, _ usd: Double?) -> Line { Line(id: id, amount: StellarFormat.amount(units, code: code(id)), usd: usd) }
        var owing: [String: Int64] = [:]
        var quotes = fees.byQuote.map(\.quote)
        for case let fee? in claims.map(\.fee) {
            if !quotes.contains(fee.quote) { quotes.append(fee.quote) }
            owing[fee.quote] = Self.sum(owing[fee.quote] ?? 0, fee.units)
        }
        var total: [Line] = []
        var received: [Line] = []
        var claimable: [Line] = []
        for quote in quotes {
            let server = fees.byQuote.first { $0.quote == quote }
            let got = server.flatMap { Int64($0.received) } ?? 0
            let gotUsd: Double? = if let server { server.receivedUsd } else { 0 }
            let waiting = owing[quote] ?? 0
            let waitingUsd: Double?
            if let server, Int64(server.claimable) == waiting {
                waitingUsd = server.claimableUsd
            } else if waiting == 0 {
                waitingUsd = 0
            } else {
                waitingUsd = Self.usdPerUnit(server, claims: claims.filter { $0.fee?.quote == quote }).map { Double(waiting) * $0 }
            }
            total.append(line(quote, Self.sum(got, waiting), gotUsd.flatMap { r in waitingUsd.map { r + $0 } }))
            received.append(line(quote, got, gotUsd))
            claimable.append(line(quote, waiting, waitingUsd))
        }
        self.total = total
        self.received = received
        self.claimable = claimable
    }

    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }

    /// Dollars per base unit of a quote asset, from the server's figures for it: its claimable fees, else its received
    /// ones, else a claim's (a coin's creator fees keep the server's dollar figure while they are the server's amount).
    private static func usdPerUnit(_ server: StellarMyLaunchpad.QuoteFees?, claims: [StellarLaunchClaim]) -> Double? {
        func per(_ usd: Double?, _ units: Int64?) -> Double? {
            guard let usd, let units, units > 0 else { return nil }
            return usd / Double(units)
        }
        if let rate = per(server?.claimableUsd, server.flatMap { Int64($0.claimable) }) ?? per(server?.receivedUsd, server.flatMap { Int64($0.received) }) {
            return rate
        }
        return claims.lazy.compactMap { per($0.usd, $0.fee?.units) }.first
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
    /// The coins whose state the latest load read: a claim made from any other state is as last read.
    private(set) var fresh: Set<String> = []
    /// `mine` is the latest load's: not what was saved, nor what an earlier load read before one that failed.
    private(set) var mineCurrent = false
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
        fresh = []
        mineCurrent = false
    }

    /// Reads the account's launchpad history, then the state of each v2 coin in it, a few at a time (`readStates`). A read
    /// that fails keeps what was read before and says so; a passkey account with no session gets `needsSignIn`, and nothing
    /// asks.
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
            // What stays on screen is from an earlier read.
            fresh = []
            mineCurrent = false
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
        let reads = await Self.readStates(tokens) { try await launches.state($0) }
        guard !Task.isCancelled else { return }
        let readAt = Date()
        let unread = reads.read.count < tokens.count
        mine = read
        mineCurrent = true
        fresh = reads.read
        // A coin whose state couldn't be read keeps the one read before (as last read); a coin launchpad v2 answered
        // without one has none.
        states = reads.states.merging(states.filter { token, _ in tokens.contains(token) && !reads.read.contains(token) }) { new, _ in new }
        statesUnread = unread
        error = nil
        savedAt = nil
        if !unread, let owner, let epoch {
            StellarSaved.shared.save(Saved(mine: read, states: states), .myLaunchpad, owner: owner, savedAt: readAt, epoch: epoch)
        }
    }

    /// At most this many coins' states are read at once: each costs the server several contract reads, and testnet's RPC
    /// is rate-limited.
    nonisolated static let stateReadLimit = 4

    /// Launchpad v2's state of each of `tokens`, at most `limit` reads at a time: the states read, and the tokens whose read
    /// went through (a coin launchpad v2 doesn't know answers no state, and counts as read).
    static func readStates(_ tokens: [String], limit: Int = stateReadLimit,
                           read: @escaping @MainActor (String) async throws -> StellarLaunchStateV2?) async -> (states: [String: StellarLaunchStateV2], read: Set<String>) {
        var states: [String: StellarLaunchStateV2] = [:]
        var done = Set<String>()
        let one: @MainActor (String) async -> (String, StellarLaunchStateV2?, Bool) = { token in
            do { return (token, try await read(token), true) } catch { return (token, nil, false) }
        }
        await withTaskGroup(of: (String, StellarLaunchStateV2?, Bool).self) { group in
            var next = 0
            while next < min(max(1, limit), tokens.count) {
                let token = tokens[next]
                group.addTask { @MainActor in await one(token) }
                next += 1
            }
            // Each read that ends starts the next.
            while let result = await group.next() {
                let (token, state, ok) = result
                if let state { states[token] = state }
                if ok { done.insert(token) }
                if next < tokens.count {
                    let token = tokens[next]
                    group.addTask { @MainActor in await one(token) }
                    next += 1
                }
            }
        }
        return (states, done)
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

// MARK: - A claim's review

/// A claim's review (§8.10.5 C): `StellarConfirmationSheet` over the claim's own plan. Its rows say what that plan pays and
/// to whom, as the server read them from the contracts when it built it, never My Launchpad's figures, which may be from
/// an earlier read. A coin's creator fees that now go to someone else are refused before Confirm.
private struct StellarClaimReview: View {
    let claim: StellarLaunchClaim
    /// The account's address: who the claim must pay.
    let account: String
    let build: () async throws -> PreparedAction
    let onDone: () -> Void
    @State private var built: PreparedAction?
    @State private var failed = false

    var body: some View {
        StellarConfirmationSheet(title: claim.reviewTitle, confirmTitle: claim.confirmTitle, build: {
            do {
                let action = try await build()
                await MainActor.run { built = action }
                return action
            } catch {
                await MainActor.run { failed = true }
                throw error
            }
        }, onDone: onDone, check: { claim.refusal(in: $0.claimDisplay, account: account) }) {
            StellarClaimFigure(label: claim.reviewLabel, value: amount, reading: reading)
            StellarClaimFigure(label: Text("To"), value: payee, reading: reading)
        }
    }

    /// The plan is being built: its rows are placeholders until it says what it pays.
    private var reading: Bool { built == nil && !failed }

    private var amount: String {
        if let built { return claim.amount(in: built.claimDisplay) ?? claim.amount }
        return failed ? "—" : claim.amount
    }

    private var payee: String {
        guard let built else { return failed ? "—" : StellarLaunchClaim.short(account) }
        return claim.payee(in: built.claimDisplay, account: account).map(StellarLaunchClaim.short) ?? "—"
    }
}

/// A review row whose value is a placeholder while the plan is built.
private struct StellarClaimFigure: View {
    let label: Text
    let value: String
    let reading: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label.foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(verbatim: value).monospacedDigit().multilineTextAlignment(.trailing).unreadFigure(reading)
        }
    }
}

extension StellarLaunchClaim {
    /// An address as the review writes it: G… or C… shortened, anything else as it is.
    static func short(_ address: String) -> String {
        if let account = StellarAccountID(address) { return account.short }
        return address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }
}

// MARK: - Claim All

/// A claim's plan as Claim All reads it: `PreparedAction`, or a test's own.
protocol StellarClaimPlan {
    /// Its claim step's intent display: what it pays, and to whom.
    var claimDisplay: [String: StellarJSON]? { get }
    /// The most the user's steps may charge together, in stroops.
    var claimFee: Int64 { get }
    /// Its claim step's fee kind ("launch_v2_claim"): that kind's estimate prices the plan built again.
    var claimStepKind: String? { get }
    /// The transactions it signs.
    var claimSteps: Int { get }
    /// The base reserves it holds back.
    var claimReserves: Int { get }
}

extension PreparedAction: StellarClaimPlan {
    var claimDisplay: [String: StellarJSON]? { plan.steps.compactMap(\.intent).last?.display }
    var claimFee: Int64 { fees.userMax }
    var claimStepKind: String? { plan.steps.last?.stepKind }
    var claimSteps: Int { plan.steps.count }
    var claimReserves: Int { fees.newReserves }
}

/// Claim All (§8.10.5 CA) apart from its sheet: each claim's plan, built for the review in order, then sent one after
/// another, each its own transaction. The server builds a plan's transaction on the account's sequence number as it
/// stands, so a plan built before another claim went out could never land: once one claim is handed to a run, every other
/// plan is built again just before it is sent, and held to the network fee the review showed for it (`cap`). A claim that
/// can't be built, or whose plan pays someone else, is set aside with why, and Claim All goes on with the others (Try
/// Again builds the ones set aside). A send that fails stops the run: Claim All carries on from that claim, unless it
/// reached the network, which nothing here sends again.
@Observable
@MainActor
final class StellarClaimAllModel<Plan: StellarClaimPlan> {
    /// How one claim's send went.
    enum Outcome: Equatable {
        case settled
        case failed(String, reachedNetwork: Bool)
    }

    /// The send that stopped the run.
    struct Failure: Equatable {
        let id: String
        let message: String
        /// It reached the network: the sheet only closes.
        let reachedNetwork: Bool
    }

    /// Every claim the sheet opened with, in order.
    let claims: [StellarLaunchClaim]
    /// The plan of each claim in Claim All, by claim id: the review's, then the one sent.
    private(set) var prepared: [String: Plan] = [:]
    /// The claims set aside, and why.
    private(set) var problems: [String: String] = [:]
    private(set) var preparing = false
    private(set) var running = false
    private(set) var settled: Set<String> = []
    private(set) var failure: Failure?

    private let account: String
    private let build: (StellarLaunchClaim) async throws -> Plan
    private let estimate: (String) -> Int64?
    /// The plans built before a claim was handed to a run: each is built again before it is sent.
    @ObservationIgnored private var stale: Set<String> = []

    /// `account`: who every claim must pay. `build`: a claim's plan, built now. `estimate`: a step kind's fee estimate.
    init(claims: [StellarLaunchClaim], account: String, build: @escaping (StellarLaunchClaim) async throws -> Plan,
         estimate: @escaping (String) -> Int64?) {
        self.claims = claims
        self.account = account
        self.build = build
        self.estimate = estimate
    }

    /// The claims with a plan, not settled yet, in order.
    var pending: [StellarLaunchClaim] { claims.filter { prepared[$0.id] != nil && !settled.contains($0.id) } }
    /// Every claim with a plan went through (a claim set aside may be tried again).
    var isDone: Bool { !settled.isEmpty && pending.isEmpty }
    /// A send reached the network and failed: nothing more is sent from here.
    var stopped: Bool { failure?.reachedNetwork == true }

    /// The most `id`'s network fee may come to: its plan's own fee, or its kind's estimate (`/v1/fees`) where that is
    /// higher, as the claim may be built again before it is sent. The review shows it, and that build is held to it.
    func cap(_ id: String) -> Int64? {
        guard let plan = prepared[id] else { return nil }
        return max(plan.claimFee, plan.claimStepKind.flatMap(estimate) ?? 0)
    }

    /// Each claim's most, of the claims still to send.
    var caps: [Int64] { pending.compactMap { cap($0.id) } }
    /// The transactions the claims still to send sign.
    var steps: Int { pending.reduce(0) { $0 + (prepared[$1.id]?.claimSteps ?? 0) } }
    /// The base reserves the claims still to send hold back.
    var reserves: Int { pending.reduce(0) { $0 + (prepared[$1.id]?.claimReserves ?? 0) } }

    /// What the review shows `claim` pays: its plan's figure once built, the listed one before.
    func amount(_ claim: StellarLaunchClaim) -> String {
        prepared[claim.id].flatMap { claim.amount(in: $0.claimDisplay) } ?? claim.amount
    }

    /// Builds the plan of each claim that has none, in order: every claim when the sheet opens, the ones set aside on Try
    /// Again.
    func prepare() async {
        guard !preparing, !running, !stopped else { return }
        preparing = true
        defer { preparing = false }
        for claim in claims where prepared[claim.id] == nil && !settled.contains(claim.id) {
            problems[claim.id] = nil
            do {
                let plan = try await build(claim)
                if let refusal = refused(claim, plan) {
                    problems[claim.id] = refusal
                } else {
                    prepared[claim.id] = plan
                    stale.remove(claim.id)
                }
            } catch {
                problems[claim.id] = LiteErrorText.describe(error)
            }
        }
    }

    /// Sends the claims still to send, in order, each through `send` (its own run). What each may cost is the review's at
    /// this moment.
    func confirm(send: (StellarLaunchClaim, Plan) async -> Outcome) async {
        guard !running, !preparing, !stopped else { return }
        let queue = pending
        guard !queue.isEmpty else { return }
        let caps = Dictionary(queue.compactMap { claim in cap(claim.id).map { (claim.id, $0) } }, uniquingKeysWith: { first, _ in first })
        running = true
        defer { running = false }
        failure = nil
        for claim in queue {
            guard var plan = prepared[claim.id], let cap = caps[claim.id] else { continue }
            if stale.contains(claim.id) {
                do {
                    plan = try await build(claim)
                } catch {
                    setAside(claim, LiteErrorText.describe(error))
                    continue
                }
                if let refusal = refused(claim, plan) {
                    setAside(claim, refusal)
                    continue
                }
                guard plan.claimFee <= cap else {
                    setAside(claim, LiteErrorText.describe(PlanRunner.Failure.feeAboveConfirmed(step: claim.subject)))
                    continue
                }
                prepared[claim.id] = plan
                stale.remove(claim.id)
            }
            // Every other plan now waits on this one's transaction: each is built again before it goes.
            stale.formUnion(prepared.keys)
            switch await send(claim, plan) {
            case .settled:
                settled.insert(claim.id)
            case .failed(let message, let reachedNetwork):
                failure = Failure(id: claim.id, message: message, reachedNetwork: reachedNetwork)
                return
            }
        }
    }

    private func setAside(_ claim: StellarLaunchClaim, _ message: String) {
        prepared[claim.id] = nil
        stale.remove(claim.id)
        problems[claim.id] = message
    }

    private func refused(_ claim: StellarLaunchClaim, _ plan: Plan) -> String? {
        claim.refusal(in: plan.claimDisplay, account: account).map(liteTr)
    }
}

extension StellarXLMShortage {
    /// What the account's XLM (`position`) can't cover of Claim All's claims still to send: each one's most (`caps`) and
    /// the reserves they hold back. Nil when it covers them.
    static func of(claims caps: [Int64], reserves: Int, position: XLMReserve) -> StellarXLMShortage? {
        func sum(_ a: Int64, _ b: Int64) -> Int64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? .max : value
        }
        let fees = caps.reduce(Int64(0)) { sum($0, max(0, $1)) }
        let need = sum(fees, position.reserves(reserves))
        guard position.spendable < need else { return nil }
        return StellarXLMShortage(fee: position.spendable < fees, need: need, spendable: position.spendable, minBalance: position.minBalance)
    }
}

/// Claim All's sheet (§8.10.5 CA): the claims of the latest read, a row each with what its plan pays, one "To" (every plan
/// here pays the account; one that doesn't is set aside), each claim's network fee, the account's XLM checked against them
/// all, then each claim's progress as it is sent (`StellarClaimAllModel`). It keeps the review's rules
/// (`StellarConfirmationSheet`): Claim All waits for the sheet's own read of the account, and a claim that reached the
/// network is never sent again. Each claim is its own transaction and its own run, so the key provider asks once per
/// claim (App Lock where it applies, the passkey per step), and the sheet says so above Claim All.
@MainActor
private struct StellarClaimAllSheet: View {
    let account: String
    /// The caller's reload once a claim settled: on Done, or when the sheet goes.
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.stellarSession) private var stellar
    @Environment(\.stellarActions) private var stellarActions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: StellarClaimAllModel<PreparedAction>
    /// Each claim's latest run, for its progress.
    @State private var runs: [String: StellarReviewRun] = [:]
    @State private var accountCheck = AccountCheck.reading
    @State private var accountReads = 0
    @State private var cleanedUp = false

    init(claims: [StellarLaunchClaim], account: String, build: @escaping (StellarLaunchClaim) async throws -> PreparedAction,
         estimate: @escaping (String) -> Int64?, onDone: @escaping () -> Void) {
        self.account = account
        self.onDone = onDone
        _model = State(initialValue: StellarClaimAllModel(claims: claims, account: account, build: build, estimate: estimate))
    }

    /// The sheet's read of the account's XLM: on appear, and again on return to the app.
    private enum AccountCheck { case reading, read, failed }

    private var store: LiteStore? { stellar?.store }
    private var isPasskey: Bool { session.isPasskeyAccount }
    /// A seed account while App Lock applies: each claim's run asks for Face ID or the passcode.
    private var asksAppLock: Bool { !isPasskey && settings.appLockApplies(to: session.account) }
    /// The plans are built, and some claim waits to be sent.
    private var ready: Bool { !model.preparing && !model.pending.isEmpty }

    /// What the account's XLM can't cover of the claims still to send, once the sheet's own read of the account went through.
    private var shortage: StellarXLMShortage? {
        guard accountCheck == .read, ready, let position = store?.account?.xlm.flatMap({ XLMReserve($0) }) else { return nil }
        return StellarXLMShortage.of(claims: model.caps, reserves: model.reserves, position: position)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.claims) { claim in
                        if model.problems[claim.id] == nil { DetailRow(claim.allLabel, Text(verbatim: model.amount(claim))) }
                    }
                    if !model.prepared.isEmpty {
                        // Every plan here pays the account: one that doesn't is set aside.
                        DetailRow("To", verbatim: StellarLaunchClaim.short(account))
                    }
                } header: {
                    if AppNetwork.stellar.isTestnet { StellarNetworkLine() }
                } footer: {
                    if ready, !model.isDone {
                        Paragraph(LocalizedStringResource("Each claim is its own transaction, sent one after another. Your phone checks each one against this review before it signs, and refuses anything else.", table: "StellarLaunchBoard", comment: "The Claim All review on My Launchpad on Stellar: every claim is a separate transaction, and the phone signs only what the review shows"))
                    }
                }
                if !model.isDone, !model.pending.isEmpty {
                    Section {
                        ForEach(model.pending) { claim in
                            if let cap = model.cap(claim.id) { DetailRow(claim.allLabel, Text(verbatim: Self.fee(cap))) }
                        }
                    } header: {
                        Text("Max network fee")
                    } footer: {
                        Paragraph("The most the network can charge. Each transaction's fee is checked again before it's signed, and refused if it's unusually high.")
                    }
                }
                if let shortage, !model.running, !model.isDone {
                    shortageSection(shortage)
                }
                if ready, !model.running, !model.isDone {
                    accountCheckSection
                }
                if model.preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                ForEach(model.claims) { claim in
                    if let problem = model.problems[claim.id] {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                claim.allLabel.font(.subheadline.weight(.medium))
                                InlineError(message: problem)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                // A claim set aside isn't lost: its plan can be built again, and Claim All then sends it too.
                if !model.problems.isEmpty, !model.preparing, !model.running, !model.stopped {
                    Section {
                        Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.prepare() } }
                    }
                }
                ForEach(model.claims) { claim in
                    if let run = runs[claim.id], !run.progress.isEmpty {
                        Section { StellarTransactionProgress(steps: run.progress.steps) } header: { claim.allLabel }
                    }
                }
                if let failure = model.failure {
                    Section { InlineError(message: failure.message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Claim All Fees"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isDone ? "Done" : "Cancel") { finish() }
                        .disabled(model.running)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if model.stopped {
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
                        if !model.running {
                            promptLine
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        PrimaryButton(title: Text("Claim All"), isBusy: model.running,
                                      isDisabled: !ready || accountCheck != .read || shortage != nil) {
                            Task { await confirm() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .interactiveDismissDisabled(model.running)
        }
        .onDisappear { cleanUp() }
        .holdsMomentLinks()
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: model.isDone) { _, done in done }
        .task { await model.prepare() }
        .task { await readAccount() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !model.running, !model.isDone else { return }
            Task { await readAccount() }
        }
    }

    /// What signing asks for, said before Claim All: the passkey once per transaction, or App Lock once per claim.
    @ViewBuilder private var promptLine: some View {
        if isPasskey, model.steps > 1 {
            Text("\(model.steps) steps · each asks for your passkey", tableName: "StellarLaunchBoard", comment: "The Claim All review on Stellar, above its button, on a passkey account: how many transactions the claims sign, each with its own passkey prompt")
        } else if asksAppLock, model.pending.count > 1 {
            Text("\(model.pending.count) claims · each asks for \(BiometricGate.promptName)", tableName: "StellarLaunchBoard", comment: "The Claim All review on Stellar, above its button, when App Lock is on: each claim is its own transaction and asks for Face ID or the passcode on its own. The first value is how many claims, the second the prompt's name (Face ID, Touch ID, Passcode)")
        }
    }

    /// A claim's most, as the review's Max network fee row writes it: "Up to 0.05 XLM".
    private static func fee(_ stroops: Int64) -> String {
        let fee = StellarFormat.xlm(stroops: stroops)
        return tr("Up to \(fee)")
    }

    /// The account's XLM can't cover the claims: what they need and it can spend, with the way to add some. Claim All
    /// stays off.
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

    /// Reads the account again for the preflight (`StellarConfirmationSheet`'s rule), and the fee estimates a claim built
    /// again is priced by: Claim All waits for a read of the account that went through.
    private func readAccount() async {
        accountReads += 1
        let read = accountReads
        accountCheck = .reading
        guard let store else {
            accountCheck = .failed
            return
        }
        let started = Date()
        async let fees: Void = store.refreshFees()
        await store.refreshAccount()
        _ = await fees
        guard read == accountReads else { return }
        accountCheck = store.updatedAt.map { $0 >= started } == true ? .read : .failed
    }

    /// Sends the claims, each through the store's own task (`StellarReviewRun`), with its own prompt.
    private func confirm() async {
        guard let store else { return }
        let reason = tr("Confirm \(tr("Claim All"))")
        let passkey = isPasskey
        await model.confirm { claim, action in
            let run = StellarReviewRun()
            runs[claim.id] = run
            if await run.start(action, store: store, reason: reason, passkey: passkey) != nil { return .settled }
            if case .failed(let message) = run.phase { return .failed(message, reachedNetwork: run.progress.reachedNetwork) }
            return .failed(TransactionRun.notSent, reachedNetwork: run.progress.reachedNetwork)
        }
    }

    private func finish() {
        dismiss()
        cleanUp()
    }

    /// The caller's reload, once, when any claim settled.
    private func cleanUp() {
        guard !model.settled.isEmpty, !cleanedUp else { return }
        cleanedUp = true
        onDone()
    }
}
#endif
