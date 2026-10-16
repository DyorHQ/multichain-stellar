// Stellar copy of ios/DyorHQ/Design/Components.swift TransactionProgress (42cd8c7 sha256:d5ee76eb41de)
// The review sheet's Progress section (docs/DESIGN-stellar-parity.md §8.7). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorLite
import StellarKit
import SwiftUI

/// Where one step of a Stellar plan stands, as the review sheet shows it, titled as Activity titles the transaction
/// (`PreparedAction.title(of:)`).
enum StellarStepProgress: Equatable {
    /// Being built or checked: "Swap · Preparing…".
    case preparing(String)
    /// A passkey account's step waits on its passkey prompt: "Swap: confirm with Face ID".
    case confirming(String)
    /// Sent to the network, not seen confirmed yet: "Swap sent", with View.
    case sent(String, hash: String)
    /// Confirmed on the network: "Swap confirmed", with View.
    case confirmed(String, hash: String)

    /// Whether the step reached the network: from then on its fee may be spent.
    var reachedNetwork: Bool {
        switch self {
        case .sent, .confirmed: true
        case .preparing, .confirming: false
        }
    }
}

/// A plan's progress, one row per step in the order the steps started, each row changing in place as its step moves on.
struct StellarPlanProgress: Equatable {
    private var order: [String] = []
    private var rows: [String: StellarStepProgress] = [:]

    /// The rows, in order.
    var steps: [StellarStepProgress] { order.compactMap { rows[$0] } }

    var isEmpty: Bool { order.isEmpty }

    /// Whether any step reached the network: the sheet never offers Confirm again then (`TransactionRun.alreadySent`).
    var reachedNetwork: Bool { rows.values.contains(where: \.reachedNetwork) }

    /// `event` of the run applied to its step's row. `title` is the step's; `passkey` whether its signing waits on a
    /// passkey prompt. A seed account's row doesn't change when its step is signed: its one App Lock prompt, if any, came
    /// at Confirm.
    mutating func apply(_ event: PlanRunner.Event, title: String, passkey: Bool) {
        let id: String
        let row: StellarStepProgress
        switch event {
        case .building(let step, _):
            id = step
            row = .preparing(title)
        case .signing(let step, _):
            id = step
            row = passkey ? .confirming(title) : rows[step] ?? .preparing(title)
        case .submitted(let step, let hash):
            id = step
            row = .sent(title, hash: hash)
        case .confirmed(let step, let hash):
            id = step
            row = .confirmed(title, hash: hash)
        }
        // A row never goes back: an event that arrives late leaves the furthest one.
        if let shown = rows[id], shown.stage > row.stage { return }
        if rows[id] == nil { order.append(id) }
        rows[id] = row
    }
}

private extension StellarStepProgress {
    /// How far the step has got.
    var stage: Int {
        switch self {
        case .preparing: 0
        case .confirming: 1
        case .sent: 2
        case .confirmed: 3
        }
    }
}

/// Progress of a Stellar plan, shown in the review sheet.
struct StellarTransactionProgress: View {
    let steps: [StellarStepProgress]
    /// When set, a sent or confirmed row's "View" calls this with the transaction's hash instead of opening StellarExpert.
    var onView: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                switch step {
                case .preparing(let title):
                    Label {
                        Text("\(title) · Preparing…", tableName: "StellarReview", comment: "The review's progress row: this step's transaction is being built and checked before it is signed. The value is the step (Swap XLM for USDC)")
                    } icon: {
                        Image(systemName: "circle.dotted")
                    }
                    .foregroundStyle(.secondary)
                case .confirming(let title):
                    Label {
                        Text("\(title): confirm with \(BiometricGate.promptName)", tableName: "StellarReview", comment: "The review's progress row on a passkey account: this step waits for the passkey prompt. The first value is the step (Swap XLM for USDC), the second the prompt's name (Face ID, Touch ID, Passcode)")
                    } icon: {
                        Image(systemName: BiometricGate.promptSymbol)
                    }
                    .foregroundStyle(Color.brand)
                case .sent(let title, let hash):
                    HStack {
                        Label("\(title) sent", systemImage: "paperplane").foregroundStyle(.secondary)
                        Spacer()
                        // Until it confirms, the explorer is the only way to see whether a sent step landed — which the
                        // user must check before trying again after an error.
                        viewLink(hash)
                    }
                case .confirmed(let title, let hash):
                    HStack {
                        Label("\(title) confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive)
                        Spacer()
                        viewLink(hash)
                    }
                }
            }
        }
        .font(.subheadline)
        .symbolRenderingMode(.hierarchical)
    }

    @ViewBuilder private func viewLink(_ hash: String) -> some View {
        if let onView {
            Button("View") { onView(hash) }.font(.footnote)
        } else if let page = StellarExplorer.transaction(hash, network: LiteGate.pinned.network) {
            Link("View", destination: page).font(.footnote)
        }
    }
}
#endif
