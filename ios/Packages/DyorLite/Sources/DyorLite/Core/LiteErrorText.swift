import Foundation
import StellarKit

/// Every error as a person reads it, in the current language (docs/DESIGN-stellar-parity.md §6.13, §4.6): the API's
/// codes and the contracts' refusals, with the facts they carry (`LiteAPIError.detail`); the phone's own checks before
/// it signs and Stellar's result for a step it sent (`PlanRunner.Failure`); the connection; the session's failures. The
/// server's own message is shown only for a transaction Stellar rejected for a reason the app has no words for, and for
/// codes this build doesn't know.
public enum LiteErrorText {
    public static func describe(_ error: Error) -> String {
        switch error {
        case let api as LiteAPIError: return describe(api)
        case let runner as PlanRunner.Failure: return describe(runner)
        // A Privy account's wallet: a signature that doesn't verify for the account (never attached), Privy's own
        // refusals and outages, a wallet only the user doesn't control.
        case is StellarSigningError: return privySigningFailed
        case let privy as PrivyAPIError: return describe(privy)
        case PrivyWalletCheck.Failure.listNotFresh:
            return tr("Stellar isn't available for this sign-in right now. Try again later.")
        case is PrivyWalletCheck.Failure:
            return tr("Privy didn't confirm this Stellar wallet as yours, so DyorHQ won't use it. Nothing was signed.")
        default: return LiteSession.failure(for: error).errorDescription ?? error.localizedDescription
        }
    }

    /// `describe(_:)` for what `action`'s run threw, with what the review knew about it: a step the network failed for
    /// want of funds (`op_underfunded`) names the asset the action spends ("Not enough XLM.").
    public static func describe(_ error: Error, for action: PreparedAction) -> String {
        if case let .failedOnChain(_, _, code?)? = error as? PlanRunner.Failure, code == "op_underfunded",
           action.spends.count == 1, let spent = action.spends.first {
            return spent == "XLM" ? tr("Not enough XLM.") : tr("Not enough \(spent).")
        }
        return describe(error)
    }

    private static func describe(_ error: LiteAPIError) -> String {
        switch error {
        case .transport: return tr("No connection. Check your network and try again.")
        case .notSignedIn: return tr("Sign in on Stellar to continue.")
        case .decoding(let what) where what.hasPrefix("the sign-in"):
            return tr("The sign-in didn't pass this iPhone's checks. Nothing was signed.")
        case .decoding: return tr("DyorHQ on Stellar sent an answer this version can't read. Try again, or update DyorHQ.")
        case let .server(_, code, message, detail): return describe(code: code, message: message, detail: detail ?? [:])
        }
    }

