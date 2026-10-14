import BigInt
import XCTest
@testable import DyorKit

/// Home's "Add funds to start trading" card (MERA-PLAN §4): only an empty, unused account sees it; a deposit turns it
/// into "Funds arrived" and, after Monad's 3-block pause, "Make your first trade"; activity ends it from any phase.
final class FirstFundingTests: XCTestCase {
    private let mon = BigUInt(10).power(18)
    private let usdc = BigUInt(1_000_000)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let tokens = Token.core
    private let usdt0 = Token.core.first { $0.symbol == "USDT0" }!
    private let weth = Token.core.first { $0.symbol == "WETH" }!
    private let airdrop = Token(address: Address(literal: "0x9999999999999999999999999999999999999999"), symbol: "FREE", name: "Free Coin", decimals: 18)

    private func snapshot(_ balances: [Address: BigUInt] = [:], prices: [Address: Double] = [:], nonce: UInt64? = 0, history: Bool = false, extra: [Token] = []) -> FirstFunding.Snapshot {
        FirstFunding.Snapshot(balances: balances, tokens: tokens + extra, prices: prices, nonce: nonce, hasHistory: history)
    }

    private func next(_ phase: FirstFunding.Phase, _ reading: FirstFunding.Snapshot?, at seconds: TimeInterval = 0) -> FirstFunding.Phase {
        FirstFunding.next(after: phase, reading: reading, now: t0.addingTimeInterval(seconds))
    }

    private func offered(_ phase: FirstFunding.Phase) -> FirstFunding.Trade? {
        switch phase {
        case .arrived(let trade, _), .firstTrade(let trade): return trade
        default: return nil
        }
    }

    func testFirstReadDecides() {
        XCTAssertEqual(next(.checking, snapshot()), .addFunds)
        XCTAssertEqual(next(.checking, snapshot([Monad.native: mon])), .done, "an account funded from the start never sees the card")
        XCTAssertEqual(next(.checking, snapshot([Monad.usdc: 5 * usdc])), .done)
        XCTAssertEqual(next(.checking, snapshot(nonce: 1)), .done, "an account that has sent a transaction is in use")
        XCTAssertEqual(next(.checking, snapshot(history: true)), .done)
        XCTAssertEqual(next(.checking, nil), .checking, "a failed first read shows nothing yet")
        XCTAssertEqual(next(.checking, snapshot(nonce: nil)), .addFunds, "an unread nonce doesn't hold the card back")
        XCTAssertFalse(FirstFunding.Phase.checking.isVisible)
        XCTAssertTrue(FirstFunding.Phase.addFunds.isVisible)
        XCTAssertFalse(FirstFunding.Phase.done.isVisible)
        XCTAssertFalse(FirstFunding.Phase.done.isWatching)
        XCTAssertTrue(FirstFunding.Phase.checking.isWatching)
    }

    func testMONDepositArrivesThenOffersTheTrade() {
        let arrived = next(.addFunds, snapshot([Monad.native: 2 * mon]), at: 0)
        let trade = FirstFunding.Trade(pay: .mon, receive: .usdc, amount: 2 * mon, needsMON: false)
        XCTAssertEqual(arrived, .arrived(trade, since: t0))
        XCTAssertTrue(arrived.isVisible)
        // Monad spends a deposit only once it is 3 blocks old: "Funds arrived" holds for the pause.
        XCTAssertEqual(next(arrived, snapshot([Monad.native: 2 * mon]), at: 1.0), .arrived(trade, since: t0))
        XCTAssertEqual(next(arrived, snapshot([Monad.native: 2 * mon]), at: FirstFunding.arrivalPause), .firstTrade(trade))
        // A failed read never holds the card on "Funds arrived".
        XCTAssertEqual(next(arrived, nil, at: 2), .firstTrade(trade))
        XCTAssertEqual(next(arrived, nil, at: 0.5), arrived)
    }

    func testUSDCDepositSwapsForMONAndAsksForMONFirst() {
        let arrived = next(.addFunds, snapshot([Monad.usdc: 20 * usdc], prices: [Monad.usdc: 1]))
        let trade = offered(arrived)
        XCTAssertEqual(trade?.pay, .usdc)
        XCTAssertEqual(trade?.receive, .mon)
        XCTAssertEqual(trade?.amount, 20 * usdc)
        XCTAssertEqual(trade?.needsMON, true, "no MON: the trade can't pay its network fee")

        // MON for the fee arrives: the same pair is offered, now ready.
        let first = next(arrived, snapshot([Monad.usdc: 20 * usdc, Monad.native: mon / 2], prices: [Monad.usdc: 1]), at: 2)
        XCTAssertEqual(first, .firstTrade(.init(pay: .usdc, receive: .mon, amount: 20 * usdc, needsMON: false)))
        XCTAssertEqual(next(first, snapshot([Monad.usdc: 20 * usdc, Monad.native: 3 * mon], prices: [Monad.usdc: 1]), at: 6),
                       .firstTrade(.init(pay: .usdc, receive: .mon, amount: 20 * usdc, needsMON: false)))
    }

