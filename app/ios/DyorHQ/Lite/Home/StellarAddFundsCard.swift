// Stellar copy of ios/DyorHQ/Home/AddFundsCard.swift AddFundsCard (42cd8c7 sha256:ed49a21a15b5)
// Stellar copy of ios/DyorHQ/Home/AddFundsCard.swift FundingWatch (42cd8c7 sha256:ae9fcb07d246)
// Stellar Home's add-funds card (docs/DESIGN-stellar-parity.md §8.2.3, §4.5; decision 7). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The rules behind Stellar Home's add-funds card, as `FirstFunding` holds Monad's. Every Stellar transaction pays its
/// network fee in XLM, so an account short of XLM (`firstFunding.needsXlm`, from `/v1/account`) is asked for some: "Add
/// funds to start trading" while it holds nothing worth $1, "Get XLM for network fees" while it holds another asset that
/// is. When a balance rises the card says "Funds arrived", then offers the first trade, until the account has traded
/// (`/v1/activity`) or the card is closed. On testnet an address that never had Friendbot's test XLM gets "Fund with
/// Friendbot", once (decision 7); nothing offers cash.
enum StellarFunding {
    /// Another asset worth this many dollars or more is funds the account can swap for its fee.
    static let fundsFloorUsd = 1.0
    /// A rise in an asset other than XLM worth less than this, in dollars, is dust, never "Funds arrived".
    static let dustUsd = 0.01
    /// The activity of an account's setup and funding, which isn't a trade: its activation, enabling an asset, Friendbot's
    /// test XLM, a restore, a bridge approval.
    static let setupKinds: Set<String> = ["activate", "trust", "faucet", "restore", "approve"]

    /// One asset in the account, with its value when it is priced.
    struct Balance: Equatable, Sendable {
        let id: String
        let code: String
        let units: Int64
        let decimals: Int
        let valueUsd: Double?
        var isXLM: Bool { id == "XLM" }
    }

    /// One read of the account.
    struct Reading: Equatable, Sendable {
        var needsXlm: Bool
        /// How much XLM to send, in stroops.
        var suggestXlm: Int64
        /// "available", "used" or "unavailable"; nil in the public view.
        var starterSwap: String?
        /// Friendbot's grant in XLM ("10000") while the address may still claim it: testnet, and `faucet.claimed` false.
        var friendbot: String?
        var balances: [Balance]
        /// Whether the account has traded (anything past its setup in `/v1/activity`); nil when unknown (not read, or a
        /// passkey account reading in the public view).
        var traded: Bool?

        /// Another asset worth $1 or more.
        var hasOtherFunds: Bool { balances.contains { !$0.isXLM && ($0.valueUsd ?? 0) >= StellarFunding.fundsFloorUsd } }

        func balance(_ id: String) -> Balance? { balances.first { $0.id == id } }
    }

    /// What the card offers an account short of XLM.
    struct Offer: Equatable, Sendable {
        /// How much XLM to send, in stroops.
        let suggestXlm: Int64
        /// "Fund with Friendbot": the grant in XLM, while the address may claim it (testnet).
        let friendbot: String?
        /// The starter swap (mainnet: DyorHQ pays its fee): the USDC it would sell, in base units.
        let starterUSDC: Int64?
    }

    /// What arrived: the asset and the account's balance of it now.
    struct Arrival: Equatable, Sendable {
        let code: String
        let units: Int64
        let decimals: Int
    }

    /// The first trade the card offers: XLM for USDC.
    struct Trade: Equatable, Sendable {
        let sell: String
        let buy: String
    }

    enum Phase: Equatable, Sendable {
        /// Not read yet. Nothing shows.
        case checking
        /// Nothing worth $1 and too little XLM: "Add funds to start trading", watching the balance.
        case addFunds(Offer)
        /// Another asset worth $1 or more but too little XLM: "Get XLM for network fees".
        case needsXLM(Offer)
        /// A deposit just landed: "Funds arrived" until `since + FirstFunding.arrivalPause`.
        case arrived(Arrival, since: Date)
        /// "Make your first trade".
        case firstTrade(Trade)
        /// The account has traded, or the card was closed. Nothing shows or polls.
        case done

        var isVisible: Bool {
            switch self {
            case .addFunds, .needsXLM, .arrived, .firstTrade: return true
            case .checking, .done: return false
            }
        }

