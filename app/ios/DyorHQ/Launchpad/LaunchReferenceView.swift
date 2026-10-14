import DyorKit
import SwiftUI

/// The Launch page of a coin whose launch a screen couldn't read (`CurveRoute.launchUnread`): it reads the launch from
/// the factory that recorded it (`LaunchpadService.launch(_:)`, a DyorHQ launchpad only), then shows the ordinary coin
/// page, sell-only on a retired launchpad. Home, the Portfolio and Swap open it through `Router.openLaunchPage(for:)`,
/// so a coin the board doesn't list (a retired launchpad's sell-only coin) is never a dead end.
struct LaunchReferenceView: View {
    let reference: LaunchReference
    @Environment(AppEnvironment.self) private var env
    @State private var launch: Launch?
    @State private var missing = false
    @State private var error: String?

    var body: some View {
        if let launch {
            LaunchDetailView(launch: launch)
        } else {
            Group {
                if missing {
                    ContentUnavailableView {
                        Label("Not a DyorHQ launch", systemImage: "flame")
                    } description: {
                        Paragraph("No DyorHQ launchpad has a launch of this coin.")
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't open this launch", systemImage: "wifi.exclamationmark")
                    } description: {
                        Paragraph(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }.buttonStyle(.borderedProminent)
                        Link("View on Monadscan", destination: Monad.explorerToken(reference.token))
                    }
                } else {
                    ProgressView("Opening launch…")
                }
            }
            .navigationTitle(tr("Launch"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: reference) { await load() }
        }
    }

    private func load() async {
        error = nil
        missing = false
        do {
            if let detail = try await env.launchpad.launch(reference) { launch = detail.launch } else { missing = true }
        } catch {
            self.error = describe(error)
        }
    }
}
