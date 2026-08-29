import Foundation

/// The standard Arca API response envelope.
/// All API responses are wrapped in `{ success, data?, error? }`.
struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable {
    let code: String
    let message: String
    let errorId: String?
    /// Structured challenge some refusals carry (co-sign, step-up).
    let details: APIErrorDetails?
}

/// An `error.details` payload reduced to its string-valued entries.
///
/// Decoded permissively on purpose: the fields differ per error code and some
/// carry arrays (step-up's `resources`). A key this decoder cannot read as a
/// string is skipped rather than failing the decode of the error itself —
/// losing a challenge field is recoverable, losing the error is not.
struct APIErrorDetails: Decodable {
    let values: [String: String]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var out: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                out[key.stringValue] = value
            }
        }
        values = out
    }
}