    /// The API's codes (§6.13), the contracts' stable codes included.
    static func describe(code: String, message: String, detail: [String: String]) -> String {
        switch code {
        case "not_enough_xlm_for_fee": return notEnoughForFee
        case "not_enough_xlm_for_reserve": return notEnoughForReserve
        case "not_enough_xlm": return notEnoughXLM(detail)
        case "fee_too_high": return feeTooHigh(detail["fee"])
        case "tx_rejected":
            // Stellar's own result code: the fee and reserve ones have words of their own; any other is the server's.
            return detail["code"].flatMap(resultCode) ?? message
        case "sponsor_limit": return tr("DyorHQ's free setup is busy today. Try again tomorrow.")
        case "already_set_up": return tr("Your account is already set up.")
        case "unsupported_asset": return tr("DyorHQ doesn't support that token on Stellar.")
        case "bad_symbol": return tr("Use 2 to 10 letters or digits for the symbol.")
        case "look_alike_symbol": return tr("That ticker looks like another token's. Choose another.")
        case "faucet_used": return tr("You already claimed your test XLM.")
        case "muxed_unsupported": return tr("Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given.")
        case "recipient_missing":
            guard let code = assetCode(detail) else { return tr("This account doesn't exist yet, so it can't receive this token.") }
            return tr("This account doesn't exist yet, so it can't receive \(code).")
        case "recipient_no_trust":
            guard let code = assetCode(detail) else { return tr("This account hasn't enabled this token, so it can't receive it.") }
            return tr("This account hasn't enabled \(code), so it can't receive it.")
        case "launch.slippage": return tr("The price moved past your 1% limit. Nothing was sent. Review again for a new price.")
        case "launch.closed": return tr("This curve isn't taking trades now.")
        case "launch.disabled": return tr("New launches are paused.")
        case "launch.nothing_to_claim": return tr("Nothing to claim yet.")
        case "moment.closed": return tr("This Moment's collect window has closed.")
        case "moment.sold_out": return tr("This Moment is sold out.")
        case "moment.price_too_low":
            guard let price = units(detail["minPrice"]), let quote = detail["quoteCode"] else { return tr("The price is below the Moment's minimum.") }
            return tr("The price is below the minimum (\("\(price) \(quote)")).")
        case "trust.missing":
            guard let code = assetCode(detail) else { return tr("Enable this token first.") }
            return tr("Enable \(code) first.")
        case "upload_budget": return tr("You've uploaded a lot today. Try again tomorrow.")
        case "bridge_relay_limit": return tr("You've bridged in many times today. Try again tomorrow.")
        case "access_revoked": return LiteSession.Failure.accessRevoked.errorDescription ?? message
        case "rate_limited": return LiteSession.Failure.rateLimited.errorDescription ?? message
        case "bad_invite": return LiteSession.Failure.inviteRejected.errorDescription ?? message
        case "not_invited": return tr("Enter your invite code to continue.")
        case "unauthorized", "refresh_invalid", "refresh_reused": return tr("Sign in on Stellar to continue.")
        default: return message
        }
    }

    private static func describe(_ failure: PlanRunner.Failure) -> String {
        switch failure {
        case let .refused(_, reason) where capRefusals.contains(reason): return feeTooHigh(nil)
        case let .refused(step, reason): return tr("Not signed: \(step) didn't pass the checks (\(reason)). Nothing was sent.")
        case .overLimit: return tr("Not signed: this would spend more than you confirmed. Nothing was sent.")
        case let .feeAboveConfirmed(step): return tr("Not signed: the network fee for \(step) went up since you confirmed. Nothing was sent.")
        // Stellar's result code once it applied the transaction (Horizon's names, WP-10's `TxStatus.error`): an operation's
        // code exists only then.
        case let .failedOnChain(step, _, code?): return resultCode(code) ?? tr("\(step) failed on the network (\(code)).")
        case let .failedOnChain(step, _, nil): return tr("\(step) failed on the network.")
        case let .timedOut(step, _): return tr("\(step) was sent; confirmation not seen yet.")
        }
    }

    /// Stellar's result codes that have words of their own (§4.6, §6.13), whether the network refused the transaction as
    /// it was sent (`tx_rejected`'s `detail.code`) or failed it as it applied it: not enough XLM for the fee or for the
    /// minimum balance, or not enough of what was sent (which asset, only the run knows: `describe(_:for:)`). Nil for any
    /// other.
    private static func resultCode(_ code: String) -> String? {
        switch code {
        case "tx_insufficient_balance", "tx_insufficient_fee": return notEnoughForFee
        case "op_low_reserve", "CHANGE_TRUST_LOW_RESERVE": return notEnoughForReserve
        case "op_underfunded": return tr("Not enough funds for this.")
        default: return nil
        }
    }

    /// The reasons StellarKit refuses a fee above the pinned caps with (`TxVerifier`, `PlanFees`, §4.4): §4.6 words a cap
    /// refusal as a fee that is unusually high right now. StellarKit says them only in its own English and with no fee,
    /// so they are matched here until it has a failure of their own (a test runs PlanFees over the cap to keep them in step).
    static let capRefusals: Set<String> = ["The network fee is above the limit.", "The inclusion fee is above the limit.",
                                           "The sponsored step's network fee is above the limit."]

