import AuthenticationServices
import BigInt
import Combine
import DyorKit
import SwiftUI

/// Welcome → Get Started. A brand hero (serif wordmark over a soft purple glow) and an auto-advancing tour of what
/// DyorHQ does, then a focused hub that LEADS with the working path — Email & Password — and keeps Import / Watch as
/// quiet alternatives. Apple / Google appear only when the build actually enables them, so no one taps a dead method.
struct OnboardingView: View {
    @State private var path: [OnboardingStep] = []
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView { path.append(.signIn) }
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .signIn: SignInView(path: $path)
                    case .email: EmailPasswordView(path: $path)
                    case .watch: WatchAddressView(path: $path)
                    case .importWallet: ImportWalletView()
                    }
                }
        }
        // A Moment link that arrived signed out waits for the sign-in; RootView's gate opens it right after.
        .safeAreaInset(edge: .top) {
            if let link = router.pendingLink { PendingLinkBanner(link: link) }
        }
        .animation(.default, value: router.pendingLink)
    }
}

/// "Sign in to open the Moment you were sent": the link waits on the router until the sign-in, or is dismissed here.
private struct PendingLinkBanner: View {
    let link: MomentLink
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").foregroundStyle(Color.brand)
            Paragraph("Sign in to open the Moment you were sent.")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { router.pendingLink = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

enum OnboardingStep: Hashable {
    case signIn, email, watch, importWallet
}

struct WelcomeView: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Hero: the wordmark on a soft brand-purple glow.
            ZStack {
                BrandGlow().offset(y: -8)
                VStack(spacing: 10) {
                    Image(.wordmark)
                        .renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: 250)
                        .accessibilityLabel(Text(verbatim: "\(SupportLinks.name). \(SupportLinks.tagline)."))
                    Text(SupportLinks.tagline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
            .padding(.top, 44)

            // An auto-advancing tour of what you can do.
            FeatureTour()
                .frame(maxHeight: .infinity)
                .padding(.bottom, 32) // keep the page dots clear of the Get Started button
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 14) {
                PrimaryButton(title: "Get Started", action: onContinue)
                Label("DyorHQ never holds your keys or your funds.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
        }
    }
}

/// A soft radial halo in the Monad accent — the one splash of color on the monochrome canvas.
private struct BrandGlow: View {
    var body: some View {
        RadialGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0)],
                       center: .center, startRadius: 4, endRadius: 210)
            .frame(height: 240)
            .blur(radius: 18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Feature {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringResource
    init(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringResource) { self.symbol = symbol; self.title = title; self.detail = detail }
}

/// A gentle, swipeable carousel of the four things DyorHQ does. Auto-advances — unless the user prefers reduced motion,
/// VoiceOver or Switch Control is running (a card moving under the cursor, AI-12), or the user has swiped it themselves
/// — and loops forward seamlessly: it never visibly rewinds to the first card.
private struct FeatureTour: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @State private var index = 0
    /// The user took over by swiping: the tour stops advancing on its own.
    @State private var userPaused = false

    private let features = [
        Feature("camera.aperture", "Make Moments last forever", "Mint a photo or video as an NFT on Monad. Share it, and earn when it’s collected."),
        Feature("flame", "Launch a coin", "Fair-launch a memecoin paired with a tokenized stock."),
        Feature("arrow.left.arrow.right", "Swap at the best price", "Kuru, Uniswap and Monday Trade — compared on every swap."),
        Feature("chart.line.uptrend.xyaxis", "Trade perpetuals", "Perpl’s on-chain order book, signed by your own wallet."),
    ]
    // A copy of the first card is appended so the tour can slide FORWARD off the last card into it, then snap back to
    // the real first with no animation — an invisible seam, so the loop never rewinds backwards to the start.
    private var loop: [Feature] { features + [features[0]] }
    private var activeDot: Int { index % features.count }
    private let advance = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            TabView(selection: $index) {
                ForEach(loop.indices, id: \.self) { i in
                    FeatureCard(feature: loop[i]).tag(i).padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in userPaused = true })

            HStack(spacing: 7) {
                ForEach(features.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == activeDot ? Color.brand : Color.secondary.opacity(0.28))
                        .frame(width: i == activeDot ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeDot)
            .accessibilityHidden(true)
        }
        .onReceive(advance) { _ in
            guard !reduceMotion, !voiceOver, !switchControl, !userPaused else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index += 1 }
        }
        .onChange(of: index) { _, new in
            // Once we slide onto the duplicated first card, jump back to the real first with animations off. Both show
            // the same content, so the reset is invisible and the tour keeps moving forward forever.
            guard new == loop.count - 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard index == loop.count - 1 else { return } // the user didn't swipe elsewhere in the meantime
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { index = 0 }
            }
        }
    }
}

