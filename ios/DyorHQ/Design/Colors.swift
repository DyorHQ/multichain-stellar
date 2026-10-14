import SwiftUI

/// Semantic colors from the asset catalog (defined light + dark per the DyorHQ design system). The accent is the
/// text/canvas pair inverted; positive/negative/attention are the only status hues and always ship with a sign or
/// word beside them, never color alone.
extension Color {
    static let accent = Color("AccentColor")
    static let positive = Color("Positive")
    static let negative = Color("Negative")
    static let attention = Color("Attention")
    /// Monad brand purple (#836EF9). The single interactive accent: prominent buttons, selection, links and the
    /// app tint. White text stays legible on it in both light and dark, which is why the prominent CTA is readable
    /// in dark mode where the old Paper-on-Paper accent was not. Text and the wordmark stay Ink/Paper — only the
    /// accent is purple, so the monochrome identity holds.
    static let brand = Color("Brand")
    /// Foreground for text/icons sitting on a filled `.positive`/`.negative` status button. White reads on the deep
    /// light-mode fills (#126A4B / #AD3047), but the dark-mode status hues are light mint/rose (#77D8AC / #F496AA) where
    /// white fails WCAG contrast — so this flips to near-black in dark mode, keeping the Long/Short CTAs legible in both.
    static let onStatus = Color(light: .white, dark: Color(red: 0.05, green: 0.05, blue: 0.07))
}

extension ShapeStyle where Self == Color {
    static var positive: Color { .positive }
    static var negative: Color { .negative }
    static var attention: Color { .attention }
}
