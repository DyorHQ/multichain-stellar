import BigInt
import Foundation

/* Retired launchpads (`LaunchpadAddresses.retiredStacks`: 0x6B1C…, 0x10F3…, 0x2F02…, 0xad3d…) are SELL-ONLY (owner
   decision 2026-09-28). A coin still on a retired launchpad's bonding curve — climbing, completed but not graduated, or
   in refund mode — can be sold by its holders, and nobody can buy it: no curve buy, no developer buy through a retired
   router's `launchAndBuy`, and no swap that buys it. Each layer refuses on its own:

     - the plan builders (`LaunchpadService.buyPlan`, `launchPlan`): nothing is built, not even the approval;
     - the coin page offers Sell only (in refund mode too), and Home's token page, the Portfolio's holdings and Swap's
       "no venue" state send a holder to that page, where the curve sell is: no Swap venue routes a bonding curve, the
       live launchpad's or a retired one's (`LaunchpadService.curveHoldings`, `curveRoute(for:)`, `LaunchpadCurves.swift`);
     - Swap (`SwapEngine.buyRefusal`): no venue's quote for buying such a coin is ever shown, reviewed or signed, read
       on-chain from every retired factory's record; a read that fails refuses too. Kuru Flow, a third party's API that
       would be told the wallet and the coin, is never asked: a round of quotes asks it a coin that may be a launchpad's
       only once the check has cleared it. The on-chain venues (Uniswap, Monday Trade) read their pools alongside the
       check, in reads that name no wallet, and nothing they find is shown until it clears the coin; one venue alone is
       asked only after it. Selling one is never checked;
     - a passkey account (`Mera.SigningPolicy.refusal`): a curve `buy` into a curve a retired factory recorded
       (`curveToToken`, read on-chain here), an approval paying anything but the coin into one, and `launchAndBuy` on a
       retired router are refused whatever the sheet declared or a Face ID approved, even if some screen built one.

   A coin that GRADUATED from a retired stack into a Monday Trade or Uniswap v4 pool is an ordinary pool token and trades
   both ways. The live stack (v2) is unaffected. */

public extension LaunchpadAddresses {
    /// Whether `factory` is one of the retired launchpads, whose curves take sells only.
    static func isRetired(_ factory: Address) -> Bool {
        !factory.isZero && retiredStack(for: factory) != nil
    }

    /// The retired stacks' routers: a `launchAndBuy` on one would be a developer buy on a retired curve.
    static var retiredRouters: [Address] { retiredStacks.map(\.router) }
}

/// What the app says (in the app's language) and checks about the retired launchpads' coins.
public enum RetiredLaunchpad {
    /// What every screen says where a buy of such a coin is refused.
    public static var notice: String { L10n.tr("This coin's launchpad is retired: you can sell, but not buy.") }

    /// Home's token page, for a sell-only coin: it sells on its curve, from its Launch page, never through Swap.
    public static var sellOnLaunchPage: String { L10n.tr("This coin's launchpad is retired: you can sell it on its Launch page, but not buy.") }

    /// Home's token page, for a sell-only coin whose completed curve waits to graduate (or is migrating): nothing trades
    /// until it graduates, and then it trades both ways on Swap.
    public static var graduationPending: String { L10n.tr("This coin's launchpad is retired and its graduation is pending: it can't be traded until it graduates.") }

    /// What a screen says of a coin on a retired launchpad's curve (`CurveRoute.notice`: Home's token page, Swap's "no
    /// venue" state), from its launch (`launch` nil when it couldn't be read): where to sell it, or, while its curve takes
    /// no sells, that it waits for its graduation. Nil once it graduated: it trades both ways on Swap.
    public static func tokenPageNotice(_ launch: Launch?) -> String? {
        guard let launch else { return sellOnLaunchPage }
        guard launch.isSellOnly else { return nil }
        return launch.curveSellsOpen ? sellOnLaunchPage : graduationPending
    }

    // MARK: Coins bought (Swap)

    /// The coins among `tokens` still on a retired launchpad's side of graduation, from every retired factory's
    /// `getLaunchedToken` record (each in its own layout) in one Multicall3 read: the launchpads' curve check
    /// (`LaunchpadCurve.curveRecords`, whose pure half `curveRecords(queries:results:)` decides) over the retired stacks
    /// alone, since only their curves refuse buys. A coin is sell-only when a retired factory's record of it exists and
    /// it has no pool yet (bonding, migrating or refund mode); a graduated one trades both ways. A factory answers an
    /// unknown token with an empty record, so a failed read, or any factory's answer missing, throws: then no coin can be
    /// ruled out.
    static func sellOnlyCoins(_ tokens: [Address], multicall: Multicall) async throws -> Set<Address> {
        Set(try await LaunchpadCurve.curveRecords(tokens, stacks: LaunchpadAddresses.retiredStacks, multicall: multicall).keys)
    }

    // MARK: Curves paid into (passkey policy)

    /// Which of `candidates` a retired factory recorded as a launch's curve, each with its coin, for
    /// `Mera.SigningPolicy.refusal`: every factory generation keeps the public `curveToToken(curve)` mapping, so each
    /// candidate is asked of every retired factory in one Multicall3 read. `.unknown` when the read fails or any answer is
    /// missing: then no curve can be ruled out.
    public static func curves(among candidates: Set<Address>, multicall: Multicall) async -> Mera.SigningPolicy.RetiredCurves {
        let curves = candidates.filter { !$0.isZero }.sorted { $0.hex < $1.hex }
        guard !curves.isEmpty else { return .none }
        let factories = LaunchpadAddresses.retiredFactories
        let calls = curves.flatMap { curve in factories.map { LaunchpadABI.call($0, LaunchpadABI.Factory.curveToToken, [.address(curve)], returns: "address") } }
        guard let results = try? await multicall.read(calls) else { return .unknown }
        return Self.curves(candidates: curves, factories: factories, results: results)
    }

    /// Pure half of `curves(among:)`: `results` holds each candidate's answer from each factory, candidate-major. A
    /// candidate is a retired curve when some factory maps it to a coin.
    static func curves(candidates: [Address], factories: [Address], results: [Result<[ABIValue], Error>]) -> Mera.SigningPolicy.RetiredCurves {
        guard results.count == candidates.count * factories.count else { return .unknown }
        var out: [Address: Address] = [:]
        for (i, curve) in candidates.enumerated() {
            for j in factories.indices {
                guard case .success(let values) = results[i * factories.count + j], let coin = values.first?.address else { return .unknown }
                if !coin.isZero, out[curve] == nil { out[curve] = coin }
            }
        }
        return .known(out)
    }
}

public extension LaunchpadService {
    /// `RetiredLaunchpad.curves(among:)` on this service's chain: what a passkey session needs to refuse a buy on a
    /// retired launchpad (`Mera.SigningPolicy.refusal`).
    func retiredCurves(among candidates: Set<Address>) async -> Mera.SigningPolicy.RetiredCurves {
        await RetiredLaunchpad.curves(among: candidates, multicall: multicall)
    }
}
