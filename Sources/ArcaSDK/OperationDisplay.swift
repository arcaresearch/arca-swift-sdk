import Foundation

// MARK: - Transfer Direction

/// Direction of a transfer relative to a specific Arca object.
public enum TransferDirection: String, Sendable {
    case incoming
    case outgoing
}

extension Operation {

    /// Determine whether this transfer is incoming or outgoing relative to `objectPath`.
    ///
    /// Returns `nil` for non-transfer operations or when neither path matches.
    public func transferDirection(for objectPath: String) -> TransferDirection? {
        guard type == .transfer else { return nil }
        if targetArcaPath?.hasPrefix(objectPath) == true { return .incoming }
        if sourceArcaPath?.hasPrefix(objectPath) == true { return .outgoing }
        return nil
    }

    /// A human-readable label for the counterparty in a transfer (e.g. "Vault").
    ///
    /// Given the arca path of the object whose history is being viewed, this
    /// returns a friendly name for the *other* side of the transfer.
    public func counterpartyLabel(for objectPath: String) -> String? {
        guard type == .transfer else { return nil }
        let otherPath: String?
        if sourceArcaPath?.hasPrefix(objectPath) == true {
            otherPath = targetArcaPath
        } else if targetArcaPath?.hasPrefix(objectPath) == true {
            otherPath = sourceArcaPath
        } else {
            return nil
        }
        guard let path = otherPath else { return nil }
        let segments = path.split(separator: "/")
        if segments.last == "main" { return "Vault" }
        return segments.last.map(String.init) ?? path
    }
}

// MARK: - Context Convenience Accessors

extension OperationContext {

    /// Transfer amount (nil for non-transfer contexts).
    public var transferAmount: String? { transfer?.amount }

    /// Transfer fee amount, if a fee was charged.
    public var transferFee: String? { transfer?.feeAmount }

    /// Transfer denomination (e.g. "USD").
    public var transferDenomination: String? { transfer?.denomination }
}
