import DyorKit
import SwiftUI

/// The app's section menu, opened from the three-line button on Home. A full-screen page in the style of the
/// reference trading apps: a close control and the wordmark on top, the signed-in profile (tap to open it), then
/// one row per section of DyorHQ — Home, Spot, Perps, Launch, Moments, News, Portfolio, Get Help.
struct SideMenuView: View {
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            LinearGradient(colors: [Color.brand.opacity(0.55), Color.brand.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .ignoresSafeArea(edges: .top)
            ScrollView {
                VStack(spacing: 16) {
                    header
                    profileRow
                    VStack(spacing: 10) {
                        ForEach(MenuItem.allCases) { item in
                            MenuRow(item: item, isCurrent: isCurrent(item)) { open(item) }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        ZStack {
            Text(verbatim: SupportLinks.name)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            HStack {
                Button { Haptics.tap(); dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Close menu")
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private var profileRow: some View {
        Button {
            Haptics.tap()
            dismiss()
            router.presented = .profile
        } label: {
            HStack(spacing: 14) {
                if let account = session.account, account.method == .watchOnly {
                    ZStack {
                        Circle().fill(.regularMaterial).frame(width: 56, height: 56)
                        Image(systemName: "eye").font(.title2).foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials, size: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(secondaryLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    private var footer: some View {
        Paragraph("DyorHQ \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · Monad mainnet")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }

    private var displayName: String {
        if let name = social.profile?.display_name, !name.isEmpty { return name }
        if let handle = social.profile?.handle, !handle.isEmpty { return "@\(handle)" }
        if let label = session.account?.label, !label.isEmpty { return label }
        return session.address?.short ?? tr("Not signed in")
    }

    /// The email or handle under the name; when the name is already the address, how the wallet is signed in.
    private var secondaryLine: String {
        guard let account = session.account else { return tr("Sign in to trade") }
        if account.method == .watchOnly { return tr("Watching \(account.address.short)") }
        if let label = account.label, !label.isEmpty, label != displayName { return label }
        if let handle = social.profile?.handle, !handle.isEmpty, "@\(handle)" != displayName { return "@\(handle)" }
        if displayName == account.address.short { return tr("Signed in with \(account.method.nameInSentence)") }
        return account.address.short
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private func isCurrent(_ item: MenuItem) -> Bool {
        switch item {
        case .home: return router.tab == .home
        case .spot: return router.tab == .trade && router.tradeMode == .swap
        case .perps: return router.tab == .trade && router.tradeMode == .perps
        case .launch: return router.tab == .launch
        case .moments: return router.tab == .moments
        case .portfolio, .news, .help: return false
        }
    }

    private func open(_ item: MenuItem) {
        Haptics.selection()
        dismiss()
        // Let the cover finish dismissing before a new one is presented, or SwiftUI drops the second presentation.
        let delay: Duration = (item == .portfolio || item == .news || item == .help) ? .milliseconds(350) : .zero
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            router.open(item)
        }
    }
}

/// One menu row: a tinted symbol tile, the section name and what it holds, a chevron. The current section is marked.
private struct MenuRow: View {
    let item: MenuItem
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: item.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 36, height: 36)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if isCurrent {
                    Text("Now", comment: "What is current: the side menu's badge on the section on screen now, and in the TP/SL sheet the label of the trigger set now [tight]")
                        .font(.caption2.weight(.bold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Color.brand.opacity(0.12), in: Capsule())
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
