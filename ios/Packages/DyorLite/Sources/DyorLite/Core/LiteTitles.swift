import Foundation
import StellarKit

/// Words the phone builds itself, in the current language, from what a transaction or a transfer is — never the
/// server's English: the review sheet's step headlines and Activity's rows say the same title for the same thing. In the
/// server's own imperative style ("Swap 10 XLM for USDC", "Enable USDC"); a row's status word says whether it happened.
/// Also the names rows give assets and swap venues.
///
/// Nil when the kind is unknown or a field it needs is missing: the caller then shows the server's words, as before.
enum LiteTitles {
    // MARK: Transactions

    /// A transaction's title from its intent's kind and display fields (backend _shared: account.ts, swap.ts, earn.ts,
    /// launchpad.ts, moments.ts, bridge.ts). The units are the server's: a payment's amount is written out
    /// (account.ts, fromStroops); every other amount is in base units of a 7-decimal Stellar asset. Amounts read as
    /// holdings write them, with at most 4 decimals.
    static func intent(kind: String, display: [String: StellarJSON]?) -> String? {
        let d = display ?? [:]
        switch kind {
        case "activate":
            return tr("Create your Stellar account")
        case "trust":
            guard let asset = text(d["asset"]) else { return nil }
            return tr("Enable \(asset)")
        case "payment":
            guard let amount = written(d["amount"]), let asset = text(d["asset"]) else { return nil }
            return tr("Send \(amount) \(asset)")
        case "swap":
            guard let amount = units(d["amountIn"]), let sell = text(d["sell"]), let buy = text(d["buy"]) else { return nil }
            return tr("Swap \(amount) \(sell) for \(buy)")
        case "earn_deposit":
            guard let amount = units(d["amount"]), let asset = text(d["asset"]) else { return nil }
            return tr("Deposit \(amount) \(asset) to earn")
        case "earn_withdraw":
            guard let amount = units(d["amount"]), let asset = text(d["asset"]) else { return nil }
            return tr("Withdraw \(amount) \(asset) from Earn")
        case "launch_create":
            guard let symbol = text(d["symbol"]) else { return nil }
            if let amount = units(d["initialBuy"], positive: true), let quote = text(d["quote"]) {
                return tr("Launch \(symbol) and buy with \(amount) \(quote)")
            }
            return tr("Launch \(symbol)")
        case "launch_buy":
            guard let symbol = text(d["symbol"]), let amount = units(d["amount"]), let quote = text(d["quote"]) else { return nil }
            return tr("Buy \(symbol) with \(amount) \(quote)")
        case "launch_sell":
            guard let amount = units(d["amount"]), let symbol = text(d["symbol"]) else { return nil }
            return tr("Sell \(amount) \(symbol)")
        case "launch_graduate":
            return tr("Move this launch to Soroswap")
        case "launch_claim":
            return tr("Claim your creator fees")
        case "moment_publish":
            guard let price = units(d["price"]), let quote = text(d["quote"]) else { return nil }
            return tr("Publish a Moment at \(price) \(quote)")
        case "moment_collect":
            guard let quantity = count(d["quantity"]), let total = units(d["total"]), let quote = text(d["quote"]) else { return nil }
            return tr("Collect \(editions(quantity)) for \(total) \(quote)")
        case "approve":
            // Only Circle's bridge asks for an allowance, and it moves USDC alone (bridge.ts, token_approve).
            guard text(d["spender"]) == "Circle CCTP", let amount = units(d["amount"]) else { return nil }
            return tr("Allow Circle's bridge to move \(amount) USDC")
        case "bridge_out":
            guard let amount = units(d["amount"]) else { return nil }
            return tr("Send \(amount) USDC to Monad")
        case "faucet":
            // Friendbot's one grant of test XLM (decision 7): the faucet's row, and since then the testnet account's
            // activation by Friendbot, which is logged as that row.
            return tr("Funded with Friendbot")
        default:
            return nil
        }
    }

    /// "3 editions", in the current language's plural.
    static func editions(_ count: Int) -> String { tr("\(count) editions") }

    // MARK: Settled actions

