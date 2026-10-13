import StellarKit
import SwiftUI

/// Lite's root: onboarding (invite + activation) until the account is ready, then four tabs.
/// The host shows it instead of the Pro tabs when the user switches to Lite.
@MainActor
public struct LiteRootView: View {
    @State private var store: LiteStore
    private let onSwitchToPro: () -> Void

    public init(env: LiteEnvironment, keys: LiteKeyProvider, monad: LiteMonadBridge? = nil, onSwitchToPro: @escaping () -> Void) {
        _store = State(initialValue: LiteStore(env: env, keys: keys, monad: monad))
        self.onSwitchToPro = onSwitchToPro
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .starting:
                ProgressView("Opening Lite…").task { await store.start() }
            case .needsInvite:
                InviteView(onSwitchToPro: onSwitchToPro)
            case .needsActivation:
                ActivationView(onSwitchToPro: onSwitchToPro)
            case .unavailable(let why):
                ContentUnavailableView {
                    Label("Lite isn't available", systemImage: "moon.zzz")
                } description: {
                    Text(why)
                } actions: {
                    Button("Try again") { Task { await store.start() } }
                    Button("Back to Pro", action: onSwitchToPro)
                }
            case .ready:
                LiteTabs(onSwitchToPro: onSwitchToPro)
            }
        }
        .environment(store)
        .tint(LiteTheme.accent)
    }
}

struct LiteTabs: View {
    let onSwitchToPro: () -> Void
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiteHomeView(onSwitchToPro: onSwitchToPro)
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            LiteEarnView()
                .tabItem { Label("Earn", systemImage: "leaf") }.tag(1)
            LiteLaunchView()
                .tabItem { Label("Launch", systemImage: "flame") }.tag(2)
            LiteMomentsView()
                .tabItem { Label("Moments", systemImage: "camera.aperture") }.tag(3)
        }
        .sensoryFeedback(.selection, trigger: tab)
    }
}

/// First Lite sign-in for an account: an invite code binds it to the internal-tester allowlist.
struct InviteView: View {
    @Environment(LiteStore.self) private var store
    let onSwitchToPro: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 52)).foregroundStyle(LiteTheme.accent)
            Text("DyorHQ Lite").font(.largeTitle.bold())
            Text("Save, earn, swap, launch and collect on Stellar, with no fees to pay. Lite is invite-only while we test it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("Invite code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(LiteTheme.negative).font(.footnote) }
            LitePrimaryButton(title: "Join Lite", busy: busy, enabled: code.count >= 8) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await store.signIn(invite: code) } catch { self.error = describe(error) }
                }
            }
            Button("Back to Pro", action: onSwitchToPro).font(.footnote)
            Spacer()
        }
        .padding(24)
    }
}

/// Creates the Stellar account (DyorHQ pays) and enables USDC.
struct ActivationView: View {
    @Environment(LiteStore.self) private var store
    let onSwitchToPro: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal").font(.system(size: 52)).foregroundStyle(LiteTheme.accent)
            Text("One tap to set up").font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                Label("Your Stellar account comes from the same secret as your DyorHQ account.", systemImage: "key")
                Label("DyorHQ pays the network fees and the account reserve.", systemImage: "gift")
                if store.network.name == "testnet" { Label("Testnet: you get 10,000 test XLM to try everything.", systemImage: "testtube.2") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(LiteTheme.negative).font(.footnote) }
            LitePrimaryButton(title: "Set up Lite", busy: busy) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await store.activate() } catch { self.error = describe(error) }
                }
            }
            Button("Back to Pro", action: onSwitchToPro).font(.footnote)
            Spacer()
        }
        .padding(24)
    }
}
