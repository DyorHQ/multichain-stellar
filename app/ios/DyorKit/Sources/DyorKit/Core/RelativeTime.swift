import Foundation

/// A short age or wait in the app's language: one whole unit, the largest that fits, written with iOS's own narrow
/// units (`Duration.UnitsFormatStyle(width: .narrow)` in `L10n.locale`). English reads "45s", "3m", "2h" and "5d", as the
/// app always wrote it; French "3min" and "5j", Spanish "3 min", Chinese "3分钟", Korean "3분". The coin cards, the
/// trade and activity rows (as "%@ ago") and the bridge's time estimate use it. Numbers stay whole: nothing rounds up.
/// Only the unit is the language's: the number is plain digits, never grouped and never in another numbering system,
/// as every number in the app is written ("1200s" on any device, not "1,200s", "1.200s" or "१२००s").
public enum RelativeTime {
    /// How long ago `unix` (seconds since 1970) was at `now`: seconds under a minute, then minutes, hours and days, each
    /// rounded down. Empty when there is no time (0 or less); a time in the future reads as 0 seconds.
    public static func short(_ unix: Int, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        guard unix > 0 else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return narrow(seconds, .seconds, of: 1, locale: locale) }
        if seconds < 3600 { return narrow(seconds / 60, .minutes, of: 60, locale: locale) }
        if seconds < 86400 { return narrow(seconds / 3600, .hours, of: 3600, locale: locale) }
        return narrow(seconds / 86400, .days, of: 86400, locale: locale)
    }

    /// A wait of `seconds`, in whole seconds ("30s", "600s", "1200s"): the bridge's estimate, as it has always been shown.
    public static func seconds(_ seconds: Int, locale: Locale = L10n.locale) -> String {
        narrow(max(0, seconds), .seconds, of: 1, locale: locale)
    }

    /// `count` of `unit` (`unitSeconds` seconds each), in that unit alone. iOS picks the unit's word and its plural form
    /// for the language; the number it wrote in the locale's own style is then put back as plain digits.
    private static func narrow(_ count: Int, _ unit: Duration.UnitsFormatStyle.Unit, of unitSeconds: Int, locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: [unit], width: .narrow)
        style.locale = locale
        var text = Duration.seconds(Int64(count) * Int64(unitSeconds)).formatted(style.attributed)
        let numbers = text.runs.filter { $0.measurement == .value }.map(\.range)
        for range in numbers.reversed() { text.replaceSubrange(range, with: AttributedString(String(count))) }
        return String(text.characters)
    }
}
