import Foundation

/// Safe wrappers around `JSONSerialization` that avoid the Objective-C
/// `NSInvalidArgumentException` raised when the top-level value is a JSON
/// *fragment* (a bare number / string / bool / `null`) instead of an array or
/// object.
///
/// `JSONSerialization.data(withJSONObject:)` raises an Obj-C `NSException` — not
/// a Swift `Error` — for fragment input. `try?` only catches Swift errors, so it
/// does **not** intercept that exception and the process aborts with `SIGABRT`.
/// Always gate the call with `isValidJSONObject(_:)` first.
enum JSONSafe {
    /// Serialize `value` to JSON `Data`, returning `nil` (rather than crashing)
    /// when `value` is not a valid top-level JSON object/array. Use this anywhere
    /// the input originates off the wire or from a caller-supplied dictionary.
    static func data(from value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }
}
