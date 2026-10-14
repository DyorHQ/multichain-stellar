import DyorKit
import SwiftUI

/// The in-app notification center: everything the app has told the user, newest first, grouped by day, with unread
/// marks and a tap-through to the screen each one is about. Opened from the bell on Home.
struct NotificationCenterView: View {
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var filter: AppNotification.Kind?
    @State private var confirmClear = false

    private var hub: NotificationHub { NotificationHub.shared }

    private var shown: [AppNotification] {
        guard let filter else { return hub.items }
        return hub.items.filter { $0.kind == filter }
    }

    /// The notifications by day, each day named in the app's language: Today, Yesterday, or its date.
    private var groups: [(day: String, items: [AppNotification])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [AppNotification]] = [:]
        for item in shown {
            let day = calendar.startOfDay(for: item.time)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(item)
        }
        return order.map { day in
            let label = calendar.isDateInToday(day) ? tr("Today") : calendar.isDateInYesterday(day) ? tr("Yesterday")
                : day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
            return (label, byDay[day] ?? [])
        }
    }

    private var presentKinds: [AppNotification.Kind] {
        let present = Set(hub.items.map(\.kind))
        return AppNotification.Kind.allCases.filter { present.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if hub.items.isEmpty {
                    ContentUnavailableView("No Notifications", systemImage: "bell", description: Text(settings.notificationsEnabled ? "Trades, claims, fees, fills and price alerts show up here." : "Notifications are off. Turn them on in Profile → Notifications to be alerted; events are still recorded here."))
                } else {
                    List {
                        if presentKinds.count > 1 {
                            Section {
                                chips.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                            }
                        }
                        ForEach(groups, id: \.day) { group in
                            Section(group.day) {
                                ForEach(group.items) { item in
                                    Button { open(item) } label: { NotificationRow(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tr("Notifications"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                        .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Mark all as read", systemImage: "checkmark.circle") { hub.markAllRead() }.disabled(hub.unreadCount == 0)
                        Button("Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }.disabled(hub.items.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Clear all notifications?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { hub.clear() }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(Text(verbatim: tr(LocalizedStringResource("notificationFilter.all", defaultValue: "All", comment: "Notification center filter: every kind of notification [tight]"))), selected: filter == nil) { filter = nil }
                ForEach(presentKinds, id: \.self) { kind in
                    chip(kind.title, selected: filter == kind) { filter = kind }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        chip(Text(title), selected: selected, action: action)
    }

    /// A kind's chip, named by the model (`AppNotification.Kind.title`).
    @_disfavoredOverload
    private func chip<S: StringProtocol>(_ title: S, selected: Bool, action: @escaping () -> Void) -> some View {
        chip(Text(verbatim: String(title)), selected: selected, action: action)
    }

    private func chip(_ title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            title
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: AppNotification) {
        Haptics.tap()
        hub.markRead(item.id)
        guard item.route != .none else { return }
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            router.open(item)
        }
    }
}

private struct NotificationRow: View {
    let item: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: Circle())
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.subheadline.weight(item.read ? .medium : .semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(item.time, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(item.body).font(.footnote).foregroundStyle(item.read ? .tertiary : .secondary).lineLimit(3)
            }
            if !item.read {
                Circle().fill(Color.brand).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch item.kind {
        case .swap, .transaction: return .allocationSpot
        case .perp: return .allocationPerps
        case .moments: return .allocationMoments
        case .priceAlert: return .attention
        case .system: return .secondary
        }
    }
}
