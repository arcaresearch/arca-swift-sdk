import Foundation

/// RFC 3339 timestamps as the platform writes them (Go's `RFC3339Nano`): a
/// fraction of one to nine digits with trailing zeros trimmed, or none.
/// `ISO8601DateFormatter` keeps only milliseconds of a fraction, and the
/// trimmed strings do not sort lexically (`…39.7Z` vs `…39.706482Z`), so the
/// fraction is parsed here and added back at full precision.
enum RFC3339 {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        guard let dot = raw.firstIndex(of: "."),
              let end = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return plain.date(from: raw)
        }
        let digits = raw[raw.index(after: dot)..<end]
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isNumber),
              let whole = plain.date(from: String(raw[..<dot]) + String(raw[end...])),
              let value = Double(digits) else { return nil }
        return whole.addingTimeInterval(value / pow(10, Double(digits.count)))
    }
}