        /// Whether the watch keeps reading.
        var isWatching: Bool { self != .done }

        var isArrival: Bool {
            if case .arrived = self { return true }
            return false
        }

        /// Whether the next read needs the account's activity: every phase but "Add funds", which an account with nothing
        /// in it can't leave by trading.
        var readsActivity: Bool {
            if case .addFunds = self { return false }
            return true
        }
    }

    /// The account as `/v1/account` read it, valued at `prices` (dollars per whole unit, by asset id or contract).
    static func reading(_ account: AccountView, prices: [String: Double], isTestnet: Bool, traded: Bool?) -> Reading? {
        guard let funding = account.firstFunding else { return nil }
        let balances = account.balances.map { row -> Balance in
            let price = prices[row.asset] ?? prices[row.contract]
            let value = price.map { Double(row.units) / pow(10, Double(row.decimals)) * $0 }
            return Balance(id: row.kind == "native" ? "XLM" : row.asset, code: row.code, units: row.units, decimals: row.decimals, valueUsd: value)
        }
        let friendbot = isTestnet && funding.faucet?.claimed == false ? funding.faucet?.amount : nil
        return Reading(needsXlm: funding.needsXlm, suggestXlm: Int64(funding.suggestXlm) ?? 0, starterSwap: funding.starterSwap,
                       friendbot: friendbot, balances: balances, traded: traded)
    }

    /// Whether `activity` shows a trade: anything the account did past its setup and funding (a bridge in from Monad is
    /// how the card funds it, so it doesn't count).
    static func hasTraded(_ activity: [StellarActivityItem]) -> Bool {
        activity.contains { $0.type == "tx" && !setupKinds.contains($0.kind) }
    }

    static func offer(_ reading: Reading) -> Offer {
        let usdc = reading.balance("USDC")?.units ?? 0
        return Offer(suggestXlm: reading.suggestXlm, friendbot: reading.friendbot,
                     starterUSDC: reading.starterSwap == "available" && usdc > 0 ? usdc : nil)
    }

    /// The first trade: the XLM it has, for USDC.
    static let firstTrade = Trade(sell: "XLM", buy: "USDC")

    /// Short of XLM: "Get XLM for network fees" with another asset worth $1, else "Add funds".
    static func short(_ reading: Reading) -> Phase {
        reading.hasOtherFunds ? .needsXLM(offer(reading)) : .addFunds(offer(reading))
    }

    /// What rose since `previous`: XLM first, then the first other asset whose rise isn't dust.
    static func arrival(from previous: Reading, to reading: Reading) -> Arrival? {
        let ordered = reading.balances.filter(\.isXLM) + reading.balances.filter { !$0.isXLM }
        for balance in ordered {
            let before = previous.balance(balance.id)?.units ?? 0
            guard balance.units > before else { continue }
            if !balance.isXLM, let value = balance.valueUsd, value < dustUsd { continue }
            return Arrival(code: balance.code, units: balance.units, decimals: balance.decimals)
        }
        return nil
    }

    /// The card's next phase after a read (`reading` nil: it failed), `previous` the last read that answered, at `now`.
    /// - A trade ends it from any phase.
    /// - The first read decides: short of XLM, "Add funds" or "Get XLM"; funded and not traded, the first trade; funded
    ///   with its history unknown, nothing.
    /// - A rise turns "Add funds" or "Get XLM" into "Funds arrived", which after `FirstFunding.arrivalPause` is the first
    ///   trade, or "Get XLM" again while the account is still short of XLM.
    static func next(after phase: Phase, reading: Reading?, previous: Reading?, now: Date) -> Phase {
        if phase == .done { return .done }
        if reading?.traded == true { return .done }
        switch phase {
        case .checking:
            guard let reading else { return .checking }
            if reading.needsXlm { return short(reading) }
            return reading.traded == false ? .firstTrade(firstTrade) : .done
        case .addFunds, .needsXLM:
            guard let reading else { return phase }
            if let previous, let arrived = arrival(from: previous, to: reading) { return .arrived(arrived, since: now) }
            return reading.needsXlm ? short(reading) : .firstTrade(firstTrade)
        case .arrived(let arrived, let since):
            guard now.timeIntervalSince(since) >= FirstFunding.arrivalPause else { return phase }
            guard let latest = reading ?? previous else { return .arrived(arrived, since: since) }
            return latest.needsXlm ? short(latest) : .firstTrade(firstTrade)
        case .firstTrade:
            return phase
        case .done:
            return .done
        }
    }

