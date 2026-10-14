import BigInt
import Foundation

/// A send of MON or an ERC-20 to another address: the transaction, and whether the chain would take it.
///
/// No token the DyorHQ contracts create restricts transfers: a launchpad coin (`LaunchToken`) moves before and after
/// graduation, its holder fee-sharing hook only books rewards, and a Moment coin is a plain capped ERC-20 that exists
/// only once minted. Any other token can refuse (paused, blocklisted, fee rules), so a send is simulated before the
/// review offers Send (`refusal`), and again before it is signed (`TransactionSender.prepare`).
public enum TokenTransfer {
    /// MON as the transaction's value; an ERC-20 as `transfer(to, amount)` on the token.
    public static func request(_ token: Token, to: Address, amount: BigUInt) throws -> TransactionRequest {
        if token.isNative { return TransactionRequest(to: to, value: amount) }
        return TransactionRequest(to: token.address, data: try ERC20.transferCalldata(to: to, amount: amount))
    }

    /// Why sending `amount` of `token` from `owner` to `to` would fail, asked of the chain with an `eth_call` at the
    /// latest block, or nil when it would go through. Only a definite answer refuses: a revert, or an ERC-20 whose
    /// `transfer` returns false (it moves nothing, yet the transaction succeeds). A call that couldn't be made says
    /// nothing here; the simulation before signing still runs.
    public static func refusal(_ token: Token, to: Address, amount: BigUInt, from owner: Address, rpc: RPCClient) async -> String? {
        guard let request = try? request(token, to: to, amount: amount) else { return L10n.tr("This transfer can't be built.") }
        let returned: Data
        do {
            returned = try await rpc.ethCall(CallRequest(from: owner, to: request.to, data: request.data, value: request.value))
        } catch let error as RPCError {
            guard isRevert(error) else { return nil }
            return wouldFail(RevertReason.describe(error))
        } catch {
            return nil
        }
        if !token.isNative, returned.count == 32, BigUInt(returned) == 0 {
            return L10n.tr("The \(token.symbol) contract refused this transfer, so nothing would be sent.")
        }
        return nil
    }

    /// "This send would fail: <reason>". The reason may be a sentence in the app's language or a contract's own words, so
    /// it keeps the mark it ends with when that ends a sentence in any script ("." "!" "?" "。" "！" "？"); a full stop is
    /// added only when it doesn't end one.
    static func wouldFail(_ reason: String) -> String {
        endsASentence(reason) ? L10n.tr("This send would fail: \(reason)") : L10n.tr("This send would fail: \(reason).")
    }

    /// Whether `text` ends with a mark that ends a sentence (Unicode's Sentence_Terminal), whatever its script.
    static func endsASentence(_ text: String) -> Bool {
        text.last?.unicodeScalars.first?.properties.isSentenceTerminal ?? false
    }

    /// A node's answer that the call itself fails (a revert, or not enough MON for it), as opposed to a failed request.
    static func isRevert(_ error: RPCError) -> Bool {
        // not localized: the nodes' own English, matched as they send it
        error.code == 3 || error.message.localizedCaseInsensitiveContains("revert")
            || error.message.localizedCaseInsensitiveContains("insufficient funds")
    }
}
