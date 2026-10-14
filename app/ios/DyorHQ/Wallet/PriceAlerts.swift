import DyorKit
import Foundation
import Observation
import SwiftUI

/// A price alert the user set: notify when `token` crosses `target` USD, from below (above == true) or above.
struct PriceAlert: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let token: Address
    let symbol: String
    let decimals: Int
    let target: Double
    let above: Bool
    var createdAt = Date()
}

/// On-device storage for price alerts, per wallet like the activity log and the notification center: each account
/// has its own alerts, and they are mirrored to that wallet's rows only (security audit 2026-09-26, RS-7). The app-wide
/// watcher (`AlertCenter`) checks them every 30 seconds while the app is open, fires a local notification when one
/// crosses its target (`PriceAlertCheck`), and removes it: an alert fires once.
enum PriceAlertStore {
    private static func key(_ owner: Address) -> String { "priceAlerts.v1.\(owner.hex)" }
    /// The device-wide list builds before per-wallet storage kept; it moves to the first wallet that reads its alerts.
    private static let legacyKey = "priceAlerts.v1"

    static func all(owner: Address?) -> [PriceAlert] {
        guard let owner else { return [] }
        adoptLegacy(owner: owner)
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PriceAlert].self, from: data)) ?? []
    }

    /// Mirrors a wallet's list to its backend rows (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([PriceAlert], Address) -> Void)?

    static func save(_ alerts: [PriceAlert], owner: Address?) {
        guard let owner else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(alerts), forKey: key(owner))
        onChange?(alerts, owner)
    }

    static func add(_ alert: PriceAlert, owner: Address?) { var a = all(owner: owner); a.append(alert); save(a, owner: owner) }
    static func remove(_ id: UUID, owner: Address?) { save(all(owner: owner).filter { $0.id != id }, owner: owner) }

    /// Drops the alerts that fired, re-reading the list first so one added or deleted meanwhile stays as it is.
    static func removeFired(_ ids: Set<UUID>, owner: Address) {
        guard !ids.isEmpty else { return }
        let current = all(owner: owner)
        let remaining = current.filter { !ids.contains($0.id) }
        if remaining.count != current.count { save(remaining, owner: owner) }
    }

    private static func adoptLegacy(owner: Address) {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.data(forKey: legacyKey) else { return }
        if defaults.data(forKey: key(owner)) == nil { defaults.set(legacy, forKey: key(owner)) }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// Lists the user's price alerts and lets them add or delete one.
struct PriceAlertsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var alerts: [PriceAlert] = []
    @State private var showCreate = false

    var body: some View {
        List {
            if !settings.notificationsEnabled || !settings.notifyPriceAlerts {
                Section {
                    Label("Turn on Notifications and Price Alerts above to receive these.", systemImage: "bell.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                if alerts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No price alerts yet.").font(.subheadline.weight(.medium))
                        Button("Add an Alert", systemImage: "plus") { Haptics.tap(); showCreate = true }
                            .font(.subheadline).buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(alerts) { alert in
                        HStack(spacing: 12) {
                            TokenLogo(token: Token(address: alert.token, symbol: alert.symbol, name: alert.symbol, decimals: alert.decimals), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.symbol).font(.subheadline.weight(.semibold))
                                Text(alert.above ? "Above \(PriceFormat.usdPrice(alert.target))" : "Below \(PriceFormat.usdPrice(alert.target))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel(alert.above ? "Above \(PriceFormat.spoken(alert.target))" : "Below \(PriceFormat.spoken(alert.target))")
                            }
                            Spacer()
                            Image(systemName: alert.above ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(alert.above ? Color.positive : Color.negative)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { PriceAlertStore.remove(alerts[i].id, owner: session.address) }
                        alerts = PriceAlertStore.all(owner: session.address)
                    }
                }
            } header: {
                HStack {
                    Text("Your Alerts")
                    Spacer()
                    Button { Haptics.tap(); showCreate = true } label: { Label("Add", systemImage: "plus") }.textCase(nil)
                }
            } footer: {
                Paragraph("Alerts arrive while DyorHQ is open: it checks prices every 30 seconds on any screen, and again as soon as you come back to it. iOS pauses the app in the background, so an alert can't reach your lock screen while DyorHQ is closed, and a price that crosses and comes back in the meantime isn't reported. An alert fires once, then it's removed. To protect a perp position, set a stop-loss on it.")
            }
        }
        .navigationTitle(tr("Price Alerts"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreate) { CreateAlertView { alerts = PriceAlertStore.all(owner: session.address) } }
        .task(id: session.address) { alerts = PriceAlertStore.all(owner: session.address) }
    }
}

/// Pick a token, see its live price, set a target above or below it.
private struct CreateAlertView: View {
    let onSaved: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var token: Token = .mon
    @State private var targetText = ""
    @State private var above = true
    @State private var currentPrice: Double?

    private var universe: [Token] { KnownTokenStore.universe(owner: session.address).filter { $0.symbol != "WMON" } }
    /// The typed target, read like an amount field (`PriceAlertTarget.parse`): "0,03" from a comma-decimal keypad is
    /// three cents, and a dust target keeps every digit.
    private var target: Double? { PriceAlertTarget.parse(targetText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Token") {
                    Picker("Token", selection: Binding(get: { token.address }, set: { addr in if let t = universe.first(where: { $0.address == addr }) { token = t } })) {
                        ForEach(universe) { Text($0.symbol).tag($0.address) }
                    }
                    if let currentPrice {
                        LabeledContent("Current price") { Text(PriceFormat.usdPrice(currentPrice)).accessibilityLabel(PriceFormat.spoken(currentPrice)) }
                    }
                }
                Section {
                    Picker("Notify when", selection: $above) {
                        Text("Rises above").tag(true)
                        Text("Falls below").tag(false)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        // The labels keep their full width; the field takes the rest of the row (up to 220 pt), so a dust
                        // target such as 0.00000006 shows in full on a small phone, and at large text sizes the field
                        // narrows instead of cutting "Target" short.
                        Text("Target").fixedSize()
                        Spacer()
                        TextField("0.00" as String, text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                            .frame(maxWidth: 220).layoutPriority(1)
                        Text("USD").foregroundStyle(.secondary).fixedSize()
                    }
                } footer: {
                    Paragraph(above
                         ? "DyorHQ notifies you once when it finds \(token.symbol) above this price. Alerts arrive while DyorHQ is open: it checks every 30 seconds."
                         : "DyorHQ notifies you once when it finds \(token.symbol) below this price. Alerts arrive while DyorHQ is open: it checks every 30 seconds.")
                }
            }
            .navigationTitle(tr("New Alert"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { save() }.fontWeight(.semibold).disabled((target ?? 0) <= 0) }
            }
            .task(id: token.address) { await loadPrice() }
        }
    }

    private func loadPrice() async {
        currentPrice = nil
        currentPrice = (try? await env.prices.prices(for: [token]))?[token.address]?.usd
        // Default the direction to whichever side the target would need to move from the current price.
        if let price = currentPrice, let t = target { above = t >= price }
    }

    private func save() {
        guard let t = target, t > 0 else { return }
        PriceAlertStore.add(PriceAlert(token: token.address, symbol: token.symbol, decimals: token.decimals, target: t, above: above), owner: session.address)
        // Setting an alert implies you want it to fire, so turn the alert delivery on and make sure the OS
        // permission is granted — otherwise the watcher stays silent behind an off-by-default toggle.
        if !settings.notifyPriceAlerts { settings.notifyPriceAlerts = true }
        if !settings.notificationsEnabled { settings.notificationsEnabled = true }
        Task { _ = await Notifications.requestAuthorization() }
        Haptics.success()
        onSaved()
        dismiss()
    }
}