private struct FeatureCard: View {
    let feature: Feature

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.12)).frame(width: 100, height: 100)
                Image(systemName: feature.symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.brand)
            }
            VStack(spacing: 8) {
                Text(feature.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Paragraph(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(LanguageStore.self) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var path: [OnboardingStep]
    @State private var busy: String?
    @State private var error: String?
    @State private var appeared = false

    /// Any social/passkey method the build actually offers. When none do, the whole block (and its divider) is hidden
    /// so the user only ever sees paths that work.
    private var hasAlternates: Bool { session.hasSocialLogins || session.hasMera || session.hasPasskeys }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get started").font(.largeTitle.weight(.bold))
                    Paragraph("Your wallet is yours — you hold the keys.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                // The primary, recommended path.
                HeroAuthCard(title: "Email & Password",
                             subtitle: "Sign up or log in. New accounts verify with a one-time code.",
                             symbol: "envelope.fill") { Haptics.tap(); path.append(.email) }

                if hasAlternates {
                    LabeledDivider("or continue with")
                    VStack(spacing: 10) { alternates }
                }

                // Also the reason a restored Privy session was ended (its wallet couldn't be set up).
                if let message = error ?? session.lastError { InlineError(message: message) }

                LabeledDivider("more ways in")
                VStack(spacing: 10) {
                    SecondaryAuthRow(title: "Import a wallet",
                                     subtitle: "Use your recovery phrase or private key.",
                                     symbol: "square.and.arrow.down") { Haptics.tap(); path.append(.importWallet) }
                    SecondaryAuthRow(title: "Watch an address",
                                     subtitle: "Follow any Monad wallet. Trading needs an account.",
                                     symbol: "eye") { Haptics.tap(); path.append(.watch) }
                }

                VStack(spacing: 4) {
                    Label("DyorHQ never holds your keys or your funds.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    LearnMoreLink(.selfCustodyAndSecurity)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
        }
        .background(Color(.systemBackground))
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        // The app's language before sign-in, once there is a second one to choose.
        .toolbar {
            if language.available.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { LanguageMenu() }
            }
        }
        .disabled(busy != nil)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { appeared = true } }
    }

    @ViewBuilder private var alternates: some View {
        if session.hasSocialLogins {
            // Apple and Google always appear together (App Review 4.8), at the same size (Google's branding guidelines).
            AppleSignInButton(busy: busy == "apple") { Haptics.tap(); run("apple") { try await session.signInWithApple() } }
            GoogleSignInButton(busy: busy == "google") { run("google") { try await session.signInWithGoogle() } }
        }
        if session.hasMera {
            // A passkey account (Mera), one sign-in method among the others: a new one, or one the user already has —
            // on this phone, in iCloud Keychain, or on another phone by QR from the system sheet.
            SocialButton(title: "Create account with a passkey", symbol: BiometricGate.promptSymbol, busy: busy == "mera") { run("mera") { try await session.signInWithMera(create: true) } }
            SocialButton(title: "I already have a passkey", symbol: "person.badge.key", busy: busy == "mera-signin") { run("mera-signin") { try await session.signInWithMera(create: false) } }
        } else if session.hasPasskeys {
            SocialButton(title: "Sign in with a Passkey", symbol: "person.badge.key", busy: busy == "passkey") { run("passkey") { try await session.signInWithPasskey() } }
            // not localized: the passkey's name, the app's
            SocialButton(title: "Create a Passkey", symbol: "faceid", busy: busy == "create") { run("create") { try await session.createPasskey(displayName: "DyorHQ") } }
        }
    }

    private func run(_ key: String, _ work: @escaping () async throws -> Void) {
        busy = key
        error = nil
        session.lastError = nil // a new attempt replaces any earlier sign-in problem
        Task {
            do {
                try await work()
            } catch where isUserCancellation(error) {
                // Closing Apple's, Google's or the passkey sheet is a choice, not a failure — nothing to show.
            } catch {
                self.error = describe(error)
            }
            busy = nil
        }
    }
}

/// The primary sign-in affordance: a filled brand-purple card that draws the eye first.
private struct HeroAuthCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: symbol).font(.title3).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// A quiet, neutral alternative sign-in row.
private struct SecondaryAuthRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(.tertiarySystemFill)).frame(width: 42, height: 42)
                    Image(systemName: symbol).font(.body).foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle())
    }
}

/// A bordered full-width social/passkey button, matched to the hub's card language.
private struct SocialButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
                Text(title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(.primary)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        }
        // Plain style so the label stays neutral Ink (not the brand tint) — the purple hero stays the only focal point.
        .buttonStyle(.plain)
    }
}

/// Apple's own "Continue with Apple" button (ASAuthorizationAppleIDButton), as Privy recommends for its Swift SDK: a tap
/// hands the whole Sign in with Apple ceremony to PrivySDK, which presents Apple's native sheet. Apple draws the label,
/// artwork and accessibility; the style follows the appearance (black in light mode, white in dark).
private struct AppleSignInButton: View {
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        AppleIDButton(style: dark ? .white : .black, action: action)
            .id(dark) // the style is fixed when the button is created — rebuild it when the appearance changes
            .frame(height: 50)
            .overlay {
                if busy {
                    RoundedRectangle(cornerRadius: 14, style: .circular)
                        .fill(dark ? Color.white : Color.black)
                        .overlay(ProgressView().tint(dark ? .black : .white))
                        .accessibilityLabel("Signing in with Apple")
                }
            }
    }
}

private struct AppleIDButton: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: style)
        button.cornerRadius = 14
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// "Continue with Google" to Google's sign-in branding guidelines: the official "G" (cropped from Google's pre-approved
/// iOS assets, one per theme), Google Sans Medium, and the Light / Dark theme fill, 1pt inside stroke and text colors.
/// Same size as the Apple button, so neither provider is more prominent. The bundled Google Sans is a subset holding only
/// the English label's letters, so a label in another language is drawn in the system font (`GoogleButtonFont`).
private struct GoogleSignInButton: View {
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(LanguageStore.self) private var language

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 14, style: .circular)
        let label = tr(LocalizedStringResource("Continue with Google", comment: "Google's sign-in button: Google's own wording for the language, on one line [tight]"))
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 20, height: 20)
                } else {
                    Image("GoogleG").resizable().frame(width: 20, height: 20)
                }
                Text(verbatim: label)
                    .font(GoogleButtonFont.usesGoogleSans(label, language: language.resolved)
                          ? Font.custom("GoogleSans-Medium", size: 17, relativeTo: .body) : Font.body.weight(.medium))
                    // Scales with Dynamic Type up to the largest size that still fits the 50pt button in one line;
                    // beyond it the label would truncate (and "…" isn't in the subset font).
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(dark ? Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255)
                                  : Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255))
            .background(dark ? Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255) : .white, in: shape)
            .overlay(shape.strokeBorder(dark ? Color(red: 0x8E / 255, green: 0x91 / 255, blue: 0x8F / 255)
                                             : Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(busy ? "Signing in with Google" : "Continue with Google")
    }
}

