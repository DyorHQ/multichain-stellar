import DyorKit
import SwiftUI

/// Account deletion, as App Store guideline 5.1.1(v) requires of an app that creates accounts. Everything DyorHQ
/// keeps for the account goes: the profile and every server row keyed to the wallet (posts, comments, follows,
/// alerts, watchlists, referral codes, device tokens — they cascade from the profile row), the
/// profile picture, the Privy sign-in account when there is one, a passkey account's passkey (reported to the passkey
/// provider, MERA-PLAN §8), and every key, token, cache and setting on this device. Funds and on-chain history stay on
/// the blockchain, reachable only through the user's own backup.
enum AccountDeletion {
    enum Failure: LocalizedError {
        case backendSignInNeeded(String)
        case privyNotConfigured
        /// An Email & Password account's email sign-in at Privy couldn't be deleted; nothing was deleted yet (SB-7).
        case emailSignInNotDeleted(String)

        /// The failure in the app's language; `why` is already in it (the app's text, or a server's known message).
        var errorDescription: String? {
            switch self {
            case .backendSignInNeeded(let why):
                return tr("The server verifies it is your wallet before deleting anything, and that sign-in didn't complete: \(why)")
            case .privyNotConfigured:
                return tr("Your DyorHQ data was deleted and this iPhone is signed out, but the sign-in account (Privy) could not be: deletion isn't enabled on the server yet. Contact support to finish.")
            case .emailSignInNotDeleted(let why):
                return tr("Nothing was deleted: removing the email sign-in DyorHQ created at Privy didn't work (\(why)). Try again in a few minutes, or contact \(SupportLinks.supportEmail).")
            }
        }
    }

    /// Runs the whole deletion. Server data first (authorized by the wallet's own signature), then the Privy
    /// account, then this device. A failure before the server data is deleted throws with nothing changed, so a retry
    /// is safe. Once it is deleted, this device signs out whatever happens next, so no later launch can recreate the
    /// profile (security audit 2026-09-26, RI-8); a Privy account that couldn't be deleted is reported afterwards
    /// (`Session.deletionNotice`). A passkey account goes through `deletePasskeyAccount`, which also removes the passkey.
    @MainActor
    static func run(session: Session, social: SocialSession, env: AppEnvironment) async throws {
        guard let account = session.account else { return }
        if account.method == .meraPasskey {
            try await deletePasskeyAccount(shown: account.address, session: session, social: social, env: env)
            return
        }
        let wallet = account.address.checksummed.lowercased()
        var notice: String?

        if account.canSign {
            // Profile work still running — a stored token's restore, a sign-in's follow-up — is waited out before and
            // after the sign-in, so a late upsert can't recreate a row deleted below (RS-8).
            await social.settle()
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { throw Failure.backendSignInNeeded(social.error ?? tr("the signature was cancelled")) }
            await social.settle()
            // A Privy login's token, fetched fresh before anything is deleted: delete-account takes only one issued in
            // the last 15 minutes, and a failure here leaves everything as it was.
            let privyToken = try await session.privyAccessToken(fresh: true)
            if account.method == .emailPassword { notice = try await deleteEmailSignIn(social: social) }
            try await deleteServerRows(wallet: wallet, social: social)
            if let privyToken {
                do {
                    _ = try await social.client.invoke(function: "delete-account", bearer: privyToken)
                } catch SupabaseError.http(let code, let body) where code == 500 && body.contains("PRIVY_APP_SECRET") { // not localized: the server's words
                    notice = Failure.privyNotConfigured.localizedDescription
                } catch {
                    let method = account.method.title
                    notice = tr("Your DyorHQ data was deleted and this iPhone is signed out, but your \(method) sign-in account at Privy wasn't deleted (\(describe(error))). To finish, sign in with \(method) again and delete the account once more, or contact \(SupportLinks.supportEmail).")
                }
            }
            social.signOut()
        }

        env.perplTrading.forget(address: account.address)
        NotificationHub.shared.clear()
        // Before the erase: a venue list save after it would turn App Lock's default off for the next launch (R4).
        env.venueList.stop()
        // The wallet's history on disk, what was built from it, and whatever a round under way reads after this — what the
        // server's history added with it, and the day of its spot check and its distrust (`ServerHistorySync.forget`). The
        // history's rounds stop first: none starts after the erase, nor keeps the reference beside the scans, while the
        // sign-out below waits on Privy.
        env.history.start(env: env, wallet: nil)
        await env.walletHistory.forget(wallet: account.address)
        await env.serverHistory?.forget(wallet: account.address)
        await session.eraseLocalData()
        session.deletionNotice = notice
    }