    /// A settled action's notification (§8.15), past tense, in the current language: its title, and its body without
    /// the network (the host adds " · Stellar testnet"). `results` are the plan's transactions, the last one the action's
    /// own (what a swap brought).
    static func settled(_ summary: LiteActionSummary, results: [TxStatus]) -> (title: String, body: String) {
        switch summary {
        case let .swap(amountIn, sell, buy, quotedOut):
            let out = results.last?.result?.amountOut.flatMap { Int64($0) } ?? quotedOut
            return (tr("Swap complete"), tr("Swapped \("\(amount(amountIn)) \(sell)") → \("\(amount(out)) \(buy)")"))
        case let .earn(deposit, value, code):
            return (deposit ? tr("Supplied to Earn") : tr("Withdrawn to Spot"), tr("\(amount(value)) \(code) · Blend"))
        case let .send(value, code, to):
            return (tr("Sent"), tr("\(amount(value)) \(code) to \(LiteFormat.short(to))"))
        case let .enable(code):
            return (tr("Enabled \(code)"), "")
        case let .launchCreate(symbol, name):
            return (tr("Launched $\(symbol)"), name)
        case let .launchTrade(buy, symbol, value, quoteCode):
            return buy ? (tr("Bought \(symbol)"), "\(amount(value)) \(quoteCode)") : (tr("Sold \(symbol)"), "\(amount(value)) \(symbol)")
        case let .launchGraduate(symbol):
            return (tr("\(symbol) graduated"), "Soroswap")
        case let .launchClaim(symbol):
            return (tr("Collected \(symbol) creator fees"), "")
        case let .publish(title):
            return (tr("Published \(title)"), "")
        case let .collect(title, quantity, total, quoteCode):
            return (tr("Collected \(title)"), tr("\(quantity) editions · \("\(amount(total)) \(quoteCode)")"))
        case let .bridgeOut(value):
            return (tr("Sent \(amount(value)) USDC to the bridge"), tr("Claim it on Monad once Circle confirms."))
        case let .launchV2(_, title, body):
            return (title, body)
        }
    }

    /// An amount in base units of a 7-decimal Stellar asset, as holdings write it (at most 4 decimals).
    private static func amount(_ units: Int64) -> String {
        StellarAmount.format(units, maxFraction: 4)
    }

    // MARK: Activity

    /// An Activity row's title: a transaction by its intent; a bridge transfer by its direction (its amount is in base
    /// units of the sending side's USDC: 6 decimals on Monad, 7 on Stellar); a cash transfer from before cash was removed
    /// until mainnet (decision 7) by the neutral "Transaction".
    static func activity(_ item: StellarActivityItem) -> String? {
        switch item.type {
        case "tx":
            return intent(kind: item.kind, display: item.display)
        case "bridge":
            let fromMonad = item.kind == "monad_to_stellar"
            let amount = units(item.amount.map(StellarJSON.string), decimals: fromMonad ? 6 : 7, positive: true)
            switch item.kind {
            case "monad_to_stellar": return amount.map { tr("Move \($0) USDC from Monad") } ?? tr("Move USDC from Monad")
            case "stellar_to_monad": return amount.map { tr("Send \($0) USDC to Monad") } ?? tr("Send USDC to Monad")
            default: return nil
            }
        case "cash":
            return tr("Transaction")
        default:
            return nil
        }
    }

    // MARK: Names

    /// The name a row gives an asset, by its registry id: the proper names of Stellar's own coin and of Circle's dollar,
    /// never translated; Blend's own test dollar in words; and the server's name for anything else (a launch's coin).
    /// Never the server's note.
    static func assetName(id: String, name: String) -> String {
        switch id {
        case "XLM": "Stellar Lumens"
        case "USDC": "USD Coin"
        case "BUSDC": tr("Blend test USDC")
        default: name
        }
    }

    /// A swap venue's name: proper names, never translated.
    static func venue(_ id: String) -> String {
        switch id.lowercased() {
        case "sdex": "Stellar DEX"
        case "aquarius": "Aquarius"
        case "soroswap": "Soroswap"
        case "phoenix": "Phoenix"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    // MARK: Reading display fields

    private static func text(_ value: StellarJSON?) -> String? {
        switch value {
        case .string(let text)?: text.isEmpty ? nil : text
        case .number?: value?.text
        default: nil
        }
    }

    /// An amount in base units, as holdings write it.
    private static func units(_ value: StellarJSON?, decimals: Int = 7, positive: Bool = false) -> String? {
        let raw: Int64?
        switch value {
        case .string(let text)?: raw = Int64(text)
        case .number(let number)? where number.isFinite && abs(number) < 9e18: raw = Int64(number)
        default: raw = nil
        }
        guard let raw, raw >= 0, !positive || raw > 0 else { return nil }
        return StellarAmount.format(raw, decimals: decimals, maxFraction: 4)
    }

    /// An amount the server wrote out ("10.5"), as holdings write it.
    private static func written(_ value: StellarJSON?) -> String? {
        guard let text = text(value), let units = StellarAmount.parse(text) else { return nil }
        return StellarAmount.format(units, maxFraction: 4)
    }

    private static func count(_ value: StellarJSON?) -> Int? {
        switch value {
        case .number(let number)? where number >= 1 && number < 1_000_000 && number == number.rounded(): Int(number)
        case .string(let text)?: Int(text).flatMap { $0 >= 1 ? $0 : nil }
        default: nil
        }
    }
}