/// A hairline rule with a small centered caption ("or continue with").
private struct LabeledDivider: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
            Text(text).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.tertiary).fixedSize()
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// Subtle press feedback for the card-style buttons.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Email + password onboarding. Sign up **verifies the email with a one-time code** (Privy), then sets a strong
/// password that deterministically becomes the wallet; log in re-derives the same wallet — no code — but only when the
/// email is a verified account matching the derived address. An account created before v2 is found only when the user
/// asks ("Signed up before September 24, 2026?") and upgrades once: a new password and an email re-verify move it to a
/// v2 wallet; while its old wallet still holds funds, log-in opens that wallet so they can be moved out first. If log-in
/// finds the email's anonymous `email-pepper` budget spent (anyone who knows the address can spend it), it offers the
/// one-time code instead: its Privy token opens the email's separate verified budget and log-in runs again. An email
/// already linked to another wallet is never moved off it without showing that wallet and what it holds, and a
/// confirmation. See `EmailWallet` (DyorKit), PasswordWallet.swift and `Session`.
struct EmailPasswordView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Binding var path: [OnboardingStep]

    enum Mode: String, CaseIterable, Identifiable {
        case signUp, logIn
        var id: String { rawValue }
        /// The mode's name on the segmented switch, in the app's language (never its raw value).
        var title: Text {
            switch self {
            case .signUp: Text("Sign Up", comment: "Email & Password: the switch's side that creates an account, a verb [tight]")
            case .logIn: Text("Log In", comment: "Email & Password: the switch's side for an existing account, a verb [tight]")
            }
        }
    }
    enum Stage { case form, otp }
    @State private var mode: Mode = .signUp
    @State private var stage: Stage = .form
    /// Forgot-password: re-verify the email by OTP, then bind it to a NEW password/wallet. Reuses the sign-up form and
    /// verify UI (it collects a new password the same way), but finishes through the `email-rebind` function.
    @State private var reset = false
    /// Log-in found an account created before v2, bound to an empty legacy wallet. It upgrades through the reset flow
    /// (`reset` is on): a NEW password — the old one's S stays guessable offline against the public legacy address —
    /// then the OTP, then that password's v2 wallet takes over the binding.
    @State private var upgrade: Upgrade?
    /// The user confirmed a used legacy wallet (`Upgrade.used`) holds nothing they want to keep.
    @State private var movedOut = false
    /// Log-in stopped on an `EmailPepperError` (the email's anonymous budget is spent, or a proof went stale): offer
    /// the email one-time code, whose token pays from the email's verified budget.
    @State private var offerVerification = false
    /// The code step is proving the email for log-in (not for sign-up or a reset); log-in runs again once it is done.
    @State private var verifyingLogIn = false
    /// Log-in found no v2 account: offer the check for one created before v2, which only the user can ask for (IOSK-2).
    @State private var offerLegacyCheck = false
    /// That check found the account's legacy wallet still funded: log in to it to move them out (GE-4).
    @State private var fundedLegacy: Address?
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @State private var acknowledged = false
    /// A reset's own acknowledgement: the current wallet's funds don't move to the new one (GE-2).
    @State private var fundsStay = false
    /// The email's code was accepted. Its Privy token proves the email to `email-rebind` for 15 minutes, so a bind that
    /// failed — or whose answer was lost after the server saved it — is retried with it, not with a new code (GE-5).
    /// The server's same-wallet re-bind changes nothing, so a retry after a lost answer simply finishes.
    @State private var verified: VerifiedEmail?
    /// The email is linked to another wallet (`email-rebind`'s 409, GE-1): what replacing it would leave behind.
    @State private var conflict: Conflict?
    @State private var replaceAcknowledged = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    /// The password fields are UIKit text fields (`PasswordField`), outside `focus`.
    @State private var passwordFocused = false
    @State private var confirmFocused = false

    private enum Field { case email, code }

    private struct Upgrade {
        /// The legacy wallet the email is bound to (already public in `profiles`).
        let legacy: Address
        /// It has sent transactions, so it may hold what the balance check can't see (Perpl collateral, launchpad or
        /// Moment holdings): the user confirms they've moved everything out (`movedOut`).
        let used: Bool
        /// The password log-in used, refused as the new one.
        let oldPassword: String
    }

    private struct VerifiedEmail {
        let token: String
        let at: Date
        /// `email-rebind` takes a Privy token for 15 minutes after it was issued; a minute is kept in hand.
        var isFresh: Bool { Date().timeIntervalSince(at) < 14 * 60 }
    }

    /// The wallet the email is linked to, and what the balance check sees in it (nil while it's read).
    private struct Conflict {
        let current: Address
        var holdings: Holdings?
        var readFailed = false
    }

    /// What a wallet holds that the balance check can see — MON and every curated token (`Token.core`) — plus how many
    /// transactions it has sent (it may then hold what balances can't show: Perpl collateral, coins, Moments), and
    /// whether it may be a legacy (pre-v2) wallet, judged by when its public profile was created.
    private struct Holdings {
        let amounts: [String]
        let transactions: UInt64
        let mayBeLegacy: Bool
        var isFunded: Bool { !amounts.isEmpty }
        /// The amounts as one list in the app's language ("12 MON and 3 USDC"). A wallet that holds none (`isFunded`) is
        /// a sentence of its own, never this list.
        var summary: String {
            let list = ListFormatter()
            list.locale = L10n.locale
            return list.string(from: amounts) ?? amounts.joined(separator: ", ")
        }
    }

    /// Sign-up and reset share the same "set a password" form and OTP verification; only login is different.
    private var setsPassword: Bool { mode == .signUp || reset }
    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.hasSuffix(".") }
    private var rejection: String? {
        if let upgrade, password == upgrade.oldPassword { return tr("Choose a new password — your current one can’t be reused.") }
        return PasswordStrength.rejection(password, email: email)
    }
    private var otpStage: Bool { (setsPassword || verifyingLogIn) && stage == .otp }
    private var formValid: Bool {
        guard emailValid else { return false }
        if setsPassword {
            return rejection == nil && !confirm.isEmpty && password == confirm && acknowledged && (upgrade?.used != true || movedOut)
                && (!reset || upgrade != nil || fundsStay)
        }
        return !password.isEmpty
    }

    var body: some View {
        Form {
            if !otpStage {
                if let upgrade {
                    Section {
                        Paragraph("Your account was created before our email-wallet security upgrade. Choose a new password: it becomes a new wallet that can’t be guessed offline, and we’ll email a code to confirm it’s you. Your previous wallet (\(upgrade.legacy.short)) has no MON or token balance left.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Security upgrade") }
                    .listRowBackground(Color.clear)
                } else if reset {
                    Section {
                        Paragraph("Resetting creates a **new, empty wallet** for your new password. Anything in your current wallet stays at its address and can only be reached with your old password. We’ll email a code to confirm it’s you.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Reset password") }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { $0.title.tag($0) } }
                            .pickerStyle(.segmented).labelsHidden()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .disabled(upgrade != nil) // the upgrade moves this email's account, found at log-in
                    PasswordField(title: reset ? "New password" : "Password", text: $password, focused: $passwordFocused)
                    if setsPassword {
                        PasswordField(title: "Confirm password", text: $confirm, focused: $confirmFocused)
                    }
                } footer: {
                    if reset {
                        if !password.isEmpty, !confirm.isEmpty, password != confirm {
                            Text("Passwords don’t match.").foregroundStyle(Color.negative)
                        }
                    } else if mode == .logIn {
                        VStack(alignment: .leading, spacing: 10) {
                            Paragraph("Log in with the email and password you signed up with. Your wallet is recreated on this device — no code needed.")
                            Button("Forgot password?") { beginReset() }.font(.footnote)
                        }
                    } else if !password.isEmpty, !confirm.isEmpty, password != confirm {
                        Text("Passwords don’t match.").foregroundStyle(Color.negative)
                    }
                }

                if setsPassword {
                    Section {
                        StrengthMeter(score: PasswordStrength.score(password))
                        if !password.isEmpty, let rejection {
                            Label(rejection, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
                        }
                        // The derivation takes the exact characters typed, so a password another keyboard may type
                        // differently is only warned about, never rewritten (IOSK-9).
                        if EmailWallet.hasHardToRetypeCharacters(password) {
                            Label("This password has characters beyond a standard keyboard, like curly quotes, long dashes or accents. It opens your wallet only when typed exactly the same way, so make sure you can type it on every device you’ll use.", systemImage: "character.cursor.ibeam")
                                .font(.caption).foregroundStyle(Color.attention)
                        }
                    } header: { Text("Password strength") }

                    Section {
                        Label {
                            if reset {
                                Paragraph("This new password **is** your new wallet. Keep it safe: if you lose it, you lose access to what you put in this wallet — write it down or save it in your password manager.")
                            } else {
                                Paragraph("This password **is** your wallet. We can’t reset it or send a recovery email. If you lose it, you lose access to your funds — write it down or save it in your password manager.")
                            }
                        } icon: {
                            Image(systemName: "key.horizontal.fill").foregroundStyle(Color.attention)
                        }
                        .modifier(ParagraphLabel())
                        .font(.footnote)
                        Toggle("I understand my password is the only way back to my wallet", isOn: $acknowledged).font(.footnote)
                        if reset, upgrade == nil {
                            Toggle("I understand my current wallet’s funds don’t move to the new one", isOn: $fundsStay).font(.footnote)
                        }
                        if let upgrade, upgrade.used {
                            Toggle("I’ve moved everything I want to keep out of my previous wallet (\(upgrade.legacy.short)). Anything left there won’t be reachable in DyorHQ after the upgrade.", isOn: $movedOut)
                                .font(.footnote)
                        }
                    }
                }
            } else if verified != nil {
                verifiedSections
            } else {
                Section {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).focused($focus, equals: .code)
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(6))
                            if code.count == 6 { completeVerification() }
                        }
                } header: {
                    Text("Verify your email")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let upgrade {
                            Paragraph("One-time security upgrade: enter the code we emailed to \(email). Your account then moves to the new wallet your new password creates. Your previous wallet (\(upgrade.legacy.short)) stays behind, and so does its public profile.")
                        } else if verifyingLogIn {
                            Paragraph("Enter the code we emailed to \(email). It proves the email is yours, so you can log in even while others are making attempts on it. We’ll log you in right after.")
                        } else if reset {
                            Paragraph("Enter the code we emailed to \(email). This confirms it’s you before your email moves to the new, empty wallet your new password creates.")
                        } else {
                            Paragraph("Enter the code we emailed to \(email). This proves the email is yours — your wallet is created after you verify, so no fake or unowned emails can register.")
                        }
                        HStack(spacing: 16) {
                            Button("Send a new code") { startSignUp() }.disabled(busy)
                            Button("Change details") { changeDetails() }.disabled(busy)
                        }
                        .font(.footnote)
                    }
                }
            }

            if let error {
                Section { InlineError(message: error) }.listRowBackground(Color.clear)
            }

            if offerVerification, !otpStage {
                Section {
                    Button("Verify Email", systemImage: "envelope.badge") { startLogInVerification() }
                } footer: {
                    Paragraph("We’ll email a one-time code to \(email). Entering it proves the email is yours, then we log you in.")
                }
            }

            if offerLegacyCheck, mode == .logIn, !reset, !otpStage {
                Section {
                    Button("Check for an Older Account", systemImage: "clock.arrow.circlepath") { logInLegacy() }
                } header: {
                    Paragraph("Signed up before September 24, 2026?")
                } footer: {
                    Paragraph("Accounts created before our email-wallet security upgrade are found with this extra check, then moved to a new password.")
                }
            }

            if let legacy = fundedLegacy, !otpStage {
                Section {
                    Paragraph("Your account’s original wallet (\(legacy.short)) still holds funds, so its security upgrade waits until they’re moved out. Log in to it now and send them to another wallet you control. Then log out and log in again to finish the upgrade.")
                        .font(.footnote)
                    Button("Log In to Move Funds", systemImage: "arrow.right.circle") { continueWithLegacy() }
                } header: { Text("Security upgrade") }
            }
        }
        .navigationTitle(otpStage ? tr("Verify Email") : (upgrade != nil ? tr("Security Upgrade") : reset ? tr("Reset Password") : tr("Email & Password")))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        // No way back mid-request: a reset or sign-up the server may already have saved can't be left half-seen (GE-5).
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if reset, !busy { Button("Cancel") { cancelReset() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() }
                else if otpStage { if verified == nil { Button("Verify") { completeVerification() }.disabled(code.count != 6) } }
                else if mode == .logIn, !reset { Button("Log In") { logIn() }.disabled(!formValid) }
                else { Button("Continue") { startSignUp() }.disabled(!formValid) }
            }
        }
        .onAppear { focus = .email }
        // Email proofs only live for this screen's flow; they never outlast it, and neither does a held legacy wallet.
        .onDisappear {
            let backend = env.social.client
            Task { await backend.forgetEmailProofs() }
            if fundedLegacy != nil, session.account == nil { dropFundedLegacy() }
        }
        .onChange(of: mode) { _, _ in
            stage = .form; code = ""; error = nil; offerVerification = false; verifyingLogIn = false; offerLegacyCheck = false
            verified = nil; conflict = nil
            dropFundedLegacy()
        }
        .onChange(of: email) { _, _ in offerVerification = false; offerLegacyCheck = false; dropFundedLegacy() }
        .onChange(of: password) { _, _ in offerLegacyCheck = false; dropFundedLegacy() }
    }

    // MARK: Verified email (GE-1, GE-5)

    @ViewBuilder private var verifiedSections: some View {
        Section {
            Label("Email verified: \(email)", systemImage: "checkmark.seal.fill")
                .font(.subheadline)
                .foregroundStyle(Color.positive)
        } footer: {
            Button("Change details") { changeDetails() }.font(.footnote)
        }
        if let conflict {
            conflictSections(conflict)
        } else {
            Section {
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await runBind(replacing: nil) } }
            } footer: {
                Paragraph("Your code was accepted, so no new code is needed. If the last attempt went through after all, this just finishes it.")
            }
        }
    }

    @ViewBuilder private func conflictSections(_ conflict: Conflict) -> some View {
        Section {
            if reset || upgrade != nil {
                Paragraph("Your email is linked to the DyorHQ wallet \(conflict.current.checksummed). Going on moves your email to a new, empty wallet. Funds in \(conflict.current.short) stay there, reachable only with its old password.")
            } else {
                Paragraph("This email already has a DyorHQ wallet (\(conflict.current.checksummed)). Log in instead, or replace it: funds in \(conflict.current.short) stay there.")
            }
            if let holdings = conflict.holdings {
                if holdings.isFunded {
                    Label("\(conflict.current.short) holds \(holdings.summary).", systemImage: "dollarsign.circle")
                } else {
                    Label("\(conflict.current.short) holds no MON or tokens.", systemImage: "circle.dashed")
                }
                if holdings.transactions > 0 {
                    Label("It has sent \(Int(clamping: holdings.transactions)) transactions, so it may also hold positions, collateral or coins not shown here.", systemImage: "clock.arrow.circlepath")
                }
            } else if conflict.readFailed {
                Label("Couldn’t read what \(conflict.current.short) holds. Check your connection and try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.attention)
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await readConflictHoldings() } }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading \(conflict.current.short)…").foregroundStyle(.secondary) }
            }
        } header: {
            Text(reset || upgrade != nil ? "Your current wallet" : "Email already registered")
        }
        .font(.footnote)

        if !reset, upgrade == nil {
            Section {
                Button("Log In Instead", systemImage: "person.crop.circle") { switchToLogIn() }
            }
        }

        if let holdings = conflict.holdings {
            if holdings.mayBeLegacy, holdings.isFunded {
                // Never off a funded legacy wallet: no password this app knows could reach it again (GE-1).
                Section {
                    InlineError(message: "\(conflict.current.short) was created before our security upgrade and still holds \(holdings.summary). Moving your email off it would leave that out of reach in DyorHQ. Log in with its password (Signed up before September 24, 2026?) to move the funds out first.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Toggle(replaceAcknowledgement(conflict.current, holdings), isOn: $replaceAcknowledged).font(.footnote)
                    Button("Replace Wallet", systemImage: "arrow.triangle.swap", role: .destructive) { Task { await runBind(replacing: conflict.current) } }
                        .disabled(!replaceAcknowledged)
                }
            }
        }
    }

    /// The confirmation, naming exactly what stays behind: each case one whole sentence, in the app's language.
    private func replaceAcknowledgement(_ current: Address, _ holdings: Holdings) -> String {
        let wallet = current.short, summary = holdings.summary
        switch (holdings.isFunded, holdings.transactions > 0) {
        case (true, true): return tr("I understand \(wallet) keeps its \(summary), and anything else it holds, and this email will no longer open it.")
        case (true, false): return tr("I understand \(wallet) keeps its \(summary) and this email will no longer open it.")
        case (false, true): return tr("I understand this email will no longer open \(wallet), which holds no MON or tokens (it may hold other things).")
        case (false, false): return tr("I understand this email will no longer open \(wallet), which holds no MON or tokens.")
        }
    }

    // MARK: Actions

    /// Send the sign-up OTP, then move to the verify step.
    private func startSignUp() {
        dismissKeyboard(); busy = true; error = nil
        verified = nil; conflict = nil
        Task {
            do { try await session.sendSignUpCode(to: email); stage = .otp; code = ""; focus = .code }
            catch { self.error = describe(error) }
            busy = false
        }
    }

    private func changeDetails() {
        stage = .form; code = ""; verifyingLogIn = false; verified = nil; conflict = nil; error = nil
    }

    private func logIn() {
        dismissKeyboard(); busy = true; error = nil; offerVerification = false; offerLegacyCheck = false
        dropFundedLegacy()
        Task {
            do {
                _ = try await session.logInWithPassword(email: email, password: password, pepper: fetchPepper, verify: verifyBinding)
                await env.social.client.forgetEmailProofs()
            } catch {
                await env.social.client.signOut() // never leave a check-in session behind a failed log-in
                // The email's anonymous budget is spent (or a proof went stale): offer the one-time code, not a wait.
                offerVerification = error is EmailPepperError
                // No v2 account for this email and password: the older-account check is the user's call (IOSK-2).
                if case SessionError.emailNotVerified = error { offerLegacyCheck = true }
                self.error = logInMessage(for: error)
            }
            busy = false
        }
    }

    /// "Signed up before September 24, 2026?" — the log-in check for an account created before v2 (IOSK-2). Empty, it
    /// upgrades; still funded, it offers to log in to that wallet so the funds can be moved out first (GE-4).
    private func logInLegacy() {
        dismissKeyboard(); busy = true; error = nil; offerVerification = false
        dropFundedLegacy()
        Task {
            do {
                switch try await session.logInToLegacyAccount(email: email, password: password, verify: verifyBinding, holdsFunds: legacyHoldsFunds) {
                case .needsUpgrade(let legacy):
                    await env.social.client.signOut() // the legacy wallet's check-in session is not the user's session
                    let used: Bool
                    do { used = try await env.rpc.transactionCount(of: legacy) > 0 }
                    catch { throw SessionError.legacyBalanceUnavailable }
                    offerLegacyCheck = false
                    beginUpgrade(Upgrade(legacy: legacy, used: used, oldPassword: password))
                case .legacyHoldsFunds(let legacy):
                    // Its check-in session stays: if the user logs in to that wallet, it is theirs.
                    offerLegacyCheck = false
                    fundedLegacy = legacy
                case .signedIn:
                    break
                }
            } catch {
                await env.social.client.signOut()
                self.error = logInMessage(for: error)
            }
            busy = false
        }
    }

    /// Logs in to the funded legacy wallet the older-account check found (GE-4).
    private func continueWithLegacy() {
        busy = true
        Task {
            fundedLegacy = nil
            await session.continueWithLegacyWallet()
            await env.social.client.forgetEmailProofs()
            busy = false
        }
    }

    /// Lets go of a funded legacy wallet the user didn't log in to, and of its check-in session.
    private func dropFundedLegacy() {
        guard fundedLegacy != nil else { return }
        fundedLegacy = nil
        session.forgetPendingLegacy()
        let backend = env.social.client
        Task { await backend.signOut() }
    }

    /// What a failed log-in says. An outage never reads as a wrong password (GE-6). A password with plain quotes or
    /// dashes gets a hint: the field no longer lets iOS turn them into curly quotes or long dashes (IOSK-9), which a
    /// password typed with the eye button on may contain.
    private func logInMessage(for error: Error) -> String {
        if SupabaseError.isOutage(error) {
            return tr("We couldn’t reach DyorHQ to check your password. Nothing is wrong with your password or your wallet: try again in a few minutes, and don’t reset your password meanwhile — a reset creates a new, empty wallet.")
        }
        let message = describe(error)
        guard case SessionError.emailNotVerified = error, password.contains(where: { "'\"-".contains($0) }) else { return message }
        return tr("\(message) If you made this password with it shown (the eye button), iOS may have typed curly quotes or a long dash in it: hold the key down to type those.")
    }

    /// Log-in hit `EmailPepperError`: email the one-time code (the same Privy OTP as sign-up), then the code step's
    /// token opens the email's verified budget and log-in runs again (`completeVerification`).
    private func startLogInVerification() {
        dismissKeyboard(); busy = true; error = nil
        Task {
            do {
                try await session.sendSignUpCode(to: email)
                verifyingLogIn = true; offerVerification = false; stage = .otp; code = ""; focus = .code
            } catch { self.error = describe(error) }
            busy = false
        }
    }

    // MARK: Forgot password (re-verify the email, then re-bind it to the new password's wallet)

    /// Switch the Log In form into the reset flow: same fields, but a fresh new password and a required email re-verify.
    private func beginReset() {
        reset = true; stage = .form; password = ""; confirm = ""; code = ""; acknowledged = false; fundsStay = false; error = nil; focus = .email
        offerVerification = false; verifyingLogIn = false; offerLegacyCheck = false; verified = nil; conflict = nil
        dropFundedLegacy()
    }

    private func cancelReset() {
        reset = false; stage = .form; code = ""; error = nil; upgrade = nil; movedOut = false; fundsStay = false
        verified = nil; conflict = nil
    }

    /// The pre-v2 upgrade is a reset of this email's account onto a new password (see `upgrade`).
    private func beginUpgrade(_ found: Upgrade) {
        beginReset(); upgrade = found; movedOut = false; focus = nil; passwordFocused = true
    }

    /// From the "email already registered" answer to Sign Up: the same email, on Log In.
    private func switchToLogIn() {
        mode = .logIn
        password = ""; confirm = ""; acknowledged = false; replaceAcknowledged = false
        verified = nil; conflict = nil
        passwordFocused = true
    }

    /// Verify the email OTP, then bind it to the wallet the password derives — server-side, through the `email-rebind`
    /// function. Sign-up, forgot-password and the pre-v2 upgrade all land here; only the upgrade names a legacy wallet
    /// to check first. Nothing is committed until the server re-verifies both proofs, so a failed attempt leaves any
    /// current session untouched. The OTP's Privy token also pays for this email's pepper from its verified budget,
    /// so these flows never meet the anonymous limit; a log-in that did (`verifyingLogIn`) just runs again with it.
    private func completeVerification() {
        guard code.count == 6, !busy else { return }
        dismissKeyboard(); busy = true; error = nil
        Task {
            do {
                let token = try await session.verifyEmailCapturingToken(email: email, code: code)
                // Sent only to `email-pepper` (for this email's e) and `email-rebind` — nowhere else.
                await env.social.client.rememberEmailProof(token, forEmail: email)
                code = ""
                if verifyingLogIn {
                    verifyingLogIn = false; stage = .form; busy = false
                    logIn()
                    return
                }
                verified = VerifiedEmail(token: token, at: Date())
                busy = false
                await runBind(replacing: nil)
                return
            } catch {
                self.error = describe(error)
                code = ""
            }
            busy = false
        }
    }

    /// Binds the verified email to the new password's wallet with the verified token: the first attempt, a retry after
    /// a failure (GE-5), or — `replacing` — the confirmed move off the wallet the email is linked to (GE-1).
    private func runBind(replacing current: Address?) async {
        guard let verified, verified.isFresh else {
            self.verified = nil; conflict = nil
            self.error = tr("Your email verification expired. Send a new code to continue.")
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            // A wallet that may be legacy is checked again right before the email moves off it (GE-1): what the user
            // saw may be out of date. Unknown counts as maybe.
            let mayBeLegacy = current != nil && conflict?.current == current && conflict?.holdings?.mayBeLegacy != false
            try await session.bindEmailPassword(email: email, password: password, token: verified.token,
                                                upgradingFrom: upgrade?.legacy, replacing: current, replacingMayBeLegacy: mayBeLegacy,
                                                pepper: fetchPepper, holdsFunds: legacyHoldsFunds, bind: bindViaServer)
            await env.social.client.forgetEmailProofs()
        } catch SessionError.emailAlreadyBound(let bound) {
            // Show that wallet and what it holds, and ask, before the email moves off it.
            replaceAcknowledged = false
            conflict = Conflict(current: bound)
            Task { await readConflictHoldings() }
        } catch SessionError.legacyWalletHasFunds(let funded) where funded == current {
            // Funds reached it after it was read: show them (a funded legacy wallet is never replaced), and ask again.
            replaceAcknowledged = false
            await readConflictHoldings()
        } catch EmailAuthError.verificationExpired {
            self.verified = nil; conflict = nil
            self.error = tr("Your email verification expired. Send a new code to continue.")
        } catch {
            // A failed Replace Wallet is retried with its own button, which stays on screen.
            if !SupabaseError.isOutage(error) {
                self.error = describe(error)
            } else if conflict == nil {
                self.error = tr("We couldn’t reach DyorHQ to finish. Your email is verified, so tap Try Again — no new code needed.")
            } else {
                self.error = tr("We couldn’t reach DyorHQ to finish. Your email is verified, so tap Replace Wallet again — no new code needed.")
            }
        }
    }

    /// Reads what the linked wallet holds (GE-1). A failed read allows nothing: an unknown balance is not an empty one.
    private func readConflictHoldings() async {
        guard let current = conflict?.current else { return }
        conflict?.readFailed = false
        conflict?.holdings = nil
        do {
            let holdings = try await walletHoldings(current)
            if conflict?.current == current { conflict?.holdings = holdings }
        } catch {
            if conflict?.current == current { conflict?.readFailed = true }
        }
    }

    /// Push the OTP proof (Privy token) and the wallet's signature to the `email-rebind` function, which verifies both
    /// and writes the binding with the service role. This is the ONLY path that writes the email → wallet row — direct
    /// PostgREST writes are revoked (migration 16) — so an email that wasn't OTP-verified can never be bound. `replace`
    /// names the wallet the user confirmed moving off (GE-1); without it, a binding to another wallet is answered 409
    /// with that wallet, and nothing is written.
    private func bindViaServer(_ token: String, _ message: String, _ signature: String, _ replace: Address?) async throws {
        struct Body: Encodable { let message: String; let signature: String; let replace: String? }
        let body = try JSONEncoder().encode(Body(message: message, signature: signature, replace: replace?.checksummed.lowercased()))
        do { _ = try await env.social.client.invoke(function: "email-rebind", bearer: token, body: body) }
        catch SupabaseError.http(409, let text) {
            // not localized: the function's own error code
            guard Self.serverField(text, "error") == "email_already_bound", let current = Self.serverField(text, "current").flatMap({ Address($0) }) else {
                throw EmailAuthError.bindFailed(Self.serverMessage(text))
            }
            throw SessionError.emailAlreadyBound(current)
        }
        // not localized: the function's own English word for a stale token, matched whatever the app's language
        catch SupabaseError.http(401, let text) where Self.serverField(text, "error")?.contains("expired") == true { throw EmailAuthError.verificationExpired }
        catch SupabaseError.http(let code, let text) where !(500...599).contains(code) { throw EmailAuthError.bindFailed(Self.serverMessage(text)) }
    }

    /// One string field of the edge function's JSON answer.
    private static func serverField(_ text: String, _ key: String) -> String? {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    /// Surfaces the `{ "error": … }` reason the edge function returns (e.g. wrong code, expired) as a clean sentence: one
    /// the app knows in the app's language (`EdgeFunctionError`), any other as the server wrote it.
    private static func serverMessage(_ text: String) -> String {
        guard let msg = serverField(text, "error"), !msg.isEmpty else {
            return tr("We couldn’t confirm that. Please try again.")
        }
        return EdgeFunctionError.emailRebind(msg)
    }

    /// Ends editing in every field, the UIKit password fields included.
    private func dismissKeyboard() {
        focus = nil; passwordFocused = false; confirmFocused = false
    }

    // MARK: v2 derivation inputs

    /// The server pepper for (e, t) — the `email-pepper` function, called before sign-in: from the email's verified
    /// budget when this screen holds its one-time-code token (`rememberEmailProof`), else the anonymous one.
    private func fetchPepper(_ e: Data, _ t: Data) async throws -> Data {
        try await env.social.client.emailPepper(e: e, t: t)
    }

    /// Does a legacy (pre-v2) wallet hold anything? Native MON or any curated token (`Token.core`: USDC, AUSD, USDT0,
    /// WMON, …) — any non-zero balance keeps the email on it. Only ever asked about the bound legacy wallet log-in
    /// found, whose address is already public. What balances can't show (Perpl collateral, launchpad or Moment
    /// holdings) takes transactions from the wallet, which log-in turns into an explicit confirmation (`Upgrade.used`).
    private func legacyHoldsFunds(_ legacy: Address) async throws -> Bool {
        !(try await balances(of: legacy)).isEmpty
    }

    /// The non-zero balances of MON and every curated token (`Token.core`). Throws when any can't be read.
    private func balances(of wallet: Address) async throws -> [(token: Token, amount: BigUInt)] {
        let rpc = env.rpc, multicall = env.multicall
        let tokens = Token.core.filter { !$0.isNative }
        let calls = try tokens.map { try ERC20.balanceOf($0.address, wallet) }
        async let native = rpc.balance(of: wallet)
        async let results = multicall.readAll(calls)
        let (mon, read) = try await (native, results)
        let amounts = read.compactMap { $0.first?.uintOrNil }
        guard amounts.count == calls.count else { throw SessionError.legacyBalanceUnavailable }
        let all: [(token: Token, amount: BigUInt)] = [(token: Token.mon, amount: mon)] + zip(tokens, amounts).map { pair in (token: pair.0, amount: pair.1) }
        return all.filter { $0.amount > 0 }
    }

    /// What the wallet an email is linked to holds, for the GE-1 confirmation: its balances, how many transactions it
    /// has sent, and whether it may be a legacy wallet (its public profile predates v2; unknown counts as maybe).
    private func walletHoldings(_ wallet: Address) async throws -> Holdings {
        let rpc = env.rpc, backend = env.social.client
        let held = try await balances(of: wallet)
        let sent = try await rpc.transactionCount(of: wallet)
        struct Profile: Decodable { let created_at: String }
        let profiles: [Profile]? = try? await backend.read("profiles", query: [
            URLQueryItem(name: "select", value: "created_at"),
            URLQueryItem(name: "wallet", value: "eq.\(wallet.checksummed.lowercased())"),
        ])
        let created = profiles?.first.flatMap { SupabaseClient.timestamp($0.created_at) }
        let amounts = held.map { "\(NumberStyle.units($0.amount, decimals: $0.token.decimals)) \($0.token.symbol)" }
        return Holdings(amounts: amounts, transactions: sent, mayBeLegacy: EmailWallet.mayBeLegacy(profileCreatedAt: created))
    }

    // MARK: Backend gate (email_accounts)

    /// Login gate: is this email bound to exactly the derived wallet? The derived wallet proves itself by signing in to
    /// the backend (wallet-auth), then reads ITS OWN binding under row-level security. There is deliberately no
    /// anonymous "does this email match this wallet" lookup — that would let anyone confirm a guessed password online.
    /// A wrong password derives a wallet with no binding: it reads nothing, the temporary session is dropped, and no
    /// profile row is created for it.
    private func verifyBinding(_ email: String, _ account: Secp256k1Account) async throws -> Bool {
        let signer = LocalWallet(account: account)
        let backend = env.social.client
        _ = try await backend.signIn(address: account.address.checksummed) { message in try await signer.signMessage(message) }
        struct Binding: Decodable { let email: String }
        let wallet = account.address.checksummed.lowercased()
        let rows: [Binding]
        do {
            rows = try await backend.read("email_accounts", query: [URLQueryItem(name: "select", value: "email"),
                                                                    URLQueryItem(name: "wallet", value: "eq.\(wallet)")], authed: true)
        } catch {
            await backend.signOut()
            throw error
        }
        let matches = rows.contains { $0.email == email }
        if !matches { await backend.signOut() } // never leave a session for a wallet that isn't the user's
        return matches
    }
}

