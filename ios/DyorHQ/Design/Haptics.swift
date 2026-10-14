import AudioToolbox
import SwiftUI
import UIKit

/// Tactile + audible feedback for taps, the way a native iOS app confirms every deliberate action. Impact
/// generators are prepared just before firing so the haptic lands with no perceptible lag. The subtle tick is the
/// system keyboard "Tock" (1104), which already respects the ring/silent switch and the user's keyboard-sound
/// setting, so it is never louder or more intrusive than the OS itself would be.
enum Haptics {
    /// A deliberate button press: a light knock plus the subtle system tick. Used by primary actions.
    static func tap() {
        impact(.light)
        tick()
    }

    /// A firmer confirmation for consequential actions (placing an order, confirming a transaction).
    static func commit() {
        impact(.medium)
        tick()
    }

    /// Moving a selection — segment, toggle, percentage, tab, timeframe. Silent by design; selection is frequent.
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    /// The subtle keyboard-tap sound.
    private static func tick() { AudioServicesPlaySystemSound(1104) }
}
