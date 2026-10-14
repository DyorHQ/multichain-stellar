// The scripted Perps demo (p4 spec D): DEBUG + Simulator only, compiled out of every other build. Launched with
// `-PerpsDemo [scenario-id]` (add `-PerpsDemoReview YES` to open the scenario in review instead of running it), it shows
// every outcome the Perps sheets can show, for QA screenshots, in any account state: signed in, watch-only or signed out.
// Each run is an isolated `PerplTrading` that has adopted a scripted `PerplTradeClient`: no socket, no key, no network.
// The sheets, the tracker and the cards are the app's own. Nothing is written to Activity, notifications or the backend.
// Everything on this screen is a DEBUG-only QA tool's: not localized, and written with `Text(verbatim:)` only.
#if DEBUG && targetEnvironment(simulator)
import DyorKit
import SwiftUI

/// The demo's launch arguments and fixtures.
enum PerpsDemo {
    static let argument = "-PerpsDemo" // not localized: a launch argument
    static let reviewArgument = "-PerpsDemoReview" // not localized: a launch argument

    /// The app was launched with `-PerpsDemo`.
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-PerpsDemo <scenario-id>`: the scenario to start at launch.
    static var requestedScenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }

    /// `-PerpsDemoReview YES`: open the scenario (in review) instead of running it.
    static var reviewRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: reviewArgument), index + 1 < arguments.count else { return false }
        return ["YES", "yes", "1", "true"].contains(arguments[index + 1]) // not localized: argument values
    }

    /// The address the demo's chain reads are made for: a fixed non-account address only the demo's stub reads.
    static let readAddress = Address(literal: "0x000000000000000000000000000000000000de30")

    /// The account a demo sheet acts for: no wallet (nothing is filed under anyone), the demo's Perpl account, no passkey.
    static let account = PerplTrading.ActionAccount(owner: nil, accountId: PerplDemoScript.accountId, passkey: false)

    /// What a scenario's sheet is set to before its confirm: the Close sheet's size chip and limit, Add Margin's amount.
    struct Terms: Equatable {
        var percent = 100
        var limitText: String?
        var postOnly = false
        var amountText: String?
    }

    static func terms(_ scenario: PerplDemoScript.Scenario) -> Terms? {
        switch scenario.screen {
        case .close(let percent, let limit, let postOnly): return Terms(percent: percent, limitText: limit.map { String(Int($0)) }, postOnly: postOnly)
        case .margin(let amount): return Terms(amountText: amount)
        case .order, .cancelOrder, .cancelTriggers, .cards: return nil
        }
    }
}

extension EnvironmentValues {
    /// The demo's Run: how long after it appears a sheet confirms itself (nil: never, the default everywhere else).
    @Entry var perpsDemoAutoConfirm: Duration? = nil
    /// The demo's terms for the sheet (nil everywhere else).
    @Entry var perpsDemoTerms: PerpsDemo.Terms? = nil
    /// Bumped when the demo's script taps the Close sheet's Try Again.
    @Entry var perpsDemoTryAgain: Int = 0
}

/// The scripted trading socket: the scenario's prelude, the heartbeat every 400 ms continuing the snapshot's sequence, and
/// Perpl's replies to what the client writes, each after its delay and in order, all through `debugReceive`; the scenario's
/// steps; and the chain reads Add Margin makes. A dropped socket delivers nothing more.
@Observable
@MainActor
final class PerpsDemoSocket {
    let scenario: PerplDemoScript.Scenario
    let client: PerplTradeClient
    /// Bumped by a `tryAgain` step: the Close sheet runs its own Try Again.
    private(set) var tryAgain = 0
    /// The screen's part of the steps.
    @ObservationIgnored var onDismissSheet: () -> Void = {}
    @ObservationIgnored var onCancelFromCard: (Int) -> Void = { _ in }

    @ObservationIgnored private var queue: [(due: Date, seq: Int, text: () -> String)] = []
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var head = PerplDemoScript.firstHead
    @ObservationIgnored private var beatSn = PerplDemoScript.snapshotSn
    @ObservationIgnored private var serverSn = 50_000
    @ObservationIgnored private var used: Set<Int> = []
    @ObservationIgnored private var writeTimes: [Date] = []
    @ObservationIgnored private var firstMarginWriteAt: Date?
    @ObservationIgnored private var dropped = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private let startedAt = Date()

    init(scenario: PerplDemoScript.Scenario, client: PerplTradeClient) {
        self.scenario = scenario
        self.client = client
    }

    func start() {
        client.debugAttach { [weak self] text in self?.written(text) }
        for template in scenario.prelude { client.debugReceive(render(template, rq: 0, sn: 0)) }
        tasks.append(Task { [weak self] in await self?.drive() })
        tasks.append(Task { [weak self] in await self?.runSteps() })
    }

    func stop() {
        dropped = true
        for task in tasks { task.cancel() }
        tasks = []
        queue = []
    }

    /// What a chain read of the position returns now (the scenario's scripted margin), or nothing without a position.
    func chainPositions() -> [PerpPosition] {
        guard scenario.hasPosition else { return [] }
        let since = firstMarginWriteAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        return [PerplDemoScript.position(margin: scenario.chainMargin(afterWriteMs: since))]
    }

    private func render(_ template: String, rq: Int, sn: Int) -> String {
        PerplDemoScript.render(template, rq: rq, sn: sn, head: head, serverSn: serverSn, nowMs: Int(Date().timeIntervalSince1970 * 1000))
    }

    private func schedule(after ms: Int, _ text: @escaping () -> String) {
        seq += 1
        queue.append((Date().addingTimeInterval(Double(ms) / 1000), seq, text))
    }

    /// A frame the client wrote: answered by the next unused reply that matches it, or never.
    private func written(_ text: String) {
        guard !dropped, let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        writeTimes.append(Date())
        guard let match = PerplDemoScript.match(frame), let sn = frame["sn"] as? Int, let rq = frame["rq"] as? Int else { return }
        if match == .margin, firstMarginWriteAt == nil { firstMarginWriteAt = Date() }
        guard let index = scenario.replies.indices.first(where: { !used.contains($0) && scenario.replies[$0].match == match }) else { return }
        used.insert(index)
        let reply = scenario.replies[index]
        serverSn += 1
        if let ack = PerplDemoScript.ackFrame(reply.ack, sn: sn, serverSn: serverSn) { schedule(after: reply.ackAfterMs) { ack } }
        for timed in reply.frames {
            // Rendered when it is sent, at the head of that moment.
            schedule(after: timed.afterMs) { [weak self] in self?.render(timed.template, rq: rq, sn: sn) ?? "" }
        }
    }

    /// Every 25 ms: the frames due, earliest first, then a heartbeat each 400 ms.
    private func drive() async {
        var nextBeat = Date().addingTimeInterval(Double(PerplDemoScript.beatMilliseconds) / 1000)
        while !Task.isCancelled, !dropped {
            let now = Date()
            for item in queue.filter({ $0.due <= now }).sorted(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
                queue.removeAll { $0.seq == item.seq }
                guard !dropped else { return }
                client.debugReceive(item.text())
            }
            while nextBeat <= now, !dropped {
                head += 1
                beatSn += 1
                client.debugReceive(PerplDemoScript.heartbeat(sn: beatSn, head: head))
                nextBeat = nextBeat.addingTimeInterval(Double(PerplDemoScript.beatMilliseconds) / 1000)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The scenario's steps, one after another: each `afterMs` after the moment the previous one ran (or the start), or
    /// after the first write since that moment.
    private func runSteps() async {
        var since = startedAt
        for step in scenario.steps {
            var anchor = since
            if step.anchor == .write {
                while !Task.isCancelled {
                    if let write = writeTimes.first(where: { $0 >= since }) { anchor = write; break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let wait = anchor.addingTimeInterval(Double(step.afterMs) / 1000).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            switch step.action {
            case .drop:
                dropped = true
                queue = []
                client.debugDrop()
            case .dismissSheet:
                onDismissSheet()
            case .removeOrder(let oid):
                client.debugReceive(render(PerplDemoScript.removal(oid: oid), rq: 0, sn: 0))
            case .tryAgain:
                tryAgain += 1
            case .cancelFromCard(let oid):
                onCancelFromCard(oid)
            }
            since = Date()
        }
    }
}

/// One run of a scenario: its own `PerplTrading` (never the app's), its scripted socket, and whether its sheet confirms
/// itself (Run) or stays in review (Open).
@MainActor
final class PerpsDemoRun {
    let scenario: PerplDemoScript.Scenario
    let trading: PerplTrading
    let socket: PerpsDemoSocket
    let autoConfirm: Bool

    init(_ scenario: PerplDemoScript.Scenario, autoConfirm: Bool) {
        // Never bound to a wallet or a passkey session: every order and margin of it has no owner, so nothing is filed or
        // posted, and its notices go to `debugNotices`.
        let trading = PerplTrading(mera: nil)
        trading.notifyFills = { true }
        // Both owner switches on, in this instance only (the app's own keep what the owner set).
        trading.liveOutcomes = true
        trading.apiActions = true
        let client = PerplTradeClient.debugScripted()
        trading.debugAdopt(client)
        let socket = PerpsDemoSocket(scenario: scenario, client: client)
        trading.noteMarkets([PerplDemoScript.market])
        // The chain reads (Add Margin's "before" and its 2/5/10 s polls, the order sheet's position): the script's, never a network's.
        trading.readPositions = { _, _ in socket.chainPositions() }
        self.scenario = scenario
        self.autoConfirm = autoConfirm
        self.trading = trading
        self.socket = socket
    }

    func stop() {
        socket.stop()
        trading.debugRelease()
    }

    /// The sheet on screen has handed its request to the session (an order or a close is followed and marked as shown, a
    /// margin's request was written): closing it now is what a swipe after the send does. Closed earlier, a sheet still
    /// sending would mark its result as shown after it was gone.
    var sheetHandedOver: Bool {
        switch scenario.screen {
        case .order, .close: return trading.orders.orders.contains { $0.presentedInSheet }
        case .margin: return trading.debugMarginPresented
        case .cancelOrder, .cancelTriggers, .cards: return true
        }
    }
}

/// A sheet the demo presents: the app's own, on the run's session.
struct PerpsDemoSheet: Identifiable {
    enum Kind {
        case order(PerplDemoScript.Ticket)
        case close
        case margin
        case cancelOrder(PerplOpenOrder, tapRq: Int?)
        case cancelTriggers([PerplOpenOrder], title: String)
    }
    let id = UUID()
    let kind: Kind
    let demo: PerpsDemoRun
    let autoConfirm: Bool
}

/// The demo screen: every scenario with Open (the sheet in review) and Run (it confirms itself 2 s after it appears), and
/// for the run on screen the trade screen's cards, its status row and the notices the app would post.
struct PerpsDemoView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var demo: PerpsDemoRun?
    @State private var sheet: PerpsDemoSheet?
    @State private var startedFromArguments = false

    private typealias Script = PerplDemoScript

    private static let groups: [(title: String, ids: [String])] = { // not localized: DEBUG-only QA screen
        let all = PerplDemoScript.scenarios
        func ids(_ match: (PerplDemoScript.Screen) -> Bool) -> [String] { all.filter { match($0.screen) }.map(\.id) }
        return [
            ("Orders", ids { if case .order = $0 { return true }; return false }), // not localized: DEBUG-only QA screen
            ("TP/SL cancels", ids { $0 == .cancelTriggers }), // not localized: DEBUG-only QA screen
            ("Closes", ids { if case .close = $0 { return true }; return false }), // not localized: DEBUG-only QA screen
            ("Margin", ids { if case .margin = $0 { return true }; return false }), // not localized: DEBUG-only QA screen
            ("Cancel order", ids { $0 == .cancelOrder }), // not localized: DEBUG-only QA screen
            ("Cards", ids { $0 == .cards }), // not localized: DEBUG-only QA screen
        ]
    }()

    var body: some View {
        NavigationStack {
            List {
                if let demo { runSections(demo) }
                ForEach(Self.groups, id: \.title) { group in
                    Section {
                        ForEach(group.ids, id: \.self) { id in
                            if let scenario = Script.scenario(id) { row(scenario) }
                        }
                    } header: {
                        Text(verbatim: group.title)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text(verbatim: "Perps demo")) // not localized: DEBUG-only QA screen
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { exit() } label: { Text(verbatim: "Close") } // not localized: DEBUG-only QA screen
                }
            }
        }
        .sheet(item: $sheet) { sheet in content(sheet) }
        .task {
            guard !startedFromArguments else { return }
            startedFromArguments = true
            if let id = PerpsDemo.requestedScenario, let scenario = Script.scenario(id) { start(scenario, autoConfirm: !PerpsDemo.reviewRequested) }
        }
        .onDisappear { stopRun() }
    }

    // MARK: The list

    private func row(_ scenario: PerplDemoScript.Scenario) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: scenario.title).font(.subheadline.weight(.semibold))
            Text(verbatim: scenario.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(verbatim: scenario.expected).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { start(scenario, autoConfirm: false) } label: { Text(verbatim: "Open") } // not localized: DEBUG-only QA screen
                    .buttonStyle(.bordered)
                Button { start(scenario, autoConfirm: true) } label: { Text(verbatim: "Run") } // not localized: DEBUG-only QA screen
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// The run on screen: the trade screen's cards (a Cards scenario), the status row, and the notices the app would post.
    @ViewBuilder private func runSections(_ demo: PerpsDemoRun) -> some View {
        if demo.scenario.screen == .cards {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in cards(demo) }
            } header: {
                Text(verbatim: "Cards · \(demo.scenario.id)") // not localized: DEBUG-only QA screen
            }
        }
        Section {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    if let order = demo.trading.orders.bannerOrder(marketId: Script.marketId, now: context.date) {
                        PerpOrderStatusRow(order: order) { demo.trading.orders.dismissBanner(order.id) }
                    } else {
                        Text(verbatim: "No status row").font(.footnote).foregroundStyle(.secondary) // not localized: DEBUG-only QA screen
                    }
                }
            }
        } header: {
            Text(verbatim: "Status row · \(demo.scenario.id)") // not localized: DEBUG-only QA screen
        }
        Section {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let notices = demo.trading.debugNotices
                VStack(alignment: .leading, spacing: 8) {
                    if notices.isEmpty {
                        Text(verbatim: "Nothing yet").font(.footnote).foregroundStyle(.secondary) // not localized: DEBUG-only QA screen
                    }
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: notice.title).font(.footnote.weight(.semibold))
                            Text(verbatim: notice.body).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(verbatim: "Would notify") // not localized: DEBUG-only QA screen
        }
    }

    /// The trade screen's cards, on the run's session: the position with its TP/SL, the resting order, the TP/SL.
    @ViewBuilder private func cards(_ demo: PerpsDemoRun) -> some View {
        let trading = demo.trading
        let market = Script.market
        let position = Script.position()
        let rows = triggerRows(trading)
        VStack(spacing: 12) {
            PositionCard(position: position, liveMark: market.mark, triggers: rows.filter(\.positionLong),
                         onClose: { present(.close, demo, autoConfirm: false) }, onAddMargin: { present(.margin, demo, autoConfirm: false) }, onTriggers: {})
            let streamKey = PerplOpenOrder.streamOrder(for: Script.chainOrder, in: trading.openOrders, priceDecimals: market.priceDecimals)?.id
            OrderCard(order: Script.chainOrder, mark: market.mark, cancelling: streamKey.map { trading.cancellingKeys.contains($0) } ?? false,
                      gone: trading.chainOrderGone(Script.chainOrder), onCancel: { cancelFromCard(31, demo, autoConfirm: false) })
            ForEach(rows) { row in
                TriggerCard(row: row, mark: market.mark, cancelling: row.order.map { trading.cancellingKeys.contains($0.id) } ?? false) {
                    if let order = row.order { cancelFromCard(order.oid, demo, autoConfirm: false) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The TP/SL on Perpl's live list, as the trade screen's rows.
    private func triggerRows(_ trading: PerplTrading) -> [TriggerRow] {
        let market = Script.market
        return trading.openOrders.filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly }.map { order in
            TriggerRow(id: "demo-\(order.oid)", symbol: market.asset, kind: order.isStopLoss ? .stopLoss : .takeProfit, // not localized: an identifier
                       price: Double(order.triggerPriceRaw ?? 0) / pow(10, Double(market.priceDecimals)), size: Double(order.sizeRaw) / pow(10, Double(market.lotDecimals)),
                       positionLong: order.protectsLong, source: trading.ordersAreLive && !trading.streamSuspect ? .live : .lastKnown, order: order,
                       positionSize: order.protectsLong ? Script.position().size : nil)
        }
    }

    // MARK: Runs

    private func start(_ scenario: PerplDemoScript.Scenario, autoConfirm: Bool) {
        stopRun()
        let demo = PerpsDemoRun(scenario, autoConfirm: autoConfirm)
        demo.socket.onDismissSheet = {
            Task { @MainActor in
                // Never while the sheet is still sending (a slow simulator can lag the script): at most 10 s.
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, !demo.sheetHandedOver { try? await Task.sleep(for: .milliseconds(50)) }
                if self.demo === demo { sheet = nil }
            }
        }
        demo.socket.onCancelFromCard = { oid in cancelFromCard(oid, demo, autoConfirm: demo.autoConfirm) }
        demo.socket.start()
        self.demo = demo
        switch scenario.screen {
        case .order(let ticket): present(.order(ticket), demo, autoConfirm: autoConfirm)
        case .close: present(.close, demo, autoConfirm: autoConfirm)
        case .margin: present(.margin, demo, autoConfirm: autoConfirm)
        case .cancelOrder: cancelFromCard(31, demo, autoConfirm: autoConfirm)
        case .cancelTriggers:
            present(.cancelTriggers(demo.trading.openOrders.filter(\.isTrigger), title: "Leftover TP/SL"), demo, autoConfirm: autoConfirm) // not localized: the existing key
        case .cards:
            break
        }
    }

    private func present(_ kind: PerpsDemoSheet.Kind, _ demo: PerpsDemoRun, autoConfirm: Bool) {
        sheet = PerpsDemoSheet(kind: kind, demo: demo, autoConfirm: autoConfirm)
    }

    /// A tap on a card's Cancel: the resting order's own sheet when Perpl's list names it, a TP/SL's otherwise; a gone order
    /// opens nothing (as on the trade screen).
    private func cancelFromCard(_ oid: Int, _ demo: PerpsDemoRun, autoConfirm: Bool) {
        let trading = demo.trading
        if oid == Script.chainOrder.orderId {
            guard trading.chainOrderGone(Script.chainOrder) == nil,
                  let target = PerplOpenOrder.streamOrder(for: Script.chainOrder, in: trading.openOrders, priceDecimals: Script.market.priceDecimals) else { return }
            present(.cancelOrder(target, tapRq: trading.requestId(for: target.id)), demo, autoConfirm: autoConfirm)
        } else if let order = trading.openOrders.first(where: { $0.oid == oid && $0.isTrigger }) {
            present(.cancelTriggers([order], title: order.isStopLoss ? "Cancel Stop Loss" : "Cancel Take Profit"), demo, autoConfirm: autoConfirm) // not localized: the existing keys
        }
    }

    private func stopRun() {
        sheet = nil
        demo?.stop()
        demo = nil
        // The one local write a real sheet makes: the order sheet's TP/SL echoes, on a market no real screen shows.
        for kind in [PlacedTrigger.Kind.takeProfit, .stopLoss] {
            for long in [true, false] { TriggerStore.remove(perpId: Script.marketId, kind: kind, positionLong: long, owner: session.address) }
        }
    }

    private func exit() {
        stopRun()
        dismiss()
    }

    // MARK: The sheets

    /// The app's own sheet, on the run's session, in the API path (the account at the tap, no wallet).
    @ViewBuilder private func content(_ sheet: PerpsDemoSheet) -> some View {
        let demo = sheet.demo
        let market = Script.market
        let position = Script.position()
        Group {
            switch sheet.kind {
            case .order(let ticket):
                AuthedOrderSheet(market: market, input: ticket.input, takeProfit: ticket.takeProfit, stopLoss: ticket.stopLoss, accountId: Script.accountId,
                                 sideColor: .positive, summaryMargin: ticket.input.size * (ticket.limitPrice ?? market.mark) / ticket.input.leverage,
                                 onChainPositions: [position], onChainOrders: [Script.chainOrder], live: true, closes: nil, held: (.long, position.size),
                                 ttlBlocks: 20, markets: [market], before: position, beforeReadAt: Date(), restingOnSide: false) { _ in }
            case .close:
                ClosePositionSheet(market: market, position: position, mark: market.mark, accountId: Script.accountId, route: PerpsDemo.account) {}
            case .margin:
                AddMarginSheet(market: market, position: position, available: demo.scenario.available, accountId: Script.accountId, route: PerpsDemo.account) {}
            case .cancelOrder(let target, let tapRq):
                CancelOrderSheet(market: market, order: Script.chainOrder, target: target, tapRq: tapRq, account: PerpsDemo.account) {}
            case .cancelTriggers(let orders, let title):
                CancelTriggersSheet(market: market, orders: orders, title: LocalizedStringResource(String.LocalizationValue(title)), note: nil) {}
            }
        }
        .environment(demo.trading)
        .environment(\.perpsDemoAutoConfirm, sheet.autoConfirm ? .seconds(2) : nil)
        .environment(\.perpsDemoTerms, PerpsDemo.terms(demo.scenario))
        .environment(\.perpsDemoTryAgain, demo.socket.tryAgain)
    }
}
#endif
