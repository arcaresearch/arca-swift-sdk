import Foundation

extension OrderExecutionReceipt {
    /// Refine using the merged fills from this receipt's account-scoped watch.
    /// Preview rows cannot finalize accounting. Recorded rows must match the
    /// original order operation and venue order, and cover the executed quantity
    /// exactly after stable-ID deduplication. Unrelated orders are ignored;
    /// conflicting or incomplete evidence leaves this receipt unchanged.
    ///
    /// The recorded VWAP is rounded to 18 fractional digits, ties to even. If
    /// Decimal cannot certify the arithmetic without overflow or precision loss,
    /// the receipt remains provisional. Final means recorded inputs are complete.
    public func refined(using fills: [Fill]) -> OrderExecutionReceipt {
        guard !averagePriceFinal,
              ["FILLED", "CANCELLED", "CANCELED", "EXPIRED", "FAILED", "REJECTED"].contains(status.uppercased()),
              let executed = Self.decimal(filledSize), executed > 0,
              !operationId.isEmpty, !orderId.isEmpty else { return self }
        struct Execution {
            let size: Decimal
            let price: Decimal
            let market: String
            let side: OrderSide?
        }
        var unique: [String: Execution] = [:]
        var market: String?
        for fill in fills where fill.orderId == orderId {
            guard let recorded = fill.operationId, !recorded.isEmpty else { continue }
            guard fill.orderOperationId == operationId,
                  let size = Self.decimal(fill.size), size > 0,
                  let price = Self.decimal(fill.price), price > 0,
                  !fill.market.isEmpty else { return self }
            if let market, market != fill.market { return self }
            market = fill.market
            let id = (fill.fillId?.isEmpty == false ? fill.fillId : nil) ?? fill.id
            guard !id.isEmpty else { return self }
            let execution = Execution(size: size, price: price, market: fill.market, side: fill.side)
            if let previous = unique[id] {
                guard previous.size == size, previous.price == price, previous.market == fill.market,
                      previous.side == fill.side else { return self }
            } else { unique[id] = execution }
        }
        guard !unique.isEmpty else { return self }
        var quantity = Decimal.zero, notional = Decimal.zero
        for execution in unique.values {
            var size = execution.size, price = execution.price, product = Decimal.zero, next = Decimal.zero
            guard NSDecimalMultiply(&product, &size, &price, .bankers) == .noError,
                  NSDecimalAdd(&next, &quantity, &size, .bankers) == .noError else { return self }
            quantity = next
            guard NSDecimalAdd(&next, &notional, &product, .bankers) == .noError else { return self }
            notional = next
        }
        guard quantity == executed else { return self }
        var average = Decimal.zero
        let division = NSDecimalDivide(&average, &notional, &quantity, .bankers)
        guard division == .noError || division == .lossOfPrecision else { return self }
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &average, 18, .bankers)
        guard rounded > 0 else { return self }

        // Certify the rounded answer against exact recorded notional. This also
        // rejects any intermediate double-rounding beyond half an output unit.
        var reconstructed = Decimal.zero, difference = Decimal.zero, tolerance = Decimal.zero
        var halfUnit = Decimal(string: "0.0000000000000000005")!
        guard NSDecimalMultiply(&reconstructed, &rounded, &quantity, .bankers) == .noError,
              NSDecimalSubtract(&difference, &notional, &reconstructed, .bankers) == .noError,
              NSDecimalMultiply(&tolerance, &quantity, &halfUnit, .bankers) == .noError,
              (difference < 0 ? -difference : difference) <= tolerance else { return self }
        return Self(objectId: objectId, operationId: operationId, orderId: orderId, status: status,
            filledSize: filledSize, requestedSize: requestedSize, remainingSize: remainingSize,
            executionState: executionState, fulfillmentState: fulfillmentState,
            remainingDisposition: remainingDisposition, avgFillPrice: NSDecimalNumber(decimal: rounded).stringValue,
            averagePriceFinal: true, averagePriceSource: "ledger_vwap", fillsComplete: true)
    }
}
