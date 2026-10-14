import CoreGraphics
import Foundation

/// A launch's picture as the create form uploads it: the largest square in the middle of the chosen photo, drawn
/// `side` pixels a side and saved as a JPEG. Every screen shows a coin's picture in a square or a circle, so what the
/// creator sees in the form's preview is what every holder sees, and no wide photo is stored at a size no screen needs.
public enum LaunchImage {
    /// The uploaded picture's width and height, in pixels.
    public static let side = 512

    /// The part of an image `size` across a launch's picture keeps: its largest square, centred. An empty size keeps
    /// nothing.
    public static func centreSquare(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return .zero }
        let edge = min(size.width, size.height)
        return CGRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
    }
}
