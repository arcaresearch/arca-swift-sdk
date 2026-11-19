import Foundation

public enum OrderSizingError: Error, Sendable {
    case missingMarket, invalidQuantity
}

extension Arca {
    /// Freeze a reduction on the canonical market's authoritative base-unit grid.
    /// Metadata absence is an error; this never guesses precision or routes by venue.
    ///
    /// A partial reduction (`fraction` below 1) is rounded down to the market's lot.
    /// A full reduction (`fraction` of 1) returns `size` itself, unrounded: a position
    /// can hold a part finer than the lot (a paper-venue liquidation remnant), and a
    /// close rounded down would leave that part open with no order able to remove it.
    /// Submit a full reduction as a reduce-only order.
    public func normalizedReductionSize(market id: String, size: String, fraction: String) async throws -> String {
        guard let metadata = try await market(id), metadata.name == id else { throw OrderSizingError.missingMarket }
        return try Self.normalizedReductionSize(size: size, fraction: fraction, decimals: metadata.szDecimals)
    }

    static func normalizedReductionSize(size: String, fraction: String, decimals: Int) throws -> String {
        let format = #"^[0-9]+(?:\.[0-9]+)?$"#
        guard size.range(of: format, options: .regularExpression) != nil,
              fraction.range(of: format, options: .regularExpression) != nil,
              let quantity = Decimal(string: size, locale: Locale(identifier: "en_US_POSIX")),
              let part = Decimal(string: fraction, locale: Locale(identifier: "en_US_POSIX")),
              !quantity.isNaN, !part.isNaN, quantity > 0, part > 0, part <= 1,
              (0...18).contains(decimals) else { throw OrderSizingError.invalidQuantity }
        if part == 1 { return NSDecimalNumber(decimal: quantity).stringValue }
        var raw = quantity * part
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, decimals, .down)
        guard !rounded.isNaN, rounded > 0 else { throw OrderSizingError.invalidQuantity }
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
