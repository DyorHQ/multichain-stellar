// Replaces `MainTabView()` in RootView's `.signedIn` case:  ProLiteRoot()
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

struct ProLiteRoot: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @State private var mode: AppMode = .pro
    @State private var keys: LiteKeyProvider?
    @State private var preparing = false
    @State private var error: String?

    private var liteAvailable: Bool { LiteGate.isAvailable(session: session, serverFlag: env.stellarLiteEnabled) }

    var body: some View {
        Group {
            if mode == .lite, let keys {
                LiteRootView(env: LiteGate.environment, keys: keys, monad: MonadBridgeAdapter(session: session)) { switchTo(.pro) }
                    .transition(.move(edge: .trailing))
            } else {
                MainTabView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if liteAvailable {
                            ModePill(isLite: false) { switchTo(.lite) }
                                .padding(.vertical, 4)
                                .overlay { if preparing { ProgressView() } }
                        }
                    }
            }
        }
        .animation(.snappy, value: mode)
        // Re-run when the remote flag arrives (after the first appearance, from UpdateGate's read) or goes off.
        .task(id: "\(session.address?.description ?? "")|\(liteAvailable)") {
            keys = nil
            mode = liteAvailable ? AppMode.current(for: session.address) : .pro
            if mode == .lite { keys = await DyorHQLiteKeys.provider(session: session) }
            if keys == nil { mode = .pro }
        }
        .alert("Lite isn't ready", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func switchTo(_ next: AppMode) {
        if next == .pro {
            mode = .pro
            AppMode.set(.pro, for: session.address)
            return
        }
        Task {
            preparing = true
            defer { preparing = false }
            do {
                // First switch on a passkey account: one passkey prompt derives the Stellar address (public; stored).
                keys = try await DyorHQLiteKeys.prepare(session: session)
                mode = .lite
                AppMode.set(.lite, for: session.address)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
#endif