    /// An Email & Password account's email sign-in at Privy (SB-7): its sign-up verified the email with a Privy one-time
    /// code, which created a Privy user, and the app keeps no Privy session to delete it with. delete-account deletes it
    /// by the email this wallet is bound to, authorised by the wallet's own backend session, so this runs before the
    /// binding is deleted. The server keeps the Privy user when it is also another way into DyorHQ. A failure of the
    /// request (the session, a limit, an outage) stops the deletion with nothing deleted. Two answers go on with it:
    /// no binding for this wallet (409) — the email was moved to another wallet (a reset, a sign-up elsewhere, Replace
    /// Wallet), whose Privy user this wallet must not delete, or a retry after the binding went — and a server without
    /// Privy deletion set up, which is reported afterwards like the Privy-login path (the returned notice). A
    /// delete-account from before this path (it reads every bearer as a Privy token and refuses it) can't do it at all,
    /// so it is skipped there, as before.
    @MainActor
    private static func deleteEmailSignIn(social: SocialSession) async throws -> String? {
        guard let token = await social.client.currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        do {
            _ = try await social.client.invoke(function: "delete-account", bearer: token, body: Data(#"{"method":"email-password"}"#.utf8))
        } catch SupabaseError.http(401, let body) where body.contains("invalid Privy access token") { // not localized: the server's words
            return nil // the delete-account from before this path
        } catch SupabaseError.http(409, let body) where serverError(body) == "no email binding" { // not localized: the server's words
            return nil
        } catch SupabaseError.http(500, let body) where body.contains("PRIVY_APP_SECRET") { // not localized: the server's words
            return Failure.privyNotConfigured.localizedDescription
        } catch SupabaseError.http(let code, let body) {
            // A reason the app knows reads in the app's language; any other as the server wrote it.
            throw Failure.emailSignInNotDeleted(serverError(body).map(EdgeFunctionError.deleteAccount) ?? tr("error \(String(code))"))
        }
        return nil
    }

    /// The `error` field of an Edge Function's JSON answer.
    private static func serverError(_ body: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
    }

    /// A passkey (Mera) account's deletion, which removes the passkey too (MERA-PLAN §8), in the order
    /// `Mera.AccountDeletion.run` fixes:
    ///
    /// 1. A forced pinned ceremony, even while a session is live (`MeraSession.stepUp`), that must derive `address` —
    ///    the one on screen. Its credential ID is kept in memory: the erase below clears `MeraCredentialStore`. The
    ///    session it opens signs the backend sign-in.
    /// 2. The server rows. A failure stops here with "Nothing on this phone was changed": no signal, no erase.
    /// 3. The signal to the passkey provider, for `Mera.relyingParty` and that credential ID.
    /// 4. This device, erased.
    ///
    /// Then the "Account deleted." screen, which RootView shows once the account is signed out (`Session.passkeyDeletion`).
    @MainActor
    static func deletePasskeyAccount(shown address: Address, session: Session, social: SocialSession, env: AppEnvironment) async throws {
        let outcome = try await Mera.AccountDeletion.run(
            account: address,
            confirm: {
                let approval = try await session.mera.stepUp(expecting: address)
                return Mera.AccountDeletion.Confirmation(credentialID: approval.credentialID, address: approval.address)
            },
            deleteServerData: {
                try await deletePasskeyServerRows(address: address, session: session, social: social)
            },
            signal: session.mera.signal,
            eraseLocalData: { await eraseThisDevice(address: address, session: session, social: social, env: env) })
        session.passkeyDeletion = Mera.AccountDeletion.Done(outcome: outcome)
    }

    /// This device's copy of an account, gone: the backend session closed, Perpl's token and socket dropped, the
    /// notification center cleared, the venue list's reading and the history's rounds stopped (nothing they save may
    /// follow the erase, R4), then `Session.eraseLocalData`. Nothing on the server is deleted and nothing is reported to
    /// the passkey provider. A passkey account's deletion does both first; "Forget This Device" (`ProfileView`) is only
    /// this, so the passkey keeps the account and "I already have a passkey" brings it back.
    @MainActor
    static func eraseThisDevice(address: Address, session: Session, social: SocialSession, env: AppEnvironment) async {
        social.signOut()
        env.perplTrading.forget(address: address)
        NotificationHub.shared.clear()
        env.venueList.stop()
        // The history's rounds stop before its store is erased: none starts after it, nor writes beside the scans. The
        // server's history's spot check and distrust for the wallet go with it.
        env.history.start(env: env, wallet: nil)
        await env.walletHistory.forget(wallet: address)
        await env.serverHistory?.forget(wallet: address)
        await session.eraseLocalData()
    }

    /// The server half for a passkey account. The backend sign-in, when one is needed, is signed prompt-free by the
    /// session the deletion's ceremony just opened (`Session.backgroundWallet`): never a second prompt. Profile work
    /// still running (a new account's background follow-up, a restore) is waited out first, so it can't recreate the
    /// profile row after it is deleted.
    @MainActor
    private static func deletePasskeyServerRows(address: Address, session: Session, social: SocialSession) async throws {
        let wallet = address.checksummed.lowercased()
        await social.settle()
        #if DEBUG && targetEnvironment(simulator)
        // Simulator test mode: a stub account never signs in to the backend (`SocialSession.startSignIn`), so it has no
        // rows there to delete. Skipped quietly, and the deletion goes on to the signal and the erase.
        if session.mera.isStub, !social.isSignedIn { return }
        #endif
        if !social.isSignedIn, let signer = session.backgroundWallet {
            await social.signIn(address: address, wallet: signer)
        }
        guard social.isSignedIn, await social.client.signedInWallet?.lowercased() == wallet else {
            throw Failure.backendSignInNeeded(social.error ?? tr("the passkey session ended before it could sign"))
        }
        await social.settle()
        try await deleteServerRows(wallet: wallet, social: social)
    }

    /// The wallet's server data, in this order, for every account type. The profile row goes last, so once it is gone
    /// every row is (RI-8): a failure before it leaves the profile, and a retry deletes the rest again (each delete of a
    /// row already gone is a no-op, and the email sign-in step reads the missing binding as nothing to delete).
    @MainActor
    private static func deleteServerRows(wallet: String, social: SocialSession) async throws {
        try await social.client.deleteObjects(bucket: "avatars", prefix: wallet)
        // The email → wallet binding has NO FK to profiles, so it doesn't cascade. Delete it explicitly: an
        // email+password wallet is deterministic, so leaving the binding would let the same credentials log back
        // in through the gate (email_account_matches) after "deletion". Owner-scoped DELETE (migration 17) only
        // touches this wallet's own row; other account types simply have no row here.
        try await social.client.delete("email_accounts", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
        // The profile row is the root: every other table references it with ON DELETE CASCADE.
        try await social.client.delete("profiles", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
    }
}

/// The confirmation sheet: what goes, what stays, the wallet-specific warning, and two deliberate steps
/// (an acknowledgement and typing DELETE) before the destructive button.
///
/// A passkey (Mera) account's version (MERA-PLAN §8) leads with its address and what could be lost, because deleting
/// removes the passkey — the wallet's only key. Its first actions are Export Recovery Phrase and Move Funds Out.
/// Deleting without having exported the phrase here always needs "I understand I may permanently lose these funds"
/// ticked, whatever the balances read. The button is "Delete with Face ID": a forced passkey prompt.
struct DeleteAccountView: View {
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var confirmation = ""
    @State private var deleting = false
    @State private var error: String?
    /// A passkey account's recovery phrase was shown and confirmed from this screen (`RecoveryPhraseView`).
    @State private var exported = false
    @State private var showSend = false

    private var method: Session.Method { session.account?.method ?? .watchOnly }
    private var isPrivy: Bool { [.apple, .google, .email, .passkey].contains(method) }
    private var isPasskey: Bool { method == .meraPasskey }
    private var typedDelete: Bool { confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" } // not localized: the word typed
    private var ready: Bool {
        guard typedDelete, !deleting else { return false }
        if isPasskey { return exported || acknowledged }
        return acknowledged || !session.canSign
    }

    var body: some View {
        NavigationStack {
            List {
                if isPasskey, let address = session.address { passkeySections(address) }

                Section {
                    Label("Your DyorHQ profile, posts, comments, follows and reactions", systemImage: "person.2")
                    Label("Alerts, watchlists and referral codes", systemImage: "bell.badge")
                    Label("Notification history and this device's push registration", systemImage: "iphone")
                    if isPrivy { Label("Your \(method.title) sign-in account at Privy, including its embedded wallet", systemImage: "key") }
                    if method == .emailPassword { Label("The Privy account that verified your email, unless it's also another way into DyorHQ", systemImage: "key") }
                    if isPasskey { Label("Your passkey: DyorHQ asks your passkey app to remove it", systemImage: "person.badge.key") }
                    Label("Every key, session and cache stored on this device", systemImage: "trash")
                } header: {
                    Text("What is deleted")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Paragraph("Transactions, tokens and Moments you created stay on the Monad blockchain — nothing can remove them — and images you published for coins or Moments stay online because those tokens point to them.")
                        LearnMoreLink(.exportSignOutDelete)
                    }
                }

                if method == .apple {
                    Section {
                        // Apple's fallback when the app can't revoke the Sign in with Apple token itself (TN3194); the
                        // steps are Apple's own (support.apple.com/102571).
                        Paragraph("Also stop using Sign in with Apple for DyorHQ: open Settings, tap your name, tap Sign in with Apple, select DyorHQ, then tap Delete.")
                    } header: {
                        Text("Sign in with Apple")
                    }
                }

                if session.canSign, !isPasskey {
                    Section {
                        switch method {
                        case .apple, .google, .email, .passkey:
                            Paragraph("Your embedded wallet is deleted together with the Privy account. Send your funds elsewhere or export the wallet's key first; afterwards nobody can recover it.")
                            NavigationLink { WalletExportView() } label: { Label("Export Wallet First", systemImage: "key.horizontal") }
                        case .imported:
                            Paragraph("This wallet's private key is removed from this device. Keep its recovery phrase or key somewhere safe; it is the only way back to the funds.")
                        case .emailPassword:
                            Paragraph("This wallet is recreated from your email and password. Removing it deletes the device copy; keep your email and password, the only way back to the funds. A password reset can't bring them back: it creates a new, empty wallet.")
                        case .meraPasskey, .watchOnly:
                            EmptyView()
                        }
                        Toggle("I understand only my own backup can recover my funds", isOn: $acknowledged)
                    } header: {
                        Text("Your wallet")
                    }
                }

                Section {
                    // The word typed is always DELETE, in every language (`typedDelete`).
                    TextField("Type DELETE to confirm", text: $confirmation,
                              prompt: Text("Type DELETE to confirm", comment: "Keep DELETE in English and in capitals: it is the word the user must type"))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button(role: .destructive) { Task { await deleteAccount() } } label: {
                        HStack {
                            Label(isPasskey ? "Delete with \(BiometricGate.promptName)" : "Delete Account", systemImage: isPasskey ? BiometricGate.promptSymbol : "person.crop.circle.badge.xmark")
                            Spacer()
                            if deleting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!ready)
                } footer: {
                    if let error { Paragraph(error).foregroundStyle(Color.attention) }
                    else if isPasskey { Paragraph("\(BiometricGate.promptName) confirms it's your passkey, even if your session is open. Your data on the server is deleted first; only then is the passkey removed and this phone cleared. This cannot be undone.") }
                    else { Paragraph(session.canSign ? "The server asks your wallet for one signature to prove it is you, then deletes everything. This cannot be undone." : "Removes everything about this watched address from this device.") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Delete Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
            .sheet(isPresented: $showSend) { SendSheet() }
        }
    }

    /// A passkey account: the address, the warning, the two ways to keep the funds, and what could be lost.
    @ViewBuilder private func passkeySections(_ address: Address) -> some View {
        Section {
            Text(address.checksummed)
                .speechSpellsOutCharacters()
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding(.vertical, 2)
            Paragraph("Deleting removes your passkey, which is this wallet's only key. Assume this is permanent unless you export the recovery phrase first.")
                .font(.subheadline)
        } header: {
            Text("Your wallet")
        }

        Section {
            NavigationLink {
                RecoveryPhraseView(onConfirmed: { exported = true })
            } label: {
                Label(exported ? "Recovery Phrase Exported" : "Export Recovery Phrase", systemImage: exported ? "checkmark.seal.fill" : "key.horizontal")
                    .fontWeight(.semibold)
                    .foregroundStyle(exported ? Color.positive : Color.brand)
            }
            Button { showSend = true } label: {
                Label("Move Funds Out", systemImage: "arrow.up.right")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brand)
            }
        } footer: {
            Paragraph("The recovery phrase restores this wallet in any other wallet app. Or send what it holds to a wallet you keep.")
        }
        .disabled(deleting)

        Section {
            Label("MON and tokens in this wallet", systemImage: "dollarsign.circle")
            Label("Perpl collateral and open positions", systemImage: "chart.line.uptrend.xyaxis")
            Label("NFTs and Moments", systemImage: "photo.on.rectangle")
            Label("Launchpad creator fees and holder rewards", systemImage: "flame")
            Label("Moments vesting and creator proceeds", systemImage: "hourglass")
            Label("Funds at this same address on other EVM chains (Bridge)", systemImage: "point.3.connected.trianglepath.dotted")
            if exported {
                Label("You exported and confirmed the recovery phrase.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.positive)
            } else {
                Toggle("I understand I may permanently lose these funds", isOn: $acknowledged)
            }
        } header: {
            Text("What could be lost")
        } footer: {
            Paragraph("All of it stays at \(address.short) on the blockchain, but without the passkey or the recovery phrase nothing can move it.")
        }
    }

    private func deleteAccount() async {
        // Deleting destroys a Privy embedded wallet or the only copy of an imported key, so with App Lock on it asks
        // for the device owner first, like key export (audit F5). A passkey account's own ceremony already asks.
        if !isPasskey, session.canSign, settings.appLockApplies(to: session.account),
           !(await BiometricGate.authenticate(reason: "Delete your DyorHQ account")) { return }
        deleting = true
        error = nil
        // A Moment link waits until the deletion ends: delivering one closes Profile, and this screen with it.
        await router.holdingLinks {
            do {
                if isPasskey, let address = session.address {
                    try await AccountDeletion.deletePasskeyAccount(shown: address, session: session, social: social, env: env)
                } else {
                    try await AccountDeletion.run(session: session, social: social, env: env)
                }
                dismiss()
            } catch where isUserCancellation(error) {
                // The passkey prompt was closed: nothing was deleted, and the form stays as it was.
            } catch {
                self.error = describe(error)
            }
        }
        deleting = false
    }
}

/// Shown in place of onboarding (RootView) after a deletion that finished on this device but left something to do
/// (`Session.deletionNotice`, RI-8): the Privy account that couldn't be deleted, and how to finish.
struct DeletionNoticeView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Color.attention)
                            .accessibilityHidden(true)
                        Text("Account deleted, one step left")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Paragraph(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section {
                    PrimaryButton(title: "Done", systemImage: "checkmark") { onClose() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Delete Account"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The screen a passkey account's deletion ends on (MERA-PLAN §8), in place of onboarding (RootView) until closed:
/// the account is gone, and what may be left of the passkey. Apple doesn't confirm what the provider did with the
/// signal, so the manual steps are always there; on iOS 18, which has no signal, they are the one step left.
struct AccountDeletedView: View {
    let done: Mera.AccountDeletion.Done
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Color.positive)
                        Text(done.title)
                            .font(.title2.weight(.bold))
                        if let note = done.recentlyDeleted {
                            Paragraph(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section {
                    if done.passkeyRemains {
                        Label(done.stepsHeading, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.attention)
                    }
                    ForEach(Array(done.steps.enumerated()), id: \.offset) { index, step in
                        Label { Text(step) } icon: { Image(systemName: "\(index + 1).circle") }
                    }
                } header: {
                    if !done.passkeyRemains { Text(done.stepsHeading) }
                }

                Section {
                    PrimaryButton(title: "Done", systemImage: "checkmark") { onClose() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Delete Account"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