enum EmailAuthError: LocalizedError {
    case bindFailed(String)
    /// `email-rebind` refused the one-time code's token as too old: a new code is needed.
    case verificationExpired
    var errorDescription: String? {
        switch self {
        case .bindFailed(let message): return message
        case .verificationExpired: return tr("Your email verification expired. Send a new code to continue.")
        }
    }
}

/// A password field with a reveal toggle — reveal matters here because a mistyped password derives a different
/// wallet, and iOS's password content type lets the user save/autofill it (so they don't forget it). A UIKit text
/// field, so that nothing rewrites what is typed (IOSK-9): no smart quotes, smart dashes or smart insert/delete, no
/// autocorrection, autocapitalization, spell checking or inline predictions, revealed or not. The password is the
/// wallet, so its characters must be exactly the keys pressed.
private struct PasswordField: View {
    /// The placeholder and VoiceOver label: a UIKit field takes a `String`, so it is resolved in the app's language.
    let title: LocalizedStringResource
    @Binding var text: String
    @Binding var focused: Bool
    @State private var reveal = false

    var body: some View {
        HStack {
            PlainTextField(title: tr(title), text: $text, secure: !reveal, focused: $focused)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
    }
}

/// The UITextField behind `PasswordField`, with every automatic text rewrite off.
private struct PlainTextField: UIViewRepresentable {
    let title: String
    @Binding var text: String
    let secure: Bool
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focused: $focused) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = title
        field.accessibilityLabel = title
        field.textContentType = .password
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.isSecureTextEntry = secure
        field.text = text
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focused = $focused
        if field.text != text { field.text = text }
        if field.isSecureTextEntry != secure { field.isSecureTextEntry = secure }
        field.placeholder = title
        field.accessibilityLabel = title
        let wantsFocus = focused
        if wantsFocus != field.isFirstResponder {
            // Outside SwiftUI's update pass, and only once the field is in a window.
            DispatchQueue.main.async {
                guard field.window != nil, wantsFocus != field.isFirstResponder else { return }
                if wantsFocus { field.becomeFirstResponder() } else { field.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: uiView.intrinsicContentSize.height)
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var focused: Binding<Bool>

        init(text: Binding<String>, focused: Binding<Bool>) {
            self.text = text
            self.focused = focused
        }

        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) { if !focused.wrappedValue { focused.wrappedValue = true } }
        func textFieldDidEndEditing(_ field: UITextField) { if focused.wrappedValue { focused.wrappedValue = false } }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

/// Four-segment strength bar for the sign-up password.
private struct StrengthMeter: View {
    let score: Int // 0…4

    private var tint: Color {
        switch score { case 0, 1: return .negative; case 2: return .attention; default: return .positive }
    }
    /// The strength's name in the app's language; a space keeps the row's height while nothing is typed.
    private var label: String {
        switch score {
        case 0: return " "
        case 1: return tr(LocalizedStringResource("Weak", comment: "A password's strength [tight]"))
        case 2: return tr(LocalizedStringResource("Fair", comment: "A password's strength [tight]"))
        case 3: return tr(LocalizedStringResource("Good", comment: "A password's strength [tight]"))
        default: return tr(LocalizedStringResource("Strong", comment: "A password's strength [tight]"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < score ? tint : Color(.tertiarySystemFill))
                        .frame(height: 5)
                }
            }
            Text(label).font(.caption2).foregroundStyle(tint)
        }
    }
}

struct WatchAddressView: View {
    @Environment(Session.self) private var session
    @Binding var path: [OnboardingStep]
    @State private var text = ""
    @FocusState private var focused: Bool

    private var address: Address? { Address(text) }

    var body: some View {
        Form {
            Section {
                TextField("0x…" as String, text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { watch() }
            } header: {
                Text("Monad address")
            } footer: {
                if !text.isEmpty, address == nil {
                    Paragraph("Enter a 42-character address starting with 0x.")
                } else {
                    Paragraph("Balances, positions and launches for this address will be shown. Nothing can be signed.")
                }
            }
            Section {
                Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                    if let pasted = UIPasteboard.general.string { text = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        .navigationTitle(tr("Watch an Address"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { watch() } label: { Text("Watch", comment: "Starts following this address without signing in, a verb [tight]") }
                    .disabled(address == nil)
            }
        }
        .onAppear { focused = true }
    }

    private func watch() {
        guard let address else { return }
        session.watch(address)
    }
}