    /// Friendbot's grant, as the server gives it in XLM ("10000"), in the app language's digits ("10,000").
    static func grant(_ amount: String) -> String {
        guard let xlm = Double(amount) else { return amount }
        return NumberStyle.number(xlm)
    }
}

/// Stellar Home's "Add funds to start trading" card, as Monad's `AddFundsCard`: the address (tap to reveal it in full), a
/// QR code, Copy, Share, Bridge from Monad and, on testnet while the address may claim it, Fund with Friendbot; it
/// watches the balance (`StellarFundingWatch`). An account short of XLM but holding another asset gets "Get XLM for
/// network fees" instead. When a deposit lands it says "Funds arrived", then offers the first trade.
struct StellarAddFundsCard: View {
    let phase: StellarFunding.Phase
    let address: StellarAccountID
    let isTestnet: Bool
    let onBridge: () -> Void
    /// Opens the larger QR code (Deposit).
    let onShowQR: () -> Void
    /// Claims Friendbot's test XLM (`LiteStore.faucet`).
    let onFriendbot: () async throws -> Void
    /// Opens Swap selling `sell` for `buy`, on the starter swap's terms when `starter` is true.
    let onSwap: (_ sell: String, _ buy: String, _ starter: Bool) -> Void
    let onClose: () -> Void
    @State private var qr: UIImage?
    @State private var revealed = false
    @State private var copied = false
    @State private var claiming = false
    @State private var failure: String?

