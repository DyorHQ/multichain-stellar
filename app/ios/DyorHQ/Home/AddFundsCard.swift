import DyorKit
import SwiftUI

/// Home's "Add funds to start trading" card for a passkey account whose balances are empty (MERA-PLAN §4). DyorHQ
/// sponsors no network fees, so the fastest route to a first transaction is a fast deposit. The card has the address
/// (tap to reveal it in full), a QR code, Copy, Share and the Aurora bridge, and it watches the balance. When a deposit
/// lands it says "Funds arrived" and then offers the first trade. `FirstFunding` holds the rules and `FundingWatch`
/// reads the chain.
struct AddFundsCard: View {
    let phase: FirstFunding.Phase
    let address: Address
    let onBridge: () -> Void
    /// Opens the larger QR code (the Receive sheet).
    let onShowQR: () -> Void
    let onTrade: (FirstFunding.Trade) -> Void
    let onClose: () -> Void
    @State private var qr: UIImage?
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        Group {
            switch phase {
            case .arrived(let trade, _): arrived(trade)
            case .firstTrade(let trade): firstTrade(trade)
            default: addFunds
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

    private var addFunds: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("tray.and.arrow.down.fill", tint: .brand, title: "Add funds to start trading",
                   detail: "Send MON or USDC on Monad to your account. Funds usually arrive in seconds.")
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
                    Label("Bridge from another chain", systemImage: "point.3.connected.trianglepath.dotted")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The Receive sheet's QR code, smaller. Tapping it opens the full-size one.
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
                Text(revealed ? address.checksummed : address.short)
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
        .accessibilityLabel(Text("Your address, ") + Text(revealed ? address.checksummed : address.short).speechSpellsOutCharacters())
        .accessibilityHint(revealed ? "Shows the short address" : "Shows the full address")
    }

    private func copyButton(_ title: LocalizedStringKey) -> some View {
        Button(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = address.checksummed
            copied = true
        }
    }

    // MARK: Funds arrived

    private func arrived(_ trade: FirstFunding.Trade) -> some View {
        header("checkmark.circle.fill", tint: .positive, title: "Funds arrived",
               detail: "\(NumberStyle.units(trade.amount, decimals: trade.pay.decimals)) \(trade.pay.symbol) is in your account.")
            .accessibilityElement(children: .combine)
    }

    // MARK: First trade

    private func firstTrade(_ trade: FirstFunding.Trade) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                header("arrow.left.arrow.right", tint: .positive, title: "Make your first trade",
                       detail: "Swap \(trade.pay.symbol) for \(trade.receive.symbol) at the best price across Monad's venues.")
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
            if trade.needsMON {
                // No MON, or too little: the trade couldn't pay its network fee, so ask for some before offering it.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Every Monad transaction pays a small network fee in MON. Send about 0.1 MON to your account to make this trade.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    copyButton("Copy address")
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            PrimaryButton(title: "Swap \(trade.pay.symbol) for \(trade.receive.symbol)", systemImage: "arrow.left.arrow.right", isDisabled: trade.needsMON) {
                onTrade(trade)
            }
        }
    }

    private func header(_ symbol: String, tint: Color, title: LocalizedStringKey, detail: LocalizedStringResource) -> some View {
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

/// Moves the Add funds card through `FirstFunding`'s phases for a passkey account. One read decides whether the card
/// shows. After that the balance is read every ~4 s, only while Home is on screen and the app is active: HomeView's task
/// ends when either stops. Nothing runs for any other account, or once the card is done.
@Observable
@MainActor
final class FundingWatch {
    private(set) var phase: FirstFunding.Phase = .checking
    @ObservationIgnored private var owner: Address?

    func watch(env: AppEnvironment, address: Address, home: HomeModel) async {
        if owner != address { owner = address; phase = .checking }
        while phase.isWatching, !Task.isCancelled {
            let reading = await read(env: env, address: address, home: home)
            guard !Task.isCancelled else { return }
            let before = phase
            update(FirstFunding.next(after: before, reading: reading, now: .now))
            if case .arrived(_, let since) = phase {
                if !before.isArrival { AccessibilityNotification.Announcement(tr("Funds arrived")).post() }
                // "Funds arrived" holds while the deposit ages the 3 blocks Monad needs before an account can spend it.
                try? await Task.sleep(for: .seconds(max(0, since.addingTimeInterval(FirstFunding.arrivalPause).timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                update(FirstFunding.next(after: phase, reading: nil, now: .now))
            }
            try? await Task.sleep(for: FirstFunding.pollInterval)
        }
    }

    /// The first trade was offered and the person closed it.
    func close() { phase = .done }

    /// Sets the phase only when it changed, so an unchanged read doesn't redraw Home every 4 s.
    private func update(_ next: FirstFunding.Phase) {
        if next != phase { phase = next }
    }

    /// The account's balances over its known tokens (Home's own source), and its nonce once there's anything to send.
    /// Prices and the other holdings come from what Home already loaded.
    private func read(env: AppEnvironment, address: Address, home: HomeModel) async -> FirstFunding.Snapshot? {
        // Not the Unverified ones (IOST-12): an airdropped fake "USDC" with a seeded pool must never read as funds arriving.
        let unverified = KnownTokenStore.unverified(owner: address)
        let tokens = KnownTokenStore.universe(owner: address).filter { !unverified.contains($0.address) }
        // The nonce shows a transaction sent from anywhere. An empty account can't send, so it isn't read until funds arrive.
        let wantsNonce = phase != .addFunds
        async let balances = ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)
        async let nonce: UInt64? = wantsNonce ? (try? await env.rpc.transactionCount(of: address)) : nil
        guard let balances = try? await balances else { return nil }
        let prices = Dictionary(home.rows.compactMap { row in row.usd.map { (row.token.address, $0) } }, uniquingKeysWith: { first, _ in first })
        // A bridge in (sent from this address on another chain) is how the card funds the account, so it doesn't count as
        // activity here. Anything the account does on Monad shows in the nonce.
        let history = ActivityLog.all(owner: address).contains { $0.kind != .bridge }
            || !home.launchHoldings.isEmpty || !home.momentRows.isEmpty || (home.perpEquity ?? 0) > 0
        return FirstFunding.Snapshot(balances: balances, tokens: tokens, prices: prices, nonce: await nonce, hasHistory: history)
    }
}

extension FirstFunding.Phase {
    var isArrival: Bool {
        if case .arrived = self { return true }
        return false
    }
}
