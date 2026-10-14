import DyorKit
import Foundation

/// Build-time configuration, injected through Secrets.xcconfig → Info.plist. Missing values degrade features
/// (sign-in methods) instead of crashing, and the UI says what is missing; on-chain addresses have baked defaults.
struct AppConfig: Sendable {
    let privyAppID: String
    let privyClientID: String
    /// Monad RPC endpoints in failover order: the keyless public endpoints (`Monad.publicRPCs`). A Debug build may point
    /// at one override (a local fork); a Release build never reads an override, so no keyed provider URL can ship.
    let rpcURLs: [URL]
    /// The primary endpoint (Settings display, Privy's embedded-wallet chain).
    var rpcURL: URL { rpcURLs[0] }
    /// Apple / Google sign-in through Privy. Off unless `SocialLoginsEnabled=YES` in Secrets.xcconfig; the methods must
    /// also be enabled in the Privy dashboard. When off, onboarding hides them so no one taps a disallowed method.
    let enableSocialLogins: Bool
    /// Mera passkey accounts next to the other sign-in methods. Off unless `PasskeysEnabled=YES` in Secrets.xcconfig —
    /// passkeys need Associated Domains on the App ID and the AASA served at `Mera.relyingParty` (owner steps), none
    /// live yet, so the UI hides passkey options until then rather than offering a flow that can't complete.
    let enablePasskeys: Bool
    let perplBuilderID: Int
    /// The live launchpad: the v2 stack baked into DyorKit (`LaunchpadAddresses.monadMainnet`). The retired stacks come
    /// from DyorKit whatever this is.
    let launchpad: LaunchpadAddresses
    /// The live Moments cohort: v2, baked into DyorKit (`MomentsAddresses.monadMainnet`). The retired cohorts 1–3 are
    /// claim-only and come from DyorKit whatever this is.
    let moments: MomentsAddresses
    /// DyorHQ's Supabase backend (social, alerts, launch index). The publishable key is safe to
    /// embed — row-level security protects the data — so these have working defaults.
    let supabaseURL: URL
    let supabaseKey: String
    /// Privy-hosted key-export page (Privy React SDK) loaded in a WebView to export an embedded wallet's key — the
    /// only supported path, since Privy's iOS SDK has no native export. Its origin must be a Privy allowed origin.
    let walletExportURL: URL?
    /// Optional NEAR account to receive the Bridge's integrator fee. The Aurora API key itself is NOT in the app: it
    /// lives server-side in the `aurora-proxy` Edge Function (Supabase secret AURORA_API_KEY).
    let auroraFeeRecipient: String?

    var hasPrivy: Bool { !privyAppID.isEmpty && !privyClientID.isEmpty }
    var hasBridge: Bool { hasSupabase }
    /// Mera passkey accounts, one sign-in method among the others. The rpId is the constant `Mera.relyingParty`, so
    /// only the flag decides.
    var hasMera: Bool { enablePasskeys }
    /// Privy passkeys (`createPasskey`, `signInWithPasskey`, Settings' "Add a Passkey") would register under the same
    /// rpId as Mera accounts, so they are off whenever Mera is on — and since both need `PasskeysEnabled`, in every build.
    var hasPasskeys: Bool { hasPrivy && enablePasskeys && !hasMera }
    var hasSupabase: Bool { !supabaseKey.isEmpty }

    static let current: AppConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        func string(_ key: String) -> String {
            let raw = (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Unset xcconfig variables come through as empty or as the literal "$(NAME)".
            return raw.hasPrefix("$(") ? "" : raw
        }
        func bool(_ key: String) -> Bool { ["yes", "true", "1"].contains(string(key).lowercased()) }
        func address(_ key: String) -> Address { Address(string(key)) ?? .zero }
        #if DEBUG
        // Development only (e.g. an anvil fork at 127.0.0.1). project.yml empties MonadRPCURL for Release as well.
        let rpcOverride = URL(string: string("MonadRPCURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        // A fork rehearsal's v2 deployment (Secrets.xcconfig LAUNCHPAD_* / MOMENTS_*). Debug only, like the RPC override:
        // project.yml empties these keys for Release, and a Release build never reads them, so no shipped build can be
        // pointed at other contracts.
        let launchpadOverride: LaunchpadAddresses? = string("LaunchpadFactory").isEmpty ? nil : LaunchpadAddresses(
            factory: address("LaunchpadFactory"),
            router: address("LaunchRouter"),
            escrow: address("FeeEscrow"),
            holderFeeSharing: address("HolderFeeSharing"),
            hook: address("MemeHook"),
            poolManager: Uniswap.poolManager,
            generation: .v2
        )
        let momentsOverride: MomentsAddresses? = string("MomentsFactory").isEmpty ? nil : MomentsAddresses(
            factory: address("MomentsFactory"),
            collect: address("MomentsCollect"),
            vesting: address("MomentsVesting"),
            graduation: address("MomentsGraduation"),
            locker: address("MomentsLocker"),
            hook: address("MomentsHook"),
            buyback: address("MomentsBuyback"),
            platform: address("MomentsPlatform"),
            treasury: address("MomentsTreasury"),
            deployBlock: UInt64(string("MomentsDeployBlock")) ?? 0,
            generation: .v2
        )
        #else
        let rpcOverride: URL? = nil
        let launchpadOverride: LaunchpadAddresses? = nil
        let momentsOverride: MomentsAddresses? = nil
        #endif
        let rpcURLs = rpcOverride.map { [$0] } ?? Monad.publicRPCs
        let supabaseURL = URL(string: string("SupabaseURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!
        let supabaseKey = { let key = string("SupabaseKey"); return key.isEmpty ? "sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT" : key }()
        return AppConfig(
            privyAppID: string("PrivyAppID"),
            privyClientID: string("PrivyClientID"),
            rpcURLs: rpcURLs,
            enableSocialLogins: bool("SocialLoginsEnabled"),
            enablePasskeys: bool("PasskeysEnabled"),
            perplBuilderID: Int(string("PerplBuilderID")) ?? 0,
            // The audited v2 stacks are baked into DyorKit (checked against contracts/deployments/143.json and
            // moments-143.json by its tests). In a Debug build, LAUNCHPAD_FACTORY / MOMENTS_FACTORY in Secrets.xcconfig
            // point it at another v2 deployment (a fork rehearsal), and then every module address comes from the xcconfig.
            launchpad: launchpadOverride ?? .monadMainnet,
            moments: momentsOverride ?? .monadMainnet,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            walletExportURL: URL(string: string("WalletExportURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil },
            auroraFeeRecipient: { let r = string("AuroraFeeRecipient"); return r.isEmpty ? nil : r }()
        )
    }()
}