    var body: some View {
        Group {
            switch phase {
            case .arrived(let arrival, _): arrived(arrival)
            case .firstTrade(let trade): firstTrade(trade)
            case .needsXLM(let offer): needsXLM(offer)
            case .addFunds(let offer): addFunds(offer)
            case .checking, .done: EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Add funds

    private func addFunds(_ offer: StellarFunding.Offer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("tray.and.arrow.down.fill", tint: .brand, title: "Add funds to start trading", detail: addFundsDetail(offer))
            HStack(alignment: .center, spacing: 14) {
                qrCode
                VStack(alignment: .leading, spacing: 10) {
                    addressButton
                    HStack(spacing: 8) {
                        copyButton("Copy")
                        ShareLink(item: address.checksummed) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label {
                Text("Watching for your deposit")
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right").symbolEffect(.variableColor.iterative, options: .repeating)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Divider()
            Button { Haptics.tap(); onBridge() } label: {
                HStack {
                    Label { Text("Bridge from Monad", tableName: "StellarHome", comment: "Stellar Home, the add-funds card: a row that opens the bridge, to move USDC from the user's Monad account to Stellar. Monad is never translated") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let amount = offer.friendbot {
                Divider()
                friendbotRow(amount)
            }
            if let failure { InlineError(message: failure) }
        }
    }

    /// Testnet: test XLM or USDC, and Friendbot below while the address may still claim it; mainnet: about how much XLM.
    private func addFundsDetail(_ offer: StellarFunding.Offer) -> LocalizedStringResource {
        guard isTestnet else {
            let xlm = StellarFormat.units(offer.suggestXlm)
            return LocalizedStringResource("Send about \(xlm) XLM or USDC on Stellar to your account. Funds usually arrive in seconds.", table: "StellarHome", comment: "Stellar Home, the add-funds card on Stellar's main network: how to fund a new account. %@ is an amount of XLM (2). XLM, USDC and Stellar are never translated")
        }
        if offer.friendbot != nil {
            return LocalizedStringResource("Send test XLM or USDC on the Stellar testnet to your account, or fund it once with Friendbot below.", table: "StellarHome", comment: "Stellar Home, the add-funds card on Stellar's test network, while the account can still claim Friendbot's free test XLM (one claim per address). Friendbot is Stellar's faucet, never translated; XLM, USDC and Stellar neither")
        }
        return LocalizedStringResource("Send test XLM or USDC on the Stellar testnet to your account.", table: "StellarHome", comment: "Stellar Home, the add-funds card on Stellar's test network, once the account had Friendbot's free test XLM. XLM, USDC and Stellar are never translated")
    }

    /// "Fund with Friendbot" and what it brings, once. The server then says the claim is made, and the row goes.
    private func friendbotRow(_ amount: String) -> some View {
        Button {
            Haptics.tap()
            Task { await claim() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "drop").font(.subheadline.weight(.medium)).foregroundStyle(Color.brand).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fund with Friendbot", tableName: "StellarHome", comment: "Stellar Home on the test network: claims Stellar's Friendbot faucet's free test XLM for the account, once per address. Friendbot is never translated")
                        .font(.subheadline.weight(.medium))
                    Text("Get \(StellarFunding.grant(amount)) free test XLM, once", tableName: "StellarHome", comment: "Under Fund with Friendbot on Stellar Home: what the one claim gives. %@ is an amount of XLM (10,000). XLM is never translated")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if claiming {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(claiming)
    }

    private func claim() async {
        claiming = true
        failure = nil
        defer { claiming = false }
        do {
            try await onFriendbot()
        } catch {
            // A dismissed passkey prompt is the user's choice: nothing to say. Anything else, as the screens say it.
            if (error as? LiteSession.Failure) != .cancelled { failure = LiteErrorText.describe(error) }
        }
    }

    /// The Deposit sheet's QR code, smaller. Tapping it opens the full-size one.
    private var qrCode: some View {
        Button { Haptics.tap(); onShowQR() } label: {
            Group {
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 112, height: 112)
            .padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("QR code of your address")
        .accessibilityHint("Shows it larger")
        .task(id: address) { qr = QRCode.image(for: address.checksummed) }
    }

    /// The short address. Tapping it shows the whole address, and tapping again hides it.
    private var addressButton: some View {
        Button { Haptics.selection(); withAnimation(.snappy) { revealed.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: revealed ? address.checksummed : address.short)
                    .speechSpellsOutCharacters()
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: revealed ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Your address, ") + Text(verbatim: revealed ? address.checksummed : address.short).speechSpellsOutCharacters())
        .accessibilityHint(revealed ? "Shows the short address" : "Shows the full address")
    }

    private func copyButton(_ title: LocalizedStringKey) -> some View {
        Button(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = address.checksummed
            copied = true
        }
    }

    // MARK: Get XLM

    private func needsXLM(_ offer: StellarFunding.Offer) -> some View {
        let xlm = StellarFormat.units(offer.suggestXlm)
        return VStack(alignment: .leading, spacing: 14) {
            header("drop.fill", tint: .attention,
                   title: LocalizedStringResource("Get XLM for network fees", table: "StellarHome", comment: "Stellar Home, the add-funds card's title for an account that holds other assets but too little XLM: every Stellar transaction pays a small network fee in XLM. XLM is never translated"),
                   detail: LocalizedStringResource("Every Stellar transaction pays a small network fee in XLM. Send about \(xlm) XLM to your account.", table: "StellarHome", comment: "Stellar Home, the add-funds card for an account short of XLM. %@ is an amount of XLM (1). XLM and Stellar are never translated"))
            if let usdc = offer.starterUSDC {
                VStack(alignment: .leading, spacing: 8) {
                    PrimaryButton(title: Text("Swap \(StellarFormat.units(usdc)) USDC for XLM", tableName: "StellarHome", comment: "Stellar Home, the add-funds card: opens the account's first swap, DyorHQ paying its network fee. %@ is an amount of USDC (25). USDC and XLM are never translated"),
                                  systemImage: "arrow.left.arrow.right") {
                        onSwap("USDC", "XLM", true)
                    }
                    Paragraph(LocalizedStringResource("DyorHQ pays this first swap's network fee.", table: "StellarHome", comment: "Under the starter swap's button on Stellar Home: DyorHQ pays the network fee of the account's first swap into XLM; every later one the user pays. DyorHQ is never translated"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                copyButton("Copy address")
                Button { Haptics.tap(); onShowQR() } label: { Label("QR code of your address", systemImage: "qrcode") }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let amount = offer.friendbot {
                Divider()
                friendbotRow(amount)
            }
            if let failure { InlineError(message: failure) }
        }
    }

    // MARK: Funds arrived

    private func arrived(_ arrival: StellarFunding.Arrival) -> some View {
        header("checkmark.circle.fill", tint: .positive, title: "Funds arrived",
               detail: "\(StellarFormat.units(arrival.units, decimals: arrival.decimals)) \(arrival.code) is in your account.")
            .accessibilityElement(children: .combine)
    }

    // MARK: First trade

    private func firstTrade(_ trade: StellarFunding.Trade) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                header("arrow.left.arrow.right", tint: .positive, title: "Make your first trade",
                       detail: LocalizedStringResource("Swap \(trade.sell) for \(trade.buy) at the best price across Stellar's venues.", table: "StellarHome", comment: "Stellar Home, the add-funds card once the account is funded: its first trade. The values are asset codes (XLM, then USDC), never translated; Stellar's venues are the exchanges a swap is routed through"))
                Spacer(minLength: 0)
                Button { Haptics.tap(); onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide")
            }
            PrimaryButton(title: "Swap \(trade.sell) for \(trade.buy)", systemImage: "arrow.left.arrow.right") {
                onSwap(trade.sell, trade.buy, false)
            }
        }
    }

    private func header(_ symbol: String, tint: Color, title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Paragraph(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Moves the add-funds card through `StellarFunding`'s phases for the account: the account (and, past "Add funds", its
/// activity) is read every ~4 s, only while Home is on screen, the app is active and Home is ready (HomeView's task ends
/// when any of them stops); nothing reads once the card is done. The account and the activity are viewer and session
/// reads that never prompt.
@MainActor
@Observable
final class StellarFundingWatch {
    private(set) var phase: StellarFunding.Phase = .checking
    @ObservationIgnored private var owner: String?
    /// The last read that answered: a rise since it is a deposit that arrived.
    @ObservationIgnored private var last: StellarFunding.Reading?

    /// Where the card's ✕ is remembered for the address: it never shows again there.
    static func closedKey(_ address: String) -> String { "lite.funding.\(address)" }

    func watch(store: LiteStore, markets: LitePublicReads, isTestnet: Bool, defaults: UserDefaults = .standard) async {
        if owner != store.address {
            owner = store.address
            last = nil
            phase = defaults.bool(forKey: Self.closedKey(store.address)) ? .done : .checking
        }
        while phase.isWatching, !Task.isCancelled {
            let reading = await read(store, markets: markets, isTestnet: isTestnet)
            guard !Task.isCancelled else { return }
            if reading == nil, let account = store.account, account.address == store.address, account.firstFunding == nil {
                // A server that doesn't say how the account is funded: no card, and nothing more to read.
                return update(.done)
            }
            let before = phase
            update(StellarFunding.next(after: before, reading: reading, previous: last, now: .now))
            if let reading { last = reading }
            if case .arrived(_, let since) = phase {
                if !before.isArrival { AccessibilityNotification.Announcement(tr("Funds arrived")).post() }
                // "Funds arrived" holds a moment before the first trade is offered.
                try? await Task.sleep(for: .seconds(max(0, since.addingTimeInterval(FirstFunding.arrivalPause).timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                update(StellarFunding.next(after: phase, reading: nil, previous: last, now: .now))
            }
            try? await Task.sleep(for: FirstFunding.pollInterval)
        }
    }

    /// The first trade was offered and the person closed it: never again for this address.
    func close(address: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.closedKey(address))
        phase = .done
    }

    /// Sets the phase only when it changed, so an unchanged read doesn't redraw Home every 4 s.
    private func update(_ next: StellarFunding.Phase) {
        if next != phase { phase = next }
    }

    /// The account (`/v1/account`), valued at the prices Home read (the holdings' and Top Tokens'), and its activity when
    /// the phase needs it.
    private func read(_ store: LiteStore, markets: LitePublicReads, isTestnet: Bool) async -> StellarFunding.Reading? {
        let readsActivity = phase.readsActivity
        async let account: Void = store.refreshAccount()
        if readsActivity { await store.refreshActivity() }
        await account
        guard let view = store.account, view.address == store.address else { return nil }
        var prices: [String: Double] = [:]
        for row in markets.markets { if let usd = row.priceUsd { prices[row.id] = usd; prices[row.contract] = usd } }
        for row in store.holdings?.spot ?? [] { if let usd = row.priceUsd { prices[row.id] = usd; prices[row.contract] = usd } }
        let traded: Bool? = readsActivity && store.status(.activity) == .read ? StellarFunding.hasTraded(store.activity) : nil
        return StellarFunding.reading(view, prices: prices, isTestnet: isTestnet, traded: traded)
    }
}
#endif