    /// "Not signed: the network fee is unusually high right now (3.1 XLM)…", with the fee when it is known.
    private static func feeTooHigh(_ stroops: String?) -> String {
        guard let fee = xlm(stroops) else { return tr("Not signed: the network fee is unusually high right now. Nothing was sent. Try again in a minute.") }
        return tr("Not signed: the network fee is unusually high right now (\(fee) XLM). Nothing was sent. Try again in a minute.")
    }

    private static var notEnoughForFee: String { tr("Not enough XLM for the network fee.") }
    private static var privySigningFailed: String { tr("Couldn't sign with your Privy wallet. Nothing was sent.") }

    /// Privy's client API, as a Privy account meets it: an expired Privy session needs a sign-in to DyorHQ again; an
    /// outage, a refusal or an answer this build can't read means no signature.
    private static func describe(_ privy: PrivyAPIError) -> String {
        switch privy {
        case .transport: return tr("No connection. Check your network and try again.")
        case .refused(401, _): return tr("Sign in to DyorHQ again to use Stellar.")
        case .unavailable: return tr("Stellar isn't available for this sign-in right now. Try again later.")
        case .refused, .decoding: return privySigningFailed
        }
    }
    private static var notEnoughForReserve: String { tr("Not enough XLM for Stellar's minimum balance.") }

    /// "Not enough XLM. 1.5 XLM stays in your account." when the refusal says what stays.
    private static func notEnoughXLM(_ detail: [String: String]) -> String {
        guard let stays = xlm(detail["minBalance"]) else { return tr("Not enough XLM.") }
        return tr("Not enough XLM. \(stays) XLM stays in your account.")
    }

    /// The asset a refusal names, by its code (never translated), else by its id (a contract shortened); nil when the
    /// server named none, and the copy then says "this token".
    private static func assetCode(_ detail: [String: String]) -> String? {
        if let code = LiteFormat.name(detail["assetCode"]) { return code }
        return LiteFormat.name(detail["asset"]).map { StrKey.isValid(.contract, $0) ? LiteFormat.short($0) : $0 }
    }

    /// Stroops as XLM, in the current language's digits ("1.5", "0.0154").
    static func xlm(_ stroops: String?) -> String? { units(stroops) }

    /// Base units of a 7-decimal Stellar asset, written out in the current language's digits, all 7 decimals kept.
    static func units(_ text: String?) -> String? {
        guard let text, let value = Int64(text), value >= 0 else { return nil }
        return LiteFormat.units(value)
    }
}

/// Amounts as the package words them in its own text: base units of a 7-decimal Stellar asset, in the current
/// language's digits (`LiteL10n.locale`), no decimal lost.
enum LiteFormat {
    /// What servers before the parity API answered for a coin they couldn't name (§9): never a name the phone shows.
    static let standIns: Set<String> = ["TOKEN", "Token"]

    /// A name worth showing: not empty, and not a stand-in.
    static func name(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !standIns.contains(text) else { return nil }
        return text
    }

    /// A server's sentence worth showing as it is: not empty, and no word of it a stand-in ("Buy TOKEN with 2 XLM" isn't).
    static func sentence(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let marks = CharacterSet.punctuationCharacters.union(.symbols)
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: marks) }
        return words.contains(where: standIns.contains) ? nil : text
    }

    static func units(_ value: Int64, decimals: Int = 7) -> String {
        let amount = Decimal(value) / pow(Decimal(10), decimals)
        return amount.formatted(.number.precision(.fractionLength(0...decimals)).locale(LiteL10n.locale))
    }

    /// "GABC…WXYZ": an address or contract's first and last four characters.
    static func short(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(4))…\(address.suffix(4))" : address
    }
}