    func testMONBelowTheFeeFloorAsksForMore() {
        let small = FirstFunding.feeFloor - 1
        let trade = offered(next(.addFunds, snapshot([Monad.native: small])))
        XCTAssertEqual(trade, .init(pay: .mon, receive: .usdc, amount: small, needsMON: true))
        XCTAssertEqual(offered(next(.addFunds, snapshot([Monad.native: FirstFunding.feeFloor])))?.needsMON, false)
        // 0.07 MON is under what Swap's Max keeps back for a swap's fee at Monad's usual fees (~0.076 MON): not ready.
        XCTAssertEqual(offered(next(.addFunds, snapshot([Monad.native: 7 * mon / 100])))?.needsMON, true)
        XCTAssertEqual(FirstFunding.feeFloor, mon / 10, "the 0.1 MON the card asks for")
    }

    func testDustIsNotADeposit() {
        XCTAssertEqual(next(.addFunds, snapshot([Monad.native: 1])), .addFunds)
        XCTAssertEqual(next(.addFunds, snapshot([Monad.native: FirstFunding.monDust - 1])), .addFunds)
        XCTAssertNotEqual(next(.addFunds, snapshot([Monad.native: FirstFunding.monDust])), .addFunds)
        // Priced: under a cent is dust.
        XCTAssertEqual(next(.addFunds, snapshot([Monad.usdc: 9_999], prices: [Monad.usdc: 1])), .addFunds)
        XCTAssertNotEqual(next(.addFunds, snapshot([Monad.usdc: 10_000], prices: [Monad.usdc: 1])), .addFunds)
        // Unpriced: a curated token counts, an airdropped one never does.
        XCTAssertNotEqual(next(.addFunds, snapshot([Monad.usdc: 1])), .addFunds)
        XCTAssertEqual(next(.addFunds, snapshot([airdrop.address: 1_000 * mon], extra: [airdrop])), .addFunds)
        XCTAssertEqual(next(.checking, snapshot([airdrop.address: 1_000 * mon], extra: [airdrop])), .addFunds, "an airdrop doesn't hide the card")
        // A priced airdrop worth something is funds, but it never becomes the trade ahead of a curated token.
        let trade = offered(next(.addFunds, snapshot([airdrop.address: mon, usdt0.address: 3 * usdc], prices: [airdrop.address: 5, usdt0.address: 1], extra: [airdrop])))
        XCTAssertEqual(trade?.pay, usdt0)
        XCTAssertEqual(trade?.receive, .mon)
    }

    func testTradePairs() {
        func pair(_ balances: [Address: BigUInt]) -> (String, String)? {
            offered(next(.addFunds, snapshot(balances))).map { ($0.pay.symbol, $0.receive.symbol) }
        }
        XCTAssertEqual(pair([Monad.native: mon, Monad.usdc: usdc])?.0, "MON", "MON pays when the account holds it")
        XCTAssertEqual(pair([Monad.native: mon, Monad.usdc: usdc])?.1, "USDC")
        XCTAssertEqual(pair([Monad.usdc: usdc, weth.address: mon])?.0, "USDC", "USDC comes before other tokens")
        XCTAssertEqual(pair([weth.address: mon])?.0, "WETH")
        XCTAssertEqual(pair([weth.address: mon])?.1, "MON")
        XCTAssertEqual(pair([Monad.wmon: mon])?.0, "WMON")
        XCTAssertEqual(pair([Monad.wmon: mon])?.1, "USDC", "WMON trades for USDC, not an unwrap")
    }

    func testActivityEndsItFromAnyPhase() {
        let trade = FirstFunding.Trade(pay: .mon, receive: .usdc, amount: mon, needsMON: false)
        for phase: FirstFunding.Phase in [.checking, .addFunds, .arrived(trade, since: t0), .firstTrade(trade)] {
            XCTAssertEqual(next(phase, snapshot([Monad.native: mon], nonce: 1)), .done, "\(phase)")
            XCTAssertEqual(next(phase, snapshot(history: true)), .done, "\(phase)")
        }
        XCTAssertEqual(next(.done, snapshot()), .done)
        XCTAssertEqual(next(.done, nil), .done)
    }

    func testNeverGoesBack() {
        let trade = FirstFunding.Trade(pay: .mon, receive: .usdc, amount: mon, needsMON: false)
        // A lagging node reads zero after the deposit: no transaction was sent, so the offer stands.
        XCTAssertEqual(next(.firstTrade(trade), snapshot()), .firstTrade(trade))
        XCTAssertEqual(next(.firstTrade(trade), nil), .firstTrade(trade))
        XCTAssertEqual(next(.arrived(trade, since: t0), snapshot(), at: 0.2), .arrived(trade, since: t0))
        XCTAssertEqual(next(.arrived(trade, since: t0), snapshot(), at: 2), .firstTrade(trade))
        XCTAssertEqual(next(.addFunds, nil), .addFunds)
    }

    func testTheTradeFollowsTheBalance() {
        let first = FirstFunding.Phase.firstTrade(.init(pay: .mon, receive: .usdc, amount: mon, needsMON: false))
        XCTAssertEqual(next(first, snapshot([Monad.native: 3 * mon])), .firstTrade(.init(pay: .mon, receive: .usdc, amount: 3 * mon, needsMON: false)))
        // USDC landing too doesn't change the pair on offer.
        XCTAssertEqual(offered(next(first, snapshot([Monad.native: 3 * mon, Monad.usdc: 50 * usdc])))?.pay, .mon)
    }
}
