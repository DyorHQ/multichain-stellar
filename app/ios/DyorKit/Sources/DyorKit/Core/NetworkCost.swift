import Foundation
import Network

/// Whether the network the phone is on is one the user pays for by the byte or asked to spare: Low Data Mode (`NWPath`'s
/// `isConstrained`) or a cellular or hotspot link (`isExpensive`). The image pipeline reads it before it fetches a whole
/// original nobody has asked to see yet (`ImagePipeline.prefetch`): a board's next rows still load as they scroll in,
/// just not ahead of it. One monitor for the app, started on first use; false until its first answer.
public final class NetworkCost: @unchecked Sendable {
    public static let shared = NetworkCost()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var metered = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.isConstrained || path.isExpensive) }
        monitor.start(queue: DispatchQueue(label: "fun.dyorhq.network-cost", qos: .utility))
    }

    /// Low Data Mode, or a cellular or hotspot link.
    public var isMetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return metered
    }

    private func update(_ value: Bool) {
        lock.lock()
        metered = value
        lock.unlock()
    }
}
