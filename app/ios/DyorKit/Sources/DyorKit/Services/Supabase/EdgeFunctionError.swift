import Foundation

/// The refusals of DyorHQ's Edge Functions that the app knows, in the app's language. The functions answer with an
/// English `error` text and no code yet (codes come with a separate, owner-approved deploy), so the app matches their
/// known English words here, whatever the app's language, and says them in its own; a text it doesn't know is shown as
/// the server wrote it. In English the app's words are the ones the screens showed before.
public enum EdgeFunctionError {
    /// `email-rebind`'s refusal as a sentence of its own, as the email sign-up, reset and upgrade show it: a known one in
    /// the app's language, any other with a capital and a full stop.
    public static func emailRebind(_ error: String) -> String {
        switch error {
        // not localized: the matched texts are the function's own English words
        case "missing Privy access token": return L10n.tr("Missing Privy access token.")
        case "invalid Privy access token": return L10n.tr("Invalid Privy access token.")
        case "this reset expired — start again": return L10n.tr("This reset expired — start again.")
        case "invalid wallet signature": return L10n.tr("Invalid wallet signature.")
        case "wallet signature did not match": return L10n.tr("Wallet signature did not match.")
        case "too many attempts — try again in a few minutes": return L10n.tr("Too many attempts — try again in a few minutes.")
        case "no verified email on this Privy account": return L10n.tr("No verified email on this Privy account.")
        case "the code you entered was for a different email": return L10n.tr("The code you entered was for a different email.")
        default:
            let capped = error.prefix(1).uppercased() + error.dropFirst()
            return capped.hasSuffix(".") ? capped : capped + "."
        }
    }

    /// `delete-account`'s refusal as the reason inside a sentence ("… didn't work (too many attempts — …)"): a known one
    /// in the app's language, any other as the server wrote it.
    public static func deleteAccount(_ error: String) -> String {
        switch error {
        // not localized: the matched texts are the function's own English words
        case "too many attempts — try again in a few minutes": return L10n.tr("too many attempts — try again in a few minutes")
        case "account deletion is unavailable right now — try again in a minute": return L10n.tr("account deletion is unavailable right now — try again in a minute")
        case "account deletion failed — contact support": return L10n.tr("account deletion failed — contact support")
        case "missing access token": return L10n.tr("missing access token")
        case "server not configured": return L10n.tr("server not configured")
        case "sign in again to delete your account": return L10n.tr("sign in again to delete your account")
        case "a signed-in wallet session is required": return L10n.tr("a signed-in wallet session is required")
        default: return error
        }
    }
}
