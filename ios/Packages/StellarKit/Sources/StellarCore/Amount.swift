import Crypto
import Foundation

enum SHA256Bridge {
    static func hash(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: Data(bytes))) }
}

/// Base-unit amounts (7 decimals for Stellar assets), kept as Int64 end to end; strings at the API boundary.
public enum StellarAmount {
    /// "12.5" → 125000000 (rounds toward zero past `decimals`). Nil for anything that isn't a plain decimal.
    public static func parse(_ text: String, decimals: Int = 7) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." }), t.filter({ $0 == "." }).count <= 1 else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let frac = parts.count > 1 ? String(parts[1].prefix(decimals)) : ""
        let padded = frac + String(repeating: "0", count: decimals - frac.count)
        guard let w = Int64(whole), let f = Int64(padded.isEmpty ? "0" : padded) else { return nil }
        let scale = Int64(pow(10, Double(decimals)))
        let (m, o1) = w.multipliedReportingOverflow(by: scale)
        let (s, o2) = m.addingReportingOverflow(f)
        return o1 || o2 ? nil : s
    }

    /// 125000000 → "12.5"; `maxFraction` trims long tails for display.
    public static func format(_ units: Int64, decimals: Int = 7, maxFraction: Int = 7) -> String {
        let scale = Int64(pow(10, Double(decimals)))
        let neg = units < 0
        let a = units.magnitude
        let whole = a / UInt64(scale)
        var frac = String(a % UInt64(scale))
        frac = String(repeating: "0", count: decimals - frac.count) + frac
        frac = String(frac.prefix(maxFraction))
        while frac.hasSuffix("0") { frac.removeLast() }
        let grouped = NumberFormatter.localizedString(from: NSNumber(value: whole), number: .decimal)
        return (neg ? "-" : "") + grouped + (frac.isEmpty ? "" : "." + frac)
    }

    public static func format(_ text: String, decimals: Int = 7, maxFraction: Int = 4) -> String {
        guard let v = Int64(text) else { return text }
        return format(v, decimals: decimals, maxFraction: maxFraction)
    }
}
