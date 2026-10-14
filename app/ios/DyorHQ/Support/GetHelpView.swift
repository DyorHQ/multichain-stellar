import DyorKit
import SwiftUI
import UIKit

/// DyorHQ's brand line and the places to reach it: the site, the Help Center (the docs), the X profile and the support
/// inbox. The name, the addresses and the handle are never translated.
enum SupportLinks {
    static let name = "DyorHQ" // not localized: the app's name
    /// The brand line, in the app's language (the catalog may keep it in English: the owner decides).
    static var tagline: String {
        tr(LocalizedStringResource("Your All-in-One Crypto App", comment: "DyorHQ's tagline, under the wordmark. Ask the owner before translating it."))
    }
    static let site = URL(string: "https://dyorhq.fun")!
    /// The docs home (dyorhq.gitbook.io/docs).
    static let helpCenter = DocsLinks.home.url
    static let terms = URL(string: "https://dyorhq.fun/terms")!
    static let privacy = URL(string: "https://dyorhq.fun/privacy")!
    static let supportEmail = "team@dyorhq.fun"
    static let xHandle = "@DyorHQ_"
    static let x: URL? = URL(string: "https://x.com/DyorHQ_")

    /// A mail link with the subject and the app / device details support asks for. The subject and the details are for
    /// the support team and stay in English; the body is the user's to write, so its prompts are in the app's language.
    static func mail(subject: String, body: String = "") -> URL? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        // not localized: for the support team
        let details = "\n\n—\nDyorHQ iOS \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body + details)]
        return components.url
    }
}

/// Get Help: the docs to learn from, how to reach support and where the community lives, in the grouped-rows shape of
/// the reference app (Help Center, Getting Started, Risk Disclosures, Contracts & Addresses; Contact Support, Report a
/// Bug; X). Opened from the side menu as a full-screen page.
struct GetHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { GetHelpContent().padding(16) }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tr("Support"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                        .accessibilityLabel("Back")
                }
            }
        }
    }
}

/// The support rows themselves, so Profile can push them inside its own navigation.
struct GetHelpContent: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // The docs, opened in Safari like the Terms and Privacy links. Contracts & Addresses lists the v2 contracts
            // this build calls (`LaunchpadAddresses.monadMainnet`, `MomentsAddresses.monadMainnet`) and the retired ones:
            // `check-launchpad-addresses.py --release` refuses every archive until the published page does.
            group("Learn") {
                HelpRow(symbol: "book", title: "Help Center", detail: "Guides to every part of DyorHQ") { openURL(SupportLinks.helpCenter) }
                HelpRow(symbol: "flag", title: "Getting Started", detail: "From sign-in to your first trade") { openURL(DocsLinks.quickstart.url) }
                HelpRow(symbol: "exclamationmark.triangle", title: "Risk Disclosures", detail: "Read these before you trade") { openURL(DocsLinks.riskDisclosures.url) }
                HelpRow(symbol: "checkmark.seal", title: "Contracts & Addresses", detail: "Verify every contract DyorHQ uses") { openURL(DocsLinks.contractsAndAddresses.url) }
            }
            group("Get Help") {
                // not localized: the subjects are for the support team
                HelpRow(symbol: "envelope", title: "Contact Support", detail: SupportLinks.supportEmail) { mail(subject: "DyorHQ support") }
                HelpRow(symbol: "ladybug", title: "Report a Bug", detail: "Tell us what went wrong") {
                    mail(subject: "DyorHQ bug report", body: tr("What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n")) // not localized: the subject
                }
            }
            if let x = SupportLinks.x {
                group("Community") {
                    HelpRow(symbol: "at", title: Text(verbatim: "X"), detail: Text(verbatim: SupportLinks.xHandle)) { openURL(x) }
                }
            }
            group("About") {
                HelpRow(symbol: "globe", title: Text(verbatim: "dyorhq.fun"), detail: Text(verbatim: SupportLinks.tagline)) { openURL(SupportLinks.site) }
                HelpRow(symbol: "doc.text", title: Text("Terms of Use"), detail: Text(verbatim: "dyorhq.fun/terms")) { openURL(SupportLinks.terms) }
                HelpRow(symbol: "hand.raised", title: Text("Privacy Policy"), detail: Text(verbatim: "dyorhq.fun/privacy")) { openURL(SupportLinks.privacy) }
            }
            Paragraph("Self-custodial: support can never reach your keys or funds. Never share a recovery phrase with anyone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            rows()
        }
    }

    private func mail(subject: String, body: String = "") {
        guard let url = SupportLinks.mail(subject: subject, body: body) else { return }
        openURL(url)
    }

}

/// One support row: a symbol on a tinted square, a title and a one-line description, a chevron. The description is a
/// catalog key when written in the code, or a `String` shown as it is (the support address). A name or an address that
/// is never translated (X, dyorhq.fun) is given as a `Text(verbatim:)`.
private struct HelpRow: View {
    let symbol: String
    private let title: Text
    private let detail: Text
    let action: () -> Void

    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: Text(title), detail: Text(detail), action: action)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(symbol: String, title: LocalizedStringKey, detail: S, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: Text(title), detail: Text(verbatim: String(detail)), action: action)
    }

    init(symbol: String, title: Text, detail: Text, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 40, height: 40)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.body.weight(.semibold)).foregroundStyle(.primary)
                    detail.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + Text(verbatim: ". ") + detail)
    }
}
